#!/usr/bin/env python3
"""Canonical member identity across real Foundation.Process argv; no GUI or user files."""
from pathlib import Path
import hashlib
import io
import os
import shutil
import struct
import subprocess
import tarfile
import tempfile
import zipfile
import zlib

PROJECT = Path(__file__).resolve().parents[1]
SWIFT = r'''
import Foundation
import Darwin

@main enum MemberNormalizationChecks {
 @MainActor static func main() async {
    do {try await run()} catch {fputs("MEMBER_NORMALIZATION_FAILURE: \(error.localizedDescription)\n",stderr);exit(1)}
 }
 @MainActor static func run() async throws {
    let root=URL(fileURLWithPath:CommandLine.arguments[1]), tools=root.appendingPathComponent("Tools")
    let python=tools.appendingPathComponent("ArchivePython/python/bin/python3")
    let bridge=tools.appendingPathComponent("ArchiveBridge/archive_bridge.py")
    let fixtures=root.appendingPathComponent("fixtures"), fm=FileManager.default
    var checks=0
    func expect(_ condition:@autoclosure () throws->Bool,_ label:String)throws {
        guard try condition() else {throw ArchiveError.invalid(label)};checks += 1
    }
    func rejects(_ label:String,_ operation:() async throws->Void)async throws {
        do {try await operation()}
        catch ArchiveError.invalid(let reason) where reason.contains("重名或大小写冲突") {checks += 1;return}
        catch {throw ArchiveError.invalid(label+" failed for an unexpected reason: "+error.localizedDescription)}
        throw ArchiveError.invalid("unexpected success: "+label)
    }
    func process(_ arguments:[String],password:Data=Data([10]))throws->(Int32,Data,Data) {
        let task=Process(),input=Pipe(),output=Pipe(),errors=Pipe()
        task.executableURL=URL(fileURLWithPath:"/usr/bin/sandbox-exec")
        task.arguments=["-p","(version 1)(allow default)(deny network*)(deny file-write*)",python.path]+arguments
        task.standardInput=input;task.standardOutput=output;task.standardError=errors
        try task.run();try input.fileHandleForWriting.write(contentsOf:password);try input.fileHandleForWriting.close()
        let bytes=output.fileHandleForReading.readDataToEndOfFile(),error=errors.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit();return (task.terminationStatus,bytes,error)
    }
    func call(_ command:String,_ file:String,_ encoding:String,_ member:String?=nil)throws->(Int32,Data,Data) {
        var args=["-I","-B",bridge.path,command,"--gao-encoding="+encoding,"--gao-limit=1048576","--",fixtures.appendingPathComponent(file).path]
        if let member {args.append(member)}
        return try process(args)
    }
    let nfc="caf\u{e9}.txt",nfd="cafe\u{301}.txt"
    let probe=try process(["-I","-B","-c","import sys;print(' '.join(format(ord(c),'x') for c in sys.argv[1]))",nfc])
    try expect(probe.0==0,"Foundation argv probe succeeds: "+String(decoding:probe.2,as:UTF8.self))
    let scalars=String(decoding:probe.1,as:UTF8.self).trimmingCharacters(in:.whitespacesAndNewlines)
    try expect(scalars=="63 61 66 65 301 2e 74 78 74","real macOS Foundation.Process decomposes NFC member argv")
    print("Foundation argv probe: NFC input reached child as NFD")
    let cases:[(String,String,String,String)]=[
        ("cp437.ace","CP437",nfc,"ACE precomposed bytes\n"),
        ("utf8.ace","auto",nfd,"ACE decomposed bytes\n"),
        ("source.zip","auto","pre/"+nfc,"ZIP precomposed bytes\n"),
        ("source.zip","auto","decomposed/"+nfd,"ZIP decomposed bytes\n"),
        ("source.tar","auto","pre/"+nfc,"TAR precomposed bytes\n"),
        ("source.tar","auto","decomposed/"+nfd,"TAR decomposed bytes\n")]
    for (file,encoding,name,expected) in cases {
        let listing=try call("l",file,encoding)
        try expect(listing.0==0,"listing succeeds: "+file)
        // Apple's libarchive already returns NFD paths for TAR. Preserve that
        // backend spelling, while ACE/ZIP retain their own original strings.
        let listedName=file.hasSuffix(".tar") ? name.decomposedStringWithCanonicalMapping : name
        try expect(listing.1.range(of:Data(("Path = "+listedName+"\n").utf8)) != nil,"listing preserves backend Unicode bytes: "+file)
        for form in [name.precomposedStringWithCanonicalMapping,name.decomposedStringWithCanonicalMapping] {
            let result=try call("x",file,encoding,form)
            try expect(result.0==0 && result.1==Data(expected.utf8),"canonical-equivalent real subprocess selects exact bytes: "+file+" "+String(decoding:result.2,as:UTF8.self))
        }
        let wrong=try call("x",file,encoding,name.uppercased())
        try expect(wrong.0 != 0 && wrong.1.isEmpty && String(decoding:wrong.2,as:UTF8.self).contains("member not found"),"case mismatch never broadens selection: "+file)
        let different=try call("x",file,encoding,name.replacingOccurrences(of:nfc,with:"cafe.txt").replacingOccurrences(of:nfd,with:"cafe.txt"))
        try expect(different.0 != 0 && different.1.isEmpty,"non-equivalent member emits no bytes: "+file)
    }
    for (file,encoding) in [("cp437.ace","CP437"),("source.zip","auto"),("source.tar","auto")] {
        let ascii=try call("x",file,encoding,"ascii.txt")
        try expect(ascii.0==0 && ascii.1==Data("ASCII original bytes\n".utf8),"ASCII member unchanged: "+file)
    }
    // Exercise the production host, not just the adapter. The two distinct raw
    // names are canonically identical and must be refused before streaming.
    let service=ArchiveService(engineURL:tools.appendingPathComponent("7zz"))
    for file in ["collision.ace","collision.zip","collision.tar"] {
        let archive=fixtures.appendingPathComponent(file),original=try Data(contentsOf:archive)
        try await rejects("host canonical duplicate listing: "+file) {_ = try await service.list(archive:archive,password:nil)}
        let target=root.appendingPathComponent("refused-"+file)
        try await rejects("host canonical duplicate extraction: "+file) {_ = try await service.extract(archive:archive,to:target,password:nil,selected:[nfc])}
        try expect(!fm.fileExists(atPath:target.path) && service.lastResultReceipts.isEmpty,"canonical duplicate publishes no output/receipt: "+file)
        try expect(try Data(contentsOf:archive)==original,"canonical duplicate source preserved: "+file)
    }
    var options=ArchiveExtractionOptions();options.filenameEncoding="CP437"
    let ace=fixtures.appendingPathComponent("cp437.ace"),original=try Data(contentsOf:ace)
    for (index,selection) in [Optional<[String]>.none,[nfc],[nfd]].enumerated() {
        let target=root.appendingPathComponent("ace-output-\(index)")
        _=try await service.extract(archive:ace,to:target,password:nil,selected:selection,options:options)
        try expect(try Data(contentsOf:target.appendingPathComponent(nfc))==Data("ACE precomposed bytes\n".utf8),"production ACE CP437 full/selected extraction returns exact content")
        try expect(fm.fileExists(atPath:target.appendingPathComponent("ascii.txt").path)==(selection==nil),"production ACE selection excludes unselected ASCII member")
        try expect(try Data(contentsOf:ace)==original,"production ACE original remains unchanged")
    }
    try expect(try !fm.contentsOfDirectory(atPath:root.path).contains{$0.hasPrefix(".gaocaozuo-stage-")},"host success/failure staging cleaned")
    print("PASS: \(checks) member normalization checks; real Foundation argv, ACE/ZIP/native TAR, raw listing preservation, exact payloads, non-equivalent rejection, canonical duplicate host rejection; no GUI")
 }
}
'''


