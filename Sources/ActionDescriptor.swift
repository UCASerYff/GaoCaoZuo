import AppKit
import ApplicationServices
import Foundation

// MARK: - ActionDescriptor & RuleContext

public enum ActionCategory: String, Codable, CaseIterable {
    case window = "window"
    case system = "system"
    case clipboard = "clipboard"
    case file = "file"
    case input = "input"
    case selection = "selection"
    case snippet = "snippet"
    case service = "service"

    public var title: String {
        switch self {
        case .window: return L10n.text("窗口管理")
        case .system: return L10n.text("系统控制")
        case .clipboard: return L10n.text("剪贴板")
        case .file: return L10n.text("文件工具")
        case .input: return L10n.text("输入与设备")
        case .selection: return L10n.text("划词动作")
        case .snippet: return L10n.text("快捷短语")
        case .service: return L10n.text("扩展服务")
        }
    }
}

public enum ActionPermission: String, Codable {
    case none = "none"
    case accessibility = "accessibility"
    case inputMonitoring = "inputMonitoring"
    case automation = "automation"

    public var title: String {
        switch self {
        case .none: return L10n.text("无需特殊权限")
        case .accessibility: return L10n.text("辅助功能")
        case .inputMonitoring: return L10n.text("输入监控")
        case .automation: return L10n.text("自动化")
        }
    }

    public var isSatisfied: Bool {
        switch self {
        case .none: return true
        case .accessibility: return AXIsProcessTrusted()
        case .inputMonitoring: return CGPreflightListenEventAccess() || AXIsProcessTrusted()
        case .automation: return true
        }
    }
}

public enum ActionContextKind: String, Codable, Hashable {
    case global = "global"
    case selection = "selection"
    case menu = "menu"
    case file = "file"
    case window = "window"
    case inputField = "inputField"
}

public enum ActionExecutionMode: String, Codable {
    case immediate = "immediate"
    case asyncTask = "asyncTask"
    case interactiveHUD = "interactiveHUD"
}

public struct ActionDescriptor: Identifiable, Equatable {
    public let id: String
    public let name: String
    public let summary: String
    public let category: ActionCategory
    public let requiredPermission: ActionPermission
    public let supportedContexts: Set<ActionContextKind>
    public let executionMode: ActionExecutionMode
    public let parameterSchema: [String: String]

    public init(id: String, name: String, summary: String = "", category: ActionCategory,
                requiredPermission: ActionPermission = .none,
                supportedContexts: Set<ActionContextKind> = [.global],
                executionMode: ActionExecutionMode = .immediate,
                parameterSchema: [String: String] = [:]) {
        self.id = id
        self.name = name
        self.summary = summary
        self.category = category
        self.requiredPermission = requiredPermission
        self.supportedContexts = supportedContexts
        self.executionMode = executionMode
        self.parameterSchema = parameterSchema
    }
}

public struct RuleContext: Equatable {
    public let frontmostBundleID: String?
    public let processLaunchIdentity: String?
    public let capturedPID: pid_t?
    public let capturedWindowID: CGWindowID?
    public let capturedWindowElement: AXUIElement?
    public let capturedElement: AXUIElement?
    public let permissionState: (accessibility: Bool, inputMonitoring: Bool)
    public let deviceCategory: String
    public let generation: UInt64
    public let timestamp: Date

    public init(frontmostBundleID: String? = nil,
                processLaunchIdentity: String? = nil,
                capturedPID: pid_t? = nil,
                capturedWindowID: CGWindowID? = nil,
                capturedWindowElement: AXUIElement? = nil,
                capturedElement: AXUIElement? = nil,
                permissionState: (accessibility: Bool, inputMonitoring: Bool) = (AXIsProcessTrusted(), CGPreflightListenEventAccess()),
                deviceCategory: String = "keyboard",
                generation: UInt64 = 0,
                timestamp: Date = Date()) {
        self.frontmostBundleID = frontmostBundleID
        self.processLaunchIdentity = processLaunchIdentity
        self.capturedPID = capturedPID
        self.capturedWindowID = capturedWindowID
        self.capturedWindowElement = capturedWindowElement
        self.capturedElement = capturedElement
        self.permissionState = permissionState
        self.deviceCategory = deviceCategory
        self.generation = generation
        self.timestamp = timestamp
    }

