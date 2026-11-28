import AppKit
import ApplicationServices
import Carbon
import Combine

enum InputTrigger: String, Codable, CaseIterable, Identifiable {
    case hotkey, mouseButton, gesture
    var id: String { rawValue }
    var title: String {
        switch self { case .hotkey: return L10n.text("快捷键"); case .mouseButton: return L10n.text("鼠标按钮"); case .gesture: return L10n.text("绘图手势") }
    }
}

struct InputBinding: Codable, Identifiable, Equatable {
    var id: UUID
    var actionID: String
    var trigger: InputTrigger
    var keyCode: UInt16
    var modifiers: UInt64
    var mouseButton: Int
    var direction: String
    var appBundleID: String
    var enabled: Bool

    init(id: UUID = UUID(), actionID: String = "panel.show", trigger: InputTrigger = .hotkey,
         keyCode: UInt16 = 31, modifiers: UInt64? = nil, mouseButton: Int = 2,
         direction: String = "right", appBundleID: String = "", enabled: Bool = true) {
        self.id = id; self.actionID = actionID; self.trigger = trigger; self.keyCode = keyCode
        self.modifiers = modifiers ?? (trigger == .hotkey ? UInt64(NSEvent.ModifierFlags([.option, .command]).rawValue)
                                      : trigger == .gesture ? UInt64(NSEvent.ModifierFlags.option.rawValue) : 0)
        self.mouseButton = mouseButton; self.direction = direction; self.appBundleID = appBundleID; self.enabled = enabled
    }

    static var defaults: [InputBinding] {
        [InputBinding(), InputBinding(actionID: "window.leftHalf", trigger: .gesture, direction: "left", enabled: false),
         InputBinding(actionID: "window.rightHalf", trigger: .gesture, direction: "right", enabled: false)]
    }
    var title: String { actionID == "panel.show" ? L10n.text("打开操作面板") : actionID }
    var triggerDescription: String {
        let flags = NSEvent.ModifierFlags(rawValue: UInt(modifiers))
        let prefix = (flags.contains(.control) ? "⌃" : "") + (flags.contains(.option) ? "⌥" : "")
            + (flags.contains(.shift) ? "⇧" : "") + (flags.contains(.command) ? "⌘" : "")
        switch trigger {
        case .hotkey: return prefix + Self.keyLabel(keyCode)
        case .mouseButton: return prefix + (mouseButton == 2 ? L10n.text("鼠标中键") : L10n.format("鼠标按钮 %ld",mouseButton + 1))
        case .gesture:
            let label = ["left": "向左", "right": "向右", "up": "向上", "down": "向下"][direction] ?? direction
            return prefix + L10n.text("右键拖动") + L10n.text(label)
        }
    }
    static func keyLabel(_ code: UInt16) -> String {
        let labels: [UInt16: String] = [0:"A",1:"S",2:"D",3:"F",4:"H",5:"G",6:"Z",7:"X",8:"C",9:"V",11:"B",12:"Q",13:"W",14:"E",15:"R",16:"Y",17:"T",18:"1",19:"2",20:"3",21:"4",22:"6",23:"5",24:"=",25:"9",26:"7",27:"-",28:"8",29:"0",30:"]",31:"O",32:"U",33:"[",34:"I",35:"P",36:"↩",37:"L",38:"J",39:"'",40:"K",41:";",42:"\\",43:",",44:"/",45:"N",46:"M",47:".",48:"⇥",49:"空格",50:"`",51:"⌫",53:"⎋",96:"F5",97:"F6",98:"F7",99:"F3",100:"F8",101:"F9",103:"F11",109:"F10",111:"F12",118:"F4",120:"F2",122:"F1",123:"←",124:"→",125:"↓",126:"↑"]
        return labels[code].map{L10n.text($0)} ?? L10n.format("键码 %ld",Int(code))
    }
}

