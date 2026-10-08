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
from types import SimpleNamespace

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
    extension = path / "Contents/PlugIns/GaoFinderSync.appex"
    (extension / "Contents/MacOS").mkdir(parents=True)
    (extension / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": BUNDLE + ".FinderSync", "CFBundleExecutable": "GaoFinderSync",
        "CFBundlePackageType": "XPC!", "NSExtension": {"NSExtensionPointIdentifier": "com.apple.FinderSync"}
    }))
    (extension / "Contents/MacOS/GaoFinderSync").write_bytes(payload + b" extension")


def registration_regressions(installer, root):
    """No system command runs here; assert exact paths, order and failure recovery."""
    def pending(name):
        case = root / name
        target = case / "Applications/搞操作.app"
        stage = target.parent / (".gaocaozuo-install-" + name)
        previous = stage / "previous.app"
        fixture(target, "1.01", b"candidate " + name.encode())
        fixture(previous, "1.00", b"previous " + name.encode())
        path = case / "Backups/transaction/manifest.json"
        path.parent.mkdir(parents=True)
        manifest = {
            "format": 1, "bundle_id": BUNDLE, "nonce": name,
            "state": "installed_pending_verification", "version": "1.01", "build": "2",
            "target_app": str(target), "stage_dir": str(stage), "manifest_path": str(path),
            "backup_root": str(path.parent.parent), "had_previous": True, "simulate": False,
            "candidate_inventory": installer.inventory(target, permit_symlinks=True),
            "previous_inventory": installer.inventory(previous, permit_symlinks=True),
            "backups": {key: {"inventory": {"state": "missing", "entries": {}}} for key in ("data", "preferences")}
        }
        installer.atomic_json(path, manifest)
        return target, stage, previous, path

    def commands(app, remove):
        return [[installer.LSREGISTER, "-u" if remove else "-f", str(app)],
                [installer.PLUGIN_KIT, "-r" if remove else "-a", str(app / "Contents/PlugIns/GaoFinderSync.appex")]]

    # The complete old pair is unregistered before the installed pair is added;
    # the old app is checked for running processes and deleted only after success.
    target, stage, previous, path = pending("registration-order")
    events = []
    real_rmtree = shutil.rmtree
    def delete(candidate):
        events.append(["delete", str(candidate)])
        real_rmtree(candidate)
    with unittest.mock.patch.object(installer, "verify_signature", side_effect=lambda p, _: installer.app_info(p)), \
         unittest.mock.patch.object(installer, "ensure_not_running", side_effect=lambda p, _: events.append(["stopped", str(p)])), \
         unittest.mock.patch.object(installer, "run", side_effect=lambda argv: events.append(argv) or ""), \
         unittest.mock.patch.object(installer, "cleanup_old_releases"), \
         unittest.mock.patch.object(installer.shutil, "rmtree", side_effect=delete):
        installer.finalize(SimpleNamespace(manifest=str(path), rollback=False))
    assert events == [["stopped", str(previous)]] + commands(previous, True) + commands(target, False) + [["delete", str(stage)]], events
    assert json.loads(path.read_text())["state"] == "verified"

    # A failed plug-in registration retains the pending old program and manifest.
    target, stage, previous, path = pending("registration-failure")
    def registration_failure(argv):
        if argv == commands(target, False)[1]:
            raise RuntimeError("simulated pluginkit failure")
        return ""
    with unittest.mock.patch.object(installer, "verify_signature"), \
         unittest.mock.patch.object(installer, "ensure_not_running"), \
         unittest.mock.patch.object(installer, "run", side_effect=registration_failure):
        try:
            installer.finalize(SimpleNamespace(manifest=str(path), rollback=False))
            raise AssertionError("Registration failure was ignored")
        except RuntimeError as error:
            assert "simulated pluginkit failure" in str(error)
    assert previous.exists() and json.loads(path.read_text())["state"] == "installed_pending_verification"

    # An automatically launched staging app must stop before any system mutation.
    target, stage, previous, path = pending("running-old-app")
    with unittest.mock.patch.object(installer, "verify_signature"), \
         unittest.mock.patch.object(installer, "ensure_not_running", side_effect=RuntimeError("old app running")), \
         unittest.mock.patch.object(installer, "run") as external:
        try:
            installer.finalize(SimpleNamespace(manifest=str(path), rollback=False))
            raise AssertionError("A running old app was removed")
        except RuntimeError as error:
            assert "old app running" in str(error)
        external.assert_not_called()
    assert previous.exists()

    # Validate the extension ID before touching even the matching parent app.
    wrong = root / "other-extension/搞操作.app"
    fixture(wrong, "1.00", b"fixture")
    plist = wrong / "Contents/PlugIns/GaoFinderSync.appex/Contents/Info.plist"
    info = plistlib.loads(plist.read_bytes()); info["CFBundleIdentifier"] = "com.example.OtherApp.FinderSync"
    plist.write_bytes(plistlib.dumps(info))
    with unittest.mock.patch.object(installer, "run") as external:
        try:
            installer.register(wrong, False, remove=True)
            raise AssertionError("An unrelated extension was unregistered")
        except RuntimeError:
            pass
        external.assert_not_called()

    # pluginkit -r reports an absent exact registration as a nonzero exit.
    # Only that complete diagnostic is idempotent; never hide service/ACL failures.
    absent_app = root / "absent-plugin/搞操作.app"
    fixture(absent_app, "1.00", b"absent plugin fixture")
    remove_command = commands(absent_app, True)[1]
    expected_absent = "remove: no plugin at " + remove_command[-1]
    def simulated_plugin_result(message, stdout=False):
        def invoke(argv, **kwargs):
            if argv == remove_command:
                return subprocess.CompletedProcess(argv, 1, message + "\n" if stdout else "", "" if stdout else message + "\n")
            return subprocess.CompletedProcess(argv, 0, "", "")
        return invoke
    for in_stdout in (False, True):
        with unittest.mock.patch.object(installer.subprocess, "run", side_effect=simulated_plugin_result(expected_absent, in_stdout)) as external:
            installer.register(absent_app, False, remove=True)
            assert [call.args[0] for call in external.call_args_list] == commands(absent_app, True)
    for diagnostic in ("remove: connection interrupted", "remove: permission denied",
                       expected_absent + " and another error", "remove: no plugin at /Applications/Other.app/Other.appex"):
        with unittest.mock.patch.object(installer.subprocess, "run", side_effect=simulated_plugin_result(diagnostic)):
            try:
                installer.register(absent_app, False, remove=True)
                raise AssertionError("Unexpected pluginkit error was ignored: " + diagnostic)
            except installer.CommandFailure as error:
                assert error.stderr.strip() == diagnostic

    # LaunchServices also returns an absent-registration diagnostic on -u retry.
    # Require the exact checked app path and -10814; -f never tolerates this error.
    expected_scan = "failed to scan " + str(absent_app) + ": -10814"
    def simulated_scan_result(message, remove=True, stdout=False):
        def invoke(argv, **kwargs):
            if argv == commands(absent_app, remove)[0]:
                return subprocess.CompletedProcess(argv, 1, message + "\n" if stdout else "", "" if stdout else message + "\n")
            return subprocess.CompletedProcess(argv, 0, "", "")
        return invoke
    for diagnostic in (expected_scan, expected_scan + "\n from spotlight"):
        for in_stdout in (False, True):
            with unittest.mock.patch.object(installer.subprocess, "run", side_effect=simulated_scan_result(diagnostic, stdout=in_stdout)) as external:
                installer.register(absent_app, False, remove=True)
                assert [call.args[0] for call in external.call_args_list] == commands(absent_app, True)
    for diagnostic, remove in (("failed to scan /Applications/Other.app: -10814", True),
                               (expected_scan.replace("-10814", "-10810"), True),
                               (expected_scan + "\n permission denied", True),
                               (expected_scan, False)):
        with unittest.mock.patch.object(installer.subprocess, "run", side_effect=simulated_scan_result(diagnostic, remove=remove)) as external:
            try:
                installer.register(absent_app, False, remove=remove)
                raise AssertionError("Unexpected lsregister error was ignored: " + diagnostic)
            except installer.CommandFailure as error:
                assert error.stderr.strip() == diagnostic
            assert len(external.call_args_list) == 1

    # Rollback removes rediscovered stage registrations, preserves failure evidence,
    # and can resume if adding the restored extension failed after the file move.
    target, stage, previous, path = pending("rollback-retry")
    failed = stage / "failed-candidate.app"
    old_inventory = installer.inventory(previous, permit_symlinks=True)
    with unittest.mock.patch.object(installer, "verify_signature"), \
         unittest.mock.patch.object(installer, "ensure_not_running"), \
         unittest.mock.patch.object(installer, "run", side_effect=registration_failure):
        try:
            installer.finalize(SimpleNamespace(manifest=str(path), rollback=True))
            raise AssertionError("Rollback registration failure was ignored")
        except RuntimeError as error:
            assert "simulated pluginkit failure" in str(error)
    record = json.loads(path.read_text())
    assert record["state"] == "installed_pending_verification" and failed.exists()
    assert installer.inventory(target, permit_symlinks=True) == old_inventory
    assert record["failed_candidate"]["inventory"] == installer.inventory(failed, permit_symlinks=True)
    events = []
    with unittest.mock.patch.object(installer, "verify_signature"), \
         unittest.mock.patch.object(installer, "ensure_not_running"), \
         unittest.mock.patch.object(installer, "run", side_effect=lambda argv: events.append(argv) or ""):
        installer.finalize(SimpleNamespace(manifest=str(path), rollback=True))
    assert events == commands(failed, True) + commands(target, False), events
    record = json.loads(path.read_text())
    assert record["state"] == "rolled_back" and record["failed_candidate"]["removed_after_registration"]
    assert not stage.exists() and installer.inventory(target, permit_symlinks=True) == old_inventory


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
        registration_regressions(installer, root)
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
        print("Install tests passed: missing records, initial install, pending-install protection, update backups, nested attachments, private permissions, preferences, rollback, verified cleanup, wrong bundle rejection, unresolved and unreadable data rejection, damaged backup protection, precise app/extension registration order, running-old-app protection, foreign extension rejection, registration failure retention, exact absent-registration idempotence for pluginkit/LaunchServices, wrong-path/code and failed-add rejection, connection/permission error rejection, rollback retry and evidence, scoped release cleanup.")
    finally:
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