    @MainActor public static func captureCurrent(generation: UInt64 = 0) -> RuleContext {
        let frontApp = NSWorkspace.shared.frontmostApplication
        let pid = frontApp?.processIdentifier
        let launchIdentity = pid.flatMap { WindowProcessIdentity.auditTokenString(for: $0) }
        let focused=ClipboardPasteTarget.capture()
        return RuleContext(
            frontmostBundleID: frontApp?.bundleIdentifier,
            processLaunchIdentity: launchIdentity,
            capturedPID: pid,
            capturedWindowID: nil,
            capturedWindowElement: focused?.window,
            capturedElement: focused?.element,
            permissionState: (AXIsProcessTrusted(), CGPreflightListenEventAccess()),
            deviceCategory: "keyboard",
            generation: generation,
            timestamp: Date()
        )
    }

    /// Verifies that the context still matches before an asynchronous write is applied.
    public func matchesTarget(pid: pid_t?, bundleID: String?, generation expectedGeneration: UInt64) -> Bool {
        guard generation == expectedGeneration else { return false }
        if let capturedPID = self.capturedPID, let pid = pid, capturedPID != pid { return false }
        if let frontmostBundleID = self.frontmostBundleID, let bundleID = bundleID, frontmostBundleID != bundleID { return false }
        return true
    }

    public static func == (lhs: RuleContext, rhs: RuleContext) -> Bool {
        return lhs.frontmostBundleID == rhs.frontmostBundleID &&
               lhs.processLaunchIdentity == rhs.processLaunchIdentity &&
               lhs.capturedPID == rhs.capturedPID &&
               lhs.capturedWindowID == rhs.capturedWindowID &&
               Self.sameElement(lhs.capturedWindowElement,rhs.capturedWindowElement) &&
               Self.sameElement(lhs.capturedElement,rhs.capturedElement) &&
               lhs.permissionState.accessibility == rhs.permissionState.accessibility &&
               lhs.permissionState.inputMonitoring == rhs.permissionState.inputMonitoring &&
               lhs.deviceCategory == rhs.deviceCategory &&
               lhs.generation == rhs.generation
    }
    private static func sameElement(_ lhs:AXUIElement?,_ rhs:AXUIElement?) -> Bool {
        if let lhs,let rhs {return CFEqual(lhs,rhs)}
        return lhs == nil && rhs == nil
    }
}

// MARK: - ActionRegistry

@MainActor
public final class ActionRegistry {
    public static let shared = ActionRegistry()

    private var descriptors: [String: ActionDescriptor] = [:]

    public init() {
        registerBuiltInActions()
    }

    public func register(_ descriptor: ActionDescriptor) {
        descriptors[descriptor.id] = descriptor
    }

    public func descriptor(for id: String) -> ActionDescriptor? {
        descriptors[id]
    }

    public func allDescriptors() -> [ActionDescriptor] {
        descriptors.values.sorted { $0.id < $1.id }
    }

    public func descriptors(in category: ActionCategory) -> [ActionDescriptor] {
        descriptors.values.filter { $0.category == category }.sorted { $0.id < $1.id }
    }

    public func descriptors(for context: ActionContextKind) -> [ActionDescriptor] {
        descriptors.values.filter { $0.supportedContexts.contains(context) }.sorted { $0.id < $1.id }
    }

