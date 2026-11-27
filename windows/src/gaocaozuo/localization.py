"""Use the repository's Mac language resources in the Windows workbench."""

import json
import os
from contextlib import contextmanager
from contextvars import ContextVar
from functools import lru_cache
from pathlib import Path

from gaocaozuo.resources import asset_dir

LANGUAGES = ("zh-Hans", "zh-Hant", "en", "ja", "de", "fr", "es", "it", "ko", "pt")
MAC_TSV_LANGUAGES = ("zh-Hans", "en", "ja", "de", "fr", "es", "ko", "pt")
_native_language = ContextVar("native_language", default="zh-Hans")


def build_catalog(repository):
    resources = repository / "Resources"
    catalog = json.loads((resources / "LocalizationCatalog.json").read_text(encoding="utf-8"))
    result = {lang: dict(catalog.get(lang, {})) for lang in LANGUAGES}
    for path in (resources / "LocalizationEnglish.tsv", resources / "LocalizationExchange.tsv", resources / "LocalizationInput.tsv"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                key, value = line.split("\t", 1)
                result["en"][key] = value
    for name in ("Common", "Window", "ArchiveNative", "Extensions", "Finder", "Safety", "InputSafety", "Completion",
                 "Dynamic", "FinalCloud", "ClipboardFinal", "ArchiveFinal"):
        for line in (resources / f"Localization{name}.tsv").read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                values = line.split("|")
                if name in {"Dynamic", "ArchiveFinal"}:
                    values = [value.replace("\\n", "\n") for value in values]
                for lang, value in zip(MAC_TSV_LANGUAGES, values, strict=True):
                    result[lang][values[0]] = value
    for path in (resources / "LocalizationOverrides").glob("*.json"):
        result[path.stem].update(json.loads(path.read_text(encoding="utf-8")))
    # Windows strings are usually the Chinese labels themselves. The Mac catalog also uses stable dotted keys.
    for key, label in result["zh-Hans"].items():
        for lang in LANGUAGES[1:]:
            if key in result[lang]:
                result[lang].setdefault(label, result[lang][key])
    for extra in sorted((repository / "windows").glob("localization-*.tsv")):
        for line in extra.read_text(encoding="utf-8").splitlines():
            if line and not line.startswith("#"):
                values = [value.replace("\\n", "\n") for value in line.split("|")]
                for lang, value in zip(LANGUAGES, values, strict=True):
                    if value:
                        result[lang][values[0]] = value
    return result


@lru_cache(maxsize=1)
def catalog():
    bundle = asset_dir() / "localization.json"
    if bundle.is_file():
        return json.loads(bundle.read_text(encoding="utf-8"))
    return build_catalog(Path(__file__).resolve().parents[3])


@lru_cache(maxsize=len(LANGUAGES))
def language_dictionary(lang):
    if lang == "zh-Hans" or lang not in LANGUAGES:
        return {}
    dictionaries = catalog()
    return {**dictionaries["en"], **dictionaries[lang]}


def resolve_native_language(setting):
    if setting in LANGUAGES:
        return setting
    if setting != "system" or os.name != "nt":
        return "zh-Hans"
    from ctypes import wintypes
    from locale import windows_locale

    from gaocaozuo.native_win import kernel

    identifier = kernel("GetUserDefaultUILanguage", wintypes.WORD)()
    parts = windows_locale.get(identifier, "en_US").split("_")
    if parts[0] == "zh":
        return "zh-Hant" if parts[-1] in {"TW", "HK", "MO", "CHT"} else "zh-Hans"
    return parts[0] if parts[0] in LANGUAGES else "en"


@contextmanager
def native_locale(setting):
    token = _native_language.set(resolve_native_language(setting))
    try:
        yield
    finally:
        _native_language.reset(token)


def native_text(key, **values):
    text = language_dictionary(_native_language.get()).get(key, key)
    return text.format_map(values) if values else text


if __name__ == "__main__":
    import sys

    Path(sys.argv[1]).write_text(json.dumps(build_catalog(Path(__file__).resolve().parents[3]), ensure_ascii=False,
                                              separators=(",", ":")), encoding="utf-8")
