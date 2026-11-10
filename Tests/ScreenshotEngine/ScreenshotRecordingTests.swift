// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import Foundation
import AVFoundation
import CoreVideo
import ImageIO

private struct RecordingTestFailure: LocalizedError {
    var message: String
    var errorDescription: String? { message }
}
private func recordingExpect(_ condition: @autoclosure () -> Bool, _ message: String) throws {
    if !condition() { throw RecordingTestFailure(message: message) }
}

/// Pure models only: no writer/decoder, device query, screen enumeration, permission request or UI.
func ScreenshotRunRecordingAlgorithmTests() throws {
    var early = ScreenshotRecordingTimeline()
    early.pause(at: CMTime(seconds: 100, preferredTimescale: 48_000))
    early.resume(at: CMTime(seconds: 103, preferredTimescale: 48_000))
    let first = early.adjusted(CMTime(seconds: 104, preferredTimescale: 48_000), canStart: true)
    try recordingExpect(first == .zero, "首帧前暂停被重复扣除，首个恢复样本未从零开始")
    let later = early.adjusted(CMTime(seconds: 105, preferredTimescale: 48_000), canStart: true)
    try recordingExpect(abs((later?.seconds ?? -1) - 1) < 0.0001, "首帧前暂停导致后续样本丢失或偏移")
    early.pause(at: CMTime(seconds: 105, preferredTimescale: 48_000))
    early.resume(at: CMTime(seconds: 108, preferredTimescale: 48_000))
    try recordingExpect(abs((early.adjusted(CMTime(seconds: 108, preferredTimescale: 48_000), canStart: true)?.seconds ?? -1) - 1) < 0.0001,
        "首帧前和首帧后的暂停修正不能累积漂移")
    early.pause(at: CMTime(seconds: 109, preferredTimescale: 48_000))
    try recordingExpect(abs((early.elapsed(at: CMTime(seconds: 115, preferredTimescale: 48_000))?.seconds ?? -1) - 2) < 0.0001,
        "暂停时停止计时未冻结到暂停入口")

    var repeated = ScreenshotRecordingTimeline()
    repeated.pause(at: CMTime(seconds: 100, preferredTimescale: 48_000))
    repeated.resume(at: CMTime(seconds: 102, preferredTimescale: 48_000))
    repeated.pause(at: CMTime(seconds: 103, preferredTimescale: 48_000))
    repeated.resume(at: CMTime(seconds: 106, preferredTimescale: 48_000))
    try recordingExpect(repeated.adjusted(CMTime(seconds: 107, preferredTimescale: 48_000), canStart: false) == nil,
        "视频首帧之前的音频错误建立了独立锚点")
    try recordingExpect(repeated.adjusted(CMTime(seconds: 108, preferredTimescale: 48_000), canStart: true) == .zero,
        "多个首帧前暂停错误推迟了时间轴")
    let audio = repeated.adjusted(CMTime(seconds: 108.1, preferredTimescale: 48_000), canStart: false)
    try recordingExpect(abs((audio?.seconds ?? -1) - 0.1) < 0.0001, "音视频未沿用同一修正锚点")

    let invalidOptions = [
        ScreenshotGIFOptions(startSeconds: .nan), ScreenshotGIFOptions(startSeconds: .infinity),
        ScreenshotGIFOptions(durationSeconds: .nan), ScreenshotGIFOptions(durationSeconds: .infinity),
        ScreenshotGIFOptions(durationSeconds: -.infinity), ScreenshotGIFOptions(durationSeconds: .greatestFiniteMagnitude),
        ScreenshotGIFOptions(durationSeconds: -.greatestFiniteMagnitude),
        ScreenshotGIFOptions(framesPerSecond: .max), ScreenshotGIFOptions(framesPerSecond: .min),
        ScreenshotGIFOptions(maximumWidth: .max), ScreenshotGIFOptions(maximumHeight: .max),
        ScreenshotGIFOptions(durationSeconds: 120, framesPerSecond: 30, maximumWidth: 64, maximumHeight: 64),
        ScreenshotGIFOptions(crop: CGRect(x: CGFloat.infinity, y: 0, width: 1, height: 1))
    ]
    for (index, options) in invalidOptions.enumerated() {
        let count = options.frameCount
        let estimate = options.estimate
        try recordingExpect((0...3600).contains(count), "GIF 帧数转换未保持安全上限（case \(index)）")
        try recordingExpect(estimate.frameCount == 0 && estimate.estimatedMinimumBytes == 0 && estimate.estimatedMaximumBytes == 0,
            "无效或溢出 GIF 参数产生了成功容量估计（case \(index)）")
        var rejected = false
        do { try options.validate() } catch { rejected = true }
        try recordingExpect(rejected, "无效 GIF 参数通过校验")
    }
    let valid = ScreenshotGIFOptions(startSeconds: 0.25, durationSeconds: 1, framesPerSecond: 10, maximumWidth: 64, maximumHeight: 64)
    try valid.validate()
    try recordingExpect(valid.frameCount == 10 && valid.estimate.frameCount == 10 && valid.estimate.estimatedMaximumBytes > 0,
        "安全估计改变了有效 GIF 帧数")

    for missing: UInt32? in [nil, 0] {
        var rejected = false
        do { _ = try ScreenshotRecordingOutputRouteGuard(currentDeviceID: missing) } catch ScreenshotRecordingError.sourceUnavailable { rejected = true }
        try recordingExpect(rejected, "系统音首次未知设备被当作可录制设备")
    }
    var route = try ScreenshotRecordingOutputRouteGuard(currentDeviceID: 42)
    let unchanged = try route.observe(currentDeviceID: 42)
    try recordingExpect(!unchanged, "未变化音源被错误判定为切换")
    let changed = try route.observe(currentDeviceID: 43)
    try recordingExpect(changed && route.deviceID == 43, "真实设备身份改变没有要求暂停复核")
    for missing: UInt32? in [nil, 0] {
        var rejected = false
        do { _ = try route.observe(currentDeviceID: missing) } catch ScreenshotRecordingError.sourceUnavailable { rejected = true }
        try recordingExpect(rejected && route.deviceID == 43, "设备消失后切换到未知来源或改写了原身份")
    }
    print("RecordingAlgorithmTests PASS: pre-anchor/repeated pauses, frozen pause time, 13 invalid GIF estimates, valid frame count, injected route missing/unchanged/changed/lost; no media or device access")
}

