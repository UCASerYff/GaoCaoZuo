import AppKit
import Foundation
import Darwin
import SwiftUI
import CoreFoundation

struct GaoActionProviderCapabilities: Decodable {
    struct Action: Decodable {
        var action:String
        var parametersSchema:[String:GaoActionAnyCodable]
        var supportsReferences:Bool?
        var supportsItems:Bool?
        var referencesSchema:[String:GaoActionAnyCodable]?
        var requiresUserConfirmation:Bool?
        var reviewOnly:Bool?
        private enum CodingKeys:String,CodingKey {
            case action,parametersSchema,parameters,supportsReferences,supportsItems,referencesSchema,requiresUserConfirmation,reviewOnly,items,references
        }
        init(from decoder:Decoder) throws {
            let c=try decoder.container(keyedBy:CodingKeys.self)
            action=try c.decode(String.self,forKey:.action)
            supportsReferences=try c.decodeIfPresent(Bool.self,forKey:.supportsReferences)
            supportsItems=try c.decodeIfPresent(Bool.self,forKey:.supportsItems)
            referencesSchema=try c.decodeIfPresent([String:GaoActionAnyCodable].self,forKey:.referencesSchema)
            requiresUserConfirmation=try c.decodeIfPresent(Bool.self,forKey:.requiresUserConfirmation)
            reviewOnly=try c.decodeIfPresent(Bool.self,forKey:.reviewOnly)
            guard c.contains(.parametersSchema) != c.contains(.parameters) else {
                throw GaoActionError.providerNotReady("参数能力必须使用一种明确的 schema 形状")
            }
            if c.contains(.parametersSchema) {
                guard !c.contains(.items),!c.contains(.references) else {throw GaoActionError.providerNotReady("不接受混合的能力约束形状")}
                parametersSchema=try c.decode([String:GaoActionAnyCodable].self,forKey:.parametersSchema)
            } else {
                // GaoXiaZai V1 declares the same JSON schema as `parameters`.
                // This adapter covers only its explicit zero-payload contract.
                guard action == "downloads.prepare",supportsItems != true,supportsReferences != true,referencesSchema == nil else {
                    throw GaoActionError.providerNotReady("尚不支持此动作的 parameters 能力形状")
                }
                for key in [CodingKeys.items,.references] {
                    let limit=try c.decode([String:GaoActionAnyCodable].self,forKey:key)
                    guard Set(limit.keys)==["maxCount"],let n=limit["maxCount"]?.value as? NSNumber,
                          CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue==0 else {
                        throw GaoActionError.providerNotReady("下载准备能力必须明确禁止文件与引用")
                    }
                }
                parametersSchema=try c.decode([String:GaoActionAnyCodable].self,forKey:.parameters)
                supportsItems=false;supportsReferences=false
            }
        }
    }
    var schemaVersion:Int
    var bundleID:String
    var appVersion:String
    var actions:[Action]
    static func load(appURL:URL,bundleID:String) throws -> Self {
        let infoFD=try GaoActionFiles.openRegular(appURL.appendingPathComponent("Contents/Info.plist"),owned:false);defer{close(infoFD)}
        let infoData=try GaoActionFiles.read(fd:infoFD,maximum:1_048_576,owned:false)
        guard let info=try PropertyListSerialization.propertyList(from:infoData,format:nil) as? [String:Any],
              info["CFBundleIdentifier"] as? String == bundleID,
              let version=info["CFBundleShortVersionString"] as? String,!version.isEmpty else {throw GaoActionError.providerNotReady("安装应用的标识或版本无效")}
        let url=appURL.appendingPathComponent("Contents/Resources/GaoCapabilities.json")
        let fd=try GaoActionFiles.openRegular(url,owned:false);defer{close(fd)}
        let data=try GaoActionFiles.read(fd:fd,maximum:GaoActionV1.maximumManifestBytes,owned:false)
        let capabilities=try JSONDecoder().decode(Self.self,from:data)
        guard capabilities.schemaVersion==1,capabilities.bundleID==bundleID,capabilities.appVersion==version,
              capabilities.actions.count<=GaoActionV1.knownActions.count,
              Set(capabilities.actions.map(\.action)).count==capabilities.actions.count else {throw GaoActionError.providerNotReady("能力表 schema、应用标识或版本不匹配")}
        for a in capabilities.actions {
            guard GaoActionV1.knownActions.contains(a.action),GaoActionV1.owners[a.action]==nil || GaoActionV1.owners[a.action]==bundleID,
                  a.parametersSchema["type"]?.value as? String == "object",
                  a.parametersSchema["additionalProperties"]?.value as? Bool == false,
                  let props=a.parametersSchema["properties"]?.value as? [String:Any],
                  Set(props.keys).isSubset(of:GaoActionV1.parameterKeys[a.action] ?? []) else {throw GaoActionError.providerNotReady("提供方声明了不兼容动作或参数 schema")}
            try GaoActionParameterSchema.validateDefinition(a.parametersSchema.mapValues(\.value))
            if let references=a.referencesSchema {try GaoActionParameterSchema.validateDefinition(references.mapValues(\.value))}
        }
        return capabilities
    }
    func require(action:String,parameters:[String:Any],items:Bool,references:Bool) throws {
        guard let capability=actions.first(where:{$0.action==action}) else {throw GaoActionError.providerNotReady(L10n.format("目标应用尚未声明实现 %@", String(describing: (action))))}
        guard (!items || capability.supportsItems != false),(!references || capability.supportsReferences != false),
              let properties=capability.parametersSchema["properties"]?.value as? [String:Any],Set(parameters.keys).isSubset(of:Set(properties.keys)) else {throw GaoActionError.providerNotReady("提供方未声明本次附件、引用或可选参数")}
        try GaoActionParameterSchema.validate(parameters,schema:capability.parametersSchema.mapValues(\.value))
        if action == "downloads.prepare" {
            guard !items,!references,let urls=parameters["urls"] as? [String],(1...32).contains(urls.count),urls.allSatisfy(GaoActionV1.safeHTTP) else {
                throw GaoActionError.providerNotReady("下载准备只接受固定契约允许的 http/https URL，不接受文件或引用")
            }
        }
    }
    func requireInputs(action:String,parameters:[String:Any],items:Bool,references:[GaoActionReference]) throws {
        try require(action:action,parameters:parameters,items:items,references:!references.isEmpty)
        guard let capability=actions.first(where:{$0.action==action}),let schema=capability.referencesSchema else {return}
        let values=try references.map { reference -> [String:Any] in
            guard let value=try JSONSerialization.jsonObject(with:JSONEncoder().encode(reference)) as? [String:Any] else {
                throw GaoActionError.providerNotReady("无法核验提供方引用约束")
            }
            return value
        }
        try GaoActionParameterSchema.validate(values,schema:schema.mapValues(\.value))
    }
}