def ace_block(block):
    return struct.pack("<HH", (~zlib.crc32(block)) & 0xffff, len(block)) + block


def ace(members):
    # Original Stored ACE 1.0 members, using only public header/CRC fields.
    dosdate = ((2026 - 1980) << 25) | (10 << 21) | (12 << 16)
    main = struct.pack("<BH", 0, 0) + b"**ACE**" + struct.pack("<BBBBI", 10, 10, 3, 0, dosdate) + bytes(8) + b"\0"
    result = ace_block(main)
    for name, data in members:
        header = struct.pack("<BHII", 1, 1, len(data), len(data)) + struct.pack("<IIIBBHHH", dosdate, 32, (~zlib.crc32(data)) & 0xffffffff, 0, 0, 0, 0, len(name)) + name
        result += ace_block(header) + data
    return result


def fixtures(root):
    root.mkdir()
    nfc, nfd = "caf\u00e9.txt", "cafe\u0301.txt"
    ascii_member = (b"ascii.txt", b"ASCII original bytes\n")
    (root / "cp437.ace").write_bytes(ace([(nfc.encode("cp437"), b"ACE precomposed bytes\n"), ascii_member]))
    (root / "utf8.ace").write_bytes(ace([(nfd.encode(), b"ACE decomposed bytes\n"), ascii_member]))
    (root / "collision.ace").write_bytes(ace([(nfc.encode(), b"first\n"), (nfd.encode(), b"second\n")]))
    for suffix in ["zip", "tar"]:
        members = [("pre/" + nfc, (suffix.upper() + " precomposed bytes\n").encode()), ("decomposed/" + nfd, (suffix.upper() + " decomposed bytes\n").encode()), ("ascii.txt", b"ASCII original bytes\n")]
        for name, entries in [("source." + suffix, members), ("collision." + suffix, [(nfc, b"first\n"), (nfd, b"second\n")])]:
            if suffix == "zip":
                with zipfile.ZipFile(root / name, "x", compression=zipfile.ZIP_STORED) as archive:
                    for path, data in entries:
                        archive.writestr(path, data)
            else:
                with tarfile.open(root / name, "x", format=tarfile.PAX_FORMAT) as archive:
                    for path, data in entries:
                        item = tarfile.TarInfo(path); item.size = len(data); item.mode = 0o600
                        archive.addfile(item, io.BytesIO(data))


