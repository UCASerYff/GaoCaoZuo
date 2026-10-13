import AppKit
import SwiftUI

struct InputEnhancementConfiguration: Codable, Equatable {
    var enabled = false
    var rules: [EnhancedInputRule] = []
    var scrollProfiles: [ScrollDeviceProfile] = []
    var experimentalRawTouch = false
    var syncFolder: String = ""
    var scriptLibrary: [InputScript] = []
    var hidProfiles: [HIDDeviceProfile] = []
    var migrationSources:[InputMigrationSource] = []
    init() {}
    enum CodingKeys: String, CodingKey { case enabled,rules,scrollProfiles,experimentalRawTouch,syncFolder,scriptLibrary,hidProfiles,migrationSources }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy:CodingKeys.self)
        enabled = try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? false
        rules = try c.decodeIfPresent([EnhancedInputRule].self,forKey:.rules) ?? []
        scrollProfiles = try c.decodeIfPresent([ScrollDeviceProfile].self,forKey:.scrollProfiles) ?? []
        experimentalRawTouch = try c.decodeIfPresent(Bool.self,forKey:.experimentalRawTouch) ?? false
        syncFolder = try c.decodeIfPresent(String.self,forKey:.syncFolder) ?? ""
        scriptLibrary = try c.decodeIfPresent([InputScript].self,forKey:.scriptLibrary) ?? []
        hidProfiles = try c.decodeIfPresent([HIDDeviceProfile].self,forKey:.hidProfiles) ?? []
        migrationSources = try c.decodeIfPresent([InputMigrationSource].self,forKey:.migrationSources) ?? []
    }
}
enum EnhancedInputTrigger: String, Codable, CaseIterable, Identifiable {
    case keyDown,keyUp,keyHold,keyReplacement,buttonDown,buttonUp,buttonHold,scroll,drawing,hotCorner,screenEdge,touch,pressure
    var id:String {rawValue}
    var title:String { switch self {
    case .keyDown:return L10n.text("按键按下");case .keyUp:return L10n.text("按键松开");case .keyHold:return L10n.text("按键长按");case .keyReplacement:return L10n.text("替换按键")
    case .buttonDown:return L10n.text("按钮按下/组合");case .buttonUp:return L10n.text("按钮松开");case .buttonHold:return L10n.text("按钮长按");case .scroll:return L10n.text("滚轮方向/组合")
    case .drawing:return L10n.text("鼠标自由绘图");case .hotCorner:return L10n.text("屏幕热角停留");case .screenEdge:return L10n.text("边角点击/滚轮");case .touch:return L10n.text("多点触控（实验）");case .pressure:return L10n.text("压力点按") }
    }
}
enum InputEffectKind:String,Codable,CaseIterable,Identifiable {
    case action,shortcut,mouseClick,scroll,systemPreset,appleScript,menuItem,openTargets
    var id:String {rawValue}
    var title:String { switch self {case .action:return L10n.text("动作库");case .shortcut:return L10n.text("输出快捷键");case .mouseClick:return L10n.text("模拟鼠标点击");case .scroll:return L10n.text("模拟滚动");case .systemPreset:return L10n.text("系统控制");case .appleScript:return "AppleScript";case .menuItem:return L10n.text("应用菜单项");case .openTargets:return L10n.text("打开指定应用、网址或路径")} }
}
enum InputWindowTargetMode:String,Codable,CaseIterable {
    case inheritSettings,frontmost,underPointer
}
struct InputEffect:Codable,Equatable {
    var kind:InputEffectKind = .action
    var actionID = "panel.show"
    var keyCode:UInt16 = 31
    var modifiers:UInt64 = UInt64(NSEvent.ModifierFlags([.command,.option]).rawValue)
    var script = ""
    var mouseButton = 2
    var scrollX: Double = 0
    var scrollY: Double = -100
    var systemPreset = "missionControl"
    var menuBundleID = ""
    var menuPath:[String] = []
    var mouseModifiers:UInt64 = 0
    var openTargets:[String] = []
    var windowTargetMode:InputWindowTargetMode = .inheritSettings
    init() {}
    enum CodingKeys:String,CodingKey {case kind,actionID,keyCode,modifiers,script,mouseButton,scrollX,scrollY,systemPreset,menuBundleID,menuPath,mouseModifiers,openTargets,windowTargetMode}
    init(from decoder:Decoder)throws {
        self.init();let c=try decoder.container(keyedBy:CodingKeys.self)
        kind=try c.decodeIfPresent(InputEffectKind.self,forKey:.kind) ?? .action
        actionID=try c.decodeIfPresent(String.self,forKey:.actionID) ?? "panel.show"
        keyCode=try c.decodeIfPresent(UInt16.self,forKey:.keyCode) ?? 31
        modifiers=try c.decodeIfPresent(UInt64.self,forKey:.modifiers) ?? UInt64(NSEvent.ModifierFlags([.command,.option]).rawValue)
        script=try c.decodeIfPresent(String.self,forKey:.script) ?? ""
        mouseButton=try c.decodeIfPresent(Int.self,forKey:.mouseButton) ?? 2
        scrollX=try c.decodeIfPresent(Double.self,forKey:.scrollX) ?? 0
        scrollY=try c.decodeIfPresent(Double.self,forKey:.scrollY) ?? -100
        systemPreset=try c.decodeIfPresent(String.self,forKey:.systemPreset) ?? "missionControl"
        menuBundleID=try c.decodeIfPresent(String.self,forKey:.menuBundleID) ?? ""
        menuPath=try c.decodeIfPresent([String].self,forKey:.menuPath) ?? []
        mouseModifiers=try c.decodeIfPresent(UInt64.self,forKey:.mouseModifiers) ?? 0
        openTargets=try c.decodeIfPresent([String].self,forKey:.openTargets) ?? []
        windowTargetMode=try c.decodeIfPresent(InputWindowTargetMode.self,forKey:.windowTargetMode) ?? .inheritSettings
    }
}
struct InputScript:Codable,Equatable,Identifiable {
    var id=UUID();var name="新脚本";var source=""
}
struct GesturePoint:Codable,Equatable {
    var x:Double;var y:Double
    init(_ point:CGPoint) {x = point.x;y = point.y}
    init(x:Double,y:Double) {self.x=x;self.y=y}
    var point:CGPoint {CGPoint(x:x,y:y)}
}
struct EnhancedInputRule:Codable,Equatable,Identifiable {
    var id = UUID()
    var name = "新规则"
    var enabled = false
    var trigger:EnhancedInputTrigger = .keyDown
    var keyCode:UInt16 = 31
    var modifiers:UInt64 = UInt64(NSEvent.ModifierFlags.option.rawValue)
    var button:Int = 1
    var heldButtons:[Int] = []
    var holdSeconds:Double = 0.7
    var allowKeyRepeat=false
    var minimumIntervalSeconds:Double=0
    var direction = "up"
    var corner = "topLeft"
    /// On vertical edges, 0 is the top; on horizontal edges, 0 is the left.
    var edgeStart:Double = 0
    var edgeEnd:Double = 1
    var edgeWidth:Double = 8
    var appBundleID = ""
    var consume = false
    var effect = InputEffect()
    var drawing:[GesturePoint] = []
    var recognitionThreshold:Double = 0.23
    var touchDevice = "any"
    var fingers = 3
    var touchGesture = "tap"
    var touchRegion = "any"
    var pressureStage = 2
    var pressureThreshold: Double = 0.8
    var thumbAtBottom = false
    var excludedApps: [String] = []
    var migrationOrigin:InputRuleMigrationOrigin? = nil
    init() {}
    enum CodingKeys:String,CodingKey {case id,name,enabled,trigger,keyCode,modifiers,button,heldButtons,holdSeconds,allowKeyRepeat,minimumIntervalSeconds,direction,corner,edgeStart,edgeEnd,edgeWidth,appBundleID,consume,effect,drawing,recognitionThreshold,touchDevice,fingers,touchGesture,touchRegion,pressureStage,pressureThreshold,thumbAtBottom,excludedApps,migrationOrigin}
    init(from decoder:Decoder)throws {
        self.init();let c = try decoder.container(keyedBy:CodingKeys.self)
        id = try c.decodeIfPresent(UUID.self,forKey:.id) ?? UUID();name = try c.decodeIfPresent(String.self,forKey:.name) ?? "新规则"
        enabled = try c.decodeIfPresent(Bool.self,forKey:.enabled) ?? false;trigger = try c.decodeIfPresent(EnhancedInputTrigger.self,forKey:.trigger) ?? .keyDown
        keyCode = try c.decodeIfPresent(UInt16.self,forKey:.keyCode) ?? 31;modifiers = try c.decodeIfPresent(UInt64.self,forKey:.modifiers) ?? UInt64(NSEvent.ModifierFlags.option.rawValue)
        button = try c.decodeIfPresent(Int.self,forKey:.button) ?? 1;heldButtons = try c.decodeIfPresent([Int].self,forKey:.heldButtons) ?? []
        holdSeconds = try c.decodeIfPresent(Double.self,forKey:.holdSeconds) ?? 0.7
        allowKeyRepeat = try c.decodeIfPresent(Bool.self,forKey:.allowKeyRepeat) ?? false
        minimumIntervalSeconds = try c.decodeIfPresent(Double.self,forKey:.minimumIntervalSeconds) ?? 0
        direction = try c.decodeIfPresent(String.self,forKey:.direction) ?? "up"
        corner = try c.decodeIfPresent(String.self,forKey:.corner) ?? "topLeft"
        edgeStart = try c.decodeIfPresent(Double.self,forKey:.edgeStart) ?? 0
        edgeEnd = try c.decodeIfPresent(Double.self,forKey:.edgeEnd) ?? 1
        edgeWidth = try c.decodeIfPresent(Double.self,forKey:.edgeWidth) ?? 8
        appBundleID = try c.decodeIfPresent(String.self,forKey:.appBundleID) ?? ""
        consume = try c.decodeIfPresent(Bool.self,forKey:.consume) ?? false;effect = try c.decodeIfPresent(InputEffect.self,forKey:.effect) ?? InputEffect()
        drawing = try c.decodeIfPresent([GesturePoint].self,forKey:.drawing) ?? [];recognitionThreshold = try c.decodeIfPresent(Double.self,forKey:.recognitionThreshold) ?? 0.23
        touchDevice = try c.decodeIfPresent(String.self,forKey:.touchDevice) ?? "any";fingers = try c.decodeIfPresent(Int.self,forKey:.fingers) ?? 3
        touchGesture = try c.decodeIfPresent(String.self,forKey:.touchGesture) ?? "tap";touchRegion = try c.decodeIfPresent(String.self,forKey:.touchRegion) ?? "any"
        pressureStage = try c.decodeIfPresent(Int.self,forKey:.pressureStage) ?? 2
        pressureThreshold = try c.decodeIfPresent(Double.self,forKey:.pressureThreshold) ?? 0.8
        thumbAtBottom = try c.decodeIfPresent(Bool.self,forKey:.thumbAtBottom) ?? false
        excludedApps = try c.decodeIfPresent([String].self,forKey:.excludedApps) ?? []
        migrationOrigin = try c.decodeIfPresent(InputRuleMigrationOrigin.self,forKey:.migrationOrigin)
    }
}
struct ScrollDeviceProfile: Codable,Equatable,Identifiable {
    var id = UUID();var name = "滚轮设置";var enabled = false
    /// allWheel means only discrete wheel events; allPrecise means only continuous trackpad events.
    /// HID IDs use vendor/product/location; a profile is never guessed from a device name.
    var deviceID = "allWheel"
    var reverseX = false;var reverseY = false
    var speed:Double = 1;var acceleration:Double = 0
    var smooth = false;var smoothingDuration:Double = 0.16
    var bypassModifiers:UInt64 = UInt64(NSEvent.ModifierFlags.shift.rawValue)
    var excludedApps:[String] = []
}

