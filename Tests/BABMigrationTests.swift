import Foundation
import AppKit

@MainActor func runBABMigrationTests() throws {
    var checks=0
    func check(_ value:Bool,_ message:String)throws {guard value else {throw SystemControlError.message("BAB迁移："+message)};checks+=1}
    func rejects(_ operation:()throws->Void,_ message:String)throws {do {try operation()} catch {checks+=1;return};throw SystemControlError.message("BAB迁移未拒绝："+message)}
    func keyboard(_ key:Int=123,_ enabled:Any="1",_ preset:String="half_of_Left")->[String:Any] {
        ["Gesture":["keyCode":key,"modifierFlags":524288],"Modifier":" -","Enable":enabled,"Note":"原创键盘规则",
         "Action":["ActionType":"Preset","Action":preset]]
    }
    func document(_ rows:[[String:Any]],scope:String="All Applications")->[String:Any] {
        ["ruleOfKeyboard":[["AppName":scope,"All Rules":rows]]]
    }
    let first=try EnhancedRuleFiles.importBAB(document([keyboard()]))
    try check(first.configuration.rules.count==1 && first.report?.rows.count==1,"转换与审计条目对应")
    try check(first.report?.rows[0].sourceEnabled==true && first.report?.rows[0].disposition == .exact,"字符串源Enable保留为明确true")
    try check(first.configuration.rules[0].effect.windowTargetMode == .frontmost,"源缺失指针开关明确使用前台，不继承将来全局指针偏好")
    try check(!first.configuration.enabled && !first.configuration.rules[0].enabled,"仅导入不自动接管")
    let again=try EnhancedRuleFiles.importBAB(document([keyboard()]))
    try check(first.configuration.rules[0].id==again.configuration.rules[0].id,"来源ID不依赖随机UUID")
    let disabled=try EnhancedRuleFiles.importBAB(document([keyboard(123,0)]))
    var disabledConfiguration=disabled.configuration
    try check(try EnhancedRuleFiles.activateReadyRules(in:&disabledConfiguration,sourceDigest:disabled.report!.sha256).isEmpty,"源禁用规则不会被接管启用")
    let uncertain=try EnhancedRuleFiles.importBAB(document([keyboard(123,"yes")]))
    try check(uncertain.report?.rows[0].sourceEnabled==nil && uncertain.report?.rows[0].disposition == .requiresReview,"未知Enable不默认为true")
    var activatable=first.configuration
    let ids=try EnhancedRuleFiles.activateReadyRules(in:&activatable,sourceDigest:first.report!.sha256)
    try check(ids.count==1 && activatable.enabled && activatable.rules[0].enabled,"已精确映射的源启用规则可明确接管")
    var forged=first.configuration;forged.rules[0].effect.kind = .appleScript;forged.rules[0].effect.script="return 999"
    try check(try EnhancedRuleFiles.activateReadyRules(in:&forged,sourceDigest:first.report!.sha256).isEmpty,"篡改候选动作为脚本但保留exact不能激活")
    forged.rules[0].enabled=true
    try rejects({try EnhancedInputValidation.validate(forged)},"运行验证将候选实际字段与原来源绑定")
    let badScope=try EnhancedRuleFiles.importBAB(document([keyboard()],scope:"An Ambiguous Display Name"))
    try check(badScope.configuration.rules.isEmpty && badScope.report?.rows[0].disposition == .unavailable,"未解析显示名不扩大为全局")
    let absentScope:[String:Any]=["ruleOfKeyboard":[["All Rules":[keyboard()]]]]
    try check(try EnhancedRuleFiles.importBAB(absentScope).configuration.rules.isEmpty,"缺失作用域不扩大为全局")
    var explicitScope=document([keyboard()],scope:"Example Editor")
    explicitScope["ruleOfKeyboard"]=[["AppName":"Example Editor","BundleIdentifier":"com.example.editor","All Rules":[keyboard()]]]
    try check(try EnhancedRuleFiles.importBAB(explicitScope).configuration.rules[0].appBundleID=="com.example.editor","明确Bundle ID可保留独立应用范围")
    var extended=keyboard();extended["FutureCondition"]=["nested":Data([1,2,3]),"date":Date(timeIntervalSinceReferenceDate:0.125)]
    var original=document([extended]);original["PassWord"]="DO-NOT-MIGRATE";original["analyticsSecret"]="DO-NOT-MIGRATE"
    let retained=try EnhancedRuleFiles.importBAB(original)
    let snapshot=try PropertyListSerialization.propertyList(from:retained.report!.operationalPlist,format:nil) as! [String:Any]
    try check(snapshot["PassWord"]==nil && snapshot["analyticsSecret"]==nil && retained.report?.omittedKeyCount==2,"不迁入凭据或遥测根字段")
    let retainedRows=((snapshot["ruleOfKeyboard"] as! [[String:Any]])[0]["All Rules"] as! [[String:Any]])
    let nested=retainedRows[0]["FutureCondition"] as! [String:Any]
    try check(nested["nested"] as? Data==Data([1,2,3]) && nested["date"] as? Date==Date(timeIntervalSinceReferenceDate:0.125),"未知嵌套Data和Date保持原类型和值")
    try check(retained.report?.rows[0].unknownKeys==["FutureCondition"] && retained.report?.rows[0].disposition == .requiresReview,"未知触发条件不能假装精确")
    let bytes=try PropertyListSerialization.data(fromPropertyList:document([keyboard()]),format:.xml,options:0)
    let fromBytes=try EnhancedRuleFiles.decode(bytes)
    try check(fromBytes.report?.originalBytesPreserved==true && fromBytes.report?.operationalPlist==bytes,"已选择操作快照保持逐字节原件")
    var corrupted=fromBytes.report!;corrupted.operationalPlist.append(0)
    try rejects({try corrupted.verify()},"档案摘要变化")
    var badActivation=first.configuration;badActivation.migrationSources[0]=corrupted
    let beforeBadActivation=badActivation
    try rejects({_ = try EnhancedRuleFiles.activateReadyRules(in:&badActivation,sourceDigest:first.report!.sha256)},"激活前发现档案损坏")
    try check(badActivation==beforeBadActivation,"激活验证失败不会留下部分enabled修改")
    var invalidKey=keyboard();invalidKey["Gesture"]=["keyCode":65536,"modifierFlags":524288]
    try check(try EnhancedRuleFiles.importBAB(document([invalidKey])).configuration.rules.isEmpty,"键码不截断溢出为其他按键")
    invalidKey=keyboard();invalidKey["Gesture"]=["keyCode":123,"modifierFlags":524288,"hold":1]
    try check(try EnhancedRuleFiles.importBAB(document([invalidKey])).configuration.rules.isEmpty,"未知按键附加条件不丢弃")
    func touch(_ gesture:String)->[String:Any] {["Gesture":gesture,"Modifier":"Fn","Enable":"1","Action":["ActionType":"Preset","Action":"Quarte_of_Top_Left"]]}
    let touchSource:[String:Any]=["ruleOfTrackPad":[["AppName":"All Applications","All Rules":[touch("1Finger_Tap_Top_Left")]]]]
    let convertedTouch=try EnhancedRuleFiles.importBAB(touchSource)
    try check(convertedTouch.configuration.rules[0].touchRegion=="topLeft" && convertedTouch.configuration.rules[0].modifiers==UInt64(NSEvent.ModifierFlags.function.rawValue),"Fn与四角精确保留，不附加Option")
    var gated=convertedTouch.configuration
    var forgedRequirements=convertedTouch.configuration;forgedRequirements.rules[0].migrationOrigin?.requirements=[]
    try check(try EnhancedRuleFiles.activateReadyRules(in:&forgedRequirements,sourceDigest:convertedTouch.report!.sha256).isEmpty,"伪造空requirements不能绕过真实触控核验")
    forgedRequirements.rules[0].enabled=true
    try rejects({try EnhancedInputValidation.validate(forgedRequirements)},"运行验证拒绝伪造来源门限")
    try check(try EnhancedRuleFiles.activateReadyRules(in:&gated,sourceDigest:convertedTouch.report!.sha256).isEmpty,"未核验触控不能自动启用")
    gated.rules[0].enabled=true
    try rejects({try EnhancedInputValidation.validate(gated)},"单改enabled绕过触控核验")
    gated=convertedTouch.configuration
    _=try EnhancedRuleFiles.activateReadyRules(in:&gated,sourceDigest:convertedTouch.report!.sha256,verifiedRequirements:["rawTouchHardware"])
    let reloaded=try JSONDecoder().decode(InputEnhancementConfiguration.self,from:JSONEncoder().encode(gated))
    try check(reloaded.rules[0].migrationOrigin?.verifiedRequirements==["rawTouchHardware"] && reloaded.rules[0].enabled,"核验声明持久保存，非临时过滤")
    for gesture in ["1Finger_TipTap_Tap","2Finger_LeftFinger_SwipeLeft","1Finger_Tap_Top_Left_Unknown"] {
        let value:[String:Any]=["ruleOfTrackPad":[["AppName":"All Applications","All Rules":[touch(gesture)]]]]
        try check(try EnhancedRuleFiles.importBAB(value).configuration.rules.isEmpty,"拒绝把复合/未知触控简化为普通轻点或滑动")
    }
    let magic:[String:Any]=["ruleOfMagicMouse":[["AppName":"All Applications","All Rules":[touch("1Finger_Tap")]]]]
    try check(try EnhancedRuleFiles.importBAB(magic).configuration.rules.isEmpty,"MagicMouse不回退触控板")
    var underCursor=keyboard();underCursor["EnableUnderCursor"]="1"
    let pointer=try EnhancedRuleFiles.importBAB(document([underCursor]))
    try check(pointer.configuration.rules[0].effect.windowTargetMode == .underPointer && pointer.report?.rows[0].requirements==["pointerWindowTarget"],"原指向目标不退化为前台目标，仍需真实核验")
    var explicitFront=keyboard();explicitFront["EnableUnderCursor"]="0"
    try check(try EnhancedRuleFiles.importBAB(document([explicitFront])).configuration.rules[0].effect.windowTargetMode == .frontmost,"源false明确前台")
    let oldEffect=try JSONDecoder().decode(InputEffect.self,from:Data("{\"kind\":\"action\",\"actionID\":\"window.leftHalf\"}".utf8))
    try check(oldEffect.windowTargetMode == .inheritSettings,"旧JSON保留原继承设置行为")
    var legacyDelivery=0,explicitDelivery:InputWindowTargetMode?
    try rejects({try InputActionDelivery.perform("window.leftHalf",mode:.frontmost,legacy:{_ in legacyDelivery+=1},invocation:nil)},"明确前台目标无新handler不能旧fallback")
    try check(legacyDelivery==0,"缺精确目标接线时零错误目标递交")
    try InputActionDelivery.perform("window.leftHalf",mode:.underPointer,legacy:{_ in legacyDelivery+=1},invocation:{_,mode in explicitDelivery=mode})
    try check(explicitDelivery == .underPointer && legacyDelivery==0,"指针目标模式原值递交给精确handler")
    try InputActionDelivery.perform("window.leftHalf",mode:.inheritSettings,legacy:{_ in legacyDelivery+=1},invocation:nil)
    try check(legacyDelivery==1,"旧继承模式仅按原handler递交一次")
    let zoom=try EnhancedRuleFiles.importBAB(document([keyboard(6,"1","Zoom")]))
    var zoomConfiguration=zoom.configuration;zoomConfiguration.rules[0].enabled=true
    try rejects({try EnhancedInputValidation.validate(zoomConfiguration)},"原Zoom未经语义确认不能运行最大化替代")
    let legacySource=document([keyboard()])
    let legacy=try EnhancedRuleFiles.legacyImportBAB(legacySource).configuration
    let oldID=legacy.rules[0].id
    let upgrade=try EnhancedRuleFiles.mergeBABUpgrade(imported:first,into:legacy,legacySource:legacySource)
    try check(upgrade.configuration.rules.count==1 && upgrade.configuration.rules[0].id==oldID && upgrade.upgraded==1 && upgrade.added==0,"旧随机UUID规则原位升级，不另添重复项")
    let replay=try EnhancedRuleFiles.mergeBABUpgrade(imported:again,into:upgrade.configuration,legacySource:legacySource)
    try check(replay.configuration.rules.count==1 && replay.added==0 && replay.upgraded==0,"同一操作快照重放无副作用")
    var changed=legacy;changed.rules[0].effect.actionID="window.rightHalf"
    let userPreserved=try EnhancedRuleFiles.mergeBABUpgrade(imported:first,into:changed,legacySource:legacySource)
    try check(userPreserved.configuration.rules==changed.rules && userPreserved.added==0 && userPreserved.preserved==1,"用户修改动作后不覆盖也不另添旁路")
    var renamedLegacy=legacy;renamedLegacy.rules[0].name="用户修改后的规则名称"
    let renamedPreserved=try EnhancedRuleFiles.mergeBABUpgrade(imported:first,into:renamedLegacy,legacySource:legacySource)
    try check(renamedPreserved.configuration.rules==renamedLegacy.rules && renamedPreserved.added==0 && renamedPreserved.upgraded==0,"用户改名后不凭触发或数组位置强行对应旧来源")
    let deletedPreserved=try EnhancedRuleFiles.mergeBABUpgrade(imported:first,into:.init(),legacySource:legacySource)
    try check(deletedPreserved.configuration.rules.isEmpty && deletedPreserved.added==0 && deletedPreserved.preserved==1,"旧解析能映射但已删除的规则不重新添加")
    let duplicateSource=document([keyboard(),keyboard()])
    let duplicateImported=try EnhancedRuleFiles.importBAB(duplicateSource)
    let duplicateLegacy=try EnhancedRuleFiles.legacyImportBAB(duplicateSource).configuration
    let duplicatePreserved=try EnhancedRuleFiles.mergeBABUpgrade(imported:duplicateImported,into:duplicateLegacy,legacySource:duplicateSource)
    try check(duplicatePreserved.configuration.rules==duplicateLegacy.rules && duplicatePreserved.added==0 && duplicatePreserved.upgraded==0,"来源与现有两侧均重复的指纹不能靠claimed先后顺序误配")
    try check(duplicatePreserved.configuration.migrationSources[0].rows.allSatisfy{$0.disposition == .preservedUserChange && $0.mappedRuleID == nil},"歧义来源全部保留审计，不声称唯一旧UUID升级")
    let sourceAmbiguous=try EnhancedRuleFiles.mergeBABUpgrade(imported:duplicateImported,into:legacy,legacySource:duplicateSource)
    try check(sourceAmbiguous.configuration.rules==legacy.rules && sourceAmbiguous.added==0 && sourceAmbiguous.upgraded==0,"两个相同来源候选不能抢占同一个现有规则")
    var duplicatedCurrent=legacy;var sameRule=legacy.rules[0];sameRule.id=UUID();duplicatedCurrent.rules.append(sameRule)
    let currentAmbiguous=try EnhancedRuleFiles.mergeBABUpgrade(imported:first,into:duplicatedCurrent,legacySource:legacySource)
    try check(currentAmbiguous.configuration.rules==duplicatedCurrent.rules && currentAmbiguous.added==0 && currentAmbiguous.upgraded==0,"单个来源不能任意选择两个相同现有规则之一")
    let ambiguousReplay=try EnhancedRuleFiles.mergeBABUpgrade(imported:duplicateImported,into:duplicatePreserved.configuration,legacySource:duplicateSource)
    try check(ambiguousReplay.configuration==duplicatePreserved.configuration && ambiguousReplay.added==0 && ambiguousReplay.upgraded==0,"歧义来源重放仍不添加或重新对应规则")
    var enabledLegacy=try EnhancedRuleFiles.legacyImportBAB(document([keyboard(6,"1","Zoom")])).configuration;enabledLegacy.rules[0].enabled=true
    let corrected=try EnhancedRuleFiles.mergeBABUpgrade(imported:zoom,into:enabledLegacy,legacySource:document([keyboard(6,"1","Zoom")]))
    try check(corrected.configuration.rules[0].id==enabledLegacy.rules[0].id && !corrected.configuration.rules[0].enabled && corrected.configuration.rules[0].migrationOrigin?.disposition == .requiresReview,"旧仅启用的错误Zoom映射保留UUID并门控暂停")
    let unsafeRow:[String:Any]=["Gesture":"1Finger_LeftFinger_SwipeLeft","Modifier":" -","Enable":1,"Action":["ActionType":"Preset","Action":"half_of_Left"]]
    let oldUnsafe:[String:Any]=["ruleOfTrackPad":[["AppName":"All Applications","All Rules":[unsafeRow]]]]
    var oldUnsafeConfig=try EnhancedRuleFiles.legacyImportBAB(oldUnsafe).configuration;oldUnsafeConfig.rules[0].enabled=true
    let unsupported=try EnhancedRuleFiles.importBAB(oldUnsafe)
    let quarantined=try EnhancedRuleFiles.mergeBABUpgrade(imported:unsupported,into:oldUnsafeConfig,legacySource:oldUnsafe)
    try check(!quarantined.configuration.rules[0].enabled && quarantined.configuration.rules[0].migrationOrigin?.disposition == .unavailable,"新无candidate时旧过宽触发也加来源门控，不能继续执行")
    let second=try EnhancedRuleFiles.importBAB(document([keyboard(124)],scope:"com.example.editor"))
    var multi=first.configuration;multi.rules+=second.configuration.rules;multi.migrationSources+=second.configuration.migrationSources
    var manual=EnhancedInputRule();manual.name="手工原创";multi.rules.append(manual)
    var scroll=ScrollDeviceProfile();scroll.enabled=true;multi.scrollProfiles=[scroll]
    var hid=HIDDeviceProfile();hid.deviceID="hid:fixture:only";hid.enabled=true;multi.hidProfiles=[hid]
    var script=InputScript();script.name="原创未运行脚本";script.source="return 123";multi.scriptLibrary=[script]
    let merged=try EnhancedRuleFiles.mergeInputConfiguration(multi,into:.init())
    try check(merged.configuration.migrationSources.count==2 && merged.configuration.rules.count==3,"nativeJSON多来源与手工规则均保留")
    try check(merged.configuration.scrollProfiles.count==1 && !merged.configuration.scrollProfiles[0].enabled && merged.configuration.hidProfiles.count==1 && !merged.configuration.hidProfiles[0].enabled,"nativeJSON滚轮/HID导入完整且暂停")
    try check(merged.configuration.scriptLibrary==[script],"nativeJSON脚本只保留，未启动进程")
    let mergedAgain=try EnhancedRuleFiles.mergeInputConfiguration(multi,into:merged.configuration)
    try check(mergedAgain.configuration.rules.count==3 && mergedAgain.configuration.migrationSources.count==2,"完整nativeJSON重放幂等")
    var open=keyboard();open["Action"]=["ActionType":"Preset","Action":"Open...","OpenArr":["/Applications/Fixture.app","https://example.invalid/"]]
    let opened=try EnhancedRuleFiles.importBAB(document([open]))
    try check(opened.configuration.rules[0].effect.kind == .openTargets && opened.configuration.rules[0].effect.openTargets.count==2,"明确OpenArr原值精确迁移，导入不启动目标")
    var delivered=0
    try rejects({try InputOpenTargets.perform(["https://example.invalid/","/missing-fixture"],exists:{_ in false},open:{_ in delivered+=1;return true})},"先整批预检，缺失目标前不部分打开")
    try check(delivered==0,"打开预检失败零投递")
    try rejects({_ = try InputOpenTargets.urls(["javascript:alert(1)"])},"不执行未知URL协议")
    try rejects({_ = try InputOpenTargets.urls(["https://user:secret@example.invalid"])},"不迁移含凭据URL")
    try rejects({_ = try InputOpenTargets.urls(["file://other-host/private/file"])},"拒绝远程文件目标")
    var legacyScriptSource=legacySource;legacyScriptSource["ruleOfAppleScript"]=[["Name":"原创脚本","AppleScript":"return 7"]]
    let oldScriptConfig=try EnhancedRuleFiles.legacyImportBAB(legacyScriptSource).configuration
    let newScriptPayload=try EnhancedRuleFiles.importBAB(legacyScriptSource)
    let scriptUpgrade=try EnhancedRuleFiles.mergeBABUpgrade(imported:newScriptPayload,into:oldScriptConfig,legacySource:legacyScriptSource)
    try check(scriptUpgrade.configuration.scriptLibrary==oldScriptConfig.scriptLibrary,"旧随机脚本UUID与用户版本保留，不重添脚本")
    var scriptAudited=document([keyboard()])
    scriptAudited["ruleOfAppleScript"]=[["Name":"原脚本","AppleScript":"return 1","Enable":"1","FutureCondition":7],
        ["Name":"缺失源码","AppleScript":Data([1])]]
    scriptAudited["ruleOfFutureDevice"]=["original":Data([2,3])]
    let scriptReport=try EnhancedRuleFiles.importBAB(scriptAudited)
    let scriptRows=scriptReport.report!.rows.filter{$0.module=="ruleOfAppleScript"}
    try check(scriptRows.count==2 && scriptRows[0].disposition == .requiresReview && scriptRows[1].disposition == .unavailable,"脚本条目逐项列原因，缺失源码不静默跳过")
    try check(scriptRows[0].unknownKeys==["FutureCondition"] && scriptReport.configuration.scriptLibrary.count==1,"脚本未知字段保留且不会自动执行")
    try check(scriptReport.report!.rows.contains{$0.module=="ruleOfFutureDevice" && $0.disposition == .unavailable},"未知规则模块显式列为未转换，原值仍保留")
    let scriptReplayed=try EnhancedRuleFiles.mergeInputConfiguration(scriptReport.configuration,into:.init())
    try check(scriptReplayed.configuration.scriptLibrary.count==1 && scriptReplayed.configuration.migrationSources[0].rows.count==4,"脚本和未知模块来源审计能合并往返")
    print("PASS: \(checks)项BAB来源保真、精确映射、旧UUID三向升级、设备门控与重放测试；未读真实配置、运行脚本或操作GUI")
}

