// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import Foundation
import AVFoundation

private struct AudioRecoveryTestFailure: LocalizedError {
    let errorDescription: String?
}
private func recoveryExpect(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try condition() == false { throw AudioRecoveryTestFailure(errorDescription: message) }
}

/// Generated AAC and locally damaged/empty ISO media only. No sound device or playback APIs.
func ScreenshotRunRecordingAudioRecoveryTests() async throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-Screenshot-AudioRecovery-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
        attributes: [.posixPermissions: 0o700])
    defer { try? FileManager.default.removeItem(at: directory) }
    let valid = try recoveryPlan(directory: directory, name: "generated-valid")
    try await writeRecoveryAAC(to: valid.partialURL)
    let original = try Data(contentsOf: valid.partialURL)
    let journal = try Data(contentsOf: valid.journalURL)
    let inspection = try await ScreenshotRecordingRecovery.inspect(journal: valid.journalURL)
    try recoveryExpect(inspection.canRecover && inspection.audioTracks == 1 && inspection.videoTracks == 0 &&
        inspection.reason.contains("PCM"), "有效自建 AAC 未经实际非空 PCM 解码通过恢复检查")
    let recovered = directory.appendingPathComponent("recovered.m4a")
    _ = try await ScreenshotRecordingRecovery.recover(journal: valid.journalURL, to: recovered)
    try recoveryExpect(try Data(contentsOf: recovered) == original, "有效恢复副本与原媒体不一致")
    try recoveryExpect(try Data(contentsOf: valid.partialURL) == original && Data(contentsOf: valid.journalURL) == journal,
        "检查或另存恢复修改了有效原件或 journal")

    // Keep metadata and encoded packet indexing intact, but make every AAC packet invalid.
    // A pass-through reader must still see packets; it is insufficient evidence of decoding.
    let damaged = try recoveryPlan(directory: directory, name: "generated-damaged")
    var badBytes = original
    let boxes = try recoveryBoxes(original)
    guard let mdat = boxes.first(where: { $0.type == "mdat" }) else { throw AudioRecoveryTestFailure(errorDescription: "生成媒体缺少 mdat") }
    badBytes.replaceSubrange(mdat.payload..<mdat.end, with: repeatElement(UInt8(0xff), count: mdat.end - mdat.payload))
    try badBytes.write(to: damaged.partialURL)
    let damagedAsset = AVURLAsset(url: damaged.partialURL)
    let damagedTracks = try await damagedAsset.loadTracks(withMediaType: .audio)
    try recoveryExpect(damagedTracks.count == 1, "损坏样本没有保留真实音轨和索引")
    let reader = try AVAssetReader(asset: damagedAsset)
    let encoded = AVAssetReaderTrackOutput(track: damagedTracks[0], outputSettings: nil)
    reader.add(encoded)
    try recoveryExpect(reader.startReading(), "损坏样本不能检验编码包直通与实际解码的差异")
    var encodedFrames = 0
    while let buffer = encoded.copyNextSampleBuffer() { encodedFrames += CMSampleBufferGetNumSamples(buffer) }
    reader.cancelReading()
    try recoveryExpect(encodedFrames > 0, "损坏样本没有编码包，无法验证旧直通检查的误判")
    try await expectUnrecoverable(plan: damaged, bytes: badBytes, name: "AAC 包损坏但容器/音轨仍可读")

    // A structurally readable audio track with positive duration but no indexed samples.
    let empty = try recoveryPlan(directory: directory, name: "generated-empty")
    var emptyBytes = original
    let zeroCounts = boxes.filter { ["stts", "stsc", "stsz", "stco", "co64"].contains($0.type) }
    try recoveryExpect(!zeroCounts.isEmpty, "生成媒体缺少音频样本索引")
    for box in zeroCounts {
        let countOffset = box.payload + (box.type == "stsz" ? 8 : 4)
        try recoveryExpect(countOffset + 4 <= box.end, "样本表越界")
        emptyBytes.replaceSubrange(countOffset..<(countOffset + 4), with: [0, 0, 0, 0])
    }
    try emptyBytes.write(to: empty.partialURL)
    let emptyTracks = try await AVURLAsset(url: empty.partialURL).loadTracks(withMediaType: .audio)
    try recoveryExpect(emptyTracks.count == 1, "空样本测试未保留音频轨")
    try await expectUnrecoverable(plan: empty, bytes: emptyBytes, name: "有音轨但无音频帧")
    print("RecordingAudioRecoveryTests PASS: generated AAC decoded to PCM and copied intact; indexed corrupted AAC and empty audio track rejected, originals/journals kept; no capture/playback")
}

private func recoveryPlan(directory: URL, name: String) throws -> ScreenshotRecordingFilePlan {
    let plan = try ScreenshotRecordingFilePlan(outputURL: directory.appendingPathComponent(name + ".m4a"))
    let now = Date()
    try plan.writeJournal(ScreenshotRecordingRecoveryRecord(sessionID: plan.id, createdAt: now, updatedAt: now,
        state: .failed, mode: .audioOnly, sourceDescription: "自建 PCM 编码的测试音频，非收音",
        partialFileName: plan.partialURL.lastPathComponent, requestedFileName: plan.finalURL.lastPathComponent,
        systemAudio: false, microphone: true, metrics: ScreenshotRecordingMetrics(), failure: "隔离恢复测试"))
    return plan
}

