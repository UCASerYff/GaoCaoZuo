import Foundation
import Darwin

@MainActor func runWindowProcessIdentityTests() throws {
    var count=0
    func check(_ condition:Bool,_ message:String) throws {
        count += 1
        if !condition {throw SystemControlError.message("窗口进程身份："+message)}
    }
    let date=Date(timeIntervalSince1970:1000),later=Date(timeIntervalSince1970:1001)
    let token=WindowProcessIdentity.Token(pid:42,startSeconds:1000,startMicroseconds:123456)
    let reused=WindowProcessIdentity.Token(pid:42,startSeconds:1001,startMicroseconds:123456)
    let microsecondChanged=WindowProcessIdentity.Token(pid:42,startSeconds:1000,startMicroseconds:123457)
    func captured(_ launchDate:Date?)->WindowProcessIdentity.Snapshot? {
        WindowProcessIdentity.capture(pid:42,launchDate:launchDate,readToken:{_ in token})
    }
    let nilDate=captured(nil),knownDate=captured(date)
    try check(nilDate != nil,"合法空launchDate仍捕获真实token")
    try check(WindowProcessIdentity.matches(captured:nilDate,currentPID:42,currentLaunchDate:nil,readToken:{_ in token}),"两边空日期依靠真实启动token匹配")
    try check(WindowProcessIdentity.matches(captured:knownDate,currentPID:42,currentLaunchDate:nil,readToken:{_ in token}),"当前日期暂不可得但token相同")
    try check(WindowProcessIdentity.matches(captured:nilDate,currentPID:42,currentLaunchDate:date,readToken:{_ in token}),"捕获日期不可得但当前有日期且token相同")
    try check(WindowProcessIdentity.matches(captured:knownDate,currentPID:42,currentLaunchDate:date,readToken:{_ in token}),"已知日期与token均相同")
    try check(!WindowProcessIdentity.matches(captured:knownDate,currentPID:42,currentLaunchDate:later,readToken:{_ in token}),"两个非空启动时间不一致仍拒绝")
    try check(!WindowProcessIdentity.matches(captured:nilDate,currentPID:42,currentLaunchDate:nil,readToken:{_ in nil}),"空日期不能在token读取失败时假相等")
    try check(!WindowProcessIdentity.matches(captured:nil,currentPID:42,currentLaunchDate:nil,readToken:{_ in token}),"缺少捕获snapshot必须停止")
    try check(WindowProcessIdentity.capture(pid:42,launchDate:nil,readToken:{_ in nil})==nil,"捕获token失败停止")
    try check(!WindowProcessIdentity.matches(captured:knownDate,currentPID:42,currentLaunchDate:date,readToken:{_ in reused}),"相同PID复用但秒级启动token不同")
    try check(!WindowProcessIdentity.matches(captured:nilDate,currentPID:42,currentLaunchDate:nil,readToken:{_ in microsecondChanged}),"保留整数微秒精度识别同秒重启")
    try check(!WindowProcessIdentity.matches(captured:nilDate,currentPID:43,currentLaunchDate:nil,readToken:{_ in .init(pid:43,startSeconds:1000,startMicroseconds:123456)}),"不同PID即使时间字段相同也不是同进程")
    try check(WindowProcessIdentity.capture(pid:42,launchDate:nil,readToken:{_ in .init(pid:43,startSeconds:1000,startMicroseconds:123456)})==nil,"reader返回错误PID拒绝")
    try check(WindowProcessIdentity.capture(pid:42,launchDate:Date(timeIntervalSinceReferenceDate:.nan),readToken:{_ in token})==nil,"非有限捕获时间拒绝")
    try check(!WindowProcessIdentity.matches(captured:nilDate,currentPID:42,currentLaunchDate:Date(timeIntervalSinceReferenceDate:.infinity),readToken:{_ in token}),"非有限当前时间拒绝")
    var invalidPIDReaderCalled=false
    try check(WindowProcessIdentity.capture(pid:0,launchDate:nil,readToken:{_ in invalidPIDReaderCalled=true;return token})==nil && !invalidPIDReaderCalled,"PID0不读取也不作为窗口目标")
    // Validate the actual C ABI result, not a fabricated token from a partial or wrong process buffer.
    let fullSize=Int32(MemoryLayout<proc_bsdinfo>.size)
    func infoReader(returning size:Int32,pid:UInt32=42,seconds:UInt64=1000,microseconds:UInt64=123456)->WindowProcessIdentity.BSDInfoReader {
        {_,info in info.pbi_pid=pid;info.pbi_start_tvsec=seconds;info.pbi_start_tvusec=microseconds;return size}
    }
    try check(WindowProcessIdentity.readToken(for:42,readInfo:infoReader(returning:fullSize))==token,"完整公开proc_bsdinfo映射整数token")
    for size:Int32 in [0,-1,fullSize-1,fullSize+1] {
        try check(WindowProcessIdentity.readToken(for:42,readInfo:infoReader(returning:size))==nil,"失败、短读或异常长读不能产生token")
    }
    try check(WindowProcessIdentity.readToken(for:42,readInfo:infoReader(returning:fullSize,pid:43))==nil,"proc_bsdinfo内PID必须匹配请求")
    try check(WindowProcessIdentity.readToken(for:42,readInfo:infoReader(returning:fullSize,seconds:0))==nil,"零启动时间不是可验证身份")
    try check(WindowProcessIdentity.readToken(for:42,readInfo:infoReader(returning:fullSize,microseconds:1_000_000))==nil,"微秒字段必须小于一百万")
    var negativeRead=false
    try check(WindowProcessIdentity.readToken(for:-1,readInfo:{_,_ in negativeRead=true;return fullSize})==nil && !negativeRead,"负PID不向系统读取")
    // Source capture and AX validation each use readers before and after IPC; model intervening changes explicitly.
    for after:WindowProcessIdentity.Token? in [reused,nil] {
        var sequence:[WindowProcessIdentity.Token?]=[token,after]
        let reader:WindowProcessIdentity.TokenReader={_ in sequence.removeFirst()}
        let before=WindowProcessIdentity.capture(pid:42,launchDate:nil,readToken:reader)
        try check(!WindowProcessIdentity.matches(captured:before,currentPID:42,currentLaunchDate:nil,readToken:reader),"AX读取期间重启或token不可读停止")
    }
    try check(!WindowProcessIdentity.definitelyDifferent(captured:nilDate!,currentToken:nil),"暂时读取失败不能删恢复记录")
    try check(!WindowProcessIdentity.definitelyDifferent(captured:nilDate!,currentToken:token),"相同token不清恢复记录")
    try check(WindowProcessIdentity.definitelyDifferent(captured:nilDate!,currentToken:reused),"已证实PID复用可判旧恢复身份失效")
    try check(!WindowProcessIdentity.definitelyDifferent(captured:nilDate!,currentToken:.init(pid:42,startSeconds:0,startMicroseconds:0)),"无效token不当作旧记录失效证据")
    // Existing non-window consumers keep their strict date-only behavior.
    try check(WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:date,currentPID:42,currentLaunchDate:date),"原日期接口已知身份不变")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:date,currentPID:42,currentLaunchDate:later),"原日期接口拒绝重启")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:nil,currentPID:42,currentLaunchDate:nil),"原日期接口不引入nil等价旁路")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:date,currentPID:42,currentLaunchDate:nil),"原日期接口单边未知停止")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:nil,currentPID:42,currentLaunchDate:date),"原日期接口捕获未知停止")
    try check(!WindowProcessIdentity.matches(capturedPID:42,capturedLaunchDate:date,currentPID:43,currentLaunchDate:date),"原日期接口PID保护不变")
    try check(!WindowProcessIdentity.matches(capturedPID:0,capturedLaunchDate:date,currentPID:0,currentLaunchDate:date),"原日期接口PID0保护不变")
    // Read only this isolated test process, never frontmost apps, AX windows or the user's GUI state.
    let ownPID=getpid(),ownBefore=WindowProcessIdentity.readToken(for:getpid()),ownAfter=WindowProcessIdentity.readToken(for:getpid())
    try check(ownBefore != nil && ownBefore==ownAfter && ownBefore?.pid==ownPID,"公开proc_pidinfo真实读取测试自身进程稳定身份")
    print("PASS: \(count)项窗口进程身份测试（合法nil日期+真实kernel token、PID复用、读失败/短读、恢复保留与旧接口）；未读取或操作真实GUI")
}
