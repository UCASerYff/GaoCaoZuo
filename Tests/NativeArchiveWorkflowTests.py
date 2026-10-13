#!/usr/bin/env python3
"""Real in-process libarchive workflows; only disposable, generated files."""
from pathlib import Path
import os
import gzip
import stat
import subprocess
import tempfile
import zipfile

PROJECT = Path(__file__).resolve().parent.parent
RUNNER = r'''
import Foundation
import Darwin

let root=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let output=root.appendingPathComponent("output",isDirectory:true)
try FileManager.default.createDirectory(at:output,withIntermediateDirectories:false)
var checks=0
func expect(_ value:@autoclosure () throws -> Bool,_ message:String)throws {
    guard try value() else {throw NativeArchive.Failure(message:message)};checks += 1
}
func rejects(_ label:String,_ work:()throws->Void)throws {
    do {try work()} catch {checks += 1;return}
    throw NativeArchive.Failure(message:"unexpected success: "+label)
}
func stagesAreClean()throws->Bool {
    try !FileManager.default.contentsOfDirectory(atPath:output.path).contains{$0.hasPrefix(".gaocaozuo-ql-")}
}
do {
for name in ["source.zip","source.7z"] {
    fputs("Native workflow fixture: \(name) inspect/preview/extract\n",stderr)
    let url=root.appendingPathComponent(name), original=try Data(contentsOf:url)
    let document=try NativeArchive.inspect(url)
    try expect(document.format == (name.hasSuffix("zip") ? "zip":"7z"),"format comes from native reader")
    try expect(document.items.contains{$0.path == "目录/one.txt" && $0.kind == .file},"Unicode native manifest")
    try expect(document.canEditCopy,"ordinary archive supports edit-copy plan")
    try expect(try NativeArchive.memberData(document,path:"目录/one.txt") == Data("one original\n".utf8),"member preview decodes exact bytes")
    let extracted=try NativeArchive.extract(document,selected:["目录"],directory:output,name:name+"-selected")
    try expect(try Data(contentsOf:extracted.appendingPathComponent("目录/one.txt")) == Data("one original\n".utf8),"directory selection extracts descendant bytes")
    try expect(!FileManager.default.fileExists(atPath:extracted.appendingPathComponent("second.txt").path),"selection excludes other files")
    try rejects("existing destination") {_ = try NativeArchive.extract(document,selected:nil,directory:output,name:name+"-selected")}
    fputs("Native workflow fixture: \(name) rebuild/verify\n",stderr)
    let edited=try NativeArchive.editedCopy(document,deleting:["目录/one.txt"],adding:[root.appendingPathComponent("added.txt")],cleanHidden:true,directory:output,name:"edited-"+name)
    let after=try NativeArchive.inspect(edited)
    try expect(!after.items.contains{$0.path == "目录/one.txt" || NativeArchive.isHidden($0.path)},"delete only the planned file; hidden cleanup is explicit")
    try expect(try NativeArchive.memberData(after,path:"added.txt") == Data("added new\n".utf8),"edited copy includes added bytes")
    try expect(try NativeArchive.memberData(after,path:"second.txt") == Data("second original\n".utf8),"edited copy preserves retained bytes")
    try expect(try Data(contentsOf:url) == original,"all workflows leave original archive unchanged")
    try expect(try stagesAreClean(),"successful/failing workflows remove only their private stages")
    let stop=NativeArchive.Cancellation();stop.cancel()
    try rejects("cancelled extraction") {_ = try NativeArchive.extract(document,selected:nil,directory:output,name:"cancel-"+name,cancellation:stop)}
    try expect(!FileManager.default.fileExists(atPath:output.appendingPathComponent("cancel-"+name).path) && stagesAreClean(),"cancelled extraction publishes nothing")
    try rejects("output traversal") {_ = try NativeArchive.extract(document,selected:nil,directory:output,name:"../outside")}
    try expect(!FileManager.default.fileExists(atPath:root.appendingPathComponent("outside").path) && stagesAreClean(),"unsafe output name creates no escaped file")
    try rejects("adding a symlink") {_ = try NativeArchive.editedCopy(document,deleting:[],adding:[root.appendingPathComponent("link.txt")],cleanHidden:false,directory:output,name:"link-"+name)}
    try rejects("adding a special FIFO cannot block") {_ = try NativeArchive.editedCopy(document,deleting:[],adding:[root.appendingPathComponent("fifo")],cleanHidden:false,directory:output,name:"fifo-"+name)}
    try expect(try stagesAreClean(),"rejected additions clean their stage")
}
for bad in ["traversal.zip","duplicate.zip","file-parent.zip"] {
    try rejects(bad) {_ = try NativeArchive.inspect(root.appendingPathComponent(bad))}
}
let links=try NativeArchive.inspect(root.appendingPathComponent("links.zip"))
try expect(!links.canEditCopy,"link-bearing archives are not silently rewritten")
try rejects("archive link extraction") {_ = try NativeArchive.extract(links,selected:nil,directory:output,name:"links")}
let encrypted=try NativeArchive.inspect(root.appendingPathComponent("encrypted.zip"))
try expect(!encrypted.canEditCopy && encrypted.items.contains(where:\.encrypted),"encrypted archive editing cannot strip protection")
try expect(try NativeArchive.memberData(encrypted,path:"added.txt",password:"FixtureOnly") == Data("added new\n".utf8),"native AES ZIP extraction uses explicit password")
try rejects("incorrect password") {_ = try NativeArchive.memberData(encrypted,path:"added.txt",password:"incorrect")}
let stream=root.appendingPathComponent("original-stream.gz")
switch try NativeArchivePreviewContent.load(stream,cancellation:NativeArchive.Cancellation()) {
case .readOnly(let listing):try expect(listing.contains("original-stream.gz") && !listing.contains("Path =") && !listing.isEmpty,"bounded read-only fallback preserves compressed-stream directory preview")
case .interactive:throw NativeArchive.Failure(message:"unexpected interactive stream capability")
}
let stopped=NativeArchive.Cancellation();stopped.cancel()
try rejects("cancelled listing never enters fallback") {_ = try NativeArchivePreviewContent.load(stream,cancellation:stopped)}
let changed=root.appendingPathComponent("changed.zip")
try FileManager.default.copyItem(at:root.appendingPathComponent("source.zip"),to:changed)
let captured=try NativeArchive.inspect(changed)
let handle=try FileHandle(forWritingTo:changed);try handle.seekToEnd();try handle.write(contentsOf:Data([0]));try handle.close()
try rejects("source changes after listing") {_ = try NativeArchive.extract(captured,selected:nil,directory:output,name:"changed")}
var tiny=NativeArchive.Budget();tiny.maxEntries=1
try rejects("entry budget") {_ = try NativeArchive.inspect(root.appendingPathComponent("source.zip"),budget:tiny)}
// These hooks run inside the actual native workflow at the vulnerable timing:
// after an FD stage exists, before its first payload/candidate creation.
let raceDoc=try NativeArchive.inspect(root.appendingPathComponent("source.zip"))
for phase in [NativeArchive.Phase.beforePayloadCreate, .beforeCandidateCreate] {
    let base=root.appendingPathComponent("stage-race-"+UUID().uuidString,isDirectory:true)
    let directory=base.appendingPathComponent("D",isDirectory:true), other=base.appendingPathComponent("E",isDirectory:true)
    try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
    try FileManager.default.createDirectory(at:other,withIntermediateDirectories:false)
    let sentinel=other.appendingPathComponent("sentinel");try Data("preserve".utf8).write(to:sentinel)
    var didSwap=false
    let hook:NativeArchive.Observer = { current, stage in
        guard current == phase, !didSwap else {return};didSwap=true
        try FileManager.default.moveItem(at:stage,to:directory.appendingPathComponent("held"))
        try FileManager.default.createSymbolicLink(at:stage,withDestinationURL:other)
    }
    try rejects("stage name replaced before first FD-relative create") {
        if phase == .beforePayloadCreate {_ = try NativeArchive.extract(raceDoc,selected:nil,directory:directory,name:"result",observer:hook)}
        else {_ = try NativeArchive.editedCopy(raceDoc,deleting:[],adding:[],cleanHidden:false,directory:directory,name:"result.zip",observer:hook)}
    }
    try expect(didSwap && FileManager.default.contentsOfDirectory(atPath:other.path) == ["sentinel"] && Data(contentsOf:sentinel) == Data("preserve".utf8),"replacement E receives no payload, candidate, bytes, or cleanup side effect")
    try expect(!FileManager.default.fileExists(atPath:directory.appendingPathComponent("result").path) && !FileManager.default.fileExists(atPath:directory.appendingPathComponent("result.zip").path),"replaced stage publishes no result")
    try expect(try FileManager.default.contentsOfDirectory(atPath:directory.appendingPathComponent("held").path).isEmpty,"cleanup follows held stage FD and removes temporary contents only")
}
let parentRace=root.appendingPathComponent("parent-race",isDirectory:true)
let originalParent=parentRace.appendingPathComponent("D",isDirectory:true), replacementParent=parentRace.appendingPathComponent("E",isDirectory:true)
try FileManager.default.createDirectory(at:originalParent,withIntermediateDirectories:true)
try FileManager.default.createDirectory(at:replacementParent,withIntermediateDirectories:false)
try rejects("parent swapped after creation cannot redirect writes or success URL") {
    _ = try NativeArchive.extract(raceDoc,selected:nil,directory:originalParent,name:"result",observer:{ phase,_ in
        if phase == .beforePayloadCreate {
            try FileManager.default.moveItem(at:originalParent,to:parentRace.appendingPathComponent("heldD"))
            try FileManager.default.createSymbolicLink(at:originalParent,withDestinationURL:replacementParent)
        }
    })
}
try expect(try FileManager.default.contentsOfDirectory(atPath:replacementParent.path).isEmpty,"parent replacement receives no writes")
for edit in [false,true] {
    let name=edit ? "late-cancel.zip":"late-cancel"
    let stop=NativeArchive.Cancellation()
    try rejects("last cancellation inside publish") {
        let hook:NativeArchive.Observer = {phase,_ in if phase == .beforePublish {stop.cancel()} }
        if edit {_ = try NativeArchive.editedCopy(raceDoc,deleting:[],adding:[],cleanHidden:false,directory:output,name:name,cancellation:stop,observer:hook)}
        else {_ = try NativeArchive.extract(raceDoc,selected:nil,directory:output,name:name,cancellation:stop,observer:hook)}
    }
    try expect(!FileManager.default.fileExists(atPath:output.appendingPathComponent(name).path) && stagesAreClean(),"last-moment cancellation prevents atomic commit and cleans private stage")
}
let afterCommitStop=NativeArchive.Cancellation()
let committed=try NativeArchive.extract(raceDoc,selected:nil,directory:output,name:"committed-before-cancel",cancellation:afterCommitStop,observer:{phase,_ in if phase == .afterCommit {afterCommitStop.cancel()} })
try expect(try Data(contentsOf:committed.appendingPathComponent("second.txt")) == Data("second original\n".utf8),"cancellation after atomic commit keeps the verified result")
let committedParent=root.appendingPathComponent("committed-parent",isDirectory:true)
try FileManager.default.createDirectory(at:committedParent,withIntermediateDirectories:false)
let movedParent=root.appendingPathComponent("committed-parent-moved",isDirectory:true)
var commitMessage=""
do {
    _ = try NativeArchive.extract(raceDoc,selected:nil,directory:committedParent,name:"result",observer:{phase,_ in
        if phase == .afterCommit {try FileManager.default.moveItem(at:committedParent,to:movedParent)}
    })
} catch {commitMessage=error.localizedDescription}
try expect(commitMessage.contains("结果已提交") && FileManager.default.fileExists(atPath:movedParent.appendingPathComponent("result/second.txt").path),"post-commit parent movement reports committed result honestly and preserves its actual location")
try rejects("payload identity replacement before publication") {
    _ = try NativeArchive.extract(raceDoc,selected:nil,directory:output,name:"foreign",observer:{ phase,stage in
        if phase == .beforePublish {
            let payload=stage.appendingPathComponent("payload")
            try FileManager.default.moveItem(at:payload,to:stage.appendingPathComponent("held-payload"))
            try FileManager.default.createDirectory(at:payload,withIntermediateDirectories:false)
            try Data("foreign".utf8).write(to:payload.appendingPathComponent("sentinel"))
        }
    })
}
try expect(!FileManager.default.fileExists(atPath:output.appendingPathComponent("foreign").path) && stagesAreClean(),"foreign payload cannot become a published result")
try rejects("8192-deep single archive path") {_ = try NativeArchive.inspect(root.appendingPathComponent("too-deep.zip"))}
try expect(try NativeArchive.inspect(root.appendingPathComponent("depth64.zip")).items.count == 1,"64-level depth stays within the documented bound")
try rejects("65-level archive path") {_ = try NativeArchive.inspect(root.appendingPathComponent("depth65.zip"))}
var pathLimit=NativeArchive.Budget();pathLimit.maxPathBytes=12
try rejects("aggregate UTF8 path bytes, including implicit prefixes") {_ = try NativeArchive.inspect(root.appendingPathComponent("path-budget.zip"),budget:pathLimit)}
var nodeLimit=NativeArchive.Budget();nodeLimit.maxTreeNodes=3
try rejects("implicit tree node budget before filesystem or outline allocation") {_ = try NativeArchive.inspect(root.appendingPathComponent("node-budget.zip"),budget:nodeLimit)}
try rejects("independent outline validation also applies node budget") {try NativeArchive.validateTree([NativeArchive.Item(path:"a/b/c/d",size:0,kind:.file,mode:0o600,modified:0,encrypted:false)],budget:nodeLimit)}
try rejects("case variants cannot undercount actual outline nodes") {_ = try NativeArchive.inspect(root.appendingPathComponent("case-node-budget.zip"),budget:nodeLimit)}
var additionLimit=NativeArchive.Budget();additionLimit.maxTreeNodes=4
try rejects("added paths share the implicit-node budget") {_ = try NativeArchive.editedCopy(raceDoc,deleting:[],adding:[root.appendingPathComponent("added.txt")],cleanHidden:false,directory:output,name:"too-many-added.zip",budget:additionLimit)}
try rejects("added directories also enforce depth before allocation") {_ = try NativeArchive.editedCopy(raceDoc,deleting:[],adding:[root.appendingPathComponent("deep-added")],cleanHidden:false,directory:output,name:"too-deep-added.zip")}
let tokenA=UUID(),tokenB=UUID(),tokenC=UUID()
let contextA=NativeArchiveRequestContext(token:tokenA,document:raceDoc)
try expect(contextA.matches(token:tokenA,document:raceDoc),"modal context accepts its exact original document")
try expect(!contextA.matches(token:tokenB,document:raceDoc) && !contextA.matches(token:tokenA,document:captured),"late A picker/password cannot apply to B or another document revision")
try expect(!NativeArchiveRequestContext.isLatest(tokenB,token:tokenC) && NativeArchiveRequestContext.isLatest(tokenC,token:tokenC),"queued B is obsolete as soon as C enters, before a worker starts")
try expect(!contextA.matches(token:UUID(),document:nil),"view disappearance invalidates outstanding panel context")
var finishedA=0,finishedB=0,finishedC=0
let requestA=NativeArchivePreviewRequest(token:tokenA,completion:{_ in finishedA += 1})
let requestB=NativeArchivePreviewRequest(token:tokenB,completion:{_ in finishedB += 1})
let requestC=NativeArchivePreviewRequest(token:tokenC,completion:{_ in finishedC += 1})
// Inject the same late-worker/queued-request ordering as Finder A -> B -> C.
try expect(!requestA.proceed(ifLatest:tokenC) && !requestB.proceed(ifLatest:tokenC) && requestC.proceed(ifLatest:tokenC),"obsolete worker/queued request each completes instead of starting or replacing latest C")
requestA.finish();requestB.finish();requestC.finish();requestC.finish()
try expect(finishedA == 1 && finishedB == 1 && finishedC == 1,"every host request finishes exactly once even when discard and completion overlap")
try expect(try stagesAreClean(),"all error paths remove private stages")
print("PASS: \(checks) native archive workflow checks; ZIP/7Z real decode/rebuild/roundtrip, AES ZIP, selection, original preservation, path/link/FIFO/collision/source-change/budget/cancellation; host Powerbox/UI still requires real GUI acceptance")
} catch { fputs("FAIL native workflows: \(error.localizedDescription)\n",stderr);exit(1) }
'''


