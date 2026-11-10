import AppKit
import ApplicationServices
import Carbon.HIToolbox
import Combine
import ScreenCaptureKit

/// Public AX APIs provide the directory. ScreenCaptureKit is only entered by the explicit one-shot preview command.
@MainActor
final class DesktopOverviewController: ObservableObject {
    typealias WindowActionHandler = (WindowAction, DesktopOverviewActionTarget) async throws -> WindowOperationOutcome
    @Published private(set) var entries: [DesktopOverviewEntry] = []
    @Published private(set) var preferences: DesktopOverviewPreferences
    @Published private(set) var isLoading = false
    @Published private(set) var isBusy = false
    @Published private(set) var isCapturingPreviews = false
    @Published private(set) var accessibilityGranted = false
    @Published private(set) var screenCaptureGranted = false
    @Published private(set) var status = "打开窗口总览后读取窗口目录。"
    @Published private(set) var previewStatus = "预览只在本页点击生成时读取窗口像素，关闭后清除。"
    @Published private(set) var previewRevision: UInt = 0
    @Published var selectedID: String?
    private(set) var isSessionActive = false

    private struct Handle {
        let element: AXUIElement?
        let application: NSRunningApplication
        let identity: WindowProcessIdentity.Snapshot
    }
    private struct Preview { let image: NSImage; let created: TimeInterval }
    private var handles: [String: Handle] = [:]
    private var previews: [String: Preview] = [:]
    private var generation = UUID()
    private var operation = UUID()
    private var operationInitialPID: pid_t?
    private var previewRequest: UUID?
    private var catalogTask: Task<Void, Never>?
    private var operationTask: Task<Void, Never>?
    private var previewTask: Task<Void, Never>?
    private var previewExpiryTask: Task<Void, Never>?
    private var nativeCaptureInFlight = false
    private var shareableInFlight = false
    private var observers: [(NotificationCenter, NSObjectProtocol)] = []
    private let ownPID = ProcessInfo.processInfo.processIdentifier
    private let onPreferencesChange: ((DesktopOverviewPreferences) throws -> Void)?
    private let onWindowAction: WindowActionHandler?
    private let blockedBundleIDs: Set<String> = ["com.apple.loginwindow", "com.apple.SecurityAgent", "com.apple.authorizationhost", "com.apple.systemuiserver", "com.apple.controlcenter", "com.apple.dock", "com.apple.WindowManager", "com.apple.ScreenSaver.Engine", "com.apple.notificationcenterui", "com.apple.UserNotificationCenter"]

    init(preferences: DesktopOverviewPreferences = .init(),
         onPreferencesChange: ((DesktopOverviewPreferences) throws -> Void)? = nil,
         onWindowAction: WindowActionHandler? = nil) {
        self.preferences = preferences
        self.onPreferencesChange = onPreferencesChange
        self.onWindowAction = onWindowAction
    }

    var supportsWindowActions: Bool { onWindowAction != nil }
    var selectedEntry: DesktopOverviewEntry? { entries.first { $0.id == selectedID } }
    var excludedApplications: [String] { preferences.excludedApplicationBundleIDs }

