import AppKit
import Foundation

private struct LegacyReplacementEvidence: Decodable { var originalFile: String; var sourceSHA256: String }
private struct LegacyReplacementCommit: Decodable { var schema:Int;var sourceDigest:String;var state:String;var importedRules:Int }

@MainActor extension OperationStore {
    func importReplacementV2(_ document: [String:Any], bytes: Data) throws {
        guard dataHealthy, let right=document["right"] as? [String:Any],
              let archive=document["archive"] as? [String:Any], let pane=document["pane"] as? [String:Any],
              let input=document["input"] as? [String:Any], let books=document["passwordBookCounts"] as? [String:Int],
              books.count == 2, books["compressPasswordBook"] == 0, books["decompressPasswordBook"] == 0,
              archive.keys.allSatisfy({ !$0.lowercased().contains("passwordbook") }) else {
            throw DataFailure.message("完整迁移载荷无效，或密码本尚未经过核验。")
        }
        let digest=ReplacementMigrationSupport.digest(bytes)
        var transaction=try data.load("replacement-migration-v2.json",as:ReplacementMigrationTransaction.self)
        if let old=transaction {
            guard old.generation == 2, old.sourceSHA256 == digest else { throw DataFailure.message("已有其他来源的迁移快照，停止覆盖。") }
            if old.state == "complete" { notify("该配置已迁移，无需重复导入");return }
            guard old.state == "restored", try ReplacementMigrationSupport.identical(settings,old.beforeSettings),
                  try ReplacementMigrationSupport.identical(archiveEnhancements.preferences,old.beforeArchive),
                  try ReplacementMigrationSupport.identical(fileEnhancements.settings,old.beforeFiles),
                  try ReplacementMigrationSupport.identical(finderPreferences.preferences,old.beforeFinder) else {
                throw DataFailure.message("上次迁移未恢复，或恢复后的设置已修改；已保留当前设置和迁移快照。")
            }
        }
        var previous:[String:Any]?
        if let evidence=try data.load("replacement-migration-evidence.json",as:LegacyReplacementEvidence.self) {
            let original=try data.verifiedData(evidence.originalFile)
            guard ReplacementMigrationSupport.digest(original) == evidence.sourceSHA256,
                  let object=try PropertyListSerialization.propertyList(from:original,format:nil) as? [String:Any] else {
                throw DataFailure.message("原迁移来源证据不符，不能覆盖后续用户设置。")
            }
            previous=object
        }
        // Early V1.05 stored a commit journal but no source preimage. Its current
        // settings may contain later user choices; lack of evidence is never a
        // first-import signal or permission to overwrite those choices.
        let legacyCommit=try data.load("replacement-migration.json",as:LegacyReplacementCommit.self)
        if let legacyCommit {
            guard legacyCommit.schema == 1,legacyCommit.state == "complete",
                  legacyCommit.importedRules >= 0,legacyCommit.sourceDigest.count == 64,
                  legacyCommit.sourceDigest.allSatisfy({$0.isHexDigit}) else {throw DataFailure.message("旧迁移尚未提交或来源日志无效，停止升级迁移。")}
        }
        let preserveUnprovenBaseline=previous == nil && legacyCommit != nil
        let oldRight=previous?["right"] as? [String:Any] ?? [:]
        let oldArchive=previous?["archive"] as? [String:Any] ?? [:]
        let oldPane=previous?["pane"] as? [String:Any] ?? [:]
        guard let resources=Bundle.main.resourceURL?.appendingPathComponent("DocumentTemplates",isDirectory:true),
              let sourceVersion=document["rightSourceVersion"] as? String else {throw DataFailure.message("本应用原创模板资源或原配置版本缺失。") }
        var plan=try RightMouseMigration.prepare(config:right,resources:resources,existing:fileEnhancements.settings,sourceVersion:sourceVersion,
                                                 resolveApplication:{NSWorkspace.shared.urlForApplication(withBundleIdentifier:$0)})
        if preserveUnprovenBaseline {
            for old in fileEnhancements.settings.templates {
                if let key=old.sourceKey,let index=plan.settings.templates.firstIndex(where:{$0.sourceKey == key}) {plan.settings.templates[index]=old}
            }
            for old in fileEnhancements.settings.apps {
                if let key=old.sourceKey,let index=plan.settings.apps.firstIndex(where:{$0.sourceKey == key}) {plan.settings.apps[index]=old}
            }
        }
        guard plan.report.sourceVersion == sourceVersion,plan.report.resourceBundleID == "com.gaoseries.GaoCaoZuo" else {
            throw DataFailure.message("模板迁移计划来源不符。")
        }
        let imported=try EnhancedRuleFiles.importBAB(input)
        if preserveUnprovenBaseline {
            guard try EnhancedRuleFiles.legacyImportBAB(input).configuration.rules.count == legacyCommit!.importedRules else {throw DataFailure.message("本次来源的旧解析条数与已提交日志不符；无法证明旧条目范围，已保留全部现有设置并停止迁移。")}
        }
        var merged=try EnhancedRuleFiles.mergeBABUpgrade(imported:imported,into:settings.inputEnhancements,
                                                         legacySource:previous?["input"] as? [String:Any] ?? (preserveUnprovenBaseline ? input:nil))
        if preserveUnprovenBaseline {merged.configuration.scriptLibrary=settings.inputEnhancements.scriptLibrary}
        var receipt=ReplacementMigrationReceipt(sourceSHA256:digest,state:"prepared")
        receipt.templateCount=plan.report.templateCount;receipt.iconCount=plan.report.iconCount;receipt.appCount=plan.report.appCount
        receipt.rulesAdded=merged.added;receipt.rulesUpgraded=merged.upgraded;receipt.rulesPreserved=merged.preserved;receipt.rulesBlocked=merged.blocked
        receipt.verifiedEmptyPasswordBooks=true
        if preserveUnprovenBaseline {receipt.notes.append("旧版只有已提交日志，缺少原来源文件。现有设置保留；旧规则只按完全一致且唯一的旧解析指纹对应，无法对应的条目不覆盖、不另添替代。")}
        receipt.notes+=plan.report.warnings + [merged.note,
            "来源资料已按原值私有保留；配置事务完成不表示全部功能和设备已验收。",
            "原软件保留。Magic Mouse、多键鼠标、多显示器及 WPS/Illustrator 编辑保存尚未实机验收。",
            "导入规则保持暂停；审阅后逐条接管。剪贴板采集与原钥匙串凭据未更改。"]
        var next=settings
        func bool(_ values:[String:Any],_ key:String)->Bool? {values[key] as? Bool}
        func mergeBool(_ candidate:Bool?,_ current:Bool,_ old:Bool?,_ key:String)->Bool {
            if preserveUnprovenBaseline {if candidate != nil {receipt.retainedUserChanges.append(key)};return current}
            return ReplacementMigrationSupport.merged(candidate,current:current,previousSource:old,key:key,retained:&receipt.retainedUserChanges)
        }
        next.showMenuBarIcon=mergeBool(bool(right,"shouldShowStatusBarIcon"),next.showMenuBarIcon,bool(oldRight,"shouldShowStatusBarIcon"),"showMenuBarIcon")
        next.playNewFileSound=mergeBool(bool(right,"shouldPlayNewFileSound"),next.playNewFileSound,bool(oldRight,"shouldPlayNewFileSound"),"playNewFileSound")
        let originalFolderIDs=Set(next.folders.map(\.id))
        for (key,role) in [("commonDirList","common"),("sendFileToDirList","send")] {
            guard right[key] == nil || right[key] is [[String:Any]] else {throw DataFailure.message("原目录列表结构未知，停止迁移。")}
            for entry in right[key] as? [[String:Any]] ?? [] {
                var folder=try ReplacementMigrationSupport.folder(entry)
                if let index=next.folders.firstIndex(where:{$0.path == folder.path}) {
                    if !originalFolderIDs.contains(next.folders[index].id) {
                        var roles=next.folders[index].sourceRoles ?? []
                        if !roles.contains(role) {roles.append(role)}
                        next.folders[index].sourceRoles=roles
                    }
                } else {folder.sourceRoles=[role];next.folders.append(folder)}
            }
        }
        next.inputEnhancements=merged.configuration
        // Preserve explicit post-migration choices, including the user's tested restore setting.
        next.windowEnhancements.restoreWhenUnsnapped=mergeBool(bool(pane,"isUnsnapRestore"),next.windowEnhancements.restoreWhenUnsnapped,bool(oldPane,"isUnsnapRestore"),"restoreWhenUnsnapped")
        next.windowEnhancements.hapticFeedback=mergeBool(bool(pane,"isHapticFeedbackOnSnap"),next.windowEnhancements.hapticFeedback,bool(oldPane,"isHapticFeedbackOnSnap"),"hapticFeedback")
        if !preserveUnprovenBaseline,let hidden=bool(pane,"isHiddenScreenEdgeText") { next.windowEnhancements.showSnapLabel = !hidden }
        // V1.05 omitted this setting. Keep an already configured snap choice.
        if previous == nil && !preserveUnprovenBaseline,let snap=bool(pane,"isDragSnapWindow") {next.windowSnapEnabled=snap}
        var files=plan.settings
        files.autoOpenNew=mergeBool(bool(right,"shouldAutoOpenNewFile"),fileEnhancements.settings.autoOpenNew,bool(oldRight,"shouldAutoOpenNewFile"),"autoOpenNew")
        var archivePreferences=archiveEnhancements.preferences
        if !preserveUnprovenBaseline {archivePreferences.creation.threads=ReplacementMigrationSupport.merged(archive["cpuUseCount"] as? Int,current:archivePreferences.creation.threads,previousSource:oldArchive["cpuUseCount"] as? Int,key:"archive.threads",retained:&receipt.retainedUserChanges)}
        archivePreferences.creation.appendDate=mergeBool(bool(archive,"shouldAppendDateAfterFileNameWhenCompress"),archivePreferences.creation.appendDate,bool(oldArchive,"shouldAppendDateAfterFileNameWhenCompress"),"archive.appendDate")
        archivePreferences.creation.revealResults=mergeBool(bool(archive,"shouldOpenOriginDirectoryAfterCompress"),archivePreferences.creation.revealResults,bool(oldArchive,"shouldOpenOriginDirectoryAfterCompress"),"archive.revealCompression")
        archivePreferences.extraction.revealResults=mergeBool(bool(archive,"shouldOpenOriginDirectoryAfterDecompress"),archivePreferences.extraction.revealResults,bool(oldArchive,"shouldOpenOriginDirectoryAfterDecompress"),"archive.revealExtraction")
        archivePreferences.saveCompressionPasswords=mergeBool(bool(archive,"shouldAutoSaveCompressPassword"),archivePreferences.saveCompressionPasswords,bool(oldArchive,"shouldAutoSaveCompressPassword"),"archive.saveCompressionPasswords")
        archivePreferences.saveExtractionPasswords=mergeBool(bool(archive,"shouldAutoSaveDecompressPassword"),archivePreferences.saveExtractionPasswords,bool(oldArchive,"shouldAutoSaveDecompressPassword"),"archive.saveExtractionPasswords")
        archivePreferences.tryPasswordBook=mergeBool(bool(archive,"shouldAutoTryDecompressPassword"),archivePreferences.tryPasswordBook,bool(oldArchive,"shouldAutoTryDecompressPassword"),"archive.tryPasswordBook")
        func patterns(_ source:[String:Any]) throws -> [String]? {
            guard let enabled=source["shouldExcludeIgnoreFilesWhenCompress"] as? Bool else{return nil}
            if !enabled{return []}
            guard let rows=source["ignoreFilesWhenCompress"] as? [[String:Any]] else {throw DataFailure.message("原压缩忽略规则无法读取。")}
            return try rows.compactMap {row in
                guard let on=row["enable"] as? Bool,let name=row["name"] as? String else{throw DataFailure.message("原压缩忽略条目无效。")}
                return on ? name:nil
            }
        }
        if !preserveUnprovenBaseline {archivePreferences.creation.ignoredPatterns=try ReplacementMigrationSupport.merged(patterns(archive),current:archivePreferences.creation.ignoredPatterns,previousSource:patterns(oldArchive),key:"archive.ignoredPatterns",retained:&receipt.retainedUserChanges)}
        // Existing originals are retained. A destructive old preference is recorded,
        // never silently activated by importing a configuration.
        if bool(archive,"shouldDeleteOriginFileAfterDecompress") == true {receipt.notes.append("旧软件解压后删除原包已保留在来源；本应用继续保留原包，需要时可明确执行解压后移到废纸篓。")}
        var menu=finderPreferences.preferences
        menu.mergeInSubmenu=mergeBool(bool(right,"shouldMergeFinderMenuItems"),menu.mergeInSubmenu,bool(oldRight,"shouldMergeFinderMenuItems"),"menu.merge")
        menu.includeExternalVolumes=mergeBool(bool(right,"shouldShowMenuOnExternalDisk"),menu.includeExternalVolumes,bool(oldRight,"shouldShowMenuOnExternalDisk"),"menu.externalVolumes")
        menu.showIcons=mergeBool(bool(right,"shouldShowMenuIconOfToolbox"),menu.showIcons,bool(oldRight,"shouldShowMenuIconOfToolbox"),"menu.icons")
        let defaults=Dictionary(uniqueKeysWithValues:FinderMenuPreferences.defaults.map{($0.id,$0)})
        let executableIDs=Set(OperationAction.all.map(\.id))
        var mappedOrder:[String]=[]
        for entry in plan.menuEntries {
            guard entry.unknownReason == nil,let id=entry.mappedActionID,FinderActionRequest.isAllowed(id) else{continue}
            if entry.kind == "newFile",let template=files.templates.first(where:{"binaryTemplate."+$0.id.uuidString == id}),template.mainMenu != true {continue}
            if !menu.items.contains(where:{$0.id == id}) {
                let dynamic=id.hasPrefix("binaryTemplate.") || id.hasPrefix("file.privateIcon.") || id.hasPrefix("file.open.")
                guard dynamic || executableIDs.contains(id) else{continue}
                let group=entry.kind == "newFile" ? "新建" : entry.kind == "fileIcon" ? "属性" : "分享与应用"
                menu.items.append(.init(id:id,title:entry.displayName ?? entry.name,icon:entry.kind == "newFile" ? "doc" : entry.kind == "fileIcon" ? "photo" : "app",enabled:entry.enabled,group:group))
            }
            guard let index=menu.items.firstIndex(where:{$0.id == id}) else{continue}
            if let original=defaults[id] {
                if !preserveUnprovenBaseline && menu.items[index] == original {menu.items[index].enabled=entry.enabled;menu.items[index].title=entry.displayName ?? entry.name}
                else {receipt.retainedUserChanges.append("menu."+id)}
            }
            if !mappedOrder.contains(id) {mappedOrder.append(id)}
        }
        if !preserveUnprovenBaseline && finderPreferences.preferences.items.map(\.id) == FinderMenuPreferences.defaults.map(\.id) {
            let mapped=Dictionary(uniqueKeysWithValues:menu.items.map{($0.id,$0)})
            menu.items=mappedOrder.compactMap{mapped[$0]} + menu.items.filter{!mappedOrder.contains($0.id)}
        } else {receipt.retainedUserChanges.append("menu.order")}
        try archivePreferences.creation.validate();try archivePreferences.extraction.validate()
        try EnhancedInputValidation.validate(next.inputEnhancements)
        let sourceName="replacement-v2-source-"+digest+".plist"
        try ReplacementMigrationSupport.preserve(bytes,name:sourceName,in:data)
        // Retrying in a fresh process must establish fingerprints for every
        // existing derived report before LocalData may replace it.
        _ = try data.load("replacement-migration-v2-receipt.json",as:ReplacementMigrationReceipt.self)
        if let report=try data.load("replacement-right-migration-report.json",as:RightMouseMigrationReport.self) {
            guard report.sourceBundleID == plan.report.sourceBundleID,report.sourceVersion == plan.report.sourceVersion else {throw DataFailure.message("现存文件迁移报告的来源不符，停止覆盖。")}
        }
        _ = try data.load("replacement-right-menu-report.json",as:[RightMouseMigrationMenuEntry].self)
        if transaction == nil {
            transaction=ReplacementMigrationTransaction(sourceSHA256:digest,beforeSettings:settings,beforeArchive:archiveEnhancements.preferences,beforeFiles:fileEnhancements.settings,beforeFinder:finderPreferences.preferences)
        }
        transaction!.state="prepared"
        try data.save(transaction!,name:"replacement-migration-v2.json")
        try data.save(receipt,name:"replacement-migration-v2-receipt.json")
        try data.save(plan.report,name:"replacement-right-migration-report.json")
        try data.save(plan.menuEntries,name:"replacement-right-menu-report.json")
        try fileEnhancements.installMigrationAttachments(plan)
        archiveEnhancements.preferences=archivePreferences;try archiveEnhancements.save()
        try fileEnhancements.update{$0=files}
        try finderPreferences.replaceForMigration(menu)
        settings=next
        guard dataHealthy else{throw DataFailure.message("配置迁移尚未提交，原快照与附件已保留。")}
        receipt.state="complete"
        try data.save(receipt,name:"replacement-migration-v2-receipt.json")
        transaction!.state="complete"
        try data.save(transaction!,name:"replacement-migration-v2.json")
        finderPreferences.publish(store:self)
        notify("配置迁移完成；原软件和待验项目已保留。")
    }

