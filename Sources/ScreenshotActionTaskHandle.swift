import Foundation

/// Cancelling the task is cooperative; the final gate also rejects a provider's late result.
@MainActor
final class ScreenshotActionTaskHandle<Value> {
    let requestID: String
    private let task: Task<Value, Error>
    private(set) var isCancelled = false

    init(requestID: String, operation: @escaping @MainActor () async throws -> Value) {
        self.requestID = requestID
        task = Task { try Task.checkCancellation(); return try await operation() }
    }

    func cancel() { isCancelled = true; task.cancel() }

    func value() async throws -> Value {
        do {
            let output = try await task.value
            guard !isCancelled else { throw CancellationError() }
            try Task.checkCancellation()
            return output
        } catch {
            if isCancelled || Task.isCancelled { throw CancellationError() }
            throw error
        }
    }
}
