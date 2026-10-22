import Foundation
import Darwin

@MainActor func runArchiveOriginalCommitTests(engine:URL)async throws {
    let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("GaoOriginalCommit-"+UUID().uuidString+".noindex",isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer{try? fm.removeItem(at:root)}
    var checks=0
    func check(_ value:Bool,_ message:String)throws {checks += 1;guard value else{throw DataFailure.message(message)}}
    func rejects(_ operation:()async throws->Void)async throws {checks += 1;do{try await operation()}catch{return};throw DataFailure.message("Unsafe original commit accepted")}
    let original=root.appendingPathComponent("public-original.zip"),candidate=root.appendingPathComponent("candidate.zip"),backups=root.appendingPathComponent("backups",isDirectory:true)
    let old=Data("Public original content".utf8),new=Data("Public replacement content".utf8)
    try old.write(to:original);try new.write(to:candidate);try fm.setAttributes([.posixPermissions:0o640],ofItemAtPath:original.path)
    let tag=try PropertyListSerialization.data(fromPropertyList:["GaoPublicTest\n0"],format:.binary,options:0)
    try tag.withUnsafeBytes{guard setxattr(original.path,"com.apple.metadata:_kMDItemUserTags",$0.baseAddress,tag.count,0,0)==0 else {throw DataFailure.message("Cannot set public tag fixture")}}
    let requestID=UUID(),identity=try QuickLookArchiveIdentity(url:original),hash=try FileTools.sha256(original)
    let committed=try ArchiveOriginalCommit.commit(original:original,expected:identity,sha256:hash,candidate:candidate,backupDirectory:backups,requestID:requestID)
    try check(try Data(contentsOf:original)==new && Data(contentsOf:committed.backup)==old && Data(contentsOf:committed.displaced)==old,"Commit lost result, frozen backup or displaced original")
    try check((try fm.attributesOfItem(atPath:original.path)[.posixPermissions] as? NSNumber)?.intValue==0o640,"Original container permissions changed")
    var actual=Data(count:tag.count)
    let tagCount=actual.withUnsafeMutableBytes{getxattr(original.path,"com.apple.metadata:_kMDItemUserTags",$0.baseAddress,tag.count,0,0)}
    try check(tagCount==tag.count && actual==tag,"Original Finder tags changed")
    let receipt=try LocalData(directory:backups).load(requestID.uuidString+".json",as:ArchiveOriginalCommit.Receipt.self)
    try check(receipt?.state=="completed" && receipt?.originalSHA256==hash,"Durable commit receipt missing")
    awaitReject: do {
        try await rejects { _=try ArchiveOriginalCommit.commit(original:original,expected:identity,sha256:hash,candidate:candidate,backupDirectory:backups,requestID:UUID()) }
    }
    for externalEdit in [false,true] {
        let source=root.appendingPathComponent("race-\(externalEdit).zip");try old.write(to:source)
        let before=try QuickLookArchiveIdentity(url:source),sha=try FileTools.sha256(source)
        try await rejects {
            _=try ArchiveOriginalCommit.commit(original:source,expected:before,sha256:sha,candidate:candidate,backupDirectory:backups,requestID:UUID(),observer:{phase in
                if phase=="swapped" {
                    if externalEdit {try Data("Public external edit".utf8).write(to:source)}
                    throw DataFailure.message("Injected post-swap failure")
                }
            })
        }
        try check(try Data(contentsOf:source)==(externalEdit ? Data("Public external edit".utf8):old),"Rollback overwrote external bytes or failed to restore original")
    }
    let input=root.appendingPathComponent("public-member.txt"),added=root.appendingPathComponent("public-added.txt")
    try Data("Public archive member\n".utf8).write(to:input);try Data("Public added member\n".utf8).write(to:added)
    for format in [ArchiveFormat.zip,.sevenZip] {
        let archive=root.appendingPathComponent("encrypted."+format.rawValue),creator=ArchiveService(engineURL:engine),password="GaoOriginalPublicV114!"
        _=try await creator.create(items:[input],destination:archive,format:format,password:password,splitMB:nil,solid:false)
        let archiveHash=try FileTools.sha256(archive),archiveIdentity=try QuickLookArchiveIdentity(url:archive)
        func service()throws->ArchiveService {
            let job=root.appendingPathComponent(UUID().uuidString,isDirectory:true);try fm.createDirectory(at:job,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700])
            let value=ArchiveService(engineURL:engine);value.executionScope=try ArchiveExecutionScope(workspace:job,runtime:engine.deletingLastPathComponent());return value
        }
        let wrong=QuickLookArchiveEditRequest(kind:.saveOriginal,archive:archive,identity:archiveIdentity,sha256:archiveHash,password:"wrong-public-password",adding:[added])
        try await rejects {_=try await QuickLookArchiveEditBackend.perform(wrong,service:try service(),backupDirectory:backups)}
        try check(try FileTools.sha256(archive)==archiveHash,"Wrong password changed original")
        let request=QuickLookArchiveEditRequest(kind:.saveOriginal,archive:archive,identity:archiveIdentity,sha256:archiveHash,password:password,adding:[added])
        let response=try await QuickLookArchiveEditBackend.perform(request,service:try service(),backupDirectory:backups)
        try check(response.status=="completed" && response.members.contains{$0.path==added.lastPathComponent} && response.members.filter{!$0.directory}.allSatisfy{$0.encrypted},"Scoped original save lost new member or encryption: "+response.members.map{"\($0.path) directory=\($0.directory) encrypted=\($0.encrypted)"}.joined(separator:"; "))
        try check(response.backup != nil && (try response.backup.map{try FileTools.sha256($0)})==archiveHash,"Encrypted original safety backup missing")
        let decoded=root.appendingPathComponent("decoded-"+format.rawValue)
        _=try await creator.extract(archive:archive,to:decoded,password:password,selected:nil)
        try check(try Data(contentsOf:decoded.appendingPathComponent(input.lastPathComponent))==Data(contentsOf:input) && Data(contentsOf:decoded.appendingPathComponent(added.lastPathComponent))==Data(contentsOf:added),"Saved encrypted archive failed exact-byte verification")
    }
    print("原位保存专项通过（\(checks)）：真实加密ZIP/7Z原位重建、解密精确字节、密码错误不改原包、原包权限/Finder标签、完整双份原件与持久收据、陈旧目标拒绝、失败恢复及外部改动保护；仅公开合成资料，无GUI。")
}
