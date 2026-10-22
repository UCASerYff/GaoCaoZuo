import Foundation
import Darwin
import CryptoKit

struct Metadata {
    let mode:mode_t;let uid:uid_t;let gid:gid_t;let flags:UInt32
    let xattrs:[String:Data];let acl:String
    func summary()->[String:Any] {["mode":String(mode,radix:8),"uid":uid,"gid":gid,"flags":flags,"xattrNames":xattrs.keys.sorted(),"aclPresent":!acl.isEmpty]}
}
func fail(_ text:String)->NSError {NSError(domain:"PublicArchiveMetadataProbe",code:1,userInfo:[NSLocalizedDescriptionKey:text])}
func metadata(_ fd:Int32)throws->Metadata {
    var s=stat();guard fstat(fd,&s)==0 else{throw fail("fstat")}
    let length=flistxattr(fd,nil,0,0);guard length>=0,length<1_048_576 else{throw fail("xattr names")}
    var names=[CChar](repeating:0,count:max(length,1));guard flistxattr(fd,&names,length,0)==length else{throw fail("xattr names changed")}
    var attrs:[String:Data]=[:]
    for raw in Data(names.prefix(length).map{UInt8(bitPattern:$0)}).split(separator:0) {
        guard let name=String(data:Data(raw),encoding:.utf8) else{throw fail("xattr name encoding")}
        let size=fgetxattr(fd,name,nil,0,0,0);guard size>=0,size<1_048_576 else{throw fail("xattr read: "+name)}
        var data=Data(count:size)
        guard data.withUnsafeMutableBytes({fgetxattr(fd,name,$0.baseAddress,size,0,0)})==size else{throw fail("xattr changed: "+name)}
        attrs[name]=data
    }
    var aclText=""
    if let acl=acl_get_fd_np(fd,ACL_TYPE_EXTENDED) {
        defer{acl_free(UnsafeMutableRawPointer(acl))}
        var count:ssize_t=0
        guard let text=acl_to_text(acl,&count) else{throw fail("acl text")};defer{acl_free(UnsafeMutableRawPointer(text))}
        aclText=String(cString:text)
    } else if errno != ENOENT {throw fail("acl read")}
    return .init(mode:s.st_mode&0o7777,uid:s.st_uid,gid:s.st_gid,flags:s.st_flags,xattrs:attrs,acl:aclText)
}
func difference(_ a:Metadata,_ b:Metadata)->[String:Any] {
    let names=Set(a.xattrs.keys).union(b.xattrs.keys)
    return ["modeMatches":a.mode==b.mode,"uidMatches":a.uid==b.uid,"gidMatches":a.gid==b.gid,"flagsMatch":a.flags==b.flags,"aclMatches":a.acl==b.acl,
            "xattrDifferenceNames":names.filter{a.xattrs[$0] != b.xattrs[$0]}.sorted(),
            "missingXattrNames":a.xattrs.keys.filter{b.xattrs[$0]==nil}.sorted(),"addedXattrNames":b.xattrs.keys.filter{a.xattrs[$0]==nil}.sorted()]
}
@main enum Probe {
 static func main()throws {
    guard CommandLine.arguments.count==3 else{throw fail("Expected public archive and private workspace")}
    let original=URL(fileURLWithPath:CommandLine.arguments[1]),workspace=URL(fileURLWithPath:CommandLine.arguments[2],isDirectory:true)
    guard original.lastPathComponent=="public-encrypted.zip" else{throw fail("Public fixture name required")}
    let bytes=try Data(contentsOf:original)
    guard bytes.count==275,SHA256.hash(data:bytes).map({String(format:"%02x",$0)}).joined()=="9fde429d8f319ea61de29a30d3a051e7bf8eb6bde66bd4f90e9d44fc15b6cb85" else{throw fail("Public fixture digest required")}
    var root=stat();guard lstat(workspace.path,&root)==0,root.st_uid==getuid(),root.st_mode&S_IFMT==S_IFDIR,root.st_mode&0o077==0 else{throw fail("Private workspace required")}
    let source=open(original.path,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);guard source>=0 else{throw fail("Open public input")};defer{close(source)}
    let before=try metadata(source)
    var results:[[String:Any]]=[]
    for (name,flags) in [("metadata-only",COPYFILE_METADATA),("full-copy",COPYFILE_ALL)] {
        let dest=workspace.appendingPathComponent(name)
        let fd=open(dest.path,O_RDWR|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC,0o600);guard fd>=0 else{throw fail("Exclusive test output")};defer{close(fd)}
        let test=Data("Public candidate data; no archive decoding.\n".utf8)
        guard test.withUnsafeBytes({Darwin.write(fd,$0.baseAddress,test.count)})==test.count else{throw fail("Write public candidate")}
        let result=fcopyfile(source,fd,nil,copyfile_flags_t(flags));let errorCode=result==0 ? 0:errno
        let after=try metadata(fd)
        results.append(["operation":name,"status":result,"errno":errorCode,"copy":after.summary(),"differences":difference(before,after)])
    }
    let after=try metadata(source)
    guard before.mode==after.mode,before.uid==after.uid,before.gid==after.gid,before.flags==after.flags,before.acl==after.acl,before.xattrs==after.xattrs,try Data(contentsOf:original)==bytes else{throw fail("Original changed during read-only probe")}
    let report:[String:Any]=["source":before.summary(),"originalBytesAndMetadataUnchanged":true,"sourceOpenedReadOnly":true,"attributeValuesOmitted":true,"results":results]
    FileHandle.standardOutput.write(try JSONSerialization.data(withJSONObject:report,options:[.prettyPrinted,.sortedKeys]))
 }
}
