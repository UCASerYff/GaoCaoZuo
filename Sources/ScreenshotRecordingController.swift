import AppKit
import AVFoundation
import ScreenCaptureKit
import Combine
import CoreAudio

@MainActor
final class ScreenshotRecordingController: NSObject, ObservableObject {
    @Published private(set) var state: ScreenshotRecordingState = .idle
    @Published private(set) var elapsed: TimeInterval = 0
    @Published private(set) var statusMessage = "录制仅在你点击开始后进行"
    @Published private(set) var lastError: String?
    /// Host lifecycle gate; evaluated before validation, permissions, files or devices.
    /// An active session is checked first and can never be stopped by a second start.
    var startBlockingReason: (() -> String?)?
    /// Host cancels pending input actions synchronously; never stops an active script.
    var onWillStart: (() -> Void)?
    @Published private(set) var lastOutputURL: URL?
    @Published private(set) var recoveryURL: URL?
    @Published private(set) var sources: [ScreenshotRecordingSource] = []
    @Published private(set) var metrics = ScreenshotRecordingMetrics()
    @Published private(set) var microphonePowerDB: Float = -160
    private var machine = ScreenshotRecordingStateMachine()
    private var pipeline: ScreenshotRecordingPipeline?
    private var stream: SCStream?
    private var audioRecorder: AVAudioRecorder?
    private var recorderDelegate: ScreenshotRecordingRecorderDelegate?
    private var filePlan: ScreenshotRecordingFilePlan?
    private var activeConfiguration: ScreenshotRecordingConfiguration?
    private var timer: Timer?
    private var monitorTask: Task<Void, Never>?
    private var selectedMicrophoneID: String?
    private var outputRoute: ScreenshotRecordingOutputRouteGuard?
    private var startedAt: Date?
    private var activeSessionID: UUID?
    private var sourceRefreshID = UUID()

    var isActive: Bool { [.preparing, .recording, .paused, .stopping].contains(state) }

    /// Explicit button action only; start() itself never opens permission dialogs.
    func requestMicrophonePermission() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    func refreshSources() async {
        guard !isActive else { return }
        let refreshID = UUID()
        sourceRefreshID = refreshID
        guard CGPreflightScreenCaptureAccess() else {
            statusMessage = "列出屏幕和窗口需要屏幕录制权限；仅麦克风录音不需要此权限"
            sources = []
            return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard sourceRefreshID == refreshID, !isActive, !Task.isCancelled else { return }
            var options = content.displays.map { ScreenshotRecordingSource(kind: .display, displayID: $0.displayID,
                name: "屏幕 \($0.displayID)（\($0.width) × \($0.height)）") }
            options += content.windows.filter { $0.owningApplication?.processID != ProcessInfo.processInfo.processIdentifier && $0.frame.width > 1 && $0.frame.height > 1 }
                .map { ScreenshotRecordingSource(kind: .window, windowID: $0.windowID, processID: $0.owningApplication?.processID,
                    name: "\($0.owningApplication?.applicationName ?? "窗口") — \($0.title ?? "未命名窗口")") }
            sources = options
            statusMessage = "已读取可捕获源；受保护内容可能拒绝输出"
        } catch {
            guard sourceRefreshID == refreshID, !isActive, !Task.isCancelled else { return }
            statusMessage = error.localizedDescription
        }
    }

