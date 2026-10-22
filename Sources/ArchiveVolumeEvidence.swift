import Foundation
import CryptoKit
import Darwin

/// Private creation evidence is issued only for the exact files returned by a
/// successful engine create + integrity test. Neighboring names are never proof.
final class ArchiveVolumeEvidenceStore {
    struct Identity:Codable,Equatable {
        var device:Int32;var inode:UInt64;var bytes:Int64;var modified:Int64;var modifiedNS:Int64;var changed:Int64;var changedNS:Int64
        init(_ s:stat) {device=s.st_dev;inode=s.st_ino;bytes=s.st_size;modified=Int64(s.st_mtimespec.tv_sec);modifiedNS=Int64(s.st_mtimespec.tv_nsec);changed=Int64(s.st_ctimespec.tv_sec);changedNS=Int64(s.st_ctimespec.tv_nsec)}
    }
    struct Member:Codable {var path:String;var fingerprint:String;var bytes:Int64;var identity:Identity}
    struct Evidence:Codable {var schema=1;var groupID=UUID();var firstPath:String;var format:String;var members:[Member]}
    private let data:LocalData
    init(directory:URL) {data=LocalData(directory:directory)}
    private func name(_ first:URL)->String {
        SHA256.hash(data:Data(first.standardizedFileURL.path.utf8)).map{String(format:"%02x",$0)}.joined()+".json"
    }
    func recordCreated(first:URL,format:String,receipts:[FileOperationReceipt]) throws {
        guard ["zip","7z"].contains(format),first.pathExtension=="001",!receipts.isEmpty,receipts.count<=999 else {throw ArchiveError.invalid("分卷创建证据无效，原卷已保留。")}
        let base=first.deletingPathExtension().path
        let ordered=receipts.sorted{$0.destination.path<$1.destination.path}
        var members:[Member]=[]
        for (index,receipt) in ordered.enumerated() {
            let expected=base+String(format:".%03d",index+1)
            let hash=receipt.fingerprint
            guard receipt.kind == .create,receipt.destination.standardizedFileURL.path==expected,
                  try FileTools.fingerprint(receipt.destination)==hash else {throw ArchiveError.invalid("分卷与创建收据不一致，原卷已保留。")}
            let info=try EnhancedFileTools.checked(receipt.destination)
            guard info.st_mode&S_IFMT==S_IFREG,info.st_uid==getuid(),info.st_nlink==1 else {throw ArchiveError.invalid("分卷不是当前用户的独立普通文件。")}
            guard try FileTools.fingerprint(receipt.destination)==hash,
                  Identity(try EnhancedFileTools.checked(receipt.destination))==Identity(info) else {throw FileToolsError.changed(receipt.destination)}
            members.append(.init(path:expected,fingerprint:hash,bytes:info.st_size,identity:Identity(info)))
        }
        try data.save(Evidence(firstPath:first.standardizedFileURL.path,format:format,members:members),name:name(first))
    }
    func verifiedMembers(first:URL) throws -> [URL] {
        guard let saved=try data.load(name(first),as:Evidence.self),saved.schema==1,
              saved.firstPath==first.standardizedFileURL.path,["zip","7z"].contains(saved.format),
              first.deletingPathExtension().pathExtension.lowercased()==saved.format,
              !saved.members.isEmpty,saved.members.count<=999 else {throw ArchiveError.invalid("找不到已核验的分卷创建证据，未移动原卷。")}
        let base=first.deletingPathExtension().path
        return try saved.members.enumerated().map {index,member in
            guard member.path==base+String(format:".%03d",index+1),member.bytes>=0 else {throw ArchiveError.invalid("分卷创建证据的路径或次序无效。")}
            let url=URL(fileURLWithPath:member.path),info=try EnhancedFileTools.checked(url)
            guard info.st_mode&S_IFMT==S_IFREG,info.st_nlink==1,info.st_uid==getuid(),info.st_size==member.bytes,Identity(info)==member.identity,
                  try FileTools.fingerprint(url)==member.fingerprint,
                  Identity(try EnhancedFileTools.checked(url))==member.identity else {throw FileToolsError.changed(url)}
            return url
        }
    }
}
