#!/usr/bin/env python3
"""Opt-in, command-line-only production archive benchmark. Never launches an App.

Example (both roots must contain reviewed Sources/Shared/Resources):
  python3 Tests/ArchivePerformanceBenchmark.py --baseline-root /tmp/frozen \
    --candidate-root . --output /tmp/archive-perf.json --run

The full profile intentionally includes three complete 10,000-member baseline
extractions. An old per-member decoder can take hours; no extrapolation replaces
those runs. Work is sequential, generated, private, bounded, and removed on exit.
"""
import argparse
import ctypes
import hashlib
import json
import os
from pathlib import Path
import platform
import random
import shutil
import struct
import subprocess
import tempfile
import threading
import time
import zlib
import zipfile

SEED = 20261015
LIMIT = 1024**3
CORE = ['ArchiveService.swift', 'ArchiveEnhancementsCore.swift',
        'ArchiveMacMetadata.swift', 'FileTools.swift']
SWIFT_MAIN = r'''import Foundation
import Darwin
final class BenchTrace: @unchecked Sendable {
 static let lock=NSLock(); static var events:[[String:Any]]=[]
 static func mark(_ name:String) { lock.lock();events.append(["event":name,"time":ProcessInfo.processInfo.systemUptime]);lock.unlock() }
}
@main enum BenchMain {
 @MainActor static func main() async throws {
  let a=CommandLine.arguments; let source=URL(fileURLWithPath:a[3]), destination=URL(fileURLWithPath:a[4])
  // This is an explicitly synthetic fixture password, never a user credential.
  let password:String?=a[6]=="encrypted" ? "original-fixture-中文-20261015" : nil
  let service=ArchiveService(engineURL:URL(fileURLWithPath:a[2]),creationIOObserver:{BenchTrace.mark("creation:"+String(describing:$0))})
  var before=rusage(), childrenBefore=rusage();getrusage(RUSAGE_SELF,&before);getrusage(RUSAGE_CHILDREN,&childrenBefore)
  var lastTick=ProcessInfo.processInfo.systemUptime, maxGap=0.0
  let ticker=Task { @MainActor in
   while !Task.isCancelled { try? await Task.sleep(nanoseconds:10_000_000); let now=ProcessInfo.processInfo.systemUptime; maxGap=max(maxGap,now-lastTick);lastTick=now }
  }
  let start=ProcessInfo.processInfo.systemUptime;BenchTrace.mark("start");var result:URL?;var failure:String?
  do {
   if a[1]=="create" { result=try await service.create(items:[source],destination:destination,format:a[5]=="zip" ? .zip:.sevenZip,password:password,splitMB:nil,solid:a[5]=="7z") }
   else if a[1]=="directory" { _=try await service.extractIntoDirectory(archive:source,to:destination,password:password) }
   else { result=try await service.extract(archive:source,to:destination,password:password,selected:a.count>7 ? [a[7]]:nil) }
  } catch { failure=error.localizedDescription }
  let elapsed=ProcessInfo.processInfo.systemUptime-start;ticker.cancel();BenchTrace.mark("end")
  var after=rusage(),childrenAfter=rusage();getrusage(RUSAGE_SELF,&after);getrusage(RUSAGE_CHILDREN,&childrenAfter)
  func cpu(_ v:rusage)->Double {Double(v.ru_utime.tv_sec+v.ru_stime.tv_sec)+Double(v.ru_utime.tv_usec+v.ru_stime.tv_usec)/1e6}
  var o:[String:Any]=["seconds":elapsed,"selfCPU":cpu(after)-cpu(before),"childCPU":cpu(childrenAfter)-cpu(childrenBefore),"selfPeakRSS":after.ru_maxrss,"childPeakRSS":childrenAfter.ru_maxrss,"events":BenchTrace.events,"processCount":BenchTrace.events.filter{($0["event"] as? String)?.hasPrefix("process:")==true}.count,"receiptCount":service.lastResultReceipts.count,"mainActorMaxTickGap":maxGap]
  if let result {o["resultFingerprint"]=try FileTools.archiveFingerprint(result)}
  if let failure {o["error"]=failure}
  print(String(decoding:try JSONSerialization.data(withJSONObject:o,options:[.sortedKeys]),as:UTF8.self))
  if failure != nil {exit(2)}
 }
}
'''


def sha(path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1024**2), b''):
            h.update(block)
    return h.hexdigest()