    func start(configuration: ScreenshotRecordingConfiguration) async {
        guard state == .idle || state == .failed else { return }
        if let reason = startBlockingReason?() {
            lastError = reason; statusMessage = reason
            return
        }
        onWillStart?()
        lastError = nil
        let sessionID = UUID()
        activeSessionID = sessionID
        sourceRefreshID = UUID()
        activeConfiguration = nil; filePlan = nil; startedAt = nil
        do {
            try configuration.validate()
            if configuration.needsScreenPermission && !CGPreflightScreenCaptureAccess() {
                throw ScreenshotRecordingError.permission("屏幕录制权限未获准。请在系统设置授权后重试。")
            }
            if configuration.microphone && AVCaptureDevice.authorizationStatus(for: .audio) != .authorized {
                throw ScreenshotRecordingError.permission("麦克风权限未获准。请点击麦克风授权按钮后重试。")
            }
            if configuration.microphone && !configuration.isMicrophoneOnly {
                guard #available(macOS 15.0, *) else { throw ScreenshotRecordingError.unsupported("录屏伴麦克风/系统音与麦克风组合需要 macOS 15；macOS 14 可独立录麦克风。") }
            }
            if configuration.highlightsMouseClicks {
                guard #available(macOS 15.0, *) else { throw ScreenshotRecordingError.unsupported("原生鼠标点击高亮需要 macOS 15") }
            }
            try changeState(.preparing)
            elapsed = 0; metrics = ScreenshotRecordingMetrics(); lastOutputURL = nil; startedAt = nil
            filePlan = nil; recoveryURL = nil
            activeConfiguration = configuration
            outputRoute = nil
            if configuration.systemAudio {
                // Establish a known route before constructing a writer or starting capture.
                outputRoute = try ScreenshotRecordingOutputRouteGuard(currentDeviceID: ScreenshotRecordingAudioRoute.currentOutputDeviceID())
            }
            let plan = try ScreenshotRecordingFilePlan(outputURL: configuration.outputURL)
            filePlan = plan; recoveryURL = plan.journalURL
            selectedMicrophoneID = configuration.microphoneDeviceID ?? AVCaptureDevice.default(for: .audio)?.uniqueID
            if configuration.microphone && selectedMicrophoneID == nil { throw ScreenshotRecordingError.sourceUnavailable("没有可用麦克风") }
            if configuration.isMicrophoneOnly {
                if let requested = configuration.microphoneDeviceID, requested != AVCaptureDevice.default(for: .audio)?.uniqueID {
                    throw ScreenshotRecordingError.unsupported("独立麦克风录音使用系统当前输入设备；请先在系统声音设置选择该设备。")
                }
                let recorder = try AVAudioRecorder(url: plan.partialURL, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                    AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000,
                    AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue])
                let failureHandler = makeFailureHandler(for: sessionID)
                let delegate = ScreenshotRecordingRecorderDelegate { error in _ = failureHandler(error) }
                recorderDelegate = delegate
                recorder.delegate = delegate
                recorder.isMeteringEnabled = true
                audioRecorder = recorder
                try writeMicrophoneJournal(state: .preparing)
                guard recorder.prepareToRecord(), recorder.record() else { throw ScreenshotRecordingError.writing("麦克风录音器无法启动") }
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.partialURL.path)
            } else {
                let (filter, captureConfiguration) = try await makeCapture(configuration, sessionID: sessionID)
                try requireSession(sessionID, in: [.preparing])
                let writer = try ScreenshotRecordingPipeline(configuration: configuration, plan: plan,
                    width: captureConfiguration.width, height: captureConfiguration.height)
                let failureHandler = makeFailureHandler(for: sessionID)
                writer.onFailure = { error in _ = failureHandler(error) }
                pipeline = writer
                let stream = SCStream(filter: filter, configuration: captureConfiguration, delegate: writer)
                self.stream = stream
                if configuration.mode == .video { try stream.addStreamOutput(writer, type: .screen, sampleHandlerQueue: writer.queue) }
                if configuration.systemAudio { try stream.addStreamOutput(writer, type: .audio, sampleHandlerQueue: writer.queue) }
                if configuration.microphone {
                    if #available(macOS 15.0, *) { try stream.addStreamOutput(writer, type: .microphone, sampleHandlerQueue: writer.queue) }
                }
                try await stream.startCapture()
                guard isCurrentSession(sessionID, in: [.preparing]) else {
                    // This is the local old stream, never whichever stream a new session owns.
                    try? await stream.stopCapture()
                    return
                }
            }
            try requireSession(sessionID, in: [.preparing])
            startedAt = Date()
            try changeState(.recording)
            statusMessage = configuration.mode == .audioOnly ? "● 正在仅录音；未创建屏幕视频轨" : "● 正在录屏；可随时暂停或停止"
            startMonitoring(sessionID: sessionID)
        } catch {
            guard activeSessionID == sessionID, state != .stopping else { return }
            // Hold the controller in stopping while cleanup suspends. A callback from this
            // failed startup must not run a second stop, or clean up a later session.
            if state != .preparing { try? changeState(.preparing) }
            try? changeState(.stopping)
            stopMonitoring()
            let oldStream = stream, oldPipeline = pipeline
            stream = nil; pipeline = nil
            audioRecorder?.delegate = nil
            audioRecorder?.stop(); audioRecorder = nil; recorderDelegate = nil
            if let oldStream {
                try? await oldStream.stopCapture()
                guard isCurrentSession(sessionID, in: [.stopping]) else { return }
            }
            if let oldPipeline {
                _ = try? await oldPipeline.finish(failure: error)
                guard isCurrentSession(sessionID, in: [.stopping]) else { return }
            }
            try? writeMicrophoneJournal(state: .failed, failure: error)
            try? changeState(.failed)
            activeSessionID = nil
            lastError = error.localizedDescription
            statusMessage = error.localizedDescription
        }
    }

    func pause() {
        guard state == .recording else { return }
        pipeline?.setPaused(true)
        audioRecorder?.pause()
        try? changeState(.paused)
        try? writeMicrophoneJournal(state: .paused)
        statusMessage = "⏸ 已暂停；暂停时段不会写入输出时长"
    }

    func resume() {
        guard state == .paused else { return }
        if let recorder = audioRecorder, !recorder.record() {
            if let sessionID = activeSessionID {
                _ = makeFailureHandler(for: sessionID)(ScreenshotRecordingError.sourceUnavailable("麦克风无法恢复录音"))
            }
            return
        }
        pipeline?.setPaused(false)
        try? changeState(.recording)
        try? writeMicrophoneJournal(state: .recording)
        statusMessage = "● 已继续录制"
    }

    func stop() async {
        guard let sessionID = activeSessionID else { return }
        await stop(failure: nil, sessionID: sessionID)
    }
    func cancel() async {
        guard let sessionID = activeSessionID else { return }
        await stop(failure: ScreenshotRecordingError.cancelled, sessionID: sessionID)
    }

    private func stop(failure: Error?, sessionID: UUID) async {
        guard isCurrentSession(sessionID, in: [.recording, .paused, .preparing]) else { return }
        try? changeState(.stopping)
        let stoppedAtHostTime = CMClockGetTime(CMClockGetHostTimeClock())
        stopMonitoring()
        statusMessage = "正在完成媒体容器，请稍候"
        var captureError = failure
        let oldStream = stream
        stream = nil
        if let oldStream {
            do { try await oldStream.stopCapture() }
            catch { if captureError == nil { captureError = error } }
            guard isCurrentSession(sessionID, in: [.stopping]) else { return }
        }
        do {
            guard let plan = filePlan, let config = activeConfiguration else { throw captureError ?? ScreenshotRecordingError.noSamples }
            if let recorder = audioRecorder {
                metrics.durationSeconds = recorder.currentTime
                recorder.delegate = nil
                recorder.stop()
                audioRecorder = nil; recorderDelegate = nil
                if let captureError { try? writeMicrophoneJournal(state: .failed, failure: captureError); throw captureError }
                let asset = AVURLAsset(url: plan.partialURL)
                let tracks = try await asset.loadTracks(withMediaType: .audio)
                try requireSession(sessionID, in: [.stopping])
                let duration = try await asset.load(.duration)
                try requireSession(sessionID, in: [.stopping])
                guard tracks.count == 1, duration.isNumeric, duration.seconds > 0 else { throw ScreenshotRecordingError.noSamples }
                metrics.durationSeconds = duration.seconds
            } else if let pipeline {
                let finishedMetrics = try await pipeline.finish(failure: captureError, atHostTime: stoppedAtHostTime)
                try requireSession(sessionID, in: [.stopping])
                metrics = finishedMetrics
                let asset = AVURLAsset(url: plan.partialURL)
                let videoTracks = try await asset.loadTracks(withMediaType: .video)
                try requireSession(sessionID, in: [.stopping])
                let audioTracks = try await asset.loadTracks(withMediaType: .audio)
                try requireSession(sessionID, in: [.stopping])
                let expectedAudio = (config.systemAudio ? 1 : 0) + (config.microphone ? 1 : 0)
                guard videoTracks.count == (config.mode == .video ? 1 : 0), audioTracks.count == expectedAudio else {
                    throw ScreenshotRecordingError.writing("导出轨道核对失败；中间文件已保留")
                }
            } else { throw captureError ?? ScreenshotRecordingError.noSamples }
            try plan.commit()
            lastOutputURL = plan.finalURL; recoveryURL = nil; elapsed = metrics.durationSeconds
            try changeState(.idle)
            statusMessage = config.mode == .audioOnly ? "已保存仅音频文件（无视频轨）；请回放核对音源" : "已保存录屏；请回放核对画面与音画同步"
        } catch {
            guard isCurrentSession(sessionID, in: [.stopping]) else { return }
            try? writeMicrophoneJournal(state: .failed, failure: error)
            try? changeState(.failed)
            lastError = error.localizedDescription
            statusMessage = "\(error.localizedDescription) 中间文件与恢复说明保留在所选输出目录。"
        }
        pipeline = nil; audioRecorder = nil; recorderDelegate = nil; activeSessionID = nil
    }

    private func changeState(_ next: ScreenshotRecordingState) throws {
        try machine.transition(to: next); state = next
    }

    private func makeCapture(_ configuration: ScreenshotRecordingConfiguration, sessionID: UUID) async throws -> (SCContentFilter, SCStreamConfiguration) {
        guard let source = configuration.source else { throw ScreenshotRecordingError.sourceUnavailable("没有选定捕获源") }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        try requireSession(sessionID, in: [.preparing])
        let filter: SCContentFilter
        var rect: CGRect
        if source.kind == .window {
            guard let window = content.windows.first(where: { $0.windowID == source.windowID && $0.owningApplication?.processID == source.processID }) else {
                throw ScreenshotRecordingError.sourceUnavailable("选定窗口已关闭或身份发生变化")
            }
            filter = SCContentFilter(desktopIndependentWindow: window)
            rect = CGRect(origin: .zero, size: window.frame.size)
        } else {
            guard let display = content.displays.first(where: { $0.displayID == source.displayID }) else { throw ScreenshotRecordingError.sourceUnavailable("选定屏幕已断开") }
            let ownApps = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
            filter = SCContentFilter(display: display, excludingApplications: ownApps, exceptingWindows: [])
            let bounds = CGRect(origin: .zero, size: display.frame.size)
            rect = source.kind == .region ? (source.region ?? .null) : bounds
            guard bounds.contains(rect), !rect.isEmpty else { throw ScreenshotRecordingError.sourceUnavailable("区域超出选定屏幕，请重新选择") }
        }
        let config = SCStreamConfiguration()
        if configuration.mode == .video {
            let scale = Double(filter.pointPixelScale)
            let fullWidth = rect.width * scale, fullHeight = rect.height * scale
            let ratio = min(1, Double(configuration.maximumPixelDimension) / max(fullWidth, fullHeight))
            config.width = max(2, Int(fullWidth * ratio) / 2 * 2)
            config.height = max(2, Int(fullHeight * ratio) / 2 * 2)
            config.sourceRect = rect
            config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
        } else {
            // No .screen output is registered, and no AVAssetWriter video input is constructed.
            config.width = 2; config.height = 2
            config.minimumFrameInterval = CMTime(seconds: 1, preferredTimescale: 600)
        }
        config.queueDepth = 5
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.colorSpaceName = CGColorSpace.sRGB
        config.showsCursor = configuration.mode == .video && configuration.showsCursor
        config.capturesAudio = configuration.systemAudio
        config.sampleRate = 48_000; config.channelCount = 2
        config.excludesCurrentProcessAudio = false
        config.streamName = "搞操作 — 用户主动录制"
        if #available(macOS 15.0, *) {
            config.captureMicrophone = configuration.microphone
            config.microphoneCaptureDeviceID = selectedMicrophoneID
            config.showMouseClicks = configuration.highlightsMouseClicks
        }
        return (filter, config)
    }

    private func startMonitoring(sessionID: UUID) {
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, self.isCurrentSession(sessionID, in: [.recording, .paused]) else { return }
                if let pipeline = self.pipeline { self.metrics = pipeline.snapshot(); self.elapsed = self.metrics.durationSeconds }
                if let recorder = self.audioRecorder {
                    self.elapsed = recorder.currentTime
                    recorder.updateMeters(); self.microphonePowerDB = recorder.averagePower(forChannel: 0)
                    self.metrics.durationSeconds = self.elapsed
                }
            }
        }
        monitorTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 2_000_000_000)
                guard !Task.isCancelled, let self, self.isCurrentSession(sessionID, in: [.recording, .paused]) else { return }
                guard await self.monitorOnce(sessionID: sessionID, check: { try await self.checkSources(sessionID: sessionID) }) else { return }
            }
        }
    }

    private func stopMonitoring() { timer?.invalidate(); timer = nil; monitorTask?.cancel(); monitorTask = nil }

    private func monitorOnce(sessionID: UUID, check: () async throws -> Void) async -> Bool {
        guard !Task.isCancelled, isCurrentSession(sessionID, in: [.recording, .paused]) else { return false }
        do {
            try await check()
            guard !Task.isCancelled, isCurrentSession(sessionID, in: [.recording, .paused]) else { return false }
            try writeMicrophoneJournal(state: state)
            return true
        } catch {
            guard !Task.isCancelled, isCurrentSession(sessionID, in: [.recording, .paused]) else { return false }
            await stop(failure: error, sessionID: sessionID)
            return false
        }
    }

    private func checkSources(sessionID: UUID) async throws {
        try requireSession(sessionID, in: [.recording, .paused])
        guard let config = activeConfiguration else { return }
        if let plan = filePlan,
           let free = ScreenshotRecordingDiskSpace.available(at: plan.finalURL.deletingLastPathComponent()),
           free < 8 * 1024 * 1024 { throw ScreenshotRecordingError.lowDiskSpace }
        if config.microphone {
            guard AVCaptureDevice.authorizationStatus(for: .audio) == .authorized else { throw ScreenshotRecordingError.permission("麦克风权限已撤销") }
            let devices = AVCaptureDevice.DiscoverySession(deviceTypes: [.microphone], mediaType: .audio, position: .unspecified).devices
            guard devices.contains(where: { $0.uniqueID == selectedMicrophoneID && $0.isConnected }) else { throw ScreenshotRecordingError.sourceUnavailable("选定麦克风已断开；未切换到其他音源") }
            if config.isMicrophoneOnly && AVCaptureDevice.default(for: .audio)?.uniqueID != selectedMicrophoneID {
                throw ScreenshotRecordingError.sourceUnavailable("系统输入设备发生变化；已停止以免悄悄切换音源")
            }
        }
        if config.systemAudio {
            guard var route = outputRoute else {
                throw ScreenshotRecordingError.sourceUnavailable("系统音频输出设备身份未建立；已停止以免切换到未知音源")
            }
            let changed = try route.observe(currentDeviceID: ScreenshotRecordingAudioRoute.currentOutputDeviceID())
            outputRoute = route
            if changed {
                if state == .recording { pause() }
                statusMessage = "耳机或系统音频输出设备发生变化，已暂停。请核对新音源后点击继续。"
            }
        }
        if config.needsScreenPermission {
            guard CGPreflightScreenCaptureAccess() else { throw ScreenshotRecordingError.permission("屏幕录制权限已撤销") }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            try requireSession(sessionID, in: [.recording, .paused])
            if config.source?.kind == .window {
                guard content.windows.contains(where: { $0.windowID == config.source?.windowID && $0.owningApplication?.processID == config.source?.processID }) else {
                    throw ScreenshotRecordingError.sourceUnavailable("选定窗口已关闭或进程已变化")
                }
            } else if !content.displays.contains(where: { $0.displayID == config.source?.displayID }) {
                throw ScreenshotRecordingError.sourceUnavailable("选定屏幕已断开；未切换到其他屏幕")
            }
        }
    }

    private func writeMicrophoneJournal(state: ScreenshotRecordingState, failure: Error? = nil) throws {
        guard let config = activeConfiguration, config.isMicrophoneOnly, let plan = filePlan else { return }
        let now = Date()
        let record = ScreenshotRecordingRecoveryRecord(sessionID: plan.id, createdAt: startedAt ?? now, updatedAt: now, state: state,
            mode: .audioOnly, sourceDescription: "系统当前麦克风", partialFileName: plan.partialURL.lastPathComponent,
            requestedFileName: plan.finalURL.lastPathComponent, systemAudio: false, microphone: true,
            metrics: metrics, failure: failure?.localizedDescription)
        try plan.writeJournal(record)
    }

    private func isCurrentSession(_ sessionID: UUID, in states: [ScreenshotRecordingState]) -> Bool {
        activeSessionID == sessionID && states.contains(state)
    }

    private func requireSession(_ sessionID: UUID, in states: [ScreenshotRecordingState]) throws {
        guard isCurrentSession(sessionID, in: states), !Task.isCancelled else { throw CancellationError() }
    }

    /// The closure captures the producer's session before crossing from its callback queue.
    /// Both the writer and each recorder's own delegate use this exact path.
    private func makeFailureHandler(for sessionID: UUID) -> (Error) -> Task<Void, Never> {
        { [weak self] error in
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.stop(failure: error, sessionID: sessionID)
            }
        }
    }

    #if RECORDING_SESSION_TESTS
    // Test setup never constructs a recorder/stream or queries devices. Failures still run
    // the production callback, monitor, and stop paths instead of a duplicate gate policy.
    func beginIsolatedSessionForTesting() throws -> UUID {
        guard state == .idle || state == .failed else { throw ScreenshotRecordingError.invalidState("测试会话仍活动") }
        let sessionID = UUID()
        activeSessionID = sessionID
        try changeState(.preparing)
        try changeState(.recording)
        return sessionID
    }
    func failureHandlerForTesting(sessionID: UUID) -> (Error) -> Task<Void, Never> { makeFailureHandler(for: sessionID) }
    func monitorOnceForTesting(sessionID: UUID, check: () async throws -> Void) async -> Bool {
        await monitorOnce(sessionID: sessionID, check: check)
    }
    #endif
}

/// AVAudioRecorder's delegate is weak. Keep one proxy per session, never reuse the
/// controller as every old recorder's delegate with access to the current session.
private final class ScreenshotRecordingRecorderDelegate: NSObject, AVAudioRecorderDelegate {
    private let onFailure: (Error) -> Void
    init(onFailure: @escaping (Error) -> Void) { self.onFailure = onFailure }
    func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Error?) {
        onFailure(error ?? ScreenshotRecordingError.writing("麦克风编码器失败"))
    }
    func audioRecorderDidFinishRecording(_ recorder: AVAudioRecorder, successfully flag: Bool) {
        if !flag { onFailure(ScreenshotRecordingError.writing("麦克风录音意外停止")) }
    }
}

private enum ScreenshotRecordingAudioRoute {
    static func currentOutputDeviceID() -> AudioDeviceID? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &address, 0, nil, &size, &device) == noErr,
              device != kAudioObjectUnknown else { return nil }
        return device
    }
}
