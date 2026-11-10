// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import AppKit
import ImageIO

private func captureAssert(_ condition: @autoclosure () throws -> Bool, _ message: String) throws {
    if try !condition() { throw NSError(domain: "CaptureTests", code: 1, userInfo: [NSLocalizedDescriptionKey: message]) }
}

private func captureSyntheticImage(width: Int, height: Int, rowOffset: Int = 0, periodic: Bool = false) throws -> CGImage {
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    for y in 0..<height {
        for x in 0..<width {
            let row = periodic ? (y + rowOffset) % 16 : y + rowOffset
            var random = UInt64(row + 1) &* 0x9E3779B97F4A7C15 &+ UInt64(x + 1) &* 0xBF58476D1CE4E5B9
            random = (random ^ (random >> 30)) &* 0xBF58476D1CE4E5B9
            random = (random ^ (random >> 27)) &* 0x94D049BB133111EB
            random ^= random >> 31
            let offset = (y * width + x) * 4
            bytes[offset] = UInt8(truncatingIfNeeded: random)
            bytes[offset + 1] = UInt8(truncatingIfNeeded: random >> 8)
            bytes[offset + 2] = UInt8(truncatingIfNeeded: random >> 16)
            bytes[offset + 3] = 255
        }
    }
    guard let provider = CGDataProvider(data: Data(bytes) as CFData),
          let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4, space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue), provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent) else { throw ScreenshotCaptureFailure.emptyImage }
    return image
}

