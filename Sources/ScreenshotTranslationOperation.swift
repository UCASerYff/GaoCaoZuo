import Foundation

/// Input text alone is not an operation identity: two approved requests may contain the same text.
struct ScreenshotTranslationOperationIdentity: Equatable, Sendable {
    let operationID: UUID
    let requestID: String?

    func matches(operationID: UUID, requestID: String?) -> Bool {
        self.operationID == operationID && self.requestID == requestID
    }
}

struct ScreenshotTranslationAttempt: Sendable {
    let id = UUID()
    let identity: ScreenshotTranslationOperationIdentity
    let text: String
    let sourceLanguage: String
    let targetLanguage: String
    let packageDownloadRequested: Bool
}

enum ScreenshotTranslationExecutionPhase: String, Sendable {
    case preparing, translating
}

struct ScreenshotTranslationExecutionFailure: LocalizedError {
    let phase: ScreenshotTranslationExecutionPhase
    let underlying: Error

    var errorDescription: String? {
        let stage = phase == .preparing ? "准备本机翻译失败" : "翻译失败"
        let error = underlying as NSError
        return "\(stage)：\(underlying.localizedDescription)（\(error.domain) / \(error.code)）。自动模式无法识别时，请明确选择原文语言。"
    }
}

/// A source-less preparation has no text with which to identify the language.
/// Automatic sessions receive text through translate; the framework owns detection and any language-choice UI.
enum ScreenshotTranslationExecution {
    @MainActor
    static func run<Value>(attempt: ScreenshotTranslationAttempt,
                           isCurrent: () -> Bool,
                           prepare: () async throws -> Void,
                           translate: (String) async throws -> Value) async throws -> Value {
        var phase = ScreenshotTranslationExecutionPhase.translating
        do {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            if attempt.sourceLanguage != "auto" {
                phase = .preparing
                try await prepare()
                try Task.checkCancellation()
                guard isCurrent() else { throw CancellationError() }
            }
            phase = .translating
            let value = try await translate(attempt.text)
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            return value
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            try Task.checkCancellation()
            guard isCurrent() else { throw CancellationError() }
            throw ScreenshotTranslationExecutionFailure(phase: phase, underlying: error)
        }
    }
}
