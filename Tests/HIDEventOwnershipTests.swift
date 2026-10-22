import AppKit

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
