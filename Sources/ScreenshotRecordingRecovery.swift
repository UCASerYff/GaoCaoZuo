import Foundation
import AVFoundation

struct ScreenshotRecordingRecoveryInspection {
    let record: ScreenshotRecordingRecoveryRecord
    let journalURL: URL
    let mediaURL: URL
    let canRecover: Bool
    let reason: String
    let videoTracks: Int
    let audioTracks: Int
    let durationSeconds: Double?
}

enum ScreenshotRecordingRecovery {
    /// Reads a user-selected output directory only. It never scans the whole filesystem or deletes unfinished recordings.
    static func journals(in directory: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isRegularFileKey], options: [])
            .filter { $0.lastPathComponent.hasPrefix(".gao-recording-") && $0.lastPathComponent.hasSuffix(".recovery.json") }
    }

    static func inspect(journal: URL) async throws -> ScreenshotRecordingRecoveryInspection {
        let record = try readRecord(journal: journal)
        let media = journal.deletingLastPathComponent().appendingPathComponent(record.partialFileName)
        let attributes = try FileManager.default.attributesOfItem(atPath: media.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              (attributes[.referenceCount] as? NSNumber)?.intValue == 1 else {
            throw ScreenshotRecordingError.writing("恢复中间文件不是独立普通文件；已保留原件")
        }
        do {
            let asset = AVURLAsset(url: media)
            let videos = try await asset.loadTracks(withMediaType: .video)
            let audios = try await asset.loadTracks(withMediaType: .audio)
            let duration = try await asset.load(.duration)
            guard duration.isNumeric, duration.seconds > 0, !videos.isEmpty || !audios.isEmpty else { throw ScreenshotRecordingError.noSamples }
            let checkedMedia: String
            if let video = videos.first {
                _ = video
                let generator = AVAssetImageGenerator(asset: asset)
                _ = try generator.copyCGImage(at: .zero, actualTime: nil)
                checkedMedia = "首个视频样本可解码"
            } else {
                for audio in audios { try decodeAudioFrames(asset: asset, track: audio) }
                checkedMedia = "每条音频轨均已实际解码出非空 PCM 帧"
            }
            return ScreenshotRecordingRecoveryInspection(record: record, journalURL: journal, mediaURL: media, canRecover: true,
                reason: "容器可读取，\(checkedMedia)；可复制为新文件，再由用户完整回放核对。", videoTracks: videos.count,
                audioTracks: audios.count, durationSeconds: duration.seconds)
        } catch {
            return ScreenshotRecordingRecoveryInspection(record: record, journalURL: journal, mediaURL: media, canRecover: false,
                reason: "中间媒体未完成或不可解码：\(error.localizedDescription) 原件与恢复说明继续保留，不声称可修复。",
                videoTracks: 0, audioTracks: 0, durationSeconds: nil)
        }
    }

    private static func decodeAudioFrames(asset: AVAsset, track: AVAssetTrack) throws {
        let reader = try AVAssetReader(asset: asset)
        // nil output settings only return encoded packets (or marker-only buffers).
        // Request PCM so a readable container alone cannot be mistaken for decodable audio.
        let output = AVAssetReaderTrackOutput(track: track, outputSettings: [
            AVFormatIDKey: kAudioFormatLinearPCM, AVLinearPCMBitDepthKey: 16,
            AVLinearPCMIsFloatKey: false, AVLinearPCMIsNonInterleaved: false,
            AVLinearPCMIsBigEndianKey: false
        ])
        guard reader.canAdd(output) else { throw ScreenshotRecordingError.writing("无法创建音频解码器") }
        reader.add(output)
        guard reader.startReading() else { throw reader.error ?? ScreenshotRecordingError.noSamples }
        defer { reader.cancelReading() }
        while let buffer = output.copyNextSampleBuffer() {
            try Task.checkCancellation()
            let frames = CMSampleBufferGetNumSamples(buffer)
            if frames == 0 { continue }
            guard CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer),
                  let description = CMSampleBufferGetFormatDescription(buffer),
                  let format = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee,
                  format.mFormatID == kAudioFormatLinearPCM, format.mBytesPerFrame > 0,
                  frames <= Int.max / Int(format.mBytesPerFrame),
                  let data = CMSampleBufferGetDataBuffer(buffer),
                  CMBlockBufferGetDataLength(data) >= frames * Int(format.mBytesPerFrame) else {
                throw ScreenshotRecordingError.writing("音频解码未返回有效的非空 PCM 帧")
            }
            return
        }
        throw reader.error ?? ScreenshotRecordingError.noSamples
    }

    /// Copies a verified playable intermediate to a new user-selected file, keeping both the original and its journal.
    static func recover(journal: URL, to output: URL) async throws -> ScreenshotRecordingRecoveryInspection {
        let inspection = try await inspect(journal: journal)
        guard inspection.canRecover else { throw ScreenshotRecordingError.writing(inspection.reason) }
        guard output.isFileURL, output.pathExtension.lowercased() == inspection.mediaURL.pathExtension.lowercased(),
              !FileManager.default.fileExists(atPath: output.path) else { throw ScreenshotRecordingError.writing("请选择同类型且不存在的恢复目标") }
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".gao-recovery-\(UUID().uuidString).\(output.pathExtension)")
        defer { try? FileManager.default.removeItem(at: temporary) }
        try FileManager.default.copyItem(at: inspection.mediaURL, to: temporary)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: temporary.path)
        let asset = AVURLAsset(url: temporary)
        let duration = try await asset.load(.duration)
        guard duration.isNumeric, abs(duration.seconds - (inspection.durationSeconds ?? -1)) < 0.001 else {
            throw ScreenshotRecordingError.writing("恢复副本时长核验失败；未替换目标")
        }
        try FileManager.default.moveItem(at: temporary, to: output)
        return inspection
    }

    private static func readRecord(journal: URL) throws -> ScreenshotRecordingRecoveryRecord {
        let attributes = try FileManager.default.attributesOfItem(atPath: journal.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular,
              let size = attributes[.size] as? NSNumber, size.intValue <= 1_048_576 else {
            throw ScreenshotRecordingError.writing("恢复说明不可读或超出大小预算")
        }
        let bytes = try Data(contentsOf: journal, options: [.mappedIfSafe])
        guard let object = try JSONSerialization.jsonObject(with: bytes) as? [String: Any],
              object["schemaVersion"] as? Int == 1 else { throw ScreenshotRecordingError.unsupported("恢复说明版本过新或不受支持；不会重置或覆盖") }
        let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
        let record = try decoder.decode(ScreenshotRecordingRecoveryRecord.self, from: bytes)
        let prefix = ".gao-recording-\(record.sessionID.uuidString).partial."
        guard record.partialFileName == URL(fileURLWithPath: record.partialFileName).lastPathComponent,
              record.partialFileName.hasPrefix(prefix), !record.partialFileName.contains(".."),
              ["mov", "m4a"].contains(URL(fileURLWithPath: record.partialFileName).pathExtension.lowercased()) else {
            throw ScreenshotRecordingError.writing("恢复说明包含越界路径；不会读取该对象")
        }
        return record
    }
}
