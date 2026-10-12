#!/usr/bin/env python3
"""Resolve real preview resources and launch its bundled metadata decoder."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import zipfile


PROJECT = Path(__file__).resolve().parent.parent
RUNNER = r'''
import AppKit
import Foundation

let extensionURL=URL(fileURLWithPath:CommandLine.arguments[1],isDirectory:true)
let extensionBundle=Bundle(url:extensionURL)!
let paths=try ArchiveQuickLookResources.resolve(classBundle:extensionBundle,mainBundle:Bundle.main)
precondition(paths.resource.resolvingSymlinksInPath().path == extensionURL.appendingPathComponent("Contents/Resources",isDirectory:true).resolvingSymlinksInPath().path)
let contents=extensionURL.deletingLastPathComponent().deletingLastPathComponent()
let expectedTools=contents.appendingPathComponent("Resources/Tools",isDirectory:true)
precondition(paths.tools.resolvingSymlinksInPath().path == expectedTools.resolvingSymlinksInPath().path,"Tools \(paths.tools.path), expected \(expectedTools.path)")
let fallback=try ArchiveQuickLookResources.resolve(classBundle:Bundle.main,mainBundle:extensionBundle)
precondition(fallback.resource == paths.resource)
do {
    _ = try ArchiveQuickLookResources.resolve(classBundle:Bundle.main,mainBundle:Bundle.main)
    preconditionFailure("Unrelated bundle was accepted")
} catch {precondition((error as NSError).domain == "GaoArchiveQuickLook" && (error as NSError).code == 3)}
let detached=Bundle(url:URL(fileURLWithPath:CommandLine.arguments[3],isDirectory:true))!
do {
    _ = try ArchiveQuickLookResources.resolve(classBundle:detached,mainBundle:Bundle.main)
    preconditionFailure("Detached extension was accepted")
} catch {precondition((error as NSError).code == 3)}
let decoder=paths.resource.appendingPathComponent("Tools/7zz")
precondition(FileManager.default.isExecutableFile(atPath:decoder.path))
let process=Process();process.executableURL=decoder;process.currentDirectoryURL=paths.resource
process.arguments=["l","-slt","-ba","-sccUTF-8","--",CommandLine.arguments[2]]
let pipe=Pipe();process.standardOutput=pipe;process.standardError=pipe
try process.run()
let listing=String(decoding:pipe.fileHandleForReading.readDataToEndOfFile(),as:UTF8.self)
process.waitUntilExit();precondition(process.terminationStatus == 0)
precondition(listing.contains("Path = 验证.txt"))
let rendered=ArchiveQuickLookDocument.render(filename:"验证包.zip",technicalListing:listing)
precondition(rendered.contains("验证.txt") && rendered.contains("1 项"))
print("Quick Look resource regression passed: Unicode/trailing directory URLs, bundle fallback/rejection, real 7zz metadata")
'''


def write_bundle(path, identifier):
    (path / "Contents").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": identifier, "CFBundlePackageType": "XPC!" if path.suffix == ".appex" else "APPL"
    }))


def main():
    with tempfile.TemporaryDirectory(prefix="gaocaozuo-ql-resource-tests.", dir="/private/tmp") as staging:
        root = Path(staging)
        app = root / "含中文 空格.app"
        write_bundle(app, "com.gaoseries.GaoCaoZuo")
        (app / "Contents/Resources/Tools").mkdir(parents=True)
        extension = app / "Contents/PlugIns/Preview.appex"
        write_bundle(extension, "com.gaoseries.GaoCaoZuo.QuickLook")
        detached = root / "Detached.appex"
        write_bundle(detached, "com.gaoseries.GaoCaoZuo.QuickLook")
        tools = extension / "Contents/Resources/Tools"
        tools.mkdir(parents=True)
        shutil.copyfile(PROJECT / "Resources/Tools/7zz", tools / "7zz")
        (tools / "7zz").chmod(0o755)
        archive = root / "验证包.zip"
        with zipfile.ZipFile(archive, "w") as output:
            output.writestr("验证.txt", "metadata preview")
        runner = root / "main.swift"
        runner.write_text(RUNNER)
        executable = root / "resource-tests"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-Xfrontend", "-disable-sandbox",
            "-target", "arm64-apple-macos14.0", "-module-cache-path", str(root / "cache"),
            str(PROJECT / "QuickLookExtension/ArchiveQuickLook.swift"), str(runner),
            "-framework", "AppKit", "-framework", "QuickLookUI", "-o", str(executable)
        ], check=True, timeout=60)
        subprocess.run([str(executable), str(extension), str(archive), str(detached)], check=True, timeout=20)


if __name__ == "__main__":
    main()
