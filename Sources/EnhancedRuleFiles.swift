import AppKit

struct EnhancedRuleImportResult {
    var configuration:InputEnhancementConfiguration
    var note:String
}
struct EnhancedRuleDocument:Codable {var format="com.gaoseries.GaoCaoZuo.input";var version=1;var configuration:InputEnhancementConfiguration}
enum EnhancedRuleFiles {
    static func read(_ url:URL)throws->EnhancedRuleImportResult {
        let values=try url.resourceValues(forKeys:[.fileSizeKey,.isRegularFileKey])
        guard values.isRegularFile==true,let size=values.fileSize,size<=8*1024*1024 else{throw SystemControlError.message("规则文件不是普通文件或超过8MiB。")}
        return try decode(Data(contentsOf:url))
    }
    static func decode(_ data:Data)throws->EnhancedRuleImportResult {
        if let document=try? JSONDecoder().decode(EnhancedRuleDocument.self,from:data) {
            guard document.format=="com.gaoseries.GaoCaoZuo.input",document.version==1 else {throw SystemControlError.message("输入规则格式未知或来自更新版本。")}
            let configuration=document.configuration;try EnhancedInputValidation.validate(configuration)
            return EnhancedRuleImportResult(configuration:configuration,note:"已导入 \(configuration.rules.count) 条规则、\(configuration.scriptLibrary.count) 个脚本；新规则保持暂停。")
        }
        // No NSKeyedUnarchiver: third-party embedded object archives remain untrusted opaque data.
        guard let dictionary=try PropertyListSerialization.propertyList(from:data,options:[],format:nil) as? [String:Any],dictionary.keys.contains(where:{$0.hasPrefix("ruleOf")}) else{throw SystemControlError.message("不是有效的搞操作 JSON 或 BetterAndBetter plist 导出文件。")}
        return try importBAB(dictionary)
    }
    static func write(_ configuration:InputEnhancementConfiguration,to url:URL)throws {
        try EnhancedInputValidation.validate(configuration)
        let encoder=JSONEncoder();encoder.outputFormatting=[.prettyPrinted,.sortedKeys]
        try encoder.encode(EnhancedRuleDocument(configuration:configuration)).write(to:url,options:.atomic)
    }
    static func beginnerRules()->[EnhancedInputRule] {
        zip([UInt16(123),124,126,125],["window.leftHalf","window.rightHalf","window.topHalf","window.bottomHalf"]).map {code,action in
            var rule=EnhancedInputRule();rule.name="⌥"+InputBinding.keyLabel(code)+" 分屏";rule.keyCode=code;rule.effect.actionID=action;return rule
        }
    }
    static func drawingExample()->EnhancedInputRule {
        var rule=EnhancedInputRule();rule.name="Fn 单指画 L → 左半屏";rule.trigger = .touch;rule.modifiers=UInt64(NSEvent.ModifierFlags.function.rawValue);rule.fingers=1;rule.touchGesture="drawing";rule.effect.actionID="window.leftHalf"
        rule.drawing=[GesturePoint(x:20,y:20),GesturePoint(x:20,y:120),GesturePoint(x:120,y:120)];return rule
    }
    static func importBAB(_ dictionary:[String:Any])throws->EnhancedRuleImportResult {
        var configuration=InputEnhancementConfiguration(),issues:[String]=[],total=0
        if let library=dictionary["ruleOfAppleScript"] as? [[String:Any]] {
            for entry in library {
                guard let source=entry["AppleScript"] as? String,source.utf8.count<=65536 else{issues.append("脚本内容缺失或超过64KiB");continue}
                var script=InputScript();script.name=entry["Name"] as? String ?? "导入脚本";script.source=source;configuration.scriptLibrary.append(script)
            }
        }
        for module in ["ruleOfKeyboard","ruleOfNormalMouse","ruleOfTrackPad","ruleOfMagicMouse","ruleOfHotCorners"] {
            guard let groups=dictionary[module] as? [[String:Any]] else{continue}
            for group in groups {
                let scope=group["AppName"] as? String ?? "All Applications"
                for row in group["All Rules"] as? [[String:Any]] ?? [] {
                    total += 1
                    do {
                        var rule=try babRule(row,module:module)
                        rule.appBundleID=scope=="All Applications" ? "":scope
                        rule.name=(row["Note"] as? String).flatMap{$0.isEmpty ? nil:$0} ?? "BAB 导入 \(total)"
                        rule.enabled=false
                        if let error=EnhancedInputValidation.error(rule){throw SystemControlError.message(error)}
                        configuration.rules.append(rule)
                    } catch {issues.append("\(module) 第\(total)项："+error.localizedDescription)}
                }
            }
        }
        if dictionary["HaveFittedMouse"] != nil {issues.append("鼠标厂商设备报文适配不能导入；不会向设备发送未知 HID 控制报文。")}
        try EnhancedInputValidation.validate(configuration)
        let note="BAB：识别 \(total) 项，转换 \(configuration.rules.count) 条规则及 \(configuration.scriptLibrary.count) 个脚本。所有规则暂停，原文件保留。"+(issues.isEmpty ? "":"\n未转换项目（仍需原应用）：\n"+issues.joined(separator:"\n"))
        return .init(configuration:configuration,note:note)
    }
    private static let windowNames:[String:String]=[
        "half_of_left":"leftHalf","half_of_right":"rightHalf","half_of_top":"topHalf","half_of_bottom":"bottomHalf",
        "quarte_of_top_left":"topLeft","quarte_of_top_right":"topRight","quarte_of_bottom_left":"bottomLeft","quarte_of_bottom_right":"bottomRight",
        "center":"center","maximize":"maximize","zoom":"maximize","minimize":"minimize","close":"close","restore":"restore",
        "left_2/3":"leftTwoThirds","right_2/3":"rightTwoThirds","maximize_height":"maximizeHeight","maximize_width":"maximizeWidth"
    ]
    private static func babEffect(_ row:[String:Any])throws->InputEffect {
        guard let action=row["Action"] as? [String:Any],let type=action["ActionType"] as? String else{throw SystemControlError.message("缺少动作类型")}
        var effect=InputEffect()
        if type == "Shortcut Keys",let shortcut=action["Action"] as? [String:Any],let key=shortcut["keyCode"] as? NSNumber,let flags=shortcut["modifierFlags"] as? NSNumber {
            effect.kind = .shortcut;effect.keyCode=key.uint16Value;effect.modifiers=flags.uint64Value&EnhancedInputValidation.modifiers;return effect
        }
        if type == "AppleScript",let script=action["AppleScript"] as? String ?? action["Action"] as? String {effect.kind = .appleScript;effect.script=script;return effect}
        if type == "Preset",let name=action["Action"] as? String {
            if let window=windowNames[name.lowercased()] {effect.actionID="window."+window;return effect}
            let presets:[String:EnhancedSystemPreset]=["VolumeUp":.volumeUp,"VolumeDown":.volumeDown,"Mute":.mute,"BrightnessUp":.brightnessUp,"BrightnessDown":.brightnessDown,"ScreenSaver":.screenSaver,"MissionControl":.missionControl,"ShowDesktop":.showDesktop]
            if let preset=presets[name] {effect.kind = .systemPreset;effect.systemPreset=preset.rawValue;return effect}
            if name=="LockScreen" {effect.actionID="system.lock";return effect}
        }
        throw SystemControlError.message("动作 \(type) 需要语义核对，未猜测转换")
    }
    private static func babRule(_ row:[String:Any],module:String)throws->EnhancedInputRule {
        var rule=EnhancedInputRule();rule.modifiers=0;rule.effect=try babEffect(row)
        let modifier=row["Modifier"] as? String ?? ""
        for (name,flag) in [("Fn",NSEvent.ModifierFlags.function),("⌘",.command),("⌃",.control),("⌥",.option),("⇧",.shift)] {if modifier.contains(name){rule.modifiers |= UInt64(flag.rawValue)}}
        // BAB " -" is no modifier; EnhancedInputRule's safe creation default is Option.
        if modifier.trimmingCharacters(in:.whitespaces)=="-" || modifier.isEmpty {rule.modifiers=0}
        if module=="ruleOfKeyboard",let gesture=row["Gesture"] as? [String:Any],let key=gesture["keyCode"] as? NSNumber,let flags=gesture["modifierFlags"] as? NSNumber {
            rule.trigger = .keyDown;rule.keyCode=key.uint16Value;rule.modifiers=flags.uint64Value&EnhancedInputValidation.modifiers;return rule
        }
        guard let gesture=row["Gesture"] as? String else{throw SystemControlError.message("手势字段缺失")}
        if module=="ruleOfHotCorners" {
            rule.trigger = .screenEdge
            let regions=["TopLeft":"topLeft","TopRight":"topRight","BottomLeft":"bottomLeft","BottomRight":"bottomRight"]
            guard let region=regions.first(where:{gesture.contains($0.key)}) else{throw SystemControlError.message("屏幕边角格式未识别")};rule.corner=region.value
            if gesture.hasPrefix("RightMouse Click") {rule.direction="click";rule.button=1}
            else if gesture.hasPrefix("LeftMouse Click") {rule.direction="click";rule.button=0}
            else if gesture.hasPrefix("Scroll Up") {rule.direction="scrollUp"}
            else if gesture.hasPrefix("Scroll Down") {rule.direction="scrollDown"}
            else {throw SystemControlError.message("边角触发格式未识别")};return rule
        }
        if module=="ruleOfTrackPad" || module=="ruleOfMagicMouse" {
            guard let first=gesture.first,let fingers=Int(String(first)),(1...5).contains(fingers),gesture.hasPrefix("\(fingers)Finger_") else {throw SystemControlError.message("需在搞操作重新录制绘图模板；未反序列化第三方对象轨迹")}
            rule.trigger = .touch;rule.fingers=fingers
            if gesture.contains("DoubleTap") {rule.touchGesture="doubleTap"}
            else if gesture.contains("_Tap_") || gesture.hasSuffix("_Tap") {rule.touchGesture="tap"}
            else if gesture.contains("Click") {rule.touchGesture="click"}
            else if gesture.contains("Swipe") {rule.touchGesture="swipe";let directions=["Left":"left","Right":"right","Up":"up","Down":"down"];guard let direction=directions.first(where:{gesture.hasSuffix("Swipe"+$0.key)}) else {throw SystemControlError.message("滑动方向未识别")};rule.direction=direction.value}
            else {throw SystemControlError.message("复合/TipTap/压力手势需重新配置，未简化为轻点")}
            let regions=["Top_Left":"topLeft","Top_Right":"topRight","Bottom_Left":"bottomLeft","Bottom_Right":"bottomRight"]
            if let region=regions.first(where:{gesture.hasSuffix($0.key)}) {rule.touchRegion=region.value}
            if module=="ruleOfMagicMouse" {throw SystemControlError.message("Magic Mouse 手势必须连接原设备逐项配置验收")}
            return rule
        }
        throw SystemControlError.message("鼠标复合/绘图手势需重新录制并核验，未丢弃成普通点击")
    }
}
