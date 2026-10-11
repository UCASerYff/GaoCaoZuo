import Foundation

@MainActor private final class QuickQueueTestGate {
    var isOpen = false
    func wait() async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !isOpen {
            guard ContinuousClock.now < deadline else { throw DataFailure.message("快捷队列测试门限等待超时") }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
}

/// Isolated file/queue tests. History stays off; no clipboard, permission request,
/// window action, engine, application launch or real user-data operation is used.
@MainActor func runQuickQueueTests() async throws {
    let fm = FileManager.default
    let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
        .appendingPathComponent("GaoCaoZuo-QuickQueueTests-" + UUID().uuidString, isDirectory: true)
    try fm.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? fm.removeItem(at: root) }

    func check(_ condition: @autoclosure () throws -> Bool, _ reason: String) throws {
        guard try condition() else { throw DataFailure.message("快捷队列测试失败：" + reason) }
    }
    func waitFor(_ label: String, until condition: @escaping @MainActor () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(5))
        while !condition() {
            guard ContinuousClock.now < deadline else { throw DataFailure.message("快捷队列测试超时：" + label) }
            try await Task.sleep(for: .milliseconds(10))
        }
    }
    func idle(_ store: OperationStore) async throws {
        try await waitFor("任务与等待队列完成") {
            !store.busy && !store.quickJobActive && store.queuedCount == 0 && store.quickJobs.isEmpty
        }
    }
    func fixture(_ name: String) throws -> (OperationStore, URL) {
        let directory = root.appendingPathComponent(name, isDirectory: true)
        let outputs = directory.appendingPathComponent("Files", isDirectory: true)
        try fm.createDirectory(at: outputs, withIntermediateDirectories: true)
        let store = OperationStore(directory: directory.appendingPathComponent("Data", isDirectory: true))
        try check(store.dataHealthy && !store.settings.clipboardEnabled && !store.clipboard.enabled,
                  "测试资料须独立且剪贴板历史保持关闭")
        return (store, outputs)
    }
    func children(_ directory: URL) throws -> [URL] {
        try fm.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil).sorted { $0.path < $1.path }
    }

    // Two rapid clicks must create two durable results, never overwrite each other
    // or a preexisting same-name file, and both must have persisted recovery records.
    do {
        let (store, output) = try fixture("rapid-create")
        let original = output.appendingPathComponent("未命名.txt")
        let originalBytes = Data("原文件必须保留".utf8)
        try originalBytes.write(to: original, options: .withoutOverwriting)
        store.prepare("new.text", files: [output])
        store.prepare("new.text", files: [output])
        try check(store.quickJobActive && store.queuedCount == 1, "连续点击须先执行一项并排队另一项")
        try await idle(store)
        let results = try children(output)
        try check(results.count == 3, "原文件之外应产生两个新文件")
        try check(try Data(contentsOf: original) == originalBytes, "同名原文件的内容不可改变")
        let destinations = store.receipts.map(\.destination)
        try check(destinations.count == 2 && Set(destinations).count == 2, "两个结果各有独立恢复记录")
        try check(!destinations.contains(original) && destinations.allSatisfy { $0.deletingLastPathComponent() == output }, "新文件只写入指定测试目录")
        for url in destinations { try check(try Data(contentsOf: url).isEmpty, "快速新建文本初始内容正确") }
        let persisted = try JSONDecoder().decode(ReceiptDocument.self, from: Data(contentsOf: store.data.directory.appendingPathComponent("receipts.json")))
        try check(Set(persisted.records.map(\.id)) == Set(store.receipts.map(\.id)), "两次操作的恢复记录须实际落盘")
        try check(store.sheet == nil, "快速新建不应打开自定义表单")
    }

    // A queued action must not start behind an active job. If that job discovers a
    // protected-data failure, later jobs must stop before creating any output.
    do {
        let (store, output) = try fixture("blocked-data")
        let gate = QuickQueueTestGate()
        var firstStarted = false
        defer { store.cancelWaitingJobs(); gate.isOpen = true }
        let settingsURL = store.data.directory.appendingPathComponent("settings.json")
        let receiptURL = store.data.directory.appendingPathComponent("receipts.json")
        let savedSettings = try Data(contentsOf: settingsURL), savedReceipts = try Data(contentsOf: receiptURL)
        store.enqueueQuick("检测资料") {
            firstStarted = true
            try await gate.wait()
            store.data.block("测试：资料核验失败")
            throw DataFailure.message("测试：停止当前任务")
        }
        store.prepare("new.text", files: [output])
        try await waitFor("首项进入等待门限") { firstStarted }
        try await Task.sleep(for: .milliseconds(60))
        try check(store.queuedCount == 1 && store.quickJobActive, "后续任务应等待当前任务")
        try check(try children(output).isEmpty, "前项未完成时不能执行后续新建")
        gate.isOpen = true
        try await idle(store)
        try check(!store.dataHealthy, "前项发现的资料错误应保留")
        try check(try children(output).isEmpty, "资料锁写后后续任务不得执行")
        try check(store.receipts.isEmpty, "未执行任务不得伪造恢复记录")
        try check(try Data(contentsOf: settingsURL) == savedSettings && Data(contentsOf: receiptURL) == savedReceipts,
                  "资料失败后原设置和恢复记录不被覆盖")
    }

    // Workflow ownership of the execution slot must hold a real queued file action
    // until the workflow ends and the queue is explicitly drained.
    do {
        let (store, output) = try fixture("workflow-serialization")
        store.workflowRunning = true
        defer { store.workflowRunning = false; store.cancelWaitingJobs() }
        store.prepare("new.text", files: [output])
        try await Task.sleep(for: .milliseconds(60))
        try check(store.queuedCount == 1 && !store.quickJobActive && !store.busy, "组合操作运行中只排队，不占用文件执行位")
        try check(try children(output).isEmpty, "组合操作期间不得启动排队的新建任务")
        store.workflowRunning = false
        store.drainQuickJobs()
        try await idle(store)
        try check(try children(output).count == 1 && store.receipts.count == 1, "组合操作结束后排队任务应执行并保存恢复记录")
    }

    // Clearing waiting jobs must retain already completed output/receipts and must
    // leave the active job running, rather than treating queue cancellation as undo.
    do {
        let (store, output) = try fixture("cancel-waiting")
        store.prepare("new.text", files: [output])
        try await idle(store)
        guard let completed = store.receipts.first else { throw DataFailure.message("取消排队测试缺少已完成结果") }
        let completedFingerprint = try FileTools.fingerprint(completed.destination)
        let receiptURL = store.data.directory.appendingPathComponent("receipts.json")
        let savedReceipts = try Data(contentsOf: receiptURL)
        let gate = QuickQueueTestGate()
        var activeStarted = false, activeFinished = false
        defer { store.cancelWaitingJobs(); gate.isOpen = true }
        store.enqueueQuick("当前执行任务") {
            activeStarted = true
            try await gate.wait()
            activeFinished = true
            return []
        }
        store.prepare("new.text", files: [output])
        try await waitFor("当前任务进入等待门限") { activeStarted }
        try check(store.queuedCount == 1, "取消前须有一个真正的等待任务")
        store.cancelWaitingJobs()
        try check(store.queuedCount == 0 && store.quickJobs.isEmpty, "清除等待任务应立即清空队列")
        try check(store.quickJobActive && store.busy && !activeFinished && !store.quickCancellationRequested,
                  "清空等待队列不应取消当前任务")
        gate.isOpen = true
        try await idle(store)
        try check(activeFinished, "当前任务继续正常结束")
        try check(try children(output).count == 1 && FileTools.fingerprint(completed.destination) == completedFingerprint,
                  "已完成文件保留且取消的等待任务不产生新文件")
        try check(try Data(contentsOf: receiptURL) == savedReceipts && store.receipts.map(\.id) == [completed.id],
                  "取消排队不移除或重写已完成操作的恢复记录")
    }
    print("快捷队列测试通过：连续创建避重名与恢复记录、资料失败停止后续、组合操作串行、取消等待保留已完成结果")
}