enum InputRules {
    static let modifierMask = UInt64(NSEvent.ModifierFlags([.command, .option, .control, .shift, .function]).rawValue)
    static func signature(_ binding: InputBinding) -> String {
        let detail: String
        switch binding.trigger {
        case .hotkey: detail = String(binding.keyCode)
        case .mouseButton: detail = String(binding.mouseButton)
        case .gesture: detail = binding.direction
        }
        return "\(binding.trigger.rawValue):\(binding.modifiers & modifierMask):\(detail):\(binding.appBundleID)"
    }
    /// The HUD and the runtime use the same specificity rule. Keep same-scope
    /// duplicates for conflict reporting; hide a global trigger shadowed by this App.
    static func effectiveBindings(in bindings:[InputBinding],appBundleID:String)->[InputBinding] {
        let active=bindings.filter{$0.enabled && ($0.appBundleID.isEmpty || $0.appBundleID==appBundleID)}
        func triggerKey(_ value:InputBinding)->String {var key=value;key.appBundleID="";return signature(key)}
        let specific=Set(active.filter{!$0.appBundleID.isEmpty}.map(triggerKey))
        return active.filter{!$0.appBundleID.isEmpty || !specific.contains(triggerKey($0))}
    }
    static func conflictingIDs(in bindings: [InputBinding]) -> Set<UUID> {
        let groups = Dictionary(grouping: bindings.filter(\.enabled), by: signature)
        return Set(groups.values.filter { $0.count > 1 }.flatMap { $0.map(\.id) })
    }
    static func validationError(_ binding: InputBinding) -> String? {
        guard !binding.actionID.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return L10n.text("未选择动作") }
        switch binding.trigger {
        case .hotkey:
            // Unmodified ordinary keys must remain typing keys.
            guard binding.modifiers & modifierMask != 0 else { return L10n.text("快捷键至少需要一个修饰键") }
        case .mouseButton:
            guard (2...31).contains(binding.mouseButton) else { return L10n.text("鼠标映射仅支持中键及额外按钮（编号 2–31）") }
        case .gesture:
            guard binding.modifiers & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0 else { return L10n.text("绘图手势必须包含 Option 修饰键") }
            guard ["left", "right", "up", "down"].contains(binding.direction) else { return L10n.text("手势方向无效") }
        }
        return nil
    }
    static func direction(from start: CGPoint, to end: CGPoint, threshold: CGFloat = 70) -> String? {
        let dx = end.x - start.x, dy = end.y - start.y
        guard hypot(dx, dy) >= threshold else { return nil }
        if abs(dx) > abs(dy) * 1.4 { return dx > 0 ? "right" : "left" }
        if abs(dy) > abs(dx) * 1.4 { return dy > 0 ? "down" : "up" }
        return nil
    }
    static func match(in bindings: [InputBinding], trigger: InputTrigger, modifiers: UInt64,
                      keyCode: UInt16 = 0, mouseButton: Int = 0, direction: String = "", appBundleID: String) -> InputBinding? {
        let effective=effectiveBindings(in:bindings,appBundleID:appBundleID)
        let conflicts=conflictingIDs(in:effective)
        let matching = effective.filter {
            guard !conflicts.contains($0.id),validationError($0)==nil,$0.enabled, $0.trigger == trigger, $0.modifiers & modifierMask == modifiers & modifierMask,
                  $0.appBundleID.isEmpty || $0.appBundleID == appBundleID else { return false }
            switch trigger { case .hotkey: return $0.keyCode == keyCode; case .mouseButton: return $0.mouseButton == mouseButton; case .gesture: return $0.direction == direction }
        }
        return matching.first { !$0.appBundleID.isEmpty } ?? matching.first
    }
}

