import Foundation
import CoreGraphics

struct WindowLayoutOutcome: Equatable {
    let requested: CGRect
    let actual: CGRect
    var isExact: Bool { WindowLayoutTransaction.matches(actual, requested) }
}

struct WindowOperationOutcome {
    let message: String
    let isExact: Bool
}

struct WindowLayoutFailure: LocalizedError {
    let reason: String
    let rollbackVerified: Bool
    var errorDescription: String? {
        reason + (rollbackVerified
            ? " 已确认恢复操作前的位置；原位置记录保留。"
            : " 未能确认恢复操作前的位置；原位置记录已保留，请用“恢复原位置”重试。")
    }
}

/// One captured window per transaction. The backend is injectable; tests never move real windows.
@MainActor
final class WindowLayoutTransaction {
    private(set) var isBusy = false
    private let pause: () async -> Void
    private let pollCount: Int

    init(pollCount: Int = 10, pause: @escaping () async -> Void = {
        // This delay also works while the caller is cancelled, so rollback can be verified.
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { continuation.resume() }
        }
    }) {
        self.pollCount = max(3, pollCount)
        self.pause = pause
    }

    nonisolated static func matches(_ lhs: CGRect, _ rhs: CGRect, tolerance: CGFloat = 4) -> Bool {
        abs(lhs.minX - rhs.minX) <= tolerance && abs(lhs.minY - rhs.minY) <= tolerance
            && abs(lhs.width - rhs.width) <= tolerance && abs(lhs.height - rhs.height) <= tolerance
    }

    nonisolated static func isValid(_ frame: CGRect) -> Bool {
        [frame.origin.x, frame.origin.y, frame.size.width, frame.size.height].allSatisfy(\.isFinite)
            && frame.size.width > 0 && frame.size.height > 0
    }

    /// Align the accepted size to the requested region; do not change app preferences to reduce its minimum size.
    nonisolated static func fittedFrame(size: CGSize, requested: CGRect, workArea: CGRect?) -> CGRect {
        func anchor(_ start: CGFloat, _ end: CGFloat, areaStart: CGFloat?, areaEnd: CGFloat?) -> CGFloat {
            if let areaStart, let areaEnd {
                let leading = abs(start - areaStart), trailing = abs(areaEnd - end)
                let edgeInset = max(4, (end - start) * 0.1)
                if leading <= trailing, leading <= edgeInset { return 0 }
                if trailing < leading, trailing <= edgeInset { return 1 }
            }
            return 0.5
        }
        var x = requested.minX + (requested.width - size.width)
            * anchor(requested.minX, requested.maxX, areaStart: workArea?.minX, areaEnd: workArea?.maxX)
        var y = requested.minY + (requested.height - size.height)
            * anchor(requested.minY, requested.maxY, areaStart: workArea?.minY, areaEnd: workArea?.maxY)
        if let area = workArea {
            x = min(max(x, area.minX), max(area.minX, area.maxX - size.width))
            y = min(max(y, area.minY), max(area.minY, area.maxY - size.height))
        }
        return CGRect(origin: CGPoint(x: x, y: y), size: size)
    }

    func execute(requested: CGRect, original: CGRect, workArea: CGRect?, resize: Bool,
                 allowConstrained: Bool, validate: () throws -> Void,
                 validateRollback: () throws -> Void, read: () throws -> CGRect,
                 setSize: (CGSize) throws -> Void, setPosition: (CGPoint) throws -> Void,
                 saveOriginal: () -> Void, didRestore: () -> Void = {}) async throws -> WindowLayoutOutcome {
        guard !isBusy else { throw SystemControlError.message("窗口操作正在进行，请稍候再试。") }
        guard Self.isValid(requested), Self.isValid(original) else {
            throw SystemControlError.message("窗口布局包含无效的位置或尺寸。")
        }
        try Task.checkCancellation()
        try validate()
        try Task.checkCancellation()
        isBusy = true
        defer { isBusy = false }
        saveOriginal() // Must precede even a partially accepted or throwing AX write.

        func check() throws { try Task.checkCancellation(); try validate(); try Task.checkCancellation() }
        func readValid() throws -> CGRect {
            let value = try read()
            guard Self.isValid(value) else { throw SystemControlError.message("目标窗口返回了无效尺寸。") }
            return value
        }
        func settle(expected: CGRect, rollingBack: Bool = false) async throws -> CGRect {
            var previous: CGRect?
            var stable = 0
            var actual = original
            for _ in 0..<pollCount {
                await pause()
                if rollingBack { try validateRollback() } else { try check() }
                actual = try readValid()
                // AX reads are IPC too; cancellation, focus or identity may change while a read is in flight.
                if rollingBack { try validateRollback() } else { try check() }
                if let previous, Self.matches(actual, previous, tolerance: 1) { stable += 1 }
                else { stable = 0 }
                previous = actual
                if stable >= 2, Self.matches(actual, expected) { return actual }
            }
            guard stable >= 2 else { throw SystemControlError.message("目标窗口仍在调整，未能确认稳定位置。") }
            return actual
        }
        // A size restriction may reject the whole CGSize. Still attempt position, then retry axes independently.
        func writeFrame(_ frame: CGRect, resizing: Bool, rollingBack: Bool = false) throws {
            func validateWrite() throws { if rollingBack { try validateRollback() } else { try check() } }
            try validateWrite()
            if resizing { try? setSize(frame.size) }
            try validateWrite()
            try? setPosition(frame.origin)
            if resizing {
                try validateWrite()
                try? setSize(frame.size) // Moving across screens can change the accepted size.
            }
        }

        do {
            try writeFrame(requested, resizing: resize)
            var actual = try await settle(expected: requested)
            if Self.matches(actual, requested) {
                if !allowConstrained { didRestore() }
                return WindowLayoutOutcome(requested: requested, actual: actual)
            }
            guard allowConstrained else { throw SystemControlError.message("目标应用拒绝恢复记录中的窗口位置或尺寸。") }
            if resize {
                // The current width is known to be accepted, so a narrow requested width cannot block full height.
                try check()
                try? setSize(CGSize(width: actual.width, height: requested.height))
                let heightTarget = CGRect(origin: actual.origin, size: CGSize(width: actual.width, height: requested.height))
                actual = try await settle(expected: heightTarget)
                if abs(actual.width - requested.width) > 4 {
                    try check()
                    try? setSize(CGSize(width: requested.width, height: actual.height))
                    let widthTarget = CGRect(origin: actual.origin, size: CGSize(width: requested.width, height: actual.height))
                    actual = try await settle(expected: widthTarget)
                }
            }
            let fitted = Self.fittedFrame(size: actual.size, requested: requested, workArea: workArea)
            try check()
            try? setPosition(fitted.origin)
            actual = try await settle(expected: fitted)
            guard Self.matches(actual, fitted) else {
                throw SystemControlError.message("目标应用拒绝将允许的窗口尺寸贴到目标区域，未完成此布局。")
            }
            guard !Self.matches(actual, original) else {
                throw SystemControlError.message("目标应用未接受所请求的窗口布局。")
            }
            return WindowLayoutOutcome(requested: requested, actual: actual)
        } catch {
            let reason = error is CancellationError ? "窗口操作已取消。" : error.localizedDescription
            var restored = false
            do {
                try writeFrame(original, resizing: true, rollingBack: true)
                restored = Self.matches(try await settle(expected: original, rollingBack: true), original)
            } catch { restored = false }
            throw WindowLayoutFailure(reason: reason, rollbackVerified: restored)
        }
    }
}
