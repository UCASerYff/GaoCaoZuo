import Foundation
import Darwin

/// Kernel start timestamps distinguish recycled PIDs even when LaunchServices has no launchDate.
/// These checks and AX IPC are separate operations; they are not an atomic process/window lock.
enum WindowProcessIdentity {
    struct Token: Equatable {
        let pid:pid_t
        let startSeconds:UInt64
        let startMicroseconds:UInt64
        var isValid:Bool {pid>0 && startSeconds>0 && startMicroseconds<1_000_000}
    }
    struct Snapshot {
        let token:Token
        let launchDate:Date?
        func matches(_ other:Snapshot?)->Bool {
            guard let other,token.isValid,other.token.isValid,token==other.token else{return false}
            return WindowProcessIdentity.compatibleLaunchDates(launchDate,other.launchDate)
        }
    }
    typealias TokenReader=(pid_t)->Token?
    typealias BSDInfoReader=(pid_t,inout proc_bsdinfo)->Int32

    static func readToken(for pid:pid_t,readInfo:BSDInfoReader = systemBSDInfo)->Token? {
        guard pid>0 else{return nil}
        var info=proc_bsdinfo()
        guard readInfo(pid,&info)==Int32(MemoryLayout<proc_bsdinfo>.size),info.pbi_pid==UInt32(pid) else{return nil}
        let token=Token(pid:pid,startSeconds:info.pbi_start_tvsec,startMicroseconds:info.pbi_start_tvusec)
        return token.isValid ? token : nil
    }
    private static func systemBSDInfo(_ pid:pid_t,_ info:inout proc_bsdinfo)->Int32 {
        proc_pidinfo(pid,PROC_PIDTBSDINFO,0,&info,Int32(MemoryLayout<proc_bsdinfo>.size))
    }
    static func capture(pid:pid_t,launchDate:Date?,readToken:TokenReader = {Self.readToken(for:$0)})->Snapshot? {
        guard pid>0,validDate(launchDate),let token=readToken(pid),token.isValid,token.pid==pid else{return nil}
        return Snapshot(token:token,launchDate:launchDate)
    }
    static func matches(captured:Snapshot?,currentPID:pid_t,currentLaunchDate:Date?,
                        readToken:TokenReader = {Self.readToken(for:$0)})->Bool {
        guard let captured,let current=capture(pid:currentPID,launchDate:currentLaunchDate,readToken:readToken) else{return false}
        return captured.matches(current)
    }
    /// A temporary inability to read identity is not proof that recovery data is stale.
    static func definitelyDifferent(captured:Snapshot,currentToken:Token?)->Bool {
        guard let currentToken,currentToken.isValid else{return false}
        return captured.token != currentToken
    }
    static func compatibleLaunchDates(_ captured:Date?,_ current:Date?)->Bool {
        guard validDate(captured),validDate(current) else{return false}
        if let captured,let current {return captured==current}
        return true // This alone never authenticates a process: callers must also compare valid kernel tokens.
    }
    private static func validDate(_ date:Date?)->Bool {date?.timeIntervalSinceReferenceDate.isFinite ?? true}

    /// Legacy date-only consumers remain strict; unknown dates never become equal identities.
    static func matches(capturedPID:pid_t,capturedLaunchDate:Date?,currentPID:pid_t,currentLaunchDate:Date?)->Bool {
        guard capturedPID>0,capturedPID==currentPID,let capturedLaunchDate,let currentLaunchDate,
              capturedLaunchDate.timeIntervalSinceReferenceDate.isFinite,
              currentLaunchDate.timeIntervalSinceReferenceDate.isFinite else{return false}
        return capturedLaunchDate==currentLaunchDate
    }
    static func auditTokenString(for pid: pid_t) -> String? {
        guard let token = readToken(for: pid) else { return nil }
        return "\(token.pid)-\(token.startSeconds)-\(token.startMicroseconds)"
    }
}
