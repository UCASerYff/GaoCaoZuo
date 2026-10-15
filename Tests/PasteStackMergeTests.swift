import Foundation

@MainActor func runPasteStackMergeTests() throws {
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-stack-merge-"+UUID().uuidString,isDirectory:true)
    defer {try? FileManager.default.removeItem(at:root)}
    let stack=PasteStack();try stack.configurePersistence(dataDirectory:root)
    func rejects(_ body:() throws -> Void) throws {do {try body()}catch{return};throw DataFailure.message("堆栈合并未拒绝无效输入")}
    try rejects {_ = try stack.mergedText()}
    try stack.pushContent(text:" 甲\n");try stack.pushContent(text:"乙 ")
    let before=stack.entries,ticket=stack.peek()!
    guard try stack.mergedText(separator:"::") == " 甲\n::乙 ",stack.entries == before else {throw DataFailure.message("文字合并次序或堆栈保留失败")}
    try stack.validateTicket(ticket)
    try rejects {_ = try stack.mergedText(separator:String(repeating:"-",count:4097))}
    try stack.pushContent(text:"rich",rtf:Data("{\\rtf1\\ansi rich}".utf8))
    let rich=stack.entries
    try rejects {_ = try stack.mergedText()}
    guard stack.entries == rich else {throw DataFailure.message("拒绝富合并改变堆栈")}
    let url=root.appendingPathComponent("PasteStack/Snippets/library.json")
    var external=try Data(contentsOf:url);external.append(Data("\n".utf8));try external.write(to:url)
    try rejects {_ = try stack.mergedText()}
    guard try Data(contentsOf:url) == external else {throw DataFailure.message("合并覆盖外部库改动")}
    print("纯文本堆栈合并定向检查通过：次序/空白/原队列与票据保留、富内容拒绝、大小门限和外部变化；未写系统剪贴板。")
}
