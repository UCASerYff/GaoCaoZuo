import AppKit

/// Exercises the production refresh gate using only value fixtures. No device
/// manager, timer, service client, event tap or generated event is constructed.
func runHIDEventServiceRefreshTests()throws {
    var checks=0
    func check(_ value:Bool,_ message:String)throws {checks += 1;guard value else {throw DataFailure.message("HID服务刷新："+message)}}
    func device(_ registry:UInt64,_ services:[UInt64]=[])->HIDDeviceDescriptor {
        .init(id:HIDConnectionIdentity.identifier(bootSession:"public-refresh-boot",registryID:registry,vendor:1,product:1,location:1,transport:"public",usagePairs:["1:2"],interfacePath:"public/\(registry)"),
              name:"same public model",vendor:1,product:1,location:1,buttonUsages:[1],registryID:registry,
              interfacePath:"public/\(registry)",eventServiceRegistryIDs:services)
    }
    func batch(_ state:inout HIDEventServiceRefreshState,_ devices:[HIDDeviceDescriptor])throws -> HIDEventServiceRefreshState.Batch {
        guard let value=state.begin(devices:devices) else {throw DataFailure.message("HID服务刷新：缺少预期批次")};return value
    }
    let original=device(10)
    var state=HIDEventServiceRefreshState(),devices=[original],identifiers=[original.registryID:original.id]
    try check(state.begin(devices:devices)==nil,"未启动不能排队")
    state.start()
    try check(state.begin(devices:[])==nil,"空设备列表不排队")
    let late=try batch(&state,devices)
    try check(state.begin(devices:devices)==nil,"只允许一个查询批次在途")
    try check(state.complete(late,serviceIDs:[[100,0,100]],devices:&devices,identifiers:identifiers),"首次为空的映射接受晚到服务")
    try check(devices[0].eventServiceRegistryIDs==[100] && HIDEventOwnership.uniqueOwner(senderID:100,devices:devices)==original.id,"晚到服务只归属原连接，且去零去重")
    var expected=original;expected.eventServiceRegistryIDs=[100]
    try check(devices==[expected],"刷新只改服务映射，保留设备身份与其他元数据")
    let unchanged=try batch(&state,devices)
    try check(!state.complete(unchanged,serviceIDs:[[100,100,0]],devices:&devices,identifiers:identifiers),"相同集合不发布变化")
    try check(!state.complete(unchanged,serviceIDs:[[999]],devices:&devices,identifiers:identifiers) && devices[0].eventServiceRegistryIDs==[100],"批次不能重复提交")
    let replacement=try batch(&state,devices)
    try check(state.complete(replacement,serviceIDs:[[101]],devices:&devices,identifiers:identifiers),"服务更换更新缓存")
    try check(HIDEventOwnership.uniqueOwner(senderID:100,devices:devices)==nil && HIDEventOwnership.uniqueOwner(senderID:101,devices:devices)==original.id,"完整替换使旧sender失效")
    let missing=try batch(&state,devices)
    try check(state.complete(missing,serviceIDs:[[]],devices:&devices,identifiers:identifiers) && devices[0].eventServiceRegistryIDs.isEmpty,"当前空集合清除失效服务")
    let disconnected=try batch(&state,devices)
    state.connectionsChanged();devices=[];identifiers=[:]
    try check(!state.complete(disconnected,serviceIDs:[[102]],devices:&devices,identifiers:identifiers) && devices.isEmpty,"断连后旧结果不能重插设备")

    devices=[original];identifiers=[10:original.id];state.connectionsChanged()
    let aba=try batch(&state,devices)
    state.connectionsChanged();state.connectionsChanged()
    try check(!state.complete(aba,serviceIDs:[[103]],devices:&devices,identifiers:identifiers) && devices[0].eventServiceRegistryIDs.isEmpty,"断连再连即使完整身份值相同，也拒绝旧拓扑结果")
    let oldSession=try batch(&state,devices)
    state.stop()
    try check(state.begin(devices:devices)==nil && !state.complete(oldSession,serviceIDs:[[104]],devices:&devices,identifiers:identifiers),"stop废弃排队和在途结果")
    state.start()
    let restarted=try batch(&state,devices)
    try check(!state.complete(oldSession,serviceIDs:[[104]],devices:&devices,identifiers:identifiers) && state.begin(devices:devices)==nil,"旧session回调不能清除新session在途批次")
    try check(state.complete(restarted,serviceIDs:[[105]],devices:&devices,identifiers:identifiers),"重启后的新批次正常提交")

    let stale=try batch(&state,devices),reconnected=device(11)
    state.connectionsChanged();devices=[reconnected];identifiers=[11:reconnected.id]
    try check(!state.complete(stale,serviceIDs:[[105]],devices:&devices,identifiers:identifiers),"同型号新连接不接收旧连接结果")
    let newConnection=try batch(&state,devices)
    try check(state.complete(newConnection,serviceIDs:[[106]],devices:&devices,identifiers:identifiers) && HIDEventOwnership.uniqueOwner(senderID:106,devices:devices)==reconnected.id,"新连接仅绑定自身服务")
    var physical=ScrollDeviceProfile();physical.enabled=true;physical.deviceID=original.id;physical.bypassModifiers=0
    try check(HIDEventOwnership.profile([physical],owner:reconnected.id,precise:false,app:"public.app",flags:0)==nil,"同型号重连不能接管原设备规则")
    let changedPath=try batch(&state,devices)
    devices[0].interfacePath="public/replaced"
    try check(!state.complete(changedPath,serviceIDs:[[999]],devices:&devices,identifiers:identifiers) && devices[0].eventServiceRegistryIDs==[106],"当前接口路径不符不提交")
    devices[0].interfacePath=reconnected.interfacePath
    let invalidScope=try batch(&state,devices)
    try check(!state.complete(invalidScope,serviceIDs:[nil],devices:&devices,identifiers:identifiers) && devices[0].eventServiceRegistryIDs==[106],"无法核验接口的结果不当作空服务集合")

    state.connectionsChanged();devices=[device(10),device(11)];identifiers=Dictionary(uniqueKeysWithValues:devices.map{($0.registryID,$0.id)})
    let ambiguous=try batch(&state,devices)
    try check(state.complete(ambiguous,serviceIDs:[[107],[107]],devices:&devices,identifiers:identifiers) && HIDEventOwnership.uniqueOwner(senderID:107,devices:devices)==nil,"共享服务仍保持歧义拒绝")
    let boundedDevices=(20..<30).map{device(UInt64($0))}
    devices=boundedDevices;identifiers=Dictionary(uniqueKeysWithValues:devices.map{($0.registryID,$0.id)});state.connectionsChanged()
    let first=try batch(&state,devices)
    try check(first.interfaces.count==8,"单批最多查询八个接口")
    _=state.complete(first,serviceIDs:Array(repeating:[],count:8),devices:&devices,identifiers:identifiers)
    let second=try batch(&state,devices)
    try check(Set((first.interfaces+second.interfaces).map(\.registryID)).count==10,"轮转覆盖超出单批上限的接口")
    state.stop()
    print("HID服务刷新专项通过（\(checks)）：晚到/替换/消失、断连与同型重连、停止/重启旧结果拒绝、接口核验、歧义保持及有界轮转；未启动真实监听、未写设备参数。")
}

