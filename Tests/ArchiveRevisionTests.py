#!/usr/bin/env python3
"""Small generated archive regression cases. No GUI, user files, or benchmark runs."""
from pathlib import Path
import hashlib
import os
import plistlib
import shutil
import subprocess
import tempfile

PROJECT = Path(__file__).resolve().parents[1]
SWIFT = r'''
import Foundation
import Darwin

final class PublicationCounter: @unchecked Sendable {
    let lock = NSLock(); var count = 0
    let target: URL; let conflict: Bool
    var resultWasAbsent = false
    init(target: URL, conflict: Bool) { self.target = target; self.conflict = conflict }
    func observe(_ phase: ArchiveCreationIO.Phase) {
        guard phase == .publishing else { return }
        lock.lock(); defer { lock.unlock() }; count += 1
        if count == 2 {
            resultWasAbsent = !FileManager.default.fileExists(atPath: target.path)
            if conflict { try? Data("raced user file".utf8).write(to: target, options: .withoutOverwriting) }
        }
    }
}
@main enum RevisionChecks {
 @MainActor static func main() async {
    do {try await run()} catch {fputs("ARCHIVE_REVISION_FAILURE: \(error.localizedDescription)\n",stderr);exit(1)}
 }
 @MainActor static func run() async throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]), engine=URL(fileURLWithPath:CommandLine.arguments[2])
    let fixtures=root.appendingPathComponent("fixtures"), fm=FileManager.default
    var checks=0
    func expect(_ condition:@autoclosure () throws->Bool,_ label:String)throws {
        guard try condition() else {throw ArchiveError.invalid(label)}; checks += 1
    }
    func rejects(_ label:String,_ operation:() async throws->Void)async throws {
        do {try await operation()} catch {checks += 1; return};throw ArchiveError.invalid("unexpected success: "+label)
    }
    try runArchiveBatchStreamTests()
    let bytes=try Data(contentsOf:fixtures.appendingPathComponent("payload.txt")), service=ArchiveService(engineURL:engine)
    let original=root.appendingPathComponent("original.zip")
    _=try await service.create(items:[fixtures.appendingPathComponent("payload.txt")],destination:original,format:.zip,password:"FixtureOnly",splitMB:nil,solid:false)
    let originalSHA=try FileTools.sha256(original)
    let addition=root.appendingPathComponent("新增 ' file.txt");try Data("new exact bytes".utf8).write(to:addition)
    for conflict in [false,true] {
        let target=root.appendingPathComponent(conflict ? "conflict.zip":"edit-copy.zip")
        let gate=PublicationCounter(target:target,conflict:conflict)
        let editor=ArchiveService(engineURL:engine,creationIOObserver:{gate.observe($0)})
        if conflict {
            try await rejects("edit copy late conflict refuses") {_ = try await editor.edit(archive:original,password:"FixtureOnly",adding:[addition],removing:[],removeHidden:false,saveTo:target,backupDirectory:root.appendingPathComponent("backups"))}
            try expect(try Data(contentsOf:target) == Data("raced user file".utf8),"raced destination is not overwritten")
            try expect(editor.lastResultReceipts.isEmpty,"failed final publication never retains private rebuilt archive receipt")
        } else {
            let result=try await editor.edit(archive:original,password:"FixtureOnly",adding:[addition],removing:[],removeHidden:false,saveTo:target,backupDirectory:root.appendingPathComponent("backups"))
            try expect(result.result == target && result.backup == nil,"edit copy publishes requested final name")
            let listing=try await editor.list(archive:target,password:"FixtureOnly")
            try expect(listing.contains{$0.path == addition.lastPathComponent && $0.isEncrypted},"AES edit retains encrypted contents")
            let output=root.appendingPathComponent("edited-content")
            _=try await editor.extract(archive:target,to:output,password:"FixtureOnly",selected:[addition.lastPathComponent])
            try expect(try Data(contentsOf:output.appendingPathComponent(addition.lastPathComponent)) == Data("new exact bytes".utf8),"edited member bytes are exact")
        }
        try expect(gate.resultWasAbsent,"final output is absent until exclusive publication phase")
        try expect(try FileTools.sha256(original) == originalSHA,"edit copy leaves original encrypted package unchanged")
        try expect(!editor.isRunning,"publication fully drains before releasing execution slot")
    }
    for (name,path) in [("gbk.zip","中文文件.txt"),("mszip.cab","hello.txt"),("original.cab","hello.txt"),("original.ar","payload.txt"),("original.cpio","payload.txt"),("original.iso","hello.txt")] {
        var options=ArchiveExtractionOptions();if name == "gbk.zip" {options.filenameEncoding="GB18030"}
        let archive=fixtures.appendingPathComponent(name), before=try FileTools.sha256(archive)
        let listing=try await service.list(archive:archive,password:nil,options:options)
        try expect(listing.contains{$0.path == path},"variant list exact name: "+name)
        let selected=root.appendingPathComponent(name+"-selected")
        _=try await service.extract(archive:archive,to:selected,password:nil,selected:[path],options:options)
        try expect(try Data(contentsOf:selected.appendingPathComponent(path)) == bytes,"variant selected bytes: "+name)
        try expect(try FileTools.sha256(archive) == before,"variant source unchanged: "+name)
    }
    let independent=fixtures.appendingPathComponent("independent.zip"), selected=root.appendingPathComponent("independent-output")
    try await rejects("independent ZipCrypto wrong password") {_ = try await service.extract(archive:independent,to:selected,password:"incorrect",selected:nil)}
    try expect(!fm.fileExists(atPath:selected.path),"password failure leaves no output")
    _=try await service.extract(archive:independent,to:selected,password:"FixtureOnly",selected:nil)
    try expect(try Data(contentsOf:selected.appendingPathComponent("payload.txt")) == bytes,"independent system zip ZipCrypto password retry exact bytes")
    var create=ArchiveCreationOptions();create.level = .store
    let large=root.appendingPathComponent("split-payload.bin"), largeBytes=Data((0..<1_100_000).map{UInt8(truncatingIfNeeded:$0)})
    try largeBytes.write(to:large)
    for format in ArchiveFormat.allCases {
        let first=try await service.create(items:[large],destination:root.appendingPathComponent("original-split."+format.rawValue),format:format,password:nil,splitMB:1,solid:false,options:create)
        let output=root.appendingPathComponent("split-output-"+format.rawValue)
        _=try await service.extract(archive:first,to:output,password:nil,selected:nil)
        try expect(try Data(contentsOf:output.appendingPathComponent(large.lastPathComponent)) == largeBytes,"numeric split isolated-copy extraction: "+format.rawValue)
        let members=try ArchiveReadSnapshot.numericMembers(first)
        try expect(members.count == 2 && members.allSatisfy{fm.fileExists(atPath:$0.path)},"numeric split originals always retained")
    }
    let metadataFile=root.appendingPathComponent("metadata.txt"), attribute=Data("original xattr".utf8), fork=Data("original resource fork".utf8)
    try bytes.write(to:metadataFile)
    for (name,value) in [("com.gaoseries.archive-revision",attribute),("com.apple.ResourceFork",fork)] {
        guard value.withUnsafeBytes({setxattr(metadataFile.path,name,$0.baseAddress,value.count,0,XATTR_NOFOLLOW)}) == 0 else {throw NSError(domain:NSPOSIXErrorDomain,code:Int(errno))}
    }
    try fm.setAttributes([.posixPermissions:0o444,.modificationDate:Date(timeIntervalSince1970:1_760_000_000)],ofItemAtPath:metadataFile.path)
    for format in ArchiveFormat.allCases {
        let app=root.appendingPathComponent("Fixture.app"), archive=root.appendingPathComponent("signed-app."+format.rawValue), output=root.appendingPathComponent("signed-app-output-"+format.rawValue)
        _=try await service.create(items:[app,metadataFile],destination:archive,format:format,password:nil,splitMB:nil,solid:false)
        _=try await service.extract(archive:archive,to:output,password:nil,selected:nil)
        let verify=Process();verify.executableURL=URL(fileURLWithPath:"/usr/bin/codesign");verify.arguments=["--verify","--strict",output.appendingPathComponent("Fixture.app").path]
        try verify.run();verify.waitUntilExit()
        try expect(verify.terminationStatus == 0,"ad-hoc signed original generated app remains valid after "+format.rawValue+" roundtrip")
        let restored=output.appendingPathComponent("metadata.txt")
        for (name,value) in [("com.gaoseries.archive-revision",attribute),("com.apple.ResourceFork",fork)] {
            var actual=Data(count:value.count)
            let amount=actual.withUnsafeMutableBytes{getxattr(restored.path,name,$0.baseAddress,value.count,0,XATTR_NOFOLLOW)}
            try expect(amount == value.count && actual == value,"metadata attribute exact: "+name+" "+format.rawValue)
        }
        let attrs=try fm.attributesOfItem(atPath:restored.path)
        try expect((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o444,"read-only mode is preserved "+format.rawValue)
        try expect(abs((attrs[.modificationDate] as! Date).timeIntervalSince1970-1_760_000_000) <= 2,"member modification time preserved "+format.rawValue)
        try expect(!fm.fileExists(atPath:output.appendingPathComponent("__MACOSX").path),"fully consumed metadata sidecar tree removed "+format.rawValue)
    }
    let tar=fixtures.appendingPathComponent("links.tar"), tarOutput=root.appendingPathComponent("links-output")
    _=try await service.extract(archive:tar,to:tarOutput,password:nil,selected:nil)
    var a=stat(),b=stat();let first=tarOutput.appendingPathComponent("dir/run.sh"),second=tarOutput.appendingPathComponent("dir/hard")
    try expect(lstat(first.path,&a) == 0 && lstat(second.path,&b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino && a.st_nlink == 2 && b.st_nlink == 2,"TAR declared hardlinks share one inode and exact link count")
    try expect(a.st_uid == getuid() && b.st_uid == getuid(),"extraction ownership remains current user, never chown")
    try expect(try !fm.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".gaocaozuo-stage-")},"all final publication stages cleaned")
    print("PASS: \(checks) V1.09 targeted production archive checks; atomic copy publication, AES edit, source preservation, GBK, MSZIP CAB, AR/CPIO/ISO, independent ZipCrypto retry, split ZIP/7Z, actual hardlink inode; no GUI or benchmark")
 }
}
'''

