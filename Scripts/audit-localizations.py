#!/usr/bin/env python3
"""Read-only source/catalog inventory. This is never a GUI coverage score.

Swift interpolated/nested strings require manual review. All Chinese literals
are candidates (including diagnostics and tests' implementation messages), not
proof that every candidate is user-visible or reachable.
"""
import argparse
import json
from pathlib import Path
import re
import runpy

ROOT = Path(__file__).resolve().parent.parent
LANGUAGES = ['zh-Hans', 'en', 'ja', 'de', 'fr', 'es', 'ko', 'pt']
QUOTED = re.compile(r'"((?:\\.|[^"\\])*)"')
CJK = re.compile(r'[\u3400-\u9fff]')


def audit():
    catalog = runpy.run_path(str(ROOT / 'Scripts/prepare-localizations.py'))['catalog']()
    files = []
    for area in ['Sources', 'Shared', 'FinderExtension', 'QuickLookExtension']:
        for path in sorted((ROOT / area).glob('*.swift')):
            text = path.read_text()
            keys, dynamic = set(), set()
            for raw in QUOTED.findall(text):
                if not CJK.search(raw):
                    continue
                if '\\(' in raw:
                    dynamic.add(raw)
                    continue
                try:
                    keys.add(json.loads('"' + raw + '"'))
                except json.JSONDecodeError:
                    dynamic.add(raw)
            if not keys and not dynamic:
                continue
            files.append({
                'source': str(path.relative_to(ROOT)),
                'viewDeclarations': re.findall(r'\bstruct\s+(\w+)\s*:\s*[^\n{]*\bView\b', text),
                'literalCandidates': sorted(keys),
                'interpolatedOrUnparsedCandidates': sorted(dynamic),
                'missingExplicitByLanguage': {language: sorted(keys - catalog[language].keys()) for language in LANGUAGES},
                'layoutEvidence': 'not-executed',
            })
    return {
        'scope': 'lexical source candidates and explicit catalog entries only',
        'guiLayoutVerified': False,
        'fallbackCountedAsTranslation': False,
        'dynamicInterpolationFullyParsed': False,
        'sourceCandidatesEstablishFullInterfaceCoverage': False,
        'catalogEntryCounts': {language: len(catalog[language]) for language in LANGUAGES},
        'files': files,
    }


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    args = parser.parse_args()
    report = audit()
    with args.output.open('x', encoding='utf-8') as stream:
        json.dump(report, stream, ensure_ascii=False, indent=2)
        stream.write('\n')
    args.output.chmod(0o600)
    print(f'{len(report["files"])} source files inventoried; no GUI/layout acceptance implied.')
