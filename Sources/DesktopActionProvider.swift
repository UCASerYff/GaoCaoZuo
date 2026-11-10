import AppKit
import SwiftUI

/// Owns only the two canonical, zero-input desktop actions. It never controls an
/// external window on reception: opening a UI requires a distinct user approval.
struct DesktopProviderRecord: Codable, Identifiable {
    var id: String { manifest.requestID }
    var manifest: GaoActionManifest
    var manifestSHA256: String
    var packageDirectory: String
    var phase: Phase
    var outcome: GaoActionStatus?
    var resultPackages: [String] = []
    enum Phase: String, Codable { case received, executing, completed, interrupted }
}
private struct DesktopProviderDocument: Codable { var schema = 1; var records: [DesktopProviderRecord] = [] }
private struct DesktopProviderMarker: Codable { var schema = 1; var initialized = true }

final class DesktopProviderJournal {
    static let actions: Set<String> = ["windows.overview", "desktop.openSettings"]
    let data: LocalData
    private let parent: LocalData
    private(set) var records: [DesktopProviderRecord]
    init(directory: URL) throws {
        parent = LocalData(directory: directory)
        data = LocalData(directory: directory.appendingPathComponent("DesktopProvider", isDirectory: true))
        if let failure = parent.failure ?? data.failure { throw DataFailure.message(failure) }
        let marker = try parent.load("desktop-provider-initialization.json", as: DesktopProviderMarker.self)
        let saved = try data.load("provider.json", as: DesktopProviderDocument.self)
        if marker == nil && saved == nil {
            records = []
            try data.save(DesktopProviderDocument(), name: "provider.json")
            try parent.save(DesktopProviderMarker(), name: "desktop-provider-initialization.json")
        } else {
            guard let marker, marker.schema == 1, marker.initialized, let saved, saved.schema == 1,
                  saved.records.count <= 128, Set(saved.records.map { $0.id.lowercased() }).count == saved.records.count else {
                throw DataFailure.message("窗口交接记录或初始化依据缺失、损坏或过新；已保留原资料并停止写入。")
            }
            records = saved.records
            for r in records {
                guard Self.actions.contains(r.manifest.action), r.manifest.kind == .request,
                      r.manifest.targetBundleID == GaoActionV1.ownBundleID,
                      r.manifest.items.isEmpty, r.manifest.references.isEmpty, r.manifest.parameters.isEmpty,
                      GaoActionV1.validHash(r.manifestSHA256), r.resultPackages.count <= 32 else {
                    throw DataFailure.message("窗口交接记录内容无效，未重新执行。")
                }
                try GaoActionV1.validateManifest(r.manifest, now: GaoActionV1.parseDate(r.manifest.createdAt) ?? .distantFuture, expectedTarget: GaoActionV1.ownBundleID)
            }
            if records.contains(where: { $0.phase == .executing }) {
                var recovered = records
                for index in recovered.indices where recovered[index].phase == .executing { recovered[index].phase = .interrupted }
                try save(recovered)
            }
        }
    }
    private func save(_ next: [DesktopProviderRecord]) throws {
        guard next.count <= 128 else { throw DataFailure.message("窗口交接记录已满，请保留记录后人工整理。") }
        try data.save(DesktopProviderDocument(records: next), name: "provider.json")
        records = next
    }
    func existing(_ manifest: GaoActionManifest, digest: String) throws -> DesktopProviderRecord? {
        if let old = records.first(where: { $0.id.caseInsensitiveCompare(manifest.requestID) == .orderedSame }) {
            guard old.manifestSHA256 == digest else { throw GaoActionError.invalidPackage("同一窗口请求标识内容已改变，拒绝覆盖。") }
            return old
        }
        return nil
    }
    func receive(_ package: GaoActionReceivedPackage) throws {
        let m = package.manifest
        guard m.kind == .request, Self.actions.contains(m.action), m.targetBundleID == GaoActionV1.ownBundleID,
              m.items.isEmpty, m.references.isEmpty, m.parameters.isEmpty else { throw GaoActionError.invalidPackage("窗口接口只接受明确的无参数请求。") }
        try GaoActionV1.validateManifest(m, expectedTarget: GaoActionV1.ownBundleID)
        if try existing(m, digest: package.manifestSHA256) != nil { return }
        try save(records + [DesktopProviderRecord(manifest: m, manifestSHA256: package.manifestSHA256, packageDirectory: package.directory.path, phase: .received)])
    }
    func verify(_ id: String) throws -> DesktopProviderRecord {
        guard let r = records.first(where: { $0.id == id }), r.phase == .received else { throw GaoActionError.invalidPackage("请求已处理或中断，不能再次执行。") }
        let header = try GaoActionV1.inspectManifest(at: URL(fileURLWithPath: r.packageDirectory), expectedTarget: GaoActionV1.ownBundleID)
        guard header.digest == r.manifestSHA256, header.manifest == r.manifest else { throw GaoActionError.invalidPackage("待确认的窗口请求已变化。") }
        return r
    }
    func begin(_ id: String) throws {
        _ = try verify(id)
        var next = records; let i = next.firstIndex(where: { $0.id == id })!
        next[i].phase = .executing
        try save(next) // Durable intent before exposing a UI; never replay on recovery.
    }
    func finish(_ id: String, outcome: GaoActionStatus) throws {
        guard let i = records.firstIndex(where: { $0.id == id }),
              records[i].phase == .executing || (records[i].phase == .received && outcome == .cancelled) else {
            throw GaoActionError.invalidPackage("窗口请求不能重复完成。")
        }
        var next = records; next[i].phase = .completed; next[i].outcome = outcome
        try save(next)
    }
    func result(_ id: String) throws -> URL {
        guard let i = records.firstIndex(where: { $0.id == id }), records[i].phase == .completed,
              let status = records[i].outcome, records[i].resultPackages.count < 32 else { throw GaoActionError.invalidPackage("尚无可发送的最终窗口结果。") }
        let r = records[i]
        let url = try GaoActionV1.createResultPackage(in: data.directory.appendingPathComponent("Exchange/Outgoing", isDirectory: true), request: r.manifest,
            status: status, provenance: ["workflowState": status == .cancelled ? "cancelled" : (status == .completed ? "completed" : "failed"),
                                      "interfaceOpened": status == .completed, "windowsModified": false])
        var next = records; next[i].resultPackages.append(url.lastPathComponent)
        try save(next)
        return url
    }
}

