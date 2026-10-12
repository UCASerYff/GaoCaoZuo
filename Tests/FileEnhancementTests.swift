import Foundation
import AppKit
import ImageIO
import UniformTypeIdentifiers

@MainActor func runFileEnhancementTests() async throws {
    let fm=FileManager.default
    let root=URL(fileURLWithPath:"/private/tmp/GaoCaoZuo-FileEnhancementTests-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false)
    defer{try? fm.removeItem(at:root)}
    var count=0
    func check(_ value:@autoclosure () throws -> Bool,_ message:String) throws {guard try value() else{throw DataFailure.message("文件增强测试失败："+message)};count += 1}
    func rejects(_ message:String,_ block:() throws -> Void) throws {do{try block()}catch{count += 1;return};throw DataFailure.message("文件增强测试应拒绝："+message)}
    func file(_ name:String,_ bytes:Data=Data("abc".utf8)) throws -> URL {let u=root.appendingPathComponent(name);try bytes.write(to:u,options:.withoutOverwriting);return u}
    func dir(_ name:String) throws -> URL {let u=root.appendingPathComponent(name,isDirectory:true);try fm.createDirectory(at:u,withIntermediateDirectories:false);return u}
    let controller=FileEnhancementController(directory:try dir("Data"))
    try check(controller.healthy,"隔离资料初始化")

    let a=try file("hash.txt")
    let hashes=try EnhancedFileTools.hashes(a)
    try check(hashes.contains("MD5: 900150983cd24fb0d6963f7d28e17f72"),"MD5 官方 abc 向量")
    try check(hashes.contains("SHA1: a9993e364706816aba3e25717850c26c9cd0d89d"),"SHA1 abc 向量")
    try check(hashes.contains("SHA256: ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad"),"SHA256 abc 向量")
    try check(hashes.contains("SHA512: ddaf35a193617abacc417349ae20413112e6fa4e89a97ea20a9eeee64b55d39a2192992a274fc1a836ba3c23a3feebbd454d4423643ce80e2a9ac94fa54ca49f"),"SHA512 abc 向量")

    try controller.changeMetadata([a],kind:"hidden",value:1)
    try check(try EnhancedFileTools.checked(a).st_flags & UInt32(UF_HIDDEN) != 0,"隐藏属性生效")
    try controller.undoMetadata()
    try check(try EnhancedFileTools.checked(a).st_flags & UInt32(UF_HIDDEN) == 0,"隐藏属性可恢复")
    try fm.setAttributes([.posixPermissions:0o400],ofItemAtPath:a.path)
    try controller.changeMetadata([a],kind:"write",value:0)
    try check(try EnhancedFileTools.checked(a).st_mode & 0o777 == 0o600,"只增加所有者写权限")
    try controller.undoMetadata()
    try check(try EnhancedFileTools.checked(a).st_mode & 0o777 == 0o400,"权限可恢复")
    try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:a.path)
    let stale=try EnhancedFileTools.metadataPlan([a],kind:"mode",value:0o644)
    try fm.setAttributes([.posixPermissions:0o640],ofItemAtPath:a.path)
    try rejects("并发属性变更",{try EnhancedFileTools.applyMetadata(stale)})
    try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:a.path)
    let link=root.appendingPathComponent("link")
    try fm.createSymbolicLink(at:link,withDestinationURL:a)
    try rejects("符号链接属性操作",{_ = try EnhancedFileTools.metadataPlan([link],kind:"mode",value:0o777)})
    try check(try EnhancedFileTools.checked(a).st_mode & 0o777 == 0o600,"拒绝链接不改变目标")
    try controller.changeMetadata([a],kind:"extension",value:1)
    try check(try a.resourceValues(forKeys:[.hasHiddenExtensionKey]).hasHiddenExtension == true,"隐藏文件扩展名")
    try controller.undoMetadata()
    try check(try a.resourceValues(forKeys:[.hasHiddenExtensionKey]).hasHiddenExtension != true,"恢复扩展名显示")
    try rejects("扩展名无效状态",{_ = try EnhancedFileTools.metadataPlan([a],kind:"extension",value:2)})
    try fm.setAttributes([.posixPermissions:0o000],ofItemAtPath:a.path)
    try controller.changeMetadata([a],kind:"write",value:0)
    try check(try EnhancedFileTools.checked(a).st_mode & 0o777 == 0o200,"无读取权限文件仍可授予所有者写权限")
    try controller.undoMetadata()
    try fm.setAttributes([.posixPermissions:0o600],ofItemAtPath:a.path)
    let mojibake=String(data:Data("测试.txt".utf8),encoding:.isoLatin1)!
    let badName=try file(mojibake)
    let repaired=try EnhancedFileTools.repairedNames([badName],byteEncoding:.isoLatin1,textEncoding:.utf8)
    try check(repaired[0].destination.lastPathComponent=="测试.txt","乱码名称修复有无损预览")
    let renamed=try FileTools.applyRenames(repaired)
    try check(try Data(contentsOf:renamed[0].destination)==Data("abc".utf8),"乱码修复只改名称不改内容")
    try FileTools.undo(renamed,trashCreated:false)
    try check(fm.fileExists(atPath:badName.path),"乱码修复可撤销")
    let legacySettings=try JSONDecoder().decode(FileEnhancementSettings.self,from:Data("{\"schema\":1,\"templates\":[],\"apps\":[],\"autoOpenNew\":true,\"cutHidesFiles\":false,\"terminalNewWindow\":false,\"customPathPrefix\":\"\"}".utf8))
    try check(legacySettings.autoOpenNew && legacySettings.confirmPermanentDelete,"新增选项兼容原设置并保留安全默认")
    let bulk=try dir("BulkHidden"),bulkA=bulk.appendingPathComponent("one.txt"),bulkB=bulk.appendingPathComponent("two.txt")
    try Data("one".utf8).write(to:bulkA);try Data("two".utf8).write(to:bulkB)
    try controller.changeMetadata(try EnhancedFileTools.children(bulk),kind:"hidden",value:1)
    try check(try EnhancedFileTools.checked(bulkA).st_flags & UInt32(UF_HIDDEN) != 0 && EnhancedFileTools.checked(bulkB).st_flags & UInt32(UF_HIDDEN) != 0,"当前目录批量隐藏")
    try controller.undoMetadata()
    try check(try EnhancedFileTools.checked(bulkA).st_flags & UInt32(UF_HIDDEN) == 0 && EnhancedFileTools.checked(bulkB).st_flags & UInt32(UF_HIDDEN) == 0,"批量隐藏整体恢复")

    let output=try dir("Output")
    try controller.importTemplate(a)
    try check(controller.settings.templates.count==1,"真实模板可导入")
    let copied=try controller.createTemplate(controller.settings.templates[0],in:output)
    try check(try Data(contentsOf:copied.destination)==Data("abc".utf8),"二进制模板按字节复制")
    let again=try controller.createTemplate(controller.settings.templates[0],in:output)
    try check(again.destination != copied.destination,"模板重名不覆盖")
    var unsafe=controller.settings.templates[0];unsafe.entries[0].relative="../escape.txt"
    try rejects("模板路径越界",{_ = try controller.createTemplate(unsafe,in:output)})
    let package=try dir("Example.pages")
    let nested=package.appendingPathComponent("Data",isDirectory:true);try fm.createDirectory(at:nested,withIntermediateDirectories:false)
    try Data([0,255,7,128,9]).write(to:nested.appendingPathComponent("opaque.bin"))
    try controller.importTemplate(package)
    let packCopy=try controller.createTemplate(controller.settings.templates[1],in:output)
    try check(try Data(contentsOf:packCopy.destination.appendingPathComponent("Data/opaque.bin"))==Data([0,255,7,128,9]),"包模板完整保留二进制附件")
    let restarted=FileEnhancementController(directory:root.appendingPathComponent("Data"))
    try check(restarted.healthy && restarted.settings.templates.count==2,"模板重启核验通过")
    let damaged=controller.settings.templates[0].entries.first!.attachment!
    try Data("changed".utf8).write(to:controller.data.directory.appendingPathComponent(damaged))
    let broken=FileEnhancementController(directory:root.appendingPathComponent("Data"))
    try check(!broken.healthy,"附件损坏阻止写入而非空白覆盖")

    let cutController=FileEnhancementController(directory:try dir("CutData")),cut=try file("cut.txt")
    try cutController.update{$0.cutHidesFiles=true}
    try cutController.beginCut([cut],writePasteboard:false)
    try check(try EnhancedFileTools.checked(cut).st_flags & UInt32(UF_HIDDEN) != 0,"剪切可隐藏")
    let moved=try cutController.pasteCut(to:output,checkPasteboard:false)
    try check(!fm.fileExists(atPath:cut.path) && fm.fileExists(atPath:moved[0].destination.path),"粘贴实现移动")
    try check(try EnhancedFileTools.checked(moved[0].destination).st_flags & UInt32(UF_HIDDEN) == 0,"粘贴恢复隐藏状态")
    try FileTools.undo(moved,trashCreated:false)
    try check(fm.fileExists(atPath:cut.path),"粘贴恢复记录有效")
    try cutController.beginCut([cut],writePasteboard:false)
    try Data("edit".utf8).write(to:cut)
    try rejects("剪切后内容被编辑",{_ = try cutController.pasteCut(to:output,checkPasteboard:false)})
    try check(fm.fileExists(atPath:cut.path),"剪切失败保留原件")
    try cutController.cancelCut()
    try cutController.beginCut([cut],writePasteboard:false)
    let sameName=output.appendingPathComponent(cut.lastPathComponent);try Data("conflict".utf8).write(to:sameName)
    try rejects("剪切粘贴目标冲突",{_ = try cutController.pasteCut(to:output,checkPasteboard:false)})
    let cutRestarted=FileEnhancementController(directory:root.appendingPathComponent("CutData"))
    try check(cutRestarted.healthy,"目标冲突后剪切日志仍可重启读取")
    try cutRestarted.cancelCut()
    try check(try EnhancedFileTools.checked(cut).st_flags & UInt32(UF_HIDDEN) == 0,"冲突后重启取消不遗留隐藏")

    let aliasRecords=try EnhancedFileTools.aliases([a],to:output)
    let bookmark=try URL.bookmarkData(withContentsOf:aliasRecords[0].destination)
    var staleAlias=false
    let target=try URL(resolvingBookmarkData:bookmark,options:[.withoutUI,.withoutMounting],relativeTo:nil,bookmarkDataIsStale:&staleAlias)
    try check(target.path==a.path,"生成真实 Finder 替身而非复制文件")
    let folders=try EnhancedFileTools.foldersUsingNames([a])
    try check(folders.count==1 && folders[0].destination.lastPathComponent=="hash","按名称创建目录")

    let dissolveController=FileEnhancementController(directory:try dir("DissolveData"))
    let folder=try dir("Unwrap");let item=folder.appendingPathComponent("inside.txt");try Data("keep".utf8).write(to:item)
    let flattened=try dissolveController.dissolveFolders([folder])
    try check(flattened.count==1 && !fm.fileExists(atPath:folder.path),"解散后原外层目录消失")
    try check(try Data(contentsOf:flattened[0])==Data("keep".utf8),"解散保留内容")
    try dissolveController.undoDissolve()
    try check(fm.fileExists(atPath:item.path) && !fm.fileExists(atPath:flattened[0].path),"解散整体可恢复")
    let collision=try file("inside.txt",Data("original".utf8))
    try rejects("解散目标冲突",{_ = try dissolveController.dissolveFolders([folder])})
    try check(try Data(contentsOf:collision)==Data("original".utf8) && fm.fileExists(atPath:item.path),"冲突预检不改原件")

    let disposable=try file("explicit-delete.txt")
    try rejects("重复项目永久删除预检",{try EnhancedFileTools.permanentlyDelete([disposable,disposable],confirmation:"彻底删除")})
    try rejects("未确认永久删除",{try EnhancedFileTools.permanentlyDelete([disposable],confirmation:"")})
    try check(fm.fileExists(atPath:disposable.path),"未确认保留原件")
    try EnhancedFileTools.permanentlyDelete([disposable],confirmation:"彻底删除")
    try check(!fm.fileExists(atPath:disposable.path),"仅明确确认删除临时样本")

    guard let context=CGContext(data:nil,width:32,height:24,bitsPerComponent:8,bytesPerRow:128,space:CGColorSpaceCreateDeviceRGB(),bitmapInfo:CGImageAlphaInfo.premultipliedLast.rawValue) else{throw DataFailure.message("图像测试上下文失败")}
    context.setFillColor(NSColor.systemBlue.cgColor);context.fill(CGRect(x:0,y:0,width:32,height:24));let image=context.makeImage()!
    let png=try file("image.png",FileEnhancementImages.encode(image,type:UTType.png.identifier))
    for symbol in FileEnhancementImages.builtinSymbols {try check(try FileEnhancementImages.builtinIcon(symbol).tiffRepresentation != nil,"原创内置图标可渲染："+symbol)}
    let iconTarget=try file("icon-target.txt",Data("keep icon target".utf8)),customIcon=try FileEnhancementImages.builtinIcon("star")
    try check(NSWorkspace.shared.setIcon(customIcon,forFile:iconTarget.path,options:[]),"真实临时文件可设置自定义图标")
    try check(try Data(contentsOf:iconTarget)==Data("keep icon target".utf8),"图标设置不改变文件内容")
    try check(NSWorkspace.shared.setIcon(nil,forFile:iconTarget.path,options:[]),"真实临时文件可移除自定义图标")
    for kind in ["icns","macicons","iosicons"] {
        let records=try FileEnhancementImages.create([png],kind:kind)
        try check(records.count==1,"生成 \(kind)")
        if kind=="icns" {try check(NSImage(contentsOf:records[0].destination) != nil,"ICNS 可由系统解码")}
        if kind=="macicons" {try check(try fm.contentsOfDirectory(atPath:records[0].destination.path).count==10,"macOS 图标双倍率齐全")}
        if kind=="iosicons" {
            let base=records[0].destination
            let json=try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("AppIcon.appiconset/Contents.json"))) as! [String:Any]
            try check((json["images"] as? [[String:String]])?.count ?? 0 > 20,"iOS 资源清单齐全")
            let watch=try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent("WatchAppIcon.appiconset/Contents.json"))) as! [String:Any]
            try check((watch["images"] as? [[String:String]])?.count==9,"Watch 独立资源清单含角色与设备尺寸")
            for group in ["AppIcon.appiconset","WatchAppIcon.appiconset"] {
                let json=try JSONSerialization.jsonObject(with:Data(contentsOf:base.appendingPathComponent(group+"/Contents.json"))) as! [String:Any]
                for item in json["images"] as! [[String:String]] {
                    let url=base.appendingPathComponent(group).appendingPathComponent(item["filename"]!)
                    let source=CGImageSourceCreateWithURL(url as CFURL,nil)!
                    let properties=CGImageSourceCopyPropertiesAtIndex(source,0,nil)! as NSDictionary
                    let points=Double(item["size"]!.components(separatedBy:"x")[0])!,scale=Double(item["scale"]!.dropLast())!
                    try check((properties[kCGImagePropertyPixelWidth] as? Int)==Int(points*scale) && (properties[kCGImagePropertyPixelHeight] as? Int)==Int(points*scale),"资源像素尺寸与清单一致")
                    try check((properties[kCGImagePropertyHasAlpha] as? Bool) != true,"App 图标无透明通道")
                }
            }
        }
    }
    let project=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent()
    let cwebp=project.appendingPathComponent("Resources/Tools/cwebp")
    if fm.isExecutableFile(atPath:cwebp.path) {
        let webp=root.appendingPathComponent("real.webp")
        try FileEnhancementImages.webP(png,to:webp,engineOverride:cwebp)
        let source=CGImageSourceCreateWithURL(webp as CFURL,nil)
        try check(source != nil && CGImageSourceGetCount(source!)==1,"官方 cwebp 实际转换并解码")
        try rejects("WebP 不覆盖",{try FileEnhancementImages.webP(png,to:webp,engineOverride:cwebp)})
    } else {throw DataFailure.message("缺少 cwebp，WebP 验收未通过")}
    let officeController=FileEnhancementController(directory:try dir("OfficeData"))
    for ext in FileEnhancements.documentFormats {
        let receipt=try officeController.createOffice(ext,in:output,resourceDirectory:project.appendingPathComponent("Resources/DocumentTemplates"))
        let bytes=try Data(contentsOf:receipt.destination)
        try check(bytes.count>20,"有效内置 \(ext) 非空模板")
        if ext=="psd" {let source=CGImageSourceCreateWithURL(receipt.destination as CFURL,nil);try check(source != nil && CGImageSourceCreateImageAtIndex(source!,0,nil) != nil,"PSD 原生空白文档可由系统解码")}
    }
    print("File enhancement tests: \(count) passed (isolated fixtures; no user documents, clipboard or external app launches).")
}
