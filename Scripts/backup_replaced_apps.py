#!/usr/bin/env python3
"""Exact, verified backups for the four replacement candidates; never uninstalls.

Container symlinks are copied as links and never traversed. Shared Desktop,
Downloads, AddressBook and iCloud targets are not this app's private data.
"""
import argparse
import datetime
import json
import os
from pathlib import Path
import plistlib
import sys
import uuid

sys.dont_write_bytecode = True
from install_safety import copy_verified, inventory, atomic_json, protect_backup

APPS = {
    "cn.better365.iRightMousePro": "iRightMouse Pro.app",
    "cn.better365.BetterAndBetter": "BetterAndBetter.app",
    "cn.better365.FastZip": "FastZip.app",
    "cn.better365.Pane": "Pane.app",
}
EXTRA = ["cn.better365.iRightMousePro.Extension", "cn.better365.FastZip.Extension", "cn.better365.PaneHelper"]


def snapshot(destination, include_apps=False):
    if destination.exists():
        raise RuntimeError("备份目标已存在，拒绝覆盖。")
    destination.mkdir(parents=True, mode=0o700)
    library = Path.home() / "Library"
    sources = []
    for bundle, name in APPS.items():
        app = Path("/Applications") / name
        with (app / "Contents/Info.plist").open("rb") as f:
            info = plistlib.load(f)
        if info.get("CFBundleIdentifier") != bundle:
            raise RuntimeError("原应用标识不匹配，停止备份。")
        if include_apps:
            sources.append(("Applications/" + name, app))
        for relative in [f"Preferences/{bundle}.plist", f"Application Support/{bundle}", f"Containers/{bundle}"]:
            sources.append((relative, library / relative))
    for bundle in EXTRA:
        sources.append((f"Containers/{bundle}", library / "Containers" / bundle))
    for relative in ["Application Support/BetterAndBetter", "Preferences/com.better365.BetterAndBetterHelper.plist"]:
        sources.append((relative, library / relative))
    result = {"schema": 1, "created": datetime.datetime.now().astimezone().isoformat(), "state": "copying", "entries": []}
    atomic_json(destination / "manifest.json", result)
    for relative, source in sources:
        # Missing paths remain explicitly missing. Unreadable paths abort.
        target = destination / "Files" / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        before = inventory(source, permit_symlinks=True)
        if before["state"] == "present":
            copied = copy_verified(source, target, False, permit_symlinks=True)
            if copied != before:
                raise RuntimeError("源资料在备份期间改变，请保留本次记录并重新备份。")
        result["entries"].append({"source": str(source), "backup": str(target), "inventory": before})
        atomic_json(destination / "manifest.json", result)
    result["state"] = "verified"
    atomic_json(destination / "manifest.json", result)
    protect_backup(destination)
    # Permission protection intentionally changes modes; store a second inventory.
    protected = inventory(destination / "Files", permit_symlinks=True)
    atomic_json(destination / "protected-inventory.json", protected)
    print(json.dumps({"state": result["state"], "backup": str(destination), "sources": len(result["entries"])}, ensure_ascii=False))


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("--destination", type=Path)
    parser.add_argument("--include-apps", action="store_true")
    args = parser.parse_args()
    destination = args.destination or Path.home() / "Library/Application Support/GaoSeries/GaoCaoZuo-Backups" / ("第三方配置-" + datetime.datetime.now().strftime("%Y%m%d-%H%M%S") + "-" + uuid.uuid4().hex[:8])
    snapshot(destination, args.include_apps)