def clean(path):
    # Only caller-created private benchmark trees are passed here. Extraction
    # intentionally preserves read-only modes; grant deletion to these copies.
    if not path.exists():
        return
    for base, directories, _ in os.walk(path, followlinks=False):
        os.chmod(base, 0o700)
        for name in directories:
            child = Path(base) / name
            if not child.is_symlink():
                child.chmod(0o700)
    shutil.rmtree(path)


def fixtures(root):
    data = root / 'data'
    data.mkdir()
    rng = random.Random(SEED)
    for name, count, size, kind in [('small10000', 10000, 256, 'text'),
                                    ('large', 2, 16*1024**2, 'binary'),
                                    ('text', 8, 2*1024**2, 'text'),
                                    ('media', 8, 2*1024**2, 'png')]:
        folder = data / name
        folder.mkdir()
        for index in range(count):
            if kind == 'text':
                line = (f'fixture={name}; row={index:08d}; 原创性能样本' + chr(92) + 'n').encode()
                content = (line*((size+len(line)-1)//len(line)))[:size]
                suffix = '.txt'
            elif kind == 'png':
                # Valid already-compressed, generated RGBA PNG; no user media.
                def chunk(tag, payload):
                    return struct.pack('>I', len(payload)) + tag + payload + struct.pack('>I', zlib.crc32(tag+payload))
                width, height = 512, 1024
                pixels = b''.join(b'\0' + rng.randbytes(width*4) for _ in range(height))
                content = b'\x89PNG\r\n\x1a\n' + chunk(b'IHDR', struct.pack('>IIBBBBB', width, height, 8, 6, 0, 0, 0)) + chunk(b'IDAT', zlib.compress(pixels, 6)) + chunk(b'IEND', b'')
                suffix = '.png'
            else:
                content, suffix = rng.randbytes(size), '.bin'
            (folder/(f'{index:05d}'+suffix)).write_bytes(content)
    mixed = data/'mixed'; mixed.mkdir()
    for index in range(32):
        (mixed/f'{index:04d}.txt').write_bytes((f'original mixed row {index}\n'*100).encode())
    (mixed/'子目录').mkdir()
    (mixed/'子目录'/'quoted \' fixture.txt').write_bytes(b'original UTF-8 path fixture\n')
    (mixed/'executable.sh').write_bytes(b'#!/bin/sh\nexit 0\n'); (mixed/'executable.sh').chmod(0o755)
    value = b'original-generated-fixture'
    lib = ctypes.CDLL(None)
    if lib.setxattr(os.fsencode(mixed/'executable.sh'), b'com.gaoseries.perf-fixture', value, len(value), 0, 0):
        raise OSError('generated xattr fixture unavailable')
    encrypted = data/'encrypted'; encrypted.mkdir()
    for index in range(2):
        (encrypted/f'{index}.txt').write_bytes((f'original encryption fixture {index}\n'*2048).encode())
    for index in range(3):
        folder = data/f'multi-{index}'; folder.mkdir()
        (folder/'entry.txt').write_bytes((f'original independent package {index}\n'*32).encode())
    manifest = {str(path.relative_to(data)): {'size': path.stat().st_size, 'sha256': sha(path)}
                for path in sorted(data.rglob('*')) if path.is_file()}
    (root/'fixture-manifest.json').write_text(json.dumps({'seed': SEED, 'files': manifest}, sort_keys=True))
    assert sum(row['size'] for row in manifest.values()) < 96*1024**2
    return data, manifest


def instrument(text):
    text = text.replace('let engineURL = try engine()', 'BenchTrace.mark("process:" + (arguments.first ?? "?")); let engineURL = try engine()')
    text = text.replace('let archive = snapshot?.url ?? opened.url', 'BenchTrace.mark("snapshot-ready"); let archive = snapshot?.url ?? opened.url')
    text = text.replace('let entries = try await checkedEntries(archive: archive, password: password)\n        let selected', 'let entries = try await checkedEntries(archive: archive, password: password)\n        BenchTrace.mark("listed")\n        let selected')
    text = text.replace('try Self.verifyExtractedTree(payload, expected: expected)', 'BenchTrace.mark("decoded"); try Self.verifyExtractedTree(payload, expected: expected)')
    text = text.replace('try ArchiveMacMetadata.restore(in: payload)', 'try ArchiveMacMetadata.restore(in: payload); BenchTrace.mark("metadata")')
    text = text.replace('try snapshot?.verify()', 'BenchTrace.mark("receipt-fingerprinted"); try snapshot?.verify(); BenchTrace.mark("source-verified")')
    text = text.replace('try fm.moveItem(at: payload, to: destination)', 'BenchTrace.mark("fingerprinted"); try fm.moveItem(at: payload, to: destination)')
    text = text.replace('try ArchiveCreationIO.publish(volumes: publication.sources', 'BenchTrace.mark("fingerprinted"); try ArchiveCreationIO.publish(volumes: publication.sources')
    text = text.replace('lastResultReceipts = [receipt]', 'BenchTrace.mark("published"); lastResultReceipts = [receipt]')
    text = text.replace('lastResultReceipts = publication.receipts', 'BenchTrace.mark("published"); lastResultReceipts = publication.receipts')
    text = text.replace('output += "\\n正在验证压缩包完整性…\\n"', 'BenchTrace.mark("encoded"); output += "\\n正在验证压缩包完整性…\\n"')
    text = text.replace('let targets = volumes.map', 'BenchTrace.mark("tested"); let targets = volumes.map', 1)
    text = text.replace('observer?(.publishing)', 'BenchTrace.mark("creation-fingerprinted"); observer?(.publishing)', 1)
    text = text.replace('let result = destination.deletingLastPathComponent().appendingPathComponent(first.lastPathComponent)', 'BenchTrace.mark("published"); let result = destination.deletingLastPathComponent().appendingPathComponent(first.lastPathComponent)', 1)
    return text


def build(source, target):
    target.mkdir()
    for name in ['Sources', 'Shared', 'Resources']:
        shutil.copytree(source/name, target/name)
    hashes = {str(path.relative_to(target)): sha(path) for name in ['Sources', 'Shared', 'Resources']
              for path in (target/name).rglob('*') if path.is_file()}
    service = target/'Sources'/'ArchiveService.swift'
    service.write_text(instrument(service.read_text()))
    (target/'BenchMain.swift').write_text(SWIFT_MAIN)
    sources = [target/'Sources'/name for name in CORE]
    batch = target/'Sources'/'ArchiveBatchStream.swift'
    if batch.exists():
        sources.append(batch)
    command = ['swiftc', '-swift-version', '5', '-O', '-target', 'arm64-apple-macos14.0',
               '-module-cache-path', str(target/'cache'), str(target/'BenchMain.swift')]
    command += [str(path) for path in sources] + [str(target/'Shared'/'GaoLocalization.swift')]
    for framework in ['AppKit', 'CryptoKit', 'CoreImage', 'ImageIO', 'UniformTypeIdentifiers']:
        command += ['-framework', framework]
    command += ['-o', str(target/'bench')]
    subprocess.run(command, check=True)
    return hashes


def observe_disk(directory, stop, samples):
    while not stop.is_set():
        row = subprocess.run(['/usr/bin/du', '-sk', str(directory)], capture_output=True, text=True)
        if row.returncode == 0:
            samples.append(int(row.stdout.split()[0])*1024)
        stop.wait(1)


def run(binary, engine, operation, source, destination, format_, encryption, selected, job):
    stop, samples = threading.Event(), []
    observer = threading.Thread(target=observe_disk, args=(job, stop, samples), daemon=True)
    observer.start()
    started = time.time()
    try:
        command = [str(binary), operation, str(engine), str(source), str(destination), format_, encryption]
        if selected:
            command.append(selected)
        value = subprocess.run(command, capture_output=True, text=True, timeout=3700)
    finally:
        stop.set(); observer.join()
    result = json.loads(value.stdout)
    if value.returncode:
        raise RuntimeError(result.get('error', value.stderr))
    final_disk = subprocess.run(['/usr/bin/du', '-sk', str(job)], capture_output=True, text=True)
    if final_disk.returncode == 0:
        samples.append(int(final_disk.stdout.split()[0])*1024)
    result['sampledTemporaryPeakBytes'] = max(samples, default=0)
    result['diskSamplingSeconds'] = 1
    result['startedEpoch'] = started
    result['endedEpoch'] = time.time()
    return result


def supplementary(root, data, manifest, records):
    jobs, archives = root/'jobs', root/'archives'
    for format_ in ['zip', '7z']:
        fixed = archives/('encrypted.'+format_)
        for round_ in range(3):
            for label in ['baseline', 'candidate']:
                job = jobs/f'encrypted-{format_}-{label}-create-{round_}'; job.mkdir()
                target = job/('result.'+format_)
                value = run(root/label/'bench', root/label/'Resources'/'Tools'/'7zz', 'create', data/'encrypted', target, format_, 'encrypted', None, job)
                value.update(case='encrypted', format=format_, operation='create', label=label, round=round_, archiveBytes=target.stat().st_size)
                records.append(value)
                if label == 'baseline' and round_ == 0:
                    shutil.copy2(target, fixed)
                clean(job)
            for label in ['baseline', 'candidate']:
                job = jobs/f'encrypted-{format_}-{label}-extract-{round_}'; job.mkdir()
                target = job/'output'
                archive_hash = sha(fixed)
                value = run(root/label/'bench', root/label/'Resources'/'Tools'/'7zz', 'extract', fixed, target, format_, 'encrypted', None, job)
                observed = {str(path.relative_to(target)): {'size': path.stat().st_size, 'sha256': sha(path)}
                            for path in target.rglob('*') if path.is_file()}
                assert observed == {name: row for name, row in manifest.items() if name.startswith('encrypted/')}
                assert sha(fixed) == archive_hash, 'encrypted source archive changed'
                value.update(case='encrypted', format=format_, operation='extract', label=label, round=round_, archiveBytes=fixed.stat().st_size, archiveSHA256=archive_hash, contentVerified=True)
                records.append(value); clean(job)
    selected_zip = archives/'selected10000.zip'
    with zipfile.ZipFile(selected_zip, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=5) as archive:
        for path in sorted((data/'small10000').rglob('*')):
            archive.write(path, path.relative_to(data).as_posix())
    selected_7z = archives/'selected10000.7z'
    preparation = jobs/'prepare-selected-7z'; preparation.mkdir()
    run(root/'baseline'/'bench', root/'baseline'/'Resources'/'Tools'/'7zz', 'create', data/'small10000', preparation/'source.7z', '7z', '-', None, preparation)
    shutil.copy2(preparation/'source.7z', selected_7z); clean(preparation)
    selection = 'small10000/09999.txt'
    for format_, archive in [('zip', selected_zip), ('7z', selected_7z)]:
        for round_ in range(3):
            for label in ['baseline', 'candidate']:
                job = jobs/f'selected-{format_}-{label}-{round_}'; job.mkdir()
                target = job/'output'
                archive_hash = sha(archive)
                value = run(root/label/'bench', root/label/'Resources'/'Tools'/'7zz', 'extract', archive, target, format_, '-', selection, job)
                files = [path for path in target.rglob('*') if path.is_file()]
                assert len(files) == 1 and sha(files[0]) == manifest[selection]['sha256']
                assert sha(archive) == archive_hash, 'selected source archive changed'
                value.update(case='selected10000', format=format_, operation='extract-one', label=label, round=round_, archiveBytes=archive.stat().st_size, archiveSHA256=archive_hash, contentVerified=True)
                records.append(value); clean(job)
    packages = []
    for index in range(3):
        path = archives/f'independent-{index}.zip'
        with zipfile.ZipFile(path, 'x', compression=zipfile.ZIP_DEFLATED, compresslevel=5) as archive:
            source = data/f'multi-{index}'/'entry.txt'
            archive.write(source, source.relative_to(data).as_posix())
        packages.append(path)
    for round_ in range(3):
        for label in ['baseline', 'candidate']:
            for index, archive in enumerate(packages):
                job = jobs/f'multiple-{label}-{round_}-{index}'; job.mkdir()
                target = job/'output'
                archive_hash = sha(archive)
                value = run(root/label/'bench', root/label/'Resources'/'Tools'/'7zz', 'extract', archive, target, 'zip', '-', None, job)
                name = f'multi-{index}/entry.txt'
                assert sha(target/name) == manifest[name]['sha256']
                assert sha(archive) == archive_hash, 'independent source archive changed'
                value.update(case='three-independent-jobs', format='zip', operation='extract', label=label, round=round_, part=index, archiveBytes=archive.stat().st_size, archiveSHA256=archive_hash, contentVerified=True)
                records.append(value); clean(job)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--baseline-root', type=Path, required=True)
    parser.add_argument('--candidate-root', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--cases', default='small10000,large,text,media,mixed')
    parser.add_argument('--formats', default='zip,7z')
    parser.add_argument('--extras-only', action='store_true')
    parser.add_argument('--skip-extras', action='store_true')
    parser.add_argument('--run', action='store_true', help='explicitly run the potentially hours-long CLI benchmark')
    args = parser.parse_args()
    if not args.run:
        parser.error('--run is required; no benchmark or application was started')
    root = Path(tempfile.mkdtemp(prefix='GaoArchivePerformance-', dir='/private/tmp'))
    root.chmod(0o700)
    records = []
    try:
        if shutil.disk_usage(root).free < 4*LIMIT:
            raise RuntimeError('benchmark needs at least 4 GiB free; total work budget is 1 GiB')
        metadata = {'seed': SEED, 'machine': platform.machine(), 'kernel': platform.release(),
                    'startedAtUTC': time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime()),
                    'macOS': subprocess.check_output(['sw_vers', '-productVersion'], text=True).strip(),
                    'cpu': subprocess.check_output(['sysctl', '-n', 'machdep.cpu.brand_string'], text=True).strip(),
                    'physicalCPUs': int(subprocess.check_output(['sysctl', '-n', 'hw.physicalcpu'], text=True)),
                    'compressionLevel': 5, 'threads': '7zz automatic', 'sevenZipSolid': True,
                    'cachePolicy': 'first and later rounds, no cache purge or unrelated process changes',
                    'concurrentActivity': 'normal desktop and background development; no CPU/IO resource isolation',
                    'scope': 'instrumented production ArchiveService CLI, no App/GUI or competitor comparison'}
        metadata['sourceHashes'] = {}
        for label, source in [('baseline', args.baseline_root.resolve()), ('candidate', args.candidate_root.resolve())]:
            metadata['sourceHashes'][label] = build(source, root/label)
        archive_library = ctypes.CDLL('/usr/lib/libarchive.2.dylib')
        archive_library.archive_version_string.restype = ctypes.c_char_p
        metadata['libarchiveVersion'] = archive_library.archive_version_string().decode()
        metadata['backendVersions'] = {}
        for label in ['baseline', 'candidate']:
            engine = root/label/'Resources'/'Tools'/'7zz'
            text = subprocess.check_output([str(engine), 'i'], text=True)
            metadata['backendVersions'][label] = next(line for line in text.splitlines() if '7-Zip' in line)
            metadata['backendVersions'][label+'Python'] = subprocess.check_output([str(engine.parent/'ArchivePython'/'python'/'bin'/'python3'), '--version'], text=True).strip()
        data, manifest = fixtures(root)
        archives = root/'archives'; archives.mkdir()
        jobs = root/'jobs'; jobs.mkdir()
        for case in ([] if args.extras_only else args.cases.split(',')):
            if case not in ['small10000', 'large', 'text', 'media', 'mixed']:
                raise RuntimeError('unknown generated case')
            for format_ in args.formats.split(','):
                if format_ not in ['zip', '7z']:
                    raise RuntimeError('unknown archive format')
                archive = None
                for round_ in range(3):
                    for label in ['baseline', 'candidate']:
                        job = jobs/(case+'-'+format_+'-'+label+'-create-'+str(round_)); job.mkdir()
                        target = job/('result.'+format_)
                        result = run(root/label/'bench', root/label/'Resources'/'Tools'/'7zz', 'create', data/case, target, format_, '-', None, job)
                        result.update(case=case, format=format_, label=label, operation='create', round=round_, archiveBytes=target.stat().st_size, archiveSHA256=sha(target))
                        records.append(result)
                        if label == 'baseline' and round_ == 0:
                            archive = archives/(case+'.'+format_); shutil.copy2(target, archive)
                        clean(job)
                for round_ in range(3):
                    for label in ['baseline', 'candidate']:
                        job = jobs/(case+'-'+format_+'-'+label+'-extract-'+str(round_)); job.mkdir()
                        target = job/'output'
                        archive_hash = sha(archive)
                        result = run(root/label/'bench', root/label/'Resources'/'Tools'/'7zz', 'extract', archive, target, format_, '-', None, job)
                        observed = {str(path.relative_to(target)): {'size': path.stat().st_size, 'sha256': sha(path)}
                                    for path in target.rglob('*') if path.is_file()}
                        expected = {name: value for name, value in manifest.items() if name.startswith(case+'/')}
                        assert observed == expected, 'byte-exact extraction verification failed'
                        assert sha(archive) == archive_hash, 'source archive changed'
                        result.update(case=case, format=format_, label=label, operation='extract', round=round_, archiveBytes=archive.stat().st_size, archiveSHA256=archive_hash, contentVerified=True)
                        records.append(result); clean(job)
                args.output.write_text(json.dumps({'metadata': metadata, 'records': records}, indent=2))
                print(case, format_, 'three complete rounds per operation/build verified', flush=True)
        if not args.skip_extras:
            supplementary(root, data, manifest, records)
            print('encrypted ZIP/7Z, selected ZIP/7Z, three independent jobs verified', flush=True)
        assert {name: sha(data/name) for name in manifest} == {name: row['sha256'] for name, row in manifest.items()}
        metadata['sourceFixturesUnchanged'] = True
        args.output.write_text(json.dumps({'metadata': metadata, 'records': records}, indent=2))
    finally:
        clean(root)


if __name__ == '__main__':
    main()
