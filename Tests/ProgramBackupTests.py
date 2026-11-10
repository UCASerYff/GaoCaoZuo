#!/usr/bin/python3
"""Fault-injected program-retention tests; all fixtures live below .noindex."""
import copy
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest import mock
import uuid


PROJECT = Path(__file__).resolve().parent.parent


def fixture(path, version, payload):
    (path / "Contents/MacOS").mkdir(parents=True)
    (path / "Contents/Info.plist").write_bytes(plistlib.dumps({
        "CFBundleIdentifier": "com.gaoseries.GaoCaoZuo",
        "CFBundleExecutable": "GaoCaoZuo",
        "CFBundleShortVersionString": version,
        "CFBundleVersion": "1" if version == "1.00" else "2",
    }))
    executable = path / "Contents/MacOS/GaoCaoZuo"
    executable.write_bytes(payload)
    executable.chmod(0o755)


class ProgramBackupTests(unittest.TestCase):
    def setUp(self):
        # The non-indexed ancestor exists before any .app fixture is generated.
        temporary = tempfile.TemporaryDirectory(
            prefix="GaoActions-ProgramBackupTests-", suffix=".noindex")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        self.assertTrue(self.root.name.endswith(".noindex"))
        spec = importlib.util.spec_from_file_location(
            "program_backup_installer_" + uuid.uuid4().hex,
            PROJECT / "Scripts/install_safety.py")
        self.installer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.installer)
        self.nonce = uuid.uuid4().hex
        self.target = self.root / "Applications/搞操作.app"
        self.stage = self.target.parent / (
            ".gaocaozuo-install-" + self.nonce + ".noindex")
        self.previous = self.stage / "previous.app"
        fixture(self.target, "1.01", b"candidate program")
        fixture(self.previous, "1.00", b"original program")
        self.stage.chmod(0o700)
        self.path = self.root / "Backups" / ("安装-" + self.nonce) / "manifest.json"
        self.path.parent.mkdir(mode=0o700, parents=True)
        self.path.parent.chmod(0o700)
        self.backup = self.path.parent / "Program.noindex/搞操作.app"
        self.data = self.root / "UserData"
        (self.data / "attachments/nested").mkdir(parents=True)
        (self.data / "database.sqlite").write_bytes(b"isolated database\x00\x01")
        (self.data / "attachments/nested/image.bin").write_bytes(bytes(range(256)))
        self.preferences = self.root / "Preferences.plist"
        self.preferences.write_bytes(plistlib.dumps({"setting": "preserved"}))
        data_backup = self.path.parent / "UserData"
        prefs_backup = self.path.parent / "Preferences.plist"
        shutil.copytree(self.data, data_backup)
        shutil.copy2(self.preferences, prefs_backup)
        self.old_inventory = self.inventory(self.previous)
        self.original_identity = self.identity(self.previous)
        self.data_inventory = self.inventory(self.data)
        self.prefs_inventory = self.inventory(self.preferences)
        self.manifest = {
            "format": 1, "bundle_id": self.installer.BUNDLE,
            "nonce": self.nonce, "state": "installed_pending_verification",
            "version": "1.01", "build": "2", "had_previous": True,
            "target_app": str(self.target), "stage_dir": str(self.stage),
            "manifest_path": str(self.path), "backup_root": str(self.path.parent.parent),
            "simulate": True, "data_root": str(self.data),
            "preferences": str(self.preferences),
            "candidate_inventory": self.inventory(self.target),
            "previous_inventory": self.old_inventory,
            "backups": {
                "data": {"original_path": str(self.data), "backup_path": str(data_backup),
                         "inventory": self.data_inventory, "backup_inventory": self.inventory(data_backup)},
                "preferences": {"original_path": str(self.preferences), "backup_path": str(prefs_backup),
                                "inventory": self.prefs_inventory, "backup_inventory": self.inventory(prefs_backup)},
            },
        }
        self.installer.atomic_json(self.path, self.manifest)
        self.evidence = self.path.parent / "verification.json"
        self.evidence.write_text(json.dumps({
            "version": "1.01", "build": "2", "verificationScope": "static-and-targeted",
            "smokeTestRun": False, "passed": True,
            "candidateInventorySHA256": self.installer.hashlib.sha256(json.dumps(
                self.manifest["candidate_inventory"], sort_keys=True,
                separators=(",", ":")).encode()).hexdigest(),
        }), encoding="utf-8")
        self.registrations = []
        self.external_run = self.patch("run", side_effect=AssertionError(
            "Program backup tests must not execute system commands"))
        self.patch("verify_signature", side_effect=lambda path, simulate: self.installer.app_info(path))
        self.patch("ensure_not_running")
        self.patch("register", side_effect=self.record_registration)
        self.patch("cleanup_old_releases")

    def patch(self, name, **kwargs):
        patcher = mock.patch.object(self.installer, name, **kwargs)
        value = patcher.start()
        self.addCleanup(patcher.stop)
        return value

    def record_registration(self, path, simulate, remove=False):
        self.installer.app_info(path)
        self.registrations.append((str(path), remove))

    def inventory(self, path):
        return self.installer.inventory(path, permit_symlinks=True)

    @staticmethod
    def identity(path):
        details = path.lstat()
        return details.st_dev, details.st_ino

    def load(self):
        return self.installer.load_manifest(self.path)

    def finalize(self, rollback=False):
        self.installer.finalize(SimpleNamespace(
            manifest=str(self.path), rollback=rollback,
            verification_scope="static-and-targeted",
            verification_evidence=str(self.evidence)))

    def assert_data_preserved(self):
        self.assertEqual(self.inventory(self.data), self.data_inventory)
        self.assertEqual(self.inventory(self.preferences), self.prefs_inventory)
        self.installer.verify_backup(self.load())
        self.external_run.assert_not_called()

    def assert_retained(self):
        manifest = self.load()
        self.assertEqual(manifest["program_backup"]["state"], "retained")
        self.assertEqual(manifest["program_backup"]["backup_path"], str(self.backup))
        self.assertEqual(self.identity(self.backup), self.original_identity)
        self.assertEqual(self.inventory(self.backup), self.old_inventory)
        self.assertEqual(self.backup.parent.stat().st_mode & 0o777, 0o700)
        self.installer.verify_program_backup(manifest, self.path)
        self.installer.verify_program_pointer(manifest, self.path)

    def preserve(self):
        self.installer.preserve_previous_program(self.manifest, self.path)

    def test_normal_finalize_retains_original_inode_and_data(self):
        self.finalize()
        self.assertEqual(self.load()["state"], "verified")
        self.assertFalse(self.load()["gui_verified"])
        self.assertFalse(self.stage.exists())
        self.assert_retained()
        self.assertEqual(self.inventory(self.target), self.manifest["candidate_inventory"])
        self.assertIn((str(self.previous), True), self.registrations)
        self.assertIn((str(self.backup), True), self.registrations)
        self.assert_data_preserved()

    def test_finalize_and_preserve_are_idempotent(self):
        self.preserve()
        self.preserve()
        self.finalize()
        before = self.path.read_bytes()
        self.finalize()
        self.assertEqual(self.path.read_bytes(), before)
        self.assert_retained()
        self.assert_data_preserved()

    def test_planned_write_failure_keeps_original_in_stage(self):
        real_write = self.installer.atomic_json

        def fail_planned(path, manifest):
            if manifest.get("program_backup", {}).get("state") == "planned":
                raise OSError("injected planned write failure")
            real_write(path, manifest)

        with mock.patch.object(self.installer, "atomic_json", side_effect=fail_planned):
            with self.assertRaisesRegex(OSError, "planned write"):
                self.finalize()
        self.assertEqual(self.identity(self.previous), self.original_identity)
        self.assertFalse(self.backup.exists())
        self.assertNotIn("program_backup", self.load())
        self.assertTrue(self.stage.exists())
        self.assert_data_preserved()

    def test_retained_write_failure_can_resume_from_durable_plan(self):
        real_write = self.installer.atomic_json

        def fail_retained(path, manifest):
            if manifest.get("program_backup", {}).get("state") == "retained":
                raise OSError("injected retained write failure")
            real_write(path, manifest)

        with mock.patch.object(self.installer, "atomic_json", side_effect=fail_retained):
            with self.assertRaisesRegex(OSError, "retained write"):
                self.finalize()
        self.assertEqual(self.load()["program_backup"]["state"], "planned")
        self.assertFalse(self.previous.exists())
        self.assertEqual(self.identity(self.backup), self.original_identity)
        self.assertTrue(self.stage.exists())
        self.finalize()
        self.assertFalse(self.stage.exists())
        self.assert_retained()
        self.assert_data_preserved()

    def test_retained_pointer_read_failure_keeps_stage_until_retry(self):
        real_verify = self.installer.verify_program_pointer

        def fail_retained_read(manifest, path):
            if manifest.get("program_backup", {}).get("state") == "retained":
                raise OSError("injected retained read failure")
            return real_verify(manifest, path)

        with mock.patch.object(self.installer, "verify_program_pointer", side_effect=fail_retained_read):
            with self.assertRaisesRegex(OSError, "retained read"):
                self.finalize()
        self.assertTrue(self.stage.exists())
        self.assertFalse(self.previous.exists())
        self.assert_retained()
        self.finalize()
        self.assertFalse(self.stage.exists())
        self.assert_data_preserved()

    def test_planned_pointer_read_failure_before_move_can_rollback(self):
        with mock.patch.object(self.installer, "verify_program_pointer", side_effect=OSError(
                "injected planned pointer read failure")):
            with self.assertRaisesRegex(OSError, "planned pointer read"):
                self.finalize()
        self.assertEqual(self.load()["program_backup"]["state"], "planned")
        self.assertEqual(self.identity(self.previous), self.original_identity)
        self.assertFalse(self.backup.exists())
        self.finalize(rollback=True)
        self.assertEqual(self.load()["state"], "rolled_back")
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assert_retained()
        self.assert_data_preserved()

    def test_move_sync_failure_keeps_recoverable_original_and_resumes(self):
        real_sync = self.installer.sync_directory

        def fail_after_move(path):
            if Path(path) == self.stage and self.backup.exists():
                raise OSError("injected move directory sync failure")
            return real_sync(path)

        with mock.patch.object(self.installer, "sync_directory", side_effect=fail_after_move):
            with self.assertRaisesRegex(OSError, "directory sync"):
                self.finalize()
        self.assertTrue(self.stage.exists())
        self.assertEqual(self.identity(self.backup), self.original_identity)
        self.assertEqual(self.load()["program_backup"]["state"], "planned")
        self.finalize()
        self.assert_retained()
        self.assert_data_preserved()

    def test_final_receipt_failure_after_stage_removal_can_rollback(self):
        real_write = self.installer.atomic_json

        def fail_final(path, manifest):
            if manifest.get("state") == "verified":
                raise OSError("injected final receipt failure")
            real_write(path, manifest)

        with mock.patch.object(self.installer, "atomic_json", side_effect=fail_final):
            with self.assertRaisesRegex(OSError, "final receipt"):
                self.finalize()
        self.assertFalse(self.stage.exists())
        self.assertEqual(self.load()["state"], "installed_pending_verification")
        self.assert_retained()
        self.finalize(rollback=True)
        self.assertEqual(self.load()["state"], "rolled_back")
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assertFalse(self.stage.exists())
        self.assert_retained()
        self.assert_data_preserved()

    def test_verified_rollback_preserves_independent_original_and_is_idempotent(self):
        self.finalize()
        self.finalize(rollback=True)
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assertNotEqual(self.identity(self.target), self.original_identity)
        self.assert_retained()
        before = self.path.read_bytes()
        self.finalize(rollback=True)
        self.assertEqual(self.path.read_bytes(), before)
        self.assert_data_preserved()

    def test_old_verified_receipt_cannot_overwrite_later_installed_program(self):
        self.finalize()
        shutil.rmtree(self.target)
        fixture(self.target, "1.02", b"later independently installed version")
        later_inventory = self.inventory(self.target)
        with self.assertRaises(RuntimeError):
            self.finalize(rollback=True)
        self.assertEqual(self.inventory(self.target), later_inventory)
        self.assertEqual(self.load()["state"], "verified")
        self.assertFalse(self.stage.exists())
        self.assert_retained()
        self.assert_data_preserved()

    def test_verified_rollback_registration_failure_can_resume(self):
        self.finalize()

        def fail_restored_registration(path, simulate, remove=False):
            self.record_registration(path, simulate, remove)
            if Path(path) == self.target and not remove:
                raise RuntimeError("injected restored program registration failure")

        with mock.patch.object(self.installer, "register", side_effect=fail_restored_registration):
            with self.assertRaisesRegex(RuntimeError, "restored program registration"):
                self.finalize(rollback=True)
        self.assertEqual(self.load()["state"], "rollback_in_progress")
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assertTrue((self.stage / "failed-candidate.app").exists())
        self.assert_retained()
        self.finalize(rollback=True)
        self.assertEqual(self.load()["state"], "rolled_back")
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assertFalse(self.stage.exists())
        self.assert_retained()
        self.assert_data_preserved()

    def test_legacy_pending_receipt_and_safe_rollback_staging(self):
        legacy = self.stage.with_name(self.stage.name.removesuffix(".noindex"))
        self.stage.rename(legacy)
        self.stage = legacy
        self.previous = legacy / "previous.app"
        self.manifest["stage_dir"] = str(legacy)
        self.installer.atomic_json(self.path, self.manifest)
        self.finalize()
        self.assert_retained()
        real_copy = self.installer.copy_verified
        destinations = []

        def checked_copy(source, destination, *args, **kwargs):
            self.assertTrue(destination.parent.name.endswith(".noindex"))
            destinations.append(destination)
            return real_copy(source, destination, *args, **kwargs)

        with mock.patch.object(self.installer, "copy_verified", side_effect=checked_copy):
            self.finalize(rollback=True)
        self.assertEqual(len(destinations), 1)
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assertFalse(legacy.exists())
        self.assertFalse(Path(self.load()["rollback_stage_dir"]).exists())
        self.assert_retained()
        self.assert_data_preserved()

    def test_first_install_creates_no_fictitious_program_backup(self):
        shutil.rmtree(self.previous)
        self.manifest["had_previous"] = False
        self.manifest.pop("previous_inventory")
        self.installer.atomic_json(self.path, self.manifest)
        self.finalize()
        self.assertEqual(self.load()["state"], "verified")
        self.assertNotIn("program_backup", self.load())
        self.assertFalse(self.backup.parent.exists())
        self.assertFalse(self.stage.exists())
        self.finalize()
        self.assert_data_preserved()

    def test_missing_previous_without_pointer_blocks_cleanup(self):
        shutil.rmtree(self.previous)
        with self.assertRaises((RuntimeError, FileNotFoundError)):
            self.finalize()
        self.assertTrue(self.stage.exists())
        self.assertEqual(self.load()["state"], "installed_pending_verification")
        self.assertNotIn("program_backup", self.load())
        self.assert_data_preserved()

    def test_missing_retained_program_blocks_cleanup(self):
        self.preserve()
        shutil.rmtree(self.backup)
        with self.assertRaises((RuntimeError, FileNotFoundError)):
            self.finalize()
        self.assertTrue(self.stage.exists())
        self.assertEqual(self.load()["state"], "installed_pending_verification")
        self.assert_data_preserved()

    def test_damaged_retained_program_blocks_cleanup(self):
        self.preserve()
        (self.backup / "Contents/MacOS/GaoCaoZuo").write_bytes(b"corrupt")
        with self.assertRaises(RuntimeError):
            self.finalize()
        self.assertTrue(self.stage.exists())
        self.assertEqual(self.load()["state"], "installed_pending_verification")
        self.assert_data_preserved()

    def test_symlink_retained_program_blocks_cleanup_without_touching_referent(self):
        self.preserve()
        moved = self.root / "unrelated-original.app"
        self.backup.rename(moved)
        self.backup.symlink_to(moved, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            self.finalize()
        self.assertEqual(self.identity(moved), self.original_identity)
        self.assertEqual(self.inventory(moved), self.old_inventory)
        self.assertTrue(self.stage.exists())
        self.assert_data_preserved()

    def test_symlink_container_blocks_move(self):
        referent = self.root / "unrelated-container"
        referent.mkdir(mode=0o700)
        self.backup.parent.symlink_to(referent, target_is_directory=True)
        with self.assertRaises(RuntimeError):
            self.finalize()
        self.assertEqual(self.identity(self.previous), self.original_identity)
        self.assertEqual(list(referent.iterdir()), [])
        self.assertTrue(self.stage.exists())
        self.assert_data_preserved()

    def test_outside_pointer_blocks_cleanup(self):
        self.preserve()
        manifest = self.load()
        manifest["program_backup"]["backup_path"] = str(self.root / "outside.app")
        self.installer.atomic_json(self.path, manifest)
        with self.assertRaises(RuntimeError):
            self.finalize()
        self.assertTrue(self.stage.exists())
        self.assertEqual(self.identity(self.backup), self.original_identity)
        self.assert_data_preserved()

    def test_cross_volume_blocks_move(self):
        real_stat = Path.stat

        def differing_device(path, *args, **kwargs):
            result = real_stat(path, *args, **kwargs)
            if path == self.backup.parent:
                fields = list(result)
                fields[2] = result.st_dev + 1
                return os.stat_result(fields)
            return result

        with mock.patch.object(Path, "stat", autospec=True, side_effect=differing_device):
            with self.assertRaisesRegex(RuntimeError, "同一卷|跨卷"):
                self.finalize()
        self.assertEqual(self.identity(self.previous), self.original_identity)
        self.assertFalse(self.backup.exists())
        self.assertTrue(self.stage.exists())
        self.assertNotIn("program_backup", self.load())
        self.assert_data_preserved()

    def test_both_old_locations_block_cleanup(self):
        self.preserve()
        shutil.copytree(self.backup, self.previous, symlinks=True)
        with self.assertRaisesRegex(RuntimeError, "同时"):
            self.finalize()
        self.assertTrue(self.previous.exists())
        self.assertTrue(self.stage.exists())
        self.assert_retained()
        self.assert_data_preserved()

    def test_changed_inode_or_nonprivate_container_blocks_cleanup(self):
        self.preserve()
        original = self.load()
        bad = copy.deepcopy(original)
        bad["program_backup"]["inode"] += 1
        self.installer.atomic_json(self.path, bad)
        with self.assertRaises(RuntimeError):
            self.finalize()
        self.installer.atomic_json(self.path, original)
        self.backup.parent.chmod(0o755)
        with self.assertRaises(RuntimeError):
            self.finalize()
        self.assertTrue(self.stage.exists())
        self.assertEqual(self.identity(self.backup), self.original_identity)
        self.assert_data_preserved()

    def test_legacy_verified_without_program_backup_cannot_claim_recovery(self):
        manifest = self.load()
        manifest["state"] = "verified"
        shutil.rmtree(self.previous)
        self.stage.rmdir()
        self.installer.atomic_json(self.path, manifest)
        before = self.path.read_bytes()
        with self.assertRaises(RuntimeError):
            self.finalize(rollback=True)
        self.assertEqual(self.path.read_bytes(), before)
        self.assertNotIn("program_backup", self.load())
        self.assert_data_preserved()

    def test_interrupted_recovery_copy_can_retry_without_consuming_original(self):
        self.finalize()
        self.stage.mkdir(mode=0o700)
        copying = self.stage / "recovery-copy.app"
        (copying / "Contents/MacOS").mkdir(parents=True)
        (copying / "Contents/MacOS/GaoCaoZuo").write_bytes(b"interrupted partial copy")
        self.finalize(rollback=True)
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assertFalse(self.stage.exists())
        self.assert_retained()
        self.assert_data_preserved()

    def test_partial_recovery_info_plist_can_retry_without_consuming_original(self):
        self.finalize()
        self.stage.mkdir(mode=0o700)
        copying = self.stage / "recovery-copy.app"
        (copying / "Contents/MacOS").mkdir(parents=True)
        (copying / "Contents/Info.plist").write_bytes(b"bplist00interrupted")
        (copying / "Contents/MacOS/GaoCaoZuo").write_bytes(b"partial executable")
        self.finalize(rollback=True)
        self.assertEqual(self.inventory(self.target), self.old_inventory)
        self.assertFalse(self.stage.exists())
        self.assert_retained()
        self.assert_data_preserved()


if __name__ == "__main__":
    unittest.main(verbosity=2)
