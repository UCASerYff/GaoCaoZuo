import ast
import json
import re
from pathlib import Path

from gaocaozuo.localization import LANGUAGES, build_catalog, native_locale, native_text


REPO = Path(__file__).resolve().parents[2]
SOURCE = REPO / "windows" / "src" / "gaocaozuo"
HAN = re.compile(r"[\u3400-\u9fff]")
VARIABLES = re.compile(r"\{[a-zA-Z][a-zA-Z0-9_]*(?::\d+)?\}")


def test_long_windows_prompts_have_every_target_language():
    resources = build_catalog(REPO)
    messages = set()
    for name in ("app.js", "screenshot.js", "media_export.js"):
        for raw in re.findall(r'"(?:[^"\\\n]|\\.)*"', (SOURCE / "assets" / name).read_text(encoding="utf-8")):
            try:
                message = json.loads(raw)
            except ValueError:
                continue
            if len(HAN.findall(message)) >= 13:
                messages.add(message)
    for path in SOURCE.glob("*.py"):
        for call in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if not isinstance(call, ast.Call) or not isinstance(call.func, ast.Name) or call.func.id != "AppError" or not call.args:
                continue
            source = call.args[0]
            if isinstance(source, ast.Constant) and isinstance(source.value, str):
                message = source.value
            elif isinstance(source, ast.JoinedStr):
                message = "".join(part.value if isinstance(part, ast.Constant) else "{" + ast.unparse(part.value) + "}"
                                  for part in source.values)
            else:
                continue
            if len(HAN.findall(message)) >= 13:
                messages.add(message)
    assert len(messages) >= 100
    missing = [(language, key) for key in sorted(messages) for language in LANGUAGES[1:] if not resources[language].get(key)]
    assert not missing, missing


def test_native_window_prompts_localize_arguments_and_restore_context():
    key = "将在 {remaining} 秒后锁定屏幕。"
    for language in LANGUAGES:
        with native_locale(language):
            translated = native_text(key, remaining=30)
            assert "30" in translated and "{" not in translated
            assert (translated == key.format(remaining=30)) == (language == "zh-Hans")
    assert native_text("选择文件") == "选择文件"


def test_windows_prompt_tables_preserve_named_fields():
    for path in (REPO / "windows").glob("localization-*.tsv"):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line or line.startswith("#"):
                continue
            columns = line.split("|")
            assert len(columns) == len(LANGUAGES), (path.name, columns[0])
            keys = sorted(VARIABLES.findall(columns[0]))
            assert all(sorted(VARIABLES.findall(translation)) == keys for translation in columns[1:] if translation), (path.name, columns[0])
