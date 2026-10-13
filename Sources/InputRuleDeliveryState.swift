import Foundation

struct InputRuleDeliveryState {
    private var delivered:[UUID:TimeInterval]=[:]
    mutating func accept(id:UUID,interval:TimeInterval,now:TimeInterval)->Bool {
        guard now.isFinite,interval.isFinite,(0...60).contains(interval) else{return false}
        if let previous=delivered[id],now<previous || now-previous<interval {return false}
        delivered[id]=now;return true
    }
}
