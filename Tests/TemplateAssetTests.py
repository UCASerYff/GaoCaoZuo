#!/usr/bin/env python3
"""Validate original shipped templates and scan decompressed iWork metadata.
No user files, installed templates, or third-party template contents are read.
"""
from pathlib import Path
import getpass
import plistlib
import re
import struct
import zipfile
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[1] / 'Resources' / 'DocumentTemplates'
LOCAL_ACCOUNT = getpass.getuser().encode('utf-8').lower()

def snappy_raw(source):
    pos = 0
    length = 0
    shift = 0
    while True:
        byte = source[pos]; pos += 1
        length |= (byte & 127) << shift
        if byte < 128: break
        shift += 7
        assert shift < 35
    out = bytearray()
    while pos < len(source):
        tag = source[pos]; pos += 1
        kind = tag & 3
        if kind == 0:
            size = tag >> 2
            if size >= 60:
                count = size - 59
                size = int.from_bytes(source[pos:pos+count], 'little'); pos += count
            size += 1
            out.extend(source[pos:pos+size]); pos += size
        else:
            if kind == 1:
                size = 4 + ((tag >> 2) & 7)
                offset = ((tag & 224) << 3) | source[pos]; pos += 1
            else:
                size = 1 + (tag >> 2)
                count = 2 if kind == 2 else 4
                offset = int.from_bytes(source[pos:pos+count], 'little'); pos += count
            assert 0 < offset <= len(out)
            for _ in range(size): out.append(out[-offset])
        assert len(out) <= length
    assert len(out) == length
    return bytes(out)

def iwa_uncompress(source):
    out = bytearray(); pos = 0
    while pos < len(source):
        assert source[pos] == 0, 'Unknown IWA framing'
        size = int.from_bytes(source[pos+1:pos+4], 'little'); pos += 4
        assert pos + size <= len(source)
        out.extend(snappy_raw(source[pos:pos+size])); pos += size
    return bytes(out)

count = 0
for ext, main in [('docx','word/document.xml'),('xlsx','xl/workbook.xml'),('pptx','ppt/presentation.xml')]:
    with zipfile.ZipFile(ROOT / ('Blank.'+ext)) as archive:
        assert archive.testzip() is None
        assert main in archive.namelist()
        for name in archive.namelist():
            if name.endswith('.xml') or name.endswith('.rels'): ET.fromstring(archive.read(name))
        core = ET.fromstring(archive.read('docProps/core.xml'))
        for node in core:
            if node.tag.endswith('creator') or node.tag.endswith('lastModifiedBy'):
                assert not node.text
        count += 1
for ext in ['pages','numbers','key']:
    with zipfile.ZipFile(ROOT / ('Blank.'+ext)) as archive:
        assert archive.testzip() is None
        assert any(name.endswith('.iwa') for name in archive.namelist())
        metadata = plistlib.loads(archive.read('Metadata/Properties.plist'))
        assert metadata['hasExternalReferenceOrMissingOrUnmaterializedRemoteData'] is False
        for name in archive.namelist():
            data = archive.read(name)
            if name.endswith('.iwa'): data = iwa_uncompress(data)
            # Test the current local account marker without storing or printing it.
            lowered = data.lower()
            assert b'/users/' not in lowered, f'Local path in {ext} asset'
            if len(LOCAL_ACCOUNT) > 4:
                assert LOCAL_ACCOUNT not in lowered, f'Account marker in {ext} asset'
            assert not re.search(rb'[a-z0-9_.+\-]+@(?:qq|163|gmail|outlook|icloud)\.com', lowered), f'Email in {ext} asset'
        count += 1
psd = (ROOT / 'Blank.psd').read_bytes()
header = struct.unpack('>4sH6sHIIHH', psd[:26])
assert header == (b'8BPS',1,bytes(6),3,512,512,8,3)
assert psd[26:40] == bytes(14)
assert len(psd) == 40 + 512*512*3
assert set(psd[40:]) == {255}
count += 1
assert (ROOT / 'Blank.rtf').read_bytes().startswith(b'{\\rtf1')
count += 1
ET.fromstring((ROOT / 'Blank.xml').read_bytes())
count += 1
print(f'Template assets: {count} native formats passed; iWork decompressed metadata contains no tested private markers.')
