import AppKit
import ApplicationServices
import Carbon
import Combine
import SwiftUI

public enum CleanSessionState: String, Codable { case idle, verifyingRescue, active, exiting }

@MainActor public final class CleanerController: ObservableObject {
    public static let shared = CleanerController()
    @Published public private(set) var state: CleanSessionState = .idle
    @Published public private(set) var remainingSeconds = 180
    @Published public private(set) var escHoldProgress: CGFloat = 0
    @Published public private(set) var errorMessage: String?
    @Published public private(set) var rescueVerified = false
    let inputSafety = CleanerInputSafety()
    var onInputDemandChanged: (() -> Void)?
    var canBegin: (() -> String?)?
    var needsInputEvents: Bool { state == .verifyingRescue || state == .active }
    private var overlays: [NSWindow] = []
    private var timer: Timer?
    private lazy var watchdogSession = CleanerWatchdogSession(safety: inputSafety)
    private var observers: [NSObjectProtocol] = []
    private var verifiedUntil: TimeInterval = 0
    private var verificationDeadline: TimeInterval = 0
    private var deadline: TimeInterval = 0
    private var escapeStart: TimeInterval?
    private var desiredDuration = 180
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public init() {}

    public func startCleaning(durationSeconds: Int = 180) {
        if let reason=canBegin?() {errorMessage=reason;return}
        desiredDuration = min(180, max(30, durationSeconds))
        guard state != .active, !watchdogSession.isRunning else { return }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            errorMessage = "清洁输入拦截需要辅助功能权限，且不能在安全输入期间开启。"; return
        }
        if state == .idle { beginRescueVerification(); return }
        guard rescueVerified, now < verifiedUntil, inputSafety.healthy else {
            rescueVerified = false
            errorMessage = "请在本页按 ⌘⌥Q 验证退出键；只有活动事件通道实际收到该组合后才能开始。"; return
        }
        let started = now
        deadline = started + TimeInterval(desiredDuration); remainingSeconds = desiredDuration
        errorMessage = nil
        guard watchdogSession.start(now: started, duration: TimeInterval(desiredDuration), canPresent: { [weak self] in
            guard let self else { return false }
            return self.state == .verifyingRescue && self.rescueVerified && self.now < self.verifiedUntil
                && AXIsProcessTrusted() && !IsSecureEventInputEnabled() && self.canBegin?() == nil
        }, present: { [weak self] in
            guard let self else { return }
            self.state = .active; self.rescueVerified = false
            self.createOverlays()
        }, failed: { [weak self] in
            guard let self else { return }
            let wasActive = self.state == .active
            self.emergencyRelease()
            self.errorMessage = wasActive ? "权限或事件通道失效，已释放清洁拦截。" : "全局事件通道不可用，未进入清洁模式。"
        }) else {
            emergencyRelease(); errorMessage = "全局事件通道不可用，未进入清洁模式。"; return
        }
    }
    public func beginRescueVerification() {
        if let reason=canBegin?() {errorMessage=reason;return}
        guard state == .idle, AXIsProcessTrusted(), !IsSecureEventInputEnabled() else {
            errorMessage = "请先获得辅助功能权限，并离开安全输入。"; return
        }
        installLifecycleObservers()
        state = .verifyingRescue; rescueVerified = false; verificationDeadline = now + 30
        errorMessage = "先按 ⌘⌥Q 验证退出通道，再点击开始。验证期间不遮屏、不拦截其他输入。"
        onInputDemandChanged?()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }
    private func tick() {
        if state == .verifyingRescue {
            if now >= verificationDeadline { emergencyRelease(); errorMessage = "退出键验证已超时，未进入清洁模式。" }
            else if rescueVerified, now >= verifiedUntil { rescueVerified = false }
            return
        }
        guard state == .active else { return }
        guard AXIsProcessTrusted(), !IsSecureEventInputEnabled(), inputSafety.permitsInterception(now: now) else {
            emergencyRelease(); errorMessage = "权限或事件通道失效，已释放清洁拦截。"; return
        }
        inputSafety.pulse(now: now); remainingSeconds = max(0, Int(ceil(deadline - now)))
        if let start = escapeStart {
            escHoldProgress = min(1, CGFloat((now - start) / 3))
            if escHoldProgress >= 1 { stopCleaning() }
        }
        if now >= deadline { stopCleaning() }
    }
    /// Called only by the existing input tap, before application rules. Never
    /// installs a second monitor and never treats a simulated test as key proof.
    func handleInputEvent(type: CGEventType, event: CGEvent) -> Bool {
        guard needsInputEvents else { return false }
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            emergencyRelease(); errorMessage = "事件通道已停用，清洁模式已释放。"; return false
        }
        guard !IsSecureEventInputEnabled(), AXIsProcessTrusted(), inputSafety.healthy else {
            emergencyRelease(); return false
        }
        let flags = event.flags.intersection([.maskCommand, .maskAlternate, .maskControl, .maskShift, .maskSecondaryFn])
        let rescue = type == .keyDown && event.getIntegerValueField(.keyboardEventKeycode) == 12 && flags == [.maskCommand, .maskAlternate]
        if state == .verifyingRescue {
            if rescue {
                guard CleanerRescuePolicy.canVerify(sourcePID:event.getIntegerValueField(.eventSourceUnixProcessID),repeated:event.getIntegerValueField(.keyboardEventAutorepeat) != 0) else {
                    errorMessage = "此按键来源不能用于退出通道验证，请使用内置实体键盘重新按一次。";return false
                }
                rescueVerified = true; verifiedUntil = now + 20; verificationDeadline = verifiedUntil
                errorMessage = "退出通道已收到按键。20 秒内可开始，最长 180 秒。"; return true
            }
            return false
        }
        guard inputSafety.permitsInterception(now: now) else { emergencyRelease(); return false }
        if rescue { stopCleaning(); return true }
        if type == .keyDown || type == .keyUp {
            if event.getIntegerValueField(.keyboardEventKeycode) == 53 {
                if type == .keyDown, escapeStart == nil { escapeStart = now }
                if type == .keyUp { escapeStart = nil; escHoldProgress = 0 }
            }
        }
        // The overlay's exit button must remain clickable. Only our visible
        // full-screen overlay receives these clicks; other applications do not.
        if [.leftMouseDown, .leftMouseUp, .mouseMoved].contains(type),
           NSWorkspace.shared.frontmostApplication?.processIdentifier == ProcessInfo.processInfo.processIdentifier,
           overlays.contains(where: { $0.isVisible && $0.frame.contains(NSEvent.mouseLocation) }) { return false }
        return true
    }
    public func stopCleaning() {
        guard state != .idle else { return }
        state = .exiting; watchdogSession.cancel(); timer?.invalidate(); timer = nil
        for window in overlays { window.orderOut(nil) }; overlays = []
        for token in observers { NSWorkspace.shared.notificationCenter.removeObserver(token); NotificationCenter.default.removeObserver(token) }; observers = []
        escapeStart = nil; escHoldProgress = 0; rescueVerified = false; state = .idle
        onInputDemandChanged?()
    }
    public func emergencyRelease() { stopCleaning() }
    func inputChannelInvalidated() {
        rescueVerified = false
        verifiedUntil = 0
        if state == .active {
            let invalidatedSession = watchdogSession.currentToken
            inputSafety.finish()
            // InputController may be in the middle of rebuilding its sole tap.
            // Release overlays after that stack unwinds, without recursive rebuilds.
            DispatchQueue.main.async { [weak self] in
                guard self?.state == .active, self?.watchdogSession.currentToken == invalidatedSession else { return }
                self?.emergencyRelease()
                self?.errorMessage = "输入通道已重建，请重新验证退出键。"
            }
        }
    }
    private func installLifecycleObservers() {
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.emergencyRelease() }
            })
        }
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.emergencyRelease() }
        })
    }
    private func createOverlays() {
        for screen in NSScreen.screens {
            let window = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false, screen: screen)
            window.level = .screenSaver; window.isOpaque = true; window.backgroundColor = .black
            window.ignoresMouseEvents = false; window.acceptsMouseMovedEvents = true
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.contentView = NSHostingView(rootView: CleanerOverlayView(controller: self))
            window.orderFrontRegardless(); overlays.append(window)
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

// MARK: - CleanerOverlayView

private struct CleanerOverlayView: View {
    @ObservedObject var controller: CleanerController

    var body: some View {
        VStack(spacing: 28) {
            Spacer()

            // Icon & Title
            VStack(spacing: 16) {
                Image(systemName: "sparkles")
                    .font(.system(size: 64, weight: .light))
                    .foregroundStyle(.cyan)

                Text(L10n.text("键盘与屏幕清洁模式"))
                    .font(.system(size: 32, weight: .bold))
                    .foregroundStyle(.white)

                Text(L10n.text("普通键鼠输入已安全拦截，可放心擦拭屏幕与键盘表面"))
                    .font(.system(size: 16, weight: .regular))
                    .foregroundStyle(.white.opacity(0.8))
            }

            // Countdown Timer Card
            VStack(spacing: 8) {
                Text(L10n.format("剩余时间：%ld 秒", controller.remainingSeconds))
                    .font(.system(size: 24, weight: .medium, design: .monospaced))
                    .foregroundStyle(.white)

                ProgressView(value: Double(controller.remainingSeconds), total: 180.0)
                    .progressViewStyle(.linear)
                    .frame(width: 280)
                    .tint(.cyan)
            }
            .padding(.vertical, 16)
            .padding(.horizontal, 32)
            .background(Color.white.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 16))

            // Rescue Exit Instructions
            VStack(spacing: 12) {
                Text(L10n.text("长按 ESC 键 3 秒 或 按 ⌘+⌥+Q 退出清洁"))
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(.yellow)

                if controller.escHoldProgress > 0 {
                    VStack(spacing: 4) {
                        ProgressView(value: Double(controller.escHoldProgress), total: 1.0)
                            .progressViewStyle(.linear)
                            .frame(width: 220)
                            .tint(.yellow)
                        Text(L10n.text("正在长按 ESC 退出..."))
                            .font(.caption2)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }

                Button(action: {
                    controller.stopCleaning()
                }) {
                    Text(L10n.text("点击直接退出"))
                        .font(.subheadline)
                        .padding(.horizontal, 20)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.borderedProminent)
                .tint(.secondary)
                .padding(.top, 8)
            }

            Spacer()

            // System Reserved Safety Notice
            Text(L10n.text("清洁模式不是系统锁屏，不承诺拦截系统保留快捷键。通道或主线程失效时停止普通输入拦截；系统安全功能保持可用。"))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