enum GaoActionJournalState:String,Codable {
    case prepared, dispatched, received, approved, executing, completed, interrupted
}
struct GaoActionJournalRecord:Codable {
    var schemaVersion=1
    var direction:String
    var manifest:GaoActionManifest
    var manifestSHA256:String
    var packageDirectory:String
    var state:GaoActionJournalState
    var businessStatus:GaoActionStatus?
    var resultIDs:[String]=[]
    var updatedAt:String
}

/// A durable per-request journal; unreadable or changed records fail closed and are never recreated as empty.
final class GaoActionJournal {
    let data:LocalData
    init(directory:URL) throws {
        data=LocalData(directory:directory)
        if let failure=data.failure {throw GaoActionError.invalidPackage(failure)}
    }
    private func name(_ id:String,direction:String) throws -> String {
        guard UUID(uuidString:id) != nil,["out","in"].contains(direction) else {throw GaoActionError.invalidPackage("journal 标识无效")}
        return direction+"-"+id.lowercased()+".json"
    }
    func record(_ id:String,direction:String) throws -> GaoActionJournalRecord? {
        let r=try data.load(try name(id,direction:direction),as:GaoActionJournalRecord.self)
        if let r {guard r.schemaVersion==1,r.direction==direction,r.manifest.requestID.caseInsensitiveCompare(id) == .orderedSame else {throw GaoActionError.invalidPackage("journal 内容不一致")}}
        return r
    }
    func save(_ record:GaoActionJournalRecord) throws {try data.save(record,name:name(record.manifest.requestID,direction:record.direction))}
    @discardableResult func prepare(manifest:GaoActionManifest,package:URL,digest:String,now:Date=Date()) throws -> GaoActionJournalRecord {
        guard try record(manifest.requestID,direction:"out")==nil else {throw GaoActionError.duplicateRequest(manifest.requestID)}
        let r=GaoActionJournalRecord(direction:"out",manifest:manifest,manifestSHA256:digest,packageDirectory:package.path,state:.prepared,updatedAt:GaoActionV1.formatDate(now))
        try save(r);return r
    }
    func transition(_ id:String,direction:String,to state:GaoActionJournalState,now:Date=Date()) throws {
        guard var r=try record(id,direction:direction) else {throw GaoActionError.invalidPackage("journal 记录缺失")}
        let allowed:[GaoActionJournalState:Set<GaoActionJournalState>]=[
            .prepared:[.dispatched],.dispatched:[.received],.received:[.approved,.completed],.approved:[.executing],.executing:[.completed,.interrupted],.interrupted:[],.completed:[]
        ]
        guard allowed[r.state]?.contains(state)==true else {throw GaoActionError.invalidPackage("journal 拒绝重复或不安全状态迁移")}
        r.state=state;r.updatedAt=GaoActionV1.formatDate(now);try save(r)
    }
    enum Reception {case new,duplicate(GaoActionJournalRecord)}
    func preflight(_ m:GaoActionManifest,digest:String) throws -> Reception {
        if let old=try record(m.requestID,direction:"in") {
            guard old.manifestSHA256==digest else {throw GaoActionError.invalidPackage("相同 requestID 的内容改变，拒绝覆盖原记录")}
            return .duplicate(old)
        }
        guard m.kind == .result,let reply=m.inReplyTo,let original=try record(reply,direction:"out"),
              original.manifest.action==m.action,original.manifest.targetBundleID==m.sourceBundleID,
              original.manifest.sourceBundleID==m.targetBundleID else {throw GaoActionError.invalidPackage("结果没有匹配的本App原请求，或提供方/动作不匹配")}
        if let status=original.businessStatus,[GaoActionStatus.completed,.partial,.cancelled,.failed,.unsupported].contains(status) {throw GaoActionError.invalidPackage("原请求已有终态；新结果需人工核对，未自动替换")}
        try validateProvenance(m,original:original.manifest)
        return .new
    }
    func receive(_ package:GaoActionReceivedPackage,now:Date=Date()) throws -> Reception {
        let m=package.manifest
        let reception=try preflight(m,digest:package.manifestSHA256)
        if case .duplicate=reception {return reception}
        let r=GaoActionJournalRecord(direction:"in",manifest:m,manifestSHA256:package.manifestSHA256,packageDirectory:package.directory.path,state:.received,businessStatus:m.status,updatedAt:GaoActionV1.formatDate(now))
        try save(r);return .new
    }
    func history() throws -> [GaoActionJournalRecord] {
        let files=try FileManager.default.contentsOfDirectory(at:data.directory,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json"}
        guard files.count<=2048 else {throw GaoActionError.sizeExceeded("交接记录过多，请保留原资料并手动核对")}
        var records:[GaoActionJournalRecord]=[]
        for url in files {
            let parts=url.deletingPathExtension().lastPathComponent.split(separator:"-",maxSplits:1)
            guard parts.count==2,["in","out"].contains(String(parts[0])) else {throw GaoActionError.invalidPackage("交接记录目录包含未知 JSON，未忽略")}
            if let r=try record(String(parts[1]),direction:String(parts[0])) {records.append(r)}
        }
        return records.sorted{$0.updatedAt>$1.updatedAt}
    }
    private func validateProvenance(_ result:GaoActionManifest,original:GaoActionManifest) throws {
        let p=result.provenance?.mapValues(\.value) ?? [:]
        func check(_ value:Any) throws {
            if let d=value as? [String:Any] {
                if d["sourceItemID"] != nil || d["sourceSHA256"] != nil {
                    guard let id=d["sourceItemID"] as? String,let hash=d["sourceSHA256"] as? String,
                          original.items.contains(where:{$0.id==id && $0.sha256==hash}) else {throw GaoActionError.invalidPackage("结果来源附件标识或摘要不匹配")}
                }
                for v in d.values {try check(v)}
            } else if let a=value as? [Any] {for v in a {try check(v)}}
        }
        try check(p)
        if result.action=="ocr.files",let status=result.status,[GaoActionStatus.completed,.partial].contains(status) {
            var sourceIDs=Set<String>(),outputIDs=Set<String>()
            func collect(_ value:Any) {
                if let d=value as? [String:Any] {
                    if let id=d["sourceItemID"] as? String {sourceIDs.insert(id);if let output=d["itemID"] as? String ?? d["resultItemID"] as? String {outputIDs.insert(output)}}
                    for v in d.values {collect(v)}
                } else if let a=value as? [Any] {for v in a {collect(v)}}
            }
            collect(p)
            guard sourceIDs==Set(original.items.map(\.id)),result.items.isEmpty || (original.items.count==1 && p["sourceItemID"] != nil) || Set(result.items.map(\.id)).isSubset(of:outputIDs) else {throw GaoActionError.invalidPackage("OCR 结果缺少逐输入/输出来源关联")}
        }
    }
    func acceptResult(_ id:String,now:Date=Date()) throws {
        guard let r=try record(id,direction:"in"),r.state == .received,let reply=r.manifest.inReplyTo,
              var original=try record(reply,direction:"out") else {throw GaoActionError.invalidPackage("结果未处于待确认状态")}
        try transition(id,direction:"in",to:.approved,now:now)
        // The executing marker is persisted before any exposure/use of outputs. A crash cannot replay a side effect.
        try transition(id,direction:"in",to:.executing,now:now)
        original.businessStatus=r.manifest.status;original.resultIDs.append(id);original.updatedAt=GaoActionV1.formatDate(now)
        if r.manifest.status != .pending {original.state = .completed}
        else {original.state = .received}
        try save(original);try transition(id,direction:"in",to:.completed,now:now)
    }
    func recoverInterruptedRecords() throws -> Int {
        let names=try FileManager.default.contentsOfDirectory(at:data.directory,includingPropertiesForKeys:nil).filter{$0.pathExtension=="json" && $0.lastPathComponent.hasPrefix("in-")}
        guard names.count<=10000 else {throw GaoActionError.sizeExceeded("交接记录过多，保留并停止自动恢复")}
        var count=0
        for url in names {
            let id=String(url.deletingPathExtension().lastPathComponent.dropFirst(3))
            if var r=try record(id,direction:"in"),[.approved,.executing].contains(r.state) {
                r.state = .interrupted;r.updatedAt=GaoActionV1.formatDate(Date());try save(r);count += 1
            }
        }
        return count
    }
}

@MainActor public final class GaoActionClient {
    public let dataDirectory:URL
    private var journalCache:GaoActionJournal?
    private var historyWindow:NSWindow?
    public init(dataDirectory:URL) {self.dataDirectory=dataDirectory}
    public var outgoingDirectory:URL {dataDirectory.appendingPathComponent("Exchange/Outgoing",isDirectory:true)}
    public var incomingDirectory:URL {dataDirectory.appendingPathComponent("Exchange/Incoming",isDirectory:true)}
    private func journal() throws -> GaoActionJournal {
        if let journalCache {return journalCache}
        let j=try GaoActionJournal(directory:dataDirectory.appendingPathComponent("Exchange/Journal",isDirectory:true))
        _ = try j.recoverInterruptedRecords();journalCache=j;return j
    }
    public func providerURL(bundleID:String,action:String,parameters:[String:Any]=[:],items:Bool=false,references:Bool=false) throws -> URL {
        guard let app=NSWorkspace.shared.urlForApplication(withBundleIdentifier:bundleID) else {throw GaoActionError.providerNotReady(L10n.format("未安装 %@；本次动作未执行", String(describing: (bundleID))))}
        do {try GaoActionProviderCapabilities.load(appURL:app,bundleID:bundleID).require(action:action,parameters:parameters,items:items,references:references)}
        catch {throw GaoActionError.providerNotReady(L10n.format("%@ 的能力表未就绪或不兼容；本次动作未执行（%@）", String(describing: (bundleID)), String(describing: (error.localizedDescription))))}
        return app
    }
    public func isProviderAvailable(bundleID:String,action:String) -> Bool {(try? providerURL(bundleID:bundleID,action:action)) != nil}
    public func exportRequest(action:String,targetBundleID:String,parameters:[String:Any]=[:],inputFiles:[URL]=[],references:[GaoActionReference]=[]) async throws -> URL {
        let operation=GaoActionActivity.shared.begin();defer {GaoActionActivity.shared.end(operation)}
        let outgoing=outgoingDirectory
        let url=try await Task.detached(priority:.userInitiated) {try GaoActionV1.createRequestPackage(in:outgoing,action:action,targetBundleID:targetBundleID,parameters:parameters,inputFiles:inputFiles,references:references)}.value
        let fd=try GaoActionFiles.openRegular(url.appendingPathComponent("manifest.json"),owned:true);defer{close(fd)}
        let data=try GaoActionFiles.read(fd:fd,maximum:GaoActionV1.maximumManifestBytes,owned:true)
        let manifest=try GaoActionV1.decodeManifest(data)
        try journal().prepare(manifest:manifest,package:url,digest:GaoActionV1.calculateSHA256(data:data))
        return url
    }
    public func sendRequest(action:String,targetBundleID:String,parameters:[String:Any]=[:],inputFiles:[URL]=[],references:[GaoActionReference]=[]) async throws -> URL {
        let operation=GaoActionActivity.shared.begin();defer {GaoActionActivity.shared.end(operation)}
        let app=try providerURL(bundleID:targetBundleID,action:action,parameters:parameters,items:!inputFiles.isEmpty,references:!references.isEmpty)
        try GaoActionProviderCapabilities.load(appURL:app,bundleID:targetBundleID).requireInputs(action:action,parameters:parameters,items:!inputFiles.isEmpty,references:references)
        let package=try await exportRequest(action:action,targetBundleID:targetBundleID,parameters:parameters,inputFiles:inputFiles,references:references)
        try await dispatch(package:package,app:app)
        return package
    }
    private func dispatch(package:URL,app:URL) async throws {
        // Packaging is asynchronous and a retained request can be resent much
        // later. Recheck the current provider against the actual new manifest
        // at this common final gate, including referencesSchema.
        let header=try GaoActionV1.inspectManifest(at:package)
        let manifest=header.manifest
        try GaoActionProviderCapabilities.load(appURL:app,bundleID:manifest.targetBundleID).requireInputs(
            action:manifest.action,parameters:manifest.parameters.mapValues(\.value),items:!manifest.items.isEmpty,references:manifest.references)
        let config=NSWorkspace.OpenConfiguration();config.activates=true;config.allowsRunningApplicationSubstitution=false
        let id=package.deletingPathExtension().lastPathComponent
        try journal().transition(id,direction:"out",to:.dispatched)
        _ = try await withCheckedThrowingContinuation { (continuation:CheckedContinuation<NSRunningApplication,Error>) in
            NSWorkspace.shared.open([package],withApplicationAt:app,configuration:config) { app,error in
                if let error {continuation.resume(throwing:error)}
                else if let app {continuation.resume(returning:app)}
                else {continuation.resume(throwing:GaoActionError.providerNotReady("未能递交文档包"))}
            }
        }
        // LaunchServices success means only that the document delivery was accepted.
    }
    public func receivePackage(_ url:URL,notify:@escaping (String,Bool)->Void) async {
        let operation=GaoActionActivity.shared.begin();defer {GaoActionActivity.shared.end(operation)}
        var created:GaoActionReceivedPackage?,retained=false
        defer {if let created,!retained {discardNewStage(created)}}
        do {
            let header=try await Task.detached {try GaoActionV1.inspectManifest(at:url,expectedTarget:GaoActionV1.ownBundleID)}.value
            let j=try journal()
            if case .duplicate(let old)=try j.preflight(header.manifest,digest:header.digest) {
                notify(L10n.format("该结果已接收：%@；未重复处理。", String(describing: (old.businessStatus?.rawValue ?? old.state.rawValue))),false)
                showHistory();return
            }
            let destination=incomingDirectory
            let package=try await Task.detached(priority:.userInitiated) {try GaoActionV1.stagePackage(at:url,in:destination)}.value
            created=package
            guard package.manifestSHA256==header.digest else {throw GaoActionError.invalidPackage("校验与复制之间 manifest 改变，拒绝处理")}
            if case .duplicate(let old)=try j.receive(package) {
                notify(L10n.format("该结果已接收：%@；未重复处理。", String(describing: (old.businessStatus?.rawValue ?? old.state.rawValue))),false);showHistory();return
            }
            retained=true
            try await confirm(package,notify:notify)
        } catch {notify(error.localizedDescription,true)}
    }
    private func discardNewStage(_ package:GaoActionReceivedPackage) {
        let url=GaoActionFiles.normalized(package.directory)
        guard url.deletingLastPathComponent().path==GaoActionFiles.normalized(incomingDirectory).path,
              UUID(uuidString:url.deletingPathExtension().lastPathComponent) != nil,url.pathExtension==GaoActionV1.packageExtension else {return}
        // This is solely the newly created, unaccepted receiver copy. Source/other-App packages are untouched.
        try? FileManager.default.removeItem(at:url)
    }
    private func confirm(_ package:GaoActionReceivedPackage,notify:@escaping (String,Bool)->Void) async throws {
        let m=package.manifest
        NSApp.activate(ignoringOtherApps:true)
        let alert=NSAlert();alert.messageText=L10n.text("接收跨应用结果")
        alert.informativeText=L10n.text("动作")+"：\(m.action)\n"+L10n.text("提供方声明")+"：\(m.sourceBundleID)\n"+L10n.text("提供方报告状态")+"：\(m.status!.rawValue)\n"+L10n.text("附件")+"：\(m.items.count) / \(m.items.reduce(UInt64(0)){$0+$1.byteCount}) bytes\n\n"+L10n.text("来源声明与 nonce 不证明发送者身份。附件已复制到本App私有暂存；接受不会覆盖原件或自动执行附件。")
        let names=m.items.map{"• \($0.relativePath) (\($0.byteCount) bytes)"}+m.references.map{"• \($0.displayName) [\($0.kind.rawValue)]"}
        if !names.isEmpty {alert.informativeText += "\n\n"+names.joined(separator:"\n")}
        alert.addButton(withTitle:L10n.text("接受并显示副本"));alert.addButton(withTitle:L10n.text("保留待核对"))
        guard alert.runModal() == .alertFirstButtonReturn else {notify("结果保留待核对，原件未改变。",false);return}
        // The modal may remain open for a long time. Revalidate the retained bytes after the user's choice.
        try await Task.detached(priority:.userInitiated) {try GaoActionV1.verifyRetainedPackage(package)}.value
        try journal().acceptResult(m.requestID)
        if !package.files.isEmpty {NSWorkspace.shared.activateFileViewerSelecting(package.files)}
        notify(L10n.format("已接收结果；提供方报告 %@。", String(describing: (m.status!.rawValue))),false)
    }
    func history() throws -> [GaoActionJournalRecord] {try journal().history()}
    func acceptDeferred(_ r:GaoActionJournalRecord,notify:@escaping (String,Bool)->Void) async throws {
        let operation=GaoActionActivity.shared.begin();defer {GaoActionActivity.shared.end(operation)}
        guard r.direction=="in",r.state == .received,let receptionClock=GaoActionV1.parseDate(r.manifest.createdAt) else {throw GaoActionError.invalidPackage("结果不处于待核对状态")}
        let url=URL(fileURLWithPath:r.packageDirectory,isDirectory:true)
        let verified=try await Task.detached {() throws -> GaoActionReceivedPackage in
            // TTL was enforced on initial reception. Deferred confirmation rechecks the retained bytes and identity.
            let header=try GaoActionV1.inspectManifest(at:url,now:receptionClock,expectedTarget:GaoActionV1.ownBundleID)
            guard header.digest==r.manifestSHA256 else {throw GaoActionError.invalidPackage("保留结果已改变，停止处理")}
            var ids=Set<String>();_ = try GaoActionV1.validatePackageDirectory(at:url,now:receptionClock,knownIDs:&ids,expectedTarget:GaoActionV1.ownBundleID)
            return .init(manifest:header.manifest,directory:url,files:header.manifest.items.map{url.appendingPathComponent("payload/"+$0.relativePath)},manifestSHA256:header.digest)
        }.value
        try await confirm(verified,notify:notify)
    }
    func resend(_ r:GaoActionJournalRecord) async throws {
        let operation=GaoActionActivity.shared.begin();defer {GaoActionActivity.shared.end(operation)}
        guard r.direction=="out",r.businessStatus==nil || r.businessStatus == .pending else {throw GaoActionError.invalidPackage("仅未完成请求可显式重新递交")}
        let m=r.manifest,parameters=m.parameters.mapValues(\.value)
        let app=try providerURL(bundleID:m.targetBundleID,action:m.action,parameters:parameters,items:!m.items.isEmpty,references:!m.references.isEmpty)
        try GaoActionProviderCapabilities.load(appURL:app,bundleID:m.targetBundleID).requireInputs(action:m.action,parameters:parameters,items:!m.items.isEmpty,references:m.references)
        let url=URL(fileURLWithPath:r.packageDirectory,isDirectory:true)
        var ids=Set<String>()
        let old=try GaoActionV1.inspectManifest(at:url,now:GaoActionV1.parseDate(m.createdAt)!,expectedTarget:m.targetBundleID)
        guard old.digest==r.manifestSHA256,old.manifest==m else {throw GaoActionError.invalidPackage("原请求保留包已改变，未重新递交")}
        _ = try GaoActionV1.validatePackageDirectory(at:url,now:GaoActionV1.parseDate(m.createdAt)!,knownIDs:&ids,expectedTarget:m.targetBundleID)
        let new=try await exportRequest(action:m.action,targetBundleID:m.targetBundleID,parameters:parameters,inputFiles:m.items.map{url.appendingPathComponent("payload/"+$0.relativePath)},references:m.references)
        let header=try GaoActionV1.inspectManifest(at:new,expectedTarget:m.targetBundleID)
        guard header.manifest.items.map(\.sha256)==m.items.map(\.sha256) else {throw GaoActionError.invalidPackage("重递交副本与原请求摘要不一致；未交给提供方")}
        try await dispatch(package:new,app:app)
    }
    public func showHistory() {
        if historyWindow==nil {
            let window=NSWindow(contentRect:NSRect(x:0,y:0,width:820,height:580),styleMask:[.titled,.closable,.resizable,.miniaturizable],backing:.buffered,defer:false)
            window.title=L10n.text("跨应用任务");window.isReleasedWhenClosed=false;window.center();historyWindow=window
        }
        historyWindow?.contentView=NSHostingView(rootView:GaoLocalizedContent{GaoActionHistoryView(client:self)})
        historyWindow?.makeKeyAndOrderFront(nil);NSApp.activate(ignoringOtherApps:true)
    }
}

@MainActor private struct GaoActionHistoryView:View {
    let client:GaoActionClient
    @State private var records:[GaoActionJournalRecord]=[]
    @State private var message=""
    @State private var busy=false
    private func refresh() {do {records=try client.history()}catch{message=error.localizedDescription}}
    var body:some View {
        VStack(alignment:.leading,spacing:12) {
            Text("跨应用任务").font(.title2.bold())
            Text("递交只表示提供方收到打开请求；实际状态来自关联结果。来源声明不是身份认证。未完成副本不会按时间自动删除。").font(.caption).foregroundStyle(.secondary)
            HStack {Button("刷新"){refresh()};Button("在 Finder 显示交接目录"){NSWorkspace.shared.activateFileViewerSelecting([client.outgoingDirectory.deletingLastPathComponent()])};Spacer()}
            if records.isEmpty {Text("暂无跨应用任务").foregroundStyle(.secondary)}
            ScrollView {
                LazyVStack(alignment:.leading,spacing:10) {
                    ForEach(records,id:\.packageDirectory) {r in
                        VStack(alignment:.leading,spacing:5) {
                            HStack {Text(r.manifest.action).bold();Spacer();Text((r.direction=="out" ? "→ " : "← ")+(r.direction=="out" ? r.manifest.targetBundleID : r.manifest.sourceBundleID)).font(.caption)}
                            Text("\(r.state.rawValue) / \(r.businessStatus?.rawValue ?? "awaitingResult") · \(r.updatedAt)").font(.caption).foregroundStyle(.secondary)
                            Text(r.manifest.requestID).font(.caption2.monospaced()).textSelection(.enabled)
                            HStack {
                                Button("在 Finder 显示私有包"){NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath:r.packageDirectory)])}
                                if r.direction=="in",r.state == .received {
                                    Button("核对并接受结果"){run{try await client.acceptDeferred(r){value,_ in message=value}}}.disabled(busy)
                                }
                                if r.direction=="out",r.businessStatus==nil || r.businessStatus == .pending {
                                    Button("重新递交副本…") {
                                        let alert=NSAlert();alert.messageText=L10n.text("重新递交跨应用动作")
                                        alert.informativeText="\(r.manifest.action) → \(r.manifest.targetBundleID)\n\n"+L10n.text("这会建立一个新的请求。原请求可能仍在提供方运行；请先核对提供方状态，避免重复业务。引用原件会重新校验，附件只使用本App保留副本。")
                                        alert.addButton(withTitle:L10n.text("建立并递交新请求"));alert.addButton(withTitle:L10n.text("取消"))
                                        if alert.runModal() == .alertFirstButtonReturn {run{try await client.resend(r);message="已重新递交，等待提供方确认与结果。"}}
                                    }.disabled(busy)
                                }
                            }
                        }.padding(10).background(Color.secondary.opacity(0.07),in:RoundedRectangle(cornerRadius:8))
                    }
                }
            }
            if !message.isEmpty {Text(L10n.text(message)).font(.caption).textSelection(.enabled)}
        }.padding(18).frame(minWidth:760,minHeight:500).onAppear{refresh()}
    }
    private func run(_ action:@escaping @MainActor () async throws -> Void) {
        busy=true;Task{@MainActor in do{try await action()}catch{message=error.localizedDescription};busy=false;refresh()}
    }
}

