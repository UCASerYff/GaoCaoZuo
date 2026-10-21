import Foundation

/// These checks use offline representations only. They never read/write a
/// system pasteboard, activate an application, query AX or post an event.
@MainActor func runClipboardPasteTransactionTests() throws {
    var checks=0
    func check(_ value:Bool,_ name:String) throws {
        checks += 1
        guard value else {throw DataFailure.message("粘贴事务检查："+name)}
    }
    func rejects(_ name:String,_ body:() throws -> Void) throws {
        var rejected=false
        do {try body()} catch {rejected=true}
        try check(rejected,name)
    }
    let original=try ClipboardPasteboardSnapshot.captureRepresentations([
        [(type:"public.utf8-plain-text",data:Data("原始文字".utf8)),
         (type:"public.rtf",data:Data("{\\rtf1 original}".utf8)),
         (type:"public.file-url",data:Data("file:///unit-test/original.txt".utf8)),
         (type:"com.example.opaque",data:Data([0,255,1,0]))]
    ],changeCount:10,currentCount:10)
    var transaction=ClipboardPasteTransaction(original:original,sendEnterRequested:true)
    try check(transaction.permitsTemporaryInstallation(changeCount:10,targetMatches:true),"前台目标完整匹配才可安装临时内容")
    try check(!transaction.permitsTemporaryInstallation(changeCount:10,targetMatches:false),"等待激活不替换原剪贴板")
    try check(!transaction.permitsTemporaryInstallation(changeCount:11,targetMatches:true),"激活过程中用户复制新内容即拒绝替换")
    try ClipboardPasteTransaction.requireIdle(nil)
    try ClipboardPasteTransaction.requireUnblocked(nil)
    try rejects("开始前清洁模式门控拒绝") {try ClipboardPasteTransaction.requireUnblocked("请先退出清洁模式。")}
    try rejects("准备阶段禁止重叠") {try ClipboardPasteTransaction.requireIdle(transaction)}
    try rejects("准备阶段不能确认插入") {try transaction.beginCompletion()}
    try rejects("准备阶段不能提前完成回调") {try transaction.completed()}
    try rejects("原板计数不能冒充临时板") {try transaction.installedTemporary(changeCount:10)}
    try check(!transaction.eventWasSubmitted && !transaction.mayRestoreOriginal,"准备尚未发送或替换")
    try transaction.installedTemporary(changeCount:11)
    try check(!transaction.permitsTemporaryInstallation(changeCount:10,targetMatches:true),"一笔事务不能二次安装临时内容")
    try check(transaction.phase == .waitingForTarget && transaction.mayRestoreOriginal,"安装后等待目标并保留恢复来源")
    try rejects("等待目标禁止重叠") {try ClipboardPasteTransaction.requireIdle(transaction)}
    try rejects("等待不能确认插入") {try transaction.requiresUserReview()}
    try rejects("等待不能发送回车") {try transaction.recordEnterSubmission()}
    try check(!transaction.permitsDispatch(changeCount:12,targetMatches:true),"最终回调改变剪贴板则拒绝")
    try check(!transaction.permitsDispatch(changeCount:11,targetMatches:false),"最终回调改变目标则拒绝")
    try rejects("剪贴板变化不得转成已发送") {try transaction.submitted(changeCount:12,targetMatches:true)}
    try rejects("目标变化不得转成已发送") {try transaction.submitted(changeCount:11,targetMatches:false)}
    try check(transaction.permitsDispatch(changeCount:11,targetMatches:true),"完整匹配允许一次提交")
    try rejects("beforeSubmit后模式变化仍拒绝") {try ClipboardPasteTransaction.requireUnblocked("退出键验证正在运行。")}
    try check(transaction.phase == .waitingForTarget && !transaction.eventWasSubmitted,"最终门控失败不发送或提交")
    try transaction.submitted(changeCount:11,targetMatches:true)
    try check(transaction.eventWasSubmitted && transaction.phase == .awaitingUser,"事件提交仅进入等待用户")
    try check(!transaction.completionWasAttempted && !transaction.completionSucceeded,"事件提交不提交堆栈")
    try check(!transaction.enterWasSubmitted,"事件提交不自动回车")
    try rejects("等待消费者期间禁止下一笔") {try ClipboardPasteTransaction.requireIdle(transaction)}
    try rejects("重复发送事件拒绝") {try transaction.submitted(changeCount:11,targetMatches:true)}
    try transaction.requiresUserReview()
    let retained=transaction.original.representations[0]
    try check(retained.count == 4 && retained[1].type == "public.rtf" && retained[3].data == Data([0,255,1,0]),"迟消费期间原富格式和未知类型仍在内存")
    var boardCount=12
    var wrote=false
    let restored=try transaction.original.restore(ifUnchanged:11,currentCount:{boardCount},write:{_ in wrote=true;return true})
    try check(!restored && !wrote,"核对前用户新复制禁止覆盖")
    try check(transaction.phase == .awaitingUser && !transaction.completionWasAttempted,"用户新复制不自动确认插入")
    boardCount=11
    var restoredRows:[[(type:String,data:Data)]]=[]
    try check(try transaction.original.restore(ifUnchanged:11,currentCount:{boardCount},write:{rows in restoredRows=rows;return true}),"显式取消可恢复未变板")
    try check(restoredRows.first?.count == 4,"取消完整保留格式")
    try check(!transaction.completionWasAttempted,"取消恢复本身不提交堆栈")
    try transaction.beginCompletion()
    try check(transaction.completionWasAttempted && !transaction.completionSucceeded && transaction.phase == .confirmed,"显式确认才开始完成一次")
    try rejects("完成失败不得自动重试") {try transaction.beginCompletion()}
    try transaction.completed()
    try check(transaction.completionSucceeded,"明确回调成功状态")
    try rejects("完成成功不能重复完成") {try transaction.completed()}
    try rejects("确认后回车前模式门控拒绝") {try ClipboardPasteTransaction.requireUnblocked("清洁模式尚未退出。")}
    try check(!transaction.enterWasSubmitted,"模式门控拒绝后无回车标记")
    try transaction.recordEnterSubmission()
    try check(transaction.enterWasSubmitted,"明确选择才标记回车提交")
    try rejects("回车禁止重复发送") {try transaction.recordEnterSubmission()}
    transaction.replaceTemporaryOwnership(changeCount:13)
    try check(transaction.ownsTemporary(changeCount:13) && !transaction.ownsTemporary(changeCount:11),"恢复清空后只持有新计数")
    try rejects("恢复失败尚未处理仍禁止新事务") {try ClipboardPasteTransaction.requireIdle(transaction)}
    var unsent=ClipboardPasteTransaction(original:original,sendEnterRequested:false)
    var failedActivation=ClipboardPasteTransaction(original:original,sendEnterRequested:false)
    failedActivation.failedBeforeSubmission()
    try check(!failedActivation.mayRestoreOriginal && !failedActivation.eventWasSubmitted,"激活失败未触板，不得恢复覆盖用户当前内容")
    try check(!failedActivation.permitsTemporaryInstallation(changeCount:10,targetMatches:true),"已失败的激活不能重用旧快照安装临时内容")
    try unsent.installedTemporary(changeCount:20)
    unsent.failedBeforeSubmission()
    try check(!unsent.eventWasSubmitted && unsent.phase == .failedBeforeSubmission,"发送前失败有明确恢复状态")
    try rejects("发送前失败不能误确认插入") {try unsent.beginCompletion()}
    try rejects("发送前恢复失败仍禁止重叠") {try ClipboardPasteTransaction.requireIdle(unsent)}
    var noEnter=ClipboardPasteTransaction(original:original,sendEnterRequested:false)
    try noEnter.installedTemporary(changeCount:21)
    try noEnter.submitted(changeCount:21,targetMatches:true)
    try rejects("未请求回车不能发送") {try noEnter.recordEnterSubmission()}
    noEnter.failedBeforeSubmission()
    try check(noEnter.eventWasSubmitted,"发送后不得降级为未发送")
    try check(ClipboardPasteTargetPolicy.documentsMatch(nil,nil),"双方没有文档匹配")
    try check(!ClipboardPasteTargetPolicy.documentsMatch(nil,"new"),"未知文档变已知必须拒绝")
    try check(!ClipboardPasteTargetPolicy.documentsMatch("old",nil),"已知文档变未知必须拒绝")
    try check(!ClipboardPasteTargetPolicy.documentsMatch("old","new"),"同窗切文档必须拒绝")
    for role in ["AXTextField","AXTextArea","AXComboBox"] {
        try check(ClipboardPasteTargetPolicy.permitsEnter(capturedRole:role,currentRole:role,capturedEditable:true,currentEditable:true),"可编辑文本允许显式回车 "+role)
    }
    for role in ["AXButton","AXOutline","AXTable","AXWebArea","AXSecureTextField","AXGroup"] {
        try check(!ClipboardPasteTargetPolicy.permitsEnter(capturedRole:role,currentRole:role,capturedEditable:true,currentEditable:true),"非文本控件禁止回车 "+role)
    }
    try check(!ClipboardPasteTargetPolicy.permitsEnter(capturedRole:"AXTextField",currentRole:"AXTextArea",capturedEditable:true,currentEditable:true),"文本角色变化拒绝")
    try check(!ClipboardPasteTargetPolicy.permitsEnter(capturedRole:"AXTextArea",currentRole:"AXTextArea",capturedEditable:false,currentEditable:true),"原目标不可编辑拒绝")
    try check(!ClipboardPasteTargetPolicy.permitsEnter(capturedRole:"AXTextArea",currentRole:"AXTextArea",capturedEditable:true,currentEditable:false),"当前目标不可编辑拒绝")
    try check(!ClipboardPasteTargetPolicy.permitsEnter(capturedRole:nil,currentRole:"AXTextArea",capturedEditable:true,currentEditable:true),"缺失原角色拒绝")
    print("粘贴事务离线定向检查通过（\(checks) 项）；未访问系统剪贴板、AX、前台或按键，系统消费者行为未验收。")
}
