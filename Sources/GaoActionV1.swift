import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers

// MARK: - GaoAction V1 Models

public enum GaoActionKind: String, Codable {
    case request
    case result
}

public enum GaoActionStatus: String, Codable {
    case pending
    case completed
    case partial
    case cancelled
    case failed
    case unsupported
}

public enum GaoActionReferenceKind: String, Codable {
    case file
    case directory
    case application
}

public struct GaoActionIdentity: Codable, Equatable {
    public var volumeUUID: String?
    public var device: Int32?
    public var inode: UInt64?
    public var byteCount: UInt64?
    public var modifiedAt: String?

    public init(volumeUUID: String? = nil, device: Int32? = nil, inode: UInt64? = nil, byteCount: UInt64? = nil, modifiedAt: String? = nil) {
        self.volumeUUID = volumeUUID
        self.device = device
        self.inode = inode
        self.byteCount = byteCount
        self.modifiedAt = modifiedAt
    }
}

public struct GaoActionApplicationRef: Codable, Equatable {
    public var bundleID: String

    public init(bundleID: String) {
        self.bundleID = bundleID
    }
}

public struct GaoActionReference: Codable, Equatable {
    public var id: String
    public var kind: GaoActionReferenceKind
    public var fileURL: String?
    public var displayName: String
    public var declaredIdentity: GaoActionIdentity?
    public var application: GaoActionApplicationRef?

    public init(id: String, kind: GaoActionReferenceKind, fileURL: String? = nil, displayName: String, declaredIdentity: GaoActionIdentity? = nil, application: GaoActionApplicationRef? = nil) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.displayName = displayName
        self.declaredIdentity = declaredIdentity
        self.application = application
    }
}

public struct GaoActionItem: Codable, Equatable {
    public var id: String
    public var relativePath: String
    public var uti: String
    public var byteCount: UInt64
    public var sha256: String

    public init(id: String, relativePath: String, uti: String, byteCount: UInt64, sha256: String) {
        self.id = id
        self.relativePath = relativePath
        self.uti = uti
        self.byteCount = byteCount
        self.sha256 = sha256
    }
}

public struct GaoActionAnyCodable: Codable, Equatable {
    public let value: Any

    public init(_ value: Any) {
        self.value = value
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self.value = NSNull()
        } else if let b = try? container.decode(Bool.self) {
            self.value = b
        } else if let i = try? container.decode(Int.self) {
            self.value = i
        } else if let d = try? container.decode(Double.self) {
            self.value = d
        } else if let s = try? container.decode(String.self) {
            self.value = s
        } else if let a = try? container.decode([GaoActionAnyCodable].self) {
            self.value = a.map(\.value)
        } else if let m = try? container.decode([String: GaoActionAnyCodable].self) {
            self.value = m.mapValues(\.value)
        } else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Unsupported GaoAction JSON value")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch value {
        case is NSNull:
            try container.encodeNil()
        case let b as Bool:
            try container.encode(b)
        case let i as Int:
            try container.encode(i)
        case let d as Double:
            try container.encode(d)
        case let s as String:
            try container.encode(s)
        case let a as [Any]:
            try container.encode(a.map { GaoActionAnyCodable($0) })
        case let m as [String: Any]:
            try container.encode(m.mapValues { GaoActionAnyCodable($0) })
        default:
            let context = EncodingError.Context(codingPath: container.codingPath, debugDescription: "Cannot encode \(value)")
            throw EncodingError.invalidValue(value, context)
        }
    }

    public static func == (lhs: GaoActionAnyCodable, rhs: GaoActionAnyCodable) -> Bool {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let leftData = try? encoder.encode(lhs), let rightData = try? encoder.encode(rhs) else { return false }
        return leftData == rightData
    }
}

public struct GaoActionManifest: Codable, Equatable {
    public var schemaVersion: Int = 1
    public var kind: GaoActionKind
    public var requestID: String
    public var sourceBundleID: String
    public var targetBundleID: String
    public var action: String
    public var createdAt: String
    public var expiresAt: String
    public var nonce: String
    public var items: [GaoActionItem] = []
    public var references: [GaoActionReference] = []
    public var parameters: [String: GaoActionAnyCodable] = [:]

