#!/usr/bin/python3
"""Sign one isolated candidate with the project's fixed Apple Development identity.

Only codesign/security subprocesses are used. No keychain mutation, key export,
ad-hoc fallback, notarization, or application launch is performed. See Apple's
TN3127 and the local codesign(1) manual for requirement and metadata semantics.
"""
import argparse
import base64
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import stat
import struct
import subprocess
import sys
import tempfile


IDENTITY = "A15B2B2D22B018CBC842063C9A8A589946647524"
TEAM = "5G96498KGJ"
BUNDLE = "com.gaoseries.GaoCaoZuo"
CODESIGN = "/usr/bin/codesign"
SECURITY = "/usr/bin/security"
# CS_ADHOC and CS_LINKER_SIGNED describe the replaced signature, not policy.
POLICY_FLAGS = 0x13F01
REPLACED_FLAGS = 0x20002
# This shipped universal tool has an unsigned x86_64 slice and a linker-signed
# arm64 slice. Permit only this exact original binary, not arbitrary differences.
INITIAL_7ZZ_SHA256 = "36ea959367d8f9ac51d47a56dc1f20bfb851f1cd22d6f206e85cb5cbc6ab4577"
FIXED = {
    ".": (BUNDLE, None),
    "Contents/PlugIns/GaoFinderSync.appex": (BUNDLE + ".FinderSync", "Resources/FinderSync.entitlements"),
    "Contents/PlugIns/GaoArchiveQuickLook.appex": (BUNDLE + ".QuickLook", "QuickLookExtension/QuickLook.entitlements"),
    "Contents/PlugIns/GaoArchiveQuickLook.appex/Contents/XPCServices/ArchiveBroker.xpc":
        (BUNDLE + ".QuickLook.ArchiveBroker", None),
}


class SigningError(RuntimeError):
    pass


def fail(message):
    raise SigningError(message)


