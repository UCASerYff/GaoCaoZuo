import Foundation
import AppKit

@MainActor private final class NativeSnapTestGate {
    private var continuation:CheckedContinuation<Void,Never>?
    private(set) var waiting=false
    func wait() async {await withCheckedContinuation {continuation=$0;waiting=true}}
    func open() {continuation?.resume();continuation=nil;waiting=false}
}

/// No event injection, permission request, AX access or real window is used.
@MainActor func runNativeWindowSnapTests() async throws {
    var checks=0
    func check(_ condition:Bool,_ message:String) throws {
        guard condition else {throw SystemControlError.message("原生拖动吸附："+message)};checks += 1
    }
    func waitUntil(_ condition:() -> Bool) async throws {
        let deadline=ContinuousClock.now.advanced(by:.seconds(2))
        while !condition() {
            guard ContinuousClock.now<deadline else {throw SystemControlError.message("原生拖动吸附测试等待超时")}
            try await Task.sleep(for:.milliseconds(5))
        }
    }
    try check(WindowInputPolicy.startMode(dragEnabled:false,snapEnabled:true,optionDown:false) == .nativeSnap,"普通左键拖动只需开启吸附，不需Option或面板")
    try check(WindowInputPolicy.startMode(dragEnabled:false,snapEnabled:true,optionDown:true) == .nativeSnap,"未开启Option移动时Option不改变原生吸附模式")
    try check(WindowInputPolicy.startMode(dragEnabled:true,snapEnabled:false,optionDown:false)==nil,"Option移动独立开关不会强制普通拖动吸附")
    try check(WindowInputPolicy.startMode(dragEnabled:true,snapEnabled:false,optionDown:true) == .optionMove,"Option移动仍独立可用")
    try check(WindowInputPolicy.startMode(dragEnabled:false,snapEnabled:false,optionDown:false)==nil,"关闭两项时不启动窗口输入")
    let work=WindowInputPolicy.needsEvents(windowsConnected:true,dragEnabled:false,snapEnabled:true)
    try check(work && !WindowInputPolicy.needsEvents(windowsConnected:false,dragEnabled:false,snapEnabled:true),"吸附单独启用会申请左键事件，有窗口管理器才启动")
    let authorization=InputListenerAuthorization(monitoring:true,accessibility:true)
    try check(InputTapLifecycle.decision(running:true,paused:false,hasWork:work,authorization:authorization,wantsActive:false,tap:nil) == .install,"无其他绑定时原生吸附仍安装listen-only输入tap")
    try check(InputTapLifecycle.decision(running:true,paused:true,hasWork:work,authorization:authorization,wantsActive:false,tap:nil) == .stop,"暂停会停止吸附监听")
    try check(InputTapLifecycle.decision(running:true,paused:false,hasWork:work,authorization:.init(monitoring:false,accessibility:false),wantsActive:false,tap:nil) == .stop,"权限全部丢失停止监听")
    try check(WindowInputPolicy.canContinue(capturedPID:42,frontPID:42,paused:false,running:true,excluded:false),"同一目标进程允许继续")
    try check(!WindowInputPolicy.canContinue(capturedPID:42,frontPID:43,paused:false,running:true,excluded:false),"用户切换应用会取消窗口输入")
    try check(!WindowInputPolicy.canContinue(capturedPID:nil,frontPID:nil,paused:false,running:true,excluded:false),"未知前台不能nil等价继续")
    try check(!WindowInputPolicy.canContinue(capturedPID:42,frontPID:42,paused:true,running:true,excluded:false),"暂停清理待处理拖动")
    try check(!WindowInputPolicy.canContinue(capturedPID:42,frontPID:42,paused:false,running:false,excluded:false),"停止监听清理待处理拖动")
    try check(!WindowInputPolicy.canContinue(capturedPID:42,frontPID:42,paused:false,running:true,excluded:true),"应用排除同样约束吸附")
    let original=CGRect(x:200,y:100,width:800,height:500),pointer=CGPoint(x:400,y:115),edge=CGPoint(x:1,y:400)
    try check(!WindowDragGeometry.isWindowDrag(initialFrame:original,currentFrame:original,initialPointer:pointer,pointer:edge),"拖文字或文件仅移动指针，不获得窗口移动证据")
    try check(!WindowDragGeometry.isWindowDrag(initialFrame:original,currentFrame:original.insetBy(dx:-10,dy:0),initialPointer:pointer,pointer:edge),"边框调整尺寸不能当标题栏拖动")
    try check(WindowDragGeometry.isWindowDrag(initialFrame:original,currentFrame:original.offsetBy(dx:-100,dy:100),initialPointer:pointer,pointer:edge),"真实窗口位移与足够指针距离才允许预览/吸附")
    let workArea=CGRect(x:0,y:25,width:1440,height:850),screen=CGRect(x:0,y:0,width:1440,height:900)
    let cases:[(CGPoint,WindowAction)]=[(CGPoint(x:1,y:450),.leftHalf),(CGPoint(x:1439,y:450),.rightHalf),(CGPoint(x:700,y:1),.maximize),(CGPoint(x:1,y:1),.topLeft),(CGPoint(x:1439,y:1),.topRight),(CGPoint(x:1,y:899),.bottomLeft),(CGPoint(x:1439,y:899),.bottomRight)]
    for (point,action) in cases {
        let snap=WindowDragGeometry.snapTarget(pointer:point,visibleFrames:[workArea],screenFrames:[screen])
        try check(snap?.action==action,"单屏左右半屏/顶部最大化/四角对应正确")
        let frame=try WindowGeometry.targetFrame(action:action,current:original,visibleFrames:[workArea])
        try check(workArea.contains(frame),"吸附结果避开菜单栏与Dock")
    }
    let restored=WindowEnhancementGeometry.restoredDragFrame(original:original,snapped:CGRect(x:0,y:25,width:720,height:850),pointer:CGPoint(x:500,y:200))
    try check(restored.size==original.size && restored.contains(CGPoint(x:500,y:200)),"拖离恢复原尺寸并保留鼠标标题栏锚点")
    // Reproduce mouse-up while the asynchronous restoration is still settling.
    do {
        let coordinator=WindowDragRestorationCoordinator(),gate=NativeSnapTestGate()
        var operationFinished=false,releaseFinished=false,observedReleasedSession=false
        try check(coordinator.begin {
            await gate.wait();observedReleasedSession=coordinator.isFinishingReleasedDrag;operationFinished=true
        },"启动一次待完成恢复")
        try await waitUntil{gate.waiting}
        let release=Task{@MainActor in await coordinator.waitForRestorationBeforeRelease();releaseFinished=true}
        try await waitUntil{coordinator.isFinishingReleasedDrag}
        try check(coordinator.isPending && !operationFinished && !releaseFinished,"快松手不提前结束会话或取消尚未完成恢复")
        try check(!coordinator.begin {},"恢复未完成时不能并发启动另一恢复")
        gate.open();await release.value
        try check(operationFinished && releaseFinished && observedReleasedSession && !coordinator.isPending,"恢复完成后才结束mouseup，保留最终吸附会话")
    }
    // Pause, permission loss or app changes invalidate the generation and cancel;
    // the coordinator still waits for the operation to acknowledge cancellation.
    do {
        let coordinator=WindowDragRestorationCoordinator(),gate=NativeSnapTestGate()
        var cancellationObserved=false,releaseFinished=false,releasedSession=false
        coordinator.begin {await gate.wait();cancellationObserved=Task.isCancelled;releasedSession=coordinator.isFinishingReleasedDrag}
        try await waitUntil{gate.waiting}
        let release=Task{@MainActor in await coordinator.waitForRestorationBeforeRelease();releaseFinished=true}
        try await waitUntil{coordinator.isFinishingReleasedDrag}
        coordinator.cancel()
        try check(coordinator.isPending && !releaseFinished && !coordinator.isFinishingReleasedDrag,"显式取消停止恢复接续，但不抛弃尚未回滚的Task")
        gate.open();await release.value
        try check(cancellationObserved && !releasedSession && releaseFinished && !coordinator.isPending,"已取消的恢复不会复活释放会话")
        var nextFinished=false
        try check(coordinator.begin {nextFinished=true},"旧恢复结束后可开始新的独立恢复")
        await coordinator.waitForRestorationBeforeRelease()
        try check(nextFinished && !coordinator.isPending,"旧Task完成不能清掉下一恢复")
    }
    print("PASS: \(checks)项原生左键窗口吸附几何/权限生命周期/快松手恢复测试；未操作真实GUI或注入输入")
}
