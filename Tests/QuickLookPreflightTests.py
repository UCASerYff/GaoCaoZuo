#!/usr/bin/env python3
"""Exercise the real 7z Quick Look preflight with original, bounded fixtures.

No user archives are read. Tiny malicious fixtures contain oversized directory
*declarations* only; they never contain a large extracted member body.
"""
import lzma
import pathlib
import struct
import subprocess
import tempfile
import zlib

ROOT = pathlib.Path(__file__).resolve().parents[1]
SWIFT = ROOT / 'QuickLookExtension/ArchiveQuickLookPreflight.swift'
SEVEN = ROOT / 'Resources/Tools/7zz'


def number(value):
    for extra in range(8):
        if value < (1 << (7 + extra * 7)):
            first = ((0xff << (8 - extra)) & 255) | (value >> (8 * extra))
            return bytes([first]) + value.to_bytes(8, 'little')[:extra]
    return b'\xff' + value.to_bytes(8, 'little')


def container(header, packed=b''):
    start = struct.pack('<QQI', len(packed), len(header), zlib.crc32(header))
    return b"7z\xbc\xaf\x27\x1c\x00\x04" + struct.pack('<I', zlib.crc32(start)) + start + packed + header


def encoded(decoded, properties=b'\x5d\x00\x00\x10\x00'):
    packed = lzma.compress(decoded, format=lzma.FORMAT_RAW,
                           filters=[{'id': lzma.FILTER_LZMA1, 'dict_size': 1 << 20,
                                     'lc': 3, 'lp': 0, 'pb': 2}])
    header = (b'\x17\x06\x00\x01\x09' + number(len(packed)) +
              b'\x00\x07\x0b\x01\x00\x01\x23\x03\x01\x01\x05' + properties +
              b'\x0c' + number(len(decoded)) + b'\x0a\x01' +
              struct.pack('<I', zlib.crc32(decoded)) + b'\x00\x00')
    return container(header, packed)


HARNESS = r'''
import Foundation
@main struct Harness {
    static func main() throws {
        let root = URL(fileURLWithPath: CommandLine.arguments[1])
        var assertions = 0
        func test(_ name: String, expected: String? = nil, metadata: Int = 4*1024*1024,
                  dictionary: Int = 64*1024*1024, entries: Int = 10000,
                  data: UInt64 = 128*1024*1024, timeout: Double = 5) throws {
            let handle = try FileHandle(forReadingFrom: root.appendingPathComponent(name))
            defer { try? handle.close() }
            try handle.seek(toOffset: 3)
            let original = try handle.offset()
            var message: String?
            do {
                try ArchiveQuickLookPreflight.validate(handle: handle, maxMetadataBytes: metadata,
                    maxDictionaryBytes: dictionary, maxEntries: entries,
                    maxDataBytes: data, timeoutSeconds: timeout)
            } catch { message = error.localizedDescription }
            guard try handle.offset() == original else { fatalError("file offset changed") }
            assertions += 1
            if let expected {
                guard let message, message.contains(expected) else { fatalError("expected rejection: " + name) }
                // Public errors must never expose any absolute input path.
                guard !message.contains(root.path), !message.contains("/private/"),
                      !message.contains("/Users/") else { fatalError("path disclosed") }
                assertions += 2
            } else {
                guard message == nil else { fatalError("valid fixture rejected: " + name) }
                assertions += 1
            }
        }
        try test("single.7z")
        try test("default-multi.7z")
        try test("inline-multi.7z")
        try test("not-7z.zip")
        try test("huge-next-header.7z", expected: "格式异常")
        try test("huge-inline-count.7z", expected: "预算")
        try test("huge-encoded-output.7z", expected: "预算")
        try test("encoded-huge-count.7z", expected: "预算")
        try test("encoded-huge-dictionary.7z", expected: "预算")
        try test("bad-start-crc.7z", expected: "格式异常")
        try test("bad-next-crc.7z", expected: "格式异常")
        try test("truncated-number.7z", expected: "格式异常")
        try test("encrypted.7z", expected: "已加密")
        try test("default-multi.7z", expected: "预算", entries: 1)
        try test("single.7z", expected: "预算", metadata: 16)
        try test("single.7z", expected: "预算", data: 0)
        try test("default-multi.7z", expected: "预算", dictionary: 1)
        try test("single.7z", expected: "预算", timeout: 0)
        try test("single.7z", expected: "预算", timeout: .nan)
        print("Quick Look 7z preflight: \(assertions) assertions passed (original fixtures; no extraction)")
    }
}
'''

