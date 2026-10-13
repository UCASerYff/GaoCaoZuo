import AppKit
import CoreFoundation

enum BABRuleImporter {
    static let modules=["ruleOfKeyboard","ruleOfNormalMouse","ruleOfTrackPad","ruleOfMagicMouse","ruleOfHotCorners"]
    static let operationalKeys:Set<String>=Set(modules+["ruleOfAppleScript","blacklistOfMiddleMouse","blacklistOfRightMouse",
        "enableAdjustMouseSpeed","mouseAcceleration","offMouseAcceleration","enableSmoothScroll","trackingSpeedOfSmoothScroll",
        "reverseMouseScrollX","reverseMouseScrollY","disableSmoothScrollOfHoldingModifierkey","bottomOutOfScrollWheel","SmoothScrollIndividualSetting",
        "oneFingerDrawingOfTrackTouch","oneFingerDrawingOfOutsideTrackTouch","drawingOfMultiTouch","enableRightMouseDrawingOfTrackpad",
        "enableMiddleMouseDrawingOfMagicMouse","enableRightMouseDrawingOfMagicMouse","simulateMiddleMouseFromMagicMouse",
        "widthOfSimulateMiddleMouseFromMagicMouse","heightOfSimulateMiddleMouseFromMagicMouse","disableClickMoreThenOneFinger",
        "disableScrollWheelMoreThenTwoFingers","disableInvalidKeyDrawingFunction","distanceOfStartDragged","distanceToTrackPadSides",
        "specialKeysOfNormalMouse","namesForKeys","MouseKeyInfo","HaveFittedMouse","displayTrackOfDrawing","lineWidthOfDrawing",
        "colorOfDrawingLine","displayActionOfTrackPad","displayActionOfMagicMouse","showActionOrNote","ActionOrNote","actionOrNoteRetetionTime"])
    static func operationalSnapshot(_ source:[String:Any])->[String:Any] {
        source.filter{operationalKeys.contains($0.key) || $0.key.hasPrefix("ruleOf")}
    }
    static func sourceBool(_ value:Any?)->Bool? {
        if let s=value as? String {if s=="1" {return true};if s=="0" {return false};return nil}
        guard let n=value as? NSNumber,n.doubleValue==0 || n.doubleValue==1 else{return nil};return n.boolValue
    }
    private static func integer(_ value:Any?,maximum:Int=127)throws->Int {
        guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,
              n.doubleValue.rounded(.towardZero)==n.doubleValue,n.doubleValue>=0,n.doubleValue<=Double(maximum) else {
            throw SystemControlError.message("键码或修饰键值不是受支持的整数。")
        };return n.intValue
    }
    static func scope(_ group:[String:Any])throws->String {
        guard let raw=group["AppName"] as? String else {throw SystemControlError.message("应用范围缺失，不能扩大为所有应用。")}
        let explicit=group["AppBundleID"] as? String ?? group["BundleIdentifier"] as? String
        if raw=="All Applications" {
            guard explicit==nil || explicit=="" else {throw SystemControlError.message("全局范围与应用标识冲突。")};return ""
        }
        let value=explicit ?? raw
        guard value.utf8.count<=256,value.range(of:"^[A-Za-z0-9_-]+(?:\\.[A-Za-z0-9_-]+)+$",options:.regularExpression) != nil else {
            throw SystemControlError.message("应用名称未提供可验证的Bundle ID，原范围保留但不执行。")
        }
        if let explicit,raw.contains("."),raw != explicit {throw SystemControlError.message("应用范围标识互相冲突。")}
        return value
    }
    static func rowID(module:String,groupIndex:Int,rowIndex:Int,row:[String:Any],scope:[String:Any])throws->UUID {
        let envelope:[String:Any]=["module":module,"group":groupIndex,"row":rowIndex,"scope":scope.filter{$0.key != "All Rules"},"value":row]
        return InputMigrationFingerprint.uuid(try InputMigrationFingerprint.canonical(envelope))
    }
    static func importRules(_ original:[String:Any],originalData:Data?=nil,validatingConfiguration:Bool=true)throws->EnhancedRuleImportResult {
        let source=operationalSnapshot(original)
        guard !source.isEmpty else {throw SystemControlError.message("没有可识别的输入操作设置。")}
        _=try InputMigrationFingerprint.canonical(source)
        let preservesOriginal=source.count==original.count && originalData != nil
        let bytes=try preservesOriginal ? originalData!:PropertyListSerialization.data(fromPropertyList:source,format:.binary,options:0)
        guard bytes.count<=8*1024*1024 else {throw SystemControlError.message("输入操作快照超过8MiB。")}
        let digest=InputMigrationFingerprint.digest(bytes)
        var configuration=InputEnhancementConfiguration(),rows:[InputMigrationRow]=[]
        if let library=source["ruleOfAppleScript"] as? [[String:Any]] {
            for (index,entry) in library.enumerated() {
                guard let script=entry["AppleScript"] as? String,script.utf8.count<=65536 else{continue}
                var item=InputScript();item.id=InputMigrationFingerprint.uuid(try InputMigrationFingerprint.canonical(["library":index,"entry":entry]))
                item.name=entry["Name"] as? String ?? "导入脚本";item.source=script;configuration.scriptLibrary.append(item)
            }
        }
        for module in modules {
            guard let rawGroups=source[module] else{continue}
            guard let groups=rawGroups as? [[String:Any]],groups.count<=100 else {throw SystemControlError.message("输入规则分组格式无效或过多。")}
            for (gi,group) in groups.enumerated() {
                guard let rawRules=group["All Rules"] as? [Any],rawRules.count<=500 else {throw SystemControlError.message("输入规则数组缺失或超过预算。")}
                for (ri,raw) in rawRules.enumerated() {
                    guard rows.count<1000,let row=raw as? [String:Any] else {throw SystemControlError.message("输入规则条目格式无效或过多。")}
                    let id=try rowID(module:module,groupIndex:gi,rowIndex:ri,row:row,scope:group)
                    let enabled=sourceBool(row["Enable"])
                    let unknown=row.keys.filter{!["Action","Enable","Gesture","Modifier","Note","EnableUnderCursor"].contains($0)}.sorted()
                    var record=InputMigrationRow(id:id,module:module,groupIndex:gi,rowIndex:ri,sourceEnabled:enabled,
                        disposition:.unavailable,requirements:[],reason:"",mappedRuleID:nil,unknownKeys:unknown)
                    do {
                        var rule=try parse(row,module:module)
                        if rule.effect.kind == .action,rule.effect.actionID.hasPrefix("window.") {rule.effect.windowTargetMode = .frontmost}
                        rule.appBundleID=try scope(group);rule.id=id;rule.enabled=false
                        rule.name=(row["Note"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? "BAB 导入 \(rows.count+1)"
                        var disposition:InputMigrationDisposition = .exact,requirements:[String]=[],reasons:[String]=[]
                        if enabled==nil {disposition = .requiresReview;reasons.append("源启用状态缺失或未知")}
                        if !unknown.isEmpty || !group.keys.filter({!["AppName","All Rules","AppBundleID","BundleIdentifier"].contains($0)}).isEmpty {
                            disposition = .requiresReview;reasons.append("未知规则或分组字段已保留，需确认其行为")
                        }
                        if row["EnableUnderCursor"] != nil {
                            guard let underCursor=sourceBool(row["EnableUnderCursor"]) else {throw SystemControlError.message("鼠标指向目标开关未知，不能改为前台目标。")}
                            if underCursor {
                                requirements.append("pointerWindowTarget");reasons.append("原动作使用鼠标指向目标，须连接并确认相同目标语义")
                                if rule.effect.kind == .action,rule.effect.actionID.hasPrefix("window.") {rule.effect.windowTargetMode = .underPointer}
                                else {disposition = .requiresReview;reasons.append("非窗口动作的原指向应用语义尚未有精确后端")}
                            }
                        }
                        if module=="ruleOfTrackPad" {requirements.append("rawTouchHardware");reasons.append("需开启实验触控并验收真实触点投递")}
                        if module=="ruleOfNormalMouse" {requirements.append("externalMouse");disposition = .requiresReview;reasons.append("原普通鼠标规则需连接相应鼠标核验；不回退到触控板")}
                        if rule.effect.kind == .appleScript {requirements.append("scriptReview");disposition = .requiresReview;reasons.append("脚本完整保留，未执行")}
                        if let a=row["Action"] as? [String:Any],a["Action"] as? String == "Zoom" {disposition = .requiresReview;reasons.append("原Zoom与铺满工作区的尺寸切换语义待确认")}
                        if let a=row["Action"] as? [String:Any],!a.keys.filter({!["ActionType","Action","AppleScript","OpenArr"].contains($0)}).isEmpty {disposition = .requiresReview;reasons.append("未知动作字段已保留")}
                        if let error=EnhancedInputValidation.error(rule) {throw SystemControlError.message(error)}
                        record.disposition=disposition;record.requirements=requirements;record.reason=reasons.isEmpty ? "触发、范围与动作已精确转换；保持暂停待接管":reasons.joined(separator:"；")
                        record.mappedRuleID=rule.id
                        rule.migrationOrigin=InputRuleMigrationOrigin(sourceDigest:digest,rowID:id,sourceEnabled:enabled,disposition:disposition,requirements:requirements,reason:record.reason)
                        configuration.rules.append(rule)
                    } catch {record.reason=error.localizedDescription}
                    rows.append(record)
                }
            }
        }
        let report=InputMigrationSource(sha256:digest,operationalPlist:bytes,originalBytesPreserved:preservesOriginal,rows:rows,
            retainedKeys:source.keys.sorted(),omittedKeyCount:original.count-source.count,
            note:"操作字段与未知嵌套值保真保留；账号、许可、遥测及OS全局偏好不迁入。源脚本只保存，未执行。")
        configuration.migrationSources=[report]
        if validatingConfiguration {try EnhancedInputValidation.validate(configuration)}
        let exact=rows.filter{$0.disposition == .exact}.count,blocked=rows.filter{$0.disposition == .unavailable}.count
        return EnhancedRuleImportResult(configuration:configuration,note:"BAB：审计 \(rows.count) 条源规则，精确转换 \(exact) 条，待复核 \(rows.count-exact-blocked) 条，未转换 \(blocked) 条。所有导入规则保持暂停；操作快照与逐项原因已保留。",report:report)
    }
    private static func modifiers(_ text:Any?)throws->UInt64 {
        guard let s=text as? String else {throw SystemControlError.message("修饰键字段缺失。")}
        if s.trimmingCharacters(in:.whitespaces)=="-" {return 0}
        let flags:[(String,NSEvent.ModifierFlags)]=[("Fn",.function),("⌘",.command),("⌃",.control),("⌥",.option),("⇧",.shift)]
        var remaining=s;var value:UInt64=0
        for (name,flag) in flags where remaining.contains(name) {value |= UInt64(flag.rawValue);remaining=remaining.replacingOccurrences(of:name,with:"")}
        guard remaining.trimmingCharacters(in:.whitespaces).isEmpty else {throw SystemControlError.message("修饰键格式未知，未丢弃额外条件。")};return value
    }
    private static func effect(_ row:[String:Any])throws->InputEffect {
        guard let a=row["Action"] as? [String:Any],let type=a["ActionType"] as? String else {throw SystemControlError.message("缺少动作类型。")}
        var result=InputEffect()
        if type=="Shortcut Keys",let s=a["Action"] as? [String:Any] {
            result.kind = .shortcut;result.keyCode=UInt16(try integer(s["keyCode"]))
            let flags=UInt64(try integer(s["modifierFlags"],maximum:Int(UInt32.max)))
            guard flags & UInt64(NSEvent.ModifierFlags([.capsLock,.help]).rawValue)==0 else {throw SystemControlError.message("快捷键含尚未支持的锁定/帮助条件。")}
            result.modifiers=flags & EnhancedInputValidation.modifiers;return result
        }
        if type=="AppleScript",let source=a["AppleScript"] as? String ?? a["Action"] as? String {result.kind = .appleScript;result.script=source;return result}
        guard type=="Preset",let name=a["Action"] as? String else {throw SystemControlError.message("动作结构未支持，原值保留。")}
        if name=="Open...",let targets=a["OpenArr"] as? [String] {result.kind = .openTargets;result.openTargets=targets;_=try InputOpenTargets.urls(targets);return result}
        let windows=["half_of_left":"leftHalf","half_of_right":"rightHalf","half_of_top":"topHalf","half_of_bottom":"bottomHalf",
            "quarte_of_top_left":"topLeft","quarte_of_top_right":"topRight","quarte_of_bottom_left":"bottomLeft","quarte_of_bottom_right":"bottomRight",
            "center":"center","maximize":"maximize","zoom":"maximize","minimize":"minimize","minimization":"minimize","close":"close","restore":"restore",
            "left_2/3":"leftTwoThirds","right_2/3":"rightTwoThirds","maximize_height":"maximizeHeight","maximize_width":"maximizeWidth",
            "window enter/exit full screen":"toggleFullScreen"]
        if let action=windows[name.lowercased()] {result.actionID="window."+action;return result}
        let systems:[String:EnhancedSystemPreset]=["VolumeUp":.volumeUp,"VolumeDown":.volumeDown,"Mute":.mute,"BrightnessUp":.brightnessUp,"BrightnessDown":.brightnessDown,"ScreenSaver":.screenSaver,"MissionControl":.missionControl,"ShowDesktop":.showDesktop]
        if let action=systems[name] {result.kind = .systemPreset;result.systemPreset=action.rawValue;return result}
        if name=="LockScreen" {result.actionID="system.lock";return result}
        throw SystemControlError.message("原预设未有精确动作映射，保留待复核。")
    }
    private static func parse(_ row:[String:Any],module:String)throws->EnhancedInputRule {
        var r=EnhancedInputRule();r.modifiers=0;r.effect=try effect(row)
        if module=="ruleOfKeyboard",let g=row["Gesture"] as? [String:Any] {
            guard Set(g.keys).isSubset(of:["keyCode","modifierFlags"]) else {throw SystemControlError.message("按键触发含未知条件，未扩大匹配。")}
            r.trigger = .keyDown;r.keyCode=UInt16(try integer(g["keyCode"]))
            let flags=UInt64(try integer(g["modifierFlags"],maximum:Int(UInt32.max)))
            guard flags & UInt64(NSEvent.ModifierFlags([.capsLock,.help]).rawValue)==0 else {throw SystemControlError.message("按键触发含未支持的锁定/帮助条件。")}
            r.modifiers=flags & EnhancedInputValidation.modifiers
            if let outer=row["Modifier"] {let value=try modifiers(outer);guard value==0 || value==r.modifiers else {throw SystemControlError.message("按键的内外修饰键条件不一致，未猜测合并。")}}
            return r
        }
        r.modifiers=try modifiers(row["Modifier"])
        guard let g=row["Gesture"] as? String else {throw SystemControlError.message("触发格式未识别。")}
        if module=="ruleOfHotCorners" {
            let prefix=["RightMouse Click":("click",1),"LeftMouse Click":("click",0),"Scroll Up":("scrollUp",0),"Scroll Down":("scrollDown",0)]
            let corners=["TopLeft":"topLeft","TopRight":"topRight","BottomLeft":"bottomLeft","BottomRight":"bottomRight"]
            for (p,v) in prefix {for (c,d) in corners where g==p+" at "+c+" Corner" {r.trigger = .screenEdge;r.direction=v.0;r.button=v.1;r.corner=d;return r}}
            throw SystemControlError.message("边角触发必须完整匹配，未知附加条件保留。")
        }
        if module=="ruleOfMagicMouse" {throw SystemControlError.message("Magic Mouse专属触发未验证；保留原规则，不转换为触控板或整组轻点。")}
        if module=="ruleOfTrackPad" {
            let expression="^([1-5])Finger_(Tap|DoubleTap|Click|SwipeLeft|SwipeRight|SwipeUp|SwipeDown)(?:_(Top_Left|Top_Right|Bottom_Left|Bottom_Right))?$"
            guard let pattern=try? NSRegularExpression(pattern:expression),let m=pattern.firstMatch(in:g,range:NSRange(g.startIndex...,in:g)) else {throw SystemControlError.message("复合、私有绘图或未知触控触发保留，未简化为整组手势。")}
            func part(_ i:Int)->String? {Range(m.range(at:i),in:g).map{String(g[$0])}}
            r.trigger = .touch;r.fingers=Int(part(1)!)!
            let gesture=part(2)!
            if gesture.hasPrefix("Swipe") {r.touchGesture="swipe";r.direction=String(gesture.dropFirst(5)).lowercased()}
            else {r.touchGesture=["Tap":"tap","DoubleTap":"doubleTap","Click":"click"][gesture]!}
            if let region=part(3) {r.touchRegion=["Top_Left":"topLeft","Top_Right":"topRight","Bottom_Left":"bottomLeft","Bottom_Right":"bottomRight"][region]!}
            return r
        }
        if module=="ruleOfNormalMouse" {
            for (word,direction) in [("Up","up"),("Down","down"),("Left","left"),("Right","right")] {
                for key in 1...3 where g=="Scroll "+word+"Of\(key)Key" {r.trigger = .scroll;r.direction=direction;r.heldButtons=[key-1];return r}
            }
            for key in 1...3 where g=="RightMouse ClickOf\(key)Key" {r.trigger = .buttonDown;r.button=1;r.heldButtons=key==2 ? []:[key-1];return r}
        }
        throw SystemControlError.message("鼠标或私有绘图触发未有精确模板，原始值保留。")
    }
}
