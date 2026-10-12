#!/usr/bin/env python3
"""Generate original, tiny archive fixtures; no third-party sample data or personal files."""
import bz2, gzip, io, lzma, pathlib, struct, sys, tarfile, zlib

root = pathlib.Path(sys.argv[1]); root.mkdir(parents=True, exist_ok=True)
payload = b'GaoCaoZuo archive fixture\n'

def ace_block(block):
    return struct.pack('<HH', (~zlib.crc32(block)) & 0xffff, len(block)) + block

def make_ace(filename, data):
    dosdate = ((2026-1980)<<25) | (10<<21) | (12<<16)
    header = struct.pack('<BH', 0, 0) + b'**ACE**' + struct.pack('<BBBBI', 10, 10, 3, 0, dosdate) + bytes(8) + b'\0'
    fileheader = struct.pack('<BHII', 1, 1, len(data), len(data)) + struct.pack('<IIIBBHHH', dosdate, 32, (~zlib.crc32(data)) & 0xffffffff, 0, 0, 0, 0, len(filename)) + filename
    return ace_block(header) + ace_block(fileheader) + data

(root/'original.ace').write_bytes(make_ace(b'hello.txt', payload))
(root/'cp437.ace').write_bytes(make_ace('caf\u00e9.txt'.encode('cp437'), payload))
(root/'unsafe.ace').write_bytes(make_ace(b'../escape.txt', payload))

def make_tar(unsafe=None):
    buffer = io.BytesIO()
    with tarfile.open(fileobj=buffer, mode='w', format=tarfile.USTAR_FORMAT) as tar:
        directory=tarfile.TarInfo('dir');directory.type=tarfile.DIRTYPE;directory.mode=0o755;directory.mtime=1_760_000_000;tar.addfile(directory)
        regular=tarfile.TarInfo('dir/run.sh');regular.size=len(payload);regular.mode=0o755;regular.mtime=1_760_000_000;tar.addfile(regular, io.BytesIO(payload))
        link=tarfile.TarInfo('dir/shortcut');link.type=tarfile.SYMTYPE;link.linkname=unsafe or 'run.sh';tar.addfile(link)
        hard=tarfile.TarInfo('dir/hard');hard.type=tarfile.LNKTYPE;hard.linkname='dir/run.sh';tar.addfile(hard)
    return buffer.getvalue()

tar = make_tar(); (root/'links.tar').write_bytes(tar)
(root/'escape-link.tar').write_bytes(make_tar('../../outside'))
for name, data in [('container.tar.gz',gzip.compress(tar)),('container.tgz',gzip.compress(tar)),('container.tar.xz',lzma.compress(tar)),('container.txz',lzma.compress(tar)),('container.tar.bz2',bz2.compress(tar)),('container.tbz2',bz2.compress(tar))]: (root/name).write_bytes(data)

def lzip(data):
    encoded=lzma.compress(data,format=lzma.FORMAT_RAW,filters=[{'id':lzma.FILTER_LZMA1,'dict_size':1<<20,'lc':3,'lp':0,'pb':2}])
    header=b'LZIP'+bytes([1,20])
    return header+encoded+struct.pack('<IQQ',zlib.crc32(data),len(data),len(header)+len(encoded)+20)
(root/'hello.lz').write_bytes(lzip(payload));(root/'container.tar.lz').write_bytes(lzip(tar))

def legacy_zip(filename, data):
    # ZIP stored method with a deliberately non-UTF8 CP932 name, as produced by older Windows tools.
    crc=zlib.crc32(data);local=struct.pack('<IHHHHHIIIHH',0x04034b50,20,0,0,0,0,crc,len(data),len(data),len(filename),0)+filename+data
    central=struct.pack('<IHHHHHHIIIHHHHHII',0x02014b50,20,20,0,0,0,0,crc,len(data),len(data),len(filename),0,0,0,0,0,0)+filename
    return local+central+struct.pack('<IHHHHIIH',0x06054b50,0,0,1,1,len(central),len(local),0)
(root/'cp932.zip').write_bytes(legacy_zip('\u30c6\u30b9\u30c8.txt'.encode('cp932'),payload))
(root/'payload.txt').write_bytes(payload)
