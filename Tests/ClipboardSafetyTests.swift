import AppKit
import CryptoKit
import Foundation

@MainActor func runClipboardSafetyTests() throws {
    func check(_ ok:Bool,_ name:String) throws {if !ok {throw DataFailure.message("剪贴板安全检查："+name)}}
    let rtf=Data("{\\rtf1\\ansi original}".utf8)
    let original:[[(type:String,data:Data?)]]=[[("public.utf8-plain-text",Data("原始文字".utf8)),("public.rtf",rtf),("com.gaoseries.unit-test.bytes",Data([0,1,2,3]))]]
    let snapshot=try ClipboardPasteboardSnapshot.captureRepresentations(original,changeCount:1,currentCount:1)
    var count=2
    var restored:[String:Data]=[:]
    try check(try snapshot.restore(ifUnchanged:2,currentCount:{count},write:{rows in restored=Dictionary(uniqueKeysWithValues:rows[0].map{($0.type,$0.data)});count += 1;return true}),"未改变可恢复")
    try check(restored["public.utf8-plain-text"] == Data("原始文字".utf8) && restored["public.rtf"] == rtf,"文本和富格式完整保留")
    try check(restored["com.gaoseries.unit-test.bytes"] == Data([0,1,2,3]),"未知类型原样保留")
    var wrote=false
    try check(try !snapshot.restore(ifUnchanged:2,currentCount:{count},write:{_ in wrote=true;return true}),"用户已改内容拒绝恢复")
    try check(!wrote,"不覆盖新复制")
    do {_ = try ClipboardPasteboardSnapshot.captureRepresentations(original,changeCount:1,currentCount:2);throw DataFailure.message("应拒绝读取期间变化")} catch {try check(error.localizedDescription.contains("变化"),"快照中途变化拒绝")}
    do {_ = try ClipboardPasteboardSnapshot.captureRepresentations(original,changeCount:1,currentCount:1,maximumBytes:5);throw DataFailure.message("应拒绝预算超限")} catch {try check(error.localizedDescription.contains("完整"),"全量预算超限拒绝而非截断")}
    let root=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-clipboard-safety-"+UUID().uuidString)
    defer {try? FileManager.default.removeItem(at:root)}
    let data=LocalData(directory:root)
    let id=UUID();let filename=id.uuidString+".rtf"
    try data.createFile(rtf,name:filename)
    let digest=SHA256.hash(data:rtf).map{String(format:"%02x",$0)}.joined()
    var entry=ClipboardItem(id:id,kind:.text,title:"私有测试",text:"body",richTextFile:filename,sourceApp:"unit.test",group:"分组",tags:["标签"],richTextSHA256:digest)
    try ClipboardService.validateDocument(ClipboardDocument(items:[entry]),directory:root)
    entry.richTextSHA256=String(repeating:"0",count:64)
    do {try ClipboardService.validateDocument(ClipboardDocument(items:[entry]),directory:root);throw DataFailure.message("应拒绝摘要变化")} catch {
        try check(error.localizedDescription.contains("摘要"),"摘要不符拒绝")
    }
    entry.richTextSHA256=digest;entry.tags=[String(repeating:"t",count:129)]
    do {try ClipboardService.validateDocument(ClipboardDocument(items:[entry]),directory:root);throw DataFailure.message("应拒绝过长标签")} catch {
        try check(error.localizedDescription.contains("标签"),"坏元数据拒绝")
    }
    let onDisk=try data.verifiedData(filename,maximumSize:10000)
    try check(onDisk == rtf,"拒绝不改附件")
    print("剪贴板摘要、元数据与完整格式恢复检查通过；使用离线类型表示，未访问系统剪贴板或发送按键；系统桥接未验收。")
}
