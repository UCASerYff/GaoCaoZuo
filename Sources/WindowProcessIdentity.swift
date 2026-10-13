import Foundation
import Darwin

/// A PID alone can be recycled. Missing launch identity is a failure, never an equal unknown value.
enum WindowProcessIdentity {
    static func matches(capturedPID:pid_t,capturedLaunchDate:Date?,currentPID:pid_t,currentLaunchDate:Date?)->Bool {
        guard capturedPID>0,capturedPID==currentPID,let capturedLaunchDate,let currentLaunchDate,
              capturedLaunchDate.timeIntervalSinceReferenceDate.isFinite,
              currentLaunchDate.timeIntervalSinceReferenceDate.isFinite else{return false}
        return capturedLaunchDate==currentLaunchDate
    }
}