struct InputListenerAuthorization:Equatable {
    var monitoring:Bool
    var accessibility:Bool
    var available:Bool {monitoring || accessibility}
}
struct InputTapState {
    var authorization:InputListenerAuthorization?
    var active:Bool
    var portValid:Bool
    var sourceValid:Bool
    var enabled:Bool
}
enum InputTapLifecycle {
    enum Decision {case stop,install,keep,rebuild}
    static func shouldRecoverDisabledTap(triggerGeneration:UInt64,currentGeneration:UInt64,hasTap:Bool)->Bool {
        hasTap && triggerGeneration == currentGeneration
    }
    static func decision(running:Bool,paused:Bool,hasWork:Bool,authorization:InputListenerAuthorization,
                         wantsActive:Bool,tap:InputTapState?)->Decision {
        guard running,!paused,hasWork,authorization.available else{return .stop}
        guard let tap else{return .install}
        guard tap.portValid,tap.sourceValid,tap.enabled,tap.authorization == authorization,
              tap.active == wantsActive else{return .rebuild}
        return .keep
    }
}

enum InputTapEvents {
    static func bit(_ type: CGEventType) -> CGEventMask { CGEventMask(1) << type.rawValue }
    static let autoInput = bit(.keyDown)
    static let flyKey = mask([.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown])
    private static let buttons = mask([.leftMouseDown, .leftMouseUp, .leftMouseDragged,
                                       .rightMouseDown, .rightMouseUp, .rightMouseDragged,
                                       .otherMouseDown, .otherMouseUp, .otherMouseDragged])
    private static let advanced = buttons | mask([.keyDown, .keyUp, .flagsChanged, .scrollWheel])

    private static func mask(_ types: [CGEventType]) -> CGEventMask {
        types.reduce(0) { $0 | bit($1) }
    }

    static func basic(bindings: [InputBinding], windows: Bool) -> CGEventMask {
        var events = windows ? mask([.leftMouseDown, .leftMouseDragged, .leftMouseUp]) : 0
        for binding in bindings where binding.enabled {
            switch binding.trigger {
            case .hotkey: events |= bit(.keyDown)
            case .mouseButton: events |= bit(.otherMouseDown)
            case .gesture: events |= mask([.rightMouseDown, .rightMouseDragged, .rightMouseUp])
            }
        }
        return events
    }

    static func enhanced(enabled: Bool, hotCorners: Bool) -> CGEventMask {
        guard enabled else { return 0 }
        return advanced | (hotCorners ? bit(.mouseMoved) : 0)
    }

    static let cleaner = advanced | bit(.mouseMoved)
}

/// Native title-bar dragging is enabled by snapping alone; Option movement is an independent feature.
enum WindowInputPolicy {
    enum StartMode {case nativeSnap,optionMove}
    static func startMode(dragEnabled:Bool,snapEnabled:Bool,optionDown:Bool)->StartMode? {
        if dragEnabled && optionDown {return .optionMove}
        return snapEnabled ? .nativeSnap : nil
    }
    static func needsEvents(windowsConnected:Bool,dragEnabled:Bool,snapEnabled:Bool)->Bool {
        windowsConnected && (dragEnabled || snapEnabled)
    }
    static func canContinue(capturedPID:pid_t?,frontPID:pid_t?,paused:Bool,running:Bool,excluded:Bool)->Bool {
        guard let capturedPID,capturedPID>0,let frontPID,frontPID==capturedPID else{return false}
        return !paused && running && !excluded
    }
}