    // Result specific fields
    public var inReplyTo: String?
    public var status: GaoActionStatus?
    public var errorCode: String?
    public var provenance: [String: GaoActionAnyCodable]?

    public init(
        schemaVersion: Int = 1,
        kind: GaoActionKind,
        requestID: String,
        sourceBundleID: String,
        targetBundleID: String,
        action: String,
        createdAt: String,
        expiresAt: String,
        nonce: String,
        items: [GaoActionItem] = [],
        references: [GaoActionReference] = [],
        parameters: [String: GaoActionAnyCodable] = [:],
        inReplyTo: String? = nil,
        status: GaoActionStatus? = nil,
        errorCode: String? = nil,
        provenance: [String: GaoActionAnyCodable]? = nil
    ) {
        self.schemaVersion = schemaVersion
        self.kind = kind
        self.requestID = requestID
        self.sourceBundleID = sourceBundleID
        self.targetBundleID = targetBundleID
        self.action = action
        self.createdAt = createdAt
        self.expiresAt = expiresAt
        self.nonce = nonce
        self.items = items
        self.references = references
        self.parameters = parameters
        self.inReplyTo = inReplyTo
        self.status = status
        self.errorCode = errorCode
        self.provenance = provenance
    }
}

// MARK: - Validation & Constants

public enum GaoActionError: LocalizedError {
    case invalidPackage(String)
    case schemaUnsupported(Int)
    case expired(String)
    case pathTraversal(String)
    case unknownAction(String)
    case sizeExceeded(String)
    case duplicateRequest(String)
    case providerNotReady(String)

    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let msg): return "GaoAction 包格式无效: \(msg)"
        case .schemaUnsupported(let ver): return "不支持的 GaoAction schemaVersion: \(ver)"
        case .expired(let id): return "GaoAction 请求已过期: \(id)"
        case .pathTraversal(let path): return "检测到非法的相对路径逃逸: \(path)"
        case .unknownAction(let action): return "未知的 GaoAction 动作: \(action)"
        case .sizeExceeded(let msg): return "GaoAction 载荷超限: \(msg)"
        case .duplicateRequest(let id): return "重复的 GaoAction requestID: \(id)"
        case .providerNotReady(let msg): return "提供方尚未就绪: \(msg)"
        }
    }
}

public enum GaoActionV1 {
    public static let packageExtension = "gaoaction"
    public static let utType = "com.gaoseries.action-package"
    public static let maximumManifestBytes: Int = 1_048_576 // 1 MiB
    public static let maximumItems: Int = 256
    public static let defaultMaxPayloadBytes: UInt64 = 2 * 1024 * 1024 * 1024 // 2 GiB
    public static let requestTTLSeconds: TimeInterval = 120

    public static let knownActions: Set<String> = [
        "capture.region", "capture.window", "capture.display", "ocr.files", "images.annotate", "images.pin", "text.translate",
        "storage.inspect", "cleanup.review", "apps.uninstall.review",
        "files.search", "files.choose", "files.reveal", "associations.manage",
        "documents.open", "documents.newText",
        "research.importDocuments",
        "portal.openSite", "portal.openWorkspace", "portal.focusSearch", "portal.proposeSite", "portal.prepareDownload",
        "windows.overview", "desktop.openSettings",
        "downloads.prepare"
    ]

    private static let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    public static func formatDate(_ date: Date) -> String {
        isoFormatter.string(from: date)
    }

    public static func parseDate(_ string: String) -> Date? {
        isoFormatter.date(from: string)
    }

