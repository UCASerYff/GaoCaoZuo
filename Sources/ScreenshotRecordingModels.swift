import Foundation
import CoreGraphics
import CoreMedia

enum ScreenshotRecordingState: String, Codable {
    case idle, preparing, recording, paused, stopping, failed
    var title: String {
        switch self {
        case .idle: return "未录制"
        case .preparing: return "正在准备"
        case .recording: return "正在录制"
        case .paused: return "已暂停"
        case .stopping: return "正在保存"
        case .failed: return "录制失败"
        }
    }
}

struct ScreenshotRecordingStateMachine {
    private(set) var state: ScreenshotRecordingState = .idle
    mutating func transition(to next: ScreenshotRecordingState) throws {
        let allowed: [ScreenshotRecordingState: Set<ScreenshotRecordingState>] = [
            .idle: [.preparing], .preparing: [.recording, .stopping, .failed],
            .recording: [.paused, .stopping, .failed], .paused: [.recording, .stopping, .failed],
            .stopping: [.idle, .failed], .failed: [.preparing, .idle]
        ]
        guard allowed[state]?.contains(next) == true else {
            throw ScreenshotRecordingError.invalidState("不能从 \(state.title)变为\(next.title)")
        }
        state = next
    }
}

struct ScreenshotRecordingSource: Identifiable, Hashable {
    enum Kind: String, Codable { case display, window, region }
    var kind: Kind
    var displayID: CGDirectDisplayID?
    var windowID: CGWindowID?
    var processID: Int32?
    /// Region in the chosen display's logical, top-left coordinate system, in points.
    var region: CGRect?
    var name: String
    var id: String { "\(kind.rawValue):\(displayID ?? 0):\(windowID ?? 0):\(region?.debugDescription ?? "")" }
}

struct ScreenshotRecordingConfiguration {
    enum Mode: String, Codable { case video, audioOnly }
    var mode: Mode = .video
    var source: ScreenshotRecordingSource?
    var outputURL: URL
    var systemAudio: Bool = true
    var microphone: Bool = false
    var microphoneDeviceID: String?
    var frameRate: Int = 30
    var maximumPixelDimension: Int = 3840
    var showsCursor: Bool = true
    var highlightsMouseClicks: Bool = false
    var isMicrophoneOnly: Bool { mode == .audioOnly && microphone && !systemAudio }
    var needsScreenPermission: Bool { mode == .video || systemAudio }
    var suggestedExtension: String { isMicrophoneOnly ? "m4a" : "mov" }

    func validate() throws {
        guard outputURL.isFileURL else { throw ScreenshotRecordingError.invalidConfiguration("输出必须为本机文件") }
        guard mode == .video || systemAudio || microphone else {
            throw ScreenshotRecordingError.invalidConfiguration("请至少选择系统音或麦克风")
        }
        guard (1...60).contains(frameRate), (64...7680).contains(maximumPixelDimension) else {
            throw ScreenshotRecordingError.invalidConfiguration("帧率须为 1–60，像素边长须为 64–7680")
        }
        guard !needsScreenPermission || source != nil else {
            throw ScreenshotRecordingError.invalidConfiguration("请明确选择录制屏幕、窗口或区域")
        }
        guard outputURL.pathExtension.lowercased() == suggestedExtension else {
            throw ScreenshotRecordingError.invalidConfiguration("此模式请保存为 .\(suggestedExtension)；组合音频 MOV 含独立音轨")
        }
        if let source, source.kind == .region {
            guard let r = source.region, !r.isNull, !r.isInfinite, r.width >= 2, r.height >= 2 else {
                throw ScreenshotRecordingError.invalidConfiguration("录制区域无效")
            }
        }
    }
}

enum ScreenshotRecordingError: LocalizedError {
    case invalidState(String), invalidConfiguration(String), permission(String), unsupported(String)
    case sourceUnavailable(String), writing(String), noSamples, cancelled, lowDiskSpace
    var errorDescription: String? {
        switch self {
        case .invalidState(let s), .invalidConfiguration(let s), .permission(let s), .unsupported(let s),
             .sourceUnavailable(let s), .writing(let s): return s
        case .noSamples: return "没有收到可写入的样本；未生成空白成功文件。检查权限、受保护内容和音源。"
        case .cancelled: return "已取消；已经捕获的中间文件保留，可在恢复目录中检查。"
        case .lowDiskSpace: return "可用磁盘空间不足；已停止并保留中间录制。"
        }
    }
}

struct ScreenshotRecordingMetrics: Codable {
    var videoFrames: Int = 0
    var systemAudioBuffers: Int = 0
    var microphoneBuffers: Int = 0
    var droppedVideoFrames: Int = 0
    var droppedAudioBuffers: Int = 0
    var firstSampleLatencySeconds: Double?
    var durationSeconds: Double = 0
    var processCPUSeconds: Double = 0
}