/// A generated-media regression for the data-loss branch only. No audio or screen/device APIs are called.
func ScreenshotRunRecordingFinalizationRetentionTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-Screenshot-TailRetentionTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let output = directory.appendingPathComponent("tail-backpressure.mov")
    let configuration = ScreenshotRecordingConfiguration(mode: .video,
        source: ScreenshotRecordingSource(kind: .display, displayID: 42, name: "自建像素，非屏幕采集"),
        outputURL: output, systemAudio: false, microphone: false, frameRate: 30, maximumPixelDimension: 128)
    let plan = try ScreenshotRecordingFilePlan(outputURL: output)
    var readinessChecks = 0
    let pipeline = try ScreenshotRecordingPipeline(configuration: configuration, plan: plan, width: 128, height: 96,
        tailFrameReadiness: { _ in readinessChecks += 1; return false })
    for index in 0..<5 {
        let pts = CMTime(seconds: 100 + Double(index) / 30, preferredTimescale: 48_000)
        let frame = try generatedRecordingVideoFrame(index: index, pts: pts)
        pipeline.queue.sync { pipeline.append(frame, track: .video) }
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try recordingExpect(pipeline.snapshot().videoFrames > 0, "未写入任何自建样本，无法验证保留风险")
    var failedInsteadOfCompleting = false
    do { _ = try await pipeline.finish(atHostTime: CMTime(seconds: 102, preferredTimescale: 48_000)) }
    catch { failedInsteadOfCompleting = error.localizedDescription.contains("尾帧") }
    try recordingExpect(readinessChecks == 1 && failedInsteadOfCompleting, "尾帧背压未确定触发或不完整录制被报告为成功")
    try recordingExpect(FileManager.default.fileExists(atPath: plan.partialURL.path), "尾帧背压删除了已有媒体")
    try recordingExpect(!FileManager.default.fileExists(atPath: output.path), "尾帧不完整仍提交了最终成品")
    let asset = AVURLAsset(url: plan.partialURL)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    let duration = try await asset.load(.duration)
    try recordingExpect(tracks.count == 1 && duration.isNumeric && duration.seconds > 0 && duration.seconds < 1,
        "保留文件不是已有样本的真实短时长视频")
    let generator = AVAssetImageGenerator(asset: asset)
    let decoded = try generator.copyCGImage(at: .zero, actualTime: nil)
    try recordingExpect(decoded.width == 128 && decoded.height == 96, "保留的媒体样本无法真实解码")
    let decoder = JSONDecoder(); decoder.dateDecodingStrategy = .iso8601
    let journal = try decoder.decode(ScreenshotRecordingRecoveryRecord.self, from: Data(contentsOf: plan.journalURL))
    try recordingExpect(journal.state == .failed && journal.failure?.contains("尾帧") == true,
        "恢复说明未保留实际失败原因")
    try recordingExpect(abs(journal.metrics.durationSeconds - duration.seconds) < 0.04,
        "恢复说明伪报了未写入尾帧的时长")
    let recovery = try await ScreenshotRecordingRecovery.inspect(journal: plan.journalURL)
    try recordingExpect(recovery.canRecover && recovery.videoTracks == 1, "背压保留文件不能被现有恢复流程读取")
    print("RecordingFinalizationRetentionTests PASS: forced tail backpressure returned failure; generated H.264 partial exists, first frame decoded128x96, actual duration \(duration.seconds)s, failure journal recoverable; no capture/playback")
}

