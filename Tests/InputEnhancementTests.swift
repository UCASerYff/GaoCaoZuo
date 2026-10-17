import AppKit

@MainActor func runInputEnhancementTests()throws {
    try runInputLifecycleTests()
    try runInputDeviceMenuTests()
    try runWindowProcessIdentityTests()
    var assertions=0
    func check(_ condition:@autoclosure ()->Bool,_ text:String)throws {assertions+=1;if !condition(){throw SystemControlError.message("输入/窗口增强测试失败："+text)}}
    let original=InputEnhancementConfiguration()
    try check(!original.enabled && !original.experimentalRawTouch,"新增全局监听和私有接口默认关闭")
    func rejects(_ body:()throws->Void,_ text:String)throws {var rejected=false;do {try body()} catch {rejected=true};try check(rejected,text)}
    let old=try JSONDecoder().decode(InputEnhancementConfiguration.self,from:Data("{}".utf8))
    try check(old==original,"旧设置缺少新字段时保留安全默认")
    let oldEffect=try JSONDecoder().decode(InputEffect.self,from:Data("{\"kind\":\"shortcut\",\"keyCode\":8,\"modifiers\":1048576}".utf8))
    try check(oldEffect.keyCode==8 && oldEffect.mouseButton==2,"旧输出规则兼容新增字段")
    var configuration=original;configuration.rules=EnhancedRuleFiles.beginnerRules()+[EnhancedRuleFiles.drawingExample()]
    var script=InputScript();script.name="测试";script.source="return 42";configuration.scriptLibrary=[script]
    try EnhancedInputValidation.validate(configuration)
    let decoded=try JSONDecoder().decode(InputEnhancementConfiguration.self,from:JSONEncoder().encode(configuration))
    try check(decoded==configuration,"输入规则包含绘图和脚本可完整往返")
    let directory=FileManager.default.temporaryDirectory.appendingPathComponent("Gao-input-test-"+UUID().uuidString)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true);defer{try? FileManager.default.removeItem(at:directory)}
    let url=directory.appendingPathComponent("rules.json");try EnhancedRuleFiles.write(configuration,to:url)
    let imported=try EnhancedRuleFiles.read(url)
    try check(imported.configuration==configuration,"磁盘输入规则文件往返")
    try rejects({_ = try EnhancedRuleFiles.decode(Data("{}".utf8))},"任意JSON不能被识别为空配置")
    let future=Data("{\"format\":\"com.gaoseries.GaoCaoZuo.input\",\"version\":99,\"configuration\":{}}".utf8)
    try rejects({_ = try EnhancedRuleFiles.decode(future)},"未来版本不得导入")
    var r=EnhancedInputRule();r.modifiers=0
    try check(EnhancedInputValidation.error(r) != nil,"普通打字键不能误注册为动作")
    r.keyCode=63;try check(EnhancedInputValidation.error(r)==nil,"Fn可独立触发")
    r.trigger = .touch;r.consume=true
    try check(EnhancedInputValidation.error(r) != nil,"原始触控监听不能声称阻止系统原手势")
    r.consume=false;r.pressureThreshold = .nan;r.trigger = .pressure
    try check(EnhancedInputValidation.error(r) != nil,"拒绝非有限压力阈值")
    r.pressureThreshold=0.8;r.pressureStage=2
    try check(EnhancedInputValidation.error(r)==nil,"真实系统阶段和压力阈值可配置")
    let l:[CGPoint]=[.init(x:0,y:0),.init(x:0,y:100),.init(x:100,y:100)]
    let shifted=l.map{CGPoint(x:$0.x*2+500,y:$0.y*2-900)}
    try check(DrawingRecognition.distance(l,shifted)<0.00001,"绘图可跨大小和位置识别")
    let rotated=l.map{CGPoint(x:-$0.y,y:$0.x)}
    try check(DrawingRecognition.distance(l,rotated)>0.2,"不同方向的L不能被归一化成同一动作")
    try check(DrawingRecognition.distance([.zero,.zero],l).isInfinite,"停留轨迹不能误匹配绘图")
    let jitter:[CGPoint]=[.init(x:0,y:0),.init(x:1,y:50),.init(x:0,y:100),.init(x:50,y:101),.init(x:100,y:100)]
    try check(DrawingRecognition.distance(l,jitter)<0.03,"小抖动不破坏自由绘图识别")
    var wheel=ScrollDeviceProfile();wheel.speed=2;wheel.reverseY=true
    try check(ScrollTransformation.delta(4,profile:wheel,horizontal:false)==(-8),"垂直反向/速度组合")
    try check(ScrollTransformation.delta(4,profile:wheel,horizontal:true)==8,"垂直反向不影响水平")
    wheel.acceleration=1
    try check(abs(ScrollTransformation.delta(20,profile:wheel,horizontal:false))>40,"加速度提高大幅滚轮输出")
    let start=[RawTouchContact(id:1,point:.init(x:0.2,y:0.3)),RawTouchContact(id:2,point:.init(x:0.8,y:0.3))]
    var sequence=TouchSequence(pid:1,start:1,contacts:start)
    sequence.update([RawTouchContact(id:1,point:.init(x:0.3,y:0.5)),RawTouchContact(id:2,point:.init(x:0.7,y:0.5))])
    try check(sequence.maxFingers==2 && abs(sequence.displacement.y-0.2)<0.001,"触点ID与最大手指数保留，测量整体位移")
    try check(sequence.spreadChange < -0.09,"捏合基于实际触点间距")
    let edge=[RawTouchContact(id:1,point:.init(x:0.05,y:0.9))]
    let corner=TouchSequence(pid:1,start:0,contacts:edge)
    try check(corner.matches(region:"topLeft") && !corner.matches(region:"bottomLeft"),"触控板角落由归一化起点限定")
    var anchor=TouchSequence(pid:1,start:0,contacts:[.init(id:1,point:.init(x:0.5,y:0.05)),.init(id:2,point:.init(x:0.5,y:0.7))])
    anchor.update([.init(id:1,point:.init(x:0.5,y:0.05)),.init(id:2,point:.init(x:0.7,y:0.8))])
    try check(anchor.hasBottomAnchor,"拇指底边锚点要求同一ID保持位置")
    anchor.update([.init(id:1,point:.init(x:0.8,y:0.05)),.init(id:2,point:.init(x:0.7,y:0.8))])
    try check(!anchor.hasBottomAnchor,"底边滑动触点不能冒充静止拇指")
    let screen=CGRect(x:-1920,y:-100,width:1920,height:1080)
    try check(EnhancedInputEngine.matchesEdge("bottomLeft",at:.init(x:-1919,y:979),frames:[screen]),"负坐标显示器热角")
    try check(!EnhancedInputEngine.matchesEdge("topRight",at:.init(x:-1000,y:400),frames:[screen]),"屏幕内部不能触发热角")
    let current=CGRect(x:-1500,y:40,width:600,height:400)
    let layouts:[WindowAction]=[.nearMaximize,.centerHalf,.leftTwoThirds,.rightTwoThirds,.maximizeHeight,.maximizeWidth,.quarterFirst,.quarterSecond,.quarterThird,.quarterFourth,.leftThreeQuarters,.rightThreeQuarters,.sixthTopLeft,.sixthTopCenter,.sixthTopRight,.sixthBottomLeft,.sixthBottomCenter,.sixthBottomRight]
    for action in layouts {let result=try WindowGeometry.targetFrame(action:action,current:current,visibleFrames:[screen]);try check(screen.contains(result),"新增布局位于目标工作区："+action.rawValue)}
    let two=try WindowGeometry.targetFrame(action:.rightTwoThirds,current:current,visibleFrames:[screen])
    try check(two==CGRect(x:-1280,y:-100,width:1280,height:1080),"右侧2/3尺寸/位置")
    let height=try WindowGeometry.targetFrame(action:.maximizeHeight,current:current,visibleFrames:[screen])
    try check(height.minX==current.minX && height.width==current.width && height.height==screen.height,"仅高度最大化不改变宽度")
    var wc=WindowEnhancementConfiguration();wc.reservedLeft=200;wc.reservedRight=100
    let area=WindowEnhancementGeometry.workArea(screen,configuration:wc)
    try check(area.minX==screen.minX+200 && area.width==screen.width-300,"左右预留区")
    let gap=WindowEnhancementGeometry.inset(area,gap:20)
    try check(gap.width==area.width-20 && gap.minX==area.minX+10,"间距不侵入相邻窗口")
    try check(WindowEnhancementGeometry.cycle(.leftHalf,count:1) == .leftTwoThirds && WindowEnhancementGeometry.cycle(.leftHalf,count:2) == .thirdLeft && WindowEnhancementGeometry.cycle(.leftHalf,count:3) == .leftHalf,"半屏动作循环")
    let restored=WindowEnhancementGeometry.restoredDragFrame(original:current,snapped:screen,pointer:.init(x:-960,y:20))
    try check(restored.size==current.size && restored.midX==(-960),"拖离吸附保持原尺寸及抓取横向比例")
    var custom=CustomWindowLayout();custom.x=0.5;custom.width=0.5
    let customFrame=try custom.frame(in:screen);try check(customFrame==CGRect(x:-960,y:-100,width:960,height:1080),"自定义百分比布局")
    custom.width=0.7;try check(!custom.isValid,"超出工作区的自定义布局被拒绝")
    let bab:[String:Any]=["ruleOfKeyboard":[["AppName":"com.test.editor","All Rules":[["Gesture":["keyCode":123,"modifierFlags":524288],"Action":["ActionType":"Preset","Action":"half_of_Left"],"Enable":1,"Note":"左半屏"],["Gesture":["keyCode":8,"modifierFlags":1048576],"Action":["ActionType":"Unknown","Action":"do not guess"]]]]],"ruleOfTrackPad":[["AppName":"All Applications","All Rules":[["Gesture":"1Finger_Tap_Top_Left","Modifier":"Fn","Action":["ActionType":"Preset","Action":"Quarte_of_Top_Left"]]]]],"ruleOfAppleScript":[["Name":"测试","AppleScript":"return 42"]]]
    let migrated=try EnhancedRuleFiles.importBAB(bab)
    try check(migrated.configuration.rules.count==2 && migrated.configuration.rules.allSatisfy{!$0.enabled},"仅明确映射迁移且全部暂停")
    try check(migrated.configuration.rules[0].appBundleID=="com.test.editor","应用范围迁移保留")
    try check(migrated.configuration.rules[1].modifiers==UInt64(NSEvent.ModifierFlags.function.rawValue),"Fn迁移不能附加默认Option条件")
    try check(migrated.note.contains("未转换") && migrated.configuration.scriptLibrary.count==1,"未转换项目明确报告，脚本仅存储")
    var tip=TouchSequence(pid:1,start:0,contacts:[.init(id:1,point:.init(x:0.5,y:0.1))])
    tip.update([.init(id:1,point:.init(x:0.5,y:0.1)),.init(id:2,point:.init(x:0.7,y:0.7))],timestamp:0.5)
    try check(tip.isTipTap(remaining:[.init(id:1,point:.init(x:0.5,y:0.1))],ended:0.6),"TipTap要求固定锚指，其他指短拍后离开")
    try check(!tip.isTipTap(remaining:[.init(id:1,point:.init(x:0.9,y:0.1))],ended:0.6),"锚指滑动不是TipTap")
    try check(!tip.isTipTap(remaining:[.init(id:1,point:.init(x:0.5,y:0.1))],ended:1.2),"长按不是TipTap")
    var device=HIDDeviceProfile();device.deviceID="hid:test:device";device.enabled=true
    var button=HIDButtonMapping();button.usage=5;button.enabled=true;device.buttons=[button]
    configuration.hidProfiles=[device];try EnhancedInputValidation.validate(configuration)
    let withHID=try JSONDecoder().decode(InputEnhancementConfiguration.self,from:JSONEncoder().encode(configuration))
    try check(withHID.hidProfiles==configuration.hidProfiles,"逐设备ID和按钮规则编解码完整保留")
    configuration.hidProfiles[0].buttons.append(button)
    try rejects({try EnhancedInputValidation.validate(configuration)},"同设备按钮冲突不得任意选择")
    try check(EnhancedSystemPreset.wifiOn.mediaKey==nil && EnhancedSystemPreset.wifiOff.mediaKey==nil,"WiFi经CoreWLAN实现，不冒充媒体快捷键")
    let invalid=ScrollTransformation.smoothingStep(CGPoint(x:Double.nan,y:1),duration:0.16)
    try check(invalid.finished && invalid.x==0 && invalid.remaining == .zero,"非有限滚轮输入不崩溃或继续插值")
    try check(ScrollTransformation.delta(.nan,profile:wheel,horizontal:false)==0,"非有限原滚轮delta保守归零")
    let half=ScrollTransformation.smoothingStep(CGPoint(x:0.5,y:-0.5),duration:0.16)
    try check(half.finished,"半像素残留按预算结束，不在正负半像素间无限振荡")
    var residual=CGPoint(x:134,y:-93),totalX:Int32=0,totalY:Int32=0,finished=false
    for _ in 0..<240 {
        let step=ScrollTransformation.smoothingStep(residual,duration:0.16)
        totalX += step.x;totalY += step.y;residual=step.remaining
        if step.finished {finished=true;break}
    }
    try check(finished && abs(Double(totalX)-134)<=0.5 && abs(Double(totalY)+93)<=0.5,"滚轮插值有限结束并保留两个轴的累计位移")
    print("PASS: \(assertions)项输入/窗口增强组件验证；真实触控、压力、媒体键、Magic Mouse及多屏仍须设备验收")
}