@MainActor final class DesktopActionProvider: ObservableObject {
    @Published private(set) var records: [DesktopProviderRecord] = []
    @Published private(set) var busy = false
    @Published private(set) var message = "外部请求只打开本应用界面，必须单独确认；来源声明不证明发送者身份。"
    let directory: URL
    private var journal: DesktopProviderJournal?
    init(directory: URL) { self.directory = directory }
    private func ready() throws -> DesktopProviderJournal {
        if let journal { return journal }
        let j = try DesktopProviderJournal(directory: directory); journal = j; records = j.records; return j
    }
    func reload() { do { records = try ready().records } catch { message = error.localizedDescription } }
    func receive(_ url: URL) async {
        guard !busy else { message = "正在处理另一窗口请求，请稍后手动重新打开。"; return }
        busy = true; defer { busy = false }
        do {
            let j = try ready()
            let header = try await Task.detached { try GaoActionV1.inspectManifest(at: url, expectedTarget: GaoActionV1.ownBundleID) }.value
            if let old = try j.existing(header.manifest, digest: header.digest) { message = "该请求已接收，保持原状态：" + old.phase.rawValue; return }
            let dest = j.data.directory.appendingPathComponent("Exchange/Incoming", isDirectory: true)
            let package = try await Task.detached { try GaoActionV1.stagePackage(at: url, in: dest) }.value
            guard package.manifestSHA256 == header.digest else { throw GaoActionError.invalidPackage("窗口请求在校验与复制期间改变。") }
            try j.receive(package); records = j.records; message = "请求已保存，请核对后打开界面或取消。"
        } catch { message = error.localizedDescription }
    }
    func decide(_ id: String, approve: Bool, open: (String) -> Bool) {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let j = try ready(); let r = try j.verify(id)
            if approve { try j.begin(id); try j.finish(id, outcome: open(r.manifest.action) ? .completed : .failed) }
            else { try j.finish(id, outcome: .cancelled) }
            records = j.records; message = approve ? "已记录实际界面打开结果；发送仍需显式操作。" : "已取消，未打开界面。"
        } catch { message = error.localizedDescription; records = journal?.records ?? [] }
    }
    func sendResult(_ id: String) async {
        guard !busy else { return }; busy = true; defer { busy = false }
        do {
            let j = try ready()
            guard let record = j.records.first(where: { $0.id == id }), let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: record.manifest.sourceBundleID),
                  Bundle(url: app)?.bundleIdentifier == record.manifest.sourceBundleID else { throw GaoActionError.providerNotReady("原应用没有可核验的正式入口。") }
            let url = try j.result(id); records = j.records
            let config = NSWorkspace.OpenConfiguration(); config.activates = true; config.allowsRunningApplicationSubstitution = false
            _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<NSRunningApplication, Error>) in
                NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config) { app, error in
                    if let error { c.resume(throwing: error) }
                    else if let app { c.resume(returning: app) }
                    else { c.resume(throwing: GaoActionError.providerNotReady("系统未确认交付。")) }
                }
            }
            message = "结果已递交，仍需原应用核对接受；不会自动重发。"
        } catch { message = error.localizedDescription }
    }
}

struct DesktopProviderHistoryView: View {
    @ObservedObject var provider: DesktopActionProvider
    var open: (String) -> Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("窗口总览外部请求").font(.headline)
            Text(provider.message).font(.caption).foregroundStyle(.secondary)
            ForEach(provider.records.reversed()) { record in
                VStack(alignment: .leading, spacing: 6) {
                    Text(record.manifest.action + " · " + record.manifest.sourceBundleID)
                    Text(record.phase.rawValue + " · " + (record.outcome?.rawValue ?? "等待确认")).font(.caption)
                    HStack {
                        if record.phase == .received {
                            Button("确认并打开界面") { provider.decide(record.id, approve: true, open: open) }
                            Button("取消请求") { provider.decide(record.id, approve: false, open: open) }
                        } else if record.phase == .completed {
                            Button("发送结果给原应用") { Task { await provider.sendResult(record.id) } }
                        }
                    }.disabled(provider.busy)
                }.padding(8).background(.quaternary.opacity(0.3), in: RoundedRectangle(cornerRadius: 8))
            }
        }.onAppear { provider.reload() }
    }
}