/// Uses only generated pixels and generated PCM. Does not enumerate screens, capture the desktop, or open audio devices.
func ScreenshotRunRecordingTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-Screenshot-RecordingTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    var machine = ScreenshotRecordingStateMachine()
    try machine.transition(to: .preparing); try machine.transition(to: .recording)
    try machine.transition(to: .paused); try machine.transition(to: .recording)
    try machine.transition(to: .stopping); try machine.transition(to: .idle)
    var rejected = false
    do { try machine.transition(to: .recording) } catch { rejected = true }
    try recordingExpect(rejected, "状态机接受了无准备的录制")

    var timeline = ScreenshotRecordingTimeline()
    try recordingExpect(timeline.adjusted(CMTime(seconds: 100, preferredTimescale: 48_000), canStart: false) == nil,
        "视频锚点前的音频不应建立第二条时间线")
    let first = timeline.adjusted(CMTime(seconds: 100, preferredTimescale: 48_000), canStart: true)
    try recordingExpect(first == .zero, "首帧时间必须为零")
    timeline.pause(at: CMTime(seconds: 101, preferredTimescale: 48_000))
    try recordingExpect(timeline.adjusted(CMTime(seconds: 102, preferredTimescale: 48_000), canStart: true) == nil, "暂停样本仍写入")
    timeline.resume(at: CMTime(seconds: 104, preferredTimescale: 48_000))
    let resumed = timeline.adjusted(CMTime(seconds: 104, preferredTimescale: 48_000), canStart: true)
    try recordingExpect(abs((resumed?.seconds ?? -1) - 1) < 0.0001, "暂停三秒未从时长中扣除")
    timeline.pause(at: CMTime(seconds: 105, preferredTimescale: 48_000))
    timeline.resume(at: CMTime(seconds: 107, preferredTimescale: 48_000))
    try recordingExpect(abs((timeline.adjusted(CMTime(seconds: 107, preferredTimescale: 48_000), canStart: true)?.seconds ?? -1) - 2) < 0.0001,
        "多次暂停产生漂移")

    let output = directory.appendingPathComponent("generated.mov")
    let configuration = ScreenshotRecordingConfiguration(mode: .video,
        source: ScreenshotRecordingSource(kind: .display, displayID: 42, name: "纯生成测试源"), outputURL: output,
        systemAudio: true, microphone: true, frameRate: 30, maximumPixelDimension: 128)
    try configuration.validate()
    let plan = try ScreenshotRecordingFilePlan(outputURL: output)
    let pipeline = try ScreenshotRecordingPipeline(configuration: configuration, plan: plan, width: 128, height: 96)
    pipeline.onFailure = { print("RecordingTests writer failure: \($0 as NSError)") }
    for index in 0..<60 {
        if index == 30 {
            pipeline.setPaused(true, hostTime: CMTime(seconds: 101, preferredTimescale: 48_000))
            let pausedFrame = try generatedRecordingVideoFrame(index: 90, pts: CMTime(seconds: 102, preferredTimescale: 48_000))
            pipeline.queue.sync { pipeline.append(pausedFrame, track: .video) }
            pipeline.setPaused(false, hostTime: CMTime(seconds: 104, preferredTimescale: 48_000))
        }
        let seconds = 100 + Double(index) / 30 + (index >= 30 ? 3 : 0)
        let pts = CMTime(seconds: seconds, preferredTimescale: 48_000)
        let frame = try generatedRecordingVideoFrame(index: index, pts: pts)
        let system = try generatedRecordingAudio(frequency: 440, channels: 2, pts: pts, sampleOffset: index * 1600)
        let mic = try generatedRecordingAudio(frequency: 880, channels: 1, pts: pts, sampleOffset: index * 1600)
        pipeline.queue.sync {
            pipeline.append(frame, track: .video)
            pipeline.append(system, track: .systemAudio)
            pipeline.append(mic, track: .microphone)
        }
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    let metrics = try await pipeline.finish()
    try recordingExpect(metrics.videoFrames == 60 && metrics.droppedVideoFrames == 0, "生成视频样本未完整写入：\(metrics.videoFrames) 帧 / \(metrics.droppedVideoFrames) 丢帧")
    try recordingExpect(metrics.systemAudioBuffers == 60 && metrics.microphoneBuffers == 60, "两条音轨样本数量不一致")
    try recordingExpect(abs(metrics.durationSeconds - 2) < 0.001, "录制暂停修正后时长错误")
    try plan.commit()
    let asset = AVURLAsset(url: output)
    let videoTracks = try await asset.loadTracks(withMediaType: .video)
    let audioTracks = try await asset.loadTracks(withMediaType: .audio)
    let duration = try await asset.load(.duration)
    try recordingExpect(videoTracks.count == 1 && audioTracks.count == 2, "实际文件没有一条视频与两条独立音轨")
    try recordingExpect(abs(duration.seconds - 2) < 0.06, "实际媒体容器时长包含暂停或负时长：\(duration.seconds)")
    for track in videoTracks + audioTracks {
        let range = try await track.load(.timeRange)
        try recordingExpect(range.start.seconds >= -0.001 && abs(range.duration.seconds - 2) < 0.08, "轨道时间轴未同步")
    }
    try await verifyGeneratedVideo(asset)
    let energies = try await audioTracks.asyncMap { track in try await recordingAudioEnergy(asset: asset, track: track) }
    try recordingExpect(energies.allSatisfy({ $0 > 0.001 }), "生成音轨无可解码非静音样本")

    let audioOnlyURL = directory.appendingPathComponent("audio-only.mov")
    let audioConfig = ScreenshotRecordingConfiguration(mode: .audioOnly,
        source: ScreenshotRecordingSource(kind: .display, displayID: 42, name: "纯生成音源"), outputURL: audioOnlyURL,
        systemAudio: true, microphone: true)
    let audioPlan = try ScreenshotRecordingFilePlan(outputURL: audioOnlyURL)
    let audioPipeline = try ScreenshotRecordingPipeline(configuration: audioConfig, plan: audioPlan, width: 2, height: 2)
    for index in 0..<30 {
        let pts = CMTime(seconds: 100 + Double(index) / 30, preferredTimescale: 48_000)
        let system = try generatedRecordingAudio(frequency: 440, channels: 2, pts: pts, sampleOffset: index * 1600)
        let mic = try generatedRecordingAudio(frequency: 880, channels: 1, pts: pts, sampleOffset: index * 1600)
        audioPipeline.queue.sync { audioPipeline.append(system, track: .systemAudio); audioPipeline.append(mic, track: .microphone) }
        try await Task.sleep(nanoseconds: 4_000_000)
    }
    _ = try await audioPipeline.finish(); try audioPlan.commit()
    let audioAsset = AVURLAsset(url: audioOnlyURL)
    let audioOnlyVideo = try await audioAsset.loadTracks(withMediaType: .video)
    let audioOnlyTracks = try await audioAsset.loadTracks(withMediaType: .audio)
    try recordingExpect(audioOnlyVideo.isEmpty && audioOnlyTracks.count == 2, "仅录音生成了屏幕视频轨")
    let m4a = directory.appendingPathComponent("mixed.m4a")
    try await ScreenshotRecordingAudioExporter.exportM4A(input: audioOnlyURL, output: m4a)
    let mixed = AVURLAsset(url: m4a)
    let mixedTracks = try await mixed.loadTracks(withMediaType: .audio)
    let mixedVideos = try await mixed.loadTracks(withMediaType: .video)
    try recordingExpect(mixedTracks.count == 1 && mixedVideos.isEmpty, "M4A 导出未正确混音为仅一条音频")
    let mixedEnergy = try await recordingAudioEnergy(asset: mixed, track: mixedTracks[0])
    try recordingExpect(mixedEnergy > 0.001, "M4A 混音解码后静音")

    let gifURL = directory.appendingPathComponent("generated.gif")
    let options = ScreenshotGIFOptions(startSeconds: 0.25, durationSeconds: 1, framesPerSecond: 10,
        maximumWidth: 64, maximumHeight: 64, crop: CGRect(x: 0, y: 0, width: 0.75, height: 1), saturation: 0.8)
    let gif = try await ScreenshotGIFExporter.convert(input: output, output: gifURL, options: options)
    try recordingExpect(gif.frameCount == 10 && gif.pixelWidth == 64 && gif.pixelHeight == 64 && gif.byteCount > 100,
        "GIF 裁剪/缩放/帧数或容量核对失败")
    guard let source = CGImageSourceCreateWithURL(gifURL as CFURL, nil) else { throw RecordingTestFailure(message: "GIF 不能重新打开") }
    var gifDuration = 0.0
    for index in 0..<CGImageSourceGetCount(source) {
        let properties = CGImageSourceCopyPropertiesAtIndex(source, index, nil) as? [CFString: Any]
        let dictionary = properties?[kCGImagePropertyGIFDictionary] as? [CFString: Any]
        gifDuration += dictionary?[kCGImagePropertyGIFUnclampedDelayTime] as? Double ?? dictionary?[kCGImagePropertyGIFDelayTime] as? Double ?? 0
    }
    try recordingExpect(abs(gifDuration - 1) < 0.03, "GIF 真实帧延时与时段不一致")
    let token = ScreenshotGIFCancellationToken()
    let cancelledURL = directory.appendingPathComponent("cancelled.gif")
    var cancellationWasReported = false
    do {
        _ = try await ScreenshotGIFExporter.convert(input: output, output: cancelledURL, options: options, cancellation: token,
            progress: { completed, _ in if completed == 2 { token.cancel() } })
    } catch ScreenshotRecordingError.cancelled { cancellationWasReported = true }
    try recordingExpect(cancellationWasReported && !FileManager.default.fileExists(atPath: cancelledURL.path), "GIF 中途取消仍提交成品")
    var overwriteRejected = false
    do { _ = try ScreenshotRecordingFilePlan(outputURL: output) } catch { overwriteRejected = true }
    try recordingExpect(overwriteRejected, "录制覆盖了已存在视频")
    let failurePlan = try ScreenshotRecordingFilePlan(outputURL: directory.appendingPathComponent("empty.mov"))
    let failureConfiguration = ScreenshotRecordingConfiguration(mode: .video, source: configuration.source,
        outputURL: failurePlan.finalURL, systemAudio: false, microphone: false)
    let empty = try ScreenshotRecordingPipeline(configuration: failureConfiguration, plan: failurePlan, width: 128, height: 96)
    var emptyRejected = false
    do { _ = try await empty.finish() } catch ScreenshotRecordingError.noSamples { emptyRejected = true }
    try recordingExpect(emptyRejected && FileManager.default.fileExists(atPath: failurePlan.journalURL.path), "空录制未保存真实失败恢复状态")
    let stillURL = directory.appendingPathComponent("still.mov")
    let stillPlan = try ScreenshotRecordingFilePlan(outputURL: stillURL)
    let stillConfig = ScreenshotRecordingConfiguration(mode: .video, source: configuration.source, outputURL: stillURL, systemAudio: false)
    let still = try ScreenshotRecordingPipeline(configuration: stillConfig, plan: stillPlan, width: 128, height: 96)
    let stillFrame = try generatedRecordingVideoFrame(index: 1, pts: CMTime(seconds: 100, preferredTimescale: 48_000))
    still.queue.sync { still.append(stillFrame, track: .video) }
    try await Task.sleep(nanoseconds: 50_000_000)
    let stillMetrics = try await still.finish(atHostTime: CMTime(seconds: 102, preferredTimescale: 48_000))
    try recordingExpect(stillMetrics.videoFrames == 2 && abs(stillMetrics.durationSeconds - 2) < 0.001, "静止画面未持帧到停止时间")
    let recovered = try await ScreenshotRecordingRecovery.inspect(journal: stillPlan.journalURL)
    try recordingExpect(recovered.canRecover && recovered.videoTracks == 1 && abs((recovered.durationSeconds ?? -1) - 2) < 0.04,
        "正常完成但未提交的中间文件不能恢复")
    let recoveredURL = directory.appendingPathComponent("recovered.mov")
    _ = try await ScreenshotRecordingRecovery.recover(journal: stillPlan.journalURL, to: recoveredURL)
    try recordingExpect(FileManager.default.fileExists(atPath: recoveredURL.path) && FileManager.default.fileExists(atPath: stillPlan.partialURL.path),
        "恢复未生成副本或删除了原中间文件")
    var futureJSON = try JSONSerialization.jsonObject(with: Data(contentsOf: stillPlan.journalURL)) as! [String: Any]
    futureJSON["schemaVersion"] = 2
    let futureURL = directory.appendingPathComponent("future.recovery.json")
    try JSONSerialization.data(withJSONObject: futureJSON).write(to: futureURL)
    var futureRejected = false
    do { _ = try await ScreenshotRecordingRecovery.inspect(journal: futureURL) } catch ScreenshotRecordingError.unsupported { futureRejected = true }
    try recordingExpect(futureRejected, "未来恢复schema被当作空白处理")
    print("RecordingTests PASS: generated 128x96 H.264 60 frames, two AAC tracks, 3-second pause removed, media duration \(duration.seconds)s, audio-only two tracks/no video, mixed M4A decoded, cropped 10-frame GIF/cancel, state/overwrite/no-sample recovery; CPU \(String(format: "%.3f", metrics.processCPUSeconds))s; first sample \(String(format: "%.4f", metrics.firstSampleLatencySeconds ?? -1))s; 0 desktop/microphone capture")
}