with tempfile.TemporaryDirectory(prefix='gaocaozuo-ql-preflight-') as temporary:
    root = pathlib.Path(temporary)
    first = root / 'payload.txt'
    second = root / ('another-' + 'name' * 30 + '.txt')
    first.write_bytes(b'GaoCaoZuo original Quick Look fixture\n')
    second.write_bytes(b'Original second metadata fixture\n')
    for name, files, options in [
        ('single.7z', [first], []),
        ('default-multi.7z', [first, second], []),
        ('inline-multi.7z', [first, second], ['-mhc=off']),
        ('encrypted.7z', [first, second], ['-pfixture-only-103', '-mhe=on'])
    ]:
        subprocess.run([str(SEVEN), 'a', '-y', '-t7z', str(root / name),
                        *map(str, files), *options], check=True,
                       stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, timeout=20)
    default = (root / 'default-multi.7z').read_bytes()
    default_header = 32 + int.from_bytes(default[12:20], 'little')
    assert default[default_header] == 0x17, 'normal multi-file fixture must exercise encoded header'
    inline = (root / 'inline-multi.7z').read_bytes()
    inline_header = 32 + int.from_bytes(inline[12:20], 'little')
    assert inline[inline_header] == 0x01, 'inline fixture must exercise unencoded header'
    (root / 'not-7z.zip').write_bytes(b'PK\x03\x04original-non-seven-zip')
    start = struct.pack('<QQI', 0, 1 << 40, 0)
    (root / 'huge-next-header.7z').write_bytes(b"7z\xbc\xaf\x27\x1c\x00\x04" + struct.pack('<I', zlib.crc32(start)) + start)
    (root / 'huge-inline-count.7z').write_bytes(container(b'\x01\x05' + number(1 << 40) + b'\x00\x00'))
    encoded_output = (b'\x17\x06\x00\x01\x09\x00\x00\x07\x0b\x01\x00\x01'
                      b'\x21\x21\x01\x00\x0c' + number(1 << 40) + b'\x00\x00')
    (root / 'huge-encoded-output.7z').write_bytes(container(encoded_output))
    (root / 'encoded-huge-count.7z').write_bytes(encoded(b'\x01\x05' + number(1 << 40) + b'\x00\x00'))
    (root / 'encoded-huge-dictionary.7z').write_bytes(encoded(b'\x01\x00', b'\x5d\xff\xff\xff\xff'))
    single = (root / 'single.7z').read_bytes()
    corrupt = bytearray(single); corrupt[8] ^= 1
    (root / 'bad-start-crc.7z').write_bytes(corrupt)
    corrupt = bytearray(single); corrupt[-1] ^= 1
    (root / 'bad-next-crc.7z').write_bytes(corrupt)
    (root / 'truncated-number.7z').write_bytes(container(b'\x01\x05\xff'))
    main = root / 'main.swift'; main.write_text(HARNESS)
    binary = root / 'preflight-tests'
    subprocess.run(['xcrun', 'swiftc', '-swift-version', '6', '-O', '-parse-as-library',
                    '-module-cache-path', str(root / 'module-cache'), str(SWIFT),
                    str(main), '-o', str(binary)], check=True, timeout=90)
    subprocess.run([str(binary), str(root)], check=True, timeout=20)
