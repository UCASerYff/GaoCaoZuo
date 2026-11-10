#if SCREENSHOT_ENGINE_TESTS
import Foundation
import Darwin

@main struct ScreenshotEngineTestMain {
    @MainActor static func main() async {
        let root = URL(fileURLWithPath: "/private/tmp", isDirectory: true)
            .appendingPathComponent("GaoCaoZuo-ScreenshotEngine-\(UUID().uuidString).noindex", isDirectory: true)
        do {
            _ = try ScreenshotGaoPrivateIO.directory(root, create: true, requirePrivate: true)
            defer { try? FileManager.default.removeItem(at: root) }
            try runHostedInputGenerationTests()
            try ScreenshotGaoActionOwnershipTests.run(in: root.appendingPathComponent("Ownership"))
            try ScreenshotRunCaptureTests()
            try ScreenshotScrollInputPolicyTests.main()
            ScreenshotScrollPixelEventBundleTests.main()
            ScreenshotLongCaptureWindowCropTests.main()
            ScreenshotLongCaptureBackingBudgetTests.main()
            await ScreenshotLongCaptureCancellationTestMain.main()
            await ScreenshotScrollTargetGuardTestsMain.main()
            try ScreenshotRunRecordingAlgorithmTests()
            try await ScreenshotRunRecordingHostGateTests(in: root)
            try await ScreenshotRunRecordingFinalizationRetentionTests()
            try await ScreenshotRunRecordingSessionIsolationTests()
            try await ScreenshotRunTranslationRegressionTests()
            if CommandLine.arguments.contains("--synthetic-media") {
                try await ScreenshotRunOCRTests()
                try await ScreenshotRunOCRExportBudgetTests(in: root.appendingPathComponent("OCRBudget"))
                try await ScreenshotRunActionRegressionTests(in: root.appendingPathComponent("Actions"))
                try await ScreenshotRunRecordingTests()
                try await ScreenshotRunRecordingAudioRecoveryTests()
            }
            print("SCREENSHOT ENGINE ISOLATED TESTS PASSED; no GUI, screen/audio capture, device input or language download")
        } catch {
            fputs("Screenshot engine FAIL: \(error.localizedDescription)\n", stderr)
            exit(1)
        }
    }
}
#endif
