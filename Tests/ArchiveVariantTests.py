#!/usr/bin/env python3
"""Opt-in, online RAR5 decode verification; no fixtures/results enter the repository.

Sources: official libarchive v3.7.4 distribution COPYING and
libarchive/test/test_read_format_rar5.c (2018 Grzegorz Antoniak, BSD-2-Clause).
Only the fixed hello and generated mathematical payloads below are downloaded.
The distribution COPYING applies; these .uu files contain no contrary notice.
The fixtures remain temporary and are not redistributed by this project.

Run explicitly: python3 -B Tests/ArchiveVariantTests.py --repetitions 5
Network, TLS or hash failures fail closed. No TLS verification is disabled.
This is not called by Scripts/test.sh. Five runs on three tiny fixtures are not a broad
performance benchmark; measurements include process startup and decoder work.
"""
import argparse
import binascii
import ctypes
import hashlib
import json
import math
import os
from pathlib import Path
import platform
import re
import statistics
import struct
import subprocess
import tempfile
import time
import zlib

PROJECT = Path(__file__).resolve().parents[1]
BASE = "https://raw.githubusercontent.com/libarchive/libarchive/v3.7.4/"
UPSTREAM = {
    "COPYING": "b2cdf763345de2de34cebf54394df3c61a105c3b71288603c251f2fa638200ba",
    "libarchive/test/test_read_format_rar5.c": "78ad415ae1d5728a9a80b9811343b4809a40d9c5d9c752226988d17fe82c3891",
}
FIXTURES = [
    ("stored", "test_read_format_rar5_stored.rar", "ec73ba623a8e8eee4909dcdf45f0526ff9adc1d856d054ce742e6c1ba1fb5fa8", "35d75e315d164d2e329afc28f7d844f013271b4fcffd4ddd78efcdd114a383a7", 109),
    ("compressed", "test_read_format_rar5_compressed.rar", "7a87af5035430d2307f9a183b2da8a71c95b3c0a5b8e8d1f172ef3343d4b8620", "68f9d7e2662cd5bc5607ba9c6bf1edbf121cf3b08011a7d8643091791750a7c8", 436),
    ("solid", "test_read_format_rar5_multiple_files_solid.rar", "0184822d0b061ae1a705a46cf1ca4adb4981b9e37bdb6500a48530a19c56fd88", "0aa2c652c06304dedd93019663c1d52d5e85055d5fdb8045bfcc4345b90b4a0f", 677),
]

RUNNER = r'''
import Foundation
import Darwin
let args=CommandLine.arguments
do {
    guard args.count==5 else {throw NativeArchive.Failure(message:"runner arguments")}
    let archive=URL(fileURLWithPath:args[1]), expectedRoot=URL(fileURLWithPath:args[2])
    let mode=args[3], output=URL(fileURLWithPath:args[4])
    let document=try NativeArchive.inspect(archive)
    let expected=try FileManager.default.contentsOfDirectory(atPath:expectedRoot.path).sorted()
    guard document.items.allSatisfy({$0.kind == .file}),document.items.map(\.path).sorted()==expected else {throw NativeArchive.Failure(message:"unexpected decoded manifest")}
    if mode=="preview" {
        for name in expected {
            let wanted=try Data(contentsOf:expectedRoot.appendingPathComponent(name))
            guard try NativeArchive.memberData(document,path:name)==wanted else {throw NativeArchive.Failure(message:"decoded preview bytes differ")}
        }
    } else {
        _=try NativeArchive.extract(document,selected:nil,directory:output,name:"payload")
    }
    print("DECODE_OK \(mode) \(expected.count)")
} catch {
    FileHandle.standardError.write(Data((error.localizedDescription+"\n").utf8));exit(1)
}
'''


def sha(data):
    return hashlib.sha256(data).hexdigest()