    func recoverInterruptedReplacementV2() throws {
        guard var transaction=try data.load("replacement-migration-v2.json",as:ReplacementMigrationTransaction.self) else{return}
        guard transaction.generation == 2,["prepared","restored","complete"].contains(transaction.state) else {
            throw DataFailure.message("完整迁移日志版本或状态未知，停止写入。")
        }
        if transaction.state == "restored" {
            if var receipt=try data.load("replacement-migration-v2-receipt.json",as:ReplacementMigrationReceipt.self) {
                guard receipt.sourceSHA256 == transaction.sourceSHA256 else {throw DataFailure.message("迁移回执来源不符。")}
                if receipt.state != "restored" {receipt.state="restored";try data.save(receipt,name:"replacement-migration-v2-receipt.json")}
            }
            return
        }
        guard transaction.state == "prepared" else{return}
        archiveEnhancements.preferences=transaction.beforeArchive;try archiveEnhancements.save()
        try fileEnhancements.update{$0=transaction.beforeFiles}
        try finderPreferences.replaceForMigration(transaction.beforeFinder)
        settings=transaction.beforeSettings
        guard dataHealthy else{throw DataFailure.message("完整迁移恢复尚未完成，保留全部快照。")}
        if var receipt=try data.load("replacement-migration-v2-receipt.json",as:ReplacementMigrationReceipt.self) {
            guard receipt.sourceSHA256 == transaction.sourceSHA256 else {throw DataFailure.message("迁移回执来源不符。")}
            receipt.state="restored";try data.save(receipt,name:"replacement-migration-v2-receipt.json")
        }
        transaction.state="restored";try data.save(transaction,name:"replacement-migration-v2.json")
        message="上次完整迁移中断，已恢复迁移前配置；新附件、原软件及安全备份保留。"
    }
}
