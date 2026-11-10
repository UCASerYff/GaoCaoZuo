import Foundation
import AVFoundation
import ImageIO
import UniformTypeIdentifiers
import CoreImage

struct ScreenshotGIFOptions {
    var startSeconds: Double = 0
    var durationSeconds: Double = 5
    var framesPerSecond: Int = 10
    var maximumWidth: Int = 640
    var maximumHeight: Int = 640
    /// Optional crop, normalized to the decoded, orientation-correct frame, with top-left origin.
    var crop: CGRect?
    var saturation: Double = 1
    var contrast: Double = 1
    var brightness: Double = 0
    var loopsForever = true

    func validate() throws {
        guard startSeconds.isFinite, durationSeconds.isFinite, startSeconds >= 0, durationSeconds > 0, durationSeconds <= 120,
              (1...30).contains(framesPerSecond), (16...1920).contains(maximumWidth), (16...1920).contains(maximumHeight),
              (0...2).contains(saturation), (0.5...2).contains(contrast), (-0.5...0.5).contains(brightness) else {
            throw ScreenshotRecordingError.invalidConfiguration("GIF 需 0–120 秒片段、1–30 fps、16–1920 像素；调色参数超出范围")
        }
        if let crop {
            guard !crop.isNull, !crop.isInfinite,
                  [crop.minX, crop.minY, crop.width, crop.height].allSatisfy({ $0.isFinite }),
                  CGRect(x: 0, y: 0, width: 1, height: 1).contains(crop), crop.width > 0, crop.height > 0 else {
                throw ScreenshotRecordingError.invalidConfiguration("GIF 裁剪区域无效")
            }
        }
        let pixels = Double(maximumWidth) * Double(maximumHeight) * Double(frameCount)
        guard frameCount <= 3000, pixels <= 240_000_000 else {
            throw ScreenshotRecordingError.invalidConfiguration("GIF 超出 2.4 亿帧像素预算，请缩短时段、降低帧率或尺寸")
        }
    }
    var frameCount: Int {
        // UI estimates are evaluated while fields are being edited, before validate().
        // Bound floating-point values before any conversion to Int; NaN/infinity and overflow must not trap.
        guard durationSeconds.isFinite, durationSeconds > 0, durationSeconds <= 120,
              (1...30).contains(framesPerSecond) else { return 0 }
        return Int(ceil(durationSeconds * Double(framesPerSecond)))
    }
    var estimate: ScreenshotGIFCapacityEstimate {
        do { try validate() }
        catch {
            return ScreenshotGIFCapacityEstimate(frameCount: 0, estimatedMinimumBytes: 0, estimatedMaximumBytes: 0,
                note: "当前 GIF 参数无效：\(error.localizedDescription)")
        }
        let indexed = Int64(maximumWidth) * Int64(maximumHeight) * Int64(frameCount)
        return ScreenshotGIFCapacityEstimate(frameCount: frameCount, estimatedMinimumBytes: max(1024, indexed / 10),
            estimatedMaximumBytes: indexed + Int64(frameCount) * 1024,
            note: "按尺寸上限估算 8 位索引帧；画面运动、实际宽高和 ImageIO 调色板会改变压缩率，最终以文件大小为准。GIF 不含音频且最多 256 色。")
    }
}

struct ScreenshotGIFCapacityEstimate {
    var frameCount: Int
    var estimatedMinimumBytes: Int64
    var estimatedMaximumBytes: Int64
    var note: String
}

final class ScreenshotGIFCancellationToken: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func cancel() { lock.lock(); value = true; lock.unlock() }
    var isCancelled: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

struct ScreenshotGIFExportResult {
    var url: URL
    var frameCount: Int
    var pixelWidth: Int
    var pixelHeight: Int
    var durationSeconds: Double
    var byteCount: Int64
}