private func expectUnrecoverable(plan: ScreenshotRecordingFilePlan, bytes: Data, name: String) async throws {
    let journal = try Data(contentsOf: plan.journalURL)
    let result = try await ScreenshotRecordingRecovery.inspect(journal: plan.journalURL)
    try recoveryExpect(!result.canRecover, "\(name) 被误称为已解码可恢复")
    var rejected = false
    do { _ = try await ScreenshotRecordingRecovery.recover(journal: plan.journalURL, to: plan.finalURL) }
    catch { rejected = true }
    try recoveryExpect(rejected && !FileManager.default.fileExists(atPath: plan.finalURL.path), "\(name) 仍提交了恢复成品")
    try recoveryExpect(try Data(contentsOf: plan.partialURL) == bytes && Data(contentsOf: plan.journalURL) == journal,
        "\(name) 的失败检查修改或删除了原件/journal")
}

private struct RecoveryBox {
    let type: String
    let payload: Int
    let end: Int
}

private func recoveryBoxes(_ data: Data) throws -> [RecoveryBox] {
    var found: [RecoveryBox] = []
    func u32(_ offset: Int) -> Int { data[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) } }
    func visit(_ start: Int, _ end: Int) throws {
        var offset = start
        while offset + 8 <= end {
            let shortSize = u32(offset)
            var header = 8
            let size: Int
            if shortSize == 1 {
                try recoveryExpect(offset + 16 <= end, "测试媒体扩展 atom 越界")
                let wide = data[(offset + 8)..<(offset + 16)].reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
                try recoveryExpect(wide <= UInt64(Int.max), "测试媒体扩展 atom 过大")
                size = Int(wide); header = 16
            } else { size = shortSize == 0 ? end - offset : shortSize }
            try recoveryExpect(size >= header && size <= end - offset, "测试媒体 atom 大小不受支持")
            let type = String(bytes: data[(offset + 4)..<(offset + 8)], encoding: .ascii) ?? ""
            let box = RecoveryBox(type: type, payload: offset + header, end: offset + size)
            found.append(box)
            if ["moov", "trak", "mdia", "minf", "stbl"].contains(type) { try visit(box.payload, box.end) }
            offset += size
        }
    }
    try visit(0, data.count)
    return found
}

private func writeRecoveryAAC(to url: URL) async throws {
    let writer = try AVAssetWriter(outputURL: url, fileType: .m4a)
    let input = AVAssetWriterInput(mediaType: .audio, outputSettings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
        AVSampleRateKey: 48_000, AVNumberOfChannelsKey: 1, AVEncoderBitRateKey: 96_000])
    input.expectsMediaDataInRealTime = false
    try recoveryExpect(writer.canAdd(input), "系统编码服务不能为自建样本创建 AAC 输入（未调用采集或播放）")
    writer.add(input)
    try recoveryExpect(writer.startWriting(), "生成 AAC 编码器无法启动：\(writer.error?.localizedDescription ?? "未知")")
    writer.startSession(atSourceTime: .zero)
    for index in 0..<30 {
        var waits = 0
        while !input.isReadyForMoreMediaData && writer.status == .writing && waits < 2000 {
            try await Task.sleep(nanoseconds: 1_000_000); waits += 1
        }
        try recoveryExpect(input.isReadyForMoreMediaData, "生成 AAC 编码器持续背压：\(writer.error?.localizedDescription ?? "未知")")
        let sample = try recoveryPCM(index: index)
        try recoveryExpect(input.append(sample), "生成 AAC 样本写入失败：\(writer.error?.localizedDescription ?? "未知")")
    }
    input.markAsFinished()
    writer.endSession(atSourceTime: CMTime(seconds: 1, preferredTimescale: 48_000))
    await withCheckedContinuation { continuation in writer.finishWriting { continuation.resume() } }
    try recoveryExpect(writer.status == .completed, "生成 AAC 容器失败：\(writer.error?.localizedDescription ?? "未知")")
}

private func recoveryPCM(index: Int) throws -> CMSampleBuffer {
    let frames = 1600
    let values = (0..<frames).map { Float(sin(2 * Double.pi * 440 * Double(index * frames + $0) / 48_000) * 0.2) }
    var format = AudioStreamBasicDescription(mSampleRate: 48_000, mFormatID: kAudioFormatLinearPCM,
        mFormatFlags: kAudioFormatFlagsNativeFloatPacked, mBytesPerPacket: 4, mFramesPerPacket: 1,
        mBytesPerFrame: 4, mChannelsPerFrame: 1, mBitsPerChannel: 32, mReserved: 0)
    var description: CMAudioFormatDescription?
    try recoveryExpect(CMAudioFormatDescriptionCreate(allocator: kCFAllocatorDefault, asbd: &format,
        layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil, extensions: nil,
        formatDescriptionOut: &description) == noErr, "创建测试 PCM 格式失败")
    var block: CMBlockBuffer?
    let length = frames * 4
    try recoveryExpect(CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
        blockLength: length, blockAllocator: kCFAllocatorDefault, customBlockSource: nil, offsetToData: 0,
        dataLength: length, flags: 0, blockBufferOut: &block) == noErr, "创建测试 PCM 数据失败")
    guard let block, let description else { throw AudioRecoveryTestFailure(errorDescription: "测试 PCM 缺少格式或数据") }
    let copied = values.withUnsafeBytes { CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
        offsetIntoDestination: 0, dataLength: length) }
    try recoveryExpect(copied == noErr, "填充测试 PCM 失败")
    var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 48_000),
        presentationTimeStamp: CMTime(value: Int64(index * frames), timescale: 48_000), decodeTimeStamp: .invalid)
    var size = 4
    var sample: CMSampleBuffer?
    try recoveryExpect(CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
        formatDescription: description, sampleCount: frames, sampleTimingEntryCount: 1, sampleTimingArray: &timing,
        sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample) == noErr, "创建测试 PCM 样本失败")
    guard let sample else { throw AudioRecoveryTestFailure(errorDescription: "测试 PCM 样本缺失") }
    return sample
}
