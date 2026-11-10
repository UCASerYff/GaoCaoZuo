/// Pending application actions have their own lifetime. Invalidating them must
/// not rebuild an event tap or change the tap's disabled-recovery generation.
struct HostedInputGeneration {
    private var value: UInt64 = 0

    init() {}

    var snapshot: UInt64 { value }

    mutating func invalidate() { value &+= 1 }

    func matches(_ snapshot: UInt64) -> Bool { value == snapshot }
}
