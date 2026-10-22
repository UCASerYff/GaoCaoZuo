import Foundation
import Darwin

struct QuickLookArchiveIdentity:Codable,Equatable {
    var device:Int32;var inode:UInt64;var bytes:Int64;var modified:Int64;var modifiedNS:Int64;var changed:Int64;var changedNS:Int64
    init(device:Int32,inode:UInt64,bytes:Int64,modified:Int64,modifiedNS:Int64,changed:Int64,changedNS:Int64) {self.device=device;self.inode=inode;self.bytes=bytes;self.modified=modified;self.modifiedNS=modifiedNS;self.changed=changed;self.changedNS=changedNS}
    init(url:URL)throws {
        var s=stat()
        guard url.isFileURL,lstat(url.path,&s)==0,s.st_mode&S_IFMT==S_IFREG,s.st_nlink==1,s.st_size>=0,s.st_size<=128*1_024*1_024 else {throw CocoaError(.fileReadUnsupportedScheme)}
        device=s.st_dev;inode=s.st_ino;bytes=s.st_size;modified=Int64(s.st_mtimespec.tv_sec);modifiedNS=Int64(s.st_mtimespec.tv_nsec);changed=Int64(s.st_ctimespec.tv_sec);changedNS=Int64(s.st_ctimespec.tv_nsec)
    }
}
struct QuickLookArchiveEditRequest:Codable {
    enum Kind:String,Codable {case inspect,saveOriginal}
    var schema=1;var requestID=UUID();var kind:Kind
    var archive:URL;var identity:QuickLookArchiveIdentity;var sha256:String
    /// Transferred only in the authenticated private XPC message, never argv/files.
    var password:String?
    var adding:[URL]=[];var removing:[String]=[];var removeHidden=false
}
struct QuickLookArchiveMember:Codable {
    var path:String;var size:UInt64;var directory:Bool;var encrypted:Bool;var permissions:UInt16?
}
struct QuickLookArchiveEditResponse:Codable {
    var schema=1;var requestID:UUID;var status:String
    var members:[QuickLookArchiveMember]=[]
    var resultSHA256:String?;var backup:URL?;var message:String?
    var helperPID:Int32?;var helperParentPID:Int32?
}
struct QuickLookArchiveEditReceipt:Codable {
    var schema=1;var requestID:UUID;var state:String
    var original:URL;var originalSHA256:String;var backup:URL;var savedSHA256:String?
}
