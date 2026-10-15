#!/usr/bin/env python3
"""Check explicit task02 translations, never counting generated English fallback.
This is a resource-format check, not full locale or GUI acceptance.
"""
import re
import runpy
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ['zh-Hans', 'en', 'ja', 'de', 'fr', 'es', 'ko', 'pt']
PLACEHOLDER = re.compile(r'%(?:\d+\$)?(?:ld|@|d|f|s|u)')
VARIABLE = re.compile(r'\{\w+\}')
SOURCE_SCOPE = ['PendingPasteReviewView.swift', 'OperationExtensionActions.swift']
REQUIRED = [
    '确认粘贴结果', '处理待确认粘贴',
    '请先处理待确认粘贴，再退出，以保留原剪贴板恢复选择。',
    '粘贴并确认后发送回车 (Enter)',
]


def main():
    rows = {}
    path = ROOT / 'Resources/LocalizationExtensions.tsv'
    for number, line in enumerate(path.read_text().splitlines(), 1):
        if not line or line.startswith('#'):
            continue
        values = line.split('|')
        assert len(values) == len(LANGUAGES), (number, 'column count')
        key = values[0]
        assert key not in rows, (number, 'duplicate source key')
        assert all(value.strip() for value in values), (number, 'empty translation')
        for language, value in zip(LANGUAGES, values):
            assert PLACEHOLDER.findall(value) == PLACEHOLDER.findall(key), (number, language, 'printf mismatch')
            assert VARIABLE.findall(value) == VARIABLE.findall(key), (number, language, 'template mismatch')
        rows[key] = values
    assert rows, 'translation table missing'
    explicit = runpy.run_path(str(ROOT / 'Scripts/prepare-localizations.py'))['catalog']()
    for key in rows:
        for language in LANGUAGES:
            assert key in explicit[language], (key, language, 'missing explicit entry')
            assert PLACEHOLDER.findall(explicit[language][key]) == PLACEHOLDER.findall(key), (key, language, 'effective format mismatch')
            assert VARIABLE.findall(explicit[language][key]) == VARIABLE.findall(key), (key, language, 'effective template mismatch')
    source_keys = set(REQUIRED)
    for filename in SOURCE_SCOPE:
        source = (ROOT / 'Sources' / filename).read_text()
        pattern = r'"((?:\\.|[^"\\])*)"' if filename == 'PendingPasteReviewView.swift' else r'L10n\.(?:text|format)\("((?:\\.|[^"\\])*)"'
        for raw in re.findall(pattern, source):
            if '\\(' in raw or not re.search(r'[\u4e00-\u9fff]', raw):
                continue
            source_keys.add(json.loads('"' + raw + '"'))
    for key in source_keys:
        for language in LANGUAGES:
            assert key in explicit[language], (key, language, 'source entry missing explicit translation')
    print(f'{len(rows)} explicit task02 translation entries passed in 8 languages; resource checks only, no GUI or fallback counted.')


if __name__ == '__main__':
    main()
