import Foundation
import CryptoKit
import Darwin

/// The trusted broker alone commits a verified private result. Decoders never
/// receive the original directory. RENAME_SWAP retains the displaced inode;
/// a durable pre-swap receipt and a frozen backup survive interruption.
enum ArchiveOriginalCommit {
    struct Receipt:Codable {
        var schema=1;var requestID:UUID;var state:String
        var original:URL;var backup:URL;var displaced:URL
        var originalSHA256:String;var resultSHA256:String
        var originalIdentity:QuickLookArchiveIdentity?=nil;var resultIdentity:QuickLookArchiveIdentity?=nil
    }
    struct Result {var backup:URL;var displaced:URL;var sha256:String}
    private static func failure(_ text:String)->Error {ArchiveError.invalid(L10n.text(text))}
    private static func posix()->Error {NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    private static func identity(_ s:stat)->QuickLookArchiveIdentity {
        .init(device:s.st_dev,inode:s.st_ino,bytes:s.st_size,modified:Int64(s.st_mtimespec.tv_sec),modifiedNS:Int64(s.st_mtimespec.tv_nsec),changed:Int64(s.st_ctimespec.tv_sec),changedNS:Int64(s.st_ctimespec.tv_nsec))
    }
    static func digest(_ fd:Int32)throws->String {
        var hash=SHA256(),offset:off_t=0,buffer=[UInt8](repeating:0,count:65536)
        while true {
            let count=pread(fd,&buffer,buffer.count,offset)
            if count<0 {if errno==EINTR {continue};throw posix()}
            if count==0 {break};offset += off_t(count)
            guard offset<=128*1_024*1_024 else {throw failure("压缩包超过原位保存预算。")}
            hash.update(data:Data(buffer.prefix(count)))
        }
        return hash.finalize().map{String(format:"%02x",$0)}.joined()
    }
    static func copyRegular(_ source:URL,to destination:URL,expected:QuickLookArchiveIdentity?=nil,sha256:String?=nil)throws {
        let input=open(source.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard input>=0 else {throw posix()};defer {close(input)}
        var before=stat();guard fstat(input,&before)==0,before.st_mode&S_IFMT==S_IFREG,before.st_nlink==1,before.st_size<=128*1_024*1_024 else {throw failure("只能处理已核验的普通文件，原件保留。")}
        if let expected {guard identity(before)==expected else {throw failure("压缩包在编辑期间发生变化，未保存到原包。")}}
        let output=open(destination.path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600)
        guard output>=0 else {throw posix()};defer {close(output)}
        guard fcopyfile(input,output,nil,copyfile_flags_t(COPYFILE_ALL))==0,fsync(output)==0 else {throw posix()}
        var after=stat();guard fstat(input,&after)==0,identity(before)==identity(after),try QuickLookArchiveIdentity(url:source)==identity(before),try digest(input)==digest(output) else {throw failure("文件在准备期间发生变化，原件保留。")}
        if let sha256 {guard try digest(output)==sha256 else {throw failure("压缩包在编辑期间发生变化，未保存到原包。")}}
    }
    private static func metadata(_ fd:Int32)throws->(mode:mode_t,uid:uid_t,gid:gid_t,flags:UInt32,xattrs:[String:Data],acl:String) {
        var info=stat();guard fstat(fd,&info)==0 else {throw posix()}
        let length=flistxattr(fd,nil,0,0);guard length>=0,length<=1_048_576 else {throw failure("无法安全保留原包的扩展属性。")}
        var names=[CChar](repeating:0,count:max(1,length));guard flistxattr(fd,&names,length,0)==length else {throw posix()}
        let pieces=Data(names.prefix(length).map{UInt8(bitPattern:$0)}).split(separator:0)
        var values:[String:Data]=[:],total=0
        for part in pieces {
            guard let name=String(data:Data(part),encoding:.utf8) else {throw failure("无法安全保留原包的扩展属性。")}
            let size=fgetxattr(fd,name,nil,0,0,0);guard size>=0,size<=1_048_576-total else {throw failure("无法安全保留原包的扩展属性。")};total += size
            var data=Data(count:size)
            let count=data.withUnsafeMutableBytes{fgetxattr(fd,name,$0.baseAddress,size,0,0)}
            guard count==size else {throw posix()};values[name]=data
        }
        var aclText=""
        if let acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED) {
            defer {acl_free(UnsafeMutableRawPointer(acl))}
            var count:ssize_t=0
            guard let text=acl_to_text(acl,&count) else {throw posix()};defer {acl_free(UnsafeMutableRawPointer(text))}
            aclText=String(cString:text)
        } else if errno != ENOENT {throw posix()}
        return (info.st_mode&0o7777,info.st_uid,info.st_gid,info.st_flags,values,aclText)
    }
    static func commit(original:URL,expected:QuickLookArchiveIdentity,sha256:String,candidate:URL,backupDirectory:URL,requestID:UUID,checkCancellation:()throws->Void={},observer:((String)throws->Void)?=nil)throws->Result {
        let fm=FileManager.default,parent=original.deletingLastPathComponent().resolvingSymlinksInPath()
        let directory=open(parent.path,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard directory>=0 else {throw posix()};defer {close(directory)}
        var parentInfo=stat();guard fstat(directory,&parentInfo)==0 else {throw posix()}
        let name=original.lastPathComponent
        let source=openat(directory,name,O_RDWR|O_NOFOLLOW|O_CLOEXEC|O_NONBLOCK)
        guard source>=0 else {throw posix()};defer {close(source)}
        func validate()throws {
            var current=stat(),path=stat(),p=stat()
            guard fstat(source,&current)==0,fstatat(directory,name,&path,AT_SYMLINK_NOFOLLOW)==0,lstat(parent.path,&p)==0,
                  p.st_dev==parentInfo.st_dev,p.st_ino==parentInfo.st_ino,
                  current.st_mode&S_IFMT==S_IFREG,current.st_nlink==1,current.st_uid==getuid(),
                  current.st_flags & UInt32(UF_IMMUTABLE|SF_IMMUTABLE|UF_APPEND|SF_APPEND)==0,
                  identity(current)==expected,identity(path)==expected,try digest(source)==sha256 else {throw failure("压缩包在编辑期间发生变化，未保存到原包。")}
        }
        try validate();try checkCancellation()
        let recoveryName=".gaocaozuo-archive-recovery-"+requestID.uuidString+".noindex"
        guard mkdirat(directory,recoveryName,0o700)==0 else {throw posix()}
        let recovery=parent.appendingPathComponent(recoveryName,isDirectory:true)
        var retainRecovery=false
        let recoveryFD=openat(directory,recoveryName,O_RDONLY|O_DIRECTORY|O_NOFOLLOW|O_CLOEXEC)
        guard recoveryFD>=0 else {throw posix()};defer {close(recoveryFD)}
        let displaced=recovery.appendingPathComponent("original."+original.pathExtension)
        defer {
            if !retainRecovery {
                // Only the one private candidate is disposable. Never recurse
                // through a path that another process could have replaced.
                _=unlinkat(recoveryFD,displaced.lastPathComponent,0)
                var opened=stat(),current=stat()
                if fstat(recoveryFD,&opened)==0,fstatat(directory,recoveryName,&current,AT_SYMLINK_NOFOLLOW)==0,opened.st_dev==current.st_dev,opened.st_ino==current.st_ino {_=unlinkat(directory,recoveryName,AT_REMOVEDIR)}
            }
        }
        try copyRegular(candidate,to:displaced)
        let replacement=openat(recoveryFD,displaced.lastPathComponent,O_RDWR|O_NOFOLLOW|O_CLOEXEC)
        guard replacement>=0 else {throw posix()};defer {close(replacement)}
        let resultHash=try digest(replacement),oldMetadata=try metadata(source)
        guard fcopyfile(source,replacement,nil,copyfile_flags_t(COPYFILE_METADATA))==0,fsync(replacement)==0 else {throw posix()}
        let preserved=try metadata(replacement)
        guard oldMetadata.mode==preserved.mode,oldMetadata.uid==preserved.uid,oldMetadata.gid==preserved.gid,oldMetadata.flags==preserved.flags,oldMetadata.xattrs==preserved.xattrs,oldMetadata.acl==preserved.acl,try digest(replacement)==resultHash else {throw failure("未能完整保留原包权限或扩展属性，原包未改变。")}
        try fm.createDirectory(at:backupDirectory,withIntermediateDirectories:true,attributes:[.posixPermissions:0o700])
        let backup=backupDirectory.appendingPathComponent(requestID.uuidString+"."+original.pathExtension)
        try copyRegular(original,to:backup,expected:expected,sha256:sha256)
        let journal=LocalData(directory:backupDirectory),receiptName=requestID.uuidString+".json"
        var receipt=Receipt(requestID:requestID,state:"prepared",original:original,backup:backup,displaced:displaced,originalSHA256:sha256,resultSHA256:resultHash)
        receipt.originalIdentity=expected;receipt.resultIdentity=try QuickLookArchiveIdentity(url:displaced)
        try journal.save(receipt,name:receiptName)
        defer {if !retainRecovery {receipt.state="not-committed";try? journal.save(receipt,name:receiptName)}}
        try observer?("prepared");try checkCancellation();try validate()
        var candidateInfo=stat();guard fstat(replacement,&candidateInfo)==0 else {throw posix()}
        guard renameatx_np(recoveryFD,displaced.lastPathComponent,directory,name,UInt32(RENAME_SWAP))==0 else {throw posix()}
        retainRecovery=true
        _=fsync(directory);_=fsync(recoveryFD)
        // ctime changes on rename. Verify the displaced original's identity,
        // data and metadata rather than treating that expected ctime as loss.
        do {
            try observer?("swapped")
            var old=stat(),saved=stat()
            guard fstatat(recoveryFD,displaced.lastPathComponent,&old,AT_SYMLINK_NOFOLLOW)==0,
                  old.st_dev==expected.device,old.st_ino==expected.inode,old.st_size==expected.bytes,
                  try digest(source)==sha256,
                  fstatat(directory,name,&saved,AT_SYMLINK_NOFOLLOW)==0,saved.st_dev==candidateInfo.st_dev,saved.st_ino==candidateInfo.st_ino,
                  try FileTools.sha256(original)==resultHash else {throw failure("保存时检测到外部更改，安全备份和现场已保留。")}
            receipt.state="completed";try journal.save(receipt,name:receiptName)
        }catch {
            var current=stat()
            if fstatat(directory,name,&current,AT_SYMLINK_NOFOLLOW)==0,current.st_dev==candidateInfo.st_dev,current.st_ino==candidateInfo.st_ino,(try? FileTools.sha256(original))==resultHash,
               renameatx_np(recoveryFD,displaced.lastPathComponent,directory,name,UInt32(RENAME_SWAP))==0 {
                receipt.state="rolled-back"
            }else{receipt.state="needs-review"}
            try? journal.save(receipt,name:receiptName)
            throw error
        }
        return Result(backup:backup,displaced:displaced,sha256:resultHash)
    }
}
