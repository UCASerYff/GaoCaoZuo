import AppKit
import SwiftUI
import Carbon

@MainActor enum ScreenshotHotkeyAdoption {
    static func applying(to settings:OperationSettings) throws -> OperationSettings {
        let modifiers=UInt64(NSEvent.ModifierFlags([.command,.option,.control]).rawValue)
        let candidates=[InputBinding(actionID:"service.capture.region",keyCode:UInt16(kVK_ANSI_2),modifiers:modifiers),
                        InputBinding(actionID:"screenshot.ocr.capture",keyCode:UInt16(kVK_ANSI_3),modifiers:modifiers)]
        var next=settings
        for candidate in candidates {
            if let same=next.bindings.first(where:{$0.actionID==candidate.actionID && InputRules.signature($0)==InputRules.signature(candidate)}) {
                guard same.enabled else {throw DataFailure.message("原截图快捷键已有停用规则，请在快捷键与手势中检查并启用；未覆盖原规则。")}
                continue
            }
            let conflicts=next.bindings.contains{$0.enabled && $0.trigger == .hotkey && $0.keyCode==candidate.keyCode && ($0.modifiers & InputRules.modifierMask)==(candidate.modifiers & InputRules.modifierMask)}
            let advanced=next.inputEnhancements.rules.contains{rule in rule.enabled && [.keyDown,.keyUp,.keyHold,.keyReplacement].contains(rule.trigger) && rule.keyCode==candidate.keyCode && (rule.modifiers & InputRules.modifierMask)==(candidate.modifiers & InputRules.modifierMask)}
            guard !conflicts && !advanced else {throw DataFailure.message("截图快捷键与现有规则冲突。请在快捷键与手势中选择新组合；原规则保留。")}
            next.bindings.append(candidate)
        }
        return next
    }
}

extension OperationStore {
    /// Source shortcuts were fixed defaults, not transferable system grants.
    /// Adopt only on this separate explicit click, preserving every conflict.
    func adoptScreenshotHotkeys() throws {
        guard dataHealthy else {throw DataFailure.message("资料保护模式下不能保存快捷键。")}
        let next=try ScreenshotHotkeyAdoption.applying(to:settings)
        try data.save(next,name:"settings.json");adoptCommittedDesktopSettings(next)
    }
}

@MainActor struct IntegratedScreenshotSettingsView:View {
    @ObservedObject var store:OperationStore
    @State private var message:String?
    var body:some View {
        VStack(alignment:.leading,spacing:8) {
            GroupBox("截图快捷键") {
                VStack(alignment:.leading,spacing:8) {
                    Text("原 ⌃⌥⌘2 区域截图、⌃⌥⌘3 静默截图 OCR 不会自动注册。可单独启用，或在快捷键与手势中选择其他组合。").font(.callout)
                    Button("单独启用原截图快捷键") {
                        do {try store.adoptScreenshotHotkeys();message="已保存规则；实际授权和注册状态见快捷键与手势。"}
                        catch {message=error.localizedDescription}
                    }.disabled(!store.dataHealthy)
                    if let message {Text(message).font(.caption).textSelection(.enabled)}
                }.frame(maxWidth:.infinity,alignment:.leading)
            }.padding([.top,.horizontal])
            store.screenshots.settingsView
        }
    }
}
