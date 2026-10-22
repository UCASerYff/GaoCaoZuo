#!/usr/bin/env python3
import importlib.util
import json
from pathlib import Path
import plistlib
import sys
import tempfile

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT / "Scripts"))
import isolate_program_backup as isolate

checks = 0


def check(value):
    global checks
    checks += 1
    assert value


with tempfile.TemporaryDirectory(prefix="gao-backup-isolation-test-", dir="/private/tmp") as temporary:
    base = Path(temporary)
    for mode in ("success", "mismatch", "rollback"):
        folder = base / mode
        app = folder / "搞操作.app"
        (app / "Contents/MacOS").mkdir(parents=True)
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": isolate.safety.BUNDLE,
            "CFBundleExecutable": "fixture", "CFBundleVersion": "1"}))
        executable = app / "Contents/MacOS/fixture"
        executable.write_bytes(b"disposable simulated binary")
        executable.chmod(0o555)
        manifest = folder / "manifest.json"
        inventory = isolate.safety.inventory(app, permit_symlinks=True)
        receipt = {"backup_app": str(app), "protected_inventory": inventory}
        if mode == "mismatch":
            receipt["protected_inventory"] = {"state": "missing", "entries": {}}
        raw = json.dumps(receipt).encode()
        manifest.write_bytes(raw)
        if mode == "success":
            result = isolate.isolate(manifest, simulate=True)
            updated = json.loads(manifest.read_text())
            moved = Path(updated["backup_app"])
            check(result["state"] == "verified" and result["restorationCopyVerified"])
            check(not app.exists() and moved.parent.name == "程序.noindex")
            check(isolate.safety.inventory(moved, permit_symlinks=True) == inventory)
            check((moved.parent / "receipt-before-isolation.json").read_bytes() == raw)
        elif mode == "mismatch":
            try:
                isolate.isolate(manifest, simulate=True)
            except RuntimeError:
                check(app.exists() and manifest.read_bytes() == raw)
            else:
                raise AssertionError("Mismatching backup inventory was moved")
        else:
            original = isolate.safety.verify_signature
            def fail_restore(path, simulate):
                if "Recovery.noindex" in str(path):
                    raise RuntimeError("simulated restore verification failure")
                return original(path, simulate)
            isolate.safety.verify_signature = fail_restore
            try:
                try:
                    isolate.isolate(manifest, simulate=True)
                except RuntimeError:
                    check(app.exists() and manifest.read_bytes() == raw)
                    check(isolate.safety.inventory(app, permit_symlinks=True) == inventory)
                    check(json.loads((folder / "program-entry-isolation.json").read_text())["state"] == "rolled-back-needs-review")
                else:
                    raise AssertionError("Restore verification failure was ignored")
            finally:
                isolate.safety.verify_signature = original
print(f"Program backup isolation targeted checks passed ({checks}); no real app, registry, index or data mutations.")
