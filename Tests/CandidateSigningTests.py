#!/usr/bin/python3
"""Pure-mock signing tests: never call security, codesign, or a real Mach-O."""
import base64
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import struct
import subprocess
import tempfile
import unittest
from unittest import mock
import uuid


PROJECT = Path(__file__).resolve().parent.parent
FIXED_IDENTITY = "A15B2B2D22B018CBC842063C9A8A589946647524"


def tlv(tag, payload):
    length = len(payload)
    raw_length = bytes([length]) if length < 128 else bytes([0x82]) + length.to_bytes(2, "big")
    return bytes([tag]) + raw_length + payload


def public_certificate(team, cn="Apple Development: Mock"):
    def attribute(oid, value):
        return tlv(0x31, tlv(0x30, tlv(0x06, oid) + tlv(0x0C, value.encode())))
    subject = tlv(0x30, attribute(b"\x55\x04\x03", cn) + attribute(b"\x55\x04\x0b", team))
    tbs = tlv(0x30, tlv(0xA0, tlv(2, b"\x02")) + tlv(2, b"\x01")
              + tlv(0x30, b"") * 3 + subject + tlv(0x30, b""))
    return tlv(0x30, tbs + tlv(0x30, b"") + tlv(3, b"\x00"))


def native(path, universal=False):
    path.parent.mkdir(parents=True, exist_ok=True)
    if universal:
        payload = b"\xca\xfe\xba\xbe" + struct.pack(">I", 2)
        payload += struct.pack(">IIIII", 0x01000007, 3, 48, 32, 0)
        payload += struct.pack(">IIIII", 0x0100000C, 0, 80, 32, 0)
        payload += bytes(64)
    else:
        payload = b"\xcf\xfa\xed\xfe" + struct.pack("<II", 0x0100000C, 0) + bytes(20)
    path.write_bytes(payload)
    path.chmod(0o755)


class CandidateSigningTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="GaoSigningTests-", suffix=".noindex")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name).resolve()
        spec = importlib.util.spec_from_file_location("candidate_signing_" + uuid.uuid4().hex,
                                                     PROJECT / "Scripts/sign-candidate.py")
        self.signer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.signer)
        self.assertEqual(self.signer.IDENTITY, FIXED_IDENTITY)
        self.project = self.root / "Project"
        self.project.mkdir()
        self.app = self.root / "Candidate.app"
        self.report = self.root / "signing.json"
        self.objects = {}
        for relative, (identifier, source) in self.signer.FIXED.items():
            bundle = self.app if relative == "." else self.app / relative
            executable = "Main" if relative == "." else bundle.stem
            native(bundle / "Contents/MacOS" / executable)
            (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundleIdentifier": identifier, "CFBundleExecutable": executable,
            }))
            self.objects[str(bundle)] = self.old_signature(identifier)
            if source:
                path = self.project / source
                path.parent.mkdir(parents=True, exist_ok=True)
                entitlement = {"com.apple.security.app-sandbox": True}
                if "QuickLook" in source:
                    entitlement["com.apple.security.files.user-selected.read-write"] = True
                path.write_bytes(plistlib.dumps(entitlement))
        self.library = self.app / "Contents/Resources/Tools/libnative.dylib"
        native(self.library)
        self.objects[str(self.library)] = self.old_signature("org.example.native", flags=0x10000,
            entitlements={"com.apple.security.cs.disable-library-validation": True})
        self.tool = self.app / "Contents/Resources/Tools/nested/tool"
        native(self.tool)
        self.objects[str(self.tool)] = None
        self.universal = self.app / "Contents/Resources/Tools/universal"
        native(self.universal, universal=True)
        self.objects[str(self.universal)] = self.old_signature("org.example.universal", flags=0x20002)
        self.commands = []
        self.signed = set()
        self.valid_identity = True
        self.security_failure = False
        self.post_team = self.signer.TEAM
        self.extracted_certificate = None
        self.der = public_certificate(self.signer.TEAM)
        real_sha1 = hashlib.sha1

        def certificate_hash(data=b""):
            if data == self.der:
                return mock.Mock(hexdigest=lambda: FIXED_IDENTITY)
            return real_sha1(data)

        patcher = mock.patch.object(self.signer.hashlib, "sha1", side_effect=certificate_hash)
        patcher.start()
        self.addCleanup(patcher.stop)
        patcher = mock.patch.object(self.signer.subprocess, "run", side_effect=self.fake_command)
        self.subprocess = patcher.start()
        self.addCleanup(patcher.stop)

    @staticmethod
    def old_signature(identifier, flags=0x20002, entitlements=None):
        return {"identifier": identifier, "flags": flags, "entitlements": entitlements or {},
                "team": "not set", "development": False,
                "dr": 'designated => cdhash H"0123456789abcdef"'}

    def completed(self, argv, stdout=b"", stderr=b"", status=0):
        return subprocess.CompletedProcess(argv, status, stdout, stderr)

    def fake_command(self, argv, **kwargs):
        self.commands.append(list(argv))
        self.assertIn(argv[0], (self.signer.CODESIGN, self.signer.SECURITY))
        if argv[0] == self.signer.SECURITY:
            if self.security_failure:
                return self.completed(argv, stderr=b"private diagnostic MUST_NOT_LEAK", status=1)
            if argv[1] == "find-identity":
                output = ('  1) %s "Apple Development: Mock"\n     1 valid identities found\n' % FIXED_IDENTITY).encode() if self.valid_identity else b"  0 valid identities found\n"
                return self.completed(argv, stdout=output)
            self.assertEqual(argv[1:], ["find-certificate", "-a", "-c", "Apple Development:", "-p"])
            return self.completed(argv, stdout=b"-----BEGIN CERTIFICATE-----\n" + base64.b64encode(self.der) + b"\n-----END CERTIFICATE-----\n")
        path = argv[-1]
        if "--sign" in argv:
            self.assertEqual(argv[argv.index("--sign") + 1], FIXED_IDENTITY)
            self.assertNotIn("--deep", argv)
            self.assertFalse(any(value.startswith("--preserve-metadata") for value in argv))
            requirement = argv[argv.index("--requirements") + 1]
            self.assertNotIn("cdhash", requirement)
            self.assertTrue(requirement.startswith("=designated => "))
            self.objects[path] = {
                "identifier": argv[argv.index("--identifier") + 1],
                "flags": int(argv[argv.index("--options") + 1], 16),
                "entitlements": plistlib.loads(Path(argv[argv.index("--entitlements") + 1]).read_bytes()),
                "team": self.post_team, "development": True, "dr": requirement[1:],
            }
            self.signed.add(path)
            return self.completed(argv)
        if "--verify" in argv:
            return self.completed(argv)
        self.assertIn("--display", argv)
        signature = self.objects[path]
        if signature is None:
            return self.completed(argv, stderr=(path + ": code object is not signed at all\n").encode(), status=1)
        if "--verbose=4" in argv:
            text = "Identifier=%s\nCodeDirectory v=20500 flags=%s(mock)\nTeamIdentifier=%s\n" % (
                signature["identifier"], hex(signature["flags"]), signature["team"])
            # Real verbose=4 output has a second, unrelated flags field.
            text += "Executable Segment base=0\nExecutable Segment limit=4096\nExecutable Segment flags=0x1\n"
            if signature["development"]:
                text += "Authority=Apple Development: Mock\n"
            return self.completed(argv, stderr=text.encode())
        if "--entitlements" in argv:
            return self.completed(argv, stdout=plistlib.dumps(signature["entitlements"]) if signature["entitlements"] else b"")
        if "--requirements" in argv:
            return self.completed(argv, stdout=signature["dr"].encode())
        extraction = [value for value in argv if value.startswith("--extract-certificates=")]
        self.assertEqual(len(extraction), 1)
        prefix = extraction[0].split("=", 1)[1]
        Path(prefix + "0").write_bytes(self.der if self.extracted_certificate is None else self.extracted_certificate)
        return self.completed(argv)

    def sign(self):
        return self.signer.sign_candidate(self.app, self.project, self.report)

    def sign_commands(self):
        return [argv for argv in self.commands if "--sign" in argv]

    def initial_mixed_7zz(self, change=None):
        tool = self.app / "Contents/Resources/Tools/7zz"
        native(tool, universal=True)
        source = self.project / "Resources/Tools/7zz"
        source.parent.mkdir(parents=True, exist_ok=True)
        source.write_bytes(tool.read_bytes())
        self.objects[str(tool)] = self.old_signature("7zz", flags=0x20002)
        original = self.signer.metadata

        def mixed(path, arch):
            value = original(path, arch)
            if path == tool and str(tool) not in self.signed:
                if arch == "x86_64":
                    value = {"signed": False, "identifier": None, "flags": 0, "entitlements": {},
                             "team": None, "hasAuthority": False, "dr": ""}
                if change:
                    change(value, arch)
            return value

        patcher = mock.patch.object(self.signer, "INITIAL_7ZZ_SHA256", hashlib.sha256(tool.read_bytes()).hexdigest())
        patcher.start(); self.addCleanup(patcher.stop)
        patcher = mock.patch.object(self.signer, "metadata", side_effect=mixed)
        patcher.start(); self.addCleanup(patcher.stop)
        return tool, source

    def test_nested_signing_order_flags_entitlements_and_complete_report(self):
        result = self.sign()
        self.assertEqual(result["status"], "verified")
        self.assertFalse(result["notarized"])
        self.assertFalse(result["smokeTestRun"])
        self.assertEqual(len(result["objects"]), 7)
        paths = [argv[-1] for argv in self.sign_commands()]
        ql = str(self.app / "Contents/PlugIns/GaoArchiveQuickLook.appex")
        broker = ql + "/Contents/XPCServices/ArchiveBroker.xpc"
        self.assertLess(paths.index(broker), paths.index(ql))
        self.assertEqual(paths[-1], str(self.app))
        self.assertEqual(self.objects[str(self.library)]["identifier"], "org.example.native")
        self.assertEqual(self.objects[str(self.library)]["flags"], 0x10000)
        self.assertEqual(self.objects[str(self.app)]["flags"], 0)
        library_command = next(argv for argv in self.sign_commands() if argv[-1] == str(self.library))
        self.assertIn("--force-library-entitlements", library_command)
        self.assertEqual(len(result["sourceEntitlementsSHA256"]), 2)
        for item in result["objects"]:
            self.assertEqual(len(item["sha256"]), 64)
            for metadata in item["after"].values():
                self.assertEqual(metadata["team"], self.signer.TEAM)
                self.assertNotIn("cdhash", metadata["dr"])
        deep = [argv for argv in self.commands if "--deep" in argv]
        self.assertEqual(len(deep), 1)
        self.assertIn("--verify", deep[0])
        self.assertEqual(json.loads(self.report.read_text())["status"], "verified")

    def test_unsigned_identifier_depends_only_on_relative_path(self):
        expected = self.signer.deterministic_identifier(self.tool.relative_to(self.app).as_posix())
        self.sign()
        self.assertEqual(self.objects[str(self.tool)]["identifier"], expected)
        self.assertNotIn(self.root.name, expected)
        self.assertEqual(expected, self.signer.deterministic_identifier("Contents/Resources/Tools/nested/tool"))

    def test_metadata_reads_code_directory_flags_not_executable_segment_flags(self):
        metadata = self.signer.metadata(self.library, "arm64")
        self.assertEqual(metadata["identifier"], "org.example.native")
        self.assertEqual(metadata["flags"], 0x10000)

    def test_metadata_rejects_missing_code_directory_even_with_segment_flags(self):
        original = self.fake_command

        def missing_directory(argv, **kwargs):
            result = original(argv, **kwargs)
            if "--verbose=4" in argv:
                result.stderr = result.stderr.replace(b"CodeDirectory ", b"OtherDirectory ")
            return result

        with mock.patch.object(self.signer.subprocess, "run", side_effect=missing_directory):
            with self.assertRaisesRegex(self.signer.SigningError, "identifier/flags"):
                self.signer.metadata(self.library, "arm64")

    def test_metadata_rejects_multiple_code_directory_policy_words(self):
        original = self.fake_command

        def duplicate_directory(argv, **kwargs):
            result = original(argv, **kwargs)
            if "--verbose=4" in argv:
                result.stderr += b"CodeDirectory v=20500 flags=0x0(mock)\n"
            return result

        with mock.patch.object(self.signer.subprocess, "run", side_effect=duplicate_directory):
            with self.assertRaisesRegex(self.signer.SigningError, "identifier/flags"):
                self.signer.metadata(self.library, "arm64")

    def test_existing_legal_nested_bundle_signing_identifier_is_preserved(self):
        bundle = self.app / "Contents/Resources/Tools/Extra.bundle"
        native(bundle / "Contents/MacOS/Extra")
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps({
            "CFBundleIdentifier": "org.example.info", "CFBundleExecutable": "Extra"}))
        self.objects[str(bundle)] = self.old_signature("org.example.existing-signature", flags=0)
        self.sign()
        self.assertEqual(self.objects[str(bundle)]["identifier"], "org.example.existing-signature")

    def test_missing_valid_private_key_identity_never_falls_back(self):
        self.valid_identity = False
        with self.assertRaisesRegex(self.signer.SigningError, "不降为 ad-hoc"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])
        self.assertEqual(json.loads(self.report.read_text())["status"], "failed")

    def test_security_failure_is_sanitized_and_never_falls_back(self):
        self.security_failure = True
        with self.assertRaises(self.signer.SigningError) as failure:
            self.sign()
        self.assertNotIn("MUST_NOT_LEAK", str(failure.exception))
        self.assertNotIn("MUST_NOT_LEAK", self.report.read_text())
        self.assertEqual(self.sign_commands(), [])

    def test_certificate_team_is_checked_before_any_sign(self):
        self.der = public_certificate("OTHERTEAM")
        with self.assertRaisesRegex(self.signer.SigningError, "Team"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_certificate_type_is_checked_before_any_sign(self):
        self.der = public_certificate(self.signer.TEAM, cn="Developer ID Application: Mock")
        with self.assertRaisesRegex(self.signer.SigningError, "证书类型"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_post_sign_team_mismatch_fails_report(self):
        self.post_team = "OTHERTEAM"
        with self.assertRaisesRegex(self.signer.SigningError, "Team"):
            self.sign()
        self.assertEqual(json.loads(self.report.read_text())["status"], "failed")

    def test_post_sign_actual_certificate_must_match_fixed_sha1(self):
        self.extracted_certificate = b"another public certificate"
        with self.assertRaisesRegex(self.signer.SigningError, "SHA1"):
            self.sign()
        self.assertEqual(json.loads(self.report.read_text())["status"], "failed")

    def test_unknown_policy_flags_stop_before_sign(self):
        self.objects[str(self.library)]["flags"] |= 0x40000000
        with self.assertRaisesRegex(self.signer.SigningError, "flags"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_fixed_component_entitlements_conflict_stops_before_sign(self):
        self.objects[str(self.app)]["entitlements"] = {"com.apple.security.app-sandbox": True}
        with self.assertRaisesRegex(self.signer.SigningError, "entitlements"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_per_architecture_metadata_difference_is_rejected(self):
        original = self.signer.metadata

        def divergent(path, arch):
            value = original(path, arch)
            if path == self.universal and arch == "x86_64":
                value["flags"] = 0x10000
            return value

        with mock.patch.object(self.signer, "metadata", side_effect=divergent):
            with self.assertRaisesRegex(self.signer.SigningError, "架构元数据不同"):
                self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_known_initial_mixed_7zz_is_signed_and_all_architectures_verified(self):
        tool, _ = self.initial_mixed_7zz()
        result = self.sign()
        record = next(item for item in result["objects"] if item["codePath"] == "Contents/Resources/Tools/7zz")
        self.assertFalse(record["before"]["x86_64"]["signed"])
        self.assertEqual(record["before"]["arm64"]["flags"], 0x20002)
        self.assertEqual(set(record["after"]), {"x86_64", "arm64"})
        for value in record["after"].values():
            self.assertEqual(value["flags"], 0)
            self.assertEqual(value["team"], self.signer.TEAM)
        self.assertEqual(self.objects[str(tool)]["identifier"], "7zz")

    def test_initial_mixed_7zz_real_policy_difference_is_rejected(self):
        self.initial_mixed_7zz(lambda value, arch: value.update(flags=value["flags"] | 0x10000) if arch == "arm64" else None)
        with self.assertRaisesRegex(self.signer.SigningError, "架构元数据不同"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_initial_mixed_7zz_entitlements_difference_is_rejected(self):
        self.initial_mixed_7zz(lambda value, arch: value.update(entitlements={"com.apple.security.app-sandbox": True}) if arch == "arm64" else None)
        with self.assertRaisesRegex(self.signer.SigningError, "架构元数据不同"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_initial_mixed_7zz_certificate_is_rejected(self):
        self.initial_mixed_7zz(lambda value, arch: value.update(hasAuthority=True) if arch == "arm64" else None)
        with self.assertRaisesRegex(self.signer.SigningError, "架构元数据不同"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_initial_mixed_7zz_team_is_rejected(self):
        self.initial_mixed_7zz(lambda value, arch: value.update(team=self.signer.TEAM) if arch == "arm64" else None)
        with self.assertRaisesRegex(self.signer.SigningError, "架构元数据不同"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_initial_mixed_7zz_source_hash_mismatch_is_rejected(self):
        _, source = self.initial_mixed_7zz()
        source.write_bytes(source.read_bytes() + b"changed")
        with self.assertRaisesRegex(self.signer.SigningError, "架构元数据不同"):
            self.sign()
        self.assertEqual(self.sign_commands(), [])

    def test_fixed_bundle_identifier_mismatch_stops_before_system_commands(self):
        path = self.app / "Contents/Info.plist"
        info = plistlib.loads(path.read_bytes())
        info["CFBundleIdentifier"] = "other.application"
        path.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(self.signer.SigningError, "Bundle ID"):
            self.sign()
        self.assertEqual(self.commands, [])

    def test_candidate_symlink_escape_is_rejected(self):
        outside = self.root / "outside-native"
        native(outside)
        (self.app / "Contents/Resources/Tools/escape").symlink_to(outside)
        with self.assertRaisesRegex(self.signer.SigningError, "符号链接"):
            self.sign()
        self.assertEqual(self.commands, [])

    def test_hardlinked_native_is_rejected(self):
        os.link(self.library, self.library.parent / "hardlinked")
        with self.assertRaisesRegex(self.signer.SigningError, "硬链接"):
            self.sign()
        self.assertEqual(self.commands, [])

    def test_report_must_not_modify_signed_app(self):
        self.report = self.app / "Contents/Resources/signing.json"
        with self.assertRaisesRegex(self.signer.SigningError, "报告"):
            self.sign()
        self.assertEqual(self.commands, [])

    def test_complete_designated_requirement_rejects_cdhash_or_extra_terms(self):
        expected = "designated => " + self.signer.expression(self.signer.BUNDLE)
        self.signer.verify_dr(expected, self.signer.BUNDLE)
        for dr in (expected + ' or cdhash H"abc"', expected + " and true", 'designated => cdhash H"abc"'):
            with self.subTest(dr=dr):
                with self.assertRaises(self.signer.SigningError):
                    self.signer.verify_dr(dr, self.signer.BUNDLE)

    def test_truncated_certificate_is_rejected_without_system_command(self):
        with self.assertRaises(self.signer.SigningError):
            self.signer.certificate_subject(self.der[:-1])
        self.assertEqual(self.commands, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
