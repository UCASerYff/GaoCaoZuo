import Foundation

/// The panel, rule editors and descriptor registry share these production IDs.
enum ExtensionActionCatalog {
    static var actions: [OperationAction] {
        var result: [OperationAction] = [
            .init(id: "inputsource.switch.abc", title: "切换至首选输入法", detail: "使用自动输入法设置中明确选择的第一项", icon: "keyboard", section: .input),
            .init(id: "inputsource.switch.pinyin", title: "切换至第二输入法", detail: "使用明确选择的第二项，不猜测语言", icon: "keyboard", section: .input),
            .init(id: "inputsource.toggle", title: "切换指定的两个输入法", detail: "缺失来源时停止并保留配置", icon: "arrow.left.arrow.right", section: .input),
            .init(id: "inputsource.settings", title: "自动输入法设置", detail: "按应用与输入区域配置规则", icon: "character.cursor.ibeam", section: .input),
            .init(id: "flykey.show", title: "快捷键速查", detail: "查看目标应用原生菜单与用户规则", icon: "command", section: .input),
            .init(id: "flykey.settings", title: "快捷键速查设置", detail: "配置双击修饰键，不拦截正常组合键", icon: "keyboard", section: .input),
            .init(id: "cleaner.start", title: "键盘与屏幕清洁模式", detail: "先验证实体退出键，再启动限时遮罩", icon: "sparkles", section: .tools),
            .init(id: "selection.bar.show", title: "显示划词快捷条", detail: "使用打开面板前捕获的选区", icon: "text.cursor", section: .tools),
            .init(id: "selection.clipboard.show", title: "用当前剪贴板打开文字工具", detail: "明确读取当前剪贴板，不回写应用选区", icon: "doc.on.clipboard", section: .tools),
            .init(id: "snippet.manager.show", title: "常用短语管理", detail: "分组、富内容、CSV 与 Excel 文本表格", icon: "text.badge.plus", section: .clipboard),
            .init(id: "snippet.paste.last", title: "粘贴最近使用的短语", detail: "仅在已选择过短语后执行", icon: "text.insert", section: .clipboard),
            .init(id: "clipboard.stack.push", title: "当前剪贴板加入粘贴堆栈", detail: "用户明确加入，不启用历史采集", icon: "square.stack.3d.up", section: .clipboard),
            .init(id: "clipboard.stack.paste", title: "粘贴堆栈顶部内容", detail: "确认内容插入后才弹出，失败保留", icon: "square.stack.3d.down.right", section: .clipboard),
            .init(id: "clipboard.stack.merge", title: "合并复制堆栈文字", detail: "按顺序换行合并，保留堆栈；富附件逐项处理", icon: "text.append", section: .clipboard),
            .init(id: "clipboard.stack.clear", title: "清空粘贴堆栈", detail: "仅清除此应用中明确加入的堆栈", icon: "trash", section: .clipboard),
            .init(id: "clipboard.clear", title: "清除未固定的剪贴板历史", detail: "固定项目保留", icon: "trash", section: .clipboard)
        ]
        for (id, title) in selectionActions {
            result.append(.init(id: "selection." + id, title: title, detail: "使用原选区；失效时显示原因", icon: "text.cursor", section: .tools))
        }
        return result
    }
    static let selectionActions: [(String, String)] = [
        ("search", "搜索选中文字"), ("translate", "翻译选中文字"), ("sendToFiles", "将选中文字交给搞文件"),
        ("copy", "复制选中文字"), ("qrcode", "选中文字转二维码"), ("stats", "选中文字统计"),
        ("uppercase", "选中文字转大写"), ("lowercase", "选中文字转小写"), ("titleCase", "选中文字词首大写"),
        ("toHalfWidth", "选中文字转半角"), ("toFullWidth", "选中文字转全角"),
        ("cleanupWhitespace", "清理选中文字空白"), ("base64Encode", "选中文字 Base64 编码"),
        ("base64Decode", "选中文字 Base64 解码"), ("urlEncode", "选中文字 URL 编码"),
        ("urlDecode", "选中文字 URL 解码"), ("speak", "朗读选中文字"),
        ("saveSnippet", "将选中文字存为短语"), ("saveClipboard", "将选中文字存入剪贴板历史")
    ]
}