private enum GaoActionParameterSchema {
    private static let metadata:Set<String>=["type","const","enum","description","title","default"]
    static func validateDefinition(_ schema:[String:Any],depth:Int=0) throws {
        func invalid() -> GaoActionError {.providerNotReady("提供方能力 schema 的约束无效或不受支持")}
        guard depth<=8 else {throw invalid()}
        for key in ["description","title"] where schema[key] != nil {guard schema[key] is String else {throw invalid()}}
        guard let type=schema["type"] as? String else {
            guard schema["const"] != nil,Set(schema.keys).isSubset(of:["const","description","title"]) else {throw invalid()};return
        }
        let extra:[String:Set<String>]=[
            "object":["properties","required","additionalProperties"],"array":["items","minItems","maxItems"],
            "string":["minLength","maxLength","pattern","format"],"number":["minimum","maximum"],"integer":["minimum","maximum"],"boolean":[]]
        guard let keys=extra[type],Set(schema.keys).isSubset(of:metadata.union(keys)) else {throw invalid()}
        func bound(_ key:String,integer:Bool)->Double? {
            guard let n=schema[key] as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite else {return nil}
            if integer {guard let count=n as? Int,count>=0,Double(count)==n.doubleValue else {return nil}}
            return n.doubleValue
        }
        for pair in [("minLength","maxLength"),("minItems","maxItems"),("minimum","maximum")] {
            let integer=pair.0 != "minimum"
            for key in [pair.0,pair.1] where schema[key] != nil {guard bound(key,integer:integer) != nil else {throw invalid()}}
            if let min=bound(pair.0,integer:integer),let max=bound(pair.1,integer:integer),min>max {throw invalid()}
        }
        if let values=schema["enum"] {guard let array=values as? [Any],!array.isEmpty,array.count<=256 else {throw invalid()}}
        if type == "object" {
            guard let props=schema["properties"] as? [String:Any],props.count<=256 else {throw invalid()}
            if let required=schema["required"] {
                guard let names=required as? [String],Set(names).count==names.count,Set(names).isSubset(of:Set(props.keys)) else {throw invalid()}
            }
            if let additional=schema["additionalProperties"] {guard let n=additional as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {throw invalid()}}
            for child in props.values {guard let child=child as? [String:Any] else {throw invalid()};try validateDefinition(child,depth:depth+1)}
        } else if type == "array" {
            if let n=schema["items"] as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() {}
            else {guard let child=schema["items"] as? [String:Any] else {throw invalid()};try validateDefinition(child,depth:depth+1)}
        } else if type == "string" {
            if let format=schema["format"] {guard format as? String == "uri" else {throw invalid()}}
            if let pattern=schema["pattern"] {
                guard let pattern=pattern as? String,pattern.utf8.count<=1024,(try? NSRegularExpression(pattern:pattern)) != nil else {throw invalid()}
            }
        }
    }
    static func validate(_ value:Any,schema:[String:Any],depth:Int=0) throws {
        func invalid() -> GaoActionError {.providerNotReady("本次参数不符合提供方能力 schema")}
        guard depth<=8 else {throw invalid()}
        if depth==0 {try validateDefinition(schema)}
        if let constant=schema["const"],GaoActionAnyCodable(value) != GaoActionAnyCodable(constant) {throw invalid()}
        if let values=schema["enum"] as? [Any],!values.contains(where:{GaoActionAnyCodable(value)==GaoActionAnyCodable($0)}) {throw invalid()}
        // V1 supports this explicit subset, rather than silently ignoring a
        // provider's new validation vocabulary and dispatching incompatible data.
        let supported:Set<String>=["type","const","enum","minimum","maximum","minLength","maxLength","pattern","format","minItems","maxItems","items","properties","required","additionalProperties","description","title","default"]
        guard Set(schema.keys).isSubset(of:supported) else {throw GaoActionError.providerNotReady("提供方使用了尚未支持的能力约束")}
        guard let type=schema["type"] as? String else {
            guard schema["const"] != nil,Set(schema.keys).isSubset(of:["const","description","title"]) else {throw GaoActionError.providerNotReady("提供方参数 schema 缺少类型")}
            return
        }
        switch type {
        case "string":
            guard let s=value as? String else {throw invalid()}
            if let max=schema["maxLength"] as? Int,s.count>max {throw invalid()}
            if let min=schema["minLength"] as? Int,s.count<min {throw invalid()}
            if let values=schema["enum"] as? [String],!values.contains(s) {throw invalid()}
            if let pattern=schema["pattern"] as? String {guard pattern.utf8.count<=1024,s.range(of:pattern,options:.regularExpression) != nil else {throw invalid()}}
            if schema["format"] as? String == "uri" {
                guard !s.isEmpty,!s.unicodeScalars.contains(where:{CharacterSet.whitespacesAndNewlines.union(.controlCharacters).contains($0)}),
                      let components=URLComponents(string:s),components.scheme?.isEmpty==false,components.url != nil else {throw invalid()}
            }
        case "number","integer":
            guard let n=value as? NSNumber,CFGetTypeID(n) != CFBooleanGetTypeID(),n.doubleValue.isFinite,type != "integer" || floor(n.doubleValue)==n.doubleValue else {throw invalid()}
            if let max=schema["maximum"] as? Double,n.doubleValue>max {throw invalid()}
            if let min=schema["minimum"] as? Double,n.doubleValue<min {throw invalid()}
        case "boolean":guard let n=value as? NSNumber,CFGetTypeID(n)==CFBooleanGetTypeID() else {throw invalid()}
        case "array":
            guard let a=value as? [Any] else {throw invalid()}
            if let max=schema["maxItems"] as? Int,a.count>max {throw invalid()}
            if let min=schema["minItems"] as? Int,a.count<min {throw invalid()}
            if let boolean=schema["items"] as? Bool {
                guard boolean || a.isEmpty else {throw invalid()};return
            }
            guard let item=schema["items"] as? [String:Any] else {throw invalid()}
            for value in a {try validate(value,schema:item,depth:depth+1)}
        case "object":
            guard let object=value as? [String:Any],let properties=schema["properties"] as? [String:Any] else {throw invalid()}
            if let required=schema["required"] as? [String],!Set(required).isSubset(of:Set(object.keys)) {throw invalid()}
            if schema["additionalProperties"] as? Bool == false,!Set(object.keys).isSubset(of:Set(properties.keys)) {throw invalid()}
            for (key,value) in object where properties[key] != nil {
                guard let child=properties[key] as? [String:Any] else {throw invalid()}
                try validate(value,schema:child,depth:depth+1)
            }
        default:throw GaoActionError.providerNotReady("提供方使用了不支持的参数 schema 类型")
        }
    }
}