@MainActor func runHIDEventOwnershipTests()throws {
    var checks=0
    func check(_ value:Bool,_ message:String)throws {checks += 1;guard value else {throw DataFailure.message(message)}}
    func device(_ registry:UInt64,_ service:UInt64)->HIDDeviceDescriptor {
        .init(id:HIDConnectionIdentity.identifier(bootSession:"public-test-boot",registryID:registry,vendor:1,product:1,location:1,transport:"public",usagePairs:["1:2"],interfacePath:"public/\(registry)"),name:"same public model",vendor:1,product:1,location:1,buttonUsages:[1],registryID:registry,eventServiceRegistryIDs:[service])
    }
    let a=device(10,100),b=device(11,101)
    try check(HIDEventOwnership.uniqueOwner(senderID:100,devices:[a,b])==a.id,"Source did not map exact connected event service")
    try check(HIDEventOwnership.uniqueOwner(senderID:101,devices:[a,b])==b.id,"Same model/port confused physical ownership")
    try check(HIDEventOwnership.uniqueOwner(senderID:10,devices:[a,b])==a.id,"Direct IORegistry device sender lost")
    try check(HIDEventOwnership.uniqueOwner(senderID:0,devices:[a,b])==nil,"Zero sender guessed a device")
    try check(HIDEventOwnership.uniqueOwner(senderID:100,devices:[b])==nil,"Disconnected source inherited a different device")
    var ambiguous=b;ambiguous.eventServiceRegistryIDs=[100]
    try check(HIDEventOwnership.uniqueOwner(senderID:100,devices:[a,ambiguous])==nil,"Ambiguous interface source guessed ownership")
    var legacy=a;legacy.id="hid:legacy"
    try check(HIDEventOwnership.uniqueOwner(senderID:100,devices:[legacy])==nil,"Unscoped legacy ID acquired a live device")
    var global=ScrollDeviceProfile(),physical=ScrollDeviceProfile()
    global.enabled=true;global.bypassModifiers=0;physical.enabled=true;physical.bypassModifiers=0;physical.deviceID=a.id
    try check(HIDEventOwnership.profile([global,physical],owner:a.id,precise:false,app:"public.app",flags:0)?.id==physical.id,"Global profile overrode an exact physical rule")
    try check(HIDEventOwnership.profile([global,physical],owner:nil,precise:false,app:"public.app",flags:0)==nil,"Unknown source fell back to all wheels")
    try check(HIDEventOwnership.profile([physical],owner:b.id,precise:false,app:"public.app",flags:0)==nil,"Rule for A modified B")
    physical.excludedApps=["public.app"]
    try check(HIDEventOwnership.profile([global,physical],owner:a.id,precise:false,app:"public.app",flags:0)==nil,"Physical app exclusion fell through to global")
    physical.excludedApps=[];physical.bypassModifiers=1
    try check(HIDEventOwnership.profile([global,physical],owner:a.id,precise:false,app:"public.app",flags:1)==nil,"Physical modifier bypass fell through to global")
    try check(HIDEventOwnership.profile([global],owner:nil,precise:false,app:"public.app",flags:0)?.id==global.id,"Explicit all-wheel rule stopped without physical rules")
    try check(HIDEventOwnership.profile([global],owner:nil,precise:true,app:"public.app",flags:0)==nil,"Discrete wheel profile modified continuous scroll")
    if let synthetic=CGEvent(scrollWheelEvent2Source:nil,units:.line,wheelCount:1,wheel1:1,wheel2:0,wheel3:0) {
        try check(HIDEventOwnership.owner(of:synthetic,devices:[a,b])==nil,"A generated CGEvent falsely proved physical ownership")
    }else {throw DataFailure.message("无法创建软件事件拒绝夹具")}
    print("HID归属专项通过（\(checks)）：精确服务/接口匹配、歧义/断接/旧绑定拒绝、未知来源放行、按设备优先及排除/绕过不退化、合成事件不能冒充实体通过；未安装监听或修改设备参数。")
}
