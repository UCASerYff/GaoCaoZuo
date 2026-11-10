import CoreGraphics

struct ScreenshotLongCaptureWindowCropResult {
    let image: CGImage
    /// Full captured window plus the independent crop context and its image snapshot.
    let workingBytes: Int
}

enum ScreenshotLongCaptureWindowCrop {
    static func imageBytes(_ image: CGImage) throws -> Int {
        let bytes = image.bytesPerRow.multipliedReportingOverflow(by: image.height)
        guard !bytes.overflow, bytes.partialValue > 0 else { throw ScreenshotCaptureFailure.budgetExceeded }
        return bytes.partialValue
    }

    static func remainingBytes(maximum: Int, retained: [Int]) throws -> Int {
        guard maximum > 0 else { throw ScreenshotCaptureFailure.budgetExceeded }
        var remaining = maximum
        for bytes in retained {
            guard bytes >= 0, bytes < remaining else { throw ScreenshotCaptureFailure.budgetExceeded }
            remaining -= bytes
        }
        return remaining
    }

    /// A desktop-independent window image must have exactly the frozen window's pixel extent.
    /// Do not rescale or fall back to a display image when its geometry is unknown.
    static func pixelRect(windowFrame: CGRect, capturedBounds: CGRect, desktopRegion: CGRect,
                          scale: CGFloat, imageSize: CGSize) throws -> CGRect {
        guard ScreenshotCaptureWindowEligibility.validFrame(windowFrame), capturedBounds == windowFrame,
              desktopRegion.width > 0, desktopRegion.height > 0,
              desktopRegion.minX.isFinite, desktopRegion.minY.isFinite,
              desktopRegion.maxX.isFinite, desktopRegion.maxY.isFinite,
              windowFrame.contains(desktopRegion) else { throw ScreenshotCaptureFailure.invalidRegion }
        let full = try ScreenshotCaptureGeometry.pixelRect(CGRect(origin: .zero, size: windowFrame.size), scale: scale)
        guard imageSize == full.size else { throw ScreenshotCaptureFailure.invalidRegion }
        let local = desktopRegion.offsetBy(dx: -windowFrame.minX, dy: -windowFrame.minY)
        let pixels = try ScreenshotCaptureGeometry.pixelRect(local, scale: scale)
        let bounded = pixels.intersection(CGRect(origin: .zero, size: imageSize))
        guard !bounded.isNull, bounded.width >= 1, bounded.height >= 1,
              bounded == pixels else { throw ScreenshotCaptureFailure.invalidRegion }
        return bounded
    }

    static func copyWorkingBytes(parentBytes: Int, width: Int, height: Int,
                                 maximumPixels: Int, maximumBytes: Int) throws -> Int {
        try ScreenshotCaptureGeometry.validateBudget(width: width, height: height,
                                           maximumPixels: maximumPixels, maximumBytes: maximumBytes)
        let cropBytes = width * height * 4 // validateBudget proved this multiplication fits.
        guard parentBytes > 0, parentBytes <= maximumBytes,
              cropBytes <= (maximumBytes - parentBytes) / 2 else { throw ScreenshotCaptureFailure.budgetExceeded }
        return parentBytes + cropBytes * 2
    }

    static func copy(_ image: CGImage, windowFrame: CGRect, capturedBounds: CGRect,
                     desktopRegion: CGRect, scale: CGFloat, maximumPixels: Int,
                     maximumBytes: Int) throws -> ScreenshotLongCaptureWindowCropResult {
        let pixels = try pixelRect(windowFrame: windowFrame, capturedBounds: capturedBounds,
                                   desktopRegion: desktopRegion, scale: scale,
                                   imageSize: CGSize(width: image.width, height: image.height))
        let width = Int(pixels.width), height = Int(pixels.height)
        let workingBytes = try copyWorkingBytes(parentBytes: imageBytes(image), width: width, height: height,
                                               maximumPixels: maximumPixels, maximumBytes: maximumBytes)
        guard let colorSpace = image.colorSpace, colorSpace.model == .rgb,
              let crop = image.cropping(to: pixels),
              let context = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                      bytesPerRow: width * 4, space: colorSpace,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            throw ScreenshotCaptureFailure.emptyImage
        }
        context.interpolationQuality = .none
        context.setBlendMode(.copy)
        context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
        // CGImage.cropping retains its full parent. Drawing into a new context severs that ownership.
        guard let owned = context.makeImage() else { throw ScreenshotCaptureFailure.emptyImage }
        return ScreenshotLongCaptureWindowCropResult(image: owned, workingBytes: workingBytes)
    }
}
