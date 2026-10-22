#!/usr/bin/env python3
"""Move a verified program backup into a .noindex container, retaining rollback.

No application is launched, renamed, archived destructively, or deleted. User
data is untouched. Old receipt bytes and the exact relocation remain as evidence.
"""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile

import install_safety as safety


def encoded_digest(value):
    return hashlib.sha256(json.dumps(value, sort_keys=True, separators=(",", ":")).encode()).hexdigest()


def program_record(receipt):
    if "backup_app" in receipt:
        return receipt, "backup_app", receipt.get("protected_inventory")
    for name in ("copies", "artifacts", "items"):
        record = receipt.get(name, {}).get("app")
        if record:
            expected = record.get("backupInventory", record.get("protected", record.get("inventory")))
            return record, "backup", expected
    raise RuntimeError("No supported program recovery receipt; backup unchanged")


def isolate(manifest_path, simulate=False):
    manifest_path = Path(manifest_path).absolute()
    if manifest_path.is_symlink() or not manifest_path.is_file():
        raise RuntimeError("Recovery receipt must be an ordinary file")
    raw = manifest_path.read_bytes()
    receipt = json.loads(raw)
    record, pointer, expected = program_record(receipt)
    old = Path(record[pointer]).absolute()
    if old.parent.name.endswith(".noindex"):
        safety.app_info(old)
        if expected != safety.inventory(old, permit_symlinks=True):
            raise RuntimeError("Isolated recovery backup no longer matches its inventory")
        safety.verify_signature(old, simulate)
        return {"state": "already-isolated", "path": str(old)}
    if old.parent != manifest_path.parent or old.name != safety.APP_NAME:
        raise RuntimeError("Only the receipt's direct child program backup is eligible")
    if simulate and not str(old).startswith("/private/tmp/"):
        raise RuntimeError("Simulation is restricted to private temporary fixtures")
    safety.app_info(old)
    safety.ensure_not_running(old, simulate)
    before = safety.inventory(old, permit_symlinks=True)
    if not expected or expected != before:
        raise RuntimeError("Program backup does not exactly match protected recovery inventory")
    safety.verify_signature(old, simulate)
    parent = manifest_path.parent
    container = parent / "程序.noindex"
    destination = container / old.name
    audit_path = parent / "program-entry-isolation.json"
    if container.exists() or audit_path.exists():
        raise RuntimeError("An isolation transaction already exists; inspect it before continuing")
    modes = {manifest_path: stat.S_IMODE(manifest_path.stat().st_mode)}
    inventory_sha = encoded_digest(before)
    audit = {"schema": 1, "state": "prepared", "bundleID": safety.BUNDLE,
             "oldPath": str(old), "newPath": str(destination),
             "inventorySHA256": inventory_sha,
             "originalReceiptSHA256": hashlib.sha256(raw).hexdigest(),
             "manifestPath": str(manifest_path), "sourceAndDataUnchanged": True}
    safety.atomic_json(audit_path, audit)
    container.mkdir(mode=0o700)
    (container / "receipt-before-isolation.json").write_bytes(raw)
    (container / "receipt-before-isolation.json").chmod(0o400)
    moved = False
    try:
        safety.register(old, simulate, remove=True)
        old.rename(destination)
        moved = True
        if safety.inventory(destination, permit_symlinks=True) != before:
            raise RuntimeError("Moved backup inventory changed")
        # Verify the real recovery path in a non-indexed temporary container.
        with tempfile.TemporaryDirectory(prefix="gao-program-restore-", dir="/private/tmp") as temporary:
            restore_container = Path(temporary) / "Recovery.noindex"
            restore_container.mkdir()
            restored = restore_container / safety.APP_NAME
            try:
                if simulate:
                    shutil.copytree(destination, restored, symlinks=True)
                else:
                    safety.run(["/usr/bin/ditto", str(destination), str(restored)])
                if safety.inventory(restored, permit_symlinks=True) != before:
                    raise RuntimeError("Restoration copy did not preserve all program files")
                safety.verify_signature(restored, simulate)
                safety.register(restored, simulate, remove=True)
            finally:
                # Only the disposable restore rehearsal copy becomes writable
                # for cleanup. The long-lived backup permissions never change.
                if restored.exists():
                    for directory, children, _ in os.walk(restored, followlinks=False):
                        path = Path(directory)
                        if not path.is_symlink():
                            path.chmod(stat.S_IMODE(path.stat().st_mode) | 0o700)
        record[pointer] = str(destination)
        manifest_path.chmod(modes[manifest_path] | 0o200)
        safety.atomic_json(manifest_path, receipt)
        manifest_path.chmod(modes[manifest_path])
        current = json.loads(manifest_path.read_bytes())
        current_record, current_pointer, current_expected = program_record(current)
        if current_record[current_pointer] != str(destination) or current_expected != before:
            raise RuntimeError("Recovery pointer verification failed")
        audit.update(state="verified", restorationCopyVerified=True,
                     restorationSignatureVerified=not simulate,
                     updatedReceiptSHA256=hashlib.sha256(manifest_path.read_bytes()).hexdigest())
        safety.atomic_json(audit_path, audit)
        return audit
    except Exception:
        # Preserve original receipt bytes and a discoverable journal even when
        # an OS service fails. Never delete or disguise the only recovery copy.
        if moved and destination.exists() and not old.exists():
            destination.rename(old)
        if manifest_path.read_bytes() != raw:
            manifest_path.chmod(modes[manifest_path] | 0o200)
            temporary = manifest_path.with_name(manifest_path.name + ".restore")
            temporary.write_bytes(raw)
            os.replace(temporary, manifest_path)
            manifest_path.chmod(modes[manifest_path])
        audit["state"] = "rolled-back-needs-review"
        safety.atomic_json(audit_path, audit)
        raise


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--manifest", required=True, type=Path)
    parser.add_argument("--apply", action="store_true")
    args = parser.parse_args()
    if not args.apply:
        receipt = json.loads(args.manifest.read_bytes())
        record, pointer, _ = program_record(receipt)
        print(json.dumps({"dryRun": True, "program": record[pointer]}, ensure_ascii=False))
    else:
        print(json.dumps(isolate(args.manifest), ensure_ascii=False))