private func generatedRecordingVideoFrame(index: Int, pts: CMTime) throws -> CMSampleBuffer {
    var pixel: CVPixelBuffer?
    let status = CVPixelBufferCreate(kCFAllocatorDefault, 128, 96, kCVPixelFormatType_32BGRA,
        [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary, &pixel)
    guard status == kCVReturnSuccess, let pixel else { throw RecordingTestFailure(message: "创建自建像素失败") }
    CVPixelBufferLockBaseAddress(pixel, [])
    if let memory = CVPixelBufferGetBaseAddress(pixel) {
        let bytes = memory.assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRow(pixel)
        for y in 0..<96 { for x in 0..<128 {
            let offset = y * stride + x * 4
            bytes[offset] = UInt8(max(0, 255 - index * 4))
            bytes[offset + 1] = UInt8((x + y) % 128)
            bytes[offset + 2] = UInt8(min(255, index * 4))
            bytes[offset + 3] = 255
        } }
    }
    CVPixelBufferUnlockBaseAddress(pixel, [])
    var format: CMVideoFormatDescription?
    let formatStatus = CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel, formatDescriptionOut: &format)
    guard formatStatus == noErr, let format else { throw RecordingTestFailure(message: "创建自建图像格式失败") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 30), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sample: CMSampleBuffer?
    let result = CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixel,
        formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
    guard result == noErr, let sample else { throw RecordingTestFailure(message: "创建自建视频样本失败") }
    return sample
}