/// Explicit, read-only audit of a human-authorized historical migration snapshot.
/// It does not activate rules, run scripts, resolve private protocols or write App data.
@MainActor func runPrivateInputMigrationAudit(snapshot:URL,report:URL)throws {
    let attributes=try FileManager.default.attributesOfItem(atPath:snapshot.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular,
          ((attributes[.size] as? NSNumber)?.intValue ?? Int.max) <= 16*1024*1024 else {
        throw SystemControlError.message("来源快照不是预算内普通文件。")
    }
    let bytes=try Data(contentsOf:snapshot)
    guard let document=try PropertyListSerialization.propertyList(from:bytes,format:nil) as? [String:Any],
          let input=document["input"] as? [String:Any] else {throw SystemControlError.message("来源快照缺少独立 input 产品字段。")}
    let parsed=try EnhancedRuleFiles.importBAB(input),source=parsed.report!
    let candidates=Dictionary(uniqueKeysWithValues:parsed.configuration.rules.map{($0.migrationOrigin!.rowID,$0)})
    let rows:[[String:Any]]=source.rows.map {row in
        var value:[String:Any]=["sourceProduct":"Better And Better","module":row.module,"groupIndex":row.groupIndex,
            "rowIndex":row.rowIndex,"disposition":row.disposition.rawValue,"requirements":row.requirements,
            "reason":row.reason,"unknownKeys":row.unknownKeys,"sourceEnabled":row.sourceEnabled.map{$0 as Any} ?? NSNull()]
        if let rule=candidates[row.id] {
            value["mapping"]=["trigger":rule.trigger.rawValue,"actionKind":rule.effect.kind.rawValue,"actionID":rule.effect.actionID,
                "windowTargetMode":rule.effect.windowTargetMode.rawValue,"enabled":rule.enabled]
        }
        return value
    }
    let counts=Dictionary(grouping:source.rows,by:{$0.disposition.rawValue}).mapValues(\.count)
    let scripts=parsed.configuration.scriptLibrary.map{["id":$0.id.uuidString,"sourceSHA256":InputMigrationFingerprint.digest(Data($0.source.utf8)),"utf8Bytes":$0.source.utf8.count,"executed":false] as [String:Any]}
    let value:[String:Any]=["schema":1,"sourceProduct":"Better And Better","sourceSnapshotSHA256":InputMigrationFingerprint.digest(bytes),
        "operationalSnapshotSHA256":source.sha256,"rows":rows,"counts":counts,"retainedOperationalKeys":source.retainedKeys,
        "omittedNonOperationalKeyCount":source.omittedKeyCount,"scripts":scripts,"allImportedRulesPaused":parsed.configuration.rules.allSatisfy{!$0.enabled},
        "actualCurrentDataModified":false,"scriptsExecuted":false,"hardwareVerified":false,
        "scope":"仅重新解析已有合法历史 input 快照；不是其他三产品迁移统计，也不证明当前替代完成。"]
    let data=try JSONSerialization.data(withJSONObject:value,options:[.prettyPrinted,.sortedKeys])
    try data.write(to:report,options:.atomic)
    try FileManager.default.setAttributes([.posixPermissions:0o600],ofItemAtPath:report.path)
    print("PASS: 只读重新解析 BAB 原快照；\(rows.count)条逐项来源审计；未激活规则、执行脚本或改动真实资料")
}
