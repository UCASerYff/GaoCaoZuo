import AppKit
import SwiftUI

/// A native field editor keeps marked text and input-method commands in AppKit.
@MainActor struct OperationPanelSearchField: NSViewRepresentable {
    static let focusReadyNotification = Notification.Name("GaoOperationPanelSearchFocusReady")
    @Binding var text: String
    var onSubmit: () -> Void
    var onCancel: () -> Void
    var onMoveSelection: (Int) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }
    func makeNSView(context: Context) -> OperationPanelSearchTextField {
        let field = OperationPanelSearchTextField(frame: .zero)
        field.isBordered = false; field.drawsBackground = false
        field.isEditable = true; field.isSelectable = true; field.focusRingType = .none
        field.font = NSFont.preferredFont(forTextStyle: .title3)
        field.textColor = .labelColor
        field.delegate = context.coordinator
        updateNSView(field, context: context)
        return field
    }
    func updateNSView(_ field: OperationPanelSearchTextField, context: Context) {
        context.coordinator.parent = self
        field.placeholderString = L10n.text("搜索操作，或输入 :短语码")
        // SwiftUI updates must not replace an active field editor, including
        // its marked text, selection or insertion point.
        if field.currentEditor() == nil, field.stringValue != text {
            field.stringValue = text
        }
    }
    static func dismantleNSView(_ field: OperationPanelSearchTextField, coordinator: Coordinator) {
        field.cancelFocusRequest()
        field.delegate = nil
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: OperationPanelSearchField
        init(_ parent: OperationPanelSearchField) { self.parent = parent }
        func controlTextDidChange(_ notification: Notification) {
            guard let field = notification.object as? NSTextField else { return }
            parent.text = field.stringValue
        }
        func control(_ control: NSControl, textView: NSTextView, doCommandBy command: Selector) -> Bool {
            guard !textView.hasMarkedText() else { return false }
            switch NSStringFromSelector(command) {
            case "insertNewline:": parent.onSubmit(); return true
            case "cancelOperation:": parent.onCancel(); return true
            case "moveUp:": parent.onMoveSelection(-1); return true
            case "moveDown:": parent.onMoveSelection(1); return true
            default: return false
            }
        }
    }
}

@MainActor final class OperationPanelSearchTextField: NSTextField {
    private var observers: [NSObjectProtocol] = []
    private var pendingFocus = false
    private var focusScheduled = false
    private var focusGeneration: UInt64 = 0
    private var attachedForPresentation = false

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        cancelFocusRequest()
        // showPanel creates a fresh hosting view for each display. Reattaching
        // this same native view must not restart a cancelled/completed request.
        guard let window, !attachedForPresentation else { return }
        attachedForPresentation = true
        pendingFocus = true
        let center = NotificationCenter.default
        observers.append(center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestFocusIfEligible() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: NSApp, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestFocusIfEligible() }
        })
        observers.append(center.addObserver(forName: OperationPanelSearchField.focusReadyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestFocusIfEligible() }
        })
        observers.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: window, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.cancelFocusRequest() }
        })
        requestFocusIfEligible()
    }
    func cancelFocusRequest() {
        pendingFocus = false; focusScheduled = false; focusGeneration &+= 1
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
        observers.removeAll()
    }
    private func requestFocusIfEligible() {
        guard pendingFocus, !focusScheduled, let window,
              window.isVisible, window.isKeyWindow, NSApp.isActive else { return }
        focusScheduled = true
        let generation = focusGeneration
        // Run after key/activation notification delivery, without a timed retry.
        DispatchQueue.main.async { [weak self, weak window] in
            guard let self, self.focusGeneration == generation else { return }
            self.focusScheduled = false
            guard self.pendingFocus, let window, self.window === window,
                  window.isVisible, window.isKeyWindow, NSApp.isActive else { return }
            self.pendingFocus = false
            _ = window.makeFirstResponder(self)
        }
    }
    isolated deinit {
        for observer in observers { NotificationCenter.default.removeObserver(observer) }
    }
}