private func generatedRecordingAudio(frequency: Double, channels: Int, pts: CMTime, sampleOffset: Int) throws -> CMSampleBuffer {
    let frames = 1600
    var data = [Float](repeating: 0, count: frames * channels)
    for index in 0..<frames {
        let value = Float(sin(2 * Double.pi * frequency * Double(index + sampleOffset) / 48_000) * 0.3)
        for channel in 0..<channels { data[index * channels + channel] = value }
    }
    var asbd = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: UInt32(channels * 4), mFramesPerPacket: 1,
        mBytesPerFrame: UInt32(channels * 4), mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 32, mReserved: 0)
    var format: CMAudioFormatDescription?
    let formatStatus = CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &asbd,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil, formatDescriptionOut: &format)
    guard formatStatus == noErr, let format else { throw RecordingTestFailure(message: "创建自建PCM格式失败") }
    let length = data.count * MemoryLayout<Float>.size
    var block: CMBlockBuffer?
    let blockStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: length, flags: 0, blockBufferOut: &block)
    guard blockStatus == noErr, let block else { throw RecordingTestFailure(message: "创建PCM数据失败") }
    let copyStatus = data.withUnsafeBytes { bytes in CMBlockBufferReplaceDataBytes(with: bytes.baseAddress!, blockBuffer: block, offsetIntoDestination: 0, dataLength: length) }
    guard copyStatus == noErr else { throw RecordingTestFailure(message: "复制PCM失败") }
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000), presentationTimeStamp: pts, decodeTimeStamp: .invalid)
    var sampleSize = channels * 4
    var sample: CMSampleBuffer?
    let sampleStatus = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block, formatDescription: format,
        sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing, sampleSizeEntryCount: 1,
        sampleSizeArray: &sampleSize, sampleBufferOut: &sample)
    guard sampleStatus == noErr, let sample else { throw RecordingTestFailure(message: "创建自建音频样本失败") }
    return sample
}