    func beginSession() {
        guard !isSessionActive else { return }
        isSessionActive = true
        let workspace = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification,
                     NSWorkspace.didWakeNotification, NSWorkspace.didTerminateApplicationNotification,
                     NSWorkspace.didLaunchApplicationNotification] {
            observe(workspace, name) { [weak self] in self?.invalidate("应用或会话已变化，请刷新窗口目录。") }
        }
        observe(NotificationCenter.default, NSApplication.didChangeScreenParametersNotification) { [weak self] in
            self?.invalidate("屏幕布局已变化，请刷新窗口目录。")
        }
        // A background overview must not retain document pixels. There is no focus polling or screen stream.
        observe(NotificationCenter.default, NSApplication.didResignActiveNotification) { [weak self] in self?.releasePreviews() }
        refresh()
    }

    func endSession() {
        isSessionActive = false
        invalidate("窗口总览已关闭，内存目录与预览已清除。")
        for (center, observer) in observers { center.removeObserver(observer) }
        observers.removeAll()
    }

    func applyPreferences(_ value: DesktopOverviewPreferences) {
        do {
            let value = try value.validated()
            let exclusionsChanged = value.excludedApplicationBundleIDs != preferences.excludedApplicationBundleIDs
            if value != preferences { releasePreviews() }
            preferences = value
            if exclusionsChanged, isSessionActive { refresh() }
        } catch { status = error.localizedDescription }
    }

    func updatePreferences(_ mutate: (inout DesktopOverviewPreferences) -> Void) {
        var value = preferences
        mutate(&value)
        do {
            value = try value.validated()
            // Persist first. A failed store write must not be presented as saved.
            try onPreferencesChange?(value)
            applyPreferences(value)
        } catch { status = "设置未保存：" + error.localizedDescription }
    }

    func excludeApplication(_ entry: DesktopOverviewEntry) {
        guard !entry.bundleID.isEmpty else { status = "此应用未提供 Bundle ID，不能保存排除规则。"; return }
        updatePreferences { if !$0.excludedApplicationBundleIDs.contains(entry.bundleID) { $0.excludedApplicationBundleIDs.append(entry.bundleID) } }
    }

    func excludePreview(_ entry: DesktopOverviewEntry) {
        guard !entry.bundleID.isEmpty else { return }
        updatePreferences { if !$0.excludedThumbnailBundleIDs.contains(entry.bundleID) { $0.excludedThumbnailBundleIDs.append(entry.bundleID) } }
    }

    func refreshPermissions() {
        accessibilityGranted = AXIsProcessTrusted()
        screenCaptureGranted = CGPreflightScreenCaptureAccess()
        if !accessibilityGranted || !screenCaptureGranted { releasePreviews() }
    }

    /// This method is connected only to the named user button; never called by init, refresh or appearance.
    func requestPreviewPermission() {
        guard isSessionActive else { return }
        screenCaptureGranted = CGPreflightScreenCaptureAccess() || CGRequestScreenCaptureAccess()
        previewStatus = screenCaptureGranted ? "屏幕录制已授权。点击“生成一次预览”才会读取窗口内容。" : "未获得屏幕录制权限，仍可使用窗口信息与应用图标。授权后可返回刷新权限。"
    }

    func openAccessibilitySettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") else { return }
        NSWorkspace.shared.open(url)
    }

    func openScreenCaptureSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") else { return }
        NSWorkspace.shared.open(url)
    }

    func refresh() {
        guard isSessionActive, !isBusy else { return }
        catalogTask?.cancel()
        operation = UUID()
        generation = UUID()
        let request = generation
        releasePreviews()
        isLoading = true
        refreshPermissions()
        catalogTask = Task { [weak self] in await self?.readDirectory(request: request) }
    }

    private func readDirectory(request: UUID) async {
        defer { if generation == request { isLoading = false; catalogTask = nil } }
        status = "正在读取运行中的应用与 AX 窗口…"
        let oldHandles = handles
        let oldEntries = entries
        var nextHandles: [String: Handle] = [:]
        var result: [DesktopOverviewEntry] = []
        let started = ProcessInfo.processInfo.systemUptime
        let deadline = started + 2
        let applications = NSWorkspace.shared.runningApplications.filter {
            !$0.isTerminated && $0.activationPolicy == .regular && $0.processIdentifier != ownPID &&
            !blockedBundleIDs.contains($0.bundleIdentifier ?? "") &&
            !preferences.excludedApplicationBundleIDs.contains($0.bundleIdentifier ?? "")
        }.sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
        var reachedBudget = applications.count > DesktopOverviewPolicy.maximumApps
        for app in applications.prefix(DesktopOverviewPolicy.maximumApps) {
            guard isCurrent(request), result.count < DesktopOverviewPolicy.maximumWindows else { reachedBudget = true; break }
            await Task.yield()
            guard isCurrent(request), let identity = WindowProcessIdentity.capture(pid: app.processIdentifier, launchDate: app.launchDate) else { continue }
            let records = accessibilityGranted && ProcessInfo.processInfo.systemUptime < deadline ? readWindows(pid: app.processIdentifier, deadline: deadline) : []
            if ProcessInfo.processInfo.systemUptime >= deadline { reachedBudget = true }
            for (element, title, frame, minimized, closeable) in records {
                guard isCurrent(request), result.count < DesktopOverviewPolicy.maximumWindows else { reachedBudget = true; break }
                let oldID = oldHandles.first { key, value in
                    value.identity.matches(identity) && value.element.map { CFEqual($0, element) } == true && oldEntries.contains { $0.id == key }
                }?.key
                let id = oldID ?? "ax:\(UUID().uuidString)"
                nextHandles[id] = Handle(element: element, application: app, identity: identity)
                result.append(makeEntry(id: id, app: app, title: title, frame: frame, minimized: minimized,
                                        canFocus: true, canClose: closeable, created: started, generation: request,
                                        detail: minimized ? "已最小化 · 可还原并聚焦" : "AX 窗口 · 可选择并聚焦"))
            }
            if records.isEmpty, result.count < DesktopOverviewPolicy.maximumWindows {
                let id = "app:\(identity.token.pid):\(identity.token.startSeconds):\(identity.token.startMicroseconds)"
                nextHandles[id] = Handle(element: nil, application: app, identity: identity)
                result.append(makeEntry(id: id, app: app, title: "", frame: nil, minimized: false, canFocus: false, canClose: false,
                                        created: started, generation: request, detail: accessibilityGranted ? "未读取到标准窗口 · 仅激活应用" : "未获辅助功能权限 · 仅激活应用"))
            }
            guard processMatches(app, identity: identity) else {
                let removed = Set(result.filter { $0.pid == app.processIdentifier }.map(\.id))
                result.removeAll { removed.contains($0.id) }
                for id in removed { nextHandles.removeValue(forKey: id) }
                continue
            }
        }
        guard isCurrent(request) else { return }
        handles = nextHandles
        entries = result
        if !entries.contains(where: { $0.id == selectedID }) { selectedID = nil }
        status = "\(result.filter(\.canFocus).count) 个窗口，\(result.filter { !$0.canFocus }.count) 个应用入口" +
            (accessibilityGranted ? "" : " · 辅助功能未授权，窗口操作不可用") +
            (reachedBudget ? " · 部分应用达到读取预算，可刷新重试" : "")
    }

    func activate(_ entry: DesktopOverviewEntry) {
        runOperation { request in
            if entry.canFocus {
                _ = try await self.focus(entry, operation: request)
                return "已读回确认：所选窗口已聚焦。"
            }
            let handle = try self.validHandle(entry)
            try self.checkOperation(request)
            let initial = self.operationInitialPID
            let before = NSWorkspace.shared.frontmostApplication?.processIdentifier
            guard before == initial || before == self.ownPID || before == entry.pid else {
                throw DesktopOverviewError.message("前台应用已变化，已停止激活此应用。")
            }
            NSApp.yieldActivation(to: handle.application)
            guard handle.application.activate(from: .current, options: []) else { throw DesktopOverviewError.message("系统拒绝激活此应用。") }
            for _ in 0..<10 {
                try await Task.sleep(for: .milliseconds(50))
                try self.checkOperation(request)
                _ = try self.validHandle(entry)
                let front = NSWorkspace.shared.frontmostApplication?.processIdentifier
                if front == entry.pid { return "已读回确认：应用已前台；此条目没有可验证的窗口。" }
                guard front == initial || front == self.ownPID else { throw DesktopOverviewError.message("前台应用已变化，已停止激活验证。") }
            }
            throw DesktopOverviewError.message("已请求激活应用，未能确认其前台状态。")
        }
    }

    func perform(_ action: WindowAction, on entry: DesktopOverviewEntry) {
        guard let onWindowAction else { status = "窗口动作处理器尚未接入。"; return }
        runOperation { request in
            let target = try await self.focus(entry, operation: request)
            try self.checkOperation(request)
            guard self.isFocused(target.element, pid: entry.pid), NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid else {
                throw DesktopOverviewError.message("窗口焦点已变化，未执行布局。")
            }
            let result = try await onWindowAction(action, target)
            return result.message
        }
    }

    /// Called after the visible confirmation. A save dialog is left to the user and is never dismissed here.
    func close(_ entry: DesktopOverviewEntry) {
        runOperation { request in
            guard entry.canClose else { throw DesktopOverviewError.message("该条目没有可验证的标准关闭按钮。") }
            let target = try self.validTarget(entry)
            guard let button = self.element(self.value(target.element, kAXCloseButtonAttribute)),
                  self.belongs(button, pid: entry.pid), self.value(button, kAXEnabledAttribute) as? Bool != false,
                  self.supports(button, action: kAXPressAction) else { throw DesktopOverviewError.message("窗口的关闭按钮已失效或不可用。") }
            try self.checkOperation(request)
            _ = try self.validTarget(entry)
            guard AXUIElementPerformAction(button, kAXPressAction as CFString) == .success else { throw DesktopOverviewError.message("系统拒绝关闭请求，未确认窗口关闭。") }
            for _ in 0..<6 {
                try await Task.sleep(for: .milliseconds(100))
                try self.checkOperation(request)
                let handle = try self.validHandle(entry)
                guard let windows = self.windowElements(pid: entry.pid) else { throw DesktopOverviewError.message("关闭请求已提交；窗口目录不可读，无法确认结果。") }
                guard self.processMatches(handle.application, identity: handle.identity) else { throw DesktopOverviewError.message("关闭请求已提交；应用身份变化，不能将进程退出当作窗口关闭验收。") }
                if !windows.contains(where: { CFEqual($0, target.element) }) {
                    self.handles.removeValue(forKey: entry.id)
                    self.entries.removeAll { $0.id == entry.id }
                    self.previews.removeValue(forKey: entry.id)
                    self.previewRevision &+= 1
                    if self.selectedID == entry.id { self.selectedID = nil }
                    return "已读回确认：窗口已从应用目录移除。"
                }
            }
            return "关闭请求已提交；窗口仍存在，可能等待未保存文档确认。"
        }
    }

    private func focus(_ entry: DesktopOverviewEntry, operation request: UUID) async throws -> DesktopOverviewActionTarget {
        var target = try validTarget(entry)
        try checkOperation(request)
        if value(target.element, kAXMinimizedAttribute) as? Bool == true {
            guard AXUIElementSetAttributeValue(target.element, kAXMinimizedAttribute as CFString, kCFBooleanFalse) == .success else {
                throw DesktopOverviewError.message("系统不允许还原此窗口。")
            }
        }
        let initial = operationInitialPID
        try await WindowFocusTransaction.perform(targetPID: entry.pid, ownPID: ownPID, allowedInitialPID: initial,
            frontmostPID: { NSWorkspace.shared.frontmostApplication?.processIdentifier },
            validateTarget: { try self.checkOperation(request); target = try self.validTarget(entry) },
            isTargetFocused: { self.isFocused(target.element, pid: entry.pid) },
            raiseTarget: {
                guard AXUIElementPerformAction(target.element, kAXRaiseAction as CFString) == .success else { throw DesktopOverviewError.message("目标应用拒绝将所选窗口带到前台。") }
            }, activateTarget: {
                if NSWorkspace.shared.frontmostApplication?.processIdentifier == entry.pid { return true }
                NSApp.yieldActivation(to: target.application)
                return target.application.activate(from: .current, options: [])
            }, isCancelled: { self.operation != request || !self.isSessionActive })
        return target
    }

    private func runOperation(_ body: @escaping (UUID) async throws -> String) {
        guard isSessionActive, !isBusy, !isLoading else { return }
        releasePreviews()
        let request = UUID()
        operation = request
        operationInitialPID = NSWorkspace.shared.frontmostApplication?.processIdentifier
        isBusy = true
        operationTask = Task { [weak self] in
            guard let self else { return }
            defer { if self.operation == request { self.isBusy = false; self.operationTask = nil; self.operationInitialPID = nil } }
            do {
                try self.checkOperation(request)
                let message = try await body(request)
                if self.operation == request { self.status = message }
            } catch {
                if self.operation == request { self.status = error is CancellationError ? "窗口操作已取消。" : error.localizedDescription }
            }
        }
    }

    private func checkOperation(_ request: UUID) throws {
        try Task.checkCancellation()
        guard isSessionActive, operation == request else { throw CancellationError() }
        guard !IsSecureEventInputEnabled() else { throw DesktopOverviewError.message("当前系统处于安全输入状态，已停止窗口操作。") }
    }

    private func validHandle(_ entry: DesktopOverviewEntry) throws -> Handle {
        guard isSessionActive, entry.generation == generation,
              DesktopOverviewPolicy.isFresh(createdAt: entry.createdAt, now: ProcessInfo.processInfo.systemUptime),
              entries.contains(where: { $0.id == entry.id }), !preferences.excludedApplicationBundleIDs.contains(entry.bundleID),
              let handle = handles[entry.id], processMatches(handle.application, identity: handle.identity) else {
            throw DesktopOverviewError.message("窗口目录已过期、应用已重启或目标已排除，请刷新后重新选择。")
        }
        return handle
    }

    private func validTarget(_ entry: DesktopOverviewEntry) throws -> DesktopOverviewActionTarget {
        guard AXIsProcessTrusted() else { throw DesktopOverviewError.message("辅助功能权限未授予或已撤销，仍可使用应用入口。") }
        let handle = try validHandle(entry)
        guard entry.canFocus, let element = handle.element, belongs(element, pid: entry.pid),
              let windows = windowElements(pid: entry.pid), windows.contains(where: { CFEqual($0, element) }),
              value(element, kAXRoleAttribute) as? String == kAXWindowRole,
              processMatches(handle.application, identity: handle.identity) else {
            throw DesktopOverviewError.message("原窗口已关闭或标准 AX 身份无法验证，请刷新。")
        }
        return DesktopOverviewActionTarget(element: element, application: handle.application, identity: handle.identity, pid: entry.pid)
    }

    private func processMatches(_ app: NSRunningApplication, identity: WindowProcessIdentity.Snapshot) -> Bool {
        guard !app.isTerminated, let current = NSRunningApplication(processIdentifier: app.processIdentifier),
              !current.isTerminated, app.isEqual(current), current.bundleIdentifier == app.bundleIdentifier else { return false }
        return WindowProcessIdentity.matches(captured: identity, currentPID: current.processIdentifier, currentLaunchDate: current.launchDate)
    }

    private func readWindows(pid: pid_t, deadline: TimeInterval) -> [(AXUIElement, String, CGRect?, Bool, Bool)] {
        guard let windows = windowElements(pid: pid) else { return [] }
        var result: [(AXUIElement, String, CGRect?, Bool, Bool)] = []
        for window in windows {
            guard ProcessInfo.processInfo.systemUptime < deadline, !Task.isCancelled else { break }
            guard !result.contains(where: { CFEqual($0.0, window) }), value(window, kAXRoleAttribute) as? String == kAXWindowRole else { continue }
            let title = String((value(window, kAXTitleAttribute) as? String ?? "").prefix(2048))
            let minimized = value(window, kAXMinimizedAttribute) as? Bool ?? false
            let close = element(value(window, kAXCloseButtonAttribute))
            let closeable = close.map { belongs($0, pid: pid) && value($0, kAXEnabledAttribute) as? Bool != false && supports($0, action: kAXPressAction) } ?? false
            result.append((window, title, readFrame(window), minimized, closeable))
        }
        return result
    }

    private func windowElements(pid: pid_t) -> [AXUIElement]? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.04)
        var raw: CFArray?
        guard AXUIElementCopyAttributeValues(app, kAXWindowsAttribute as CFString, 0, 64, &raw) == .success,
              let values = raw as? [AXUIElement] else { return nil }
        return values.filter { belongs($0, pid: pid) }
    }

    private func value(_ target: AXUIElement, _ attribute: String) -> CFTypeRef? {
        AXUIElementSetMessagingTimeout(target, 0.03)
        var raw: CFTypeRef?
        guard AXUIElementCopyAttributeValue(target, attribute as CFString, &raw) == .success else { return nil }
        return raw
    }

    private func element(_ raw: CFTypeRef?) -> AXUIElement? {
        guard let raw, CFGetTypeID(raw) == AXUIElementGetTypeID() else { return nil }
        return raw as! AXUIElement
    }

    private func belongs(_ element: AXUIElement, pid: pid_t) -> Bool {
        var actual: pid_t = 0
        return AXUIElementGetPid(element, &actual) == .success && actual == pid
    }

    private func supports(_ element: AXUIElement, action: String) -> Bool {
        var actions: CFArray?
        return AXUIElementCopyActionNames(element, &actions) == .success && (actions as? [String] ?? []).contains(action)
    }

    private func readFrame(_ target: AXUIElement) -> CGRect? {
        guard let position = value(target, kAXPositionAttribute), let size = value(target, kAXSizeAttribute),
              CFGetTypeID(position) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var point = CGPoint.zero, dimensions = CGSize.zero
        guard AXValueGetValue(position as! AXValue, .cgPoint, &point), AXValueGetValue(size as! AXValue, .cgSize, &dimensions) else { return nil }
        let frame = CGRect(origin: point, size: dimensions)
        return DesktopOverviewPolicy.sameGeometry(frame, frame) ? frame : nil
    }

    private func isFocused(_ target: AXUIElement, pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        return element(value(app, kAXFocusedWindowAttribute)).map { CFEqual($0, target) } ?? false
    }

    private func makeEntry(id: String, app: NSRunningApplication, title: String, frame: CGRect?, minimized: Bool,
                           canFocus: Bool, canClose: Bool, created: TimeInterval, generation: UUID, detail: String) -> DesktopOverviewEntry {
        DesktopOverviewEntry(id: id, appName: app.localizedName ?? app.bundleIdentifier ?? "应用", title: title,
                             bundleID: app.bundleIdentifier ?? "", pid: app.processIdentifier,
                             icon: app.icon ?? NSImage(named: NSImage.applicationIconName) ?? NSImage(size: NSSize(width: 32, height: 32)),
                             frame: frame, isMinimized: minimized, canFocus: canFocus, canClose: canClose, detail: detail,
                             createdAt: created, generation: generation)
    }

    private func isCurrent(_ request: UUID) -> Bool { isSessionActive && generation == request && !Task.isCancelled }

    private func invalidate(_ message: String) {
        generation = UUID(); operation = UUID(); operationInitialPID = nil
        catalogTask?.cancel(); catalogTask = nil
        operationTask?.cancel(); operationTask = nil
        isLoading = false; isBusy = false
        releasePreviews()
        handles.removeAll(); entries.removeAll(); selectedID = nil
        status = message
    }

    private func observe(_ center: NotificationCenter, _ name: Notification.Name, body: @escaping @MainActor () -> Void) {
        let token = center.addObserver(forName: name, object: nil, queue: .main) { _ in Task { @MainActor in body() } }
        observers.append((center, token))
    }

    deinit {
        catalogTask?.cancel(); operationTask?.cancel(); previewTask?.cancel(); previewExpiryTask?.cancel()
        for (center, token) in observers { center.removeObserver(token) }
    }
}

