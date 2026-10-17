import AppKit
import Foundation
import CryptoKit
import UniformTypeIdentifiers
import Darwin
import Security
import CoreFoundation

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
    enum CodingKeys:String,CodingKey { case volumeUUID,device,inode,byteCount,modifiedAt }
    public func encode(to encoder:Encoder) throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(volumeUUID,forKey:.volumeUUID);try c.encode(device,forKey:.device)
        try c.encode(inode,forKey:.inode);try c.encode(byteCount,forKey:.byteCount);try c.encode(modifiedAt,forKey:.modifiedAt)
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
    public var bundleID: String?
    public var sha256: String?

    public init(id: String, kind: GaoActionReferenceKind, fileURL: String? = nil, displayName: String, declaredIdentity: GaoActionIdentity? = nil, application: GaoActionApplicationRef? = nil, bundleID: String? = nil, sha256: String? = nil) {
        self.id = id
        self.kind = kind
        self.fileURL = fileURL
        self.displayName = displayName
        self.declaredIdentity = declaredIdentity
        self.application = application
        self.bundleID = bundleID ?? application?.bundleID
        self.sha256 = sha256
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

// MARK: - Fixed contract, structural and action validation

public enum GaoActionError: LocalizedError {
    case invalidPackage(String), schemaUnsupported(Int), expired(String), pathTraversal(String)
    case unknownAction(String), sizeExceeded(String), duplicateRequest(String), providerNotReady(String)
    public var errorDescription: String? {
        switch self {
        case .invalidPackage(let s): return L10n.format("GaoAction 校验失败：%@",L10n.text(s))
        case .schemaUnsupported(let n): return L10n.format("不支持 GaoAction schemaVersion %d",n)
        case .expired: return L10n.text("GaoAction 包已过期，请重新发送。")
        case .pathTraversal: return L10n.text("GaoAction 附件路径不安全。")
        case .unknownAction(let s): return L10n.format("不支持 GaoAction 动作：%@",s)
        case .sizeExceeded(let s): return L10n.format("GaoAction 超限：%@；请分批或另选文件。",L10n.text(s))
        case .duplicateRequest: return L10n.text("该请求已经接收；仅显示原状态，不重复执行。")
        case .providerNotReady(let s): return L10n.format("提供方尚未就绪：%@",L10n.text(s))
        }
    }
}

public enum GaoActionV1 {
    public static let ownBundleID = "com.gaoseries.GaoCaoZuo"
    public static let packageExtension = "gaoaction", utType = "com.gaoseries.action-package"
    public static let maximumManifestBytes = 1_048_576, maximumItems = 256
    public static let defaultMaxPayloadBytes: UInt64 = 2 * 1024 * 1024 * 1024
    public static let requestTTLSeconds: TimeInterval = 120
    public static let owners: [String:String] = Dictionary(uniqueKeysWithValues: [
        ("GaoJieTu", ["capture.region","capture.window","capture.display","ocr.files","images.annotate","images.pin","text.translate"]),
        ("GaoJiLing", ["storage.inspect","cleanup.review","apps.uninstall.review"]),
        ("GaoZhengLi", ["files.search","files.choose","files.reveal","associations.manage"]),
        ("GaoWenJian", ["documents.open","documents.newText"]),
        ("GaoZhuoMian", ["windows.overview","desktop.openSettings"]),
        ("GaoXiaZai", ["downloads.prepare"])
    ].flatMap { name, actions in actions.map { ($0, "com.gaoseries." + name) } } + [
        "portal.openSite","portal.openWorkspace","portal.focusSearch","portal.proposeSite","portal.prepareDownload"
    ].map { ($0, "cn.mendao.launcher") })
    public static let knownActions = Set(owners.keys).union(["research.importDocuments"])
    public static let parameterKeys: [String:Set<String>] = [
        "capture.region":["delaySeconds"], "capture.window":["delaySeconds"], "capture.display":["delaySeconds"],
        "ocr.files":["languages","outputs"], "text.translate":["sourceLanguage","targetLanguage"],
        "storage.inspect":["mode"], "files.search":["query"], "files.choose":["allowedUTIs","multiple"],
        "associations.manage":["uti"], "documents.newText":["suggestedTitle"], "research.importDocuments":["targetRecordID"],
        "portal.openSite":["siteID","browserID"], "portal.openWorkspace":["workspaceID"], "portal.focusSearch":["query"],
        "portal.proposeSite":["url","title"], "portal.prepareDownload":["urls"], "downloads.prepare":["urls","mediaType"]
    ]
    public static func formatDate(_ date: Date) -> String { ISO8601DateFormatter().string(from: date) }
    public static func parseDate(_ string: String) -> Date? {
        guard string.hasSuffix("Z") else { return nil }
        let f = ISO8601DateFormatter()
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime,.withFractionalSeconds]; return f.date(from:string)
    }
    public static func randomNonce() throws -> String {
        var bytes = [UInt8](repeating:0,count:32)
        guard SecRandomCopyBytes(kSecRandomDefault,bytes.count,&bytes) == errSecSuccess else {
            // Failing randomness must never create a predictable production nonce.
            throw GaoActionError.invalidPackage("系统随机源不可用，未建立 GaoAction 请求")
        }
        return Data(bytes).base64EncodedString()
    }
    public static func calculateSHA256(data: Data) -> String { SHA256.hash(data:data).map { String(format:"%02x",$0) }.joined() }
    public static func calculateFileSHA256(url: URL) throws -> String {
        let fd = try GaoActionFiles.openRegular(url, owned:false); defer { close(fd) }
        return try GaoActionFiles.copy(fd:fd,to:nil,limit:defaultMaxPayloadBytes).hash
    }
    static func validBundleID(_ s:String) -> Bool {
        s.count <= 255 && s.range(of:"^[A-Za-z0-9][A-Za-z0-9-]*(\\.[A-Za-z0-9][A-Za-z0-9-]*)+$",options:.regularExpression) != nil
    }
    static func validHash(_ s:String) -> Bool { s.range(of:"^[0-9a-f]{64}$",options:.regularExpression) != nil }
    static func validLanguage(_ s:String) -> Bool { s.utf8.count <= 64 && s.range(of:"^[A-Za-z]{2,8}(-[A-Za-z0-9]{1,8})*$",options:.regularExpression) != nil }
    static func identifier(_ s:String) -> Bool { !s.isEmpty && s.utf8.count <= 256 && !s.unicodeScalars.contains { $0.value < 32 } }
    static func safeRelativePath(_ s:String) throws {
        let parts=s.split(separator:"/",omittingEmptySubsequences:false)
        guard !s.isEmpty,s.utf8.count<=4096,!s.hasPrefix("/"),!s.contains("\\"),!s.contains("\0"),parts.count<=64,
              parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count<=255 }) else { throw GaoActionError.pathTraversal(s) }
    }
    public static func validateManifest(_ m:GaoActionManifest, now:Date=Date(), knownIDs:inout Set<String>, expectedTarget:String?=nil) throws {
        try validateManifest(m,now:now,expectedTarget:expectedTarget)
        guard !knownIDs.contains(m.requestID.lowercased()) else { throw GaoActionError.duplicateRequest(m.requestID) }
        // Invalid input must not poison deduplication state.
        knownIDs.insert(m.requestID.lowercased())
    }
    public static func validateManifest(_ m:GaoActionManifest, now:Date=Date(), expectedTarget:String?=nil) throws {
        guard m.schemaVersion == 1 else { throw GaoActionError.schemaUnsupported(m.schemaVersion) }
        guard knownActions.contains(m.action) else { throw GaoActionError.unknownAction(m.action) }
        guard UUID(uuidString:m.requestID) != nil,validBundleID(m.sourceBundleID),validBundleID(m.targetBundleID) else { throw GaoActionError.invalidPackage("UUID 或 bundleID 无效") }
        if let expectedTarget, m.targetBundleID != expectedTarget { throw GaoActionError.invalidPackage("目标应用不匹配") }
        if let owner=owners[m.action] {
            guard (m.kind == .request ? m.targetBundleID : m.sourceBundleID) == owner else { throw GaoActionError.invalidPackage("动作归属与提供方不匹配") }
        }
        guard let created=parseDate(m.createdAt),let expires=parseDate(m.expiresAt),expires > created,
              expires.timeIntervalSince(created) <= requestTTLSeconds, created <= now.addingTimeInterval(5) else { throw GaoActionError.invalidPackage("UTC 时间或 120 秒 TTL 无效") }
        guard expires > now else { throw GaoActionError.expired(m.requestID) }
        guard let nonce=Data(base64Encoded:m.nonce),nonce.count==32,nonce.base64EncodedString()==m.nonce else { throw GaoActionError.invalidPackage("nonce 必须为 32 字节标准 Base64") }
        guard m.items.count<=maximumItems,m.references.count<=maximumItems,Set(m.items.map(\.id)).count==m.items.count,
              Set(m.references.map(\.id)).count==m.references.count,Set(m.items.map(\.relativePath)).count==m.items.count else { throw GaoActionError.sizeExceeded("条目超限或标识/路径重复") }
        var total:UInt64=0
        for i in m.items {
            try safeRelativePath(i.relativePath)
            guard identifier(i.id),identifier(i.uti),UTType(i.uti) != nil,validHash(i.sha256),i.byteCount<=defaultMaxPayloadBytes-total else { throw GaoActionError.invalidPackage("附件类型、摘要、标识或预算无效") }
            total += i.byteCount
        }
        for r in m.references { try validateReferenceStructure(r) }
        if m.kind == .request {
            guard m.inReplyTo == nil,m.status == nil,m.errorCode == nil,m.provenance == nil else { throw GaoActionError.invalidPackage("请求包含结果专用字段") }
            try validateActionInputs(m)
        } else {
            guard let reply=m.inReplyTo,UUID(uuidString:reply) != nil,let status=m.status,m.parameters.isEmpty,let provenance=m.provenance else { throw GaoActionError.invalidPackage("结果关联、状态或 provenance 缺失") }
            if let code=m.errorCode { guard identifier(code) else { throw GaoActionError.invalidPackage("errorCode 无效") } }
            try validateJSON(provenance.mapValues(\.value),depth:0)
            try validateResultPayload(m)
            if let workflow=provenance["workflowState"]?.value as? String {
                if workflow == "awaitingUser" || workflow == "accepted" { guard status == .pending else { throw GaoActionError.invalidPackage("等待复核/任务接收不能标为完成") } }
                if workflow == "cancelled" { guard status == .cancelled else { throw GaoActionError.invalidPackage("取消状态不一致") } }
            }
            if ["cleanup.review","apps.uninstall.review"].contains(m.action),status == .completed {
                guard let receipt=provenance["receiptID"]?.value as? String,identifier(receipt),provenance["workflowState"]?.value as? String == "completed" else { throw GaoActionError.invalidPackage("复核完成结果缺少实际执行收据") }
            }
        }
    }
    static func validateResultPayload(_ m:GaoActionManifest) throws {
        guard let status=m.status,let p=m.provenance?.mapValues(\.value) else {throw GaoActionError.invalidPackage("结果状态缺失")}
        let successful=status == .completed || status == .partial
        if !["files.search","files.choose"].contains(m.action),!m.references.isEmpty {throw GaoActionError.invalidPackage("结果动作不接受原件引用")}
        if ["files.reveal","documents.open","documents.newText","associations.manage","cleanup.review","apps.uninstall.review","portal.openSite","portal.openWorkspace","portal.focusSearch","portal.proposeSite","portal.prepareDownload","windows.overview","desktop.openSettings","images.pin"].contains(m.action),!m.items.isEmpty {throw GaoActionError.invalidPackage("此动作结果不应附带文件")}
        if ["capture.region","capture.window","capture.display","images.annotate"].contains(m.action),successful {
            guard !m.items.isEmpty,m.items.allSatisfy({UTType($0.uti)?.conforms(to:.image)==true}) else {throw GaoActionError.invalidPackage("图像动作完成结果缺少图像产物")}
            if m.action != "images.annotate" {
                func dimensions(_ d:[String:Any])->Bool {
                    let size=d["pixelSize"] as? [String:Any] ?? d
                    let w=(size["width"] ?? size["pixelWidth"]) as? NSNumber,h=(size["height"] ?? size["pixelHeight"]) as? NSNumber
                    guard let w,let h,CFGetTypeID(w) != CFBooleanGetTypeID(),CFGetTypeID(h) != CFBooleanGetTypeID(),w.doubleValue>0,h.doubleValue>0,w.doubleValue<=100000,h.doubleValue<=100000,
                          let scale=d["scale"] as? NSNumber,CFGetTypeID(scale) != CFBooleanGetTypeID(),scale.doubleValue.isFinite,scale.doubleValue>0,let color=d["colorSpace"] as? String,identifier(color) else {return false}
                    return true
                }
                let outputs=p["outputs"] as? [[String:Any]]
                guard dimensions(p) || (outputs?.count==m.items.count && outputs?.allSatisfy(dimensions)==true) else {throw GaoActionError.invalidPackage("截图结果缺少像素尺寸、scale 或色彩空间")}
            }
        }
        if m.action=="images.pin",status == .completed {
            guard let state=p["workflowState"] as? String,["opened","closed"].contains(state) else {throw GaoActionError.invalidPackage("贴图结果必须说明实际打开或关闭")}
        }
        if m.action=="text.translate",successful {
            guard m.items.count==1,UTType(m.items[0].uti)?.conforms(to:.plainText)==true,
                  let provider=p["provider"] as? String,identifier(provider),let network=p["networkUsed"] ?? p["isNetwork"] ?? p["networked"],network is Bool else {throw GaoActionError.invalidPackage("翻译结果缺少译文、provider 或联网声明")}
        }
        if m.action=="ocr.files",successful {
            guard m.items.allSatisfy({let t=UTType($0.uti);return t?.conforms(to:.text)==true || t?.conforms(to:.pdf)==true || t?.conforms(to:.json)==true}),status != .completed || !m.items.isEmpty else {throw GaoActionError.invalidPackage("OCR 完成结果缺少文本/JSON/PDF 产物")}
        }
        if m.action=="downloads.prepare" {
            if p["workflowState"] as? String == "accepted" {
                guard status == .pending,let ids=p["taskIDs"] as? [String],!ids.isEmpty,ids.count<=32,ids.allSatisfy(identifier),Set(ids).count==ids.count else {throw GaoActionError.invalidPackage("下载接收仅可返回 pending 与实际 taskIDs")}
            }
            if successful {guard !m.items.isEmpty else {throw GaoActionError.invalidPackage("下载完成结果缺少实际输出文件")}}
        }
    }
    static func validateReferenceStructure(_ r:GaoActionReference) throws {
        guard identifier(r.id),identifier(r.displayName),let raw=r.fileURL,raw.utf8.count<=16384,
              let u=URL(string:raw),u.isFileURL,u.host == nil || u.host == "localhost",u.query==nil,u.fragment==nil,
              !u.path.contains("\0"),u.path.hasPrefix("/"),!u.path.split(separator:"/").contains(where:{$0 == "." || $0 == ".."}),GaoActionFiles.normalized(u).path == u.path,
              let identity=r.declaredIdentity else { throw GaoActionError.invalidPackage("reference 不是规范本机文件引用或缺少声明身份") }
        if let t=identity.modifiedAt { guard parseDate(t) != nil else { throw GaoActionError.invalidPackage("reference modifiedAt 无效") } }
        if let v=identity.volumeUUID { guard UUID(uuidString:v) != nil else { throw GaoActionError.invalidPackage("reference volumeUUID 无效") } }
        if let hash=r.sha256 { guard r.kind == .file,validHash(hash) else { throw GaoActionError.invalidPackage("reference 摘要无效") } }
        let bundle=r.bundleID ?? r.application?.bundleID
        if r.kind == .application { guard let bundle,validBundleID(bundle),r.application?.bundleID == nil || r.application?.bundleID == bundle else { throw GaoActionError.invalidPackage("应用引用缺少一致 bundleID") } }
        else if bundle != nil { throw GaoActionError.invalidPackage("非应用引用包含 bundleID") }
    }
    static func validateJSON(_ value:Any,depth:Int) throws {
        guard depth<=12 else { throw GaoActionError.invalidPackage("JSON 嵌套过深") }
        if let d=value as? [String:Any] {
            guard d.count<=256 else { throw GaoActionError.invalidPackage("JSON 字段过多") }
            for (k,v) in d {
                guard identifier(k),!["shell","script","callbackURL","browserArguments","setDefault","sudo","command","executable"].contains(k) else { throw GaoActionError.invalidPackage("结果包含不允许的指令字段") }
                try validateJSON(v,depth:depth+1)
            }
        } else if let a=value as? [Any] { guard a.count<=1024 else { throw GaoActionError.invalidPackage("JSON 数组过长") };for v in a {try validateJSON(v,depth:depth+1)} }
        else if let s=value as? String { guard s.utf8.count<=65536,!s.contains("\0") else { throw GaoActionError.invalidPackage("JSON 字符串无效") } }
        else if let n=value as? Double { guard n.isFinite else { throw GaoActionError.invalidPackage("JSON 数值无效") } }
        else if !(value is NSNumber) && !(value is NSNull) { throw GaoActionError.invalidPackage("JSON 值无效") }
    }
    static func validateActionInputs(_ m:GaoActionManifest) throws {
        let p=m.parameters.mapValues(\.value),keys=parameterKeys[m.action] ?? []
        guard Set(p.keys).isSubset(of:keys) else { throw GaoActionError.invalidPackage("动作参数不在白名单中") }
        func string(_ key:String,max:Int=4096,required:Bool=false) throws {
            if let v=p[key] { guard let s=v as? String,!s.isEmpty,s.utf8.count<=max,!s.contains("\0") else {throw GaoActionError.invalidPackage("参数 \(key) 无效")} }
            else if required {throw GaoActionError.invalidPackage("缺少参数 \(key)")}
        }
        func strings(_ key:String,max:Int=64) throws -> [String]? {
            guard let v=p[key] else {return nil};guard let a=v as? [String],!a.isEmpty,a.count<=max,Set(a).count==a.count else {throw GaoActionError.invalidPackage("数组参数 \(key) 无效")};return a
        }
        func noPayload() throws {guard m.items.isEmpty,m.references.isEmpty else {throw GaoActionError.invalidPackage("动作不接受文件或引用")}}
        func references(_ kinds:Set<GaoActionReferenceKind>,count:ClosedRange<Int>) throws {guard m.items.isEmpty,count.contains(m.references.count),m.references.allSatisfy({kinds.contains($0.kind)}) else {throw GaoActionError.invalidPackage("动作引用数量或类型不符")}}
        func image(_ i:GaoActionItem) -> Bool {UTType(i.uti)?.conforms(to:.image) == true}
        switch m.action {
        case "capture.region","capture.window","capture.display":
            try noPayload();if let v=p["delaySeconds"] {guard !(v is Bool),let n=v as? NSNumber,n.doubleValue>=0,n.doubleValue<=60 else {throw GaoActionError.invalidPackage("delaySeconds 必须为 0..60")}}
        case "ocr.files":
            guard !m.items.isEmpty,m.references.isEmpty,m.items.allSatisfy({image($0) || UTType($0.uti)?.conforms(to:.pdf) == true}) else {throw GaoActionError.invalidPackage("OCR 仅接受图像/PDF 副本")}
            if let a=try strings("languages") {guard a.allSatisfy(validLanguage) else {throw GaoActionError.invalidPackage("OCR 语言无效")}}
            if let a=try strings("outputs",max:4) {guard Set(a).isSubset(of:["text","markdown","json","searchablePDF"]) else {throw GaoActionError.invalidPackage("OCR 输出格式无效")}}
        case "images.annotate","images.pin": guard m.references.isEmpty,m.items.count==1,m.items.allSatisfy(image) else {throw GaoActionError.invalidPackage("图像动作仅接受一张图像副本")}
        case "text.translate":
            guard m.references.isEmpty,m.items.count==1,UTType(m.items[0].uti)?.conforms(to:.plainText) == true else {throw GaoActionError.invalidPackage("翻译仅接受一份 UTF-8 文本")}
            guard let target=p["targetLanguage"] as? String,validLanguage(target) else {throw GaoActionError.invalidPackage("翻译目标语言无效")}
            if let source=p["sourceLanguage"] {guard let s=source as? String,s == "auto" || validLanguage(s) else {throw GaoActionError.invalidPackage("翻译来源语言无效")}}
        case "storage.inspect":try references([.directory],count:1...1);if let mode=p["mode"] {guard let s=mode as? String,["metadata","duplicates"].contains(s) else {throw GaoActionError.invalidPackage("扫描模式无效")}}
        case "apps.uninstall.review":try references([.application],count:1...1)
        case "files.reveal":try references([.file,.directory,.application],count:1...1)
        case "files.search":try references([.directory],count:0...1);try string("query",required:true)
        case "files.choose":
            try references([.directory],count:0...1)
            if let a=try strings("allowedUTIs") {guard a.allSatisfy({UTType($0) != nil}) else {throw GaoActionError.invalidPackage("allowedUTIs 无效")}}
            if let v=p["multiple"] {guard v is Bool else {throw GaoActionError.invalidPackage("multiple 必须为布尔值")}}
        case "documents.open":guard (!m.items.isEmpty && m.references.isEmpty) || (m.items.isEmpty && !m.references.isEmpty && m.references.allSatisfy({$0.kind == .file})) else {throw GaoActionError.invalidPackage("文档副本与原件引用不得混用")}
        case "documents.newText":
            guard m.items.count==1,m.references.isEmpty,UTType(m.items[0].uti)?.conforms(to:.plainText) == true || m.items[0].uti == "net.daringfireball.markdown" else {throw GaoActionError.invalidPackage("新建文本仅接受一份 UTF-8 文本/Markdown")};try string("suggestedTitle",max:256)
        case "research.importDocuments":guard !m.items.isEmpty,m.references.isEmpty else {throw GaoActionError.invalidPackage("研究导入仅接受文档副本")};try string("targetRecordID",max:256)
        case "associations.manage":try noPayload();try string("uti",max:256);if let v=p["uti"] as? String,UTType(v)==nil {throw GaoActionError.invalidPackage("关联 UTI 无效")}
        case "portal.openSite":try noPayload();try string("siteID",max:256,required:true);try string("browserID",max:256)
        case "portal.openWorkspace":try noPayload();try string("workspaceID",max:256,required:true)
        case "portal.focusSearch":try noPayload();try string("query")
        case "portal.proposeSite":try noPayload();try string("url",required:true);try string("title",max:256);guard let raw=p["url"] as? String,safeHTTP(raw) else {throw GaoActionError.invalidPackage("站点仅接受 http/https URL")}
        case "portal.prepareDownload","downloads.prepare":
            try noPayload();guard let a=try strings("urls",max:32),a.allSatisfy(safeHTTP) else {throw GaoActionError.invalidPackage("下载仅接受 1..32 个 http/https URL")}
            if let v=p["mediaType"] {guard let s=v as? String,["file","video","audio","image","subtitle"].contains(s) else {throw GaoActionError.invalidPackage("媒体类型无效")}}
        default:try noPayload()
        }
    }
    static func safeHTTP(_ raw:String)->Bool {
        guard raw.utf8.count<=16384,let u=URL(string:raw),["http","https"].contains(u.scheme?.lowercased() ?? ""),u.host?.isEmpty==false,u.user==nil,u.password==nil else {return false};return true
    }

    public static func reference(for url:URL,id:String="ref-1") throws -> GaoActionReference {
        let canonical=GaoActionFiles.normalized(url)
        let fd=try GaoActionFiles.openPath(canonical,directory:nil,owned:false);defer{close(fd)}
        let s=try GaoActionFiles.info(fd)
        let isDirectory=s.st_mode & S_IFMT == S_IFDIR
        guard isDirectory || s.st_mode & S_IFMT == S_IFREG else {throw GaoActionError.invalidPackage("引用仅支持普通文件、目录或应用")}
        let bundle=isDirectory && canonical.pathExtension.lowercased()=="app" ? Bundle(url:canonical)?.bundleIdentifier : nil
        let volume=try? canonical.resourceValues(forKeys:[.volumeUUIDStringKey]).volumeUUIDString
        let identity=GaoActionIdentity(volumeUUID:volume ?? nil,device:s.st_dev,inode:UInt64(s.st_ino),byteCount:UInt64(max(0,s.st_size)),modifiedAt:formatDate(Date(timeIntervalSince1970:Double(s.st_mtimespec.tv_sec)+Double(s.st_mtimespec.tv_nsec)/1e9)))
        return GaoActionReference(id:id,kind:bundle != nil ? .application : (isDirectory ? .directory : .file),fileURL:canonical.absoluteString,displayName:canonical.lastPathComponent,declaredIdentity:identity,bundleID:bundle)
    }
    /// References are untrusted descriptions, not grants of access. All non-null fields must still match.
    public static func verifyReference(_ r:GaoActionReference) throws -> URL {
        try validateReferenceStructure(r)
        let url=GaoActionFiles.normalized(URL(string:r.fileURL!)!)
        let fd=try GaoActionFiles.openPath(url,directory:r.kind != .file,owned:false);defer{close(fd)}
        let s=try GaoActionFiles.info(fd),identity=r.declaredIdentity!
        guard identity.device != nil,identity.inode != nil else {throw GaoActionError.invalidPackage("引用身份不明确；请由接收方重新选择并核实原件")}
        guard identity.device == s.st_dev,identity.inode == UInt64(s.st_ino),identity.byteCount == nil || identity.byteCount == UInt64(max(0,s.st_size)) else {throw GaoActionError.invalidPackage("引用原件身份或大小已变化，停止处理")}
        if let modified=identity.modifiedAt,let expected=parseDate(modified) {
            // V1 ISO8601 timestamps may have only second precision; inode/size and optional digest remain independent checks.
            let actual=Double(s.st_mtimespec.tv_sec)+Double(s.st_mtimespec.tv_nsec)/1e9
            guard abs(actual-expected.timeIntervalSince1970)<(modified.contains(".") ? 0.002 : 1) else {throw GaoActionError.invalidPackage("引用修改时间已变化")}
        }
        if let volume=identity.volumeUUID {guard (try url.resourceValues(forKeys:[.volumeUUIDStringKey])).volumeUUIDString?.caseInsensitiveCompare(volume) == .orderedSame else {throw GaoActionError.invalidPackage("引用卷身份已变化")}}
        if r.kind == .application {guard Bundle(url:url)?.bundleIdentifier == (r.bundleID ?? r.application?.bundleID) else {throw GaoActionError.invalidPackage("应用引用 bundleID 已变化")}}
        if let hash=r.sha256 {guard try GaoActionFiles.copy(fd:fd,to:nil,limit:defaultMaxPayloadBytes).hash == hash else {throw GaoActionError.invalidPackage("引用摘要已变化")}}
        return url
    }
    static func decodeManifest(_ data:Data) throws -> GaoActionManifest {
        guard let object=try JSONSerialization.jsonObject(with:data) as? [String:Any] else {throw GaoActionError.invalidPackage("manifest 必须为 JSON object")}
        let allowed:Set<String>=["schemaVersion","kind","requestID","sourceBundleID","targetBundleID","action","createdAt","expiresAt","nonce","items","references","parameters","inReplyTo","status","errorCode","provenance"]
        guard Set(object.keys).isSubset(of:allowed) else {throw GaoActionError.invalidPackage("manifest 包含未知字段")}
        func check(_ key:String,allowed:Set<String>) throws {
            if let values=object[key] as? [[String:Any]] {guard values.allSatisfy({Set($0.keys).isSubset(of:allowed)}) else {throw GaoActionError.invalidPackage("\(key) 包含未知字段")}}
        }
        try check("items",allowed:["id","relativePath","uti","byteCount","sha256"])
        try check("references",allowed:["id","kind","fileURL","displayName","declaredIdentity","bundleID","application","sha256"])
        if let refs=object["references"] as? [[String:Any]] {
            for r in refs {
                if let i=r["declaredIdentity"] as? [String:Any] {guard Set(i.keys).isSubset(of:["volumeUUID","device","inode","byteCount","modifiedAt"]) else {throw GaoActionError.invalidPackage("reference 身份字段未知")}}
                if let a=r["application"] as? [String:Any] {guard Set(a.keys)==["bundleID"] else {throw GaoActionError.invalidPackage("旧 application 引用字段未知")}}
            }
        }
        return try JSONDecoder().decode(GaoActionManifest.self,from:data)
    }
    public static func inspectManifest(at url:URL,now:Date=Date(),expectedTarget:String?=nil) throws -> (manifest:GaoActionManifest,digest:String) {
        guard url.isFileURL,url.pathExtension.lowercased()==packageExtension else {throw GaoActionError.invalidPackage("不是 GaoAction 包")}
        let root=try GaoActionFiles.openPath(url,directory:true,owned:true);defer{close(root)}
        let fd=openat(root,"manifest.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw GaoActionError.invalidPackage("无法读取 manifest")};defer{close(fd)}
        let data=try GaoActionFiles.read(fd:fd,maximum:maximumManifestBytes,owned:true)
        let manifest=try decodeManifest(data);try validateManifest(manifest,now:now,expectedTarget:expectedTarget)
        return (manifest,calculateSHA256(data:data))
    }
    public static func validatePackageDirectory(at url:URL,now:Date=Date(),knownIDs:inout Set<String>,expectedTarget:String?=nil) throws -> GaoActionManifest {
        let package=try readPackage(at:url,staging:nil,now:now,expectedTarget:expectedTarget)
        guard !knownIDs.contains(package.manifest.requestID.lowercased()) else {throw GaoActionError.duplicateRequest(package.manifest.requestID)}
        knownIDs.insert(package.manifest.requestID.lowercased());return package.manifest
    }
    public static func verifyRetainedPackage(_ package:GaoActionReceivedPackage) throws {
        guard let originalClock=parseDate(package.manifest.createdAt) else {throw GaoActionError.invalidPackage("保留包创建时间无效")}
        let header=try inspectManifest(at:package.directory,now:originalClock,expectedTarget:package.manifest.targetBundleID)
        guard header.digest==package.manifestSHA256,header.manifest==package.manifest else {throw GaoActionError.invalidPackage("保留包 manifest 已改变，未接受结果")}
        var ids=Set<String>()
        _ = try validatePackageDirectory(at:package.directory,now:originalClock,knownIDs:&ids,expectedTarget:package.manifest.targetBundleID)
    }
    /// Open each component without following links, hold file descriptors and verify the received copy.
    public static func stagePackage(at url:URL,in stagingBase:URL,now:Date=Date(),expectedTarget:String=ownBundleID) throws -> GaoActionReceivedPackage {
        let parentFD = try GaoActionFiles.privateDirectory(stagingBase); close(parentFD)
        let destination=stagingBase.appendingPathComponent(UUID().uuidString+".gaoaction",isDirectory:true)
        do {
            let header=try inspectManifest(at:url,now:now,expectedTarget:expectedTarget)
            return try GaoActionStorageBudget.reserving(in:stagingBase,additionalBytes:header.manifest.items.reduce(UInt64(maximumManifestBytes)){$0+$1.byteCount}) {
                try readPackage(at:url,staging:destination,now:now,expectedTarget:expectedTarget)
            }
        }
        catch {try? FileManager.default.removeItem(at:destination);throw error}
    }
    private static func readPackage(at url:URL,staging:URL?,now:Date,expectedTarget:String?) throws -> GaoActionReceivedPackage {
        guard url.isFileURL,url.pathExtension.lowercased()==packageExtension else {throw GaoActionError.invalidPackage("请选择 .gaoaction 文档包")}
        let root=try GaoActionFiles.openPath(url,directory:true,owned:true);defer{close(root)}
        let rootInfo=try GaoActionFiles.info(root)
        let fd=openat(root,"manifest.json",O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC)
        guard fd>=0 else {throw GaoActionError.invalidPackage("无法读取 manifest.json")};defer{close(fd)}
        let data=try GaoActionFiles.read(fd:fd,maximum:maximumManifestBytes,owned:true)
        let m=try decodeManifest(data);try validateManifest(m,now:now,expectedTarget:expectedTarget)
        let payload=openat(root,"payload",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard payload>=0 else {throw GaoActionError.invalidPackage("缺少安全 payload 目录")};defer{close(payload)}
        try GaoActionFiles.check(try GaoActionFiles.info(payload),directory:true,owned:true)
        var stageFD:Int32 = -1
        defer { if stageFD >= 0 { close(stageFD) } }
        if let staging {
            stageFD=try GaoActionFiles.privateDirectory(staging)
            guard mkdirat(stageFD,"payload",0o700)==0 else {throw GaoActionError.invalidPackage("无法建立接收暂存目录")}
        }
        var files:[URL]=[],total:UInt64=0
        for item in m.items {
            let input=try GaoActionFiles.openRelative(item.relativePath,at:payload);defer{close(input)}
            let before=try GaoActionFiles.info(input);try GaoActionFiles.check(before,directory:false,owned:true)
            guard UInt64(before.st_size)==item.byteCount,item.byteCount<=defaultMaxPayloadBytes-total else {throw GaoActionError.sizeExceeded("附件尺寸不符或总载荷超过 2 GiB")};total += item.byteCount
            var output:Int32 = -1
            if let staging {
                let dest=staging.appendingPathComponent("payload").appendingPathComponent(item.relativePath)
                output=try GaoActionFiles.createRelative("payload/"+item.relativePath,at:stageFD);files.append(dest)
            }
            defer {if output>=0 {close(output)}}
            let copied=try GaoActionFiles.copy(fd:input,to:output>=0 ? output : nil,limit:item.byteCount,validateUTF8:m.kind == .request && ["documents.newText","text.translate"].contains(m.action))
            guard copied.bytes==item.byteCount,copied.hash==item.sha256 else {throw GaoActionError.invalidPackage("附件摘要不符或复制期间发生变化")}
        }
        for reference in m.references { _ = try verifyReference(reference) }
        guard GaoActionFiles.same(rootInfo,try GaoActionFiles.info(root)) else {throw GaoActionError.invalidPackage("接收期间包目录发生变化")}
        if stageFD>=0 {try GaoActionFiles.write(data,name:"manifest.json",at:stageFD)}
        return GaoActionReceivedPackage(manifest:m,directory:staging ?? GaoActionFiles.normalized(url),files:files,manifestSHA256:calculateSHA256(data:data))
    }
    public static func createRequestPackage(in baseDir:URL,action:String,targetBundleID:String,sourceBundleID:String=ownBundleID,parameters:[String:Any]=[:],inputFiles:[URL]=[],references:[GaoActionReference]=[],requestID:UUID=UUID(),now:Date=Date(),nonce:String?=nil) throws -> URL {
        let m=GaoActionManifest(kind:.request,requestID:requestID.uuidString,sourceBundleID:sourceBundleID,targetBundleID:targetBundleID,action:action,createdAt:formatDate(now),expiresAt:formatDate(now.addingTimeInterval(requestTTLSeconds)),nonce:try nonce ?? randomNonce(),references:references,parameters:parameters.mapValues(GaoActionAnyCodable.init))
        return try createBudgetedPackage(in:baseDir,manifest:m,inputFiles:inputFiles,now:now)
    }
    public static func createResultPackage(in baseDir:URL,request:GaoActionManifest,status:GaoActionStatus,provenance:[String:Any],inputFiles:[URL]=[],errorCode:String?=nil,now:Date=Date()) throws -> URL {
        let m=GaoActionManifest(kind:.result,requestID:UUID().uuidString,sourceBundleID:request.targetBundleID,targetBundleID:request.sourceBundleID,action:request.action,createdAt:formatDate(now),expiresAt:formatDate(now.addingTimeInterval(requestTTLSeconds)),nonce:try randomNonce(),inReplyTo:request.requestID,status:status,errorCode:errorCode,provenance:provenance.mapValues(GaoActionAnyCodable.init))
        return try createBudgetedPackage(in:baseDir,manifest:m,inputFiles:inputFiles,now:now)
    }
    private static func createBudgetedPackage(in base:URL,manifest:GaoActionManifest,inputFiles:[URL],now:Date) throws -> URL {
        var size=UInt64(maximumManifestBytes)
        for url in inputFiles {
            let fd=try GaoActionFiles.openRegular(url,owned:false);defer{close(fd)}
            let s=try GaoActionFiles.info(fd)
            guard UInt64(s.st_size)<=defaultMaxPayloadBytes,size<=defaultMaxPayloadBytes+UInt64(maximumManifestBytes)-UInt64(s.st_size) else {throw GaoActionError.sizeExceeded("总载荷超过 2 GiB")}
            size += UInt64(s.st_size)
        }
        return try GaoActionStorageBudget.reserving(in:base,additionalBytes:size) {try createPackage(in:base,manifest:manifest,inputFiles:inputFiles,now:now)}
    }
    private static func createPackage(in baseDir:URL,manifest original:GaoActionManifest,inputFiles:[URL],now:Date) throws -> URL {
        guard inputFiles.count<=maximumItems else {throw GaoActionError.sizeExceeded("最多 256 个普通文件")}
        let base=try GaoActionFiles.privateDirectory(baseDir);defer{close(base)}
        let name=original.requestID+".gaoaction",temporary=".preparing-"+UUID().uuidString
        guard mkdirat(base,temporary,0o700)==0 else {throw GaoActionError.invalidPackage("无法建立发件暂存")}
        let work=baseDir.appendingPathComponent(temporary,isDirectory:true)
        var committed=false;defer{if !committed {try? FileManager.default.removeItem(at:work)}}
        let root=try GaoActionFiles.openPath(work,directory:true,owned:true);defer{close(root)}
        guard mkdirat(root,"payload",0o700)==0 else {throw GaoActionError.invalidPackage("无法建立 payload")}
        var m=original,total:UInt64=0
        for (index,url) in inputFiles.enumerated() {
            let fd=try GaoActionFiles.openRegular(url,owned:false);defer{close(fd)}
            let s=try GaoActionFiles.info(fd)
            guard UInt64(s.st_size)<=defaultMaxPayloadBytes-total else {throw GaoActionError.sizeExceeded("总载荷超过 2 GiB")};total += UInt64(s.st_size)
            let relative="item-\(index+1)-"+url.lastPathComponent
            try safeRelativePath(relative)
            let output=try GaoActionFiles.createRelative("payload/"+relative,at:root);defer{close(output)}
            let copied=try GaoActionFiles.copy(fd:fd,to:output,limit:UInt64(s.st_size),validateUTF8:m.kind == .request && ["documents.newText","text.translate"].contains(m.action))
            let standard:[String:String] = ["txt":"public.plain-text","md":"net.daringfireball.markdown","markdown":"net.daringfireball.markdown","pdf":"com.adobe.pdf","png":"public.png","jpg":"public.jpeg","jpeg":"public.jpeg","tif":"public.tiff","tiff":"public.tiff","heic":"public.heic","gif":"com.compuserve.gif","bmp":"com.microsoft.bmp","webp":"org.webmproject.webp"]
            let type=standard[url.pathExtension.lowercased()] ?? (try? url.resourceValues(forKeys:[.contentTypeKey]))?.contentType?.identifier ?? UTType(filenameExtension:url.pathExtension)?.identifier ?? UTType.data.identifier
            m.items.append(.init(id:"item-\(index+1)",relativePath:relative,uti:type,byteCount:copied.bytes,sha256:copied.hash))
        }
        for r in m.references {_ = try verifyReference(r)}
        try validateManifest(m,now:now)
        let encoder=JSONEncoder();encoder.outputFormatting=[.sortedKeys,.prettyPrinted]
        let data=try encoder.encode(m)
        guard data.count<=maximumManifestBytes else {throw GaoActionError.sizeExceeded("manifest 超过 1 MiB")}
        // Manifest is written last, then the complete package is atomically published without overwriting.
        try GaoActionFiles.write(data,name:"manifest.json",at:root)
        guard fsync(root)==0,renameatx_np(base,temporary,base,name,UInt32(RENAME_EXCL))==0 else {throw GaoActionError.invalidPackage("不能提交包；已有同名请求或磁盘写入失败")}
        _ = fsync(base);committed=true;return baseDir.appendingPathComponent(name,isDirectory:true)
    }
}

public struct GaoActionReceivedPackage {
    public let manifest:GaoActionManifest
    public let directory:URL
    public let files:[URL]
    public let manifestSHA256:String
}

/// All external reads use fixed descriptors. Root aliases are the only symlinks normalized implicitly.
enum GaoActionFiles {
    static func normalized(_ url:URL)->URL {
        var path=url.path
        if path=="/tmp" || path.hasPrefix("/tmp/") || path=="/var" || path.hasPrefix("/var/") {path="/private"+path}
        return URL(fileURLWithPath:path,isDirectory:url.hasDirectoryPath)
    }
    static func info(_ fd:Int32) throws -> stat {var s=stat();guard fstat(fd,&s)==0 else {throw GaoActionError.invalidPackage("无法读取文件身份")};return s}
    static func check(_ s:stat,directory:Bool,owned:Bool) throws {
        guard s.st_mode & S_IFMT == (directory ? S_IFDIR : S_IFREG),directory || s.st_nlink==1,s.st_size>=0 else {throw GaoActionError.invalidPackage("拒绝链接、硬链接附件或非普通文件")}
        if owned {guard s.st_uid==getuid(),s.st_mode & 0o022==0,s.st_mode & S_IRUSR != 0 else {throw GaoActionError.invalidPackage("包属主、读取权限或写入权限不安全")}}
    }
    static func openPath(_ url:URL,directory:Bool?,owned:Bool) throws -> Int32 {
        guard url.isFileURL,!url.path.contains("\0"),url.path.hasPrefix("/") else {throw GaoActionError.invalidPackage("不是本机文件路径")}
        let path=normalized(url).path,parts=path.split(separator:"/").map(String.init)
        guard !parts.isEmpty,parts.allSatisfy({$0 != "." && $0 != ".."}) else {throw GaoActionError.invalidPackage("不能使用文件系统根或未规范化路径")}
        var current=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard current>=0 else {throw GaoActionError.invalidPackage("无法访问文件系统")}
        do {
            for (index,part) in parts.enumerated() {
                let isParent=index<parts.count-1
                let next=openat(current,part,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC|(isParent || directory == true ? O_DIRECTORY : 0))
                guard next>=0 else {throw GaoActionError.invalidPackage("路径不可读取或父级包含链接；请由接收方重新选择原件")}
                close(current);current=next
            }
            let s=try info(current)
            try check(s,directory:directory ?? (s.st_mode & S_IFMT == S_IFDIR),owned:owned)
            return current
        } catch {close(current);throw error}
    }
    static func openRegular(_ url:URL,owned:Bool) throws -> Int32 {try openPath(url,directory:false,owned:owned)}
    static func privateDirectory(_ url:URL) throws -> Int32 {
        guard url.isFileURL,!url.path.contains("\0") else {throw GaoActionError.invalidPackage("私有目录不是本机路径")}
        let parts=normalized(url).path.split(separator:"/").map(String.init)
        guard !parts.isEmpty,parts.allSatisfy({$0 != "." && $0 != ".."}) else {throw GaoActionError.invalidPackage("私有目录路径无效")}
        var current=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard current>=0 else {throw GaoActionError.invalidPackage("不能访问私有目录根")}
        do {
            for part in parts {
                if mkdirat(current,part,0o700) != 0,errno != EEXIST {throw GaoActionError.invalidPackage("无法建立私有目录")}
                let next=openat(current,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard next>=0 else {throw GaoActionError.invalidPackage("私有目录父级包含链接或不可读")}
                close(current);current=next
            }
            try check(try info(current),directory:true,owned:true)
            guard fchmod(current,0o700)==0 else {throw GaoActionError.invalidPackage("不能保护私有目录")}
            return current
        } catch {close(current);throw error}
    }
    static func openRelative(_ relative:String,at root:Int32) throws -> Int32 {
        try GaoActionV1.safeRelativePath(relative)
        let parts=relative.split(separator:"/").map(String.init)
        var current=dup(root)
        guard current>=0 else {throw GaoActionError.invalidPackage("无法固定 payload 目录")}
        do {
            for (i,part) in parts.enumerated() {
                let directory=i<parts.count-1
                let next=openat(current,part,O_RDONLY|O_NOFOLLOW|O_NONBLOCK|O_CLOEXEC|(directory ? O_DIRECTORY : 0))
                guard next>=0 else {throw GaoActionError.invalidPackage("附件缺失或路径包含链接")}
                close(current);current=next;try check(try info(current),directory:directory,owned:true)
            }
            return current
        } catch {close(current);throw error}
    }
    static func createRelative(_ relative:String,at root:Int32) throws -> Int32 {
        try GaoActionV1.safeRelativePath(relative)
        let parts=relative.split(separator:"/").map(String.init)
        var current=dup(root);defer{close(current)}
        guard current>=0 else {throw GaoActionError.invalidPackage("无法固定写入目录")}
        for part in parts.dropLast() {
            if mkdirat(current,part,0o700) != 0,errno != EEXIST {throw GaoActionError.invalidPackage("无法创建附件目录")}
            let next=openat(current,part,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
            guard next>=0 else {throw GaoActionError.invalidPackage("附件目录被替换")}
            close(current);current=next;try check(try info(current),directory:true,owned:true)
        }
        let fd=openat(current,parts.last!,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard fd>=0 else {throw GaoActionError.invalidPackage("附件已存在或不能写入")};return fd
    }
    static func same(_ a:stat,_ b:stat)->Bool {
        a.st_dev==b.st_dev && a.st_ino==b.st_ino && a.st_uid==b.st_uid && a.st_mode==b.st_mode && a.st_nlink==b.st_nlink && a.st_size==b.st_size && a.st_mtimespec.tv_sec==b.st_mtimespec.tv_sec && a.st_mtimespec.tv_nsec==b.st_mtimespec.tv_nsec && a.st_ctimespec.tv_sec==b.st_ctimespec.tv_sec && a.st_ctimespec.tv_nsec==b.st_ctimespec.tv_nsec
    }
    static func read(fd:Int32,maximum:Int,owned:Bool) throws -> Data {
        let before=try info(fd);try check(before,directory:false,owned:owned)
        guard before.st_size<=maximum else {throw GaoActionError.sizeExceeded("文件超过读取预算")}
        var result=Data(),buffer=[UInt8](repeating:0,count:65536)
        while true {
            let n=Darwin.read(fd,&buffer,min(buffer.count,maximum-result.count+1))
            if n<0 {if errno==EINTR {continue};throw GaoActionError.invalidPackage("读取中断")}
            if n==0 {break};guard n<=maximum-result.count else {throw GaoActionError.sizeExceeded("读取期间文件超过预算")};result.append(contentsOf:buffer.prefix(n))
        }
        guard same(before,try info(fd)),result.count==before.st_size else {throw GaoActionError.invalidPackage("读取期间内容发生变化")};return result
    }
    static func write(_ data:Data,name:String,at root:Int32) throws {
        let fd=try createRelative(name,at:root);defer{close(fd)}
        try data.withUnsafeBytes { raw in
            var offset=0
            while offset<data.count {
                let n=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),data.count-offset)
                if n<0,errno==EINTR {continue};guard n>0 else {throw GaoActionError.invalidPackage("写入失败")};offset += n
            }
        }
        guard fsync(fd)==0 else {throw GaoActionError.invalidPackage("写入未同步")}
    }
    static func copy(fd:Int32,to output:Int32?,limit:UInt64,validateUTF8:Bool=false,onChunk:((UInt64)->Void)?=nil) throws -> (hash:String,bytes:UInt64) {
        let before=try info(fd);try check(before,directory:false,owned:false)
        guard UInt64(before.st_size)<=limit,lseek(fd,0,SEEK_SET)>=0 else {throw GaoActionError.sizeExceeded("附件超过预算")}
        var hash=SHA256(),total:UInt64=0,buffer=[UInt8](repeating:0,count:65536)
        var utf8=GaoActionUTF8Validator()
        while true {
            let n=Darwin.read(fd,&buffer,buffer.count)
            if n<0 {if errno==EINTR {continue};throw GaoActionError.invalidPackage("附件读取失败")};if n==0 {break}
            guard UInt64(n)<=limit-total else {throw GaoActionError.sizeExceeded("读取期间载荷超限")};total += UInt64(n)
            let bytes=Data(buffer.prefix(n));hash.update(data:bytes)
            if validateUTF8,!utf8.consume(buffer.prefix(n)) {throw GaoActionError.invalidPackage("文本附件必须为有效 UTF-8")}
            onChunk?(total)
            if let output {
                try bytes.withUnsafeBytes { raw in
                    var offset=0
                    while offset<n {let written=Darwin.write(output,raw.baseAddress!.advanced(by:offset),n-offset);if written<0,errno==EINTR {continue};guard written>0 else {throw GaoActionError.invalidPackage("暂存写入失败或磁盘已满")};offset += written}
                }
            }
        }
        guard same(before,try info(fd)),total==UInt64(before.st_size) else {throw GaoActionError.invalidPackage("附件在复制期间改变")}
        if validateUTF8,!utf8.complete {throw GaoActionError.invalidPackage("文本附件必须为完整 UTF-8")}
        if let output {guard fsync(output)==0 else {throw GaoActionError.invalidPackage("附件暂存未同步")}}
        return (hash.finalize().map{String(format:"%02x",$0)}.joined(),total)
    }
    static func isUTF8(_ fd:Int32) throws -> Bool {
        guard lseek(fd,0,SEEK_SET)>=0 else {throw GaoActionError.invalidPackage("不能校验 UTF-8")}
        var continuation=0,scalar:UInt32=0,minimum:UInt32=0,buffer=[UInt8](repeating:0,count:65536)
        while true {
            let n=Darwin.read(fd,&buffer,buffer.count)
            if n<0 {if errno==EINTR {continue};throw GaoActionError.invalidPackage("文本读取失败")};if n==0 {return continuation==0}
            for b in buffer.prefix(n) {
                if continuation==0 {
                    if b<=0x7f {continue}
                    if (0xc2...0xdf).contains(b) {continuation=1;scalar=UInt32(b&0x1f);minimum=0x80}
                    else if (0xe0...0xef).contains(b) {continuation=2;scalar=UInt32(b&0x0f);minimum=0x800}
                    else if (0xf0...0xf4).contains(b) {continuation=3;scalar=UInt32(b&7);minimum=0x10000}
                    else {return false}
                } else {
                    guard b&0xc0==0x80 else {return false};scalar=(scalar<<6)|UInt32(b&0x3f);continuation -= 1
                    if continuation==0,(scalar<minimum || scalar>0x10ffff || (0xd800...0xdfff).contains(scalar)) {return false}
                }
            }
        }
    }
}


/// Retention is bounded without expiring or deleting unfinished work. The lock also bounds concurrent sends.
enum GaoActionStorageBudget {
    static let maximumRetainedBytes:UInt64 = 8*1024*1024*1024
    static let maximumPackages=128,maximumEntries=65536
    static func reserving<T>(in base:URL,additionalBytes:UInt64,_ operation:() throws -> T) throws -> T {
        guard ["Incoming","Outgoing"].contains(base.lastPathComponent),base.deletingLastPathComponent().lastPathComponent=="Exchange" else {return try operation()}
        let exchange=base.deletingLastPathComponent(),root=try GaoActionFiles.privateDirectory(exchange);defer{close(root)}
        let lock=openat(root,".budget.lock",O_RDWR|O_CREAT|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard lock>=0 else {throw GaoActionError.invalidPackage("无法取得交接储存锁")};defer{close(lock)}
        try GaoActionFiles.check(try GaoActionFiles.info(lock),directory:false,owned:true)
        guard flock(lock,LOCK_EX)==0 else {throw GaoActionError.invalidPackage("无法锁定交接储存预算")};defer{_ = flock(lock,LOCK_UN)}
        try check(exchange:exchange,additionalBytes:additionalBytes)
        return try operation()
    }
    static func check(exchange:URL,additionalBytes:UInt64,maximumBytes:UInt64=maximumRetainedBytes,maximumCount:Int=maximumPackages) throws {
        let fd=try GaoActionFiles.openPath(exchange,directory:true,owned:true);defer{close(fd)}
        var bytes:UInt64=0,packages=0,entries=0
        var enumerationError:Error?
        guard let enumerator=FileManager.default.enumerator(at:exchange,includingPropertiesForKeys:[.isSymbolicLinkKey,.isDirectoryKey],options:[],errorHandler:{_,error in enumerationError=error;return false}) else {throw GaoActionError.invalidPackage("无法核验交接储存目录")}
        for case let url as URL in enumerator {
            entries += 1;guard entries<=maximumEntries else {throw GaoActionError.sizeExceeded("交接留存条目已满，请在跨应用任务中手动核对")}
            let item=try GaoActionFiles.openPath(url,directory:nil,owned:true);defer{close(item)}
            let info=try GaoActionFiles.info(item)
            if info.st_mode & S_IFMT == S_IFDIR {
                if url.pathExtension==GaoActionV1.packageExtension || url.lastPathComponent.hasPrefix(".preparing-") {packages += 1}
            } else {
                guard UInt64(info.st_size)<=maximumBytes-bytes else {throw GaoActionError.sizeExceeded("交接留存空间已满，请手动复核；未清理未完成资料")};bytes += UInt64(info.st_size)
            }
        }
        if enumerationError != nil {throw GaoActionError.invalidPackage("交接目录不能完整读取，未按空目录处理")}
        guard packages<maximumCount,additionalBytes<=maximumBytes-bytes else {throw GaoActionError.sizeExceeded("交接留存已达 128 包或 8 GiB；请在跨应用任务中手动复核，未清理未完成资料")}
    }
}

private struct GaoActionUTF8Validator {
    private var remaining=0,scalar:UInt32=0,minimum:UInt32=0
    var complete:Bool {remaining==0}
    mutating func consume<S:Sequence>(_ bytes:S)->Bool where S.Element==UInt8 {
        for b in bytes {
            if remaining==0 {
                if b<=0x7f {continue}
                if (0xc2...0xdf).contains(b) {remaining=1;scalar=UInt32(b&0x1f);minimum=0x80}
                else if (0xe0...0xef).contains(b) {remaining=2;scalar=UInt32(b&0x0f);minimum=0x800}
                else if (0xf0...0xf4).contains(b) {remaining=3;scalar=UInt32(b&7);minimum=0x10000}
                else {return false}
            } else {
                guard b&0xc0==0x80 else {return false};scalar=(scalar<<6)|UInt32(b&0x3f);remaining -= 1
                if remaining==0,(scalar<minimum || scalar>0x10ffff || (0xd800...0xdfff).contains(scalar)) {return false}
            }
        }
        return true
    }
}
