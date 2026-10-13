import AppKit
import PDFKit
import ImageIO

/// Displays decoded bytes without executing active documents or launching an app.
final class NativeArchivePreview: NSView {
    private var content: NSView?
    func showMessage(_ message: String) {
        let label = NSTextField(wrappingLabelWithString: message)
        label.textColor = .secondaryLabelColor; label.alignment = .center
        install(label, inset: 20)
    }
    func show(data: Data, filename: String) throws {
        guard data.count <= 16 * 1_024 * 1_024 else { throw NativeArchive.Failure(message: "内嵌内容预览仅接受不超过 16 MiB 的普通文件。") }
        if data.starts(with: Data("%PDF-".utf8)) {
            guard let document = PDFDocument(data: data), document.pageCount <= 100 else { throw NativeArchive.Failure(message: "PDF 无法读取或超过 100 页内嵌预览预算。") }
            let preview = PDFView(); preview.document = document; preview.autoScales = true
            install(preview); return
        }
        if let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) {
            guard let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? NSNumber,
                  let height = properties[kCGImagePropertyPixelHeight] as? NSNumber,
                  width.int64Value > 0, height.int64Value > 0, width.int64Value <= 10_000, height.int64Value <= 10_000,
                  width.int64Value * height.int64Value <= 40_000_000,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 4_096, kCGImageSourceShouldCacheImmediately: false] as CFDictionary) else { throw NativeArchive.Failure(message: "图片无法读取或超过内嵌预览像素预算。") }
            let preview = NSImageView(); preview.image = NSImage(cgImage: image, size: .zero); preview.imageScaling = .scaleProportionallyUpOrDown
            install(preview); return
        }
        guard data.count <= 2 * 1_024 * 1_024, let text = String(data: data, encoding: .utf8),
              !text.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) && ![9, 10, 13].contains($0.value) }) else { throw NativeArchive.Failure(message: "此内容不能安全内嵌预览，请明确提取后打开。") }
        showListing(text)
    }
    func showListing(_ text: String) {
        let view = NSTextView(); view.string = text; view.isEditable = false; view.isSelectable = true
        view.font = .monospacedSystemFont(ofSize: 12, weight: .regular); view.textContainerInset = NSSize(width: 12, height: 12)
        view.isVerticallyResizable = true; view.isHorizontallyResizable = false
        let scroll = NSScrollView(); scroll.hasVerticalScroller = true; scroll.documentView = view
        view.autoresizingMask = [.width]; install(scroll)
    }
    private func install(_ view: NSView, inset: CGFloat = 0) {
        content?.removeFromSuperview(); content = view; addSubview(view); view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([view.leadingAnchor.constraint(equalTo: leadingAnchor, constant: inset), view.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -inset), view.topAnchor.constraint(equalTo: topAnchor, constant: inset), view.bottomAnchor.constraint(equalTo: bottomAnchor, constant: -inset)])
    }
}
