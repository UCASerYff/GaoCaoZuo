import Foundation

struct PendingPaste: Identifiable {
    let id: UUID
    let sendEnterRequested: Bool
    let message: String
    let eventWasSubmitted: Bool
}

/// Pure in-memory lease. Event submission never transitions to confirmed by
/// a timer, focus change, pasteboard read or optimistic target assumption.
struct ClipboardPasteTransaction {
    enum Phase { case preparing, waitingForTarget, failedBeforeSubmission, awaitingUser, confirmed }
    let id: UUID
    let original: ClipboardPasteboardSnapshot
    let sendEnterRequested: Bool
    private(set) var phase: Phase = .preparing
    private(set) var temporaryChangeCount: Int?
    private(set) var enterWasSubmitted = false
    private(set) var completionWasAttempted = false
    private(set) var completionSucceeded = false

    init(id: UUID = UUID(), original: ClipboardPasteboardSnapshot, sendEnterRequested: Bool) {
        self.id = id; self.original = original; self.sendEnterRequested = sendEnterRequested
    }
    static func requireIdle(_ active: Self?) throws {
        guard active == nil else { throw DataFailure.message("还有一项粘贴等待核对。请先确认已插入或取消，不能连续覆盖原剪贴板。") }
    }
    static func requireUnblocked(_ reason:String?) throws {
        if let reason {throw DataFailure.message(reason.isEmpty ? "当前输入模式暂不允许自动粘贴。" : reason)}
    }
    func permitsTemporaryInstallation(changeCount: Int, targetMatches: Bool) -> Bool {
        phase == .preparing && temporaryChangeCount == nil
            && original.changeCount == changeCount && targetMatches
    }
    mutating func installedTemporary(changeCount: Int) throws {
        guard phase == .preparing, changeCount != original.changeCount else { throw DataFailure.message("临时剪贴板状态无效，未发送粘贴。") }
        temporaryChangeCount = changeCount; phase = .waitingForTarget
    }
    mutating func replaceTemporaryOwnership(changeCount: Int) {
        temporaryChangeCount = changeCount
    }
    mutating func failedBeforeSubmission() {
        if phase == .preparing || phase == .waitingForTarget { phase = .failedBeforeSubmission }
    }
    var eventWasSubmitted: Bool { phase == .awaitingUser || phase == .confirmed }
    func permitsDispatch(changeCount: Int, targetMatches: Bool) -> Bool {
        phase == .waitingForTarget && temporaryChangeCount == changeCount && targetMatches
    }
    mutating func submitted(changeCount: Int, targetMatches: Bool) throws {
        guard permitsDispatch(changeCount: changeCount, targetMatches: targetMatches) else { throw DataFailure.message("粘贴前目标或剪贴板已变化，未发送。") }
        phase = .awaitingUser
    }
    func requiresUserReview() throws {
        guard phase == .awaitingUser || phase == .confirmed else { throw DataFailure.message("粘贴事件尚未发送，请等待目标确认或取消。") }
    }
    mutating func recordEnterSubmission() throws {
        try requiresUserReview()
        guard sendEnterRequested, !enterWasSubmitted else { throw DataFailure.message("这项请求没有待发送回车，或回车事件已发送。") }
        enterWasSubmitted = true
    }
    mutating func beginCompletion() throws {
        try requiresUserReview()
        guard !completionWasAttempted else { throw DataFailure.message("插入确认记录已经处理过，不会自动重试或重复弹出堆栈。") }
        completionWasAttempted = true; phase = .confirmed
    }
    mutating func completed() throws {
        guard phase == .confirmed,completionWasAttempted,!completionSucceeded else {
            throw DataFailure.message("插入确认记录状态无效，未重复提交。")
        }
        completionSucceeded = true
    }
    var mayRestoreOriginal: Bool { temporaryChangeCount != nil }
    func ownsTemporary(changeCount: Int) -> Bool { temporaryChangeCount == changeCount }
}

enum ClipboardPasteTargetPolicy {
    static func documentsMatch(_ captured: String?, _ current: String?) -> Bool { captured == current }
    static func permitsEnter(capturedRole: String?, currentRole: String?, capturedEditable: Bool, currentEditable: Bool) -> Bool {
        let roles = ["AXTextField", "AXTextArea", "AXComboBox"]
        guard let capturedRole, roles.contains(capturedRole), capturedRole == currentRole else { return false }
        return capturedEditable && currentEditable
    }
}