def main():
    with tempfile.TemporaryDirectory(prefix="gaocaozuo-native-workflow.", dir="/private/tmp") as temporary:
        root = Path(temporary)
        fixture = root / "fixture"
        (fixture / "目录").mkdir(parents=True)
        (fixture / "目录/one.txt").write_text("one original\n")
        (fixture / "second.txt").write_text("second original\n")
        (fixture / ".DS_Store").write_bytes(b"hidden fixture")
        (root / "added.txt").write_text("added new\n")
        (root / "original-stream.gz").write_bytes(gzip.compress(b"original compressed stream\n"))
        (root / "link.txt").symlink_to(root / "added.txt")
        os.mkfifo(root / "fifo")
        with zipfile.ZipFile(root / "source.zip", "w", zipfile.ZIP_DEFLATED) as archive:
            archive.write(fixture / "目录", "目录/")
            for path in sorted(fixture.rglob("*")):
                if path.is_file():
                    archive.write(path, path.relative_to(fixture).as_posix())
        with zipfile.ZipFile(root / "traversal.zip", "w") as archive:
            archive.writestr("../escape", b"no")
        with zipfile.ZipFile(root / "duplicate.zip", "w") as archive:
            archive.writestr("Case.txt", b"one")
            archive.writestr("case.txt", b"two")
        with zipfile.ZipFile(root / "file-parent.zip", "w") as archive:
            archive.writestr("parent", b"file")
            archive.writestr("parent/child", b"child")
        with zipfile.ZipFile(root / "links.zip", "w") as archive:
            entry = zipfile.ZipInfo("link")
            entry.create_system = 3
            entry.external_attr = (stat.S_IFLNK | 0o777) << 16
            archive.writestr(entry, "../outside")
        for filename, name in [("too-deep.zip", "/".join(["a"] * 8192)), ("depth64.zip", "/".join(["a"] * 64)), ("depth65.zip", "/".join(["a"] * 65))]:
            with zipfile.ZipFile(root / filename, "w") as archive:
                archive.writestr(name, b"bound")
        with zipfile.ZipFile(root / "path-budget.zip", "w") as archive:
            archive.writestr("abcdefg", b"a")
            archive.writestr("hijklmn", b"b")
        with zipfile.ZipFile(root / "node-budget.zip", "w") as archive:
            archive.writestr("a/b/c/d", b"d")
        with zipfile.ZipFile(root / "case-node-budget.zip", "w") as archive:
            archive.writestr("NodeA/x", b"x")
            archive.writestr("nodea/y", b"y")
        deep = root / "deep-added"
        for _ in range(65):
            deep.mkdir()
            deep = deep / "a"
        engine = str(PROJECT / "Resources/Tools/7zz")
        subprocess.run([engine, "a", "-t7z", str(root / "source.7z"), "目录", "second.txt", ".DS_Store"], cwd=fixture, check=True, stdout=subprocess.DEVNULL, timeout=20)
        subprocess.run([engine, "a", "-tzip", "-mem=AES256", "-pFixtureOnly", str(root / "encrypted.zip"), "added.txt"], cwd=root, check=True, stdout=subprocess.DEVNULL, timeout=20)
        runner = root / "main.swift"
        runner.write_text(RUNNER)
        executable = root / "native-workflows"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-Xfrontend", "-disable-sandbox", "-O",
            "-application-extension", "-target", "arm64-apple-macos14.0", "-module-cache-path", str(root / "cache"),
            *[str(p) for p in sorted((PROJECT / "QuickLookExtension").glob("*.swift"))],
            str(PROJECT / "Shared/GaoLocalization.swift"), str(runner),
            "-framework", "AppKit", "-framework", "QuickLookUI", "-framework", "PDFKit", "-framework", "ImageIO", "-framework", "CryptoKit", "-o", str(executable),
        ], check=True, timeout=90)
        subprocess.run([str(executable), str(root)], check=True, timeout=90)


if __name__ == "__main__":
    main()
