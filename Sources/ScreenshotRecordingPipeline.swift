import Foundation
import AVFoundation
import ScreenCaptureKit
import CoreMedia
import Darwin

enum ScreenshotRecordingTrack { case video, systemAudio, microphone }

/// Mutable capture/writer state is confined to queue; synchronous controls cross that queue explicitly.
final class ScreenshotRecordingPipeline: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    let queue = DispatchQueue(label: "com.gaoseries.GaoCaoZuo.screenshot.recording.writer", qos: .userInitiated)
    let plan: ScreenshotRecordingFilePlan
    private let configuration: ScreenshotRecordingConfiguration
    private let writer: AVAssetWriter
    private let videoInput: AVAssetWriterInput?
    private let systemInput: AVAssetWriterInput?
    private let microphoneInput: AVAssetWriterInput?
    private let tailFrameReadiness: (AVAssetWriterInput) -> Bool
    private let startedAt = Date()
    private let initialCPU = ScreenshotRecordingPipeline.cpuTime()
    private var timeline = ScreenshotRecordingTimeline()
    private var metrics = ScreenshotRecordingMetrics()
    private var lastTimes: [String: CMTime] = [:]
    private var lastEnd = CMTime.zero
    private var started = false
    private var finishing = false
    private var failed = false
    private var lastFailure: Error?
    private var lastVideoBuffer: CMSampleBuffer?
    private var lastJournal = Date.distantPast
    private var recovery: ScreenshotRecordingRecoveryRecord
    var onFailure: ((Error) -> Void)?

    init(configuration: ScreenshotRecordingConfiguration, plan: ScreenshotRecordingFilePlan, width: Int, height: Int,
         tailFrameReadiness: @escaping (AVAssetWriterInput) -> Bool = { $0.isReadyForMoreMediaData }) throws {
        self.configuration = configuration
        self.plan = plan
        self.tailFrameReadiness = tailFrameReadiness
        writer = try AVAssetWriter(outputURL: plan.partialURL, fileType: .mov)
        writer.shouldOptimizeForNetworkUse = false
        if configuration.mode == .video {
            videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: [
                AVVideoCodecKey: AVVideoCodecType.h264,
                AVVideoWidthKey: width, AVVideoHeightKey: height,
                AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: min(60_000_000, max(1_000_000, width * height * 5)),
                                                   AVVideoExpectedSourceFrameRateKey: configuration.frameRate,
                                                   AVVideoMaxKeyFrameIntervalKey: configuration.frameRate * 2],
                AVVideoColorPropertiesKey: [AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                                            AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                                            AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2]
            ])
        } else { videoInput = nil }
        func audioInput(channels: Int) -> AVAssetWriterInput {
            AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVSampleRateKey: 48_000, AVNumberOfChannelsKey: channels, AVEncoderBitRateKey: channels * 96_000])
        }
        systemInput = configuration.systemAudio ? audioInput(channels: 2) : nil
        microphoneInput = configuration.microphone ? audioInput(channels: 1) : nil
        recovery = ScreenshotRecordingRecoveryRecord(sessionID: plan.id, createdAt: startedAt, updatedAt: startedAt,
            state: .preparing, mode: configuration.mode, sourceDescription: configuration.source?.name ?? "麦克风",
            partialFileName: plan.partialURL.lastPathComponent, requestedFileName: plan.finalURL.lastPathComponent,
            systemAudio: configuration.systemAudio, microphone: configuration.microphone, metrics: metrics)
        super.init()
        for input in [videoInput, systemInput, microphoneInput].compactMap({ $0 }) {
            input.expectsMediaDataInRealTime = true
            guard writer.canAdd(input) else { throw ScreenshotRecordingError.writing("此系统无法创建所选独立音视频轨") }
            writer.add(input)
        }
        try plan.writeJournal(recovery)
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        let track: ScreenshotRecordingTrack
        switch type {
        case .screen:
            guard let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
                  let raw = attachments.first?[.status] as? Int,
                  SCFrameStatus(rawValue: raw) == .complete else { return }
            track = .video
        case .audio: track = .systemAudio
        default:
            if #available(macOS 15.0, *), type == .microphone { track = .microphone }
            else { return }
        }
        // SCStream invokes this method on our serial sample queue.
        append(sampleBuffer, track: track)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        queue.async { [weak self] in self?.reportFailure(error) }
    }

    /// Also used by generated, public sample buffers in isolated tests. Must run on queue.
    func append(_ buffer: CMSampleBuffer, track: ScreenshotRecordingTrack) {
        guard !finishing, !failed, CMSampleBufferIsValid(buffer), CMSampleBufferDataIsReady(buffer) else { return }
        let input: AVAssetWriterInput?
        let key: String
        switch track {
        case .video: input = videoInput; key = "video"
        case .systemAudio: input = systemInput; key = "system"
        case .microphone: input = microphoneInput; key = "microphone"
        }
        guard let input else { return }
        let rawPTS = CMSampleBufferGetPresentationTimeStamp(buffer)
        guard let pts = timeline.adjusted(rawPTS, canStart: configuration.mode == .audioOnly || track == .video) else { return }
        if let previous = lastTimes[key], pts <= previous { return }
        if !started {
            guard writer.startWriting() else { reportFailure(writer.error ?? ScreenshotRecordingError.writing("无法启动媒体写入")); return }
            writer.startSession(atSourceTime: .zero)
            started = true
            metrics.firstSampleLatencySeconds = Date().timeIntervalSince(startedAt)
            recovery.state = .recording
            try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: plan.partialURL.path)
        }
        guard writer.status == .writing else {
            reportFailure(writer.error ?? ScreenshotRecordingError.writing("媒体写入器已停止")); return
        }
        guard input.isReadyForMoreMediaData else {
            if track == .video { metrics.droppedVideoFrames += 1 } else { metrics.droppedAudioBuffers += 1 }
            return
        }
        do {
            let adjusted = try Self.retime(buffer, offset: rawPTS - pts)
            guard input.append(adjusted) else { throw writer.error ?? ScreenshotRecordingError.writing("写入样本失败") }
            lastTimes[key] = pts
            switch track {
            case .video: metrics.videoFrames += 1; lastVideoBuffer = buffer
            case .systemAudio: metrics.systemAudioBuffers += 1
            case .microphone: metrics.microphoneBuffers += 1
            }
            let duration = CMSampleBufferGetDuration(adjusted)
            let end = pts + (duration.isNumeric && duration > .zero ? duration : CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate)))
            if end > lastEnd { lastEnd = end }
            metrics.durationSeconds = max(0, lastEnd.seconds)
            if Date().timeIntervalSince(lastJournal) >= 1 { updateJournal() }
        } catch { reportFailure(error) }
    }

    func setPaused(_ paused: Bool, hostTime: CMTime = CMClockGetTime(CMClockGetHostTimeClock())) {
        queue.sync {
            if paused { timeline.pause(at: hostTime); recovery.state = .paused }
            else { timeline.resume(at: hostTime); recovery.state = .recording }
            updateJournal()
        }
    }

    func snapshot() -> ScreenshotRecordingMetrics {
        queue.sync { var m = metrics; m.processCPUSeconds = Self.cpuTime() - initialCPU; return m }
    }

    func finish(failure: Error? = nil, atHostTime: CMTime? = nil) async throws -> ScreenshotRecordingMetrics {
        try await withCheckedThrowingContinuation { continuation in
            queue.async { [self] in
                guard !finishing else { continuation.resume(throwing: ScreenshotRecordingError.invalidState("正在完成录制")); return }
                finishing = true
                recovery.state = .stopping
                recovery.failure = failure?.localizedDescription
                updateJournal()
                var finalizationFailure: Error? = failure ?? lastFailure
                guard started else {
                    recovery.state = .failed
                    let reason = failure ?? lastFailure ?? ScreenshotRecordingError.noSamples
                    recovery.failure = reason.localizedDescription
                    updateJournal()
                    continuation.resume(throwing: reason)
                    return
                }
                guard writer.status == .writing else {
                    let error = writer.error ?? failure ?? ScreenshotRecordingError.writing("媒体写入已中断；中间文件已保留")
                    recovery.state = .failed; recovery.failure = error.localizedDescription; updateJournal()
                    continuation.resume(throwing: error)
                    return
                }
                if finalizationFailure == nil, let hostTime = atHostTime, let end = timeline.elapsed(at: hostTime), end > lastEnd,
                   let videoInput, let lastVideoBuffer, let image = CMSampleBufferGetImageBuffer(lastVideoBuffer),
                   let format = CMSampleBufferGetFormatDescription(lastVideoBuffer) {
                    // SCK omits unchanged desktop frames. Hold the last real frame through the user's stop time.
                    // Otherwise a still screen with audio disabled would produce a one-frame, near-zero duration movie.
                    let frameDuration = CMTime(value: 1, timescale: CMTimeScale(configuration.frameRate))
                    let pts = max(lastEnd, end - frameDuration)
                    var timing = CMSampleTimingInfo(duration: end - pts, presentationTimeStamp: pts, decodeTimeStamp: .invalid)
                    var heldFrame: CMSampleBuffer?
                    let code = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: image,
                        formatDescription: format, sampleTiming: &timing, sampleBufferOut: &heldFrame)
                    if code == noErr, let heldFrame, tailFrameReadiness(videoInput), videoInput.append(heldFrame) {
                        metrics.videoFrames += 1; lastEnd = end; metrics.durationSeconds = end.seconds
                    } else {
                        let error = writer.error ?? ScreenshotRecordingError.writing("尾帧未能写入，实际录制时长可能不完整；已有媒体保留为中间文件，请通过恢复功能核验。")
                        finalizationFailure = error
                        recovery.state = .failed; recovery.failure = error.localizedDescription; updateJournal()
                        // cancelWriting deletes the output. Finish already accepted samples instead,
                        // and still report failure so incomplete media is never committed as completed.
                    }
                }
                guard writer.status == .writing else {
                    let error = writer.error ?? finalizationFailure ?? ScreenshotRecordingError.writing("已有媒体容器无法继续完成；恢复说明与可能存在的中间文件已保留。")
                    recovery.state = .failed; recovery.failure = error.localizedDescription; updateJournal()
                    continuation.resume(throwing: error)
                    return
                }
                for input in [videoInput, systemInput, microphoneInput].compactMap({ $0 }) { input.markAsFinished() }
                writer.endSession(atSourceTime: lastEnd)
                let reportedFailure = finalizationFailure ?? lastFailure
                writer.finishWriting { [self, reportedFailure] in
                    queue.async { [self, reportedFailure] in
                        metrics.processCPUSeconds = Self.cpuTime() - initialCPU
                        if writer.status == .completed {
                            let missingVideo = configuration.mode == .video && metrics.videoFrames == 0
                            let missingSystem = configuration.systemAudio && metrics.systemAudioBuffers == 0
                            let missingMic = configuration.microphone && metrics.microphoneBuffers == 0
                            if let failure = reportedFailure ?? ((missingVideo || missingSystem || missingMic) ? ScreenshotRecordingError.noSamples : nil) {
                                recovery.state = .failed; recovery.failure = failure.localizedDescription; updateJournal()
                                continuation.resume(throwing: failure)
                            } else { continuation.resume(returning: metrics) }
                        } else {
                            let error = writer.error ?? ScreenshotRecordingError.writing("容器索引无法完成；中间文件已保留")
                            recovery.state = .failed; recovery.failure = error.localizedDescription; updateJournal()
                            continuation.resume(throwing: error)
                        }
                    }
                }
            }
        }
    }

    private func updateJournal() {
        recovery.updatedAt = Date()
        recovery.metrics = metrics
        do { try plan.writeJournal(recovery); lastJournal = Date() }
        catch { if !failed { reportFailure(error) } }
    }

    private func reportFailure(_ error: Error) {
        guard !failed else { return }
        failed = true
        lastFailure = error
        recovery.state = .failed
        recovery.failure = error.localizedDescription
        try? plan.writeJournal(recovery)
        onFailure?(error)
    }

    static func retime(_ buffer: CMSampleBuffer, offset: CMTime) throws -> CMSampleBuffer {
        var count = 0
        var status = CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: 0, arrayToFill: nil, entriesNeededOut: &count)
        guard status == noErr, count > 0 else { throw ScreenshotRecordingError.writing("样本缺少时间戳") }
        var timings = [CMSampleTimingInfo](repeating: CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .invalid, decodeTimeStamp: .invalid), count: count)
        status = CMSampleBufferGetSampleTimingInfoArray(buffer, entryCount: count, arrayToFill: &timings, entriesNeededOut: &count)
        guard status == noErr else { throw ScreenshotRecordingError.writing("无法读取媒体时序：\(status)") }
        for i in timings.indices {
            timings[i].presentationTimeStamp = timings[i].presentationTimeStamp - offset
            if timings[i].decodeTimeStamp.isNumeric { timings[i].decodeTimeStamp = timings[i].decodeTimeStamp - offset }
        }
        var result: CMSampleBuffer?
        status = CMSampleBufferCreateCopyWithNewTiming(allocator: kCFAllocatorDefault, sampleBuffer: buffer,
            sampleTimingEntryCount: count, sampleTimingArray: &timings, sampleBufferOut: &result)
        guard status == noErr, let result else { throw ScreenshotRecordingError.writing("无法修正媒体时间戳：\(status)") }
        return result
    }

    private static func cpuTime() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec) + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
    }
}
