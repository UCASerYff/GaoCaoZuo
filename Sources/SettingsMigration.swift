import Foundation
import CryptoKit

private struct ReplacementMigrationJournal:Codable {
    var schema=1
    var sourceDigest:String
    var state="prepared"
    var date=Date()
    var beforeSettings:OperationSettings
    var beforeArchive:ArchiveEnhancementPreferences
    var beforeFiles:FileEnhancementSettings
    var beforeFinder:FinderMenuPreferences
    var folders:Int
    var importedRules:Int
    var note:String
}

@MainActor extension OperationStore {
    func importReplacementSettings(_ url:URL) throws {
        guard dataHealthy else {throw DataFailure.message("资料保护模式，停止迁移。")}
        let attrs=try FileManager.default.attributesOfItem(atPath:url.path)
        guard attrs[.type] as? FileAttributeType == .typeRegular,(attrs[.size] as? NSNumber)?.intValue ?? Int.max<=8_000_000 else {throw DataFailure.message("迁移文件无效或过大。")}
        let bytes=try Data(contentsOf:url)
        let digest=SHA256.hash(data:bytes).map{String(format:"%02x",$0)}.joined()
        var journal=try data.load("replacement-migration.json",as:ReplacementMigrationJournal.self)
        if let previous=journal {
            guard previous.schema == 1,previous.sourceDigest == digest else {throw DataFailure.message("已存在其他配置的迁移快照，停止覆盖；请在设置中单独导入规则。")}
            if previous.state == "complete" {notify("该配置已迁移，无需重复导入");return}
            guard previous.state == "restored" else {throw DataFailure.message("上次迁移中断，请重启以恢复迁移前设置，再重新导入同一文件。")}
            let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys]
            func unchanged<T:Encodable>(_ current:T,_ original:T) throws -> Bool {
                try encoder.encode(current) == encoder.encode(original)
            }
            guard try unchanged(settings,previous.beforeSettings),
                  try unchanged(archiveEnhancements.preferences,previous.beforeArchive),
                  try unchanged(fileEnhancements.settings,previous.beforeFiles),
                  try unchanged(finderPreferences.preferences,previous.beforeFinder) else {
                throw DataFailure.message("中断恢复后的设置已修改，不能复用旧迁移快照。已保留当前设置和原快照；请单独导入需要的规则，或先恢复迁移前设置后重试。")
            }
        }
        guard let document=try PropertyListSerialization.propertyList(from:bytes,format:nil) as? [String:Any],document["schema"] as? Int == 1,
              let right=document["right"] as? [String:Any],let archive=document["archive"] as? [String:Any],let pane=document["pane"] as? [String:Any],let inputDocument=document["input"] as? [String:Any] else {throw DataFailure.message("迁移文件结构不完整；未更改任何设置。")}
        var next=settings
        if let v=right["shouldShowStatusBarIcon"] as? Bool {next.showMenuBarIcon=v}
        if let v=right["shouldPlayNewFileSound"] as? Bool {next.playNewFileSound=v}
        var folders=0
        for entry in (right["commonDirList"] as? [[String:Any]] ?? []) + (right["sendFileToDirList"] as? [[String:Any]] ?? []) {
            guard let path=entry["path"] as? String,path.hasPrefix("/"),!path.contains("\0"),let name=entry["name"] as? String,!name.isEmpty else{continue}
            if !next.folders.contains(where:{$0.path==path}) {next.folders.append(.init(name:name,path:path));folders += 1}
        }
        let imported=try EnhancedRuleFiles.importBAB(inputDocument)
        next.inputEnhancements.rules += imported.configuration.rules
        next.inputEnhancements.scriptLibrary += imported.configuration.scriptLibrary
        // Coexistence is intentional until replacement verification: imported triggers remain paused.
        if let v=pane["isUnsnapRestore"] as? Bool {next.windowEnhancements.restoreWhenUnsnapped=v}
        if let v=pane["isHapticFeedbackOnSnap"] as? Bool {next.windowEnhancements.hapticFeedback=v}
        if let v=pane["isHiddenScreenEdgeText"] as? Bool {next.windowEnhancements.showSnapPreview = !v}
        var archivePreferences=archiveEnhancements.preferences
        if let v=archive["cpuUseCount"] as? Int,(0...256).contains(v) {archivePreferences.creation.threads=v}
        if let v=archive["shouldAppendDateAfterFileNameWhenCompress"] as? Bool {archivePreferences.creation.appendDate=v}
        if let v=archive["shouldOpenOriginDirectoryAfterCompress"] as? Bool {archivePreferences.creation.revealResults=v}
        if let v=archive["shouldOpenOriginDirectoryAfterDecompress"] as? Bool {archivePreferences.extraction.revealResults=v}
        if archive["shouldExcludeIgnoreFilesWhenCompress"] as? Bool == true {
            archivePreferences.creation.ignoredPatterns=(archive["ignoreFilesWhenCompress"] as? [[String:Any]] ?? []).compactMap {entry in
                guard entry["enable"] as? Bool == true,let name=entry["name"] as? String,!name.isEmpty else{return nil};return name
            }
        }
        if let v=archive["shouldAutoSaveDecompressPassword"] as? Bool {archivePreferences.saveExtractionPasswords=v}
        if let v=archive["shouldAutoSaveCompressPassword"] as? Bool {archivePreferences.saveCompressionPasswords=v}
        if let v=archive["shouldAutoTryDecompressPassword"] as? Bool {archivePreferences.tryPasswordBook=v}
        try archivePreferences.creation.validate();try archivePreferences.extraction.validate()
        try EnhancedInputValidation.validate(next.inputEnhancements)
        // A single journal keeps immutable prestate and an explicit commit marker across all files.
        if journal == nil {
            journal=ReplacementMigrationJournal(sourceDigest:digest,beforeSettings:settings,beforeArchive:archiveEnhancements.preferences,beforeFiles:fileEnhancements.settings,beforeFinder:finderPreferences.preferences,folders:folders,importedRules:imported.configuration.rules.count,note:imported.note+"\n原软件保留；迁入规则暂停。原密码与钥匙串未改动。")
        }
        journal!.state="prepared"
        try data.save(journal!,name:"replacement-migration.json")
        archiveEnhancements.preferences=archivePreferences;try archiveEnhancements.save()
        try fileEnhancements.update {if let v=right["shouldAutoOpenNewFile"] as? Bool {$0.autoOpenNew=v}}
        var menu=finderPreferences.preferences
        if let v=right["shouldMergeFinderMenuItems"] as? Bool {menu.mergeInSubmenu=v}
        if let v=right["shouldShowMenuOnExternalDisk"] as? Bool {menu.includeExternalVolumes=v}
        if let v=right["shouldShowMenuIconOfToolbox"] as? Bool {menu.showIcons=v}
        try finderPreferences.replaceForMigration(menu)
        settings=next
        guard data.failure == nil else {throw DataFailure.message("主要配置迁移未完成；迁移前快照已保留。")}
        journal!.state="complete"
        try data.save(journal!,name:"replacement-migration.json")
        finderPreferences.publish(store:self)
        notify("配置已迁移：\(folders)个目录、\(imported.configuration.rules.count)条暂停规则；详情保存在本地资料。")
    }
    func recoverInterruptedMigration() throws {
        guard dataHealthy, var journal=try data.load("replacement-migration.json",as:ReplacementMigrationJournal.self) else {return}
        guard journal.schema == 1,["prepared","restored","complete"].contains(journal.state) else {throw DataFailure.message("迁移日志版本或状态无效，停止写入。")}
        guard journal.state == "prepared" else {return}
        archiveEnhancements.preferences=journal.beforeArchive;try archiveEnhancements.save()
        try fileEnhancements.update{$0=journal.beforeFiles}
        try finderPreferences.replaceForMigration(journal.beforeFinder)
        settings=journal.beforeSettings
        guard data.failure == nil else {throw DataFailure.message("迁移恢复尚未完成，请保留日志与安全备份。")}
        journal.state="restored";try data.save(journal,name:"replacement-migration.json")
        message="上次配置迁移中断，已恢复迁移前设置；原应用与安全备份保留。"
    }

}