enum ScreenshotGIFExporter {
    /// Bounded frame-by-frame decoding, with original video left untouched. Progress counts completed real frames.
    static func convert(input: URL, output: URL, options: ScreenshotGIFOptions,
                        cancellation: ScreenshotGIFCancellationToken = ScreenshotGIFCancellationToken(),
                        progress: @escaping @Sendable (Int, Int) -> Void = { _, _ in }) async throws -> ScreenshotGIFExportResult {
        try options.validate()
        guard output.isFileURL, output.pathExtension.lowercased() == "gif", input.standardizedFileURL != output.standardizedFileURL,
              !FileManager.default.fileExists(atPath: output.path) else { throw ScreenshotRecordingError.writing("GIF 输出无效或文件已存在") }
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        guard !tracks.isEmpty, duration.isNumeric, options.startSeconds + options.durationSeconds <= duration.seconds + 0.001 else {
            throw ScreenshotRecordingError.invalidConfiguration("视频无有效画面或裁剪时段超出视频时长")
        }
        return try await withTaskCancellationHandler {
            try await Task.detached(priority: .userInitiated) {
                try encode(asset: asset, output: output, options: options, cancellation: cancellation, progress: progress)
            }.value
        } onCancel: { cancellation.cancel() }
    }

    private static func encode(asset: AVURLAsset, output: URL, options: ScreenshotGIFOptions,
                               cancellation: ScreenshotGIFCancellationToken, progress: @escaping @Sendable (Int, Int) -> Void) throws -> ScreenshotGIFExportResult {
        let temporary = output.deletingLastPathComponent().appendingPathComponent(".gao-gif-\(UUID().uuidString).partial.gif")
        defer { try? FileManager.default.removeItem(at: temporary) }
        guard let destination = CGImageDestinationCreateWithURL(temporary as CFURL, UTType.gif.identifier as CFString,
            options.frameCount, nil) else { throw ScreenshotRecordingError.writing("无法创建 GIF 输出") }
        CGImageDestinationSetProperties(destination, [kCGImagePropertyGIFDictionary:
            [kCGImagePropertyGIFLoopCount: options.loopsForever ? 0 : 1]] as CFDictionary)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: min(3840, options.maximumWidth * 2), height: min(3840, options.maximumHeight * 2))
        generator.requestedTimeToleranceBefore = .zero
        generator.requestedTimeToleranceAfter = .zero
        let context = CIContext(options: [.cacheIntermediates: false])
        var resultSize = CGSize.zero
        for index in 0..<options.frameCount {
            if cancellation.isCancelled { generator.cancelAllCGImageGeneration(); throw ScreenshotRecordingError.cancelled }
            try autoreleasepool {
                let seconds = options.startSeconds + Double(index) / Double(options.framesPerSecond)
                let frame = try generator.copyCGImage(at: CMTime(seconds: seconds, preferredTimescale: 60_000), actualTime: nil)
                var cropped = frame
                if let crop = options.crop {
                    let rect = CGRect(x: crop.minX * Double(frame.width), y: crop.minY * Double(frame.height),
                        width: crop.width * Double(frame.width), height: crop.height * Double(frame.height)).integral
                    guard let image = frame.cropping(to: rect) else { throw ScreenshotRecordingError.writing("GIF 裁剪失败") }
                    cropped = image
                }
                var image = CIImage(cgImage: cropped)
                if options.saturation != 1 || options.contrast != 1 || options.brightness != 0 {
                    image = image.applyingFilter("CIColorControls", parameters: [kCIInputSaturationKey: options.saturation,
                        kCIInputContrastKey: options.contrast, kCIInputBrightnessKey: options.brightness])
                }
                let scale = min(1, Double(options.maximumWidth) / image.extent.width, Double(options.maximumHeight) / image.extent.height)
                image = image.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let bounds = CGRect(x: 0, y: 0, width: max(1, floor(image.extent.width)), height: max(1, floor(image.extent.height)))
                guard let rendered = context.createCGImage(image, from: bounds, format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)) else {
                    throw ScreenshotRecordingError.writing("GIF 帧调色或缩放失败")
                }
                resultSize = CGSize(width: rendered.width, height: rendered.height)
                let delay = min(1 / Double(options.framesPerSecond), options.durationSeconds - Double(index) / Double(options.framesPerSecond))
                CGImageDestinationAddImage(destination, rendered, [kCGImagePropertyGIFDictionary:
                    [kCGImagePropertyGIFDelayTime: delay, kCGImagePropertyGIFUnclampedDelayTime: delay]] as CFDictionary)
            }
            progress(index + 1, options.frameCount)
        }
        if cancellation.isCancelled { throw ScreenshotRecordingError.cancelled }
        guard CGImageDestinationFinalize(destination) else { throw ScreenshotRecordingError.writing("GIF 完成写入失败（可能磁盘空间不足）") }
        guard let source = CGImageSourceCreateWithURL(temporary as CFURL, nil),
              CGImageSourceGetCount(source) == options.frameCount,
              CGImageSourceCreateImageAtIndex(source, 0, nil) != nil,
              CGImageSourceCreateImageAtIndex(source, options.frameCount - 1, nil) != nil else {
            throw ScreenshotRecordingError.writing("GIF 重新读取校验失败")
        }
        if cancellation.isCancelled { throw ScreenshotRecordingError.cancelled }
        try FileManager.default.moveItem(at: temporary, to: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
        let bytes = (try FileManager.default.attributesOfItem(atPath: output.path)[.size] as? NSNumber)?.int64Value ?? 0
        return ScreenshotGIFExportResult(url: output, frameCount: options.frameCount, pixelWidth: Int(resultSize.width),
            pixelHeight: Int(resultSize.height), durationSeconds: options.durationSeconds, byteCount: bytes)
    }
}