struct ScreenshotRecordingRecoveryRecord: Codable {
    var schemaVersion = 1
    var sessionID: UUID
    var createdAt: Date
    var updatedAt: Date
    var state: ScreenshotRecordingState
    var mode: ScreenshotRecordingConfiguration.Mode
    var sourceDescription: String
    var partialFileName: String
    var requestedFileName: String
    var systemAudio: Bool
    var microphone: Bool
    var metrics: ScreenshotRecordingMetrics
    var failure: String?
    var recoveryNote = "正常停止会完成容器索引。进程崩溃留下的未完成 MOV 可能无法修复；不会将其标为可播放或删除。"
}

struct ScreenshotRecordingFilePlan {
    let id: UUID
    let finalURL: URL
    let partialURL: URL
    let journalURL: URL
    init(outputURL: URL) throws {
        let fm = FileManager.default
        guard !fm.fileExists(atPath: outputURL.path) else { throw ScreenshotRecordingError.writing("目标文件已存在，请选择其他文件名") }
        let parent = outputURL.deletingLastPathComponent()
        var isDirectory: ObjCBool = false
        guard fm.fileExists(atPath: parent.path, isDirectory: &isDirectory), isDirectory.boolValue,
              fm.isWritableFile(atPath: parent.path) else { throw ScreenshotRecordingError.writing("输出目录不存在或不可写") }
        id = UUID()
        finalURL = outputURL
        partialURL = parent.appendingPathComponent(".gao-recording-\(id.uuidString).partial.\(outputURL.pathExtension)")
        journalURL = parent.appendingPathComponent(".gao-recording-\(id.uuidString).recovery.json")
        if let free = ScreenshotRecordingDiskSpace.available(at: parent),
           free < 64 * 1024 * 1024 { throw ScreenshotRecordingError.lowDiskSpace }
    }
    func writeJournal(_ record: ScreenshotRecordingRecoveryRecord) throws {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(record).write(to: journalURL, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: journalURL.path)
    }
    func commit() throws {
        // A same-directory move preserves completed media and never overwrites a concurrent export.
        guard !FileManager.default.fileExists(atPath: finalURL.path) else { throw ScreenshotRecordingError.writing("停止时目标文件已被其他程序创建；中间文件已保留") }
        try FileManager.default.moveItem(at: partialURL, to: finalURL)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: finalURL.path)
        try? FileManager.default.removeItem(at: journalURL)
    }
}

enum ScreenshotRecordingDiskSpace {
    static func available(at directory: URL) -> Int64? {
        let resource = try? directory.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey]).volumeAvailableCapacityForImportantUsage
        if let resource, resource > 0 { return resource }
        // In a restricted process the opportunistic-capacity API can return zero despite a readable volume.
        // Query the filesystem before treating that value as an actual full disk.
        if let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path),
           let value = attributes[.systemFreeSize] as? NSNumber { return value.int64Value }
        return resource
    }
}

/// All tracks use one host-clock anchor and one pause offset. Audio and video never establish independent timelines.
struct ScreenshotRecordingTimeline {
    private(set) var anchor: CMTime?
    private(set) var pausedAt: CMTime?
    private(set) var removedDuration = CMTime.zero
    mutating func pause(at hostTime: CMTime) { if pausedAt == nil { pausedAt = hostTime } }
    mutating func resume(at hostTime: CMTime) {
        guard let pausedAt else { return }
        let gap = hostTime - pausedAt
        if gap.isNumeric && gap >= .zero { removedDuration = removedDuration + gap }
        self.pausedAt = nil
    }
    mutating func adjusted(_ timestamp: CMTime, canStart: Bool) -> CMTime? {
        guard pausedAt == nil, timestamp.isNumeric else { return nil }
        // The first sample may arrive after a pause. Anchor in the already pause-adjusted
        // clock so pauses before any media do not get subtracted again from future samples.
        if anchor == nil && canStart { anchor = timestamp - removedDuration }
        guard let anchor else { return nil }
        let result = timestamp - anchor - removedDuration
        return result >= .zero && result.isNumeric ? result : nil
    }
    func elapsed(at hostTime: CMTime) -> CMTime? {
        guard let anchor else { return nil }
        let result = (pausedAt ?? hostTime) - anchor - removedDuration
        return result.isNumeric && result >= .zero ? result : nil
    }
}

/// Pure route identity policy, separate from CoreAudio queries so missing/changing routes are testable without audio devices.
struct ScreenshotRecordingOutputRouteGuard {
    private(set) var deviceID: UInt32

    init(currentDeviceID: UInt32?) throws {
        guard let currentDeviceID, currentDeviceID != 0 else {
            throw ScreenshotRecordingError.sourceUnavailable("无法核验当前系统音频输出设备，未开始录制。")
        }
        deviceID = currentDeviceID
    }

    /// A true result requires the controller to pause and let the user review before continuing.
    mutating func observe(currentDeviceID: UInt32?) throws -> Bool {
        guard let currentDeviceID, currentDeviceID != 0 else {
            throw ScreenshotRecordingError.sourceUnavailable("系统音频输出设备不可用；已停止以便核对音源")
        }
        guard currentDeviceID != deviceID else { return false }
        deviceID = currentDeviceID
        return true
    }
}
