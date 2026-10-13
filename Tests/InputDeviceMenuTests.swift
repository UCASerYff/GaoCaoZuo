import AppKit

@MainActor func runInputDeviceMenuTests()throws {
    var count=0
    func check(_ value:@autoclosure()->Bool,_ message:String)throws {count += 1;if !value() {throw SystemControlError.message("设备/边段/菜单测试："+message)}}
    func rejects(_ body:()throws->Void,_ message:String)throws {do {try body()} catch {try check(true,message);return};try check(false,message)}
    try check(InputDeviceMatrix.currentMatrix(devices:[],monitoringAuthorized:true).isEmpty,"缺设备不能虚构三条已连接设备")
    let pad=HIDDeviceDescriptor(id:"hid:1452:1:42",name:"Apple Internal Trackpad",vendor:1452,product:1,location:42,buttonUsages:[1],transport:"SPI",isBuiltIn:true,registryID:123,usagePairs:["1:2","13:5"],hasWheelElement:false,hasPressureElement:true)
    let matrix=InputDeviceMatrix.currentMatrix(devices:[pad],monitoringAuthorized:false)
    try check(matrix.count==1 && matrix[0].identity.registryID==123 && matrix[0].identity.transport=="SPI" && matrix[0].identity.isBuiltIn,"矩阵只映射真实描述符身份及连接")
    try check(matrix[0].identity.isTrackpad && !matrix[0].identity.authorized,"设备枚举不意味着监听授权")
    try check(!matrix[0].verifiedOnCurrentMachine && matrix[0].identity.verifiedModel==nil,"内置触控板不自动被标记为实测")
    try check(!matrix[0].capabilities.supportsPerDeviceSpeedHardwareApplied && !matrix[0].capabilities.supportsTipTap,"配置字段和私有算法不冒充硬件已实现能力")
    try check(matrix[0].capabilities.buttonCount==1 && matrix[0].capabilities.supportsPressure,"按钮数量和压力元素仅来自描述符")
    let authorized=InputDeviceMatrix.currentMatrix(devices:[pad],monitoringAuthorized:true)
    try check(authorized[0].identity.authorized && !authorized[0].verifiedOnCurrentMachine,"授权仍不等于真实动作验收")
    let external=HIDDeviceDescriptor(id:"hid:2:3:session-124",name:"Pointer",vendor:2,product:3,location:0,buttonUsages:[1,2,3,5],registryID:124,usagePairs:["1:2"],hasWheelElement:true)
    let mouse=InputDeviceMatrix.currentMatrix(devices:[external],monitoringAuthorized:true)[0]
    try check(mouse.capabilities.buttonCount==4 && mouse.capabilities.supportsDiscreteScroll && !mouse.identity.isTrackpad,"不按设备名称猜测五个按钮或触控能力")
    let f=CGRect(x:-1800,y:-300,width:1800,height:1200)
    func edge(_ region:String,_ point:CGPoint,_ start:Double=0.25,_ end:Double=0.5)->Bool {EnhancedInputEngine.matchesEdge(region,at:point,frames:[f],start:start,end:end,width:10)}
    try check(edge("left",.init(x:-1795,y:0)),"负坐标屏左边段以该屏顶部为0")
    try check(!edge("left",.init(x:-1795,y:-1)),"不在边段内不触发")
    try check(!edge("left",.init(x:-1795,y:300)) && edge("left",.init(x:-1795,y:300),0.5,0.75),"相邻边段端点只触发后一个")
    try check(edge("bottom",.init(x:-900,y:895),0.5,1),"水平边段从左向右且使用Quartz坐标")
    try check(!edge("right",.init(x:-11,y:0)),"配置边缘宽度不扩大至内部")
    try check(!edge("left",.init(x:CGFloat.nan,y:0)) && !edge("left",.zero,0.7,0.2),"非有限坐标和反向区间被拒绝")
    var rule=EnhancedInputRule();rule.trigger = .screenEdge;rule.direction="click";rule.corner="left";rule.edgeStart=0.25;rule.edgeEnd=0.5;rule.edgeWidth=12
    try check(EnhancedInputValidation.error(rule)==nil,"精细边段进入实际规则校验")
    let decoded=try JSONDecoder().decode(EnhancedInputRule.self,from:JSONEncoder().encode(rule))
    try check(decoded==rule,"精细边段字段往返保留")
    let old=try JSONDecoder().decode(EnhancedInputRule.self,from:Data("{}".utf8))
    try check(old.edgeStart==0 && old.edgeEnd==1 && old.edgeWidth==8,"旧边角规则保持原完整边缘语义")
    rule.edgeEnd=0.251;try check(EnhancedInputValidation.error(rule) != nil,"拒绝过窄无意义边段")
    struct Node {let title:String;var enabled=true;var press=false;var children:[Int]=[]}
    var nodes=[Node(title:"root",children:[1]),Node(title:"文件",children:[2]),Node(title:"新建",press:true)]
    func resolve(_ path:[String])throws->Int {try InputMenuPathResolver.resolve(path:path,root:0,children:{nodes[$0].children},title:{nodes[$0].title},enabled:{nodes[$0].enabled},canPress:{nodes[$0].press})}
    let resolved=try resolve(["文件","新建"])
    try check(resolved==2,"按层级确切标题解析最终菜单项")
    try rejects({_ = try resolve(["文件","打开"])},"菜单变化不模糊选取其他项目")
    nodes[1].children=[2,3];nodes.append(Node(title:"新建",press:true))
    try rejects({_ = try resolve(["文件","新建"])},"重名菜单不任意点第一个")
    nodes[1].children=[2];nodes[2].enabled=false
    try rejects({_ = try resolve(["文件","新建"])},"运行时禁用菜单被拒绝")
    nodes[2].enabled=true;nodes[2].press=false
    try rejects({_ = try resolve(["文件","新建"])},"未提供公开AXPress的菜单不假装可执行")
    try rejects({_ = try resolve(["文件"])},"缺最终菜单项的路径拒绝")
    var effect=InputEffect();effect.kind = .menuItem;effect.menuBundleID="com.test.Editor";effect.menuPath=["文件","新建"]
    rule=EnhancedInputRule();rule.effect=effect
    try check(EnhancedInputValidation.error(rule)==nil,"菜单动作接入统一规则验证")
    let roundtrip=try JSONDecoder().decode(InputEffect.self,from:JSONEncoder().encode(effect))
    try check(roundtrip==effect,"菜单目标应用与路径完整保存")
    rule.effect.menuPath=[];try check(EnhancedInputValidation.error(rule) != nil,"不能启用空路径菜单动作")
    var a=EnhancedInputRule();a.enabled=true;a.trigger = .screenEdge;a.direction="click";a.corner="left";a.edgeStart=0.2;a.edgeEnd=0.5
    var b=a;b.id=UUID();b.edgeStart=0.4;b.edgeEnd=0.8
    try check(EnhancedInputValidation.conflictingIDs([a,b])==Set([a.id,b.id]),"同应用重叠边段冲突必须暂停，不任意优先")
    b.edgeStart=0.5;try check(EnhancedInputValidation.conflictingIDs([a,b]).isEmpty,"相邻非重叠边段可用")
    b.edgeStart=0.4;b.appBundleID="com.test.Editor"
    try check(EnhancedInputValidation.conflictingIDs([a,b]).isEmpty,"逐App覆盖全局规则允许优先级")
    var delivery=InputRuleDeliveryState();let ruleID=UUID(),otherID=UUID()
    try check(delivery.accept(id:ruleID,interval:0.5,now:10),"节流首次请求可执行")
    try check(!delivery.accept(id:ruleID,interval:0.5,now:10.49),"短间隔重复被节流")
    try check(delivery.accept(id:otherID,interval:0.5,now:10.49),"不同规则相互不抑制")
    try check(delivery.accept(id:ruleID,interval:0.5,now:10.5),"节流到期允许下一次")
    try check(!delivery.accept(id:ruleID,interval:0.5,now:9) && !delivery.accept(id:ruleID,interval:.nan,now:11),"无效时钟与阈值不触发动作")
    rule=EnhancedInputRule();rule.allowKeyRepeat=true;rule.minimumIntervalSeconds=0.4
    let repeatRule=try JSONDecoder().decode(EnhancedInputRule.self,from:JSONEncoder().encode(rule))
    try check(repeatRule.allowKeyRepeat && repeatRule.minimumIntervalSeconds==0.4,"重复与节流设置完整保存；旧配置默认不重复")
    print("PASS: \(count)项真实设备矩阵映射/精细边段/菜单精确解析测试；不代表真实硬件或AX菜单点按验收")
}