@MainActor
final class InputController: ObservableObject {
    @Published private(set) var permissionGranted = CGPreflightListenEventAccess() || AXIsProcessTrusted()
    @Published private(set) var isPaused = false
    @Published private(set) var lastError: String?
    private var bindings: [InputBinding] = []
    private var handler: ((String) -> Void)?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var installedAuthorization:InputListenerAuthorization?
    private var installedActiveTap=false
    private var installedEventMask: CGEventMask = 0
    private var basicEventMask: CGEventMask = 0
    private var enhancedEventMask: CGEventMask = 0
    private var tapGeneration:UInt64=0
    private var timer: Timer?
    private var configurationError: String?
    private var windowInputError: String?
    private var excludedApps: Set<String> = []
    private weak var windows: WindowManager?
    private var windowDragEnabled = false
    private var windowSnapEnabled = false
    private var windowDragToken: UUID?
    private var windowDragPID: pid_t?
    private var movingWindowWithPointer = false
    private var lastWindowUpdate: TimeInterval = 0
    private var gestureStart: (point: CGPoint, flags: UInt64, app: String)?
    private var desiredRunning = false
    private var autoInputEvents = false
    private var flyKeyEvents = false
    private var lifecycleObservers:[NSObjectProtocol]=[]
    private var sleepingOrInactive=false
    var onPauseChanged: ((Bool) -> Void)?
    var hostedInputIsExclusive:(()->Bool)? {didSet{enhanced.hostedInputIsExclusive=hostedInputIsExclusive}}
    var hostedCaptureBlockingReason:String? {enhanced.hostedCaptureBlockingReason}
    private var yieldedHostedInput=false
    private var hostedInputGeneration=HostedInputGeneration()
    func yieldPendingInputForCapture() {
        hostedInputGeneration.invalidate()
        gestureStart=nil;cancelWindowInput();enhanced.yieldPendingInputToHost()
        yieldedHostedInput=true
    }
    private let enhanced = EnhancedInputEngine()
    private var enhancementError: String?
    private var tapModeError:String?
    @Published private(set) var enhancementStatus = "高级输入未启用"
    @Published private(set) var touchDevices: [String] = []

    func configure(bindings: [InputBinding], excludedApps: [String] = [], windows: WindowManager? = nil,
                   windowDragEnabled: Bool = false, windowSnapEnabled: Bool = false, enhancements: InputEnhancementConfiguration = .init(), invocationHandler: ((String,InputWindowTargetMode)->Void)? = nil, handler: @escaping (String) -> Void) {
        tearDownTap()
        let conflicting = InputRules.conflictingIDs(in: bindings)
        let invalid = bindings.filter { $0.enabled && InputRules.validationError($0) != nil }
        self.bindings = bindings.filter { $0.enabled && InputRules.validationError($0) == nil }
        self.handler = handler
        enhancementError = nil
        enhanced.configure(enhancements, excludedApps: Set(excludedApps), handler: handler) { [weak self] message in
            self?.enhancementError = message; self?.updateCombinedError()
        }
        enhanced.invocationHandler=invocationHandler
        self.excludedApps = Set(excludedApps)
        self.windows = windows
        self.windowDragEnabled = windowDragEnabled
        self.windowSnapEnabled = windowSnapEnabled
        windowInputError = nil
        var messages: [String] = []
        if !conflicting.isEmpty { messages.append(L10n.format("%@ 条输入规则存在同一应用内的触发冲突，已暂停这些规则。", String(describing: (conflicting.count)))) }
        if let first = invalid.first { messages.append(L10n.format("%@：%@，已暂停该规则。", String(describing: (first.triggerDescription)), String(describing: (InputRules.validationError(first) ?? "规则无效")))) }
        if (windowDragEnabled || windowSnapEnabled), windows == nil { messages.append("窗口拖动或吸附尚未连接窗口管理器，功能未启动。") }
        configurationError = messages.isEmpty ? nil : messages.joined(separator: "\n")
        lastError = configurationError
        start()
    }

    func pause(_ paused: Bool) {
        isPaused = paused
        gestureStart = nil
        if paused { refreshPermission() } else { start() }
        onPauseChanged?(paused)
    }
    func configureExtensionDemand(autoInput: Bool, flyKey: Bool) {
        autoInputEvents = autoInput
        flyKeyEvents = flyKey
        refreshPermission()
    }
    func refreshExtensionDemand() { refreshPermission() }

    func requestPermission() {
        _ = CGRequestListenEventAccess()
        refreshPermission()
        if !permissionGranted {
            lastError = "请在系统设置的“隐私与安全性 → 输入监控”中允许搞操作。授权后会自动重试。"
        }
    }

