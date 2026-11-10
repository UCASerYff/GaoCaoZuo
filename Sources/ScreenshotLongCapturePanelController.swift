import AppKit

/// Non-activating controls deliberately leave keyboard focus in the user-selected scroll target.
@MainActor
final class ScreenshotLongCapturePanelController: NSObject, NSWindowDelegate {
    private var panel: ScreenshotLongCapturePanel?
    private var service: ScreenshotCaptureService?
    private var selection: ScreenshotCaptureSelectionController?
    private var operation: ScreenshotLongCaptureOperation?
    private var session: ScreenshotLongScreenshotSession?
    private var source: ScreenshotCaptureSource?
    private var options = ScreenshotCaptureOptions()
    private var completion: ((CGImage) -> Void)?
    private var captureTask: Task<Void, Never>?
    private var busy = false
    private let status = NSTextField(wrappingLabelWithString: "")
    private let seamLabel = NSTextField(labelWithString: "")
    private let seamSlider = NSSlider(value: 0, minValue: 0, maxValue: 1, target: nil, action: nil)
    private let previousPreview = NSImageView()
    private let currentPreview = NSImageView()
    private let nextButton = NSButton(title: "下一帧（手动滚动后）", target: nil, action: nil)
    private let scrollButton = NSButton(title: "向下滚动并捕获", target: nil, action: nil)
    private let finishButton = NSButton(title: "完成并标注", target: nil, action: nil)
    private let acceptButton = NSButton(title: "确认此接缝", target: nil, action: nil)
    private let rejectButton = NSButton(title: "拒绝并重试", target: nil, action: nil)
    private let cancelButton = NSButton(title: "取消", target: nil, action: nil)
    private var previewStack: NSStackView?
    var onStatus: ((String) -> Void)?
    var onCancel: (() -> Void)?

    func start(service: ScreenshotCaptureService, selection: ScreenshotCaptureSelectionController, operation: ScreenshotLongCaptureOperation, options: ScreenshotCaptureOptions = .init(), onComplete: @escaping (CGImage) -> Void) async throws {
        try operation.checkActive()
        cancelSession(notify: false)
        self.operation = operation; self.selection = selection
        onStatus?("长截图：先单击目标窗口，再拖选其中的纯滚动内容区；排除固定页眉、页脚和侧栏。")
        let prepared = try await ScreenshotLongCapturePreparation.run(operation: operation,
            isCurrent: { [weak self] in self?.operation === operation },
            refreshCatalog: { try await service.refreshCatalog() },
            selectWindow: { await selection.selectWindow(from: $0) },
            willSelectRegion: { [weak self] in self?.onStatus?("长截图：拖选目标窗口内的滚动内容区，Return 确认。") },
            selectRegion: { await selection.selectRegion()?.desktopRect },
            activate: { window in
                // Explicitly selected product target, activated once. Subsequent controls never steal its focus.
                guard let app = NSRunningApplication(processIdentifier: window.processID), app.activate(options: []) else { throw ScreenshotCaptureFailure.sourceMissing }
            },
            settle: { try await Task.sleep(nanoseconds: 350_000_000) })
        try operation.checkActive()
        guard self.operation === operation else { throw CancellationError() }
        let window = prepared.window, region = prepared.region
        self.service = service; self.options = options; self.completion = onComplete
        self.source = .window(window.id)
        self.session = ScreenshotLongScreenshotSession(target: ScreenshotScrollTargetIdentity(processID: window.processID, windowID: window.id, frame: window.frame, scrollRegion: region))
        buildPanel(targetName: window.applicationName)
        captureNext(scroll: false)
    }

    func cancel() { cancelSession(notify: true) }
    func windowWillClose(_ notification: Notification) { cancelSession(notify: true) }

