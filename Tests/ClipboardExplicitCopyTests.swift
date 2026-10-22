import AppKit

@MainActor func runClipboardExplicitCopyTests()throws {
    let board=NSPasteboard(name:.init("com.gaoseries.GaoCaoZuo.tests.copy."+UUID().uuidString))
    defer {board.clearContents();board.releaseGlobally()}
    let privateType=NSPasteboard.PasteboardType("com.gaoseries.tests.public-synthetic")
    let publicBytes=Data([0,128,255,10,65])
    func seed(_ text:String="Original")throws {
        let item=NSPasteboardItem();item.setString(text,forType:.string);item.setData(publicBytes,forType:privateType)
        board.clearContents();guard board.writeObjects([item]) else {throw DataFailure.message("专项命名剪贴板不可写")}
    }
    func prepared(_ value:String="Merged")->NSPasteboardItem {let item=NSPasteboardItem();item.setString(value,forType:.string);return item}
    func failure(_ body:()throws->Void)throws->ClipboardExplicitCopy.Failure {
        do {try body()}catch let value as ClipboardExplicitCopy.Failure {return value}
        throw DataFailure.message("复制写入失败未报告")
    }
    try seed()
    try ClipboardExplicitCopy.publish(prepared(),to:board,expectedCount:board.changeCount)
    guard board.string(forType:.string)=="Merged" else {throw DataFailure.message("成功复制被自动恢复")}
    try seed()
    let restored=try failure {try ClipboardExplicitCopy.publish(prepared(),to:board,expectedCount:board.changeCount,write:{_ in false})}
    guard restored.recovery==nil,board.string(forType:.string)=="Original",board.data(forType:privateType)==publicBytes else {throw DataFailure.message("复制失败未恢复全部原格式")}
    try seed()
    let concurrent=try failure {try ClipboardExplicitCopy.publish(prepared(),to:board,expectedCount:board.changeCount,write:{_ in
        board.clearContents();_ = board.writeObjects([prepared("Concurrent")]);return false
    })}
    guard let recovery=concurrent.recovery,board.string(forType:.string)=="Concurrent" else {throw DataFailure.message("失败自动覆盖了并发复制")}
    try recovery.restore()
    guard board.string(forType:.string)=="Original",board.data(forType:privateType)==publicBytes else {throw DataFailure.message("显式恢复未保留原格式")}
    try seed()
    let changed=try failure {try ClipboardExplicitCopy.publish(prepared(),to:board,expectedCount:board.changeCount,write:{_ in
        board.clearContents();_ = board.writeObjects([prepared("Concurrent")]);return false
    })}
    try seed("Newer")
    var refused=false
    do {try changed.recovery!.restore()}catch {refused=true}
    guard refused,board.string(forType:.string)=="Newer" else {throw DataFailure.message("恢复未拒绝提示后发生变化的剪贴板")}
    try seed();let count=board.changeCount
    var approvals=0
    refused=false
    do {try ClipboardExplicitCopy.publish(prepared(),to:board,expectedCount:count,shouldProceed:{approvals += 1;return approvals==1})}catch {refused=true}
    guard refused,board.changeCount==count,board.string(forType:.string)=="Original" else {throw DataFailure.message("来源变化后仍清空剪贴板")}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-copy-lease-"+UUID().uuidString,isDirectory:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let service=ClipboardService(directory:root,tracksApplications:false,secureInputForCopy:{false})
    let original=try ClipboardPasteboardSnapshot.capture(board)
    service.retainCopyRecovery(.init(snapshot:original,board:board,expectedCount:board.changeCount))
    guard service.hasCopyRecovery,service.hasActivePasteTransaction else {throw DataFailure.message("复制恢复未阻止退出")}
    let dummy=ClipboardItem(kind:.text,title:"public",text:"public",sourceApp:"public.synthetic")
    for action in [{try service.pastePreparedItems([prepared()])},{try service.pasteFromStack()},{try service.paste(dummy)},{try service.pastePlainText()}] {
        var blocked=false
        do {try action()}catch {blocked=error.localizedDescription=="请先处理复制前剪贴板的恢复选择。"}
        guard blocked,service.hasCopyRecovery,service.hasActivePasteTransaction,board.changeCount==count else {throw DataFailure.message("复制恢复期间普通或堆栈粘贴未互斥")}
    }
    refused=false
    do {try service.cancelPendingPaste()}catch {refused=error.localizedDescription=="没有待处理的粘贴。"}
    guard refused,service.hasActivePasteTransaction else {throw DataFailure.message("无关粘贴取消解除复制恢复保护")}
    try seed("Newest");refused=false
    do {try service.resolveFailedCopy(restore:true)}catch {refused=true}
    guard refused,service.hasCopyRecovery,service.hasActivePasteTransaction,board.string(forType:.string)=="Newest" else {throw DataFailure.message("恢复失败丢失快照或退出保护")}
    try service.resolveFailedCopy(restore:false);try service.requireClipboardIdle()
    guard !service.hasCopyRecovery,!service.hasActivePasteTransaction else {throw DataFailure.message("保留当前内容后未释放恢复租约")}
    service.retainCopyRecovery(.init(snapshot:original,board:board,expectedCount:board.changeCount))
    try service.resolveFailedCopy(restore:true);try service.requireClipboardIdle()
    guard !service.hasActivePasteTransaction,board.string(forType:.string)=="Original",board.data(forType:privateType)==publicBytes else {throw DataFailure.message("显式恢复成功后未释放租约或格式丢失")}
    let secureService=ClipboardService(directory:root,tracksApplications:false,secureInputForCopy:{true})
    secureService.retainCopyRecovery(.init(snapshot:original,board:board,expectedCount:board.changeCount))
    refused=false
    do {try secureService.resolveFailedCopy(restore:true)}catch {refused=error.localizedDescription=="安全输入期间不读取剪贴板。"}
    guard refused,secureService.hasCopyRecovery,secureService.hasActivePasteTransaction else {throw DataFailure.message("安全输入阻止恢复时丢失保护")}
    try secureService.resolveFailedCopy(restore:false)
    print("显式复制专项通过：成功不恢复、失败完整恢复、并发复制保留、手动恢复、提示后变化拒绝、来源二次核验、恢复与粘贴互斥、安全输入允许/拒绝（依赖注入）；仅命名合成剪贴板，未访问系统通用剪贴板。")
}
