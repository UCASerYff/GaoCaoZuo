import AppKit
import Foundation

@MainActor func runEnhancementIntegrationTests() throws {
    let fm=FileManager.default
    let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("GaoCaoZuo-Integration-"+UUID().uuidString)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    var count=0
    func check(_ value:@autoclosure () throws -> Bool,_ message:String) throws {count += 1;if try !value(){throw DataFailure.message("增强整合测试："+message)}}
    func rejects(_ message:String,_ body:() throws -> Void) throws {var rejected=false;do{try body()}catch{rejected=true};try check(rejected,message)}
    let folder=root.appendingPathComponent("tree");try fm.createDirectory(at:folder,withIntermediateDirectories:false)
    let text=folder.appendingPathComponent("text");try Data("safe".utf8).write(to:text)
    try check(try FileTools.archiveFingerprint(folder)==FileTools.fingerprint(folder),"无链接摘要兼容旧恢复记录")
    let sidecar=folder.appendingPathComponent("._text");try Data("sidecar".utf8).write(to:sidecar)
    let ordinary=try FileTools.fingerprint(folder);try Data("edited sidecar".utf8).write(to:sidecar)
    try check(try FileTools.fingerprint(folder) != ordinary,"AppleDouble内容修改进入摘要保护")
    let link=folder.appendingPathComponent("alias");try fm.createSymbolicLink(atPath:link.path,withDestinationPath:"text")
    let digest=try FileTools.archiveFingerprint(folder)
    try check(digest.hasPrefix("archive-tree-v1:"),"合法内部链接单独版本化摘要")
    try rejects("普通文件操作仍拒绝链接"){_ = try FileTools.fingerprint(folder)}
    let receipt=FileOperationReceipt(kind:.create,destination:folder,fingerprint:digest)
    try Data("changed".utf8).write(to:text)
    try rejects("用户改动后不能撤销删除"){try FileTools.undo([receipt],trashCreated:false)}
    try check(fm.fileExists(atPath:text.path),"拒绝撤销后保留编辑")
    try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:"../outside")
    try rejects("越界链接不能登记恢复记录"){_ = try FileTools.archiveFingerprint(folder)}
    try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:"alias")
    try rejects("循环链接不能登记"){_ = try FileTools.archiveFingerprint(folder)}
    try fm.removeItem(at:link);try fm.createSymbolicLink(atPath:link.path,withDestinationPath:"text")
    try FileTools.undo([.init(kind:.create,destination:folder,fingerprint:try FileTools.archiveFingerprint(folder))],trashCreated:false)
    try check(!fm.fileExists(atPath:folder.path),"合法链接树能精确撤销")

    var snapshot=FinderMenuSnapshot()
    let uuid=UUID().uuidString
    snapshot.folders=[.init(id:uuid,name:"测试目录",path:root.path)]
    snapshot.templates=[.init(id:uuid,name:"测试模板",binary:true)]
    let target=NSObject()
    let menu=FinderMenuBuilder.menu(snapshot:snapshot,urls:[root],hasSelection:false,target:target,selector:Selector(("perform:")))
    guard let sub=menu.items.first?.submenu else{throw DataFailure.message("菜单未收纳")}
    func find(_ id:String,in menu:NSMenu)->NSMenuItem? {for item in menu.items {if item.representedObject as? String == id{return item};if let sub=item.submenu,let match=find(id,in:sub){return match}};return nil}
    try check(find("new.text",in:sub)?.isEnabled == true,"空白处可直接新建")
    try check(find("file.hide",in:sub)?.isEnabled == false,"空白处不能误隐藏整个目录")
    try check(find("binaryTemplate."+uuid,in:sub)?.isEnabled == true,"原样模板从空白目录直接新建")
    try check(find("folder.copy."+uuid,in:sub)?.isEnabled == false,"没有选择不能复制目录自身")
    try check(FinderActionRequest.isAllowed("folder.move."+uuid),"常用目录UUID动作可交接")
    try check(!FinderActionRequest.isAllowed("folder.move.../escape"),"动态动作拒绝伪造路径")
    snapshot.preferences.mergeInSubmenu=false
    snapshot.preferences.items=[.init(id:"new.folder",title:"自定名称",icon:"folder",enabled:true,group:"新建"),.init(id:"new.text",title:"隐藏项",icon:"doc",enabled:false,group:"新建")]
    let flat=FinderMenuBuilder.menu(snapshot:snapshot,urls:[root],hasSelection:false,target:target,selector:Selector(("perform:")))
    try check(flat.items.map(\.title)==["自定名称"],"菜单名称顺序与开关生效")
    let dataRoot=root.appendingPathComponent("Data")
    try fm.createDirectory(at:dataRoot,withIntermediateDirectories:false)
    try Data("not json".utf8).write(to:dataRoot.appendingPathComponent("finder-menu.json"))
    let controller=FinderPreferenceController(directory:dataRoot)
    try check(controller.data.failure != nil,"损坏菜单配置保留且停止写入")
    controller.update{$0.showIcons=false}
    try check(try Data(contentsOf:dataRoot.appendingPathComponent("finder-menu.json"))==Data("not json".utf8),"不可读取的配置不被默认值覆盖")
    print("PASS: \(count)项菜单/安全链接/恢复与损坏配置整合测试")
}