enum ScreenshotRecordingAudioExporter {
    enum Selection { case track(Int), mixAll }
    /// Extract a selected independent track or explicitly mix all audio tracks into a new M4A.
    static func exportM4A(input: URL, output: URL, selection: Selection = .mixAll) async throws {
        guard output.pathExtension.lowercased() == "m4a", !FileManager.default.fileExists(atPath: output.path) else {
            throw ScreenshotRecordingError.writing("M4A 文件已存在或输出扩展名不正确")
        }
        let asset = AVURLAsset(url: input)
        let duration = try await asset.load(.duration)
        let original = try await asset.loadTracks(withMediaType: .audio)
        let selected: [AVAssetTrack]
        switch selection {
        case .track(let index):
            guard original.indices.contains(index) else { throw ScreenshotRecordingError.invalidConfiguration("所选音轨不存在") }
            selected = [original[index]]
        case .mixAll: selected = original
        }
        guard !selected.isEmpty else { throw ScreenshotRecordingError.noSamples }
        let composition = AVMutableComposition()
        let mix = AVMutableAudioMix()
        var mixParameters: [AVMutableAudioMixInputParameters] = []
        for track in selected {
            guard let destination = composition.addMutableTrack(withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid) else {
                throw ScreenshotRecordingError.writing("无法创建音轨导出")
            }
            let range = try await track.load(.timeRange)
            try destination.insertTimeRange(range, of: track, at: range.start)
            let parameters = AVMutableAudioMixInputParameters(track: destination)
            // Equal gain avoids clipping when the user explicitly selects the combined export.
            parameters.setVolume(1 / Float(selected.count), at: .zero)
            mixParameters.append(parameters)
        }
        mix.inputParameters = mixParameters
        let temp = output.deletingLastPathComponent().appendingPathComponent(".gao-audio-\(UUID().uuidString).partial.m4a")
        defer { try? FileManager.default.removeItem(at: temp) }
        guard let export = AVAssetExportSession(asset: composition, presetName: AVAssetExportPresetAppleM4A) else {
            throw ScreenshotRecordingError.writing("此系统无法创建 M4A 导出器")
        }
        export.audioMix = mix
        export.timeRange = CMTimeRange(start: .zero, duration: duration)
        export.outputURL = temp; export.outputFileType = .m4a
        let sessionBox = ScreenshotRecordingExportSessionBox(export)
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                sessionBox.session.exportAsynchronously {
                    if sessionBox.session.status == .completed { continuation.resume() }
                    else { continuation.resume(throwing: sessionBox.session.error ?? ScreenshotRecordingError.writing("音频导出失败或取消")) }
                }
            }
        } onCancel: { sessionBox.session.cancelExport() }
        try Task.checkCancellation()
        let decoded = AVURLAsset(url: temp)
        let tracks = try await decoded.loadTracks(withMediaType: .audio)
        guard tracks.count == 1, try await decoded.loadTracks(withMediaType: .video).isEmpty else {
            throw ScreenshotRecordingError.writing("音频导出轨道核对失败")
        }
        try FileManager.default.moveItem(at: temp, to: output)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: output.path)
    }
}

/// AVAssetExportSession supports cancelExport concurrently with its asynchronous export.
private final class ScreenshotRecordingExportSessionBox: @unchecked Sendable {
    let session: AVAssetExportSession
    init(_ session: AVAssetExportSession) { self.session = session }
}
