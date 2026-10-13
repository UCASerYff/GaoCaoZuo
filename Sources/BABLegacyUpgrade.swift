import Foundation

extension EnhancedRuleFiles {
    static func mergeBABUpgrade(imported:EnhancedRuleImportResult,into current:InputEnhancementConfiguration,
                               legacySource:[String:Any]?=nil)throws->EnhancedRuleMergeResult {
        guard var source=imported.report else {throw SystemControlError.message("输入导入缺少逐项来源档案。")}
        try source.verify();try EnhancedInputValidation.validate(current);try EnhancedInputValidation.validate(imported.configuration)
        let semanticDigest=try source.semanticDigest()
        if try current.migrationSources.contains(where:{retained in
            if retained.sha256==source.sha256 {return true}
            return try retained.semanticDigest()==semanticDigest
        }) {
            return .init(configuration:current,added:0,upgraded:0,preserved:0,blocked:source.rows.filter{$0.disposition != .exact}.count,note:"相同输入操作快照已导入，未重复添加或改变现有规则。")
        }
        var result=current,added=0,upgraded=0,preserved=0
        let legacy=try legacySource.map{try legacyRows($0)} ?? [:]
        let exactCounts=Dictionary(grouping:try legacy.values.map{try InputMigrationFingerprint.legacyRule($0)},by:{$0}).mapValues(\.count)
        let relaxedCounts=Dictionary(grouping:try legacy.values.map{try InputMigrationFingerprint.legacyRule($0,ignoringEnabled:true)},by:{$0}).mapValues(\.count)
        let candidatePairs=imported.configuration.rules.map{($0.migrationOrigin?.rowID ?? $0.id,$0)}
        guard Set(candidatePairs.map(\.0)).count==candidatePairs.count else {throw SystemControlError.message("输入来源条目重复，停止导入。")}
        let candidates=Dictionary(uniqueKeysWithValues:candidatePairs)
        var claimed=Set<UUID>()
        for i in source.rows.indices {
            let row=source.rows[i],key=legacyKey(row.module,row.groupIndex,row.rowIndex)
            source.rows[i].mappedRuleID=nil
            let old=legacy[key]
            let provenanceMatches=result.rules.indices.filter{result.rules[$0].migrationOrigin?.rowID==row.id}
            var destination:Int?
            if provenanceMatches.count==1 {destination=provenanceMatches[0]}
            else if provenanceMatches.count>1 {
                source.rows[i].disposition = .preservedUserChange;source.rows[i].reason="相同来源对应多个现有条目，保留全部并停止自动替换。";preserved+=1;continue
            } else if let old {
                let expected=try InputMigrationFingerprint.legacyRule(old)
                guard exactCounts[expected] == 1 else {
                    source.rows[i].disposition = .preservedUserChange;source.rows[i].reason="多个旧来源条目具有相同指纹，无法唯一对应；现有规则保留，未另添替代。";preserved+=1;continue
                }
                var matches=try result.rules.indices.filter {index in
                    guard result.rules[index].migrationOrigin==nil else{return false}
                    return try InputMigrationFingerprint.legacyRule(result.rules[index])==expected
                }
                if matches.isEmpty {
                    let enabledIndependent=try InputMigrationFingerprint.legacyRule(old,ignoringEnabled:true)
                    guard relaxedCounts[enabledIndependent] == 1 else {
                        source.rows[i].disposition = .preservedUserChange;source.rows[i].reason="忽略暂停状态后旧来源指纹仍有歧义，现有规则保留。";preserved+=1;continue
                    }
                    matches=try result.rules.indices.filter {index in
                        guard result.rules[index].migrationOrigin==nil else{return false}
                        return try InputMigrationFingerprint.legacyRule(result.rules[index],ignoringEnabled:true)==enabledIndependent
                    }
                }
                if matches.count==1 && !claimed.contains(result.rules[matches[0]].id) {destination=matches[0]}
                else {
                    // An edited old rule cannot be located by name or array position.
                    // Do not add a parallel replacement that could bypass that edit.
                    source.rows[i].disposition = .preservedUserChange;source.rows[i].reason="旧来源存在此条目，但现有条目已修改、缺失或无法唯一对应；未覆盖或另添替代项。";preserved+=1;continue
                }
            }
            guard var candidate=candidates[row.id] else {
                if let destination {
                    let id=result.rules[destination].id
                    result.rules[destination].migrationOrigin = .init(sourceDigest:source.sha256,rowID:row.id,sourceEnabled:row.sourceEnabled,
                        disposition:.unavailable,requirements:row.requirements,reason:row.reason)
                    result.rules[destination].enabled=false
                    source.rows[i].mappedRuleID=id;claimed.insert(id);upgraded+=1
                }
                continue
            }
            if let destination {
                let existing=result.rules[destination]
                // Provenance from an earlier precise import is evidence, not permission
                // to overwrite edits or a user's later enabled/disabled choice.
                if existing.migrationOrigin != nil {
                    var comparison=candidate;comparison.id=existing.id
                    let unchanged=try InputMigrationFingerprint.legacyRule(existing)==InputMigrationFingerprint.legacyRule(comparison)
                    guard unchanged else {
                        source.rows[i].disposition = .preservedUserChange;source.rows[i].reason="用户已调整此来源条目，现有规则与UUID保留。";source.rows[i].mappedRuleID=existing.id;preserved+=1;continue
                    }
                }
                candidate.id=existing.id;candidate.enabled=existing.enabled
                if EnhancedInputValidation.migrationBlockReason(candidate) != nil {candidate.enabled=false}
                result.rules[destination]=candidate;claimed.insert(candidate.id);source.rows[i].mappedRuleID=candidate.id;upgraded+=1
            } else {
                guard !result.rules.contains(where:{$0.id==candidate.id}) else {throw SystemControlError.message("输入来源ID与现有规则冲突，停止导入。")}
                result.rules.append(candidate);source.rows[i].mappedRuleID=candidate.id;added+=1
            }
        }
        let oldScripts=try legacySource.map{try legacyImportBAB($0).configuration.scriptLibrary} ?? []
        for (index,script) in imported.configuration.scriptLibrary.enumerated() {
            if result.scriptLibrary.contains(where:{$0.id==script.id}) {continue}
            if index<oldScripts.count,oldScripts[index].name==script.name,oldScripts[index].source==script.source {
                // Legacy scripts have random IDs. An exact match is kept with that ID;
                // absence can mean a user edit/deletion, which must not be undone.
                continue
            }
            if !result.scriptLibrary.contains(where:{$0.name==script.name && $0.source==script.source}) {result.scriptLibrary.append(script)}
        }
        result.migrationSources.append(source)
        try EnhancedInputValidation.validate(result)
        let blocked=source.rows.filter{$0.disposition != .exact || !$0.requirements.isEmpty}.count
        return .init(configuration:result,added:added,upgraded:upgraded,preserved:preserved,blocked:blocked,
            note:"输入升级：保留UUID更新 \(upgraded) 条，新增 \(added) 条，保留用户变更 \(preserved) 条；\(blocked) 条需语义或设备验收。高级开关和现有启用状态未擅自改变。")
    }
    /// Merge every source archive plus native manual rules/profiles/scripts. A native
    /// export can contain several BAB imports; taking only its first report loses data.
    static func mergeInputConfiguration(_ imported:InputEnhancementConfiguration,into current:InputEnhancementConfiguration,
        legacySource:[String:Any]?=nil)throws->EnhancedRuleMergeResult {
        try EnhancedInputValidation.validate(imported);try EnhancedInputValidation.validate(current)
        var result=current,added=0,upgraded=0,preserved=0,blocked=0
        for source in imported.migrationSources {
            var part=InputEnhancementConfiguration();part.migrationSources=[source]
            part.rules=imported.rules.filter{$0.migrationOrigin?.sourceDigest==source.sha256}
            let value=try mergeBABUpgrade(imported:.init(configuration:part,note:source.note,report:source),into:result,legacySource:legacySource)
            result=value.configuration;added+=value.added;upgraded+=value.upgraded;preserved+=value.preserved;blocked+=value.blocked
        }
        for var rule in imported.rules where rule.migrationOrigin==nil {
            guard !result.rules.contains(where:{$0.id==rule.id}) else{preserved+=1;continue}
            rule.enabled=false;result.rules.append(rule);added+=1
        }
        for var profile in imported.scrollProfiles where !result.scrollProfiles.contains(where:{$0.id==profile.id}) {profile.enabled=false;result.scrollProfiles.append(profile)}
        for var profile in imported.hidProfiles where !result.hidProfiles.contains(where:{$0.id==profile.id}) {profile.enabled=false;result.hidProfiles.append(profile)}
        let oldScripts=try legacySource.map{try legacyImportBAB($0).configuration.scriptLibrary} ?? []
        for script in imported.scriptLibrary {
            guard !result.scriptLibrary.contains(where:{$0.id==script.id || $0.name==script.name && $0.source==script.source}),
                  !oldScripts.contains(where:{$0.name==script.name && $0.source==script.source}) else{continue}
            result.scriptLibrary.append(script)
        }
        try EnhancedInputValidation.validate(result)
        return .init(configuration:result,added:added,upgraded:upgraded,preserved:preserved,blocked:blocked,
            note:"输入合并：新增 \(added) 条，升级 \(upgraded) 条，保留现有变更 \(preserved) 条；完整保留所有来源档案及手工配置，导入内容保持暂停。")
    }
    /// Only exact source-enabled rules with explicitly satisfied runtime requirements
    /// are activated. Scripts, ambiguous mappings and unverified devices remain paused.
    @discardableResult static func activateReadyRules(in configuration:inout InputEnhancementConfiguration,
        sourceDigest:String,verifiedRequirements:Set<String>=[])throws->[UUID] {
        var next=configuration,activated:[UUID]=[]
        let expected=try InputMigrationExecutionPolicy.expectedRules(next)
        for i in next.rules.indices {
            guard let origin=next.rules[i].migrationOrigin,origin.sourceDigest==sourceDigest,
                  origin.sourceEnabled==true,origin.disposition == .exact,
                  Set(origin.requirements).isSubset(of:verifiedRequirements) else {continue}
            guard try InputMigrationExecutionPolicy.blockReason(next.rules[i],expected:expected[origin.sourceDigest]?[origin.rowID],verification:verifiedRequirements)==nil else {continue}
            next.rules[i].migrationOrigin?.verifiedRequirements=origin.requirements
            next.rules[i].enabled=true;activated.append(next.rules[i].id)
        }
        if !activated.isEmpty {next.enabled=true}
        try EnhancedInputValidation.validate(next);configuration=next;return activated
    }
    private static func legacyKey(_ module:String,_ group:Int,_ row:Int)->String {"\(module)|\(group)|\(row)"}
    private static func legacyRows(_ dictionary:[String:Any])throws->[String:EnhancedInputRule] {
        var result:[String:EnhancedInputRule]=[:],ordinal=0
        for module in BABRuleImporter.modules {
            for (gi,group) in (dictionary[module] as? [[String:Any]] ?? []).enumerated() {
                for (ri,original) in (group["All Rules"] as? [[String:Any]] ?? []).enumerated() {
                    ordinal+=1;var row=original
                    if (row["Note"] as? String).map({$0.isEmpty}) ?? true {row["Note"]="BAB 导入 \(ordinal)"}
                    var isolated=group;isolated["All Rules"]=[row]
                    let imported=try legacyImportBAB([module:[isolated]])
                    if let rule=imported.configuration.rules.first {result[legacyKey(module,gi,ri)]=rule}
                }
            }
        }
        return result
    }
}