def main():
    with tempfile.TemporaryDirectory(prefix="gaocaozuo-archive-revision-", dir="/private/tmp") as temporary:
        root=Path(temporary); os.chmod(root,0o700)
        subprocess.run(["/usr/bin/python3","-B",str(PROJECT/"Tests/ArchiveFixtures.py"),str(root/"fixtures")],check=True,timeout=30)
        subprocess.run(["/usr/bin/zip","-q","-P","FixtureOnly","independent.zip","payload.txt"],cwd=root/"fixtures",check=True,timeout=10)
        app=root/"Fixture.app"; (app/"Contents/MacOS").mkdir(parents=True); (app/"Contents/Resources").mkdir()
        (app/"Contents/Info.plist").write_bytes(plistlib.dumps({"CFBundleIdentifier":"com.gaoseries.fixture.original","CFBundleExecutable":"fixture","CFBundlePackageType":"APPL","CFBundleVersion":"1"}))
        (app/"Contents/Resources/原创.txt").write_text("Original generated app fixture, no user data.\n")
        (root/"fixture.c").write_text("int main(void) { return 0; }\n")
        subprocess.run(["/usr/bin/clang",str(root/"fixture.c"),"-o",str(app/"Contents/MacOS/fixture")],check=True,timeout=30)
        subprocess.run(["/usr/bin/codesign","--force","--sign","-",str(app)],check=True,timeout=10)
        (root/"runner.swift").write_text(SWIFT)
        sources=["Sources/ArchiveService.swift","Sources/ArchiveBatchStream.swift","Sources/ArchiveEnhancementsCore.swift","Sources/ArchiveMacMetadata.swift","Sources/FileTools.swift","Shared/GaoLocalization.swift","Tests/ArchiveBatchStreamTests.swift"]
        frozen=[]
        for name in sources:
            copy=root/name; copy.parent.mkdir(parents=True,exist_ok=True); shutil.copyfile(PROJECT/name,copy); frozen.append(str(copy))
        print("SOURCE_SHA256", {name:hashlib.sha256((root/name).read_bytes()).hexdigest() for name in sources},flush=True)
        executable=root/"archive-revision"
        command=["swiftc","-swift-version","5","-O","-target","arm64-apple-macos14.0","-module-cache-path",str(root/"cache"),str(root/"runner.swift"),*frozen]
        for framework in ["AppKit","CryptoKit","CoreImage","ImageIO","UniformTypeIdentifiers"]:command += ["-framework",framework]
        subprocess.run(command+["-o",str(executable)],check=True,timeout=120)
        subprocess.run([str(executable),str(root),str(PROJECT/"Resources/Tools/7zz")],check=True,timeout=90)

if __name__ == "__main__":main()
