#!/usr/bin/python3
"""Verified local install transactions. Never migrates, deletes, or restores user data."""
import argparse
import contextlib
import datetime
import decimal
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile
import uuid

BUNDLE = "com.gaoseries.GaoCaoZuo"
APP_NAME = "搞操作.app"
EXTENSION_BUNDLE = BUNDLE + ".FinderSync"
EXTENSION_NAME = "GaoFinderSync.appex"
PLUGIN_KIT = "/usr/bin/pluginkit"
DEFAULT_TARGET = Path("/Applications") / APP_NAME
PROJECT = Path(__file__).resolve().parent.parent
DEFAULT_DATA = Path.home() / "Library/Application Support/GaoSeries/GaoCaoZuo"
DEFAULT_PREFS = Path.home() / "Library/Preferences" / (BUNDLE + ".plist")
DEFAULT_BACKUPS = DEFAULT_DATA.parent / "GaoCaoZuo-Backups"
LSREGISTER = "/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister"


def fail(message):
    raise RuntimeError(message)


class CommandFailure(RuntimeError):
    def __init__(self, argv, result):
        self.argv = list(argv)
        self.returncode = result.returncode
        self.stdout = result.stdout
        self.stderr = result.stderr
        super().__init__("命令失败：" + argv[0] + "\n" + (result.stderr or result.stdout).strip()[:1800])


def run(argv):
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise CommandFailure(argv, result)
    return result.stdout


