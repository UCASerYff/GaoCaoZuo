import Foundation
import Darwin
@_silgen_name("gao_archive_caller_access") private func callerAccess(_ pid:pid_t,_ operation:UnsafePointer<CChar>,_ path:UnsafePointer<CChar>)->Int32

private final class BrokerStop:@unchecked Sendable {
    private let lock=NSLock();private var stopped=false
    func cancel(){lock.lock();stopped=true;lock.unlock()}
    func check()throws {lock.lock();let value=stopped;lock.unlock();if value {throw CancellationError()}}
}
@MainActor private final class BrokerJobs {
    static let shared=BrokerJobs()
    private var active:(owner:UUID,id:UUID,service:ArchiveService,stop:BrokerStop)?
    func cancel(owner:UUID,id:String?=nil) {
        guard let active,active.owner==owner,id==nil || active.id.uuidString==id else{return}
        active.stop.cancel();active.service.cancel()
    }
    func execute(_ bytes:Data,owner:UUID,callerPID:pid_t,requirement:String,host:URL,reply:@escaping(Data)->Void) async {
        var requestID=UUID(),backup:URL?
        do {
            guard active==nil,bytes.count<=1_024*1_024 else {throw ArchiveError.invalid(L10n.text("已有压缩任务正在运行，请等待或取消。"))}
            try QuickLookArchiveBrokerIdentity.verify(pid:callerPID,requirement:requirement)
            let envelope=try JSONDecoder().decode(QuickLookArchiveBrokerEnvelope.self,from:bytes)
            let request=envelope.request;requestID=request.requestID
            guard envelope.archiveBookmark.count<=64*1024,envelope.addingBookmarks.count==request.adding.count,request.adding.count<=64,
                  envelope.addingBookmarks.allSatisfy({$0.count<=64*1024}),(envelope.directoryBookmark?.count ?? 0)<=64*1024 else {throw CocoaError(.fileReadTooLarge)}
            var resources:[URL]=[]
            defer {resources.forEach{$0.stopAccessingSecurityScopedResource()}}
            func resolve(_ data:Data,expected:URL)throws->URL {
                var stale=false
                let url=try URL(resolvingBookmarkData:data,options:.withoutUI,relativeTo:nil,bookmarkDataIsStale:&stale)
                _=url.startAccessingSecurityScopedResource();resources.append(url)
                guard !stale,url.isFileURL,url.standardizedFileURL.resolvingSymlinksInPath()==expected.standardizedFileURL.resolvingSymlinksInPath() else {throw CocoaError(.fileReadNoPermission)}
                return url
            }
            _=try resolve(envelope.archiveBookmark,expected:request.archive)
            if request.kind == .saveOriginal {
                guard let data=envelope.directoryBookmark else {throw CocoaError(.fileWriteNoPermission)}
                _=try resolve(data,expected:request.archive.deletingLastPathComponent())
            } else {guard request.adding.isEmpty,request.removing.isEmpty,!request.removeHidden else {throw CocoaError(.fileReadCorruptFile)}}
            for (bookmark,url) in zip(envelope.addingBookmarks,request.adding) {_=try resolve(bookmark,expected:url)}
            func allowed(_ operation:String,_ url:URL)->Bool {
                operation.withCString{op in url.resolvingSymlinksInPath().path.withCString{callerAccess(callerPID,op,$0) != 0}}
            }
            // The broker is trusted and has its own file permissions. Require
            // the sandboxed caller's actual selected-file/parent scope too;
            // an unprivileged path-only bookmark cannot confer broker authority.
            guard allowed("file-read-data",request.archive),request.adding.allSatisfy({allowed("file-read-data",$0)}) else {throw CocoaError(.fileReadNoPermission)}
            if request.kind == .saveOriginal {
                // sandbox_check canonicalizes an existing object; a future
                // filename reports denied even for an unrestricted process.
                let parent=request.archive.deletingLastPathComponent()
                guard allowed("file-write-data",request.archive),allowed("file-write-create",parent) else {throw CocoaError(.fileWriteNoPermission)}
            }
            let fm=FileManager.default,job=fm.temporaryDirectory.appendingPathComponent("GaoQuickLook-"+UUID().uuidString+".noindex",isDirectory:true)
            try fm.createDirectory(at:job,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:job)}
            let runtime=host.appendingPathComponent("Contents/Resources/Tools",isDirectory:true)
            let service=ArchiveService(engineURL:runtime.appendingPathComponent("7zz")),stop=BrokerStop()
            service.executionScope=try ArchiveExecutionScope(workspace:job,runtime:runtime)
            let support=fm.urls(for:.applicationSupportDirectory,in:.userDomainMask)[0]
            let backups=support.appendingPathComponent("GaoSeries/GaoCaoZuo/QuickLookArchiveBackups",isDirectory:true)
            backup=backups.appendingPathComponent(requestID.uuidString+"."+request.archive.pathExtension)
            active=(owner,requestID,service,stop);defer {active=nil}
            let result=try await QuickLookArchiveEditBackend.perform(request,service:service,backupDirectory:backups,checkCancellation:{try stop.check()})
            respond(result,reply:reply)
        }catch {
            let saved=backup.flatMap{FileManager.default.fileExists(atPath:$0.path) ? $0:nil}
            respond(.init(requestID:requestID,status:error is CancellationError ? "cancelled":"failed",backup:saved,message:error.localizedDescription),reply:reply)
        }
    }
    private func respond(_ value:QuickLookArchiveEditResponse,reply:(Data)->Void) {
        var value=value;value.helperPID=getpid();value.helperParentPID=getppid()
        guard let data=try? JSONEncoder().encode(value),data.count<=8*1_024*1_024 else {reply(Data());return};reply(data)
    }
}
private final class BrokerSession:NSObject,GaoQuickLookArchiveBrokerProtocol {
    let owner=UUID(),pid:pid_t,requirement:String,host:URL
    init(pid:pid_t,requirement:String,host:URL){self.pid=pid;self.requirement=requirement;self.host=host}
    func execute(_ payload:Data,reply:@escaping(Data)->Void) {Task{@MainActor in await BrokerJobs.shared.execute(payload,owner:owner,callerPID:pid,requirement:requirement,host:host,reply:reply)}}
    func cancel(_ requestID:String,reply:@escaping()->Void) {Task{@MainActor in BrokerJobs.shared.cancel(owner:owner,id:requestID);reply()}}
}
private final class BrokerDelegate:NSObject,NSXPCListenerDelegate {
    let requirement:String,host:URL
    init(requirement:String,host:URL){self.requirement=requirement;self.host=host}
    func listener(_ listener:NSXPCListener,shouldAcceptNewConnection connection:NSXPCConnection)->Bool {
        guard connection.effectiveUserIdentifier==getuid() else{return false}
        let session=BrokerSession(pid:connection.processIdentifier,requirement:requirement,host:host)
        connection.setCodeSigningRequirement(requirement)
        connection.exportedInterface=NSXPCInterface(with:GaoQuickLookArchiveBrokerProtocol.self);connection.exportedObject=session
        connection.invalidationHandler={Task{@MainActor in BrokerJobs.shared.cancel(owner:session.owner)}}
        connection.resume();return true
    }
}
@main enum QuickLookArchiveBrokerMain {
    static func main() {
        do {
            let client=Bundle.main.bundleURL.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            let host=client.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            guard client.pathExtension=="appex",host.pathExtension=="app",
                  Bundle(url:client)?.bundleIdentifier=="com.gaoseries.GaoCaoZuo.QuickLook",
                  Bundle(url:host)?.bundleIdentifier=="com.gaoseries.GaoCaoZuo",
                  host.standardizedFileURL.resolvingSymlinksInPath().path=="/Applications/搞操作.app" else {exit(1)}
            let delegate=BrokerDelegate(requirement:try QuickLookArchiveBrokerIdentity.requirement(for:client),host:host)
            let listener=NSXPCListener.service();listener.delegate=delegate
            withExtendedLifetime(delegate){listener.resume()}
        }catch {exit(1)}
    }
}