enum EnhancedInputValidation {
    static let modifiers = UInt64(NSEvent.ModifierFlags([.command,.control,.option,.shift,.function]).rawValue)
    static func migrationBlockReason(_ rule:EnhancedInputRule)->String? {
        guard let origin=rule.migrationOrigin else{return nil}
        guard origin.disposition == .exact else {return L10n.text("输入迁移语义尚未复核，此规则不能启动。")}
        guard Set(origin.requirements).isSubset(of:Set(origin.verifiedRequirements)) else {return L10n.text("输入迁移所需设备或权限行为尚未核验，此规则不能启动。")}
        return nil
    }
    static func error(_ rule:EnhancedInputRule)->String? {
        if rule.enabled,let reason=migrationBlockReason(rule) {return reason}
        guard !rule.name.isEmpty,rule.name.count<=200,rule.appBundleID.count<=256 else {return L10n.text("规则名称或应用范围无效")}
        guard rule.keyCode<=127,rule.effect.keyCode<=127,(0...31).contains(rule.button),rule.heldButtons.allSatisfy({(0...31).contains($0)}),Set(rule.heldButtons).count==rule.heldButtons.count else {return L10n.text("键码或按钮编号无效")}
        guard rule.holdSeconds.isFinite,(0.2...10).contains(rule.holdSeconds),rule.recognitionThreshold.isFinite,(0.05...0.5).contains(rule.recognitionThreshold) else {return L10n.text("时间或识别阈值无效")}
        if !rule.minimumIntervalSeconds.isFinite || !(0...60).contains(rule.minimumIntervalSeconds) {return L10n.text("规则节流间隔必须为0–60秒")}
        if rule.consume && [.touch,.pressure,.hotCorner].contains(rule.trigger) {return L10n.text("此触发只可监听，不能阻止系统原始手势")}
        if rule.trigger == .keyReplacement && rule.effect.kind != .shortcut {return L10n.text("按键替换必须选择输出快捷键")}
        if [.keyDown,.keyUp,.keyHold].contains(rule.trigger) && rule.modifiers & modifiers == 0 && rule.keyCode != 63 {return L10n.text("动作快捷键至少使用一个修饰键；普通键替换请显式使用替换按键")}
        if rule.trigger == .drawing && rule.modifiers & modifiers == 0 {return L10n.text("绘图请指定修饰键，避免误触")}
        if (rule.trigger == .drawing || rule.touchGesture == "drawing" && rule.trigger == .touch) && (rule.drawing.count<3 || rule.drawing.count>2048 || !rule.drawing.allSatisfy({$0.x.isFinite && $0.y.isFinite && abs($0.x)<100000 && abs($0.y)<100000})) {return L10n.text("请先绘制至少三个点的轨迹")}
        if rule.trigger == .touch && (!(1...5).contains(rule.fingers) || !["tap","doubleTap","click","swipe","pinchIn","pinchOut","rotateLeft","rotateRight","drawing","tipTap","middleDrag"].contains(rule.touchGesture) || !["any","left","right","top","bottom","topLeft","topRight","bottomLeft","bottomRight"].contains(rule.touchRegion)) {return L10n.text("触控规则无效；压力规则使用系统压力事件")}
        if rule.trigger == .pressure && (!(1...2).contains(rule.pressureStage) || !rule.pressureThreshold.isFinite || !(0.05...1).contains(rule.pressureThreshold)) {return L10n.text("压力阈值或级别无效")}
        if [.screenEdge,.hotCorner].contains(rule.trigger) && !["left","right","top","bottom","topLeft","topRight","bottomLeft","bottomRight"].contains(rule.corner) {return L10n.text("屏幕边角无效")}
        if rule.trigger == .screenEdge && (!rule.edgeStart.isFinite || !rule.edgeEnd.isFinite || !rule.edgeWidth.isFinite || rule.edgeStart < 0 || rule.edgeEnd > 1 || rule.edgeEnd-rule.edgeStart < 0.01 || !(2...80).contains(rule.edgeWidth)) {return L10n.text("边段必须位于0–1内，长度至少0.01，边缘宽度2–80pt")}
        if rule.trigger == .screenEdge && !["click","scrollUp","scrollDown","scrollLeft","scrollRight"].contains(rule.direction) {return L10n.text("边角触发方式无效")}
        if rule.effect.kind == .mouseClick && !(0...31).contains(rule.effect.mouseButton) {return L10n.text("输出鼠标按钮无效")}
        if rule.effect.mouseModifiers & ~modifiers != 0 {return L10n.text("输出鼠标修饰键无效")}
        if rule.effect.kind == .scroll && ![rule.effect.scrollX,rule.effect.scrollY].allSatisfy({$0.isFinite && abs($0)<=10000}) {return L10n.text("输出滚动值无效")}
        if rule.effect.kind == .systemPreset && !EnhancedSystemPreset.allCases.map(\.rawValue).contains(rule.effect.systemPreset) {return L10n.text("系统动作无效")}
        if rule.effect.kind == .appleScript && (rule.effect.script.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty || rule.effect.script.utf8.count>65536) {return L10n.text("脚本为空或超过 64 KiB")}
        if rule.effect.kind == .menuItem && (rule.effect.menuBundleID.isEmpty || rule.effect.menuBundleID.utf8.count>256 || !(2...10).contains(rule.effect.menuPath.count) || !rule.effect.menuPath.allSatisfy({!$0.isEmpty && $0.utf8.count<=1024})) {return L10n.text("请选择目标应用和完整菜单路径")}
        if rule.effect.kind == .action && rule.effect.actionID.isEmpty {return L10n.text("请选择动作")}
        if rule.effect.kind == .openTargets {do {_=try InputOpenTargets.urls(rule.effect.openTargets)} catch {return error.localizedDescription}}
        return nil
    }
    static func signature(_ r:EnhancedInputRule)->String {
        [r.trigger.rawValue,String(r.keyCode),String(r.modifiers & modifiers),String(r.button),r.heldButtons.sorted().map(String.init).joined(separator:","),r.direction,r.corner,String(r.edgeStart),String(r.edgeEnd),String(r.edgeWidth),r.appBundleID,r.touchDevice,String(r.fingers),r.touchGesture,r.touchRegion,String(r.thumbAtBottom),String(r.pressureStage),String(r.pressureThreshold),r.trigger == .drawing ? r.id.uuidString : ""].joined(separator:"|")
    }
    static func conflictingIDs(_ rules:[EnhancedInputRule])->Set<UUID> {
        let candidates=rules.filter{$0.enabled && $0.trigger != .drawing && !($0.trigger == .touch && $0.touchGesture == "drawing")}
        var ids=Set(Dictionary(grouping:candidates,by:signature).values.filter{$0.count>1}.flatMap{$0.map(\.id)})
        let edges=candidates.filter{$0.trigger == .screenEdge}
        for (i,a) in edges.enumerated() {for b in edges.dropFirst(i+1) {
            if a.appBundleID==b.appBundleID,a.modifiers & modifiers == b.modifiers & modifiers,
               a.corner==b.corner,a.direction==b.direction,(a.direction != "click" || a.button==b.button),
               max(a.edgeStart,b.edgeStart)<min(a.edgeEnd,b.edgeEnd) {ids.insert(a.id);ids.insert(b.id)}
        }}
        return ids
    }
    static func validate(_ c:InputEnhancementConfiguration)throws {
        guard c.migrationSources.count<=16,c.migrationSources.reduce(0,{$0+$1.operationalPlist.count})<=32*1024*1024,
              Set(c.migrationSources.map(\.sha256)).count==c.migrationSources.count else {throw SystemControlError.message("输入迁移档案重复或超过保留预算。")}
        for source in c.migrationSources {try source.verify()}
        for rule in c.rules {
            if let origin=rule.migrationOrigin,!c.migrationSources.contains(where:{$0.sha256==origin.sourceDigest && $0.rows.contains(where:{$0.id==origin.rowID})}) {
                throw SystemControlError.message("输入规则来源档案缺失，停止启动。")
            }
        }
        if c.rules.contains(where:{$0.enabled && $0.migrationOrigin != nil}) {
            let expected=try InputMigrationExecutionPolicy.expectedRules(c)
            for rule in c.rules where rule.enabled {
                if let origin=rule.migrationOrigin,let reason=try InputMigrationExecutionPolicy.blockReason(rule,expected:expected[origin.sourceDigest]?[origin.rowID]) {
                    throw SystemControlError.message(reason)
                }
            }
        }
        guard c.rules.count<=500,c.scrollProfiles.count<=100,c.scriptLibrary.count<=200,c.hidProfiles.count<=100 else {throw SystemControlError.message("输入配置超过 500 条规则或 100 个设备配置。")}
        guard Set(c.rules.map(\.id)).count==c.rules.count,Set(c.scrollProfiles.map(\.id)).count==c.scrollProfiles.count else {throw SystemControlError.message("输入配置存在重复 ID。")}
        for rule in c.rules {if let error = error(rule) {throw SystemControlError.message(rule.name + "：" + error)}}
        let hidSignatures=c.hidProfiles.filter(\.enabled).flatMap {p in p.buttons.filter(\.enabled).map {p.deviceID+"|\($0.usage)|\($0.whenReleased)|"+$0.appBundleID}}
        guard Set(hidSignatures).count==hidSignatures.count else {throw SystemControlError.message("HID按钮存在相同设备/应用/触发冲突，配置未启动。") }
        for p in c.hidProfiles {
            guard !p.deviceID.isEmpty,p.buttons.count<=100,p.trackingSpeed.isFinite,(0.1...8).contains(p.trackingSpeed),p.trackingAcceleration.isFinite,(0...3).contains(p.trackingAcceleration) else {throw SystemControlError.message("HID设备配置无效。") }
            for b in p.buttons {guard (1...32).contains(b.usage) else {throw SystemControlError.message("HID按钮Usage超出1–32。")};var rule=EnhancedInputRule();rule.effect=b.effect;if let error=error(rule) {throw SystemControlError.message(error)}}
        }
        for script in c.scriptLibrary {guard !script.name.isEmpty,script.source.utf8.count<=65536 else {throw SystemControlError.message("脚本库项目无效或超过64KiB。")}}
        for p in c.scrollProfiles {
            guard p.speed.isFinite,(0.1...8).contains(p.speed),p.acceleration.isFinite,(0...3).contains(p.acceleration),p.smoothingDuration.isFinite,(0.04...0.8).contains(p.smoothingDuration) else {throw SystemControlError.message("滚轮速度、加速度或平滑时长无效。")}
        }
    }
}