@MainActor
func ScreenshotRunCaptureTests() throws {
    let appKit = CGRect(x: -300, y: 800, width: 200, height: 100)
    let desktop = ScreenshotCaptureGeometry.appKitToDesktop(appKit, mainDisplayTop: 1000)
    try captureAssert(desktop == CGRect(x: -300, y: 100, width: 200, height: 100), "跨屏负原点坐标转换")
    try captureAssert(ScreenshotCaptureGeometry.desktopToAppKit(desktop, mainDisplayTop: 1000) == appKit, "桌面坐标往返")
    let pixels = try ScreenshotCaptureGeometry.pixelRect(CGRect(x: 0.25, y: 2.5, width: 11.5, height: 5), scale: 2)
    try captureAssert(pixels == CGRect(x: 0, y: 5, width: 24, height: 10), "Retina点与像素向外取整")
    let oneScale = try ScreenshotCaptureGeometry.pixelRect(CGRect(x: 0, y: 0, width: 11, height: 5), scale: 1)
    try captureAssert(oneScale.width == 11, "1x坐标")
    try captureAssert(ScreenshotCaptureGeometry.rotatePixelPoint(CGPoint(x: 3, y: 5), unrotatedSize: CGSize(width: 100, height: 80), degrees: 90) == CGPoint(x: 75, y: 3), "90度旋转")
    try captureAssert(ScreenshotCaptureGeometry.rotatePixelPoint(CGPoint(x: 3, y: 5), unrotatedSize: CGSize(width: 100, height: 80), degrees: -90) == CGPoint(x: 5, y: 97), "270度旋转")
    do { try ScreenshotCaptureGeometry.validateBudget(width: Int.max, height: Int.max, maximumPixels: 100_000_000, maximumBytes: 512_000_000); throw NSError(domain: "CaptureTests", code: 2) } catch ScreenshotCaptureFailure.budgetExceeded {}
    do { _ = try ScreenshotCaptureGeometry.pixelRect(CGRect(x: 0, y: 0, width: 10, height: 10), scale: .nan); throw NSError(domain: "CaptureTests", code: 3) } catch ScreenshotCaptureFailure.invalidRegion {}

    let full = try captureSyntheticImage(width: 96, height: 224)
    let a = try captureSyntheticImage(width: 96, height: 140)
    let b = try captureSyntheticImage(width: 96, height: 140, rowOffset: 84)
    let estimate = try ScreenshotScrollOverlapMatcher.estimate(previous: a, current: b)
    try captureAssert(estimate.overlapPixels == 56, "应找到真实56像素重叠")
    try captureAssert(estimate.confidence >= 0.88 && !estimate.duplicate, "独特纹理接缝置信度")
    let session = ScreenshotLongScreenshotSession()
    _ = try session.addFrame(a); _ = try session.addFrame(b)
    let stitched = try session.finish()
    try captureAssert(stitched.width == 96 && stitched.height == 224, "拼接尺寸与去重")
    for y in [0, 55, 139, 140, 223] {
        for x in [0, 24, 95] {
            let expected = try ScreenshotCaptureColorSampler.pixel(in: full, at: CGPoint(x: x, y: y))
            let actual = try ScreenshotCaptureColorSampler.pixel(in: stitched, at: CGPoint(x: x, y: y))
            try captureAssert(expected.hex == actual.hex, "拼接实际行位置和方向应保持一致：\(x),\(y)")
        }
    }
    let duplicate = try ScreenshotScrollOverlapMatcher.estimate(previous: a, current: a)
    try captureAssert(duplicate.duplicate, "静止边界帧应判重复")
    let duplicateSession = ScreenshotLongScreenshotSession(); _ = try duplicateSession.addFrame(a); _ = try duplicateSession.addFrame(a)
    try captureAssert(duplicateSession.capturedFrameCount == 1, "重复帧不追加")

    let repeatedA = try captureSyntheticImage(width: 96, height: 140, periodic: true)
    let repeatedB = try captureSyntheticImage(width: 96, height: 140, rowOffset: 6, periodic: true)
    let ambiguous = ScreenshotLongScreenshotSession(); _ = try ambiguous.addFrame(repeatedA); _ = try ambiguous.addFrame(repeatedB)
    try captureAssert(ambiguous.state == .awaitingSeam && ambiguous.pendingSeam != nil, "重复纹理必须停在接缝预览")
    do { _ = try ambiguous.finish(); throw NSError(domain: "CaptureTests", code: 4) } catch ScreenshotCaptureFailure.unsupported {}
    try ambiguous.acceptPending(overlapPixels: 134)
    try captureAssert(ambiguous.outputHeight == 146, "用户手动接缝调整")
    let cancelled = ScreenshotLongScreenshotSession(); _ = try cancelled.addFrame(a); cancelled.cancel()
    do { _ = try cancelled.finish(); throw NSError(domain: "CaptureTests", code: 5) } catch ScreenshotCaptureFailure.cancelled {}
    let guarded = ScreenshotLongScreenshotSession(target: ScreenshotScrollTargetIdentity(processID: 12, windowID: 34))
    try guarded.validateTarget(frontmostPID: 12, activeWindowID: 34)
    do { try guarded.validateTarget(frontmostPID: 56, activeWindowID: 34); throw NSError(domain: "CaptureTests", code: 6) } catch ScreenshotCaptureFailure.unsupported {}
    if case .paused = guarded.state {} else { throw NSError(domain: "CaptureTests", code: 7, userInfo: [NSLocalizedDescriptionKey: "目标改变未暂停"]) }
    var smallBudget = ScreenshotScrollCaptureBudget(); smallBudget.maximumHeight = 180
    let bounded = ScreenshotLongScreenshotSession(budget: smallBudget); _ = try bounded.addFrame(a)
    do { _ = try bounded.addFrame(b); throw NSError(domain: "CaptureTests", code: 8) } catch ScreenshotCaptureFailure.budgetExceeded {}
    try captureAssert(bounded.capturedFrameCount == 1, "超预算不损坏已捕获分段")

    let color = try ScreenshotCaptureColorSampler.pixel(in: a, at: CGPoint(x: 30, y: 20))
    try captureAssert(color.hex.count == 7 && color.alpha == 255 && color.colorSpace.contains("sRGB"), "真实像素颜色与色彩空间")
    let magnifier = try ScreenshotCaptureColorSampler.magnifier(in: a, at: CGPoint(x: 0, y: 0), radius: 8, scale: 12)
    try captureAssert(magnifier.width == 108 && magnifier.height == 108, "边缘取色放大不能越界")
    let framed = try ScreenshotCaptureImageExport.framed(a, padding: 16, cornerRadius: 8, shadow: false, shell: true)
    try captureAssert(framed.width == 128 && framed.height == 220, "原创壳尺寸")
    try captureAssert(try ScreenshotCaptureColorSampler.pixel(in: framed, at: .zero).alpha == 0, "壳导出透明外边")
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("GaoJieTuCaptureTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let pngURL = directory.appendingPathComponent("framed.png")
    let decoded = try ScreenshotCaptureImageExport.write(framed, to: pngURL)
    try captureAssert(decoded.width == framed.width && decoded.height == framed.height, "PNG导出重读尺寸")
    try captureAssert(try ScreenshotCaptureColorSampler.pixel(in: decoded, at: .zero).alpha == 0, "PNG导出保留透明")
    do { _ = try ScreenshotCaptureImageExport.write(framed, to: pngURL); throw NSError(domain: "CaptureTests", code: 9) } catch ScreenshotCaptureFailure.exportFailed {}
    let jpeg = try ScreenshotCaptureImageExport.write(a, to: directory.appendingPathComponent("scaled.jpg"), format: .jpeg, quality: 0.8, maximumDimension: 70)
    try captureAssert(jpeg.width == 48 && jpeg.height == 70, "JPEG显式分辨率与压缩导出")
    let privateRoot = directory.appendingPathComponent("PrivatePins", isDirectory: true)
    let attachmentRoot = privateRoot.appendingPathComponent("Pins", isDirectory: true)
    try ScreenshotPinnedImagePersistence.ensurePrivateDirectory(attachmentRoot)
    let pinURL = attachmentRoot.appendingPathComponent("pin.png")
    _ = try ScreenshotCaptureImageExport.write(a, to: pinURL)
    let record = ScreenshotPinnedImageRecord(imagePath: pinURL.path, windowFrame: "{{10, 10}, {96, 140}}", imageScale: 1, opacity: 0.8)
    try ScreenshotPinnedImagePersistence.write([record], root: privateRoot)
    try captureAssert(try ScreenshotPinnedImagePersistence.read(root: privateRoot).count == 1, "持久贴图与位置私有保存")
    let metadataURL = privateRoot.appendingPathComponent("PinnedImages.json")
    let validMetadata = try Data(contentsOf: metadataURL)
    try FileManager.default.removeItem(at: pinURL)
    do { try ScreenshotPinnedImagePersistence.write([], root: privateRoot); throw NSError(domain: "CaptureTests", code: 10) } catch ScreenshotCaptureFailure.unsupported {}
    try captureAssert(try Data(contentsOf: metadataURL) == validMetadata, "附件缺失不能空白覆盖贴图记录")
    try Data("{\"schemaVersion\":2,\"records\":[]}".utf8).write(to: metadataURL)
    do { try ScreenshotPinnedImagePersistence.write([], root: privateRoot); throw NSError(domain: "CaptureTests", code: 11) } catch ScreenshotCaptureFailure.unsupported {}
    try Data("broken metadata".utf8).write(to: metadataURL)
    do { try ScreenshotPinnedImagePersistence.write([], root: privateRoot); throw NSError(domain: "CaptureTests", code: 12) } catch ScreenshotCaptureFailure.unsupported {}
    print("Capture isolated: 1x/2x/rotation, overlap=56, stitched=96x224, peak-estimate=\(session.estimatedPeakMemoryBytes) bytes; PNG alpha and JPEG resize decoded.")
    try ScreenshotRunCaptureRegressionTests()
}
