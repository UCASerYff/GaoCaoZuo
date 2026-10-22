import Foundation
import Darwin

final class InputCloudCancellation:@unchecked Sendable {
    private let lock=NSLock()
    private var cancelled=false
    private var coordinator:NSFileCoordinator?
    private let deadline=Date().addingTimeInterval(15)
    init() {DispatchQueue.global(qos:.utility).asyncAfter(deadline:.now()+15){[weak self] in self?.cancel()}}
    func cancel() {lock.lock();cancelled=true;let active=coordinator;lock.unlock();active?.cancel()}
    func check() throws {lock.lock();let failed=cancelled || Date()>deadline;lock.unlock();if failed {throw DataFailure.message("iCloud 文件协调超时或已取消；本机和远端版本保留。")}}
    func using<T>(_ coordinator:NSFileCoordinator,_ body:()throws->T) throws -> T {
        try check();lock.lock();self.coordinator=coordinator;let stopped=cancelled;lock.unlock()
        defer {lock.lock();self.coordinator=nil;lock.unlock()}
        if stopped {coordinator.cancel()};try check();return try body()
    }
}

/// Only immutable revision files in one anchored directory are accessed. Every
/// path component is opened without following links; reads/writes use its FD.
/// File coordination is still used, on a detached I/O task, for iCloud itself.
final class InputCloudTransport:@unchecked Sendable {
    let root:URL
    let namespace:String
    private let selected:URL
    private let selectedFD:Int32
    private let rootFD:Int32
    private let selectedIdentity:ArchiveVolumeEvidenceStore.Identity
    private let rootIdentity:ArchiveVolumeEvidenceStore.Identity
    private let scoped:Bool
    init(configuration:InputEnhancementConfiguration,cancellation:InputCloudCancellation) throws {
        var selectedURL=URL(fileURLWithPath:configuration.iCloudSyncFolder,isDirectory:true)
        if let bookmark=configuration.iCloudSyncBookmark {
            var stale=false
            let resolved=try URL(resolvingBookmarkData:bookmark,options:[.withSecurityScope,.withoutUI],relativeTo:nil,bookmarkDataIsStale:&stale)
            guard !stale,resolved.standardizedFileURL.path==selectedURL.standardizedFileURL.path else {throw DataFailure.message("iCloud 文件夹授权已变化，请重新选择；本机规则保留。")}
            selectedURL=resolved
        }
        let didScope=selectedURL.startAccessingSecurityScopedResource()
        let parent:Int32
        do {parent=try Self.openDirectory(selectedURL.path)}catch {if didScope {selectedURL.stopAccessingSecurityScopedResource()};throw error}
        var child:Int32 = -1,success=false
        defer {if !success {close(parent);if child>=0 {close(child)};if didScope {selectedURL.stopAccessingSecurityScopedResource()}}}
        let values=try selectedURL.resourceValues(forKeys:[.isDirectoryKey,.isUbiquitousItemKey])
        guard values.isDirectory==true,values.isUbiquitousItem==true else {throw DataFailure.message("请选择真实的 iCloud Drive 文件夹；普通交换文件夹不能开启自动同步。")}
        let parentIdentity=try Self.identity(parent)
        let folder=selectedURL.appendingPathComponent("搞操作输入规则",isDirectory:true)
        var coordinationError:NSError?,failure:Error?
        let coordinator=NSFileCoordinator()
        try cancellation.using(coordinator) {
            coordinator.coordinate(writingItemAt:folder,options:[],error:&coordinationError) {url in
                do {
                    try cancellation.check()
                    guard url.standardizedFileURL==folder.standardizedFileURL else {throw DataFailure.message("iCloud 同步目录在协调期间移动，未写入。")}
                    if mkdirat(parent,"搞操作输入规则",0o700) != 0 && errno != EEXIST {throw Self.posix()}
                    child=openat(parent,"搞操作输入规则",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                    guard child>=0 else {throw Self.posix()}
                }catch {failure=error}
            }
        }
        if let error=coordinationError ?? (failure as NSError?) {throw error}
        guard child>=0 else {throw DataFailure.message("iCloud 同步目录尚不可用，未写入。")}
        let childIdentity=try Self.identity(child),current=try Self.openDirectory(selectedURL.path)
        defer {close(current)}
        let currentChild=openat(current,"搞操作输入规则",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard currentChild>=0 else {throw Self.posix()};defer {close(currentChild)}
        guard Self.sameNode(try Self.identity(current),parentIdentity),Self.sameNode(try Self.identity(currentChild),childIdentity) else {throw DataFailure.message("iCloud 同步目录身份已变化，未继续读写。")}
        selected=selectedURL;scoped=didScope;selectedFD=parent;rootFD=child
        selectedIdentity=parentIdentity;rootIdentity=childIdentity;root=folder
        namespace=folder.path+"|\(childIdentity.device)|\(childIdentity.inode)"
        success=true
    }
    deinit {close(rootFD);close(selectedFD);if scoped {selected.stopAccessingSecurityScopedResource()}}
    private static func posix()->NSError {NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    private static func identity(_ fd:Int32)throws->ArchiveVolumeEvidenceStore.Identity {var s=stat();guard fstat(fd,&s)==0 else {throw posix()};return .init(s)}
    private static func sameNode(_ a:ArchiveVolumeEvidenceStore.Identity,_ b:ArchiveVolumeEvidenceStore.Identity)->Bool {a.device==b.device && a.inode==b.inode}
    private static func validID(_ id:String)->Bool {id.count==64 && id.allSatisfy{$0.isHexDigit && !$0.isUppercase}}
    static func openDirectory(_ path:String)throws->Int32 {
        guard path.hasPrefix("/"),!path.contains("\0") else {throw DataFailure.message("iCloud 同步目录路径无效。")}
        let canonical=URL(fileURLWithPath:path).standardizedFileURL.path
        var fd=open("/",O_RDONLY|O_DIRECTORY|O_CLOEXEC)
        guard fd>=0 else {throw posix()}
        do {
            for component in canonical.split(separator:"/") {
                let next=openat(fd,String(component),O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
                guard next>=0 else {throw posix()};close(fd);fd=next
            }
            return fd
        }catch {close(fd);throw error}
    }
    func ensureCurrent() throws {
        let actual=try Self.openDirectory(selected.path);defer {close(actual)}
        let child=openat(actual,"搞操作输入规则",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard child>=0 else {throw Self.posix()};defer {close(child)}
        guard Self.sameNode(try Self.identity(actual),selectedIdentity),Self.sameNode(try Self.identity(child),rootIdentity) else {throw DataFailure.message("iCloud 同步目录身份已变化，未继续读写。")}
    }
    private func names(cancellation:InputCloudCancellation)throws->[String] {
        try ensureCurrent();try cancellation.check()
        let duplicate=openat(rootFD,".",O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC);guard duplicate>=0 else {throw Self.posix()}
        guard let directory=fdopendir(duplicate) else {close(duplicate);throw Self.posix()};defer {closedir(directory)}
        var names:[String]=[]
        while let pointer=readdir(directory) {
            try cancellation.check()
            let name=withUnsafePointer(to:&pointer.pointee.d_name){ptr in ptr.withMemoryRebound(to:CChar.self,capacity:256){String(cString:$0)}}
            if name != "." && name != ".." {names.append(name)}
            guard names.count<=8192 else {throw DataFailure.message("iCloud 同步版本超过保护预算；历史版本已保留。")}
        }
        try ensureCurrent();return names
    }
    private func bytes(_ name:String,cancellation:InputCloudCancellation)throws->Data {
        try cancellation.check();try ensureCurrent()
        guard !name.contains("/"),name != ".",name != ".." else {throw DataFailure.message("iCloud 版本名称无效。")}
        let fd=openat(rootFD,name,O_RDONLY|O_CLOEXEC|O_NOFOLLOW|O_NONBLOCK);guard fd>=0 else {throw Self.posix()};defer {close(fd)}
        var s=stat();guard fstat(fd,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_nlink==1,s.st_size>=0,s.st_size<=2_000_000 else {throw DataFailure.message("iCloud 同步版本不是有界普通文件。")}
        let before=ArchiveVolumeEvidenceStore.Identity(s)
        var result=Data(),buffer=[UInt8](repeating:0,count:65536)
        while true {
            try cancellation.check();let count=Darwin.read(fd,&buffer,buffer.count)
            if count<0 && errno==EINTR {continue}
            guard count>=0,count<=2_000_000-result.count else {throw DataFailure.message("iCloud 同步读取失败或超出预算。")}
            if count==0 {break};result.append(contentsOf:buffer.prefix(count))
        }
        var named=stat()
        guard try Self.identity(fd)==before,fstatat(rootFD,name,&named,AT_SYMLINK_NOFOLLOW)==0,ArchiveVolumeEvidenceStore.Identity(named)==before else {throw DataFailure.message("iCloud 版本在读取期间变化，未应用。")}
        try ensureCurrent();return result
    }
    func read(cancellation:InputCloudCancellation)throws->[String:InputCloudRevision] {
        var result:[String:InputCloudRevision]=[:],total=0
        for name in try names(cancellation:cancellation) {
            if name.hasPrefix("."),name.hasSuffix(".json.icloud") {
                let original=String(name.dropFirst().dropLast(7))
                let stem=String(original.dropLast(5))
                if stem.count==64,stem.allSatisfy(\.isHexDigit) {try FileManager.default.startDownloadingUbiquitousItem(at:root.appendingPathComponent(original));throw DataFailure.message("iCloud 同步版本尚未下载完整；保留本机内容，稍后自动重试。")}
            }
            guard name.hasSuffix(".json") else {continue}
            let id=String(name.dropLast(5))
            guard Self.validID(id) else {continue}
            var payload:Data?,coordinationError:NSError?,failure:Error?
            let coordinator=NSFileCoordinator(),url=root.appendingPathComponent(name)
            try cancellation.using(coordinator) {
                coordinator.coordinate(readingItemAt:url,options:.withoutChanges,error:&coordinationError) {coordinated in
                    do {guard coordinated.standardizedFileURL==url.standardizedFileURL else {throw DataFailure.message("iCloud 版本在协调期间移动，未读取。")};payload=try bytes(name,cancellation:cancellation)}catch {failure=error}
                }
            }
            if let error=coordinationError ?? (failure as NSError?) {throw error}
            guard let payload else {throw DataFailure.message("iCloud 同步文件尚未就绪，稍后自动重试。")}
            total += payload.count;guard total<=64*1_024*1_024,result.count<4096 else {throw DataFailure.message("iCloud 同步版本超过保护预算；历史版本已保留。")}
            let value=try JSONDecoder().decode(InputCloudRevision.self,from:payload)
            guard value.schema==1,value.configuration==value.configuration.cloudPayload,value.parents.count<=4096,Set(value.parents).count==value.parents.count,try value.digest==id else {throw DataFailure.message("iCloud 同步版本摘要或格式无效，本机内容保留。")}
            result[id]=value
        }
        return result
    }
    func publish(_ revision:InputCloudRevision,cancellation:InputCloudCancellation)throws->String {
        try cancellation.check()
        guard revision.schema==1,revision.configuration==revision.configuration.cloudPayload,
              revision.parents.count<=4096,Set(revision.parents).count==revision.parents.count,
              revision.parents.allSatisfy(Self.validID) else {throw DataFailure.message("iCloud 待发布版本无效或包含本机授权资料，未上传。")}
        try EnhancedInputValidation.validate(revision.configuration)
        // Never publish a child whose parent is unavailable, replaced or only a
        // placeholder. This also protects callers besides the live controller.
        for parent in revision.parents {
            let value=try JSONDecoder().decode(InputCloudRevision.self,from:bytes(parent+".json",cancellation:cancellation))
            guard value.schema==1,value.configuration==value.configuration.cloudPayload,
                  value.parents.count<=4096,Set(value.parents).count==value.parents.count,value.parents.allSatisfy(Self.validID),
                  try value.digest==parent else {throw DataFailure.message("iCloud 父版本摘要或格式已变化，停止发布；历史版本保留。")}
        }
        let payload=try revision.encoded,id=try revision.digest,name=id+".json",url=root.appendingPathComponent(id+".json")
        guard payload.count<=2_000_000 else {throw DataFailure.message("iCloud 规则版本超过2MB，本机内容保留。")}
        let coordinator=NSFileCoordinator();var coordinationError:NSError?,failure:Error?
        try cancellation.using(coordinator) {
            coordinator.coordinate(writingItemAt:url,options:[],error:&coordinationError) {coordinated in
                do {
                    try cancellation.check();try ensureCurrent()
                    guard coordinated.standardizedFileURL==url.standardizedFileURL else {throw DataFailure.message("iCloud 版本在协调期间移动，未写入。")}
                    var existing=stat()
                    if fstatat(rootFD,name,&existing,AT_SYMLINK_NOFOLLOW)==0 {
                        guard try bytes(name,cancellation:cancellation)==payload else {throw DataFailure.message("iCloud 版本路径被其他内容占用，未覆盖。")};return
                    }
                    guard errno==ENOENT else {throw Self.posix()}
                    let temporary=".tmp-"+UUID().uuidString
                    let fd=openat(rootFD,temporary,O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
                    guard fd>=0 else {throw Self.posix()}
                    let created=try Self.identity(fd)
                    defer {
                        var named=stat()
                        if fstatat(rootFD,temporary,&named,AT_SYMLINK_NOFOLLOW)==0,Self.sameNode(ArchiveVolumeEvidenceStore.Identity(named),created) {_ = unlinkat(rootFD,temporary,0)}
                        close(fd)
                    }
                    try payload.withUnsafeBytes {raw in
                        var offset=0
                        while offset<raw.count {try cancellation.check();let count=Darwin.write(fd,raw.baseAddress!.advanced(by:offset),raw.count-offset);if count<0 && errno==EINTR {continue};guard count>0 else {throw Self.posix()};offset += count}
                    }
                    guard fsync(fd)==0 else {throw Self.posix()};try cancellation.check();try ensureCurrent()
                    guard renameatx_np(rootFD,temporary,rootFD,name,UInt32(RENAME_EXCL))==0 else {throw Self.posix()}
                    _ = fsync(rootFD);try ensureCurrent()
                }catch {failure=error}
            }
        }
        if let error=coordinationError ?? (failure as NSError?) {throw error};return id
    }
    func uploaded(_ ids:[String],cancellation:InputCloudCancellation)throws->Bool {
        try ensureCurrent();var uploaded=true
        for id in ids {
            try cancellation.check()
            guard Self.validID(id) else {throw DataFailure.message("iCloud 版本名称无效。")}
            let value=try root.appendingPathComponent(id+".json").resourceValues(forKeys:[.ubiquitousItemIsUploadedKey,.ubiquitousItemUploadingErrorKey])
            if let error=value.ubiquitousItemUploadingError {throw error};uploaded = uploaded && value.ubiquitousItemIsUploaded==true
        }
        try ensureCurrent();return uploaded
    }
}
