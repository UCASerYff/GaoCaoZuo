#!/usr/bin/env python3
"""No-backup installer regressions; synthetic files only, no apps are launched."""
import hashlib
import importlib.util
import json
from pathlib import Path
import plistlib
import shutil
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

PROJECT = Path(__file__).resolve().parent.parent
spec = importlib.util.spec_from_file_location('installer', PROJECT / 'Scripts/install_safety.py')
installer = importlib.util.module_from_spec(spec)
spec.loader.exec_module(installer)
BUNDLE = installer.BUNDLE


def fixture(path, version, payload, bundle=BUNDLE):
    (path / 'Contents/MacOS').mkdir(parents=True)
    (path / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': bundle, 'CFBundleExecutable': 'GaoCaoZuo',
        'CFBundleShortVersionString': version, 'CFBundleVersion': '17'}))
    (path / 'Contents/MacOS/GaoCaoZuo').write_bytes(payload)
    ext = path / 'Contents/PlugIns/GaoFinderSync.appex'
    (ext / 'Contents/MacOS').mkdir(parents=True)
    (ext / 'Contents/Info.plist').write_bytes(plistlib.dumps({
        'CFBundleIdentifier': BUNDLE + '.FinderSync', 'CFBundleExecutable': 'GaoFinderSync',
        'CFBundlePackageType': 'XPC!', 'NSExtension': {'NSExtensionPointIdentifier': 'com.apple.FinderSync'}}))
    (ext / 'Contents/MacOS/GaoFinderSync').write_bytes(payload + b' extension')


class NoBackupInstallTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='gaocaozuo-install-tests-', suffix='.noindex', dir='/private/tmp')
        self.root = Path(self.temp.name)
        self.source = self.root / 'source/搞操作.app'
        self.target = self.root / 'Applications/搞操作.app'
        self.data = self.root / 'Data'
        self.prefs = self.root / 'Preferences.plist'
        self.receipts = self.root / 'receipts.noindex'
        fixture(self.source, '1.16', b'new')
        fixture(self.target, '1.15', b'old')
        (self.data / 'attachments/nested').mkdir(parents=True)
        (self.data / 'attachments/nested/actual.pdf').write_bytes(b'actual user attachment')
        (self.data / 'settings.json').write_bytes(b'{"enabled":true}')
        self.prefs.write_bytes(plistlib.dumps({'keep': True}))
        self.before = installer.live_data_inventory(self.data, self.prefs)
        self.args = SimpleNamespace(app=str(self.source), target=str(self.target), data_root=str(self.data),
                                    preferences=str(self.prefs), receipt_root=str(self.receipts), simulate=True)

    def tearDown(self):
        self.temp.cleanup()

    def manifest_path(self):
        return next(self.receipts.glob('install-*.json'))

    def install(self):
        installer.install(self.args)
        return json.loads(self.manifest_path().read_text())

    def evidence(self, record):
        path = self.root / 'evidence.json'
        path.write_text(json.dumps({'version': record['version'], 'build': record['build'],
            'candidateInventorySHA256': hashlib.sha256(json.dumps(record['candidate_inventory'], sort_keys=True, separators=(',', ':')).encode()).hexdigest(),
            'verificationScope': 'static-and-targeted', 'smokeTestRun': False, 'passed': True}))
        return path

    def finalize(self, evidence):
        installer.finalize(SimpleNamespace(manifest=str(self.manifest_path()), verification_scope='static-and-targeted', verification_evidence=str(evidence)))

    def test_update_leaves_data_and_no_backup_or_previous_app(self):
        record = self.install()
        self.assertEqual(installer.live_data_inventory(self.data, self.prefs), self.before)
        self.assertEqual(installer.inventory(self.target, True), installer.inventory(self.source, True))
        self.assertFalse(record['backup_created'])
        self.assertFalse(record['rollback_available'])
        self.assertNotIn('backups', record)
        self.assertFalse(Path(record['stage_dir']).exists())
        apps = sorted(str(p.relative_to(self.root)) for p in self.root.rglob('*.app'))
        self.assertEqual(apps, ['Applications/搞操作.app', 'source/搞操作.app'])
        self.finalize(self.evidence(record))
        final = json.loads(self.manifest_path().read_text())
        self.assertEqual(final['state'], 'verified')
        self.assertFalse(final['gui_verified'])
        self.assertEqual(installer.live_data_inventory(self.data, self.prefs), self.before)

    def test_changed_attachment_rejected_before_old_program_deletion(self):
        original_copy = installer.copy_verified
        def concurrent_change(*args, **kwargs):
            result = original_copy(*args, **kwargs)
            (self.data / 'attachments/nested/actual.pdf').write_bytes(b'user concurrent edit')
            return result
        with patch.object(installer, 'copy_verified', side_effect=concurrent_change):
            with self.assertRaisesRegex(RuntimeError, '资料或设置'):
                installer.install(self.args)
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'old')
        self.assertEqual((self.data / 'attachments/nested/actual.pdf').read_bytes(), b'user concurrent edit')
        self.assertFalse(any(self.target.parent.glob('.gaocaozuo-install-*')))

    def test_unreadable_data_stops_before_candidate_creation(self):
        with patch.object(installer, 'live_data_inventory', side_effect=PermissionError('unreadable')):
            with self.assertRaises(PermissionError):
                installer.install(self.args)
        self.assertFalse(self.receipts.exists())
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'old')

    def test_first_install_missing_data_is_recorded_without_creating_empty_store(self):
        shutil.rmtree(self.target)
        self.args.data_root = str(self.root / 'MissingData')
        record = self.install()
        self.assertEqual(record['data_inventory']['data']['state'], 'missing')
        self.assertFalse(Path(self.args.data_root).exists())

    def test_existing_install_missing_data_stops_before_replacement(self):
        self.args.data_root = str(self.root / 'MissingData')
        with self.assertRaisesRegex(RuntimeError, '资料目录或主设置.*缺失'):
            installer.install(self.args)
        self.assertFalse(Path(self.args.data_root).exists())
        self.assertFalse(self.receipts.exists())
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'old')
        self.assertEqual(installer.live_data_inventory(self.data, self.prefs), self.before)

    def test_existing_install_missing_authoritative_settings_stops_before_replacement(self):
        (self.data / 'settings.json').unlink()
        before = installer.live_data_inventory(self.data, self.prefs)
        with self.assertRaisesRegex(RuntimeError, '主设置 settings.json 缺失'):
            installer.install(self.args)
        self.assertFalse(self.receipts.exists())
        self.assertFalse((self.data / 'settings.json').exists())
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'old')
        self.assertEqual(installer.live_data_inventory(self.data, self.prefs), before)

    def test_symlink_data_and_overlapping_paths_rejected(self):
        alias = self.root / 'Alias'
        alias.symlink_to(self.data)
        self.args.data_root = str(alias)
        with self.assertRaises(RuntimeError):
            installer.install(self.args)
        self.args.data_root = str(self.target / 'UserData')
        with self.assertRaises(RuntimeError):
            installer.install(self.args)
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'old')

    def test_wrong_bundle_and_indexable_source_rejected(self):
        plist = self.source / 'Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes()); info['CFBundleIdentifier'] = 'com.example.Unrelated'
        plist.write_bytes(plistlib.dumps(info))
        with self.assertRaisesRegex(RuntimeError, 'Bundle ID'):
            installer.install(self.args)
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'old')
        self.args.app = '/Applications/Another.app'
        with self.assertRaisesRegex(RuntimeError, '.noindex'):
            installer.install(self.args)

    def test_foreign_finder_extension_stops_before_mutation(self):
        plist = self.source / 'Contents/PlugIns/GaoFinderSync.appex/Contents/Info.plist'
        info = plistlib.loads(plist.read_bytes()); info['CFBundleIdentifier'] = 'com.example.Unrelated'
        plist.write_bytes(plistlib.dumps(info))
        with patch.object(installer, 'run') as external:
            with self.assertRaisesRegex(RuntimeError, '扩展标识'):
                installer.install(self.args)
            external.assert_not_called()
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'old')

    def test_registration_failure_stops_without_restore_or_data_change(self):
        def register(app, simulate, remove=False):
            if app == self.target and not remove:
                raise RuntimeError('registration unavailable')
        with patch.object(installer, 'register', side_effect=register):
            with self.assertRaisesRegex(RuntimeError, 'registration unavailable'):
                installer.install(self.args)
        self.assertEqual((self.target / 'Contents/MacOS/GaoCaoZuo').read_bytes(), b'new')
        self.assertEqual(installer.live_data_inventory(self.data, self.prefs), self.before)
        self.assertFalse(any(self.target.parent.glob('.gaocaozuo-install-*')))
        self.assertEqual(json.loads(self.manifest_path().read_text())['state'], 'failed')

    def test_pending_install_and_wrong_evidence_rejected(self):
        record = self.install()
        with self.assertRaisesRegex(RuntimeError, '未完成'):
            installer.install(self.args)
        evidence = self.evidence(record)
        wrong = json.loads(evidence.read_text()); wrong['smokeTestRun'] = True
        evidence.write_text(json.dumps(wrong))
        with self.assertRaisesRegex(RuntimeError, '不匹配'):
            self.finalize(evidence)
        self.assertEqual(json.loads(self.manifest_path().read_text())['state'], 'installed_pending_verification')

    def test_changed_installed_program_rejected_at_finalize(self):
        record = self.install()
        (self.target / 'Contents/MacOS/GaoCaoZuo').write_bytes(b'changed')
        with self.assertRaisesRegex(RuntimeError, '程序发生变化'):
            self.finalize(self.evidence(record))

    def test_precise_release_cleanup_requires_valid_new_checksum(self):
        project = self.root / 'Project'
        release = project / 'Release'; release.mkdir(parents=True)
        for name in ('GaoCaoZuo-1.15.dmg', 'GaoCaoZuo-1.15-source.zip', 'GaoCaoZuo-1.16.dmg', 'GaoCaoZuo-1.17.dmg', 'GaoWenJian-1.00.dmg', 'actual-attachment.pdf'):
            (release / name).write_bytes(b'fixture')
        with patch.object(installer, 'PROJECT', project):
            installer.cleanup_old_releases('1.16')
            self.assertTrue((release / 'GaoCaoZuo-1.15.dmg').exists())
            (release / 'GaoCaoZuo-1.16.dmg.sha256').write_text(installer.digest_file(release / 'GaoCaoZuo-1.16.dmg') + '  GaoCaoZuo-1.16.dmg\n')
            installer.cleanup_old_releases('1.16')
        self.assertFalse((release / 'GaoCaoZuo-1.15.dmg').exists())
        self.assertFalse((release / 'GaoCaoZuo-1.15-source.zip').exists())
        self.assertTrue((release / 'GaoCaoZuo-1.17.dmg').exists())
        self.assertTrue((release / 'GaoWenJian-1.00.dmg').exists())
        self.assertTrue((release / 'actual-attachment.pdf').exists())


if __name__ == '__main__':
    unittest.main()