def command(argv, allow_failure=False):
    """Never echo subprocess output, certificate names, or keychain diagnostics."""
    result = subprocess.run(argv, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode and not allow_failure:
        fail("签名工具操作失败（%s，退出码 %s）；未回退签名身份。" %
             (Path(argv[0]).name, result.returncode))
    return result


def sha256(path):
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def atomic_report(path, record):
    descriptor, name = tempfile.mkstemp(prefix=".signing-report-", dir=str(path.parent))
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as stream:
            json.dump(record, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
        descriptor = os.open(str(path.parent), os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    finally:
        if temporary.exists():
            temporary.unlink()


def inside(path, root):
    return path == root or root in path.parents


def validated_paths(app, project, report):
    app, project, report = (Path(value).expanduser().absolute() for value in (app, project, report))
    if (app != app.resolve() or app.is_symlink() or not app.is_dir()
            or app.suffix != ".app" or not project.is_dir() or project != project.resolve()):
        fail("候选及项目必须使用实际、规范化的绝对目录。")
    containers = [parent for parent in app.parents if parent.name.endswith(".noindex")]
    if not containers:
        fail("候选必须先位于 .noindex 容器内。")
    container = containers[0]
    if (not report.parent.is_dir() or report.parent != report.parent.resolve()
            or report.is_symlink() or not inside(report, container) or inside(report, app)):
        fail("报告必须位于同一 .noindex 容器内、候选应用之外的实际目录。")
    if report.exists() and not report.is_file():
        fail("签名报告路径不是普通文件。")
    return app, project, report, container


def der_item(data, offset=0):
    """Read a definite-length DER TLV, rejecting truncation/noncanonical lengths."""
    if offset + 2 > len(data):
        fail("公开签名证书 DER 不完整。")
    tag, length = data[offset], data[offset + 1]
    cursor = offset + 2
    if length & 0x80:
        count = length & 0x7F
        if not count or count > 4 or cursor + count > len(data):
            fail("公开签名证书 DER 长度无效。")
        raw = data[cursor:cursor + count]
        if raw[0] == 0:
            fail("公开签名证书 DER 长度不规范。")
        length = int.from_bytes(raw, "big")
        cursor += count
        if length < 128:
            fail("公开签名证书 DER 长度不规范。")
    end = cursor + length
    if end > len(data):
        fail("公开签名证书 DER 内容不完整。")
    return tag, data[cursor:end], end


def der_children(data):
    children, cursor = [], 0
    while cursor < len(data):
        tag, value, cursor = der_item(data, cursor)
        children.append((tag, value))
    return children


def certificate_subject(der):
    tag, certificate, end = der_item(der)
    if tag != 0x30 or end != len(der):
        fail("公开签名证书格式无效。")
    certificate_fields = der_children(certificate)
    if len(certificate_fields) != 3 or certificate_fields[0][0] != 0x30:
        fail("公开签名证书结构无效。")
    tbs = der_children(certificate_fields[0][1])
    offset = 1 if tbs and tbs[0][0] == 0xA0 else 0
    if len(tbs) < offset + 6 or tbs[offset + 4][0] != 0x30:
        fail("公开签名证书缺少主体。")
    subject = {}
    for set_tag, rdn in der_children(tbs[offset + 4][1]):
        if set_tag != 0x31:
            fail("公开签名证书主体结构无效。")
        for sequence_tag, attribute in der_children(rdn):
            fields = der_children(attribute)
            if sequence_tag != 0x30 or len(fields) != 2 or fields[0][0] != 0x06:
                fail("公开签名证书主体属性无效。")
            oid, (string_tag, value) = fields[0][1], fields[1]
            if oid in (b"\x55\x04\x03", b"\x55\x04\x0b"):
                if string_tag in (0x0C, 0x13, 0x16):
                    decoded = value.decode("utf-8")
                elif string_tag == 0x1E:
                    decoded = value.decode("utf-16-be")
                else:
                    fail("公开签名证书主体编码不支持。")
                subject.setdefault("CN" if oid[-1] == 3 else "OU", []).append(decoded)
    return subject


def identity_gate():
    result = command([SECURITY, "find-identity", "-v", "-p", "codesigning"])
    identities = re.findall(rb'^\s*\d+\)\s+([0-9A-Fa-f]{40})\s+"[^"\r\n]+"\s*$',
                            result.stdout, re.MULTILINE)
    if IDENTITY.encode() not in [value.upper() for value in identities]:
        fail("固定 Apple Development 身份没有可用的有效证书与私钥；停止且不降为 ad-hoc。")
    result = command([SECURITY, "find-certificate", "-a", "-c", "Apple Development:", "-p"])
    matches = []
    for pem in re.findall(rb"-----BEGIN CERTIFICATE-----\s*(.*?)\s*-----END CERTIFICATE-----",
                          result.stdout, re.DOTALL):
        try:
            der = base64.b64decode(re.sub(rb"\s+", b"", pem), validate=True)
        except ValueError:
            fail("公开签名证书 PEM 无效。")
        if hashlib.sha1(der).hexdigest().upper() == IDENTITY:
            matches.append(der)
    if not matches:
        fail("无法核验固定签名证书的公开主体；停止且不降为 ad-hoc。")
    subject = certificate_subject(matches[0])
    if subject.get("OU") != [TEAM] or len(subject.get("CN", [])) != 1 or not subject["CN"][0].startswith("Apple Development:"):
        fail("固定证书的 Team 或证书类型不符合项目要求。")


def architecture(cpu, subtype):
    subtype &= 0xFFFFFF
    names = {
        (0x01000007, 3): "x86_64", (0x01000007, 8): "x86_64h",
        (0x0100000C, 0): "arm64", (0x0100000C, 1): "arm64", (0x0100000C, 2): "arm64e",
        (7, 3): "i386", (12, 6): "armv6", (12, 9): "armv7",
        (12, 11): "armv7s", (12, 12): "armv7k", (0x0200000C, 1): "arm64_32",
    }
    if (cpu, subtype) not in names:
        fail("候选包含尚未支持的 Mach-O 架构；停止，避免漏签。")
    return names[cpu, subtype]


def macho_architectures(path):
    with path.open("rb") as stream:
        header = stream.read(8)
        if len(header) < 4:
            return []
        thin = {b"\xce\xfa\xed\xfe": "<", b"\xcf\xfa\xed\xfe": "<",
                b"\xfe\xed\xfa\xce": ">", b"\xfe\xed\xfa\xcf": ">"}
        fat = {b"\xca\xfe\xba\xbe": (">", 20), b"\xbe\xba\xfe\xca": ("<", 20),
               b"\xca\xfe\xba\xbf": (">", 32), b"\xbf\xba\xfe\xca": ("<", 32)}
        if header[:4] in thin:
            stream.seek(4)
            payload = stream.read(8)
            if len(payload) != 8:
                fail("候选 Mach-O 头不完整。")
            return [architecture(*struct.unpack(thin[header[:4]] + "II", payload))]
        if header[:4] not in fat:
            return []
        if len(header) != 8:
            fail("候选通用 Mach-O 头不完整。")
        endian, size = fat[header[:4]]
        count = struct.unpack(endian + "I", header[4:])[0]
        if not 1 <= count <= 32:
            fail("候选通用 Mach-O 架构数无效。")
        entries = stream.read(count * size)
        if len(entries) != count * size:
            fail("候选通用 Mach-O 架构表不完整。")
        names = [architecture(*struct.unpack(endian + "II", entries[index * size:index * size + 8]))
                 for index in range(count)]
        if len(names) != len(set(names)):
            fail("候选通用 Mach-O 包含重复架构。")
        return names


def read_plist(path, root):
    if not inside(path.resolve(), root) or not path.is_file():
        fail("Info/entitlements 路径越界或缺失。")
    with path.open("rb") as stream:
        value = plistlib.load(stream)
    if not isinstance(value, dict):
        fail("Info/entitlements 必须为字典。")
    return value


def stable_identifier(value):
    return (isinstance(value, str) and bool(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9._-]{0,254}", value))
            and not re.search(r"(?:^|[._-])(?:tmp|private|gaocaozuo-build)(?:$|[._-])", value, re.I))


def deterministic_identifier(relative):
    name = re.sub(r"[^A-Za-z0-9]+", "-", Path(relative).name).strip("-")[:48] or "code"
    return BUNDLE + ".native." + name + "." + hashlib.sha256(relative.encode()).hexdigest()[:20]


def discover(app):
    natives, directories = {}, [app]
    for root, dirs, files in os.walk(app, followlinks=False):
        root = Path(root)
        dirs.sort()
        files.sort()
        for name in dirs + files:
            path = root / name
            if path.is_symlink():
                if not inside(path.resolve(strict=True), app):
                    fail("候选包含越出应用的符号链接。")
                continue
            details = path.lstat()
            if stat.S_ISDIR(details.st_mode):
                directories.append(path)
            elif stat.S_ISREG(details.st_mode):
                arches = macho_architectures(path)
                if arches:
                    if details.st_nlink != 1:
                        fail("Mach-O 存在硬链接，禁止修改候选外的同一 inode。")
                    natives[path] = arches
            else:
                fail("候选包含特殊文件，禁止签名。")
    bundles = {}
    for directory in directories:
        if directory != app and directory.suffix not in (".app", ".appex", ".xpc", ".framework", ".bundle"):
            continue
        info_path = directory / "Contents/Info.plist"
        framework = directory.suffix == ".framework"
        if framework:
            info_path = directory / "Resources/Info.plist"
        if not info_path.is_file():
            if directory == app or str(directory.relative_to(app)) in FIXED:
                fail("必要组件缺少 Info.plist。")
            continue
        info = read_plist(info_path, app)
        executable = info.get("CFBundleExecutable")
        if not isinstance(executable, str) or not executable or "/" in executable or executable in (".", ".."):
            fail("代码 bundle 的可执行文件配置无效。")
        binary = (directory / executable if framework else directory / "Contents/MacOS" / executable).resolve()
        if not inside(binary, app) or binary not in natives:
            fail("代码 bundle 的主程序不是候选内实际 Mach-O。")
        if binary in bundles:
            fail("多个代码 bundle 共享同一主程序，禁止重复改签。")
        bundles[binary] = (directory, info)
    objects = []
    for binary, arches in natives.items():
        sign_path, info = bundles.get(binary, (binary, None))
        relative = sign_path.relative_to(app).as_posix()
        if relative in FIXED and (not info or info.get("CFBundleIdentifier") != FIXED[relative][0]):
            fail("固定组件 Bundle ID 不匹配。")
        objects.append({"path": sign_path, "binary": binary, "relative": relative, "arches": arches, "info": info})
    if not set(FIXED).issubset({item["relative"] for item in objects}):
        fail("候选缺少根 App/Finder/Quick Look/ArchiveBroker 完整组件。")
    return sorted(objects, key=lambda item: (-len(item["path"].parts), item["relative"]))


def metadata(path, arch):
    result = command([CODESIGN, "--display", "--architecture", arch, "--verbose=4", str(path)], allow_failure=True)
    if result.returncode:
        expected = (str(path) + ": code object is not signed at all").encode()
        if result.returncode == 1 and result.stderr.strip() == expected and not result.stdout.strip():
            return {"signed": False, "identifier": None, "flags": 0, "entitlements": {}, "team": None,
                    "hasAuthority": False, "dr": ""}
        fail("无法读取原签名元数据；只接受明确的未签名对象。")
    text = (result.stdout + b"\n" + result.stderr).decode("utf-8", errors="strict")
    identifiers = re.findall(r"^Identifier=(.+)$", text, re.M)
    # Verbose output also contains `Executable Segment flags=...`, which is
    # unrelated to the CodeDirectory policy word. Only read its own line.
    flags = re.findall(r"^CodeDirectory\b[^\r\n]*\bflags=(0x[0-9a-fA-F]+)\b", text, re.M)
    teams = re.findall(r"^TeamIdentifier=(.+)$", text, re.M)
    if len(identifiers) != 1 or len(flags) != 1:
        fail("签名元数据缺少唯一 identifier/flags。")
    ent = command([CODESIGN, "--display", "--architecture", arch, "--entitlements", "-", "--xml", str(path)]).stdout.strip()
    entitlements = plistlib.loads(ent) if ent else {}
    if not isinstance(entitlements, dict):
        fail("嵌入 entitlements 不是字典。")
    requirements = command([CODESIGN, "--display", "--architecture", arch, "--requirements", "-", str(path)])
    dr = requirements.stdout.decode("utf-8").strip()
    return {"signed": True, "identifier": identifiers[0], "flags": int(flags[0], 16),
            "entitlements": entitlements, "team": teams[0] if len(teams) == 1 else None,
            "hasAuthority": bool(re.search(r"^Authority=", text, re.M)),
            "authorityDevelopment": bool(re.search(r"^Authority=Apple Development:", text, re.M)), "dr": dr}


def expression(identifier):
    return 'identifier "%s" and anchor apple generic and certificate leaf[subject.OU] = "%s"' % (identifier, TEAM)


def verify_dr(dr, identifier):
    # The compiler may omit quotes around an alphanumeric OU; its expression
    # order stays the same. Require the complete, single explicit DR, not substrings.
    clean = re.sub(r"/\*.*?\*/", "", dr, flags=re.S).strip()
    expected = (r'designated\s*=>\s*identifier\s+"' + re.escape(identifier)
                + r'"\s+and\s+anchor\s+apple\s+generic\s+and\s+certificate\s+leaf\[subject\.OU\]\s*=\s*"?'
                + re.escape(TEAM) + r'"?')
    if not re.fullmatch(expected, clean) or re.search(r"cdhash|certificate\s+leaf\s*=\s*H", clean, re.I):
        fail("新 designated requirement 不是完整的固定 identifier/Apple anchor/Team 规则。")


def json_value(value):
    if isinstance(value, bytes):
        return {"base64": base64.b64encode(value).decode("ascii")}
    if isinstance(value, datetime.datetime):
        return {"datetime": value.isoformat()}
    if isinstance(value, dict):
        return {key: json_value(item) for key, item in value.items()}
    if isinstance(value, list):
        return [json_value(item) for item in value]
    return value


def initial_7zz_metadata(item, before, project):
    if (item["relative"] != "Contents/Resources/Tools/7zz"
            or set(before) != {"x86_64", "arm64"}
            or sha256(item["binary"]) != INITIAL_7ZZ_SHA256
            or sha256(project / "Resources/Tools/7zz") != INITIAL_7ZZ_SHA256):
        return None
    unsigned, linker = before["x86_64"], before["arm64"]
    if (unsigned["signed"] or unsigned["identifier"] is not None or unsigned["flags"] != 0
            or not linker["signed"] or linker["identifier"] != "7zz" or linker["flags"] != REPLACED_FLAGS):
        return None
    for value in (unsigned, linker):
        if (value["entitlements"] or value["team"] not in (None, "not set")
                or value.get("hasAuthority") or value.get("authorityDevelopment")):
            return None
    return linker


def plan_objects(objects, app, project):
    sources = {}
    for item in objects:
        before = {arch: metadata(item["path"], arch) for arch in item["arches"]}
        first = before[item["arches"][0]]
        if any(any(value[key] != first[key] for key in ("signed", "identifier", "flags", "entitlements"))
               for value in before.values()):
            initial = initial_7zz_metadata(item, before, project)
            if initial is None:
                fail("通用 Mach-O 的架构元数据不同；停止，禁止扁平化。")
            first = initial
        old_flags = first["flags"]
        if old_flags & ~(POLICY_FLAGS | REPLACED_FLAGS):
            fail("原签名含未识别 flags，禁止静默丢弃。")
        fixed = FIXED.get(item["relative"])
        entitlement_path = None
        if fixed:
            identifier, source = fixed
            expected_entitlements = {}
            if source:
                entitlement_path = project / source
                expected_entitlements = read_plist(entitlement_path, project)
                sources[source] = sha256(entitlement_path)
            if first["entitlements"] and first["entitlements"] != expected_entitlements:
                fail("固定组件原 entitlements 与源码显式契约不一致。")
        else:
            candidate = first["identifier"]
            if not stable_identifier(candidate) and item["info"]:
                bundle_identifier = item["info"].get("CFBundleIdentifier")
                if stable_identifier(bundle_identifier):
                    candidate = bundle_identifier
            identifier = candidate if stable_identifier(candidate) else deterministic_identifier(item["binary"].relative_to(app).as_posix())
            expected_entitlements = first["entitlements"]
        item.update({"before": before, "identifier": identifier, "flags": old_flags & POLICY_FLAGS,
                     "entitlements": expected_entitlements, "entitlement_source": entitlement_path,
                     "before_sha256": sha256(item["binary"])})
    return sources


def sign_candidate(app, project, report):
    app, project, report, container = validated_paths(app, project, report)
    result = {"format": 1, "status": "preparing", "identitySHA1": IDENTITY, "team": TEAM,
              "signingKind": "Apple Development", "notarized": False, "smokeTestRun": False,
              "appName": app.name, "objects": []}
    atomic_report(report, result)
    try:
        objects = discover(app)
        sources = plan_objects(objects, app, project)
        identity_gate()
        with tempfile.TemporaryDirectory(prefix="signing-metadata-", suffix=".noindex", dir=str(container)) as temporary:
            temporary = Path(temporary)
            for index, item in enumerate(objects):
                for source, digest in sources.items():
                    if sha256(project / source) != digest:
                        fail("签名前 entitlements 源文件发生变化。")
                entitlements = temporary / ("entitlements-%d.plist" % index)
                entitlements.write_bytes(plistlib.dumps(item["entitlements"], sort_keys=True))
                argv = [CODESIGN, "--force", "--sign", IDENTITY, "--timestamp=none",
                        "--identifier", item["identifier"], "--options", hex(item["flags"]),
                        "--requirements", "=designated => " + expression(item["identifier"]),
                        "--entitlements", str(entitlements)]
                if item["path"].is_file() and item["entitlements"]:
                    argv.append("--force-library-entitlements")
                command(argv + [str(item["path"])])
            command([CODESIGN, "--verify", "--deep", "--strict", "--all-architectures", str(app)])
            for index, item in enumerate(objects):
                after = {}
                for arch in item["arches"]:
                    value = metadata(item["path"], arch)
                    if (not value["signed"] or value["identifier"] != item["identifier"]
                            or value["flags"] != item["flags"] or value["entitlements"] != item["entitlements"]
                            or value["team"] != TEAM or not value.get("authorityDevelopment")):
                        fail("签后某架构的 Team/identifier/flags/entitlements 与计划不符。")
                    verify_dr(value["dr"], item["identifier"])
                    prefix = temporary / ("certificate-%d-%s-" % (index, arch))
                    # This option has an optional argument: the '=' is required
                    # to keep the prefix from being interpreted as another input.
                    command([CODESIGN, "--display", "--architecture", arch,
                             "--extract-certificates=" + str(prefix), str(item["path"])])
                    leaf = Path(str(prefix) + "0")
                    if not leaf.is_file() or hashlib.sha1(leaf.read_bytes()).hexdigest().upper() != IDENTITY:
                        fail("签后实际叶证书与固定证书 SHA1 不符。")
                    after[arch] = value
                command([CODESIGN, "--verify", "--strict", "--all-architectures", "--test-requirement",
                         "=" + expression(item["identifier"]), str(item["path"])])
                result["objects"].append({
                    "codePath": item["relative"], "machOPath": item["binary"].relative_to(app).as_posix(),
                    "architectures": item["arches"], "identifier": item["identifier"],
                    "beforeSHA256": item["before_sha256"], "sha256": sha256(item["binary"]),
                    "before": json_value(item["before"]), "after": json_value(after),
                })
        for source, digest in sources.items():
            if sha256(project / source) != digest:
                fail("核验时 entitlements 源文件发生变化。")
        final_objects = discover(app)
        if [(item["relative"], item["arches"]) for item in final_objects] != [(item["relative"], item["arches"]) for item in objects]:
            fail("签名期间 Mach-O 集合发生变化。")
        result.update({"status": "verified", "sourceEntitlementsSHA256": sources,
                       "verifiedAt": datetime.datetime.now(datetime.timezone.utc).isoformat()})
        atomic_report(report, result)
        return result
    except Exception as error:
        result.update({"status": "failed", "error": str(error) if isinstance(error, SigningError) else type(error).__name__})
        atomic_report(report, result)
        raise


def main():
    parser = argparse.ArgumentParser(description="仅为搞操作隔离候选使用固定开发签名并核验全部 Mach-O")
    parser.add_argument("--app", required=True)
    parser.add_argument("--project", required=True)
    parser.add_argument("--report", required=True)
    args = parser.parse_args()
    try:
        result = sign_candidate(args.app, args.project, args.report)
        print("SIGNING_REPORT=" + str(Path(args.report).resolve()))
        print("固定 Apple Development 签名已逐对象核验：%d 个 Mach-O；未公证，未运行冒烟。" % len(result["objects"]))
        return 0
    except Exception as error:
        print("候选签名已停止：" + (str(error) if isinstance(error, SigningError) else type(error).__name__), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