extension DesktopOverviewController {
    func cachedPreview(for entry: DesktopOverviewEntry) -> NSImage? {
        guard isSessionActive, entry.generation == generation, preferences.thumbnailsEnabled,
              !preferences.excludedThumbnailBundleIDs.contains(entry.bundleID),
              !IsSecureEventInputEnabled(), CGPreflightScreenCaptureAccess(), AXIsProcessTrusted(),
              let preview = previews[entry.id] else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        guard now >= preview.created, now - preview.created < DesktopOverviewPolicy.previewLifetime else { return nil }
        return preview.image
    }

    func releasePreviews() {
        previewRequest = nil
        previewTask?.cancel(); previewTask = nil
        previewExpiryTask?.cancel(); previewExpiryTask = nil
        previews.removeAll(); isCapturingPreviews = false
        previewRevision &+= 1
    }

    /// A batch is finite, serial, and requires a new click for every batch. Old settings never imply session consent.
    func capturePreviews() {
        guard !isLoading, !isBusy, !isCapturingPreviews else { return }
        refreshPermissions()
        guard DesktopOverviewPolicy.previewAllowed(sessionActive: isSessionActive, explicitlyRequested: true,
                enabled: preferences.thumbnailsEnabled, screenAuthorized: screenCaptureGranted,
                accessibilityAuthorized: accessibilityGranted, secureInput: IsSecureEventInputEnabled(), excluded: false) else {
            previewStatus = "生成预览需要开启预览、辅助功能和屏幕录制授权；未授权时继续使用图标。"
            return
        }
        guard !nativeCaptureInFlight, !shareableInFlight else { previewStatus = "系统上次预览请求尚未返回，请稍后重试。"; return }
        releasePreviews()
        let request = UUID(), catalog = generation
        previewRequest = request
        isCapturingPreviews = true
        previewTask = Task { [weak self] in await self?.captureBatch(request: request, catalog: catalog) }
    }

