import AppKit
import ApplicationServices
import Carbon
import Darwin

/// One explicitly opted-in, isolated acceptance capture. These observations do
/// not choose a device/profile or change any input event.
@MainActor final class ScrollAcceptanceDiagnostic {
    private static let allowedRoot = "/private/tmp/gaocaozuo-acceptance-7ba84a4e-3a21-40e6-8ac8-b64e2000b32c.noindex"
    private static let rootName = "gaocaozuo-acceptance-7ba84a4e-3a21-40e6-8ac8-b64e2000b32c.noindex"
    private static var admitted = false
    struct Delta: Encodable, Sendable { var x: Double?; var y: Double? }
    struct Deltas: Encodable, Sendable { var line: Delta; var fixed: Delta; var point: Delta }
    struct NativeChild: Encodable, Sendable { var indexPath: [Int]; var type: UInt32; var sender: UInt64 }
    struct Native: Encodable, Sendable {
        var copyAvailable: Bool; var senderAvailable: Bool; var typeAvailable: Bool; var childrenAvailable: Bool
        var exists = false; var rootType: UInt32?; var rootSender: UInt64?
        var children: [NativeChild] = []; var childrenTruncated = false
    }
    struct Device: Encodable, Sendable { var hashID: String?; var registryID: UInt64; var cachedEventServiceIDs: [UInt64] }
    struct Profile: Encodable, Sendable {
        var id: UUID; var device: String?; var enabled: Bool; var appExcluded: Bool
        var bypassModifiers: UInt64; var bypassHeld: Bool; var reverseX: Bool; var reverseY: Bool
    }
    struct Capture {
        var elapsed: Double; var sourcePID: Int64; var flags: UInt64; var maskedFlags: UInt64
        var shiftClass: Bool; var precise: Bool; var tapActive: Bool?; var accessibilityTrusted: Bool
        var native: Native; var devices: [Device]; var profiles: [Profile]; var before: Deltas
    }
    struct Entry: Encodable, Sendable {
        var sequence: Int; var elapsed: Double; var sourcePID: Int64; var flags: UInt64; var maskedFlags: UInt64
        var shiftClass: Bool; var precise: Bool; var tapActive: Bool?; var accessibilityTrusted: Bool
        var native: Native; var devices: [Device]; var profiles: [Profile]
        var productionOwner: String?; var selectedProfileID: UUID?; var decision: String; var bypassReason: String?
        var consumed: Bool; var before: Deltas; var after: Deltas
    }
    struct Report: Encodable, Sendable {
        var schema = 1; var kind = "isolated-scroll-ownership-metadata"
        var operationID: UUID; var finishReason: String; var duration: Double
        var normalCount: Int; var shiftCount: Int; var skippedNormalAtQuota: Int; var skippedShiftAtQuota: Int
        var entries: [Entry]
    }
    private struct WriteJob: Sendable {
        let descriptor: Int32
        let rootPath: String
        let device: dev_t
        let inode: ino_t
        let dataDevice: dev_t
        let dataInode: ino_t
        let owner: uid_t
        let report: Report
    }
    private typealias CopyNative = @convention(c) (CGEvent) -> Unmanaged<CFTypeRef>?
    private typealias Sender = @convention(c) (CFTypeRef) -> UInt64
    private typealias NativeType = @convention(c) (CFTypeRef) -> UInt32
    private typealias Children = @convention(c) (CFTypeRef) -> Unmanaged<CFArray>?
    private static let graphics = dlopen("/System/Library/Frameworks/CoreGraphics.framework/CoreGraphics", RTLD_NOW | RTLD_LOCAL)
    private static let hid = dlopen("/System/Library/Frameworks/IOKit.framework/IOKit", RTLD_NOW | RTLD_LOCAL)
    private static let copyNative: CopyNative? = graphics.flatMap { dlsym($0, "CGEventCopyIOHIDEvent") }.map { unsafeBitCast($0, to: CopyNative.self) }
    private static let sender: Sender? = hid.flatMap { dlsym($0, "IOHIDEventGetSenderID") }.map { unsafeBitCast($0, to: Sender.self) }
    private static let nativeType: NativeType? = hid.flatMap { dlsym($0, "IOHIDEventGetType") }.map { unsafeBitCast($0, to: NativeType.self) }
    private static let children: Children? = hid.flatMap { dlsym($0, "IOHIDEventGetChildren") }.map { unsafeBitCast($0, to: Children.self) }

