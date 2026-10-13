import Foundation
import CryptoKit
import Darwin

struct RightMouseMigrationMenuEntry: Codable {
    var sourceKey: String
    var kind: String
    var index: Int
    var enabled: Bool
    var name: String
    var displayName: String? = nil
    var mappedActionID: String?
    var unknownReason: String?
}
struct RightMouseMigrationReport: Codable {
    struct Resource: Codable { var relativePath: String; var bytes: Int; var sha256: String }
    struct AssetReference: Codable { var sourceKey:String; var sha256:String; var bytes:Int; var retainedInBackup:Bool; var reason:String }
    var sourceBundleID: String
    var sourceVersion: String
    var resourceBundleID = "com.gaoseries.GaoCaoZuo"
    var templateCount = 0
    var iconCount = 0
    var appCount = 0
    var unavailableApps: [String] = []
    var unavailableTemplates: [String] = []
    var iconReferences: [AssetReference] = []
    var unmappedKeys: [String] = []
    var resources: [Resource] = []
    var warnings: [String] = []
}
struct RightMouseMigrationPlan {
    var settings: FileEnhancementSettings
    var attachments: [String:Data]
    var menuEntries: [RightMouseMigrationMenuEntry]
    var report: RightMouseMigrationReport
}

/// Maps old configuration to this app's original resources. Competitor stock
/// templates/icons remain solely in their safety backup and are never reused.
enum RightMouseMigration {
    static let bundleID = "cn.better365.iRightMousePro"
    static let resourceFiles = ["rtf":"Blank.rtf", "xml":"Blank.xml", "docx":"Blank.docx", "xlsx":"Blank.xlsx", "pptx":"Blank.pptx", "pages":"Blank.pages", "numbers":"Blank.numbers", "key":"Blank.key", "psd":"Blank.psd"]
    static func sha(_ bytes: Data) -> String { SHA256.hash(data:bytes).map { String(format:"%02x",$0) }.joined() }
    static func bytes(_ url: URL, maximum: Int = 32_000_000) throws -> Data {
        let before = try EnhancedFileTools.checked(url)
        guard before.st_mode & S_IFMT == S_IFREG, before.st_size >= 0, before.st_size <= maximum else { throw DataFailure.message("迁移附件不是有界普通文件。") }
        let fd = Darwin.open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw DataFailure.message("迁移附件不可读取；未用空白替代。") }
        let handle = FileHandle(fileDescriptor:fd,closeOnDealloc:true)
        var opened = stat()
        guard fstat(fd,&opened) == 0, opened.st_dev == before.st_dev, opened.st_ino == before.st_ino else { throw FileToolsError.changed(url) }
        let result = try handle.read(upToCount:maximum+1) ?? Data()
        var after = stat()
        let final = try EnhancedFileTools.checked(url)
        guard result.count <= maximum, result.count == before.st_size,
              fstat(fd,&after) == 0, final.st_dev == before.st_dev, final.st_ino == before.st_ino,
              after.st_size == before.st_size, after.st_mtimespec.tv_sec == before.st_mtimespec.tv_sec,
              after.st_mtimespec.tv_nsec == before.st_mtimespec.tv_nsec else { throw FileToolsError.changed(url) }
        return result
    }
    static func prepare(config: [String:Any], resources: URL, existing: FileEnhancementSettings,
                        sourceVersion:String = "unknown",
                        resolveApplication: (String) -> URL?) throws -> RightMouseMigrationPlan {
        let root = resources.standardizedFileURL
        guard root.isFileURL, root.path == root.resolvingSymlinksInPath().path,
              root.lastPathComponent == "DocumentTemplates",
              !root.pathComponents.contains("iRightMouse Pro.app"),
              (try EnhancedFileTools.checked(root)).st_mode & S_IFMT == S_IFDIR else { throw DataFailure.message("只能使用本应用原创 DocumentTemplates；禁止复用竞品模板或跟随符号链接。") }
        guard let templates = config["newFileList"] as? [[String:Any]],
              let tools = config["toolboxList"] as? [[String:Any]],
              let icons = config["fileIconList"] as? [[String:Any]],
              templates.count <= 1000, tools.count <= 1000, icons.count <= 1000 else { throw DataFailure.message("原文件增强配置缺失或结构无效；未按空配置迁移。") }
        var plan = RightMouseMigrationPlan(settings:existing,attachments:[:],menuEntries:[],report:.init(sourceBundleID:bundleID,sourceVersion:sourceVersion))
        plan.report.unmappedKeys=config.keys.filter{!["newFileList","toolboxList","fileIconList","shouldAutoOpenNewFile"].contains($0)}.map{"right/"+$0}.sorted()
        var total = 0
        func attach(_ value:Data, suffix:String) throws -> (String,String) {
            total += value.count
            guard value.count <= 32_000_000, total <= 128_000_000 else { throw DataFailure.message("迁移附件超出预算。") }
            let name = UUID().uuidString + suffix
            plan.attachments[name] = value
            return (name,sha(value))
        }
        func fields(_ entry:[String:Any], allowed:Set<String>, path:String) {
            plan.report.unmappedKeys += entry.keys.filter { !allowed.contains($0) }.map { path + "/" + $0 }.sorted()
        }
        for (index,entry) in templates.enumerated() {
            let key = "right/newFile/\(index)"
            guard let name = entry["name"] as? String, !name.isEmpty,
                  let suffix = entry["suffix"] as? String, let enabled = entry["enable"] as? Bool,
                  let main = entry["mainMenu"] as? Bool else { throw DataFailure.message("原模板条目缺少名称、后缀或开关。") }
            fields(entry,allowed:["name","suffix","enable","mainMenu","icon"],path:key)
            // Unknown templates are retained in the source payload, never replaced
            // by a similarly named built-in or an invented empty document.
            guard suffix.isEmpty || ["txt","md","wps","et","dps","ai"].contains(suffix) || resourceFiles[suffix] != nil,
                  !entry.keys.contains(where: { !["name","suffix","enable","mainMenu","icon"].contains($0) }) else {
                plan.menuEntries.append(.init(sourceKey:key,kind:"newFile",index:index,enabled:enabled,name:name,unknownReason:"自定义模板来源尚未证明；原条目和附件必须保留。")); continue
            }
            let unsupported=["wps","et","dps","ai"].contains(suffix)
            let unavailable=unsupported ? "尚无合法原创 \(suffix.uppercased()) 模板及原生编辑验收；竞品模板仅保留在安全备份，禁止复用。" : nil
            var sourceValue:Data?, sourcePath:String?
            if suffix == "txt" || suffix == "md" {sourceValue=Data();sourcePath="generated/empty."+suffix}
            else if !suffix.isEmpty && !unsupported {
                let relative=resourceFiles[suffix]!, value=try bytes(root.appendingPathComponent(relative))
                guard !value.isEmpty else {throw DataFailure.message("本应用原创模板缺失内容，未以空白替代。")}
                sourceValue=value; sourcePath=relative
                plan.report.resources.append(.init(relativePath:relative,bytes:value.count,sha256:sha(value)))
            }
            var template: BinaryTemplate
            if let old = existing.templates.first(where:{$0.sourceKey == key}) {
                guard old.directory == suffix.isEmpty, (old.unavailableReason != nil) == unsupported else {throw DataFailure.message("同来源模板类型已变化，不能复用旧迁移。")}
                if let value=sourceValue { guard old.provenance?.bundleID == "com.gaoseries.GaoCaoZuo", old.provenance?.sha256 == sha(value), old.provenance?.relativePath == sourcePath else { throw DataFailure.message("本应用原创模板内容已变化，不能覆盖或复用其他来源。") } }
                template = old
            }
            else if unsupported {
                template = .init(name:name,filename:"未命名."+suffix,directory:false,entries:[])
            } else if suffix.isEmpty {
                template = .init(name:name,filename:"New Folder",directory:true,entries:[.init(relative:"",attachment:nil,digest:nil,mode:0o755)])
            } else {
                let relative = sourcePath!, value = sourceValue!
                let (attachment,digest) = try attach(value,suffix:".template")
                template = .init(name:name,filename:"未命名."+suffix,directory:false,entries:[.init(relative:"",attachment:attachment,digest:digest,mode:0o644)])
                template.provenance = .init(bundleID:"com.gaoseries.GaoCaoZuo",version:"original",relativePath:relative,sha256:digest)
            }
            template.name = name; template.enabled = enabled; template.mainMenu = main; template.sourceKey = key;template.unavailableReason=unavailable
            if let old = plan.settings.templates.firstIndex(where:{$0.sourceKey == key}) { plan.settings.templates[old] = template }
            else { plan.settings.templates.append(template) }
            if unsupported {plan.report.unavailableTemplates.append(suffix)} else {plan.report.templateCount += 1}
            plan.menuEntries.append(.init(sourceKey:key,kind:"newFile",index:index,enabled:enabled,name:name,mappedActionID:unsupported ? nil : "binaryTemplate."+template.id.uuidString,unknownReason:unavailable))
        }
        for (index,entry) in icons.enumerated() {
            let key = "right/fileIcon/\(index)"
            guard let name = entry["name"] as? String, !name.isEmpty, let enabled = entry["enable"] as? Bool,
                  entry["icon"] == nil, let digest=entry["iconSHA256"] as? String,digest.count == 64,digest.allSatisfy({$0.isHexDigit}),
                  let count=entry["iconByteCount"] as? Int,count>=0,count<=32_000_000,
                  entry["assetRetainedInBackup"] as? Bool == true else {throw DataFailure.message("竞品图标只能保留核验备份引用；迁移载荷不得包含图像Data。")}
            fields(entry,allowed:["name","enable","iconSHA256","iconByteCount","assetRetainedInBackup"],path:key)
            let reason="竞品图标禁止复制或复用；原附件仅在安全备份中保留。"
            plan.report.iconReferences.append(.init(sourceKey:key,sha256:digest.lowercased(),bytes:count,retainedInBackup:true,reason:reason))
            plan.menuEntries.append(.init(sourceKey:key,kind:"fileIcon",index:index,enabled:enabled,name:name,unknownReason:reason))
        }
        for (index,entry) in tools.enumerated() {
            let key = "right/toolbox/\(index)"
            guard let name = entry["name"] as? String, let enabled = entry["enable"] as? Bool,
                  let type = entry["type"] as? Int else { throw DataFailure.message("原工具箱条目结构无效。") }
            var action:String?, reason:String?, displayName:String?
            if type == 2 {
                let id = entry["bundleId"] as? String ?? ""
                displayName=label(name) ?? label(entry["appName"] as? String)
                if id.isEmpty { reason = "原应用身份缺失，不能只凭显示名猜测自定义应用。" }
                else {
                    let resolved = resolveApplication(id)
                    if let resolved, Bundle(url:resolved)?.bundleIdentifier != id { throw DataFailure.message("迁移应用身份不匹配。") }
                    if displayName == nil,let resolved,let verified=Bundle(url:resolved) {
                        displayName=label(verified.object(forInfoDictionaryKey:"CFBundleDisplayName") as? String)
                            ?? label(verified.object(forInfoDictionaryKey:"CFBundleName") as? String)
                            ?? label(resolved.deletingPathExtension().lastPathComponent)
                    }
                    guard let title=displayName else {
                        plan.menuEntries.append(.init(sourceKey:key,kind:"toolbox",index:index,enabled:enabled,name:name,unknownReason:"原应用显示名缺失，且无法从已核验应用取得标签；原字段已保留。"))
                        fields(entry,allowed:["name","enable","icon","type","selectOptionIndex","appName","bundleId"],path:key)
                        if resolved == nil {plan.report.unavailableApps.append(id)}
                        continue
                    }
                    var app = existing.apps.first(where:{$0.sourceKey == key}) ?? .init(name:title,bundleID:id,path:resolved?.path ?? "")
                    guard app.bundleID == id else {throw DataFailure.message("同来源应用身份已变化，不能复用旧迁移。")}
                    app.name = title; app.enabled = enabled; app.sourceKey = key
                    if id == "com.apple.Terminal" || id == "com.googlecode.iterm2" {
                        // Index semantics are not inferred: retain the exact value
                        // in the source and request review before changing behavior.
                        reason = "终端原 selectOptionIndex 语义需本人复核；未擅自映射新窗口或标签。"
                        app.enabled = false
                    }
                    if let old = plan.settings.apps.firstIndex(where:{$0.sourceKey == key}) { plan.settings.apps[old] = app }
                    else { plan.settings.apps.append(app) }
                    plan.report.appCount += 1
                    if resolved == nil { plan.report.unavailableApps.append(id) }
                    action = "file.open." + app.id.uuidString
                }
            } else {
                let token = (entry["finderToolType"] ?? entry["format"] ?? entry["toolType"] ?? entry["serviceType"]) as? String ?? ""
                action = toolActions[token]
                if action == nil { reason = "原动作意图尚无精确对应，保留并停止自动启用。" }
                else if ["Cut","Delete directly"].contains(token), (entry["selectOptionIndex"] as? Int ?? -1) >= 0 { reason = "原确认/隐藏参数语义需本人复核；未擅自改变安全设置。" }
                if label(name) == nil {reason="原工具显示名为空，保留原条目等待复核。"}
            }
            fields(entry,allowed:["name","enable","icon","type","selectOptionIndex","finderToolType","format","toolType","serviceType","appName","bundleId"],path:key)
            plan.menuEntries.append(.init(sourceKey:key,kind:"toolbox",index:index,enabled:enabled,name:name,displayName:displayName,mappedActionID:action,unknownReason:reason))
        }
        if let value=config["shouldAutoOpenNewFile"] as? Bool { plan.settings.autoOpenNew=value }
        plan.report.warnings.append("仅映射到本应用原创模板；竞品模板与图标不复用。WPS/Ai 原创生成与原生编辑保存重开仍未完成。")
        if plan.menuEntries.contains(where:{$0.unknownReason != nil}) { plan.report.warnings.append("存在未证明的动作或参数；不能宣称完整替代或据此卸载原应用。") }
        return plan
    }
    private static func label(_ value:String?) -> String? {
        guard let value,!value.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,
              !value.unicodeScalars.contains(where:CharacterSet.controlCharacters.contains) else {return nil}
        return value
    }
    static let toolActions = ["File Information":"file.info", "Send Shortcut to Desktop":"file.alias", "AirDrop":"file.airdrop", "Copy File(Folder) Name":"name.copy", "Create Folder by File Name":"file.folderNames", "Cut":"file.cut", "Dissolve Folder":"file.dissolve", "Set as Wallpaper":"file.wallpaper", "Copy Path":"path.copy", "Delete directly":"file.delete", "Grant write permission to selected files":"file.write", "Nohidden All Files in Path":"file.unhideAll", "Hidden All Files in Path":"file.hideAll", "Nohidden Selected Files":"file.unhide", "Hidden Selected Files":"file.hide", "Fix garbled filename":"file.fixNames", "Convert to webp format image":"images.webp", "Convert to heic format image":"images.heic", "Convert to jpg format image":"images.jpeg", "Convert to png format image":"images.png", "Image to Icns for mac":"images.icns", "Image to Icons for mac":"images.macicons", "Image to Icons for iOS":"images.iosicons", "Compressed to 7z By FastZip":"archive.7z", "Compressed to zip By FastZip":"archive.create", "Decompress to the current folder By FastZip":"archive.extract", "Translate by Baidu":"text.baidu", "Translate by Google":"text.google", "Change to QR Code":"text.qrcode.clipboard"]
}

@MainActor extension FileEnhancementController {
    /// Call only after the root migration journal is durably prepared. Settings
    /// commit/rollback belongs to that transaction; these immutable attachments
    /// remain recoverable on interruption and are never used as empty defaults.
    func installMigrationAttachments(_ plan:RightMouseMigrationPlan) throws {
        guard healthy else { throw DataFailure.message(data.failure ?? "文件资料不可写。") }
        for (name,value) in plan.attachments.sorted(by:{$0.key<$1.key}) {
            try data.createFile(value,name:name)
            guard try data.verifiedData(name) == value else { throw DataFailure.message("迁移附件落盘核验失败。") }
        }
    }
}