private func verifyGeneratedVideo(_ asset: AVAsset) async throws {
    let generator = AVAssetImageGenerator(asset: asset)
    let first = try generator.copyCGImage(at: CMTime(seconds: 0.1, preferredTimescale: 600), actualTime: nil)
    let last = try generator.copyCGImage(at: CMTime(seconds: 1.8, preferredTimescale: 600), actualTime: nil)
    func red(_ image: CGImage) -> UInt8 {
        var pixel = [UInt8](repeating: 0, count: 4)
        pixel.withUnsafeMutableBytes { memory in
            if let context = CGContext(data: memory.baseAddress, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) {
                context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            }
        }
        return pixel[0]
    }
    try recordingExpect(first.width == 128 && first.height == 96 && last.width == 128 && red(last) > red(first) + 80,
        "生成视频不能解码或首尾画面无预期变化")
}

private func recordingAudioEnergy(asset: AVAsset, track: AVAssetTrack) async throws -> Double {
    let reader = try AVAssetReader(asset: asset)
    let output = AVAssetReaderTrackOutput(track: track, outputSettings: [AVFormatIDKey: kAudioFormatLinearPCM,
        AVLinearPCMIsFloatKey: true, AVLinearPCMBitDepthKey: 32, AVLinearPCMIsNonInterleaved: false])
    reader.add(output)
    guard reader.startReading() else { throw reader.error ?? RecordingTestFailure(message: "音频解码器无法启动") }
    var energy = 0.0, count = 0
    while let buffer = output.copyNextSampleBuffer() {
        guard let block = CMSampleBufferGetDataBuffer(buffer) else { continue }
        let length = CMBlockBufferGetDataLength(block)
        var bytes = [UInt8](repeating: 0, count: length)
        let status = bytes.withUnsafeMutableBytes { CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: $0.baseAddress!) }
        guard status == noErr else { throw RecordingTestFailure(message: "无法读取解码音频") }
        bytes.withUnsafeBytes { raw in
            for value in raw.bindMemory(to: Float.self) { energy += Double(value * value); count += 1 }
        }
    }
    guard reader.status == .completed else { throw reader.error ?? RecordingTestFailure(message: "音频解码中断") }
    return count > 0 ? energy / Double(count) : 0
}

private extension Array {
    func asyncMap<T>(_ transform: (Element) async throws -> T) async rethrows -> [T] {
        var results: [T] = []
        for item in self { results.append(try await transform(item)) }
        return results
    }
}
