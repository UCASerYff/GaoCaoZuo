#!/usr/bin/env python3
"""Explicit Finder translations and format checks; no GUI or fallback acceptance."""
import json
import re
import runpy
from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]
LANGUAGES=['zh-Hans','en','ja','de','fr','es','ko','pt']
catalog=runpy.run_path(str(ROOT/'Scripts/prepare-localizations.py'))['catalog']()
placeholder=re.compile(r'%(?:\d+\$)?(?:ld|@|d|f|s|u)')
rows={}
for number,line in enumerate((ROOT/'Resources/LocalizationFinder.tsv').read_text().splitlines(),1):
    if not line or line.startswith('#'):continue
    values=line.split('|')
    assert len(values) == 8,(number,'column count')
    assert values[0] not in rows,(number,'duplicate source key')
    assert all(value.strip() for value in values),(number,'empty value')
    for language,value in zip(LANGUAGES,values):
        assert placeholder.findall(value) == placeholder.findall(values[0]),(number,language,'format mismatch')
        # Reviewed per-language overrides may replace a wording. They remain
        # explicit translations; generated English fallback is not in catalog().
        assert values[0] in catalog[language],(number,language,'effective explicit translation missing')
        assert placeholder.findall(catalog[language][values[0]]) == placeholder.findall(values[0]),(number,language,'effective format mismatch')
    rows[values[0]]=values

# These sources use Chinese keys for displayed strings; old migration labels
# are historical data, never new interface labels.
ignored={'打开 iShot','用 iShot 打开图片','DiskMap 分析'}
for filename in ['Sources/FinderPreferences.swift','Shared/FinderMenuSnapshot.swift','Sources/FileAppAdapter.swift']:
    for raw in re.findall(r'"((?:\\.|[^"\\])*)"',(ROOT/filename).read_text()):
        if '\\(' in raw or not re.search('[\u4e00-\u9fff]',raw):continue
        key=json.loads('"'+raw+'"')
        if key in ignored:continue
        for language in LANGUAGES:
            assert key in catalog[language],(filename,key,language,'no explicit translation')
print(f'{len(rows)} explicit Finder/settings/application-open rows verified in 8 languages; no GUI layout, native-app consumption or fallback counted.')