    public static func randomNonce() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, 32, &bytes)
        return Data(bytes).base64EncodedString()
    }

    public static func calculateSHA256(data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    public static func calculateFileSHA256(url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 65536), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - Validation

    public static func validateManifest(_ manifest: GaoActionManifest, now: Date = Date(), knownIDs: inout Set<String>) throws {
        guard manifest.schemaVersion == 1 else {
            throw GaoActionError.schemaUnsupported(manifest.schemaVersion)
        }
        guard knownActions.contains(manifest.action) else {
            throw GaoActionError.unknownAction(manifest.action)
        }
        guard UUID(uuidString: manifest.requestID) != nil else {
            throw GaoActionError.invalidPackage("requestID 必须为有效的 UUID")
        }
        if knownIDs.contains(manifest.requestID) {
            throw GaoActionError.duplicateRequest(manifest.requestID)
        }
        knownIDs.insert(manifest.requestID)

        if let expires = parseDate(manifest.expiresAt) {
            if expires < now {
                throw GaoActionError.expired(manifest.requestID)
            }
        } else {
            throw GaoActionError.invalidPackage("expiresAt 格式无效")
        }

        guard manifest.items.count <= maximumItems else {
            throw GaoActionError.sizeExceeded("条目数超限 (\(manifest.items.count) > \(maximumItems))")
        }

        for item in manifest.items {
            let rel = item.relativePath
            if rel.hasPrefix("/") || rel.contains("..") || rel.contains("\0") || rel.split(separator: "/").contains("..") {
                throw GaoActionError.pathTraversal(rel)
            }
        }
    }

    public static func validatePackageDirectory(at url: URL, now: Date = Date(), knownIDs: inout Set<String>) throws -> GaoActionManifest {
        let manifestURL = url.appendingPathComponent("manifest.json")
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw GaoActionError.invalidPackage("缺失 manifest.json")
        }
        let data = try Data(contentsOf: manifestURL)
        guard data.count <= maximumManifestBytes else {
            throw GaoActionError.sizeExceeded("manifest.json 超过 1 MiB")
        }
        let manifest = try JSONDecoder().decode(GaoActionManifest.self, from: data)
        try validateManifest(manifest, now: now, knownIDs: &knownIDs)

        // Validate payload items
        let payloadDir = url.appendingPathComponent("payload", isDirectory: true)
        var totalBytes: UInt64 = 0
        for item in manifest.items {
            let fileURL = payloadDir.appendingPathComponent(item.relativePath)
            guard FileManager.default.fileExists(atPath: fileURL.path) else {
                throw GaoActionError.invalidPackage("缺失 payload 项: \(item.relativePath)")
            }
            let values = try fileURL.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .fileSizeKey])
            if values.isSymbolicLink == true || values.isRegularFile != true {
                throw GaoActionError.invalidPackage("payload 文件必须为普通独立文件: \(item.relativePath)")
            }
            let size = UInt64(values.fileSize ?? 0)
            guard size == item.byteCount else {
                throw GaoActionError.invalidPackage("尺寸不符: \(item.relativePath) 预期 \(item.byteCount), 实际 \(size)")
            }
            totalBytes += size
            guard totalBytes <= defaultMaxPayloadBytes else {
                throw GaoActionError.sizeExceeded("payload 总尺寸超过 2 GiB")
            }
            let hash = try calculateFileSHA256(url: fileURL)
            guard hash == item.sha256 else {
                throw GaoActionError.invalidPackage("哈希校验不符: \(item.relativePath)")
            }
        }

        return manifest
    }

    // MARK: - Package Creation

    public static func createRequestPackage(
        in baseDir: URL,
        action: String,
        targetBundleID: String,
        sourceBundleID: String = "com.gaoseries.GaoCaoZuo",
        parameters: [String: Any] = [:],
        inputFiles: [URL] = [],
        references: [GaoActionReference] = [],
        requestID: UUID = UUID(),
        now: Date = Date(),
        nonce: String? = nil
    ) throws -> URL {
        guard knownActions.contains(action) else {
            throw GaoActionError.unknownAction(action)
        }
        let packageDir = baseDir.appendingPathComponent("\(requestID.uuidString).\(packageExtension)", isDirectory: true)
        let fm = FileManager.default
        try fm.createDirectory(at: packageDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])

        let payloadDir = packageDir.appendingPathComponent("payload", isDirectory: true)
        if !inputFiles.isEmpty {
            try fm.createDirectory(at: payloadDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }

        var items: [GaoActionItem] = []
        var totalPayload: UInt64 = 0
        for (index, file) in inputFiles.enumerated() {
            let relativePath = file.lastPathComponent
            let dest = payloadDir.appendingPathComponent(relativePath)
            try fm.copyItem(at: file, to: dest)
            try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: dest.path)
            let values = try dest.resourceValues(forKeys: [.fileSizeKey, .contentTypeKey])
            let size = UInt64(values.fileSize ?? 0)
            totalPayload += size
            guard totalPayload <= defaultMaxPayloadBytes else {
                throw GaoActionError.sizeExceeded("总载荷超过 2 GiB")
            }
            let hash = try calculateFileSHA256(url: dest)
            let uti = values.contentType?.identifier ?? UTType.data.identifier
            items.append(GaoActionItem(id: "item-\(index + 1)", relativePath: relativePath, uti: uti, byteCount: size, sha256: hash))
        }

        let createdAt = formatDate(now)
        let expiresAt = formatDate(now.addingTimeInterval(requestTTLSeconds))
        let manifestNonce = nonce ?? randomNonce()

        let codableParams = parameters.mapValues { GaoActionAnyCodable($0) }
        let manifest = GaoActionManifest(
            schemaVersion: 1,
            kind: .request,
            requestID: requestID.uuidString,
            sourceBundleID: sourceBundleID,
            targetBundleID: targetBundleID,
            action: action,
            createdAt: createdAt,
            expiresAt: expiresAt,
            nonce: manifestNonce,
            items: items,
            references: references,
            parameters: codableParams
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let manifestData = try encoder.encode(manifest)
        guard manifestData.count <= maximumManifestBytes else {
            throw GaoActionError.sizeExceeded("manifest.json 超限")
        }
        let manifestURL = packageDir.appendingPathComponent("manifest.json")
        try manifestData.write(to: manifestURL, options: .withoutOverwriting)
        try fm.setAttributes([.posixPermissions: 0o600], ofItemAtPath: manifestURL.path)

        return packageDir
    }
}

