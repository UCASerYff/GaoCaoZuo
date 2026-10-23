import Foundation
import AppKit
import Darwin

@main enum OperationTestMain {
    @MainActor static func main() async throws {
        setbuf(stdout,nil)
        if CommandLine.arguments.contains("--device-service-refresh-only") {
            try runHIDEventServiceRefreshTests()
            return
        }
        if CommandLine.arguments.contains("--cleaner-safety-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try runCleanerSafetyTests()
            try await runCleanerWatchdogStartupTests()
            return
        }
        if CommandLine.arguments.contains("--archive-original-commit-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            guard let index=CommandLine.arguments.firstIndex(of:"--engine"),CommandLine.arguments.count>index+1 else {exit(1)}
            do {try await runArchiveOriginalCommitTests(engine:URL(fileURLWithPath:CommandLine.arguments[index+1]))}
            catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
            return
        }
        if CommandLine.arguments.contains("--cloud-transport-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            do {
                try runInputCloudLocalConsentTests()
                guard let index=CommandLine.arguments.firstIndex(of:"--cloud-test-parent"),CommandLine.arguments.count>index+1 else {throw DataFailure.message("Explicit dedicated cloud test parent required")}
                try await runInputCloudTransportTests(cloudParent:URL(fileURLWithPath:CommandLine.arguments[index+1],isDirectory:true))
            }catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
            return
        }
        if CommandLine.arguments.contains("--cloud-rules-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try runInputCloudMergeTests()
            return
        }
        if CommandLine.arguments.contains("--volume-evidence-only") {
            guard let index=CommandLine.arguments.firstIndex(of:"--engine"),index+1<CommandLine.arguments.count else {throw DataFailure.message("Missing test engine")}
            GaoLocale.shared.setLanguage(.zhHans)
            try await runArchiveVolumeEvidenceTests(engine:URL(fileURLWithPath:CommandLine.arguments[index+1]))
            return
        }
        if CommandLine.arguments.contains("--rich-stack-only") || CommandLine.arguments.contains("--rich-and-cloud-only") || CommandLine.arguments.contains("--rich-cloud-ownership-only") {
            // RTFD serialization creates AppKit text attachments and requires a
            // registered AppKit process. No window or event loop is created.
            NSApplication.shared.setActivationPolicy(.prohibited)
            GaoLocale.shared.setLanguage(.zhHans)
            do {
                try runPasteStackMergeTests()
                try runClipboardExplicitCopyTests()
                if CommandLine.arguments.contains("--rich-and-cloud-only") || CommandLine.arguments.contains("--rich-cloud-ownership-only") {try runInputCloudMergeTests()}
                if CommandLine.arguments.contains("--rich-cloud-ownership-only") {try runHIDEventOwnershipTests()}
            }catch {
                FileHandle.standardError.write(Data(("富堆栈/复制恢复专项失败："+error.localizedDescription+"\n").utf8))
                exit(1)
            }
            return
        }
        if CommandLine.arguments.contains("--device-ownership-only") {
            NSApplication.shared.setActivationPolicy(.prohibited)
            do {try runHIDEventOwnershipTests()}
            catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
            return
        }
        if CommandLine.arguments.contains("--archive-execution-scope-only") {
            guard let index=CommandLine.arguments.firstIndex(of:"--engine"),CommandLine.arguments.count>index+1 else {throw DataFailure.message("Missing scope engine")}
            do {try await runArchiveExecutionScopeTests(engine:URL(fileURLWithPath:CommandLine.arguments[index+1]))}
            catch {FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)}
            return
        }
        let releaseTargeted=CommandLine.arguments.contains("--release-targeted")
        if CommandLine.arguments.contains("--capabilities-and-paste-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try await runGaoActionTests()
            try runClipboardSafetyTests()
            try runClipboardPasteTransactionTests()
            return
        }
        if CommandLine.arguments.contains("--file-adapter-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try runFileAppAdapterTests()
            return
        }
        if CommandLine.arguments.contains("--finder-adapters-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try runFinderCommandTests(renderMenus:false)
            try runFileAppAdapterTests()
            return
        }
        if CommandLine.arguments.contains("--input-targeted-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try runInputAutomationTests()
            try runInputDeviceMenuTests()
            try runInputEnhancementTests()
            try runInputLifecycleTests()
            try runBABMigrationTests()
            try runCleanerSafetyTests()
            if let source=CommandLine.arguments.firstIndex(of:"--input-private-snapshot"),let report=CommandLine.arguments.firstIndex(of:"--input-private-report"),
               CommandLine.arguments.count>source+1,CommandLine.arguments.count>report+1 {
                try runPrivateInputMigrationAudit(snapshot:URL(fileURLWithPath:CommandLine.arguments[source+1]),report:URL(fileURLWithPath:CommandLine.arguments[report+1]))
            }
            return
        }
        if CommandLine.arguments.contains("--client-window-clipboard-only") {
            GaoLocale.shared.setLanguage(.zhHans)
            try await runGaoActionTests()
            try runWindowTargetModeTests()
            try runWindowProcessIdentityTests()
            try runWindowFocusTests()
            try await runWindowFocusTransactionTests()
            try await runWindowLayoutTransactionTests()
            try runClipboardSafetyTests()
            try runClipboardPasteTransactionTests()
            return
        }
        if let i=CommandLine.arguments.firstIndex(of:"--upgrade-copy-check"),CommandLine.arguments.count > i+1 {
            try runUpgradeCopyCheck(directory:URL(fileURLWithPath:CommandLine.arguments[i+1],isDirectory:true))
            return
        }
        if CommandLine.arguments.contains("--extensions-only") || releaseTargeted {
            GaoLocale.shared.setLanguage(.zhHans)
            try runInputAutomationTests()
            try runInputMenuEvidenceTests()
            try runWindowTargetModeTests()
            try runSelectionSnippetTests()
            try await runSnippetNativeBackupTests()
            try runSnippetNamedAttachmentExportTests()
            try runSnippetFileReferenceTests()
            try runPasteStackMergeTests()
            try runCleanerSafetyTests()
            try runExtensionLifecycleTests()
            try runClipboardSafetyTests()
            try runClipboardPasteTransactionTests()
            try runProductionActionCatalogTests()
            if !releaseTargeted {return}
        }
        if CommandLine.arguments.contains("--archive-stream-only") {try runArchiveBatchStreamTests();return}
        if CommandLine.arguments.contains("--archive-safety-only") || releaseTargeted {
            try runArchiveBatchStreamTests()
            guard let i=CommandLine.arguments.firstIndex(of:"--engine"),CommandLine.arguments.count > i+1 else {throw DataFailure.message("缺少指定压缩引擎")}
            try await runArchiveBatchIntegrationTests(engine:URL(fileURLWithPath:CommandLine.arguments[i+1]))
            try await runArchiveStageCleanupTests()
            if !releaseTargeted {return}
        }
        if releaseTargeted {
            guard let i=CommandLine.arguments.firstIndex(of:"--release-data-copy"),CommandLine.arguments.count > i+1 else {throw DataFailure.message("最终定向检查需要独立升级资料副本")}
            try runUpgradeCopyCheck(directory:URL(fileURLWithPath:CommandLine.arguments[i+1],isDirectory:true))
            return
        }
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
