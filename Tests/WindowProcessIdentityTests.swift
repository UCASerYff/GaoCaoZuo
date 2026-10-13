import Foundation
@MainActor func runWindowProcessIdentityTests()throws {
    var count=0
    func check(_ condition:Bool,_ message:String)throws {count += 1;if !condition {throw SystemControlError.message("窗口进程身份："+message)}}
    let captured=Date(timeIntervalSince1970:1000),restarted=Date(timeIntervalSince1970:1001)
    try check(WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:captured,currentPID:42,currentLaunchDate:captured),"同PID且同启动时间可匹配")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:captured,currentPID:42,currentLaunchDate:restarted),"复用PID或重启不可匹配")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:nil,currentPID:42,currentLaunchDate:nil),"两个未知启动身份不能被当作相等")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:captured,currentPID:42,currentLaunchDate:nil),"当前启动身份不可读必须停止")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:nil,currentPID:42,currentLaunchDate:captured),"捕获时身份未知必须停止")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:captured,currentPID:43,currentLaunchDate:captured),"即使时间相同也不能换进程")
    try check(!WindowProcessIdentity.matches(capturedPID:0,capturedLaunchDate:captured,currentPID:0,currentLaunchDate:captured),"PID0不能被当成有效窗口目标")
    print("PASS: \(count)项窗口进程启动身份测试（包含PID复用和未知身份）；不操作真实窗口")
}
