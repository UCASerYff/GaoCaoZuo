import Foundation

/// Offline bookmark resolver plus real temporary files. This exercises the
/// production path gate, not ScopedBookmarksAgent or a GUI/pasteboard host.
@MainActor func runSnippetFileReferenceTests() throws {
    var checks=0
    func check(_ value:Bool,_ name:String) throws {
        checks += 1
        guard value else {throw DataFailure.message("文件引用一致性检查："+name)}
    }
    func rejects(_ name:String,_ expected:String,_ action:() throws -> Void) throws {
        var rejected=false
        do {try action()} catch {rejected=error.localizedDescription.contains(expected)}
        try check(rejected,name)
    }
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-reference-"+UUID().uuidString,isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:false)
    defer {try? FileManager.default.removeItem(at:directory)}
    let first=directory.appendingPathComponent("已选文件甲.txt"),second=directory.appendingPathComponent("另一个文件乙.txt")
    let firstBytes=Data("fixture-a".utf8),secondBytes=Data("fixture-b".utf8)
    try firstBytes.write(to:first);try secondBytes.write(to:second)
    let bookmark=Data("offline-bookmark-a".utf8)
    let resolve:(Data) throws -> (url:URL,isStale:Bool)={bytes in
        guard bytes == bookmark else {throw DataFailure.message("测试解析器收到未知书签。")}
        return (first,false)
    }
    let matching=SnippetFileReference(path:first.path,bookmark:bookmark)
    try check(try matching.verifiedURL(resolvingBookmark:resolve).standardizedFileURL.path == first.standardizedFileURL.path,"匹配书签正常使用")
    let mismatch=SnippetFileReference(path:second.path,bookmark:bookmark)
    try rejects("显示乙但书签指向甲必须拒绝","不一致") {_ = try mismatch.verifiedURL(resolvingBookmark:resolve)}
    let plain=SnippetFileReference(path:second.path,bookmark:nil)
    try check(try plain.verifiedURL().standardizedFileURL.path == second.standardizedFileURL.path,"没有书签仍使用明确本机路径")
    let lexical=SnippetFileReference(path:directory.appendingPathComponent("unused/../已选文件甲.txt").path,bookmark:bookmark)
    try check(try lexical.verifiedURL(resolvingBookmark:resolve).standardizedFileURL.path == first.standardizedFileURL.path,"规范化同一路径不误拒绝")
    if first.path.hasPrefix("/private/var/") || first.path.hasPrefix("/private/tmp/") {
        let alias=String(first.path.dropFirst("/private".count))
        try check(try SnippetFileReference(path:alias,bookmark:bookmark).verifiedURL(resolvingBookmark:resolve).standardizedFileURL.path == first.standardizedFileURL.path,"系统tmp或var别名仍匹配")
    } else if first.path.hasPrefix("/var/") || first.path.hasPrefix("/tmp/") {
        let canonical="/private"+first.path
        try check(try SnippetFileReference(path:canonical,bookmark:bookmark).verifiedURL(resolvingBookmark:resolve).standardizedFileURL.path == first.standardizedFileURL.path,"系统tmp或var规范路径仍匹配")
    }
    try rejects("过期书签不得使用","已过期") {_ = try matching.verifiedURL(resolvingBookmark:{_ in (first,true)})}
    try rejects("解析失败保持拒绝","解析器失败") {_ = try matching.verifiedURL(resolvingBookmark:{_ in throw DataFailure.message("解析器失败")})}
    let remote=URL(string:"file://untrusted-host/unit-test.txt")!
    try rejects("非本机书签拒绝","不一致") {_ = try matching.verifiedURL(resolvingBookmark:{_ in (remote,false)})}
    try check(try Data(contentsOf:first) == firstBytes && Data(contentsOf:second) == secondBytes,"所有拒绝后两原件逐字节保留")
    print("短语文件引用一致性定向检查通过（\(checks) 项）；使用离线书签解析和隔离文件，无系统书签宿主、剪贴板或GUI。")
}