    func start() {
        desiredRunning = true
        if lifecycleObservers.isEmpty {
            let center=NSWorkspace.shared.notificationCenter
            for name in [NSWorkspace.willSleepNotification,NSWorkspace.sessionDidResignActiveNotification] {
                lifecycleObservers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.sleepingOrInactive = true
                        self?.timer?.invalidate()
                        self?.timer = nil
                        self?.tearDownTap()
                        FlyKeyController.shared.resetTapDetector()
                    }
                })
            }
            for name in [NSWorkspace.didWakeNotification,NSWorkspace.sessionDidBecomeActiveNotification] {
                lifecycleObservers.append(center.addObserver(forName:name,object:nil,queue:.main) { [weak self] _ in
                    MainActor.assumeIsolated {self?.sleepingOrInactive=false;self?.refreshPermission()}
                })
            }
        }
        refreshPermission()
    }

    func stop() {
        desiredRunning = false
        for token in lifecycleObservers {NSWorkspace.shared.notificationCenter.removeObserver(token)}
        lifecycleObservers=[];sleepingOrInactive=false
        timer?.invalidate(); timer = nil
        tearDownTap()
    }

    private func refreshPermission() {
        let authorization=InputListenerAuthorization(monitoring:CGPreflightListenEventAccess(),accessibility:AXIsProcessTrusted())
        if permissionGranted != authorization.available { permissionGranted = authorization.available }
        let needsWindows = WindowInputPolicy.needsEvents(windowsConnected:windows != nil,dragEnabled:windowDragEnabled,snapEnabled:windowSnapEnabled)
        let cleaner = CleanerController.shared
        basicEventMask = InputTapEvents.basic(bindings: bindings, windows: needsWindows)
        enhancedEventMask = InputTapEvents.enhanced(enabled: enhanced.needsEvents, hotCorners: enhanced.needsPointerMotion)
        var mask = basicEventMask | enhancedEventMask
        if autoInputEvents { mask |= InputTapEvents.autoInput }
        if flyKeyEvents { mask |= InputTapEvents.flyKey }
        if cleaner.needsInputEvents { mask |= InputTapEvents.cleaner }
        let hasWork = mask != 0
        let running = desiredRunning && !sleepingOrInactive
        if running && !isPaused && hasWork {
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 3, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshPermission() }
                }
                timer?.tolerance = 0.5
            }
        } else {
            timer?.invalidate()
            timer = nil
        }
        let wantsActive=(enhanced.needsActiveTap || cleaner.needsInputEvents) && authorization.accessibility
        let state:InputTapState?=tap.map {port in
            let valid=CFMachPortIsValid(port)
            return InputTapState(authorization:installedAuthorization,active:installedActiveTap,portValid:valid,
                                 sourceValid:source.map{CFRunLoopSourceIsValid($0)} ?? false,
                                 enabled:valid && CGEvent.tapIsEnabled(tap:port))
        }
        switch InputTapLifecycle.decision(running:running,paused:isPaused,hasWork:hasWork,
                                          authorization:authorization,wantsActive:wantsActive,tap:state) {
        case .stop:
            if tap != nil || cleaner.needsInputEvents { tearDownTap() }
            setError(desiredRunning && !isPaused && hasWork && !permissionGranted
                ? [configurationError,"快捷键、鼠标按钮与绘图手势尚未获得输入监听权限，或权限已失效。"].compactMap{$0}.joined(separator:"\n")
                : configurationError)
            return
        case .rebuild:
            tearDownTap();installTap(authorization:authorization, mask: mask)
        case .install:installTap(authorization:authorization, mask: mask)
        case .keep:
            if installedEventMask != mask { tearDownTap(); installTap(authorization:authorization, mask: mask) }
        }
        if let tap,CFMachPortIsValid(tap),CGEvent.tapIsEnabled(tap:tap) {enhanced.startMonitoring()}
        publishEnhancementState()
        if tap != nil {
            if IsSecureEventInputEnabled() {
                setError([configurationError, windowInputError, "系统正处于安全输入状态，键盘快捷键可能暂时不可用；离开密码输入后会自动恢复。"].compactMap { $0 }.joined(separator: "\n"))
            } else if needsWindows, !authorization.accessibility {
                setError([configurationError, "窗口拖动与边缘吸附需要辅助功能权限；其他已授权输入规则仍可使用。"].compactMap { $0 }.joined(separator: "\n"))
            } else { updateCombinedError() }
        }
    }

    private func installTap(authorization:InputListenerAuthorization, mask: CGEventMask) {
        let active=(enhanced.needsActiveTap || CleanerController.shared.needsInputEvents) && authorization.accessibility
        tapModeError = enhanced.needsActiveTap && !authorization.accessibility ? "按键替换、吞掉原输入和滚轮修改需要辅助功能权限；仅保留监听动作。" : nil
        let callback: CGEventTapCallBack = { _, type, event, context in
            guard let context else { return Unmanaged.passUnretained(event) }
            let controller = Unmanaged<InputController>.fromOpaque(context).takeUnretainedValue()
            let consume = MainActor.assumeIsolated { () -> Bool in
                if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {controller.receive(type:type,event:event);return false}
                if event.getIntegerValueField(.eventSourceUserData) == EnhancedInputEngine.syntheticTag { return false }
                if controller.hostedInputIsExclusive?() == true {
                    if !controller.yieldedHostedInput {controller.yieldPendingInputForCapture()}
                    return false
                }
                controller.yieldedHostedInput=false
                if CleanerController.shared.handleInputEvent(type:type,event:event) { return true }
                guard !controller.isPaused else { return false }
                let eventBit = InputTapEvents.bit(type)
                if controller.autoInputEvents, eventBit & InputTapEvents.autoInput != 0 { InputSourceCoordinator.shared.handleInputActivity(type:type,event:event) }
                if controller.flyKeyEvents, eventBit & InputTapEvents.flyKey != 0 { FlyKeyController.shared.handleInputEvent(type:type,event:event) }
                let consumed = eventBit & controller.enhancedEventMask != 0 && controller.enhanced.receive(type:type,event:event)
                if !consumed, eventBit & controller.basicEventMask != 0 { controller.receive(type:type,event:event) }
                return consumed
            }
            return consume ? nil : Unmanaged.passUnretained(event)
        }
        guard let created = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .tailAppendEventTap,
                                             options: active ? .defaultTap : .listenOnly, eventsOfInterest: mask, callback: callback,
                                             userInfo: Unmanaged.passUnretained(self).toOpaque()) else {
            setError("系统未能启动输入监听。请检查输入监控权限及其他输入工具的兼容性。")
            return
        }
        guard let createdSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, created, 0) else {
            CFMachPortInvalidate(created)
            setError("无法创建输入监听事件源。")
            return
        }
        tap = created; source = createdSource
        CleanerController.shared.inputSafety.bind(created, active:active)
        installedAuthorization=authorization;installedActiveTap=active;installedEventMask=mask
        enhanced.scrollAcceptanceTapActive=active
        CFRunLoopAddSource(CFRunLoopGetMain(), createdSource, .commonModes)
        CGEvent.tapEnable(tap: created, enable: true)
        setError(configurationError)
    }

    private func tearDownTap() {
        CleanerController.shared.inputChannelInvalidated()
        CleanerController.shared.inputSafety.bind(nil, active:false)
        tapGeneration &+= 1
        enhanced.stop()
        gestureStart = nil
        cancelWindowInput()
        if let source { CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes); CFRunLoopSourceInvalidate(source) }
        if let tap { CGEvent.tapEnable(tap: tap, enable: false); CFMachPortInvalidate(tap) }
        source = nil; tap = nil
        installedAuthorization=nil;installedActiveTap=false;installedEventMask=0;tapModeError=nil
        enhanced.scrollAcceptanceTapActive=false
        publishEnhancementState()
    }

    private func receive(type: CGEventType, event: CGEvent) {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            gestureStart = nil
            cancelWindowInput()
            guard tap != nil else{return}
            let failedGeneration=tapGeneration
            // Rebuild outside the callback, releasing held replacements and restoring every monitor.
            DispatchQueue.main.async { [weak self] in
                guard let self,InputTapLifecycle.shouldRecoverDisabledTap(triggerGeneration:failedGeneration,currentGeneration:self.tapGeneration,hasTap:self.tap != nil) else{return}
                self.tearDownTap();self.refreshPermission()
            }
            return
        }
        guard !isPaused else { return }
        // High-resolution mice can emit far more than 60 drag events per second.
        if type == .leftMouseDragged {
            guard windowDragToken != nil else { return }
            let now = ProcessInfo.processInfo.systemUptime
            guard now - lastWindowUpdate >= 1.0 / 60.0 else { return }
            lastWindowUpdate = now
        }
        let flags = event.flags.rawValue & InputRules.modifierMask
        if type == .keyDown, windowDragToken == nil, gestureStart == nil {
            let key = UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode))
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0,
                  bindings.contains(where: { $0.trigger == .hotkey && $0.keyCode == key && $0.modifiers & InputRules.modifierMask == flags })
            else { return }
        }
        let front = NSWorkspace.shared.frontmostApplication
        let app = front?.bundleIdentifier ?? ""
        guard !excludedApps.contains(app) else { gestureStart = nil; cancelWindowInput(); return }
        var matched: InputBinding?
        switch type {
        case .leftMouseDown:
            cancelWindowInput()
            guard windows != nil,let mode=WindowInputPolicy.startMode(dragEnabled:windowDragEnabled,snapEnabled:windowSnapEnabled,
                optionDown:flags & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0) else{return}
            let moveWithPointer=mode == .optionMove
            let token = UUID()
            windowDragToken = token; movingWindowWithPointer = moveWithPointer; lastWindowUpdate = 0
            windowDragPID = front?.processIdentifier
            let point = event.location
            // AX work stays outside the event-tap callback; the target is fixed for the whole drag.
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canContinueWindowInput(token), let windows = self.windows else { return }
                do {
                    guard try windows.beginWindowDrag(at: point, moveWithPointer: moveWithPointer, snapEnabled: self.windowSnapEnabled) else {
                        self.cancelWindowInput(); return
                    }
                    self.windowInputError = nil; self.updateCombinedError()
                } catch { self.failWindowInput(error) }
            }
        case .leftMouseDragged:
            guard let token = windowDragToken else { return }
            if movingWindowWithPointer, flags & UInt64(NSEvent.ModifierFlags.option.rawValue) == 0 {
                cancelWindowInput(); return
            }
            let point = event.location
            DispatchQueue.main.async { [weak self] in
                guard let self, self.canContinueWindowInput(token) else { return }
                do { try self.windows?.updateWindowDrag(to: point) }
                catch { self.failWindowInput(error) }
            }
        case .leftMouseUp:
            guard let token = windowDragToken else { return }
            if movingWindowWithPointer, flags & UInt64(NSEvent.ModifierFlags.option.rawValue) == 0 {
                cancelWindowInput(); return
            }
            let point = event.location
            // Let the target app process the final ordinary title-bar mouse event before reading its frame.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                guard let self, self.canContinueWindowInput(token) else { return }
                Task { @MainActor in
                    guard self.canContinueWindowInput(token) else { return }
                    do {
                        try await self.windows?.endWindowDrag(at: point, snap: self.windowSnapEnabled)
                        guard self.canContinueWindowInput(token) else { return }
                        self.windowInputError = self.windows?.lastError; self.updateCombinedError()
                        self.cancelWindowInput()
                    } catch {
                        guard self.canContinueWindowInput(token) else { return }
                        self.failWindowInput(error)
                    }
                }
            }
        case .flagsChanged:
            break
        case .keyDown:
            guard event.getIntegerValueField(.keyboardEventAutorepeat) == 0 else { return }
            matched = InputRules.match(in: bindings, trigger: .hotkey, modifiers: flags,
                                       keyCode: UInt16(clamping: event.getIntegerValueField(.keyboardEventKeycode)), appBundleID: app)
        case .otherMouseDown:
            matched = InputRules.match(in: bindings, trigger: .mouseButton, modifiers: flags,
                                       mouseButton: Int(event.getIntegerValueField(.mouseEventButtonNumber)), appBundleID: app)
        case .rightMouseDown:
            if flags & UInt64(NSEvent.ModifierFlags.option.rawValue) != 0 {
                gestureStart = (event.location, flags, app)
            } else { gestureStart = nil }
        case .rightMouseDragged:
            if flags != gestureStart?.flags { gestureStart = nil }
        case .rightMouseUp:
            defer { gestureStart = nil }
            if let start = gestureStart, start.flags == flags, start.app == app,
               let direction = InputRules.direction(from: start.point, to: event.location) {
                matched = InputRules.match(in: bindings, trigger: .gesture, modifiers: flags,
                                           direction: direction, appBundleID: app)
            }
        default: break
        }
        if let matched {
            // Defer work outside the event-tap callback, which the system expects to return promptly.
            let action = matched.actionID,capturedGeneration=tapGeneration,hostedGeneration=hostedInputGeneration.snapshot
            guard let front,let identity=WindowProcessIdentity.capture(pid:front.processIdentifier,launchDate:front.launchDate) else{return}
            DispatchQueue.main.async { [weak self] in
                guard let self,!self.isPaused,self.desiredRunning,!self.sleepingOrInactive,
                      self.hostedInputIsExclusive?() != true,
                      self.hostedInputGeneration.matches(hostedGeneration),
                      self.tapGeneration==capturedGeneration,!IsSecureEventInputEnabled(),
                      let current=NSWorkspace.shared.frontmostApplication,!current.isTerminated,
                      current.bundleIdentifier==app,!self.excludedApps.contains(app),
                      identity.matches(WindowProcessIdentity.capture(pid:current.processIdentifier,launchDate:current.launchDate)),
                      self.bindings.contains(where:{$0==matched}) else { return }
                self.handler?(action)
            }
        }
    }

    private func canContinueWindowInput(_ token:UUID)->Bool {
        let front=NSWorkspace.shared.frontmostApplication
        guard hostedInputIsExclusive?() != true,windowDragToken==token,WindowInputPolicy.canContinue(capturedPID:windowDragPID,frontPID:front?.processIdentifier,
            paused:isPaused,running:desiredRunning,excluded:excludedApps.contains(front?.bundleIdentifier ?? "")) else {
            if windowDragToken==token {cancelWindowInput()}
            return false
        }
        return true
    }
    private func cancelWindowInput() {
        windowDragToken = nil
        windowDragPID = nil
        movingWindowWithPointer = false
        lastWindowUpdate = 0
        windows?.cancelWindowDrag()
    }
    private func failWindowInput(_ error: Error) {
        windowInputError = error.localizedDescription
        cancelWindowInput()
        updateCombinedError()
    }
    private func updateCombinedError() {
        let messages = [configurationError, windowInputError, enhancementError,tapModeError].compactMap { $0 }
        setError(messages.isEmpty ? nil : messages.joined(separator: "\n"))
    }
    private func setError(_ value: String?) {
        if lastError != value { lastError = value }
    }
    private func publishEnhancementState() {
        let status = enhanced.capabilityStatus, devices = enhanced.touchDeviceNames
        if enhancementStatus != status { enhancementStatus = status }
        if touchDevices != devices { touchDevices = devices }
    }

    isolated deinit {
        timer?.invalidate()
        for token in lifecycleObservers {NSWorkspace.shared.notificationCenter.removeObserver(token)}
        if let source { CFRunLoopSourceInvalidate(source) }
        if let tap { CFMachPortInvalidate(tap) }
    }
}
