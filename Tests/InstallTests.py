#!/usr/bin/python3
"""Installer regression tests use only a fresh system-temporary directory."""
import json
from pathlib import Path
import plistlib
import subprocess
import tempfile
import shutil
import importlib.util
import unittest.mock

PROJECT = Path(__file__).resolve().parent.parent
INSTALL = PROJECT / "Scripts/install.sh"
FINALIZE = PROJECT / "Scripts/finalize-install.sh"
BUNDLE = "com.gaoseries.GaoCaoZuo"


def invoke(command, expected=0):
    result = subprocess.run([str(item) for item in command], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    assert result.returncode == expected, result.stdout + result.stderr
    return result.stdout


def fixture(path, version, payload, bundle=BUNDLE):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": bundle, "CFBundleExecutable": "GaoCaoZuo",
        "CFBundleShortVersionString": version, "CFBundleVersion": str(int(round(float(version) * 100)) - 99)
    }))
    (path / "Contents/MacOS/GaoCaoZuo").write_bytes(payload)
    (path / "Contents/MacOS/GaoCaoZuo").chmod(0o755)


def main():
    root = Path(tempfile.mkdtemp(prefix="GaoActions-InstallTests-")).resolve()
    try:
        source = root / "new/搞操作.app"
        fixture(source, "1.00", b"initial candidate")
        target = root / "Applications/搞操作.app"
        data = root / "UserData"
        preferences = root / "Preferences.plist"
        backups = root / "Backups"
        args = [INSTALL, "--app", source, "--target", target, "--data-root", data,
                "--preferences", preferences, "--backup-root", backups, "--defer-cleanup", "--simulate"]

        def install():
            output = invoke(args)
            return Path(next(line[len("MANIFEST="):] for line in output.splitlines() if line.startswith("MANIFEST=")))

        # First install explicitly records missing data and preferences.
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        assert manifest["state"] == "installed_pending_verification"
        assert manifest["backups"]["data"]["inventory"]["state"] == "missing"
        assert manifest["backups"]["preferences"]["inventory"]["state"] == "missing"
        # A pending install cannot be overwritten before explicit verification.
        invoke(args, expected=1)
        invoke([FINALIZE, "--manifest", manifest_path, "--rollback"])
        assert not target.exists()
        assert not Path(manifest["stage_dir"]).exists()
        assert manifest_path.exists()

        # Verify a successful first install removes staging, and keeps the manifest.
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        invoke([FINALIZE, "--manifest", manifest_path, "--verified"])
        assert target.exists() and not Path(manifest["stage_dir"]).exists()
        assert json.loads(manifest_path.read_text())["state"] == "verified"

        # An update backs up attachments and preferences byte-for-byte.
        (data / "attachments/nested").mkdir(parents=True)
        (data / "database.sqlite").write_bytes(b"actual database\x00\x01")
        (data / "attachments/nested/图片.png").write_bytes(bytes(range(256)))
        prefs = plistlib.dumps({"fontSize": 17, "privateSetting": "kept local"})
        preferences.write_bytes(prefs)
        shutil.rmtree(source)
        fixture(source, "1.01", b"updated candidate")
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        previous = Path(manifest["stage_dir"]) / "previous.app"
        assert previous.exists()
        assert (previous / "Contents/MacOS/GaoCaoZuo").read_bytes() == b"initial candidate"
        backup_data = Path(manifest["backups"]["data"]["backup_path"])
        assert (backup_data / "database.sqlite").read_bytes() == (data / "database.sqlite").read_bytes()
        assert (backup_data / "attachments/nested/图片.png").read_bytes() == bytes(range(256))
        assert Path(manifest["backups"]["preferences"]["backup_path"]).read_bytes() == prefs
        assert backups.stat().st_mode & 0o777 == 0o700
        assert backup_data.stat().st_mode & 0o777 == 0o700
        assert (backup_data / "database.sqlite").stat().st_mode & 0o777 == 0o600
        assert manifest_path.stat().st_mode & 0o777 == 0o600
        invoke([FINALIZE, "--manifest", manifest_path, "--rollback"])
        assert (target / "Contents/MacOS/GaoCaoZuo").read_bytes() == b"initial candidate"
        assert preferences.read_bytes() == prefs and (data / "database.sqlite").exists()

        # After GUI verification, only the obsolete program and staging are removed.
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        invoke([FINALIZE, "--manifest", manifest_path, "--verified"])
        assert not Path(manifest["stage_dir"]).exists()
        assert Path(manifest["backups"]["data"]["backup_path"]).exists()
        assert (target / "Contents/MacOS/GaoCaoZuo").read_bytes() == b"updated candidate"

        # Wrong bundle IDs, damaged backups and unresolved attachments cannot be cleared.
        bad = root / "bad/搞操作.app"
        fixture(bad, "1.02", b"unrelated", bundle="com.example.OtherApp")
        bad_args = list(args); bad_args[bad_args.index("--app") + 1] = bad
        invoke(bad_args, expected=1)
        assert (target / "Contents/MacOS/GaoCaoZuo").read_bytes() == b"updated candidate"
        (data / "unresolved-attachment").symlink_to(root / "missing-attachment")
        invoke(args, expected=1)
        assert (target / "Contents/MacOS/GaoCaoZuo").read_bytes() == b"updated candidate"
        (data / "unresolved-attachment").unlink()
        manifest_path = install()
        manifest = json.loads(manifest_path.read_text())
        (Path(manifest["backups"]["data"]["backup_path"]) / "database.sqlite").write_bytes(b"damaged backup")
        invoke([FINALIZE, "--manifest", manifest_path, "--verified"], expected=1)
        assert (Path(manifest["stage_dir"]) / "previous.app").exists()
        # Permission failures must propagate instead of being treated as missing.
        spec = importlib.util.spec_from_file_location("installer",PROJECT / "Scripts/install_safety.py")
        installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(installer)
        with unittest.mock.patch.object(Path,"lstat",side_effect=PermissionError("test unreadable")):
            try:
                installer.inventory(root / "unreadable")
                raise AssertionError("Permission failure was treated as missing")
            except PermissionError:
                pass
        # Cleanup is confined to checked older artifacts of this independent app.
        installer.PROJECT = root / "project"
        release = installer.PROJECT / "Release"
        release.mkdir(parents=True)
        for name in ['GaoCaoZuo-1.00.dmg','GaoCaoZuo-1.00.dmg.sha256','GaoCaoZuo-1.01.dmg',
                     'GaoCaoZuo-1.02.dmg','GaoWenJian-1.00.dmg','personal-attachment.txt']:
            (release/name).write_bytes(b'test fixture')
        installer.cleanup_old_releases('1.01')
        assert (release/'GaoCaoZuo-1.00.dmg').exists()
        (release/'GaoCaoZuo-1.01.dmg.sha256').write_text(installer.digest_file(release/'GaoCaoZuo-1.01.dmg')+'  GaoCaoZuo-1.01.dmg\n')
        installer.cleanup_old_releases('1.01')
        assert not (release/'GaoCaoZuo-1.00.dmg').exists()
        assert not (release/'GaoCaoZuo-1.00.dmg.sha256').exists()
        assert (release/'GaoCaoZuo-1.02.dmg').exists()
        assert (release/'GaoWenJian-1.00.dmg').exists()
        assert (release/'personal-attachment.txt').exists()
        print("Install tests passed: missing records, initial install, pending-install protection, update backups, nested attachments, private permissions, preferences, rollback, verified cleanup, wrong bundle rejection, unresolved and unreadable data rejection, damaged backup protection, scoped release cleanup.")
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
