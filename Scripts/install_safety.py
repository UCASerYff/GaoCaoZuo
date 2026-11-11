#!/usr/bin/python3
"""Install verified candidates without copying data or retaining previous programs."""
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
DEFAULT_RECEIPTS = Path("/private/tmp/gaocaozuo-install-receipts.noindex")
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
        sync_directory(path.parent)
    finally:
        if temporary.exists():
            temporary.unlink()


def sync_directory(path):
    """Persist directory entries, including receipt replacements and App moves."""
    fd = os.open(str(path), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


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
                fail("资料含符号链接，无法核验全部附件，请先核验：" + str(item))
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
            fail("无法核验特殊文件，安装已停止：" + str(item))

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
    finder = finder_extension(path)
    quicklook = quicklook_extension(path)
    # Validate every identity before invoking LaunchServices or removing an App.
    objects = [(path, BUNDLE)]
    if finder is not None:
        objects.append((finder, EXTENSION_BUNDLE))
    if quicklook is not None:
        objects.append((quicklook, BUNDLE + ".QuickLook"))
        broker = quicklook / "Contents/XPCServices/ArchiveBroker.xpc"
        with (broker / "Contents/Info.plist").open("rb") as stream:
            info = plistlib.load(stream)
        if (broker.is_symlink() or not broker.is_dir()
                or info.get("CFBundleIdentifier") != BUNDLE + ".QuickLook.ArchiveBroker"
                or info.get("CFBundleExecutable") != "ArchiveBroker"
                or not (broker / "Contents/MacOS/ArchiveBroker").is_file()):
            fail("压缩代理身份不符，禁止安装或登记。")
        objects.append((broker, BUNDLE + ".QuickLook.ArchiveBroker"))
    if not simulate:
        if finder is None or quicklook is None:
            fail("正式候选缺少 Finder 或 Quick Look 扩展。")
        run(["/usr/bin/codesign", "--verify", "--deep", "--strict", str(path)])
        for component, identifier in objects:
            requirement = 'identifier "' + identifier + '" and anchor apple generic and certificate leaf[subject.OU] = "5G96498KGJ"'
            run(["/usr/bin/codesign", "--verify", "--strict", "--all-architectures", "--test-requirement", "=" + requirement, str(component)])


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


def quicklook_extension(path):
    plugins = path / "Contents/PlugIns"
    extension = plugins / "GaoArchiveQuickLook.appex"
    try:
        extension.lstat()
    except FileNotFoundError:
        return None
    if plugins.is_symlink() or extension.is_symlink() or not extension.is_dir() or extension.resolve() != path.resolve() / "Contents/PlugIns/GaoArchiveQuickLook.appex":
        fail("压缩预览扩展路径不合法，停止登记。")
    with (extension / "Contents/Info.plist").open("rb") as stream:
        info = plistlib.load(stream)
    if info.get("CFBundleIdentifier") != BUNDLE + ".QuickLook" or info.get("NSExtension", {}).get("NSExtensionPointIdentifier") != "com.apple.quicklook.preview" or info.get("CFBundleExecutable") != "GaoArchiveQuickLook" or not (extension / "Contents/MacOS/GaoArchiveQuickLook").is_file():
        fail("压缩预览扩展标识无效，停止登记。")
    return extension


def register(path, simulate, remove=False):
    # Validate both identities before the first external mutation. LaunchServices
    # may rediscover private staging apps after they were moved, so remove their
    # exact old paths again during finalization, including their Finder extension.
    app_info(path)
    extensions = [finder_extension(path), quicklook_extension(path)]
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
        for extension in (value for value in extensions if value is not None):
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
    ensure_executable_not_running(executable, simulate)


def ensure_executable_not_running(executable, simulate):
    if simulate:
        return
    for line in run(["/bin/ps", "-axo", "pid=,comm="]).splitlines():
        pieces = line.strip().split(None, 1)
        if len(pieces) == 2 and pieces[1] == executable:
            fail("搞操作仍在运行。请保存文件并退出，再安装；安装脚本不会强行终止编辑进程。")


def copy_verified(source, destination, simulate, permit_symlinks=False):
    """Copy only a candidate program, with inventories before and after copying."""
    before = inventory(source, permit_symlinks=permit_symlinks)
    if before["state"] != "present" or destination.exists() or destination.is_symlink():
        fail("候选来源缺失或暂存目标已存在，禁止覆盖。")
    if simulate:
        shutil.copytree(str(source), str(destination), symlinks=True)
    else:
        run(["/usr/bin/ditto", str(source), str(destination)])
    if inventory(destination, permit_symlinks=permit_symlinks) != before or inventory(source, permit_symlinks=permit_symlinks) != before:
        fail("候选复制逐文件校验失败。")
    return before


def check_simulation_paths(paths):
    roots = [Path("/private/tmp").resolve(), Path(tempfile.gettempdir()).resolve()]
    for path in paths:
        resolved = path.resolve()
        if not any(resolved == root or root in resolved.parents for root in roots):
            fail("--simulate 仅允许隔离的系统临时目录，不可操作实际安装或真实资料。")


@contextlib.contextmanager
def installation_lock(receipt_root):
    if receipt_root.is_symlink():
        fail("安装记录目录不可为符号链接。")
    receipt_root.mkdir(mode=0o700, parents=True, exist_ok=True)
    if receipt_root.resolve() != receipt_root or not receipt_root.name.endswith(".noindex"):
        fail("安装记录必须位于规范化的 .noindex 目录。")
    receipt_root.chmod(0o700)
    descriptor = os.open(str(receipt_root / ".installation.lock"), os.O_CREAT | os.O_APPEND | os.O_WRONLY | os.O_NOFOLLOW, 0o600)
    with os.fdopen(descriptor, "a") as stream:
        fcntl.flock(stream.fileno(), fcntl.LOCK_EX)
        yield


def live_data_inventory(data_root, preferences):
    # A missing source is explicit evidence, never an empty replacement store.
    # Read failures, unsupported files and symlinks stop before App replacement.
    return {"data": inventory(data_root), "preferences": inventory(preferences)}


def verify_live_data(manifest):
    current = live_data_inventory(Path(manifest["data_root"]), Path(manifest["preferences"]))
    if current != manifest["data_inventory"]:
        fail("用户资料或设置在核验期间发生变化；已停止，不修改资料、不恢复或创建备份。")


def load_manifest(path):
    if path.is_symlink() or not path.is_file():
        fail("安装记录缺失或不是实际文件。")
    with path.open(encoding="utf-8") as stream:
        manifest = json.load(stream)
    if manifest.get("bundle_id") != BUNDLE or manifest.get("format") != 2:
        fail("不是当前无备份安装流程的记录。")
    target, stage = Path(manifest["target_app"]), Path(manifest["stage_dir"])
    receipts = Path(manifest["receipt_root"])
    if (target.name != APP_NAME or stage.parent != target.parent
            or stage.name != ".gaocaozuo-install-" + manifest["nonce"] + ".noindex"
            or manifest.get("manifest_path") != str(path)
            or path.parent != receipts or not receipts.name.endswith(".noindex")
            or any(item.is_symlink() or item != item.resolve() for item in (target, stage, receipts))):
        fail("安装记录中的路径校验失败。")
    if manifest["simulate"]:
        check_simulation_paths([target, Path(manifest["data_root"]), Path(manifest["preferences"]), path])
    return manifest


def cleanup_stage(stage, expected, simulate):
    """A stage may contain only the disposable, verified candidate App."""
    if not stage.exists():
        return
    children = list(stage.iterdir())
    if children:
        candidate = stage / "candidate.app"
        if children != [candidate] or inventory(candidate, permit_symlinks=True) != expected:
            fail("安装暂存包含未知或变化内容，停止精确清理。")
        ensure_not_running(candidate, simulate)
        register(candidate, simulate, remove=True)
    shutil.rmtree(str(stage))
    sync_directory(stage.parent)


def install(args):
    source = Path(args.app).expanduser().absolute()
    target = Path(args.target).expanduser().absolute()
    data_root = Path(args.data_root).expanduser().absolute()
    preferences = Path(args.preferences).expanduser().absolute()
    receipts = Path(args.receipt_root).expanduser().absolute()
    paths = (source, target, data_root, preferences, receipts)
    if any(path.is_symlink() or path.resolve() != path for path in paths):
        fail("应用、资料、设置与安装记录必须使用实际规范化路径。")
    if (target.name != APP_NAME or source == target or source in target.parents or target in source.parents
            or not any(parent.name.endswith(".noindex") for parent in source.parents)):
        fail("候选必须来自 .noindex 容器，目标必须是独立的 搞操作.app。")
    for protected in (data_root, preferences):
        for disposable in (source, target, receipts):
            if protected == disposable or protected in disposable.parents or disposable in protected.parents:
                fail("资料和设置不能与程序或安装记录路径互相包含。")
    if args.simulate:
        check_simulation_paths(paths)
    info = app_info(source)
    version, build = str(info.get("CFBundleShortVersionString", "")), str(info.get("CFBundleVersion", ""))
    if not re.fullmatch(r"[0-9]+\.[0-9]{2}", version) or decimal.Decimal(version) < 1 or not build.isdigit():
        fail("版本或构建号配置无效。")
    verify_signature(source, args.simulate)
    had_previous = target.exists()
    if had_previous:
        old = app_info(target)
        verify_signature(target, args.simulate)
        if decimal.Decimal(version) < decimal.Decimal(str(old.get("CFBundleShortVersionString", "0"))):
            fail("禁止用较旧版本覆盖当前程序。")
    ensure_not_running(target, args.simulate)
    ensure_not_running(source, args.simulate)
    # Hash all live files before creating candidate staging or removing the App.
    data_inventory = live_data_inventory(data_root, preferences)
    if had_previous:
        data = data_inventory["data"]
        settings = data["entries"].get("settings.json", {})
        if data["state"] != "present" or settings.get("type") != "file":
            fail("现有安装的资料目录或主设置 settings.json 缺失，停止升级；不按空资料覆盖。")
    target.parent.mkdir(parents=True, exist_ok=True)
    with installation_lock(receipts):
        for prior in receipts.glob("install-*.json"):
            recorded = load_manifest(prior)
            if recorded["state"] in ("preparing", "prepared", "installed_pending_verification"):
                fail("存在未完成的安装记录，请先核验：" + str(prior))
        nonce = uuid.uuid4().hex
        path = receipts / ("install-" + nonce + ".json")
        stage = target.parent / (".gaocaozuo-install-" + nonce + ".noindex")
        stage.mkdir(mode=0o700)
        candidate = stage / "candidate.app"
        manifest = {"format": 2, "bundle_id": BUNDLE, "nonce": nonce, "state": "preparing",
                    "version": version, "build": build, "source_app": str(source), "target_app": str(target),
                    "stage_dir": str(stage), "manifest_path": str(path), "receipt_root": str(receipts),
                    "had_previous": had_previous, "simulate": args.simulate,
                    "data_root": str(data_root), "preferences": str(preferences), "data_inventory": data_inventory,
                    "created_at": datetime.datetime.now().astimezone().isoformat(),
                    "backup_created": False, "rollback_available": False}
        atomic_json(path, manifest)
        try:
            manifest["candidate_inventory"] = copy_verified(source, candidate, args.simulate, permit_symlinks=True)
            verify_signature(candidate, args.simulate)
            finder_extension(candidate)
            quicklook_extension(candidate)
            verify_live_data(manifest)
            ensure_not_running(target, args.simulate)
            if had_previous:
                manifest["previous_inventory_sha256"] = hashlib.sha256(json.dumps(inventory(target, permit_symlinks=True), sort_keys=True).encode()).hexdigest()
            manifest["state"] = "prepared"
            atomic_json(path, manifest)
            if had_previous:
                # The user explicitly prohibits old-program copies and rollback.
                # All candidate/data checks finish before this exact deletion.
                register(target, args.simulate, remove=True)
                shutil.rmtree(str(target))
                sync_directory(target.parent)
            candidate.rename(target)
            sync_directory(target.parent)
            verify_signature(target, args.simulate)
            if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
                fail("安装后程序逐文件校验失败。")
            verify_live_data(manifest)
            register(target, args.simulate)
            cleanup_stage(stage, manifest["candidate_inventory"], args.simulate)
            manifest["state"] = "installed_pending_verification"
            atomic_json(path, manifest)
            print("MANIFEST=" + str(path))
            print("已安装搞操作 V" + version + "；未启动应用，未创建资料或旧程序备份。")
        except Exception as error:
            manifest["state"] = "failed"
            manifest["failure"] = str(error)
            atomic_json(path, manifest)
            # No restoration or alternate program is created on failure.
            # Dispose of the stage only when its exact contents are verified.
            if "candidate_inventory" in manifest:
                cleanup_stage(stage, manifest["candidate_inventory"], args.simulate)
            elif stage.exists() and not any(stage.iterdir()):
                stage.rmdir()
            raise


def finalize(args):
    path = Path(args.manifest).expanduser().absolute()
    manifest = load_manifest(path)
    with installation_lock(Path(manifest["receipt_root"])):
        if manifest["state"] == "verified":
            print("安装事务已完成：verified")
            return
        if manifest["state"] != "installed_pending_verification":
            fail("此安装事务未处于待验收状态，禁止确认。")
        scope = args.verification_scope
        if scope == "static-and-targeted":
            if not args.verification_evidence:
                fail("静态与定向验证必须提供核验记录。")
            evidence_path = Path(args.verification_evidence).expanduser().absolute()
            if evidence_path.is_symlink() or not evidence_path.is_file() or evidence_path.stat().st_size > 1024 * 1024:
                fail("核验记录缺失、不是实际文件或过大。")
            evidence = json.loads(evidence_path.read_text())
            expected_inventory = hashlib.sha256(json.dumps(manifest["candidate_inventory"], sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            if (evidence.get("version") != manifest["version"] or str(evidence.get("build")) != manifest["build"]
                    or evidence.get("candidateInventorySHA256") != expected_inventory
                    or evidence.get("verificationScope") != scope or evidence.get("smokeTestRun") is not False
                    or evidence.get("passed") is not True):
                fail("核验记录与候选版本、摘要或实际范围不匹配。")
            manifest["verification_evidence_sha256"] = digest_file(evidence_path)
            verify_live_data(manifest)
        target = Path(manifest["target_app"])
        verify_signature(target, manifest["simulate"])
        if inventory(target, permit_symlinks=True) != manifest["candidate_inventory"]:
            fail("安装后的程序发生变化，禁止确认。")
        register(target, manifest["simulate"])
        cleanup_stage(Path(manifest["stage_dir"]), manifest["candidate_inventory"], manifest["simulate"])
        manifest.update(state="verified", verified_at=datetime.datetime.now().astimezone().isoformat(),
                        verification_scope=scope, gui_verified=scope == "manual")
        atomic_json(path, manifest)
        if not manifest["simulate"]:
            cleanup_old_releases(manifest["version"])
        print("安装核验已确认（" + ("静态与定向；未运行冒烟或 GUI 验收" if scope == "static-and-targeted" else "人工验收") + "）；资料留在原路径，无备份或旧程序副本。")


def cleanup_old_releases(current_version):
    release = PROJECT / "Release"
    if release.is_symlink():
        fail("Release 目录为符号链接，停止清理。")
    if not release.is_dir():
        return
    current = release / ("GaoCaoZuo-" + current_version + ".dmg")
    checksum = current.with_name(current.name + ".sha256")
    if not current.is_file() or not checksum.is_file():
        return
    if digest_file(current) != checksum.read_text().strip().split()[0]:
        fail("最新版发行包校验不符，停止旧包清理。")
    for item in release.iterdir():
        match = re.fullmatch(r"GaoCaoZuo-(\d+\.\d{2})(?:\.dmg(?:\.sha256)?|-source\.zip(?:\.sha256)?)", item.name)
        if match and not item.is_symlink() and item.is_file() and decimal.Decimal(match.group(1)) < decimal.Decimal(current_version):
            item.unlink()


def main():
    parser = argparse.ArgumentParser(description="搞操作无备份安装与逐文件核验")
    commands = parser.add_subparsers(dest="command", required=True)
    install_parser = commands.add_parser("install")
    install_parser.add_argument("--app", required=True)
    install_parser.add_argument("--target", default=str(DEFAULT_TARGET))
    install_parser.add_argument("--data-root", default=str(DEFAULT_DATA))
    install_parser.add_argument("--preferences", default=str(DEFAULT_PREFS))
    install_parser.add_argument("--receipt-root", default=str(DEFAULT_RECEIPTS))
    install_parser.add_argument("--simulate", action="store_true", help="仅临时目录模拟，不调用签名或系统登记")
    final_parser = commands.add_parser("finalize")
    final_parser.add_argument("--manifest", required=True)
    final_parser.add_argument("--verification-scope", choices=("manual", "static-and-targeted"), default="static-and-targeted")
    final_parser.add_argument("--verification-evidence")
    final_parser.add_argument("--verified", action="store_true", required=True)
    args = parser.parse_args()
    try:
        install(args) if args.command == "install" else finalize(args)
    except Exception as error:
        print("安装操作已停止：" + str(error), file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
