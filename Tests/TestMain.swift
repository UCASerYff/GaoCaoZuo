import Foundation
import AppKit

@main enum OperationTestMain {
    @MainActor static func main() async throws {
        try runSystemTests()
        try runWindowDragTests()
        print("系统几何与输入规则测试通过")
        try runDataTests()
        print("资料完整性与剪贴板附件测试通过")
        try await runFileToolsTests()
        print("文件与压缩真实引擎测试通过")
        let temp=FileManager.default.temporaryDirectory.appendingPathComponent("GaoCaoZuo-model-"+UUID().uuidString)
        defer{try? FileManager.default.removeItem(at:temp)}
        let store=OperationStore(directory:temp)
        guard store.dataHealthy, store.version == "1.00" else{throw DataFailure.message("首次启动资料或版本错误")}
        store.update{$0.folders.append(.init(name:"临时",path:temp.path));$0.snippets.append(.init(name:"测试",text:"临时文本"))}
        let reread=OperationStore(directory:temp)
        guard reread.settings.snippets.first?.text == "临时文本",reread.settings.folders.count == 1 else{throw DataFailure.message("配置保存后重启未保留")}
        let wf=OperationWorkflow(name:"等待",steps:[WorkflowStep(actionID:"delay",argument:"0.01")])
        try await store.executeWorkflowStep(wf.steps[0])
        print("配置重启保留与组合步骤测试通过")
    }
}
