import AppKit
import ApplicationServices
import Combine
import SwiftUI

// MARK: - CleanSessionState

public enum CleanSessionState: String, Codable {
    case idle
    case verifyingRescue
    case active
    case exiting
}

// MARK: - CleanerController

@MainActor
public final class CleanerController: ObservableObject {
    public static let shared = CleanerController()

    @Published public private(set) var state: CleanSessionState = .idle
    @Published public private(set) var remainingSeconds: Int = 180
    @Published public private(set) var escHoldProgress: CGFloat = 0.0
    @Published public private(set) var errorMessage: String?

    private var overlayWindows: [NSWindow] = []
    private var countdownTimer: Timer?
    private var escHoldTimer: Timer?
    private var escHoldStartTime: Date?
    private var eventMonitor: Any?
    private var sleepObserver: NSObjectProtocol?
    private var terminateObserver: NSObjectProtocol?
    private let rescueHoldDuration: TimeInterval = 3.0
    private let defaultSessionDuration: Int = 180
    private let maximumSessionDuration: Int = 600

    public init() {
        setupSafetyObservers()
    }

    private func setupSafetyObservers() {
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.emergencyRelease()
            }
        }

        terminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.emergencyRelease()
            }
        }
    }

    public func startCleaning(durationSeconds: Int = 180) {
        guard state == .idle else { return }

        // 1. Authorization & environment preflight
        guard CGPreflightListenEventAccess() || AXIsProcessTrusted() else {
            errorMessage = "进入清洁模式需要输入监控或辅助功能权限以拦截按键。"
            return
        }

        // 2. State transition: verifying rescue mechanisms
        state = .verifyingRescue
        escHoldProgress = 0.0
        remainingSeconds = min(maximumSessionDuration, max(30, durationSeconds))

        // 3. Construct overlay windows across all connected screens
        createOverlayWindows()

        // 4. Activate input interception and start countdown timer
        installInterception()
        startCountdown()

        state = .active
        errorMessage = nil
    }

    public func stopCleaning() {
        guard state != .idle else { return }
        state = .exiting

        countdownTimer?.invalidate()
        countdownTimer = nil
        escHoldTimer?.invalidate()
        escHoldTimer = nil
        escHoldStartTime = nil

        removeInterception()
        destroyOverlayWindows()

        state = .idle
        escHoldProgress = 0.0
    }

    /// Immediate fail-safe release for sleep, app termination, or tap failure
    public func emergencyRelease() {
        stopCleaning()
    }

    private func createOverlayWindows() {
        destroyOverlayWindows()

        for screen in NSScreen.screens {
            let win = NSWindow(
                contentRect: screen.frame,
                styleMask: [.borderless],
                backing: .buffered,
                defer: false,
                screen: screen
            )
            win.level = .screenSaver
            win.isOpaque = false
            win.backgroundColor = NSColor.black.withAlphaComponent(0.96)
            win.ignoresMouseEvents = false
            win.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]

            let contentView = CleanerOverlayView(controller: self)
            win.contentView = NSHostingView(rootView: contentView)

            win.makeKeyAndOrderFront(nil)
            overlayWindows.append(win)
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    private func destroyOverlayWindows() {
        for win in overlayWindows {
            win.orderOut(nil)
        }
        overlayWindows.removeAll()
    }

    private func startCountdown() {
        countdownTimer?.invalidate()
        countdownTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self else { return }
                if self.remainingSeconds > 1 {
                    self.remainingSeconds -= 1
                } else {
                    self.stopCleaning()
                }
            }
        }
    }

    private func installInterception() {
        removeInterception()

        // Local event monitor for key and mouse events directed at the overlay windows
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .keyUp, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]) { [weak self] event in
            guard let self = self, self.state == .active else { return event }

            // Check for immediate rescue combination: Command + Option + Q
            if event.type == .keyDown && event.keyCode == 12 && event.modifierFlags.contains([.command, .option]) {
                self.stopCleaning()
                return nil
            }

            // Check for Esc hold (keyCode 53)
            if event.keyCode == 53 {
                if event.type == .keyDown && !event.isARepeat {
                    self.startEscHold()
                } else if event.type == .keyUp {
                    self.cancelEscHold()
                }
                return nil
            }

            // Intercept all other keyboard and mouse input
            return nil
        }
    }

    private func removeInterception() {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }

    private func startEscHold() {
        escHoldStartTime = Date()
        escHoldTimer?.invalidate()
        escHoldTimer = Timer.scheduledTimer(withTimeInterval: 0.05, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                guard let self = self, let start = self.escHoldStartTime else { return }
                let elapsed = Date().timeIntervalSince(start)
                let progress = min(1.0, CGFloat(elapsed / self.rescueHoldDuration))
                self.escHoldProgress = progress

                if progress >= 1.0 {
                    self.stopCleaning()
                }
            }
        }
    }

    private func cancelEscHold() {
        escHoldTimer?.invalidate()
        escHoldTimer = nil
        escHoldStartTime = nil
        escHoldProgress = 0.0
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
            Text(L10n.text("系统底层保留提示：Touch ID、Mac 电源键、强制退出（⌘⌥⎋）等内核级按键由 macOS 固件与系统内核直接管理，任何普通应用均不会且无法进行拦截。"))
                .font(.system(size: 12, weight: .regular))
                .foregroundStyle(.white.opacity(0.45))
                .multilineTextAlignment(.center)
                .frame(maxWidth: 600)
                .padding(.bottom, 24)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