def download(relative, digest, root):
    target = root / (relative.replace("/", "_") + ".download")
    subprocess.run([
        "/usr/bin/curl", "--fail", "--silent", "--show-error", "--location",
        "--proto", "=https", "--tlsv1.2", "--connect-timeout", "15",
        "--max-time", "30", "--max-filesize", "1048576", "--output", str(target), BASE + relative,
    ], check=True, timeout=35)
    os.chmod(target, 0o600)
    if target.stat().st_size > 1048576:
        raise RuntimeError("upstream download exceeds budget")
    value = target.read_bytes()
    if sha(value) != digest:
        raise RuntimeError("fixed upstream SHA256 differs: " + relative)
    return value


def formula(size, magic):
    # Independent reconstruction of the v3.7.4 verify_data contract: LE32.
    return b"".join(struct.pack("<I", max(0, k*k - 3*k + 1 + magic) & 0xffffffff)
                    for k in range(1, size//4 + 1))


def expected(variant):
    if variant == "stored":
        return {"helloworld.txt": b"hello libarchive test suite!\n"}
    if variant == "compressed":
        return {"test.bin": formula(1200, 0)}
    return {"test%d.bin" % i: formula(4096, i) for i in range(1, 5)}


def validate(directory, wanted):
    actual = set()
    for path in directory.rglob("*"):
        if path.is_symlink() or not path.is_file():
            raise RuntimeError("unexpected output kind")
        name = path.relative_to(directory).as_posix()
        actual.add(name)
        data = path.read_bytes()
        if name not in wanted or len(data) != len(wanted[name]) or data != wanted[name]:
            raise RuntimeError("decoded output bytes differ: " + name)
        if zlib.crc32(data) != zlib.crc32(wanted[name]):
            raise RuntimeError("decoded CRC differs")
    if actual != set(wanted):
        raise RuntimeError("decoded output set differs")


def measured(command, output, wanted):
    started = time.perf_counter()
    run = subprocess.run(["/usr/bin/time", "-l", *command], capture_output=True, timeout=35)
    elapsed = (time.perf_counter() - started) * 1000
    stderr = run.stderr.decode("utf-8", "replace")
    match = re.search(r"(\d+)\s+maximum resident set size", stderr)
    result = {"decode_success": False, "elapsed_ms": round(elapsed, 3),
              "peak_rss_bytes": int(match.group(1)) if match else None}
    if run.returncode != 0:
        result["error"] = re.sub(r"/private/tmp/[^\s]+", "<temporary>", stderr[:1800]).strip()
        return result
    try:
        validate(output, wanted)
        result["decode_success"] = True
    except Exception as error:
        result["error"] = str(error)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--repetitions", type=int, default=5)
    args = parser.parse_args()
    if not 1 <= args.repetitions <= 10:
        parser.error("repetitions must be 1–10")
    if platform.system() != "Darwin":
        parser.error("this harness exercises the shipped macOS decoder")
    summary = {"upstream": "libarchive v3.7.4", "system": platform.platform(),
               "measurement_scope": "decoder subprocess launch+inspect/extract; Python byte comparison excluded",
               "not_tested": ["RAR5 encryption", "RAR5 multivolume (available selected upstream families include ELF/poetry)",
                              "ACE compressed/solid/encrypted (public corpus lacks unambiguous per-item licence evidence)"]}
    library = ctypes.CDLL("/usr/lib/libarchive.2.dylib")
    library.archive_version_string.restype = ctypes.c_char_p
    summary["native_library"] = library.archive_version_string().decode()
    engine = PROJECT / "Resources/Tools/7zz"
    version = subprocess.run([str(engine), "i"], check=True, capture_output=True, timeout=10)
    summary["primary_backend"] = next(s for s in version.stdout.decode().splitlines() if s.startswith("7-Zip"))
    source_files = [PROJECT / "QuickLookExtension/NativeArchive.swift", PROJECT / "QuickLookExtension/ArchiveQuickLookPreflight.swift",
                    PROJECT / "Shared/GaoLocalization.swift", engine]
    source_hashes = {p: sha(p.read_bytes()) for p in source_files}
    summary["local_decoder_sha256"] = {p.name: digest for p, digest in source_hashes.items()}
    all_passed = True
    with tempfile.TemporaryDirectory(prefix="GaoArchiveVariant-", dir="/private/tmp") as temporary:
        root = Path(temporary)
        for name, digest in UPSTREAM.items():
            download(name, digest, root)
        print(json.dumps({"provenance": UPSTREAM, **summary}, ensure_ascii=False), flush=True)
        runner = root / "main.swift"
        runner.write_text(RUNNER)
        executable = root / "native-decode"
        subprocess.run([
            "swiftc", "-swift-version", "5", "-Xfrontend", "-disable-sandbox", "-O",
            "-target", "arm64-apple-macos14.0", "-module-cache-path", str(root / "cache"),
            str(PROJECT / "QuickLookExtension/NativeArchive.swift"),
            str(PROJECT / "QuickLookExtension/ArchiveQuickLookPreflight.swift"),
            str(PROJECT / "Shared/GaoLocalization.swift"), str(runner),
            "-framework", "CryptoKit", "-o", str(executable),
        ], check=True, timeout=90)
        for variant, filename, encoded_sha, archive_sha, archive_size in FIXTURES:
            encoded = download("libarchive/test/" + filename + ".uu", encoded_sha, root)
            lines = encoded.splitlines()
            if lines[0] != ("begin 644 " + filename).encode() or lines[-1] != b"end":
                raise RuntimeError("unexpected uu wrapper")
            data = b"".join(binascii.a2b_uu(line) for line in lines[1:-1])
            if len(data) != archive_size or sha(data) != archive_sha:
                raise RuntimeError("decoded fixture hash differs")
            archive = root / filename
            archive.write_bytes(data)
            os.chmod(archive, 0o600)
            wanted = expected(variant)
            expected_root = root / (variant + "-expected")
            expected_root.mkdir()
            for name, payload in wanted.items():
                (expected_root / name).write_bytes(payload)
            report = {"variant": variant, "archive_sha256": archive_sha,
                      "expected": {name: {"size": len(payload), "crc32": "%08x" % zlib.crc32(payload),
                                           "sha256": sha(payload)} for name, payload in wanted.items()}}
            preview = subprocess.run([str(executable), str(archive), str(expected_root), "preview", str(root)], capture_output=True, timeout=35)
            report["native_memberData"] = {"decode_success": preview.returncode == 0,
                                            "error": preview.stderr.decode("utf-8", "replace")[:1000] if preview.returncode else None}
            all_passed &= preview.returncode == 0
            for backend in ["7zz", "NativeArchive"]:
                runs = []
                for index in range(args.repetitions):
                    output = root / (variant + "-" + backend + "-" + str(index))
                    output.mkdir()
                    if backend == "7zz":
                        command = [str(engine), "x", str(archive), "-o" + str(output), "-y", "-bd", "-bsp0"]
                        decoded = output
                    else:
                        command = [str(executable), str(archive), str(expected_root), "extract", str(output)]
                        decoded = output / "payload"
                    run = measured(command, decoded, wanted)
                    runs.append(run)
                    all_passed &= run["decode_success"]
                times = sorted(r["elapsed_ms"] for r in runs if r["decode_success"])
                peaks = [r["peak_rss_bytes"] for r in runs if r["decode_success"] and r["peak_rss_bytes"] is not None]
                report[backend] = {"runs": runs, "p50_ms": statistics.median(times) if times else None,
                                   "p95_ms_nearest_rank": times[math.ceil(len(times)*0.95)-1] if times else None,
                                   "max_peak_rss_bytes": max(peaks) if peaks else None,
                                   "all_decodes_verified": all(r["decode_success"] for r in runs)}
            print(json.dumps(report, ensure_ascii=False), flush=True)
        if any(sha(p.read_bytes()) != digest for p, digest in source_hashes.items()):
            raise RuntimeError("local decoder changed during verification; rerun against a stable source")
    print(json.dumps({"all_selected_decodes_verified": all_passed, "temporary_files_removed": True,
                      "coverage_is_limited_to_selected_fixtures": True}), flush=True)
    return 0 if all_passed else 1


if __name__ == "__main__":
    raise SystemExit(main())
