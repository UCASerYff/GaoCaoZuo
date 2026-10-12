#!/usr/bin/env python3
"""Exercise the real in-process Quick Look reader, formats and preview budgets."""
from pathlib import Path
import bz2
import gzip
import lzma
import shutil
import struct
import subprocess
import tempfile
import zipfile
import zlib

PROJECT = Path(__file__).resolve().parent.parent
RUNNER = r'''
import AppKit
import Foundation

let url=URL(fileURLWithPath:CommandLine.arguments[1])
let mode=CommandLine.arguments.count>2 ? CommandLine.arguments[2] : "normal"
let roots=ArchiveQuickLookDocument.render(filename:"root.zip",technicalListing:"Path = /\nSize = 0\nFolder = +\n\nPath = ///\nSize = 0\nFolder = +\n\n")
precondition(roots.contains("2 项") && roots.contains("///"))
var limits=ArchiveQuickLookNative.Limits()
switch mode {
case "entries":limits.maxEntries=2
case "bytes":limits.maxReadBytes=32
case "timeout":limits.timeoutSeconds=0
case "declared":limits.maxDeclaredBytes=1
case "listing":limits.maxListingBytes=8
default:break
}
do {
    let listing=try ArchiveQuickLookNative.list(url:url,limits:limits)
    print(ArchiveQuickLookDocument.render(filename:url.lastPathComponent,technicalListing:listing))
} catch {print("PREVIEW_ERROR: "+error.localizedDescription)}
'''

def main():
    with tempfile.TemporaryDirectory(prefix="gaocaozuo-ql-native-tests.", dir="/private/tmp") as staging:
        root=Path(staging)
        fixtures=root/"fixtures"
        subprocess.run(["python3","-B",str(PROJECT/"Tests/ArchiveFixtures.py"),str(fixtures)],check=True,timeout=20)
        payload=root/"验证.txt";payload.write_text("read-only native preview\n")
        archive=root/"含中文 空格.zip"
        with zipfile.ZipFile(archive,"w",zipfile.ZIP_DEFLATED) as output:
            output.writestr("目录/",b"")
            output.writestr("目录/验证.txt",payload.read_bytes())
            output.writestr("second.txt",b"second")
        seven=root/"验证.7z"
        encrypted=root/"加密.zip"
        rar=root/"原创RAR4.rar"
        def rar_block(block):
            return struct.pack("<H",zlib.crc32(block)&0xffff)+block
        name=b"original.txt";body=payload.read_bytes()
        main_header=rar_block(struct.pack("<BHHHI",0x73,0,13,0,0))
        file_header=rar_block(struct.pack("<BHHIIBIIBBHI",0x74,0x8000,32+len(name),len(body),len(body),3,zlib.crc32(body),0,20,0x30,len(name),0o100644)+name)
        end_header=rar_block(struct.pack("<BHH",0x7b,0,7))
        rar.write_bytes(b"Rar!\x1a\x07\x00"+main_header+file_header+body+end_header)
        for target,flags in [(seven,["-t7z"]),(encrypted,["-tzip","-mem=AES256","-pPreviewFixtureOnly"] )]:
            subprocess.run([str(PROJECT/"Resources/Tools/7zz"),"a",*flags,str(target),payload.name],cwd=root,check=True,stdout=subprocess.DEVNULL,timeout=20)
        for suffix,compress in [("gz",gzip.compress),("bz2",bz2.compress),("xz",lzma.compress)]:
            (root/("单文件."+suffix)).write_bytes(compress(payload.read_bytes()))
        (root/"损坏.zip").write_bytes(b"not an archive")
        many=root/"多项目.zip"
        with zipfile.ZipFile(many,"w") as output:
            for index in range(4001):output.writestr(f"entry{index:04d}.txt",b"")
        runner=root/"main.swift";runner.write_text(RUNNER)
        executable=root/"native-tests"
        sources=root/"QuickLookExtension"
        shutil.copytree(PROJECT/"QuickLookExtension",sources)
        subprocess.run([
            "swiftc","-swift-version","5","-Xfrontend","-disable-sandbox","-O",
            "-target","arm64-apple-macos14.0","-module-cache-path",str(root/"cache"),
            *[str(p) for p in sorted(sources.glob("*.swift"))],str(runner),
            "-framework","AppKit","-framework","QuickLookUI","-o",str(executable)
        ],check=True,timeout=60)
        def preview(path,mode="normal"):
            result=subprocess.run([str(executable),str(path),mode],check=True,capture_output=True,text=True,timeout=10)
            return result.stdout
        plain=preview(archive)
        assert "验证.txt" in plain and "second.txt" in plain and "3 项" in plain,plain
        assert "验证.txt" in preview(seven)
        assert "original.txt" in preview(rar)
        assert "🔒" in preview(encrypted)
        for suffix in ("gz","bz2","xz"):
            text=preview(root/("单文件."+suffix))
            assert "单文件" in text and "大小未知" in text,text
        for name in ("links.tar","container.tar.gz","container.tgz","container.tar.xz","container.txz","container.tar.bz2","container.tbz2","container.tar.lz"):
            text=preview(fixtures/name)
            assert "run.sh" in text and "4 项" in text,(name,text)
        assert "hello" in preview(fixtures/"hello.lz")
        assert "ACE" in preview(fixtures/"original.ace") and "PREVIEW_ERROR" in preview(fixtures/"original.ace")
        for mode in ("entries","declared","listing"):
            text=preview(archive,mode)
            assert "已截断" in text and "已列出" in text,(mode,text)
        for mode in ("bytes","timeout"):
            assert "PREVIEW_ERROR" in preview(archive,mode)
        assert "PREVIEW_ERROR" in preview(root/"损坏.zip")
        assert "PREVIEW_ERROR" in preview(root)
        many_text=preview(many)
        assert "4001 项" in many_text and "仅显示前 4000 项" in many_text and "entry3999" in many_text and "entry4000" not in many_text
        assert archive.exists() and not (root/"目录").exists()
        print("Quick Look native regression passed: ZIP/AES/7Z/RAR4/TAR/gzip/bzip2/xz/lzip; Unicode, unknown size, encryption, entry/read/deadline/listing/declared budgets; no extraction")

if __name__=="__main__":main()