def atomic_json(path, content):
    temporary = path.with_name(path.name + ".tmp-" + uuid.uuid4().hex)
    try:
        fd = os.open(str(temporary), os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
        with os.fdopen(fd, "w", encoding="utf-8") as stream:
            json.dump(content, stream, ensure_ascii=False, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(str(temporary), str(path))
    finally:
        if temporary.exists():
            temporary.unlink()


def digest_file(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        while True:
            block = stream.read(1024 * 1024)
            if not block:
                break
            digest.update(block)
    return digest.hexdigest()


def inventory(path, permit_symlinks=False):
    """lstat/open failures are fatal; a missing source is explicitly recorded."""
    try:
        path.lstat()
    except FileNotFoundError:
        return {"state": "missing", "entries": {}}
    entries = {}

    def visit(item, relative):
        details = item.lstat()
        mode = stat.S_IMODE(details.st_mode)
        if stat.S_ISLNK(details.st_mode):
            if not permit_symlinks:
                fail("资料含符号链接，无法保证全部附件备份，请先核验：" + str(item))
            entries[relative] = {"type": "symlink", "target": os.readlink(str(item)), "mode": mode}
        elif stat.S_ISDIR(details.st_mode):
            entries[relative] = {"type": "directory", "mode": mode}
            with os.scandir(str(item)) as children:
                names = sorted(entry.name for entry in children)
            for name in names:
                visit(item / name, (relative + "/" + name) if relative != "." else name)
        elif stat.S_ISREG(details.st_mode):
            entries[relative] = {"type": "file", "size": details.st_size, "sha256": digest_file(item), "mode": mode}
        else:
            fail("不支持备份特殊文件，安装已停止：" + str(item))

    visit(path, ".")
    return {"state": "present", "entries": entries}


def app_info(path):
    if path.is_symlink() or not path.is_dir():
        fail("应用必须是实际的 .app 目录：" + str(path))
    with (path / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE:
        fail("Bundle ID 不匹配，禁止修改此应用：" + str(path))
    executable = info.get("CFBundleExecutable")
    if not isinstance(executable, str) or not executable or "/" in executable:
        fail("应用缺少有效的可执行文件配置。")
    if not (path / "Contents/MacOS" / executable).is_file():
        fail("应用可执行文件不存在。")
    return info


def verify_signature(path, simulate):
    app_info(path)
    if not simulate:
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)])


def finder_extension(path):
    """Return only this app's real embedded FinderSync bundle, never another plug-in."""
    plugins = path / "Contents/PlugIns"
    extension = plugins / EXTENSION_NAME
    try:
        extension.lstat()
    except FileNotFoundError:
        return None
    if plugins.is_symlink() or extension.is_symlink() or not extension.is_dir():
        fail("Finder 扩展必须是本应用内的实际目录：" + str(extension))
    if extension.resolve() != path.resolve() / "Contents/PlugIns" / EXTENSION_NAME:
        fail("Finder 扩展路径越出本应用，禁止修改系统登记。")
    with (extension / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if (info.get("CFBundleIdentifier") != EXTENSION_BUNDLE or
            info.get("CFBundlePackageType") != "XPC!" or
            info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.FinderSync"):
        fail("Finder 扩展标识不匹配，禁止修改系统登记：" + str(extension))
    executable = info.get("CFBundleExecutable")
    if (not isinstance(executable, str) or not executable or "/" in executable or
            not (extension / "Contents/MacOS" / executable).is_file()):
        fail("Finder 扩展缺少有效可执行文件。")
    return extension


def register(path, simulate, remove=False):
    # Validate both identities before the first external mutation. LaunchServices
    # may rediscover private staging apps after they were moved, so remove their
    # exact old paths again during finalization, including their Finder extension.
    app_info(path)
    extension = finder_extension(path)
    if not simulate:
        command = [LSREGISTER, "-u" if remove else "-f", str(path)]
        try:
            run(command)
        except CommandFailure as error:
            # kLSApplicationNotFoundErr is harmless only while removing this
            # already validated, exact app path. Never ignore a failed -f scan.
            expected = "failed to scan " + str(path) + ": -10814"
            diagnostics = (expected, expected + "\n from spotlight")
            outputs = (error.stdout.strip(), error.stderr.strip())
            absent = (remove and error.argv == command and
                      any(outputs in (("", message), (message, "")) for message in diagnostics))
            if not absent:
                raise
        if extension is not None:
            command = [PLUGIN_KIT, "-r" if remove else "-a", str(extension)]
            try:
                run(command)
            except CommandFailure as error:
                # Removing an already absent registration is an idempotent success.
                # Match the full response AND requested path; permission, service,
                # connection and unrelated-path failures must still stop cleanup.
                expected = "remove: no plugin at " + str(extension)
                outputs = (error.stdout.strip(), error.stderr.strip())
                absent = (remove and error.argv == command and
                          outputs in (("", expected), (expected, "")))
                if not absent:
                    raise


def ensure_not_running(target, simulate):
    if simulate or not target.exists():
        return
    info = app_info(target)
    executable = str(target / "Contents/MacOS" / info["CFBundleExecutable"])
    for line in run(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        pieces = line.strip().split(None, 1)
        if len(pieces) == 2 and pieces[1] == executable:
            fail("搞操作仍在运行。请保存文件并退出，再安装；安装脚本不会强行终止编辑进程。")


def copy_verified(source, destination, simulate, permit_symlinks=False):
    before = inventory(source, permit_symlinks=permit_symlinks)
    if before["state"] == "missing":
        return before
    if destination.exists():
        fail("备份目标已存在，禁止覆盖：" + str(destination))
    if simulate:
        if source.is_dir():
            shutil.copytree(str(source), str(destination), symlinks=True)
        else:
            shutil.copy2(str(source), str(destination))
    else:
        run(["/usr/bin/ditto", str(source), str(destination)])
    if inventory(destination, permit_symlinks=permit_symlinks) != before:
        fail("复制后逐文件校验失败：" + str(source))
    if inventory(source, permit_symlinks=permit_symlinks) != before:
        fail("备份期间原资料发生变化，安装已停止：" + str(source))
    return before


def check_simulation_paths(paths):
    roots = [Path("/private/tmp").resolve(), Path(tempfile.gettempdir()).resolve()]
    for path in paths:
        resolved = path.resolve()
        if not any(resolved == root or root in resolved.parents for root in roots):
            fail("--simulate 仅允许隔离的系统临时目录，不可操作实际安装或真实资料：" + str(path))


@contextlib.contextmanager
def installation_lock(backup_root):
    if backup_root.is_symlink():
        fail("安全备份目录不可为符号链接。")
    backup_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    backup_root.chmod(0o700)
    fd = os.open(str(backup_root / ".installation.lock"), os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd,"a") as stream:
        os.fchmod(stream.fileno(),0o600)
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        yield


def protect_backup(path):
    """Backup content stays owner-only even if a source has permissive modes."""
    if not path.exists():
        return
    if path.is_dir():
        path.chmod(0o700)
        for child in path.iterdir():
            protect_backup(child)
    else:
        path.chmod(0o600)


def load_manifest(path):
    with path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("bundle_id") != BUNDLE or manifest.get("format") != 1:
        fail("不是搞操作的安装记录。")
    target = Path(manifest["target_app"])
    stage = Path(manifest["stage_dir"])
    if target.name != APP_NAME or stage.parent != target.parent or stage.name != ".gaocaozuo-install-" + manifest["nonce"]:
        fail("安装记录中的路径校验失败。")
    if Path(manifest["manifest_path"]) != path.resolve():
        fail("安装记录已移位，禁止清理未核验路径。")
    if stage.is_symlink() or target.is_symlink():
        fail("安装路径不应为符号链接。")
    if manifest["simulate"]:
        check_simulation_paths([target, Path(manifest["data_root"]), Path(manifest["preferences"]), path])
    return manifest


def verify_backup(manifest):
    for key in ("data", "preferences"):
        item = manifest["backups"][key]
        if item["inventory"]["state"] == "present":
            if inventory(Path(item["backup_path"])) != item.get("backup_inventory",item["inventory"]):
                fail("安全备份校验失败，禁止删除旧程序：" + key)


def rollback(manifest, path):
    target = Path(manifest["target_app"])
    stage = Path(manifest["stage_dir"])
    previous = stage / "previous.app"
    failed = stage / "failed-candidate.app"
    simulate = manifest["simulate"]
    ensure_not_running(target, simulate)
    # If a registration command failed after the old app was restored, a retry
    # resumes that exact recovery rather than replacing the saved failed candidate.
    restored = manifest["had_previous"] and failed.exists() and not previous.exists()
    if restored:
        verify_signature(target, simulate)
        if inventory(target, permit_symlinks=True) != manifest.get("previous_inventory"):
            fail("恢复后的旧程序发生变化，保留现场并停止回滚。")
    else:
        if target.exists() and failed.exists():
            fail("已有待检查的失败程序，禁止覆盖：" + str(failed))
        if manifest["had_previous"]:
            if not previous.exists():
                fail("旧程序未找到，已保留现有资料与备份，请人工核验安装记录。")
            ensure_not_running(previous, simulate)
            verify_signature(previous, simulate)
            if inventory(previous, permit_symlinks=True) != manifest.get("previous_inventory"):
                fail("旧程序备份发生变化，禁止回滚。")
            # Staging copies can have been rediscovered after the original move.
            register(previous, simulate, remove=True)
        if target.exists():
            app_info(target)
            register(target, simulate, remove=True)
            target.rename(failed)
        if manifest["had_previous"]:
            previous.rename(target)
    if failed.exists():
        ensure_not_running(failed, simulate)
        app_info(failed)
        manifest["failed_candidate"] = {
            "path": str(failed), "inventory": inventory(failed, permit_symlinks=True),
            "recorded_at": datetime.datetime.now().astimezone().isoformat()
        }
        atomic_json(path, manifest)
        register(failed, simulate, remove=True)
    if manifest["had_previous"]:
        register(target, simulate)
    if failed.exists():
        shutil.rmtree(str(failed))
        manifest["failed_candidate"]["removed_after_registration"] = True
    if stage.exists() and not any(stage.iterdir()):
        stage.rmdir()
    manifest["state"] = "rolled_back"
    manifest["rolled_back_at"] = datetime.datetime.now().astimezone().isoformat()
    atomic_json(path, manifest)
    print("已恢复旧程序。用户资料、安全备份与失败候选核验记录均保留。" if manifest["had_previous"] else "已撤回首次安装。用户资料、安全备份与失败候选核验记录均保留。")


def install(args):
    source = Path(args.app).expanduser().resolve()
    target = Path(args.target).expanduser().absolute()
    data_root = Path(args.data_root).expanduser().absolute()
    preferences = Path(args.preferences).expanduser().absolute()
    backup_root = Path(args.backup_root).expanduser().absolute()
    if target.name != APP_NAME or target == source:
        fail("安装目标必须是独立的 搞操作.app，且不能与来源相同。")
    if target.is_symlink() or data_root.is_symlink() or preferences.is_symlink() or backup_root.is_symlink():
        fail("应用、资料根和设置路径不可使用符号链接。")
    target = target.parent.resolve() / target.name
    data_root = data_root.resolve()
    preferences = preferences.resolve()
    backup_root = backup_root.resolve()
    if data_root == target or target in data_root.parents or data_root in target.parents:
        fail("应用与资料路径不可互相包含。")
    if data_root == backup_root or data_root in backup_root.parents or backup_root in data_root.parents:
        fail("安全备份目录必须与用户资料目录分开。")
    if args.simulate:
        check_simulation_paths([source, target, data_root, preferences, backup_root])
    info = app_info(source)
    version = str(info.get("CFBundleShortVersionString", ""))
    build = str(info.get("CFBundleVersion", ""))
    if len(version.split(".")) != 2 or len(version.split(".")[1]) != 2 or decimal.Decimal(version) < decimal.Decimal("1.00") or not build.isdigit():
        fail("版本配置无效，应从 1.00 / build 1 开始。")
    verify_signature(source, args.simulate)
    had_previous = target.exists()
    if had_previous:
        old = app_info(target)
        verify_signature(target, args.simulate)
        if decimal.Decimal(version) < decimal.Decimal(str(old.get("CFBundleShortVersionString", "0"))):
            fail("禁止用较旧版本覆盖当前程序。")
    ensure_not_running(target, args.simulate)
    ensure_not_running(source, args.simulate)
    target.parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(backup_root):
        for prior in backup_root.glob("安装-*/manifest.json"):
            with prior.open(encoding="utf-8") as stream:
                recorded = json.load(stream)
            if recorded.get("bundle_id") == BUNDLE and recorded.get("state") in ("prepared", "installed_pending_verification"):
                fail("存在未完成验收的安装，请先验证或回滚：" + str(prior))
        nonce = uuid.uuid4().hex
        stamp = datetime.datetime.now().astimezone().strftime("%Y%m%d-%H%M%S")
        transaction = backup_root / ("安装-" + stamp + "-" + nonce[:8])
        transaction.mkdir(mode=0o700)
        path = transaction / "manifest.json"
        stage = target.parent / (".gaocaozuo-install-" + nonce)
        stage.mkdir(mode=0o700)
        candidate = stage / "candidate.app"
        previous = stage / "previous.app"
        manifest = {
            "format": 1, "bundle_id": BUNDLE, "nonce": nonce, "state": "preparing",
            "version": version, "build": build, "source_app": str(source), "target_app": str(target),
            "stage_dir": str(stage), "manifest_path": str(path.resolve()), "had_previous": had_previous,
            "simulate": args.simulate, "data_root": str(data_root), "preferences": str(preferences),
            "backup_root": str(backup_root), "backups": {}, "created_at": datetime.datetime.now().astimezone().isoformat(),
            "defer_cleanup": bool(args.defer_cleanup)
        }
        atomic_json(path, manifest)
        changed_target = False
        unregistered_previous = False
        try:
            for key, original in (("data", data_root), ("preferences", preferences)):
                destination = transaction / ("用户资料" if key == "data" else "preferences.plist")
                copied = copy_verified(original, destination, args.simulate)
                protect_backup(destination)
                manifest["backups"][key] = {"original_path": str(original), "backup_path": str(destination), "inventory": copied, "backup_inventory": inventory(destination)}
                atomic_json(path, manifest)
            copy_verified(source, candidate, args.simulate, permit_symlinks=True)
            # Preserve the build's nested extension entitlements and identity.
            # A verified byte-for-byte copy does not need to be re-signed.
            verify_signature(candidate, args.simulate)
            manifest["candidate_inventory"] = inventory(candidate, permit_symlinks=True)
            if had_previous:
                manifest["previous_inventory"] = inventory(target, permit_symlinks=True)
            manifest["state"] = "prepared"
            atomic_json(path, manifest)
            if had_previous:
                register(target, args.simulate, remove=True)
                unregistered_previous = True
                target.rename(previous)
                changed_target = True
            candidate.rename(target)
            changed_target = True
            verify_signature(target, args.simulate)
            if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
                fail("安装后的程序逐文件校验失败。")
            for item in manifest["backups"].values():
                if inventory(Path(item["original_path"])) != item["inventory"]:
                    fail("安装期间用户资料或设置发生变化，停止安装并恢复旧程序。")
            register(target, args.simulate)
            manifest["state"] = "installed_pending_verification"
            atomic_json(path, manifest)
            print("MANIFEST=" + str(path))
            print("已安装搞操作 V" + version + "，等待 GUI 验收。旧程序、资料和设置备份均保留。")
            print("验收后：Scripts/finalize-install.sh --manifest '" + str(path) + "' --verified")
            print("验收失败：Scripts/finalize-install.sh --manifest '" + str(path) + "' --rollback")
        except Exception as error:
            manifest["failure"] = str(error)
            atomic_json(path, manifest)
            if changed_target:
                try:
                    rollback(manifest, path)
                except Exception as rollback_error:
                    manifest["rollback_failure"] = str(rollback_error)
                    atomic_json(path, manifest)
                    fail(str(error) + "\n自动恢复未完成：" + str(rollback_error) + "\n请保留安装记录：" + str(path))
            else:
                if unregistered_previous and target.exists():
                    register(target, args.simulate)
                manifest["state"] = "preparation_failed"
                atomic_json(path, manifest)
            raise


def finalize(args):
    path = Path(args.manifest).expanduser().resolve()
    manifest = load_manifest(path)
    with installation_lock(Path(manifest["backup_root"])):
        if manifest["state"] in ("verified", "rolled_back"):
            print("安装事务已完成：" + manifest["state"])
            return
        if manifest["state"] != "installed_pending_verification":
            fail("此安装事务未处于待验收状态，禁止清理或覆盖。")
        if args.rollback:
            rollback(manifest, path)
            return
        verify_backup(manifest)
        target = Path(manifest["target_app"])
        stage = Path(manifest["stage_dir"])
        verify_signature(target, manifest["simulate"])
        if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
            fail("程序在安装后发生变化，不能删除旧程序，请核验或回滚。")
        if (stage / "previous.app").exists():
            app_info(stage / "previous.app")
            if inventory(stage / "previous.app", permit_symlinks=True) != manifest["previous_inventory"]:
                fail("旧程序备份发生变化，禁止清理。")
        old_apps = []
        if stage.exists():
            old_apps = sorted(stage.iterdir())
            allowed = {"previous.app", "candidate.app"}
            if any(child.name not in allowed for child in old_apps):
                fail("暂存目录包含未知文件，禁止自动清理。")
            # Check every old identity and process before changing any registration.
            # A staging app opened by LaunchServices must be quit by the user first.
            for child in old_apps:
                app_info(child)
                finder_extension(child)
                ensure_not_running(child, manifest["simulate"])
                expected = manifest.get("previous_inventory" if child.name == "previous.app" else "candidate_inventory")
                if expected is None or inventory(child, permit_symlinks=True) != expected:
                    fail("暂存程序发生变化，禁止清理：" + str(child))
        finder_extension(target)
        for child in old_apps:
            register(child, manifest["simulate"], remove=True)
        # Re-register the installed pair after removing stale registrations, but
        # before deleting the recovery copy. Any failed command leaves the pending
        # transaction, stage and data backups intact and safely retryable.
        register(target, manifest["simulate"])
        if stage.exists():
            shutil.rmtree(str(stage))
        manifest["state"] = "verified"
        manifest["verified_at"] = datetime.datetime.now().astimezone().isoformat()
        atomic_json(path, manifest)
        if not manifest["simulate"]:
            cleanup_old_releases(manifest["version"])
        print("GUI 验收已确认，旧程序和本次安装暂存已删除。用户资料与安全备份保留。")


def cleanup_old_releases(current_version):
    """Only older version-named packages owned by this project are eligible."""
    release = PROJECT / "Release"
    if release.is_symlink():
        fail("Release 目录为符号链接，未执行旧发行包清理。")
    if not release.is_dir():
        return
    current_dmg = release / ("GaoCaoZuo-" + current_version + ".dmg")
    current_checksum = current_dmg.with_name(current_dmg.name + ".sha256")
    if not current_dmg.is_file() or not current_checksum.is_file():
        print("最新版发行包或校验文件尚未就绪，保留旧发行包。")
        return
    expected = current_checksum.read_text().strip().split()[0]
    if digest_file(current_dmg) != expected:
        fail("最新版发行包校验不符，保留全部旧发行包。")
    for item in release.iterdir():
        match = re.fullmatch(r"GaoCaoZuo-(\d+\.\d{2})(?:\.dmg(?:\.sha256)?|-source\.zip(?:\.sha256)?)",item.name)
        if match and not item.is_symlink() and item.is_file() and decimal.Decimal(match.group(1)) < decimal.Decimal(current_version):
            item.unlink()
            print("已清理本应用旧发行包：" + item.name)


def main():
    parser = argparse.ArgumentParser(description="搞操作本地安装与安全回滚")
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--app", required=True)
    install_parser.add_argument("--target", default=str(DEFAULT_TARGET))
    install_parser.add_argument("--data-root", default=str(DEFAULT_DATA))
    install_parser.add_argument("--preferences", default=str(DEFAULT_PREFS))
    install_parser.add_argument("--backup-root", default=str(DEFAULT_BACKUPS))
    install_parser.add_argument("--defer-cleanup", action="store_true", help="保留旧程序等待 GUI 验收；所有安装均要求显式 finalize")
    install_parser.add_argument("--simulate", action="store_true", help="仅临时目录模拟，不调用签名或系统登记")
    final_parser = commands.add_parser("finalize")
    final_parser.add_argument("--manifest", required=True)
    actions = final_parser.add_mutually_exclusive_group(required=True)
    actions.add_argument("--verified", action="store_true")
    actions.add_argument("--rollback", action="store_true")
    args = parser.parse_args()
    try:
        install(args) if args.command == "install" else finalize(args)
    except Exception as error:
        print("安装操作已停止：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