    private func previewGate(_ request: UUID, catalog: UUID, bundleID: String = "") -> Bool {
        !Task.isCancelled && generation == catalog && previewRequest == request &&
        DesktopOverviewPolicy.previewAllowed(sessionActive: isSessionActive, explicitlyRequested: previewRequest != nil,
            enabled: preferences.thumbnailsEnabled, screenAuthorized: CGPreflightScreenCaptureAccess(),
            accessibilityAuthorized: AXIsProcessTrusted(), secureInput: IsSecureEventInputEnabled(),
            excluded: preferences.excludedThumbnailBundleIDs.contains(bundleID) || preferences.excludedApplicationBundleIDs.contains(bundleID))
    }

    private func captureBatch(request: UUID, catalog: UUID) async {
        defer { if previewRequest == request { isCapturingPreviews = false; previewTask = nil } }
        previewStatus = "正在生成一次静态预览…"
        guard previewGate(request, catalog: catalog), let content = await shareableContent(), previewGate(request, catalog: catalog) else {
            if previewRequest == request { previewStatus = "系统未返回可用窗口，继续使用应用图标。" }
            return
        }
        var budget = DesktopOverviewPreviewBudget()
        let deadline = ProcessInfo.processInfo.systemUptime + 5
        let sources = content.windows.filter { $0.windowLayer == 0 && $0.isOnScreen && $0.owningApplication?.processID != ownPID }
        let ordered: [DesktopOverviewEntry]
        if let selected = selectedEntry { ordered = [selected] + entries.filter { $0.id != selected.id } }
        else { ordered = entries }
        for entry in ordered {
            guard previewGate(request, catalog: catalog), ProcessInfo.processInfo.systemUptime < deadline,
                  budget.count < DesktopOverviewPolicy.maximumPreviews else { break }
            guard entry.canFocus, !entry.isMinimized, !entry.title.isEmpty, let frame = entry.frame,
                  previewGate(request, catalog: catalog, bundleID: entry.bundleID),
                  let target = try? validTarget(entry), let currentFrame = readFrame(target.element),
                  value(target.element, kAXTitleAttribute) as? String == entry.title,
                  DesktopOverviewPolicy.sameGeometry(frame, currentFrame) else { continue }
            let peers = sources.filter { $0.owningApplication?.processID == entry.pid && $0.owningApplication?.bundleIdentifier == entry.bundleID }
            let evidence = DesktopOverviewEvidence(title: entry.title, frame: frame)
            guard let currentWindows = windowElements(pid: entry.pid) else { continue }
            let axPeers = currentWindows.compactMap { window -> DesktopOverviewEvidence? in
                guard let currentFrame = readFrame(window), let title = value(window, kAXTitleAttribute) as? String else { return nil }
                return DesktopOverviewEvidence(title: title, frame: currentFrame)
            }
            let capturePeers = peers.map { DesktopOverviewEvidence(title: $0.title ?? "", frame: $0.frame) }
            guard DesktopOverviewPolicy.uniquePreviewMatch(source: evidence, axPeers: axPeers, capturePeers: capturePeers),
                  let source = peers.first(where: { $0.title == entry.title && DesktopOverviewPolicy.sameGeometry($0.frame, frame) }),
                  freshScreenEvidence(source, entry: entry) else { continue }
            let configuration = SCStreamConfiguration()
            let scale = min(1, 640 / frame.width, 400 / frame.height)
            configuration.width = max(1, Int(frame.width * scale))
            configuration.height = max(1, Int(frame.height * scale))
            configuration.showsCursor = false
            configuration.capturesAudio = false
            guard budget.reserve(pixels: configuration.width * configuration.height),
                  ProcessInfo.processInfo.systemUptime < deadline,
                  previewGate(request, catalog: catalog, bundleID: entry.bundleID),
                  (try? validTarget(entry)) != nil else { continue }
            guard let cgImage = await captureImage(source, configuration: configuration) else {
                if nativeCaptureInFlight { break } // A timeout does not release an unreturned native request slot.
                continue
            }
            guard previewGate(request, catalog: catalog, bundleID: entry.bundleID),
                  let checked = try? validTarget(entry), let current = readFrame(checked.element),
                  value(checked.element, kAXTitleAttribute) as? String == entry.title,
                  DesktopOverviewPolicy.sameGeometry(frame, current), freshScreenEvidence(source, entry: entry),
                  cgImage.width > 0, cgImage.height > 0, cgImage.width <= 640, cgImage.height <= 400 else { continue }
            previews[entry.id] = Preview(image: NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height)), created: ProcessInfo.processInfo.systemUptime)
            previewRevision &+= 1
        }
        guard previewGate(request, catalog: catalog) else { return }
        previewStatus = "已生成 \(previews.count) 张静态预览 · 最多12张/600万像素 · 15秒后清除；排除、透明、离屏或映射不明的窗口使用图标。"
        let oldest = previews.values.map(\.created).min() ?? ProcessInfo.processInfo.systemUptime
        let remaining = max(0.001, DesktopOverviewPolicy.previewLifetime - (ProcessInfo.processInfo.systemUptime - oldest))
        previewExpiryTask = Task { [weak self] in
            do { try await Task.sleep(for: .seconds(remaining)) } catch { return }
            guard let self, self.previewRequest == request else { return }
            self.releasePreviews()
            self.previewStatus = "静态预览已清除。再次点击生成才会读取窗口内容。"
        }
    }

    private func freshScreenEvidence(_ source: SCWindow, entry: DesktopOverviewEntry) -> Bool {
        guard let frame = entry.frame,
              let row = (CGWindowListCopyWindowInfo([.optionIncludingWindow], source.windowID) as? [[String: Any]])?.first,
              (row[kCGWindowNumber as String] as? NSNumber)?.uint32Value == source.windowID,
              (row[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value == entry.pid,
              row[kCGWindowName as String] as? String == entry.title,
              let bounds = row[kCGWindowBounds as String] as? NSDictionary, let current = CGRect(dictionaryRepresentation: bounds),
              DesktopOverviewPolicy.sameGeometry(current, frame) else { return false }
        return DesktopOverviewPolicy.eligibleScreenWindow(onScreen: row[kCGWindowIsOnscreen as String] as? Bool ?? false,
            alpha: (row[kCGWindowAlpha as String] as? NSNumber)?.doubleValue,
            layer: (row[kCGWindowLayer as String] as? NSNumber)?.intValue, frame: current)
    }

    private func shareableContent() async -> SCShareableContent? {
        guard !shareableInFlight else { return nil }
        shareableInFlight = true
        return await withCheckedContinuation { continuation in
            let once = DesktopOverviewOneShot<SCShareableContent?>(continuation)
            once.timeout(seconds: 2, value: nil)
            SCShareableContent.getExcludingDesktopWindows(true, onScreenWindowsOnly: true) { [weak self] content, _ in
                Task { @MainActor in self?.shareableInFlight = false; once.finish(content) }
            }
        }
    }

    private func captureImage(_ source: SCWindow, configuration: SCStreamConfiguration) async -> CGImage? {
        guard !nativeCaptureInFlight else { return nil }
        nativeCaptureInFlight = true
        return await withCheckedContinuation { continuation in
            let once = DesktopOverviewOneShot<CGImage?>(continuation)
            once.timeout(seconds: 1.5, value: nil)
            SCScreenshotManager.captureImage(contentFilter: SCContentFilter(desktopIndependentWindow: source), configuration: configuration) { [weak self] image, _ in
                Task { @MainActor in self?.nativeCaptureInFlight = false; once.finish(image) }
            }
        }
    }
}

/// Native callbacks may never arrive; continuation completion and native concurrency accounting are separate.
@MainActor private final class DesktopOverviewOneShot<Value> {
    private var continuation: CheckedContinuation<Value, Never>?
    private var timer: Task<Void, Never>?
    init(_ continuation: CheckedContinuation<Value, Never>) { self.continuation = continuation }
    func finish(_ value: Value) {
        guard let continuation else { return }
        self.continuation = nil; timer?.cancel(); timer = nil
        continuation.resume(returning: value)
    }
    func timeout(seconds: Double, value: Value) {
        timer = Task { [self] in
            do { try await Task.sleep(for: .seconds(seconds)) } catch { return }
            guard !Task.isCancelled else { return }
            finish(value)
        }
    }
}
