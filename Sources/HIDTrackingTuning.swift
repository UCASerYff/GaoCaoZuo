import Foundation

/// Per-service parameter ownership. No global preference or event rewriting is
/// used. The journal is durable before the first write and is also the crash
/// recovery plan if a process dies between a write and its readback.
struct HIDTrackingBinding: Codable, Hashable {
    let deviceID: String
    let serviceID: UInt64
    var bootSession: String? = nil
}
struct HIDTrackingValues: Codable, Equatable {
    let accelerationKey: String
    let resolution: Int64
    let acceleration: Int64
    static let resolutionKey = "HIDPointerResolution"
    static let accelerationKeys = ["HIDMouseAcceleration", "HIDTrackpadAcceleration", "HIDPointerAcceleration"]
    var valid: Bool {
        Self.accelerationKeys.contains(accelerationKey) && (1...Int64(Int32.max)).contains(resolution)
            && (Int64(Int32.min)...Int64(Int32.max)).contains(acceleration)
    }
    func value(_ key: String) -> Int64 {key == Self.resolutionKey ? resolution : acceleration}
    var keys: [String] {[Self.resolutionKey, accelerationKey]}
    func requested(speed: Double, acceleration: Double) throws -> Self {
        guard valid, speed.isFinite, (0.1...8).contains(speed), acceleration.isFinite, (0...3).contains(acceleration) else {
            throw HIDTrackingFailure.message("逐设备调校的原值或请求值无效；未修改设备。")
        }
        let resolution = (Double(self.resolution) / speed).rounded()
        guard (1...Double(Int32.max)).contains(resolution) else {throw HIDTrackingFailure.message("请求速度超出该设备的分辨率范围；未修改设备。")}
        return Self(accelerationKey: accelerationKey, resolution: Int64(resolution), acceleration: Int64((acceleration * 65536).rounded()))
    }
}
enum HIDTrackingFailure: LocalizedError {
    case message(String)
    var errorDescription: String? {if case .message(let value) = self {return L10n.text(value)};return nil}
}
@MainActor struct HIDTrackingBackend {
    var read: (HIDTrackingBinding) throws -> HIDTrackingValues
    var write: (HIDTrackingBinding, String, Int64) throws -> Bool
    var currentBootSession: () -> String? = {nil}
}
@MainActor final class HIDTrackingTuning {
    struct Request: Equatable {
        let profileID: UUID
        let binding: HIDTrackingBinding
        let speed: Double
        let acceleration: Double
    }
    struct Entry: Codable, Equatable {
        let id: UUID
        let profileID: UUID
        let binding: HIDTrackingBinding
        let original: HIDTrackingValues
        let requested: HIDTrackingValues
        let created: Date
        var state: String // prepared/active/restoring/restored/conflict/released/retired
        var detail: String?
        var needsRecovery: Bool {["prepared", "active", "restoring"].contains(state)}
    }
    struct Document: Codable {var schema = 1;var entries: [Entry] = []}
    struct Persistence {
        var load: () throws -> Document?
        /// Production uses LocalData's no-follow, change-detected, fsync write.
        var save: (Document) throws -> Void
    }
    private let backend: HIDTrackingBackend
    private let persistence: Persistence
    private var document: Document?
    private var blocked: Set<String> = []
    private(set) var status = "逐设备调校尚未应用"
    private(set) var appliedBindings: Set<HIDTrackingBinding> = []
    var onStatus: ((String) -> Void)?
    init(backend: HIDTrackingBackend, persistence: Persistence) {self.backend = backend;self.persistence = persistence}
    private func publish(_ message: String) {if status != message {status = message;onStatus?(message)}}
    private func load() throws {
        guard document == nil else {return}
        let loaded = try persistence.load() ?? Document()
        guard loaded.schema == 1, loaded.entries.count <= 512, Set(loaded.entries.map(\.id)).count == loaded.entries.count,
              loaded.entries.allSatisfy({$0.original.valid && $0.requested.valid && $0.original.accelerationKey == $0.requested.accelerationKey && $0.binding.serviceID != 0 && $0.binding.deviceID.hasPrefix("hid-v2:") && $0.binding.deviceID.count == 71 && $0.binding.deviceID.dropFirst(7).allSatisfy({$0.isHexDigit}) && ["prepared","active","restoring","restored","conflict","released","retired"].contains($0.state)}) else {
            throw HIDTrackingFailure.message("逐设备原值恢复记录损坏或版本不受支持；已保留记录并停止调校。")
        }
        document = loaded
        // A retained outside change is not consent to overwrite on next launch.
        blocked.formUnion(loaded.entries.filter{$0.state == "conflict"}.map{ $0.binding.deviceID })
    }
    private func save(_ updated: Document) throws {try persistence.save(updated);document = updated}
    private func restore(_ id: UUID) throws {
        guard var updated = document, let index = updated.entries.firstIndex(where:{$0.id == id}), updated.entries[index].needsRecovery else {return}
        var entry = updated.entries[index]
        appliedBindings.remove(entry.binding)
        if let oldBoot=entry.binding.bootSession, let currentBoot=backend.currentBootSession(), oldBoot != currentBoot {
            // IORegistry IDs are scoped to a boot. Preserve the original
            // evidence, but never chase it onto a newly enumerated device.
            entry.state="retired"
            entry.detail="系统启动已变化；旧设备参数无法重访，已保留原值记录，未修改新设备。"
            updated.entries[index]=entry;try save(updated);appliedBindings.remove(entry.binding);return
        }
        entry.state = "restoring";updated.entries[index] = entry;try save(updated)
        var conflicts: [String] = []
        // Restore only values still equal to our declared write. A changed key
        // belongs to its new writer, even if its value happens to be numeric.
        for key in entry.original.keys.reversed() {
            let current = try backend.read(entry.binding)
            guard current.valid, current.accelerationKey == entry.original.accelerationKey else {throw HIDTrackingFailure.message("设备参数类型已变化；原值记录已保留，未覆盖新参数。")}
            let value = current.value(key), original = entry.original.value(key)
            if value == original {continue}
            guard value == entry.requested.value(key) else {conflicts.append(key);continue}
            guard try backend.write(entry.binding, key, original), try backend.read(entry.binding).value(key) == original else {
                throw HIDTrackingFailure.message("设备原值恢复未得到一致读回；记录已保留，等待设备可用后重试。")
            }
        }
        entry.state = conflicts.isEmpty ? "restored" : "conflict"
        entry.detail = conflicts.isEmpty ? nil : "检测到外部参数变化，已保留新值：" + conflicts.joined(separator: ", ")
        updated = document!;updated.entries[index] = entry;try save(updated)
        appliedBindings.remove(entry.binding)
        if !conflicts.isEmpty {blocked.insert(entry.binding.deviceID);throw HIDTrackingFailure.message("设备参数已由系统或其他应用更改；仅恢复仍属于本应用的值，已暂停该设备调校。")}
    }
    /// Startup and disconnect recovery never use VID/PID or a replacement
    /// attachment. An unavailable exact binding remains pending in the journal.
    func recover() {
        do {
            try load()
            var failures: [String] = []
            for entry in document!.entries where entry.needsRecovery {
                do {try restore(entry.id)} catch {failures.append(error.localizedDescription)}
            }
            let retired=document!.entries.contains{$0.state == "retired"}
            publish(failures.isEmpty ? (retired ? "旧系统启动中的设备已失效；原值记录保留，未向新设备写入。" : "逐设备原值恢复已完成") : failures.joined(separator: "\n"))
        } catch {publish(error.localizedDescription)}
    }
    func reconcile(_ requests: [Request]) {
        do {
            try load()
            guard Set(requests.map(\.binding)).count == requests.count,
                  Set(requests.map{$0.binding.deviceID}).count == requests.count else {
                recover()
                throw HIDTrackingFailure.message("同一设备存在多个调校配置；已停止应用，等待消除冲突。")
            }
            let wanted = Set(requests.map{$0.binding.deviceID})
            var acknowledged = document!
            for index in acknowledged.entries.indices where acknowledged.entries[index].state == "conflict" && !wanted.contains(acknowledged.entries[index].binding.deviceID) {
                acknowledged.entries[index].state = "released"
            }
            if acknowledged.entries != document!.entries {try save(acknowledged)}
            blocked = blocked.intersection(wanted)
            // A changed request restores the original first, so speed ratios
            // never compound across configuration saves.
            var unavailable: Set<HIDTrackingBinding> = []
            var recoveryFailures: [String] = []
            for entry in document!.entries where entry.needsRecovery {
                do {
                let same = requests.first{$0.profileID == entry.profileID && $0.binding == entry.binding}
                if entry.state == "active", let same,
                   try entry.original.requested(speed: same.speed, acceleration: same.acceleration) == entry.requested {
                    if try backend.read(entry.binding) == entry.requested {appliedBindings.insert(entry.binding);continue}
                    try restore(entry.id)
                    var changed = document!
                    if let index = changed.entries.firstIndex(where:{$0.id == entry.id}) {
                        changed.entries[index].state = "conflict"
                        changed.entries[index].detail = "活动调校参数由外部重置；已暂停，等待明确关闭配置。"
                        try save(changed)
                    }
                    blocked.insert(entry.binding.deviceID)
                    throw HIDTrackingFailure.message("设备调校读回发生变化；已恢复仍属于本应用的参数，并暂停该设备。")
                }
                try restore(entry.id)
                } catch {
                    // One disconnected former attachment must not redirect its
                    // restore onto, or prevent explicit tuning of, another one.
                    unavailable.insert(entry.binding)
                    appliedBindings.remove(entry.binding)
                    recoveryFailures.append(error.localizedDescription)
                }
            }
            for request in requests where !appliedBindings.contains(request.binding) {
                if unavailable.contains(request.binding) {continue}
                guard !blocked.contains(request.binding.deviceID) else {throw HIDTrackingFailure.message("该设备检测到外部参数变化；请先关闭逐设备调校，再确认是否重新启用。")}
                let original = try backend.read(request.binding)
                let requested = try original.requested(speed: request.speed, acceleration: request.acceleration)
                guard document!.entries.count < 512 else {throw HIDTrackingFailure.message("逐设备原值记录已满；旧恢复记录保留，本次未修改设备。")}
                var updated = document!
                let entry = Entry(id: UUID(), profileID: request.profileID, binding: request.binding, original: original,
                                  requested: requested, created: Date(), state: "prepared")
                updated.entries.append(entry);try save(updated) // backup before ANY write
                do {
                    for key in original.keys where original.value(key) != requested.value(key) {
                        let current = try backend.read(request.binding)
                        // A preceding key may already have been written; every
                        // other key must still be original or our target.
                        guard current.valid, current.accelerationKey == original.accelerationKey,
                              original.keys.allSatisfy({current.value($0) == original.value($0) || current.value($0) == requested.value($0)}) else {throw HIDTrackingFailure.message("应用调校前设备参数已变化；停止写入并保留原值记录。")}
                        guard try backend.write(request.binding, key, requested.value(key)),
                              try backend.read(request.binding).value(key) == requested.value(key) else {throw HIDTrackingFailure.message("设备拒绝逐服务调校或读回不一致；已停止并开始恢复原值。")}
                    }
                    guard try backend.read(request.binding) == requested else {throw HIDTrackingFailure.message("设备调校最终读回不一致；已停止并开始恢复原值。")}
                    updated = document!;updated.entries[updated.entries.count - 1].state = "active";try save(updated)
                    appliedBindings.insert(request.binding)
                } catch {
                    let initial = error
                    do {try restore(entry.id)} catch {publish(error.localizedDescription);return}
                    blocked.insert(request.binding.deviceID)
                    throw initial
                }
            }
            publish(recoveryFailures.isEmpty ? (requests.isEmpty ? "逐设备原值恢复已完成" : "逐设备调校已应用并读回核对；停用时恢复原值") : recoveryFailures.joined(separator: "\n"))
        } catch {publish(error.localizedDescription)}
    }
    // A pause/permission loss/quit is not acknowledgement of an outside change.
    // Only an actual disabled request releases that refusal in reconcile([]).
    func stop() {recover()}
}
