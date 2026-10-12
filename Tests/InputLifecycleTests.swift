import AppKit
import Foundation

@MainActor func runInputLifecycleTests() throws {
    var count=0
    func check(_ value:@autoclosure ()->Bool,_ message:String) throws {
        count += 1;if !value(){throw DataFailure.message("输入生命周期："+message)}
    }
    let none=InputListenerAuthorization(monitoring:false,accessibility:false)
    let listen=InputListenerAuthorization(monitoring:true,accessibility:false)
    let both=InputListenerAuthorization(monitoring:true,accessibility:true)
    let ax=InputListenerAuthorization(monitoring:false,accessibility:true)
    let healthy=InputTapState(authorization:listen,active:false,portValid:true,sourceValid:true,enabled:true)
    func decision(_ authorization:InputListenerAuthorization,_ state:InputTapState?=nil,
                  running:Bool=true,paused:Bool=false,work:Bool=true,active:Bool=false)->InputTapLifecycle.Decision {
        InputTapLifecycle.decision(running:running,paused:paused,hasWork:work,authorization:authorization,wantsActive:active,tap:state)
    }
    try check(decision(none) == .stop,"无权限不启动")
    try check(decision(listen) == .install && decision(ax) == .install,"两种监听授权均可恢复缺失tap")
    try check(decision(listen,healthy) == .keep,"健康监听保持，不重置手势会话")
    try check(decision(both,healthy,active:true) == .rebuild,"后授予AX需升级active tap")
    var state=healthy;state.authorization=both;state.active=true
    try check(decision(listen,state) == .rebuild,"撤销AX需降级并清理原有替换状态")
    try check(decision(ax,state,active:true) == .rebuild,"独立输入监控状态变化同样重建")
    state=healthy;state.portValid=false
    try check(decision(listen,state) == .rebuild,"非nil失效Mach port必须恢复")
    state=healthy;state.sourceValid=false
    try check(decision(listen,state) == .rebuild,"失效runloop source必须恢复")
    state=healthy;state.enabled=false
    try check(decision(listen,state) == .rebuild,"系统禁用tap必须恢复")
    try check(decision(both,healthy,running:false) == .stop && decision(both,healthy,paused:true) == .stop && decision(both,healthy,work:false) == .stop,"停止/暂停/无规则不自动重启")
    state=healthy;state.authorization=both
    try check(decision(both,state,active:true) == .rebuild,"授权未变但监听模式不符仍重建")
    try check(InputTapLifecycle.shouldRecoverDisabledTap(triggerGeneration:7,currentGeneration:7,hasTap:true),"当前tap的停用通知允许恢复")
    try check(!InputTapLifecycle.shouldRecoverDisabledTap(triggerGeneration:7,currentGeneration:8,hasTap:true),"旧回调不能拆掉重新配置/轮询恢复的新tap")
    try check(!InputTapLifecycle.shouldRecoverDisabledTap(triggerGeneration:7,currentGeneration:7,hasTap:false),"暂停或停止后陈旧恢复不能重启监听")

    // Inject only the public monitor registration boundary: no fabricated pressure events or permissions.
    var globalAdds=0,localAdds=0,nextToken=0
    var removed:[Int]=[]
    let backend=InputPressureMonitorBackend(addGlobal:{_ in globalAdds += 1;nextToken += 1;return nextToken},
                                           addLocal:{_ in localAdds += 1;nextToken += 1;return nextToken},
                                           remove:{if let token=$0 as? Int {removed.append(token)}})
    let engine=EnhancedInputEngine(pressureBackend:backend)
    engine.startMonitoring()
    try check(globalAdds==0 && localAdds==0,"默认高级输入关闭不申请监听")
    var configuration=InputEnhancementConfiguration();configuration.enabled=true
    var pressure=EnhancedInputRule();pressure.enabled=true;pressure.trigger = .pressure;pressure.consume=false
    configuration.rules=[pressure]
    engine.configure(configuration,excludedApps:[],handler:{_ in},report:{_ in})
    try check(globalAdds==0 && localAdds==0,"配置阶段不在权限确认前安装压力监听")
    engine.startMonitoring();engine.startMonitoring()
    try check(globalAdds==1 && localAdds==1 && removed.isEmpty,"重复恢复入口不重复安装压力监听")
    engine.stop()
    try check(removed==[1,2],"暂停清理全部压力监听")
    engine.startMonitoring()
    try check(globalAdds==2 && localAdds==2,"暂停/失权恢复后重新安装压力监听")
    engine.configure(configuration,excludedApps:[],handler:{_ in},report:{_ in});engine.startMonitoring()
    try check(globalAdds==3 && localAdds==3 && removed==[1,2,3,4],"重新配置释放旧监听并恢复新监听")
    configuration.rules[0].enabled=false
    engine.configure(configuration,excludedApps:[],handler:{_ in},report:{_ in});engine.startMonitoring()
    try check(globalAdds==3 && localAdds==3 && removed==[1,2,3,4,5,6],"禁用压力规则后不重装")
    var retryGlobal=0,retryLocal=0
    let retryEngine=EnhancedInputEngine(pressureBackend:.init(addGlobal:{_ in retryGlobal += 1;return retryGlobal==1 ? nil:retryGlobal},addLocal:{_ in retryLocal += 1;return 100+retryLocal},remove:{_ in}))
    configuration.rules[0].enabled=true
    retryEngine.configure(configuration,excludedApps:[],handler:{_ in},report:{_ in})
    retryEngine.startMonitoring();retryEngine.startMonitoring();retryEngine.startMonitoring()
    try check(retryGlobal==2 && retryLocal==1,"系统未接受全局monitor时重试，不重复局部monitor")
    retryEngine.stop();engine.stop()

    let root=URL(fileURLWithPath:"/private/tmp").appendingPathComponent("GaoCaoZuo-InputLifecycle-"+UUID().uuidString)
    defer{try? FileManager.default.removeItem(at:root)}
    let store=OperationStore(directory:root)
    var layout=CustomWindowLayout();layout.name="独立布局验收"
    store.update{$0.windowEnhancements.customLayouts.append(layout);$0.workflows.append(.init(name:"独立组合验收",steps:[]))}
    let app=EnhancedOpenApp(name:"独立应用验收",bundleID:"com.example.InputLifecycleFixture",path:"/Applications/Fixture.app")
    try store.fileEnhancements.update{$0.apps.append(app)}
    let actions=OperationPanelView(store:store,close:{}).actions
    try check(actions.contains{$0.id=="window.custom."+layout.id.uuidString},"操作面板包含真实自定义布局动作")
    try check(actions.contains{$0.id=="file.open."+app.id.uuidString && $0.files},"操作面板包含已保存应用的文件动作")
    try check(actions.contains{$0.id.hasPrefix("workflow.run.") && $0.title=="独立组合验收"},"复用动作库仍保留动态组合操作")
    try check(!actions.contains{$0.id=="panel.show"},"面板不列出自我切换动作")
    print("PASS: \(count)项输入监听生命周期/压力注册恢复/面板动作测试；未改系统权限、未生成压力样本、未启动设备监听或应用")
}