// MARK: - GaoAction Clients for GaoCaoZuo

@MainActor
public final class GaoActionClient {
    public let dataDirectory: URL
    private var knownRequestIDs: Set<String> = []

    public init(dataDirectory: URL) {
        self.dataDirectory = dataDirectory
    }

    public var outgoingDirectory: URL {
        dataDirectory.appendingPathComponent("Exchange", isDirectory: true).appendingPathComponent("Outgoing", isDirectory: true)
    }

    public func isProviderAvailable(bundleID: String) -> Bool {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) != nil
    }

    public func sendRequest(
        action: String,
        targetBundleID: String,
        parameters: [String: Any] = [:],
        inputFiles: [URL] = [],
        references: [GaoActionReference] = []
    ) async throws -> URL {
        guard isProviderAvailable(bundleID: targetBundleID) else {
            throw GaoActionError.providerNotReady("\(targetBundleID) 尚未安装；保留当前软件与上下文，请在安装对应提供方后重试。")
        }
        guard let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: targetBundleID) else {
            throw GaoActionError.providerNotReady("无法定位目标应用程序: \(targetBundleID)")
        }

        let packageURL = try GaoActionV1.createRequestPackage(
            in: outgoingDirectory,
            action: action,
            targetBundleID: targetBundleID,
            parameters: parameters,
            inputFiles: inputFiles,
            references: references
        )

        let config = NSWorkspace.OpenConfiguration()
        config.activates = true
        _ = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<NSRunningApplication, Error>) in
            NSWorkspace.shared.open([packageURL], withApplicationAt: appURL, configuration: config) { app, error in
                if let error = error {
                    continuation.resume(throwing: error)
                } else if let app = app {
                    continuation.resume(returning: app)
                } else {
                    continuation.resume(throwing: GaoActionError.providerNotReady("无法启动目标应用 \(targetBundleID)"))
                }
            }
        }
        return packageURL
    }
}