    private var descriptor: Int32
    private let device: dev_t, inode: ino_t
    private let dataDevice: dev_t, dataInode: ino_t
    private let operationID = UUID()
    private let armedAt = ProcessInfo.processInfo.systemUptime
    private var firstScroll: TimeInterval?
    private var entries: [Entry] = []
    private var normalCount = 0, shiftCount = 0, skippedNormal = 0, skippedShift = 0
    private var idleTask: Task<Void, Never>?, finishTask: Task<Void, Never>?
    private var finished = false

    private init(descriptor: Int32, info: stat, dataInfo: stat) {
        self.descriptor = descriptor; device = info.st_dev; inode = info.st_ino
        dataDevice = dataInfo.st_dev; dataInode = dataInfo.st_ino
    }
    static func makeIfAllowed() -> ScrollAcceptanceDiagnostic? {
        // No environment opt-in means no filesystem access, native event copy,
        // timer, or output file from this diagnostic.
        guard !admitted, ProcessInfo.processInfo.environment["GAO_SCROLL_ACCEPTANCE_DIR"] == allowedRoot else { return nil }
        let arguments = CommandLine.arguments
        guard arguments.filter({ $0 == "--data-dir" }).count == 1,
              !arguments.contains(where: { $0.hasPrefix("--data-dir=") }),
              let index = arguments.firstIndex(of: "--data-dir"), index + 1 < arguments.count,
              arguments[index + 1] == allowedRoot + "/data" else { return nil }
        // Literal allowlist plus POSIX directory anchors: no /tmp alias or URL
        // canonicalization may silently widen or reject the fixed root.
        let parent = open("/private/tmp", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard parent >= 0 else { return nil }; defer { close(parent) }
        var info = stat(), dataInfo = stat()
        guard fstatat(parent, rootName, &info, AT_SYMLINK_NOFOLLOW) == 0, info.st_mode & S_IFMT == S_IFDIR,
              info.st_uid == getuid(), info.st_mode & 0o7777 == 0o700 else { return nil }
        let fd = openat(parent, rootName, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let dataFD = openat(fd, "data", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard dataFD >= 0 else { close(fd); return nil }; defer { close(dataFD) }
        var opened = stat()
        var openedData = stat()
        guard fstat(fd, &opened) == 0, opened.st_dev == info.st_dev, opened.st_ino == info.st_ino,
              opened.st_uid == getuid(), opened.st_mode & 0o7777 == 0o700,
              fstatat(fd, "data", &dataInfo, AT_SYMLINK_NOFOLLOW) == 0, dataInfo.st_mode & S_IFMT == S_IFDIR,
              dataInfo.st_uid == getuid(), dataInfo.st_mode & 0o7777 == 0o700,
              fstat(dataFD, &openedData) == 0, openedData.st_dev == dataInfo.st_dev,
              openedData.st_ino == dataInfo.st_ino, openedData.st_uid == getuid(),
              openedData.st_mode & 0o7777 == 0o700 else { close(fd); return nil }
        admitted = true
        let capture = ScrollAcceptanceDiagnostic(descriptor: fd, info: opened, dataInfo: dataInfo)
        capture.idleTask = Task { @MainActor [weak capture] in
            try? await Task.sleep(nanoseconds: 300_000_000_000)
            guard !Task.isCancelled, let capture, capture.firstScroll == nil else { return }
            capture.finish(reason: "idle-expired")
        }
        return capture
    }
    private static func safeID(_ value: String?) -> String? {
        guard let value else { return nil }
        if value == "allWheel" || value == "allPrecise" { return value }
        return value.range(of: "^hid-v2:[a-f0-9]{64}$", options: .regularExpression) == nil ? nil : value
    }
    private static func deltas(_ event: CGEvent) -> Deltas {
        func number(_ field: CGEventField) -> Double? { let value = event.getDoubleValueField(field); return value.isFinite ? value : nil }
        return Deltas(line: Delta(x: number(.scrollWheelEventDeltaAxis2), y: number(.scrollWheelEventDeltaAxis1)),
                      fixed: Delta(x: number(.scrollWheelEventFixedPtDeltaAxis2), y: number(.scrollWheelEventFixedPtDeltaAxis1)),
                      point: Delta(x: number(.scrollWheelEventPointDeltaAxis2), y: number(.scrollWheelEventPointDeltaAxis1)))
    }
    private static func nativeSummary(_ event: CGEvent) -> Native {
        var report = Native(copyAvailable: copyNative != nil, senderAvailable: sender != nil,
                            typeAvailable: nativeType != nil, childrenAvailable: children != nil)
        guard let copyNative, let native = copyNative(event)?.takeRetainedValue() else { return report }
        report.exists = true; report.rootType = nativeType?(native); report.rootSender = sender?(native)
        guard let children, let nativeType, let sender else { return report }
        func visit(_ value: CFTypeRef, path: [Int], depth: Int) {
            guard depth < 3, let list = children(value)?.takeUnretainedValue() else { return }
            let count = CFArrayGetCount(list)
            if count > 32 || report.children.count + count > 32 { report.childrenTruncated = true }
            for index in 0..<min(count, 32) {
                guard report.children.count < 32 else { break }
                guard let pointer = CFArrayGetValueAtIndex(list, index) else { continue }
                let child: CFTypeRef = Unmanaged<AnyObject>.fromOpaque(pointer).takeUnretainedValue()
                let childPath = path + [index]
                report.children.append(NativeChild(indexPath: childPath, type: nativeType(child), sender: sender(child)))
                visit(child, path: childPath, depth: depth + 1)
            }
        }
        // Read type/sender even for a non-scroll wrapper. Never promote any
        // observed child to a production owner in this diagnostic.
        visit(native, path: [], depth: 0)
        return report
    }
    func begin(event: CGEvent, devices: [HIDDeviceDescriptor], profiles: [ScrollDeviceProfile],
               app: String, maskedFlags: UInt64, tapActive: Bool?) -> Capture? {
        guard !finished, event.type == .scrollWheel else { return nil }
        // Application-originated automation must not arm/consume the human
        // sample window. Source zero is an event-channel gate, not identity auth.
        let sourcePID = event.getIntegerValueField(.eventSourceUnixProcessID)
        guard sourcePID == 0 else { return nil }
        let now = ProcessInfo.processInfo.systemUptime
        if firstScroll == nil {
            guard now - armedAt < 300 else { finish(reason: "idle-expired"); return nil }
            firstScroll = now; idleTask?.cancel(); idleTask = nil
            finishTask = Task { @MainActor [weak self] in
                try? await Task.sleep(nanoseconds: 30_000_000_000)
                guard !Task.isCancelled else { return }; self?.finish(reason: "time-limit")
            }
        }
        guard let firstScroll, now - firstScroll < 30 else { finish(reason: "time-limit"); return nil }
        let shift = event.flags.contains(.maskShift)
        if shift ? shiftCount >= 80 : normalCount >= 80 {
            if shift { skippedShift = min(1_000_000, skippedShift + 1) }
            else { skippedNormal = min(1_000_000, skippedNormal + 1) }
            return nil
        }
        let deviceRows = devices.prefix(32).map {
            Device(hashID: Self.safeID($0.id), registryID: $0.registryID,
                   cachedEventServiceIDs: Array($0.eventServiceRegistryIDs.sorted().prefix(32)))
        }
        let profileRows = profiles.prefix(32).map {
            Profile(id: $0.id, device: Self.safeID($0.deviceID), enabled: $0.enabled,
                    appExcluded: $0.excludedApps.contains(app), bypassModifiers: $0.bypassModifiers,
                    bypassHeld: $0.bypassModifiers != 0 && maskedFlags & $0.bypassModifiers != 0,
                    reverseX: $0.reverseX, reverseY: $0.reverseY)
        }
        return Capture(elapsed: now - firstScroll, sourcePID: sourcePID,
            flags: event.flags.rawValue, maskedFlags: maskedFlags, shiftClass: shift,
            precise: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            tapActive: tapActive, accessibilityTrusted: AXIsProcessTrusted(), native: Self.nativeSummary(event),
            devices: deviceRows, profiles: profileRows, before: Self.deltas(event))
    }
    func end(_ capture: Capture, event: CGEvent, owner: String?, selectedProfileID: UUID?, decision: String, consumed: Bool) {
        guard !finished else { return }
        let active = capture.profiles.filter(\.enabled)
        let physical = active.filter { $0.device != "allWheel" && $0.device != "allPrecise" }
        let candidate = owner.flatMap { id in physical.first { $0.device == id } }
            ?? active.first { $0.device == (capture.precise ? "allPrecise" : "allWheel") }
        var bypass: String?
        if owner == nil && !physical.isEmpty { bypass = "unknown-or-ambiguous-physical-owner" }
        else if candidate == nil { bypass = "no-matching-profile" }
        else if candidate?.appExcluded == true { bypass = "profile-app-excluded" }
        else if candidate?.bypassHeld == true { bypass = "profile-modifier-bypass" }
        entries.append(Entry(sequence: entries.count + 1, elapsed: capture.elapsed, sourcePID: capture.sourcePID,
            flags: capture.flags, maskedFlags: capture.maskedFlags, shiftClass: capture.shiftClass,
            precise: capture.precise, tapActive: capture.tapActive, accessibilityTrusted: capture.accessibilityTrusted,
            native: capture.native, devices: capture.devices, profiles: capture.profiles,
            productionOwner: Self.safeID(owner), selectedProfileID: selectedProfileID, decision: decision,
            bypassReason: bypass, consumed: consumed, before: capture.before, after: Self.deltas(event)))
        if capture.shiftClass { shiftCount += 1 } else { normalCount += 1 }
        if entries.count >= 160 { finish(reason: "both-class-quotas") }
    }
    private func finish(reason: String) {
        guard !finished else { return }; finished = true
        idleTask?.cancel(); finishTask?.cancel(); idleTask = nil; finishTask = nil
        let fd = descriptor; descriptor = -1; guard fd >= 0 else { return }
        guard !entries.isEmpty else { close(fd); return }
        let report = Report(operationID: operationID, finishReason: reason,
            duration: max(0, ProcessInfo.processInfo.systemUptime - (firstScroll ?? armedAt)),
            normalCount: normalCount, shiftCount: shiftCount, skippedNormalAtQuota: skippedNormal,
            skippedShiftAtQuota: skippedShift, entries: entries)
        let job = WriteJob(descriptor: fd, rootPath: Self.allowedRoot, device: device, inode: inode,
            dataDevice: dataDevice, dataInode: dataInode, owner: getuid(), report: report)
        // The event callback only freezes value metadata and transfers fd
        // ownership. No JSON encoding or filesystem write runs on the tap/main.
        DispatchQueue(label: "com.gaoseries.GaoCaoZuo.scroll-acceptance-writer", qos: .utility).async {
            Self.write(job)
        }
    }
    private nonisolated static func write(_ job: WriteJob) {
        // Only immutable Sendable values and an exclusively transferred fd.
        // No AppKit, CGEvent, main-actor mutable state or callback is accessed.
        let fd = job.descriptor; defer { close(fd) }
        var named = stat(), opened = stat(), dataInfo = stat()
        guard lstat(job.rootPath, &named) == 0, named.st_mode & S_IFMT == S_IFDIR,
              fstat(fd, &opened) == 0, named.st_dev == job.device, named.st_ino == job.inode,
              opened.st_dev == job.device, opened.st_ino == job.inode, named.st_uid == job.owner,
              opened.st_uid == job.owner, opened.st_mode & S_IFMT == S_IFDIR,
              opened.st_mode & 0o7777 == 0o700,
              named.st_mode & 0o7777 == 0o700,
              fstatat(fd, "data", &dataInfo, AT_SYMLINK_NOFOLLOW) == 0, dataInfo.st_mode & S_IFMT == S_IFDIR,
              dataInfo.st_uid == job.owner, dataInfo.st_mode & 0o7777 == 0o700,
              dataInfo.st_dev == job.dataDevice, dataInfo.st_ino == job.dataInode else { return }
        guard let bytes = try? JSONEncoder().encode(job.report), bytes.count <= 8 * 1024 * 1024 else { return }
        let name = "scroll-acceptance-" + job.report.operationID.uuidString + ".json"
        let output = openat(fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { return }; defer { close(output) }
        guard fchmod(output, 0o600) == 0 else { return }
        var complete = true
        bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let count = Darwin.write(output, raw.baseAddress!.advanced(by: offset), raw.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { complete = false; break }; offset += count
            }
        }
        if complete { _ = fsync(output); _ = fsync(fd) }
    }
    isolated deinit {
        idleTask?.cancel(); finishTask?.cancel()
        if descriptor >= 0 { close(descriptor) }
    }
}
