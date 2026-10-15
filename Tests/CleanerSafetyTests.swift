import Foundation

@MainActor func runCleanerSafetyTests() throws {
    var health=true
    var releases=0
    let safety=CleanerInputSafety(health:{health},release:{releases += 1})
    func check(_ ok:Bool,_ name:String) throws {if !ok {throw DataFailure.message("清洁安全回归失败："+name)}}
    try check(CleanerRescuePolicy.canVerify(sourcePID:0,repeated:false),"系统来源可用于演练")
    try check(!CleanerRescuePolicy.canVerify(sourcePID:123,repeated:false) && !CleanerRescuePolicy.canVerify(sourcePID:0,repeated:true),"合成和重复不能作为演练")
    try check(!safety.permitsInterception(now:10),"未开始不拦截")
    try check(!safety.begin(now:10,duration:29) && !safety.begin(now:10,duration:181),"时限边界")
    try check(!safety.begin(now:.nan,duration:30),"拒绝无效时钟")
    health=false;try check(!safety.begin(now:10,duration:30),"无健康通道不能开始")
    health=true;try check(safety.begin(now:10,duration:30),"可用通道租约")
    try check(safety.permitsInterception(now:10.9),"心跳有效")
    safety.pulse(now:10.9);try check(safety.permitsInterception(now:11.8),"续租")
    try check(!safety.permitsInterception(now:12) && releases == 1,"主线程无心跳释放")
    try check(!safety.permitsInterception(now:12.1) && releases == 1,"失效不重复释放")
    safety.finish();try check(safety.begin(now:20,duration:30),"全新会话")
    health=false;try check(!safety.permitsInterception(now:20.1) && releases == 2,"通道丢失释放")
    health=true;safety.finish();try check(safety.begin(now:30,duration:30),"重新开始")
    safety.pulse(now:59.9);try check(!safety.permitsInterception(now:60) && releases == 3,"硬截止不可续租越界")
    safety.finish();try check(safety.begin(now:70,duration:30),"重建前租约")
    safety.bind(nil,active:false);try check(!safety.permitsInterception(now:70.1) && releases == 4,"通道重建使原租约失效")
    safety.finish();try check(!safety.permitsInterception(now:70.2),"退出即放行")
    print("清洁模式租约与故障释放定向检查通过；未创建遮罩、事件通道或发送按键。")
}

@MainActor func runProductionActionCatalogTests() throws {
    let actions=OperationAction.all
    guard Set(actions.map(\.id)).count == actions.count else {throw DataFailure.message("生产动作目录存在重复ID")}
    let registry=ActionRegistry()
    for action in actions {
        guard registry.descriptor(for:action.id) != nil else {throw DataFailure.message("动作未接入统一注册表："+action.id)}
    }
    for id in ["cleaner.start","flykey.show","inputsource.settings","snippet.manager.show","selection.uppercase","selection.clipboard.show","clipboard.stack.push"] {
        guard actions.contains(where:{$0.id == id}) else {throw DataFailure.message("生产面板未暴露动作："+id)}
    }
    print("生产动作与统一描述表覆盖检查通过（\(actions.count)项）；未执行系统或应用动作。")
}
