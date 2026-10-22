import Foundation
import Darwin

@MainActor func runArchiveVolumeEvidenceTests(engine:URL) async throws {
    let fm=FileManager.default,root=fm.temporaryDirectory.appendingPathComponent("gao-volume-evidence-"+UUID().uuidString,isDirectory:true)
    try fm.createDirectory(at:root,withIntermediateDirectories:false,attributes:[.posixPermissions:0o700]);defer {try? fm.removeItem(at:root)}
    let service=ArchiveService(engineURL:engine),store=ArchiveVolumeEvidenceStore(directory:root.appendingPathComponent("evidence"))
    service.volumeEvidence=store
    let source=root.appendingPathComponent("public-synthetic.bin")
    let payload=Data((0..<2_300_000).map{UInt8(truncatingIfNeeded:$0)})
    try payload.write(to:source)
    var options=ArchiveCreationOptions();options.level = .store
    var checks=0
    func check(_ value:Bool,_ message:String) throws {checks += 1;guard value else {throw DataFailure.message(message)}}
    func rejects(_ body:() throws -> Void) throws {checks += 1;do {try body()}catch{return};throw DataFailure.message("Expected evidence rejection")}
    for format in [ArchiveFormat.zip,.sevenZip] {
        let first=try await service.create(items:[source],destination:root.appendingPathComponent("safe."+format.rawValue),format:format,password:nil,splitMB:1,solid:false,options:options)
        let creationReceipts=service.lastResultReceipts
        let group=try ArchiveVolumeGroup.capture(first,evidence:store)
        try check(group.members.count==3,"Real split create did not publish expected volumes")
        try group.verifyUnchanged()
        let unowned=first.deletingPathExtension().appendingPathExtension("004"),unownedBytes=Data("Unrelated neighboring file; never trash".utf8)
        try unownedBytes.write(to:unowned)
        try check(try ArchiveVolumeGroup.capture(first,evidence:store).members==group.members,"Adjacent unowned name entered evidence group")
        let output=root.appendingPathComponent(format.rawValue+"-decoded")
        _ = try await service.extract(archive:first,to:output,password:nil,selected:nil)
        try check(try Data(contentsOf:output.appendingPathComponent(source.lastPathComponent))==payload,"Split extraction content mismatch")
        let current=group.members[1],held=current.appendingPathExtension("held")
        try fm.moveItem(at:current,to:held)
        try rejects {_ = try ArchiveVolumeGroup.capture(first,evidence:store)}
        try fm.moveItem(at:held,to:current)
        // A rename changes ctime, deliberately invalidating the old creation
        // evidence. Reissuing only exact successful create receipts is explicit.
        try rejects {_ = try ArchiveVolumeGroup.capture(first,evidence:store)}
        try store.recordCreated(first:first,format:format.rawValue,receipts:creationReceipts)
        let replaced=group.members[0],replacement=replaced.appendingPathExtension("replacement")
        try fm.copyItem(at:replaced,to:replacement);try fm.removeItem(at:replaced);try fm.moveItem(at:replacement,to:replaced)
        try rejects {_ = try ArchiveVolumeGroup.capture(first,evidence:store)}
        try store.recordCreated(first:first,format:format.rawValue,receipts:creationReceipts)
        let beforeMetadataChange=try ArchiveVolumeGroup.capture(first,evidence:store)
        let changed=beforeMetadataChange.members[1]
        let attributes=try fm.attributesOfItem(atPath:changed.path),oldHash=try FileTools.fingerprint(changed)
        let oldMode=(attributes[.posixPermissions] as! NSNumber).intValue
        var oldStat=stat(),newStat=stat()
        guard lstat(changed.path,&oldStat)==0 else {throw DataFailure.message("Cannot inspect metadata-only fixture")}
        try fm.setAttributes([.posixPermissions:oldMode^0o200],ofItemAtPath:changed.path)
        try fm.setAttributes([.posixPermissions:oldMode],ofItemAtPath:changed.path)
        guard lstat(changed.path,&newStat)==0 else {throw DataFailure.message("Cannot inspect changed fixture")}
        try check(oldStat.st_mode==newStat.st_mode && oldStat.st_mtimespec.tv_sec==newStat.st_mtimespec.tv_sec && oldStat.st_mtimespec.tv_nsec==newStat.st_mtimespec.tv_nsec && (oldStat.st_ctimespec.tv_sec != newStat.st_ctimespec.tv_sec || oldStat.st_ctimespec.tv_nsec != newStat.st_ctimespec.tv_nsec),"Fixture must change only ctime while restoring exact mode and preserving nanosecond mtime")
        try check(try FileTools.fingerprint(changed)==oldHash,"Metadata-only fixture changed archive bytes")
        try rejects {try beforeMetadataChange.verifyUnchanged()}
        var attemptedMoves=0
        try rejects {try ArchiveEnhancementController.trashUnchanged(beforeMetadataChange.fingerprints,validateOriginal:{try beforeMetadataChange.verifyUnchanged($0)},moveToTrash:{url in attemptedMoves += 1;return url})}
        try check(attemptedMoves==0 && beforeMetadataChange.members.allSatisfy{fm.fileExists(atPath:$0.path)},"ctime-only change did not retain every original volume")
        try store.recordCreated(first:first,format:format.rawValue,receipts:creationReceipts)
        let approved=try ArchiveVolumeGroup.capture(first,evidence:store)
        let fakeTrash=root.appendingPathComponent(format.rawValue+"-fake-trash",isDirectory:true)
        try fm.createDirectory(at:fakeTrash,withIntermediateDirectories:false)
        try approved.verifyUnchanged()
        try ArchiveEnhancementController.trashUnchanged(approved.fingerprints,validateOriginal:{try approved.verifyUnchanged($0)},moveToTrash:{url in
            let target=fakeTrash.appendingPathComponent(url.lastPathComponent);try fm.moveItem(at:url,to:target);return target
        })
        try check(approved.members.allSatisfy{!fm.fileExists(atPath:$0.path)},"Exact proven volume originals were not postprocessed")
        try check(try Data(contentsOf:unowned)==unownedBytes,"Unrelated volume neighbor changed")
    }
    try await runArchiveDisposalSafetyTests(service:service,root:root,payload:Data("public original protection fixture".utf8))
    print("Volume evidence checks passed (\(checks)); private evidence, exact member bytes and no wildcard disposal.")
}
