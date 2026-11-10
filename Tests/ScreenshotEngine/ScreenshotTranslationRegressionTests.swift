// Imported synthetic regression from GaoJieTu 1.08/build9; namespaced for the host.
import Foundation

private enum TranslationRegressionError: Error { case failed(String), unavailable }
private func translationRequire(_ value: @autoclosure () -> Bool, _ message: String) throws {
    if !value() { throw TranslationRegressionError.failed(message) }
}

/// Exercises the production execution path with controlled framework boundaries; no GUI, download or translation service.
@MainActor
func ScreenshotRunTranslationRegressionTests() async throws {
    let text = "Hello world. This is a public synthetic test."
    let identity = ScreenshotTranslationOperationIdentity(operationID: UUID(), requestID: UUID().uuidString)
    let automatic = ScreenshotTranslationAttempt(identity: identity, text: text, sourceLanguage: "auto", targetLanguage: "zh", packageDownloadRequested: false)
    var prepared = false
    let actual = try await ScreenshotTranslationExecution.run(attempt: automatic, isCurrent: { true }, prepare: {
        prepared = true
        // This is the observed system failure when preparation has no source language or source text.
        throw NSError(domain: "TranslationErrorDomain", code: 21)
    }, translate: { received in
        try translationRequire(received == text, "automatic translation must receive the exact original text")
        return "system-detected-language"
    })
    try translationRequire(!prepared && actual == "system-detected-language", "automatic mode must not preflight a source-less session")

    let explicit = ScreenshotTranslationAttempt(identity: identity, text: text, sourceLanguage: "en", targetLanguage: "zh", packageDownloadRequested: true)
    var order = [String]()
    _ = try await ScreenshotTranslationExecution.run(attempt: explicit, isCurrent: { true }, prepare: { order.append("prepare") }, translate: { _ in order.append("translate"); return "ok" })
    try translationRequire(order == ["prepare", "translate"], "explicit pair must retain normal language-package preparation")
    var translatedAfterFailedPreparation = false
    do {
        _ = try await ScreenshotTranslationExecution.run(attempt: explicit, isCurrent: { true }, prepare: { throw TranslationRegressionError.unavailable }, translate: { _ in translatedAfterFailedPreparation = true; return "bad" })
        throw TranslationRegressionError.failed("failed preparation returned success")
    } catch let failure as ScreenshotTranslationExecutionFailure {
        try translationRequire(failure.phase == .preparing && !translatedAfterFailedPreparation, "preparation failures must retain their phase and stop translation")
    }
    do {
        _ = try await ScreenshotTranslationExecution.run(attempt: automatic, isCurrent: { true }, prepare: {}, translate: { _ -> String in throw TranslationRegressionError.unavailable })
        throw TranslationRegressionError.failed("translation failure returned success")
    } catch let failure as ScreenshotTranslationExecutionFailure {
        try translationRequire(failure.phase == .translating, "unrecognized/unsupported translation must stay an honest translation failure")
    }

    var activeAttempt = explicit.id
    var prepareContinuation: CheckedContinuation<Void, Never>?
    var staleTranslated = false
    let preparing = Task { @MainActor in
        try await ScreenshotTranslationExecution.run(attempt: explicit, isCurrent: { activeAttempt == explicit.id }, prepare: {
            await withCheckedContinuation { prepareContinuation = $0 }
        }, translate: { _ in staleTranslated = true; return "bad" })
    }
    while prepareContinuation == nil { await Task.yield() }
    activeAttempt = UUID(); prepareContinuation?.resume()
    do { _ = try await preparing.value; throw TranslationRegressionError.failed("stale preparation continued") }
    catch is CancellationError { }
    try translationRequire(!staleTranslated, "expired input must be rejected before the translate call")

    let newIdentity = ScreenshotTranslationOperationIdentity(operationID: UUID(), requestID: UUID().uuidString)
    let repeated = ScreenshotTranslationAttempt(identity: newIdentity, text: text, sourceLanguage: "auto", targetLanguage: "zh", packageDownloadRequested: false)
    var activeIdentity = identity
    var continuation: CheckedContinuation<String, Never>?
    let late = Task { @MainActor in
        try await ScreenshotTranslationExecution.run(attempt: automatic, isCurrent: { activeIdentity == automatic.identity }, prepare: {}, translate: { _ in
            await withCheckedContinuation { continuation = $0 }
        })
    }
    while continuation == nil { await Task.yield() }
    activeIdentity = repeated.identity; continuation?.resume(returning: "old result")
    do { _ = try await late.value; throw TranslationRegressionError.failed("same text rebound an old result to a new request") }
    catch is CancellationError { }

    var cancelledContinuation: CheckedContinuation<String, Never>?
    let cancelled = Task { @MainActor in
        try await ScreenshotTranslationExecution.run(attempt: automatic, isCurrent: { true }, prepare: {}, translate: { _ in
            await withCheckedContinuation { cancelledContinuation = $0 }
        })
    }
    while cancelledContinuation == nil { await Task.yield() }
    cancelled.cancel(); cancelledContinuation?.resume(returning: "late result")
    do { _ = try await cancelled.value; throw TranslationRegressionError.failed("cancelled task returned a late result") }
    catch is CancellationError { }
    var errorContinuation: CheckedContinuation<String, Error>?
    let cancelledError = Task { @MainActor in
        try await ScreenshotTranslationExecution.run(attempt: automatic, isCurrent: { true }, prepare: {}, translate: { _ in
            try await withCheckedThrowingContinuation { errorContinuation = $0 }
        })
    }
    while errorContinuation == nil { await Task.yield() }
    cancelledError.cancel(); errorContinuation?.resume(throwing: TranslationRegressionError.unavailable)
    do { _ = try await cancelledError.value; throw TranslationRegressionError.failed("late framework error overwrote cancellation") }
    catch is CancellationError { }
    print("Translation regressions PASS: automatic text-first detection; explicit preparation; phase-specific errors; stale input/request isolation; late completion cancellation. No GUI or language download.")
}