    private func buildPanel(targetName: String) {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1000, height: 700)
        let rect = CGRect(x: screen.maxX - 580, y: screen.maxY - 620, width: 560, height: 600)
        let panel = ScreenshotLongCapturePanel(contentRect: rect, styleMask: [.titled, .nonactivatingPanel, .utilityWindow], backing: .buffered, defer: false)
        panel.title = "长截图 · \(targetName)"; panel.level = .floating; panel.isReleasedWhenClosed = false
        panel.becomesKeyOnlyIfNeeded = true; panel.hidesOnDeactivate = false; panel.delegate = self
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        self.panel = panel
        status.font = .systemFont(ofSize: 13); status.maximumNumberOfLines = 5
        status.stringValue = "正在捕获首帧。随后在目标窗口内手动滚动，再点“下一帧”；一次滚动请保留至少20%重叠。"
        for imageView in [previousPreview, currentPreview] {
            imageView.imageScaling = .scaleProportionallyUpOrDown
            imageView.wantsLayer = true; imageView.layer?.backgroundColor = NSColor.controlBackgroundColor.cgColor
            imageView.widthAnchor.constraint(equalToConstant: 250).isActive = true
            imageView.heightAnchor.constraint(equalToConstant: 160).isActive = true
        }
        let previews = NSStackView(views: [previousPreview, currentPreview]); previews.orientation = .horizontal; previews.spacing = 12
        seamSlider.target = self; seamSlider.action = #selector(seamChanged)
        acceptButton.target = self; acceptButton.action = #selector(acceptSeam)
        rejectButton.target = self; rejectButton.action = #selector(rejectSeam)
        let seamActions = NSStackView(views: [acceptButton, rejectButton]); seamActions.orientation = .horizontal
        let seamArea = NSStackView(views: [previews, seamLabel, seamSlider, seamActions]); seamArea.orientation = .vertical; seamArea.alignment = .leading; seamArea.spacing = 6
        seamArea.isHidden = true; previewStack = seamArea
        nextButton.target = self; nextButton.action = #selector(nextFrame)
        scrollButton.target = self; scrollButton.action = #selector(scrollFrame)
        finishButton.target = self; finishButton.action = #selector(finishCapture)
        cancelButton.target = self; cancelButton.action = #selector(cancelCapture)
        let buttons = NSStackView(views: [nextButton, scrollButton, finishButton, cancelButton]); buttons.orientation = .horizontal; buttons.spacing = 8
        let note = NSTextField(wrappingLabelWithString: "辅助功能未授权时仅手动滚动。目标焦点/窗口改变即暂停；重复画面视为边界。动画、视频、无限滚动与复杂固定区域请逐条核对。像素/高度/内存达预算会保留已捕获分段并停止追加。")
        note.font = .systemFont(ofSize: 11); note.textColor = .secondaryLabelColor
        let stack = NSStackView(views: [status, seamArea, buttons, note]); stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        guard let content = panel.contentView else { return }; content.addSubview(stack)
        NSLayoutConstraint.activate([stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16), stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16), stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16), stack.bottomAnchor.constraint(lessThanOrEqualTo: content.bottomAnchor, constant: -16), status.widthAnchor.constraint(equalTo: stack.widthAnchor), note.widthAnchor.constraint(equalTo: stack.widthAnchor), seamSlider.widthAnchor.constraint(equalTo: stack.widthAnchor)])
        panel.orderFrontRegardless()
    }

    private func captureNext(scroll: Bool) {
        guard !busy, let service, let source, let session, let operation, operation.isActive else { return }
        busy = true; updateButtons(); status.stringValue = scroll ? "向目标窗口发送一次滚动并等待画面稳定…" : "正在捕获当前帧…"
        captureTask = Task { [weak self] in
            guard let self else { return }
            do {
                let seam: ScreenshotScrollSeamEstimate?
                if scroll {
                    seam = try await session.scrollAndCapture(using: service, source: source, options: self.options,
                        waitingForPointer: { [weak self] in self?.status.stringValue = "请将鼠标移回原选区，最多等待2秒；不会自动移动鼠标。" })
                }
                else { seam = try await session.captureNext(using: service, source: source, options: self.options) }
                guard !Task.isCancelled, operation.isActive, self.operation === operation else { return }
                if let pending = session.pendingSeam { self.showSeam(pending) }
                else if seam?.duplicate == true { self.status.stringValue = "画面没有移动，当前帧未追加。可能已到边界，可完成或手动滚动后重试。" }
                else { self.status.stringValue = "已捕获 \(session.capturedFrameCount) 帧 · 高度 \(session.outputHeight) px · 估计峰值 \(session.estimatedPeakMemoryBytes / 1024 / 1024) MiB。请滚动后捕获下一帧，或完成。" }
            } catch {
                guard !Task.isCancelled, operation.isActive, self.operation === operation else { return }
                self.status.stringValue = error.localizedDescription
            }
            self.busy = false; self.captureTask = nil; self.updateButtons()
        }
    }

    private func showSeam(_ seam: ScreenshotScrollSeamEstimate) {
        seamSlider.minValue = 0; seamSlider.maxValue = Double(max(1, (session?.pendingFrameHeight ?? 2) - 1))
        seamSlider.doubleValue = Double(seam.overlapPixels)
        previewStack?.isHidden = false; seamChanged()
        status.stringValue = "接缝置信度 \(Int(seam.confidence * 100))%。上帧底部（左）/本帧顶部（右）需人工核对。\n" + seam.warnings.joined(separator: "\n")
    }

    private func updateButtons() {
        let pending = session?.pendingSeam != nil
        nextButton.isEnabled = !busy && !pending; scrollButton.isEnabled = !busy && !pending && AXIsProcessTrusted()
        finishButton.isEnabled = !busy && !pending && (session?.capturedFrameCount ?? 0) > 0
        acceptButton.isEnabled = !busy && pending; rejectButton.isEnabled = !busy && pending
    }

    @objc private func seamChanged() {
        let overlap = Int(seamSlider.doubleValue.rounded())
        do {
            guard let session, let preview = try session.pendingPreview(overlapPixels: overlap) else { return }
            previousPreview.image = NSImage(cgImage: preview.previousImage, size: .zero)
            currentPreview.image = NSImage(cgImage: preview.currentImage, size: .zero)
            seamLabel.stringValue = overlap > 0 ? "重叠 \(overlap) px · 两侧对应重叠末尾 \(preview.currentImage.height) 行" : "重叠 0 px · 无共同行，请核对两侧直接相接"
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func nextFrame() { captureNext(scroll: false) }
    @objc private func scrollFrame() { captureNext(scroll: true) }
    @objc private func acceptSeam() {
        do { try session?.acceptPending(overlapPixels: Int(seamSlider.doubleValue.rounded())); previewStack?.isHidden = true; status.stringValue = "已按用户确认追加此帧。可继续滚动。"; updateButtons() }
        catch { status.stringValue = error.localizedDescription }
    }
    @objc private func rejectSeam() { session?.rejectPending(); previewStack?.isHidden = true; status.stringValue = "已拒绝接缝。请回到目标窗口调整滚动位置，再点下一帧。"; updateButtons() }
    @objc private func finishCapture() {
        do {
            guard let operation, operation.isActive else { return }
            guard let image = try session?.finish() else { return }
            let completion = self.completion; self.completion = nil
            closePanel(); service = nil; session = nil; source = nil; selection = nil; self.operation = nil
            clearPreviews()
            completion?(image)
        } catch { status.stringValue = error.localizedDescription }
    }
    @objc private func cancelCapture() { cancel() }
    private func closePanel() { panel?.delegate = nil; panel?.orderOut(nil); panel?.close(); panel = nil }
    private func clearPreviews() { previousPreview.image = nil; currentPreview.image = nil; previewStack?.isHidden = true }
    private func cancelSession(notify: Bool) {
        operation = nil
        selection?.cancel(); selection = nil
        captureTask?.cancel(); captureTask = nil; session?.cancel(); session = nil; service = nil; source = nil; completion = nil; busy = false
        closePanel(); clearPreviews(); if notify { onCancel?() }
    }
}

private final class ScreenshotLongCapturePanel: NSPanel {
    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }
}