def main():
    with tempfile.TemporaryDirectory(prefix="gaocaozuo-member-normalization-", dir="/private/tmp") as temporary:
        root = Path(temporary); os.chmod(root, 0o700)
        fixtures(root / "fixtures")
        tools = root / "Tools"; tools.mkdir()
        (tools / "7zz").symlink_to(PROJECT / "Resources/Tools/7zz")
        (tools / "ArchivePython").symlink_to(PROJECT / "Resources/Tools/ArchivePython", target_is_directory=True)
        shutil.copytree(PROJECT / "Resources/Tools/ArchiveBridge", tools / "ArchiveBridge", ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
        sources = ["Sources/ArchiveService.swift", "Sources/ArchiveBatchStream.swift", "Sources/ArchiveEnhancementsCore.swift", "Sources/ArchiveMacMetadata.swift", "Sources/FileTools.swift", "Shared/GaoLocalization.swift"]
        frozen = []
        for name in sources:
            copy = root / name; copy.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(PROJECT / name, copy); frozen.append(str(copy))
        print("SOURCE_SHA256", {name: hashlib.sha256((root / name).read_bytes()).hexdigest() for name in sources}, flush=True)
        print("BRIDGE_SHA256", hashlib.sha256((tools / "ArchiveBridge/archive_bridge.py").read_bytes()).hexdigest(), flush=True)
        runner = root / "runner.swift"; runner.write_text(SWIFT)
        executable = root / "member-normalization"
        command = ["swiftc", "-swift-version", "5", "-O", "-target", "arm64-apple-macos14.0", "-module-cache-path", str(root / "cache"), str(runner), *frozen]
        for framework in ["AppKit", "CryptoKit", "CoreImage", "ImageIO", "UniformTypeIdentifiers"]:
            command += ["-framework", framework]
        subprocess.run(command + ["-o", str(executable)], check=True, timeout=120)
        subprocess.run([str(executable), str(root)], check=True, timeout=60)
        # Python's exec path preserves argv bytes, unlike Foundation. This
        # exercises the reverse canonical direction against libarchive's NFD
        # names as well as the ACE/ZIP original spellings, without changing any
        # metadata or allowing case/compatibility folding.
        direct_cases = [("cp437.ace", "CP437", "caf\u00e9.txt", b"ACE precomposed bytes\n"), ("utf8.ace", "auto", "cafe\u0301.txt", b"ACE decomposed bytes\n")]
        for suffix in ["zip", "tar"]:
            direct_cases += [("source." + suffix, "auto", "pre/caf\u00e9.txt", (suffix.upper() + " precomposed bytes\n").encode()), ("source." + suffix, "auto", "decomposed/cafe\u0301.txt", (suffix.upper() + " decomposed bytes\n").encode())]
        import unicodedata
        for file, encoding, name, expected in direct_cases:
            for form in ["NFC", "NFD"]:
                args = ["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)(deny network*)(deny file-write*)", str(tools / "ArchivePython/python/bin/python3"), "-I", "-B", str(tools / "ArchiveBridge/archive_bridge.py"), "x", "--gao-encoding=" + encoding, "--", str(root / "fixtures" / file), unicodedata.normalize(form, name)]
                result = subprocess.run(args, input=b"\n", capture_output=True, timeout=5)
                if result.returncode or result.stdout != expected:
                    raise AssertionError("direct canonical direction failed: " + file + " " + form + " " + result.stderr.decode())
        print("PASS: 12 reverse-direction canonical member subprocess checks; unchanged filename bytes", flush=True)


if __name__ == "__main__":
    main()
