import Foundation

enum InputMigrationExecutionPolicy {
    /// Recompute candidates from the retained source, rather than trusting mutable
    /// origin/exact flags in an imported JSON. Parsing is bounded and never executes.
    static func expectedRules(_ configuration:InputEnhancementConfiguration)throws->[String:[UUID:EnhancedInputRule]] {
        var result:[String:[UUID:EnhancedInputRule]]=[:]
        for source in configuration.migrationSources {
            try source.verify()
            guard let dictionary=try PropertyListSerialization.propertyList(from:source.operationalPlist,format:nil) as? [String:Any] else {throw SystemControlError.message("输入操作档案格式无效。")}
            let parsed=try BABRuleImporter.importRules(dictionary,originalData:source.operationalPlist,validatingConfiguration:false)
            result[source.sha256]=Dictionary(uniqueKeysWithValues:parsed.configuration.rules.map{($0.migrationOrigin!.rowID,$0)})
        }
        return result
    }
    static func blockReason(_ rule:EnhancedInputRule,expected:EnhancedInputRule?,
                            verification:Set<String>?=nil)throws->String? {
        guard let origin=rule.migrationOrigin else{return nil}
        guard let expected,let original=expected.migrationOrigin,original.disposition == .exact,
              origin.disposition == .exact,origin.sourceEnabled==original.sourceEnabled,
              Set(origin.requirements)==Set(original.requirements),
              Set(origin.verifiedRequirements).isSubset(of:Set(original.requirements)) else {
            return "输入来源审计与原始操作快照不一致，保持暂停。"
        }
        guard try InputMigrationFingerprint.legacyRule(rule,ignoringEnabled:true)==InputMigrationFingerprint.legacyRule(expected,ignoringEnabled:true) else {
            return "迁入规则已改变原触发、范围或动作，请作为新规则审阅；原来源规则保持暂停。"
        }
        let verified=verification ?? Set(origin.verifiedRequirements)
        guard Set(original.requirements).isSubset(of:verified) else {return "输入迁移所需设备或目标行为尚未核验，保持暂停。"}
        return nil
    }
}
