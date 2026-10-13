import Foundation
import AppKit
import Darwin

@main enum OperationTestMain {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if let index=CommandLine.arguments.firstIndex(of:"--provider-interop") {
            guard CommandLine.arguments.count>index+1 else {throw DataFailure.message("Provider interop requires a package-pair directory.")}
            try runProviderPackageInteropTests(directory:URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true))
            return
        }
        if CommandLine.arguments.contains("--migration-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try runMigrationTests()
            try runRightMouseMigrationTests()
            try runReplacementMigrationV2Tests()
            try runBABMigrationTests()
            let arguments=CommandLine.arguments
            if let m=arguments.firstIndex(of:"--private-migration"),let s=arguments.firstIndex(of:"--private-snapshot"),arguments.count>m+1,arguments.count>s+1 {
                try runPrivateReplacementPreflight(snapshot:URL(fileURLWithPath:arguments[s+1]),payload:URL(fileURLWithPath:arguments[m+1]))
            }
            return
        }
        try runLocalizationTests()
        // Existing behavioral fixtures use Chinese diagnostics; resource tests above
        // exercise explicit language changes independently of the host's language.
        GaoLocale.shared.setLanguage(.zhHans)
        try runMigrationTests()
        try runRightMouseMigrationTests()
        try runReplacementMigrationV2Tests()
        try await runGaoActionTests()
        try runEnhancementIntegrationTests()
        try runExtensionIntegrationTests()
        try runInputEnhancementTests()
        try runBABMigrationTests()
        try runSystemTests()
        try runWindowDragTests()
        try await runNativeWindowSnapTests()
        try runWindowFocusTests()
        try await runWindowFocusTransactionTests()
        try await runWindowLayoutTransactionTests()
        try runFinderCommandTests()
        print("系统几何与输入规则测试通过")
        try runDataTests()
        print("资料完整性与剪贴板附件测试通过")
        try await runArchiveEnhancementTests()
        try await runFileEnhancementTests()
        try await runFileToolsTests()
        try await runQuickFileActionsTests()
        try await runQuickQueueTests()
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
        let arguments=CommandLine.arguments
        if let m=arguments.firstIndex(of:"--private-migration"),let s=arguments.firstIndex(of:"--private-snapshot"),arguments.count>m+1,arguments.count>s+1 {
            try runPrivateReplacementPreflight(snapshot:URL(fileURLWithPath:arguments[s+1]),payload:URL(fileURLWithPath:arguments[m+1]))
        }
    }
}