/// Direction-sensitive, translation/scale invariant single-stroke matching, with arc-length resampling.
/// No rotation normalization: an L and a rotated L remain distinct user gestures.
enum DrawingRecognition {
    static func normalized(_ points:[CGPoint],count:Int=64)->[CGPoint] {
        guard points.count>=2,count>=2,points.allSatisfy({$0.x.isFinite && $0.y.isFinite}) else {return []}
        var lengths:[CGFloat] = [0]
        for i in 1..<points.count {lengths.append(lengths.last! + hypot(points[i].x-points[i-1].x,points[i].y-points[i-1].y))}
        guard let total=lengths.last,total>0.001 else {return []}
        var sample:[CGPoint]=[];var j=1
        for i in 0..<count {
            let distance=total*CGFloat(i)/CGFloat(count-1)
            while j<lengths.count-1 && lengths[j]<distance {j+=1}
            let t=(distance-lengths[j-1])/max(0.000001,lengths[j]-lengths[j-1])
            sample.append(CGPoint(x:points[j-1].x+(points[j].x-points[j-1].x)*t,y:points[j-1].y+(points[j].y-points[j-1].y)*t))
        }
        let minX=sample.map(\.x).min()!,maxX=sample.map(\.x).max()!,minY=sample.map(\.y).min()!,maxY=sample.map(\.y).max()!
        let scale=max(maxX-minX,maxY-minY)
        guard scale>0.001 else {return []}
        let center=CGPoint(x:sample.map(\.x).reduce(0,+)/CGFloat(count),y:sample.map(\.y).reduce(0,+)/CGFloat(count))
        return sample.map {CGPoint(x:($0.x-center.x)/scale,y:($0.y-center.y)/scale)}
    }
    static func distance(_ a:[CGPoint],_ b:[CGPoint])->Double {
        let aa=normalized(a),bb=normalized(b)
        guard !aa.isEmpty,aa.count==bb.count else {return .infinity}
        return Double(zip(aa,bb).map {hypot($0.x-$1.x,$0.y-$1.y)}.reduce(0,+)/CGFloat(aa.count))
    }
    static func length(_ points:[CGPoint])->CGFloat {zip(points,points.dropFirst()).reduce(0){$0+hypot($1.0.x-$1.1.x,$1.0.y-$1.1.y)}}
}

enum ScrollTransformation {
    static func delta(_ value:Double,profile:ScrollDeviceProfile,horizontal:Bool)->Double {
        let accelerated = value * profile.speed * (1 + profile.acceleration * min(abs(value)/20,3))
        return max(-10000,min(10000,accelerated)) * ((horizontal ? profile.reverseX : profile.reverseY) ? -1 : 1)
    }
}