    private func registerBuiltInActions() {
        for action in OperationAction.all { registerOperationIfMissing(action) }
        // Window Actions
        register(ActionDescriptor(id: "window.leftHalf", name: L10n.text("左半屏"), category: .window, requiredPermission: .accessibility, supportedContexts: [.global, .window]))
        register(ActionDescriptor(id: "window.rightHalf", name: L10n.text("右半屏"), category: .window, requiredPermission: .accessibility, supportedContexts: [.global, .window]))
        register(ActionDescriptor(id: "window.topHalf", name: L10n.text("上半屏"), category: .window, requiredPermission: .accessibility, supportedContexts: [.global, .window]))
        register(ActionDescriptor(id: "window.bottomHalf", name: L10n.text("下半屏"), category: .window, requiredPermission: .accessibility, supportedContexts: [.global, .window]))
        register(ActionDescriptor(id: "window.maximize", name: L10n.text("全屏 / 最大化"), category: .window, requiredPermission: .accessibility, supportedContexts: [.global, .window]))
        register(ActionDescriptor(id: "window.center", name: L10n.text("居中窗口"), category: .window, requiredPermission: .accessibility, supportedContexts: [.global, .window]))
        register(ActionDescriptor(id: "window.restore", name: L10n.text("恢复窗口位置"), category: .window, requiredPermission: .accessibility, supportedContexts: [.global, .window]))

        // System & Panel Actions
        register(ActionDescriptor(id: "panel.show", name: L10n.text("打开操作面板"), category: .system, executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "finder.popup", name: L10n.text("访达扩展菜单"), category: .system, supportedContexts: [.file, .global]))
        register(ActionDescriptor(id: "flykey.show", name: L10n.text("FlyKey 快捷键速查"), category: .system, requiredPermission: .accessibility, executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "cleaner.start", name: L10n.text("键盘与屏幕清洁设置"), category: .system, executionMode: .interactiveHUD))

        // Input Source Actions
        register(ActionDescriptor(id: "inputsource.switch.abc", name: L10n.text("切换至首选输入法"), category: .input, executionMode: .immediate))
        register(ActionDescriptor(id: "inputsource.switch.pinyin", name: L10n.text("切换至第二输入法"), category: .input, executionMode: .immediate))
        register(ActionDescriptor(id: "inputsource.toggle", name: L10n.text("切换指定的两个输入法"), category: .input, executionMode: .immediate))

        // Clipboard Actions
        register(ActionDescriptor(id: "clipboard.show", name: L10n.text("查看剪贴板历史"), category: .clipboard, executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "clipboard.pasteplain", name: L10n.text("粘贴为纯文本"), category: .clipboard, requiredPermission: .accessibility))
        register(ActionDescriptor(id: "clipboard.copyplain", name: L10n.text("复制为纯文本"), category: .clipboard))
        register(ActionDescriptor(id: "clipboard.clear", name: L10n.text("清空剪贴板历史"), category: .clipboard))
        register(ActionDescriptor(id: "clipboard.stack.paste", name: L10n.text("粘贴堆栈：依次弹出并粘贴"), category: .clipboard, requiredPermission: .accessibility))
        register(ActionDescriptor(id: "clipboard.stack.clear", name: L10n.text("清空粘贴堆栈"), category: .clipboard))

        // Selection Actions
        register(ActionDescriptor(id: "selection.bar.show", name: L10n.text("显示划词快捷条"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection, .global], executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "selection.search", name: L10n.text("划词网页搜索"), category: .selection, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.translate", name: L10n.text("划词翻译"), category: .selection, supportedContexts: [.selection], executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "selection.qrcode", name: L10n.text("生成选中文本二维码"), category: .selection, supportedContexts: [.selection], executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "selection.stats", name: L10n.text("选中文本统计 (字数/行数)"), category: .selection, supportedContexts: [.selection], executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "selection.uppercase", name: L10n.text("转为大写"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.lowercase", name: L10n.text("转为小写"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.cleanupWhitespace", name: L10n.text("清理多余空白与换行"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.base64Encode", name: L10n.text("Base64 编码"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.base64Decode", name: L10n.text("Base64 解码"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.urlEncode", name: L10n.text("URL 编码"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.urlDecode", name: L10n.text("URL 解码"), category: .selection, requiredPermission: .accessibility, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.speak", name: L10n.text("朗读选中文本"), category: .selection, supportedContexts: [.selection]))
        register(ActionDescriptor(id: "selection.saveSnippet", name: L10n.text("存为常用短语"), category: .selection, supportedContexts: [.selection]))

        // Snippet Actions
        register(ActionDescriptor(id: "snippet.manager.show", name: L10n.text("常用短语管理"), category: .snippet, executionMode: .interactiveHUD))
        register(ActionDescriptor(id: "snippet.paste.last", name: L10n.text("粘贴上一条短语"), category: .snippet, requiredPermission: .accessibility))
    }

    func registerOperationIfMissing(_ action: OperationAction) {
        guard descriptors[action.id] == nil else { return }
        let category: ActionCategory
        switch action.section {
        case .windows: category = .window
        case .clipboard: category = action.id.hasPrefix("snippet.") ? .snippet : .clipboard
        case .files, .archives: category = .file
        case .input: category = .input
        default: category = action.id.hasPrefix("selection.") ? .selection : .system
        }
        let permission: ActionPermission = action.id.hasPrefix("window.") ? .accessibility : .none
        register(ActionDescriptor(id:action.id,name:action.title,summary:action.detail,category:category,
                                  requiredPermission:permission,supportedContexts:action.files ? [.global,.file] : [.global],
                                  executionMode:.asyncTask))
    }
}
