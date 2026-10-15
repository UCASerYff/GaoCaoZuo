import AppKit
import Carbon

@MainActor extension OperationStore {
    func confirmClipboardClear(stack:Bool)->Bool {
        guard !clipboard.hasActivePasteTransaction else {notify("请先处理当前粘贴，再清空历史或堆栈。",failed:true);showPasteReview?();return false}
        activateForDialog?()
        let alert=NSAlert();alert.messageText=L10n.text(stack ? "清空粘贴堆栈？" : "清除未固定的剪贴板历史？")
        alert.informativeText=L10n.text(stack ? "仅清除此应用中明确加入的堆栈项目；短语库和系统剪贴板不变。" : "固定内容会保留；清除会同时移除本应用保存的对应图片与富文本附件。")
        alert.addButton(withTitle:L10n.text("取消"));alert.addButton(withTitle:L10n.text("清除"))
        return alert.runModal() == .alertSecondButtonReturn
    }
    func handleSelectionAction(_ id: String) -> Bool {
        guard id.hasPrefix("selection.") else { return false }
        let snapshot: SelectionSnapshot
        if id == "selection.clipboard.show" {
            guard !IsSecureEventInputEnabled(), let text=NSPasteboard.general.string(forType:.string),
                  !text.isEmpty, text.utf8.count <= 2_000_000 else {
                notify("当前剪贴板没有可处理的文字，或安全输入正在启用。",failed:true); return true
            }
            snapshot=SelectionSnapshot(pid:0,bundleID:nil,launchIdentity:nil,element:nil,selectedText:text,range:nil,isFromClipboardFallback:true)
        } else {
            guard let captured=capturedSelection,let context=capturedRuleContext,
                  context.matchesTarget(pid:captured.pid,bundleID:captured.bundleID,generation:captured.generation),
                  context.processLaunchIdentity == captured.launchIdentity,
                  Date().timeIntervalSince(captured.timestamp) <= 60,
                  !IsSecureEventInputEnabled() else {
                notify("未捕获可用选区。请先在目标应用选择文字，再打开面板；也可明确选择剪贴板文字工具。",failed:true);return true
            }
            snapshot=captured
        }
        if id == "selection.bar.show" || id == "selection.clipboard.show" {
            SelectionActionBar.shared.showBar(snapshot:snapshot);return true
        }
        if id == "selection.stats" {
            let stats=SelectionTransformations.statistics(snapshot.selectedText)
            notify(L10n.format("字符 %ld · 非空白 %ld · 行 %ld · UTF-8 %ld 字节",stats.characterCount,stats.nonWhitespaceCount,stats.lineCount,stats.byteCount))
            return true
        }
        let actions:[String:SelectionBarAction] = [
            "search":.search,"translate":.translate,"sendToFiles":.sendToFiles,"copy":.copy,"qrcode":.qrcode,
            "uppercase":.uppercase,"lowercase":.lowercase,"titleCase":.titleCase,"toHalfWidth":.toHalfWidth,
            "toFullWidth":.toFullWidth,"cleanupWhitespace":.cleanupWhitespace,"base64Encode":.base64Encode,
            "base64Decode":.base64Decode,"urlEncode":.urlEncode,"urlDecode":.urlDecode,"speak":.speak,
            "saveSnippet":.saveSnippet,"saveClipboard":.saveClipboard
        ]
        guard let action=actions[String(id.dropFirst(10))] else { notify("未找到划词动作。",failed:true);return true }
        SelectionActionBar.shared.perform(action,snapshot:snapshot)
        return true
    }

    func executeSnippet(_ snippet: AdvancedSnippet, mode: SnippetExecutionMode? = nil) {
        guard dataHealthy else {notify(snippetLibrary.failure ?? data.failure ?? "资料保护模式，短语未执行。",failed:true);return}
        do {
            let actual=mode ?? snippet.executionMode
            if actual == .copyOnly {
                try snippetLibrary.copyToPasteboard(snippet)
                update { $0.lastSnippetID=snippet.id }
                if let failure=data.failure {throw DataFailure.message(failure)}
                notify("已复制短语")
            } else {
                let sourceChangeCount=NSPasteboard.general.changeCount
                let objects=try snippetLibrary.pasteboardItems(for:snippet)
                try clipboard.pastePreparedItems(objects,sendEnter:actual == .pasteAndEnter,sourceChangeCount:sourceChangeCount,onSubmitted:{ [weak self] in
                    guard let self else {throw DataFailure.message("短语状态已失效，未更新最近使用记录。")}
                    self.update { $0.lastSnippetID=snippet.id }
                    if let failure=self.data.failure {throw DataFailure.message(failure)}
                })
                notify(actual == .pasteAndEnter ? "正在发送粘贴；回车需确认插入后单独发送" : "正在恢复目标并粘贴短语")
            }
        } catch {notify(error.localizedDescription,failed:true)}
    }

    func performConfiguredInputSource(_ id: String) {
        guard !IsSecureEventInputEnabled() else {notify("安全输入期间不切换输入法。",failed:true);return}
        let configuration=settings.autoInput
        let target: String?
        switch id {
        case "inputsource.switch.abc": target=configuration.manualPrimarySourceID
        case "inputsource.switch.pinyin": target=configuration.manualSecondarySourceID
        case "inputsource.toggle":
            guard let first=configuration.manualPrimarySourceID,let second=configuration.manualSecondarySourceID,
                  first != second,let current=InputSourceCatalog.shared.currentInputSource() else {
                notify("请在自动输入法设置中明确选择两个不同的输入源。",failed:true);showExtensionSettings?(10);return
            }
            guard current.id == first || current.id == second else {
                notify("当前输入源不在指定的配对中；请选择首选或第二输入法动作。",failed:true);return
            }
            target=current.id == first ? second : first
        default: notify("未找到输入法动作。",failed:true);return
        }
        guard let target,let source=InputSourceCatalog.shared.availableKeyboardInputSources().first(where:{$0.id == target}) else {
            notify("指定输入源尚未选择或已不可用，原配置已保留。",failed:true);showExtensionSettings?(10);return
        }
        let success=InputSourceCatalog.shared.selectInputSource(sourceID:target)
        notify(success ? L10n.format("已请求切换至 %@",source.name) : "系统未接受输入源切换请求",failed:!success)
    }
}
