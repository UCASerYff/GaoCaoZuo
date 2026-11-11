#!/usr/bin/env python3
"""Exercise lease ownership without touching the real workspace locks."""
import contextlib
import importlib.util
import io
import json
from pathlib import Path
import shutil
import subprocess
import sys
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('workspace_lease', Path(__file__).resolve().parents[1] / 'Scripts/workspace_lease.py')
lease = importlib.util.module_from_spec(spec)
spec.loader.exec_module(lease)
bootstrap_spec = importlib.util.spec_from_file_location('setup_workspace_leases', Path(__file__).resolve().parents[1] / 'Scripts/setup-workspace-leases.py')
bootstrap = importlib.util.module_from_spec(bootstrap_spec)
bootstrap_spec.loader.exec_module(bootstrap)


class WorkspaceLeaseTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(suffix='.noindex', dir='/private/tmp')
        self.original_root = lease.ROOT
        lease.ROOT = Path(self.temporary.name)
        self.original_argv = sys.argv

    def tearDown(self):
        lease.ROOT = self.original_root
        sys.argv = self.original_argv
        self.temporary.cleanup()

    def cli(self, kind, *args):
        sys.argv = ['workspace_lease', *args]
        output = io.StringIO()
        with contextlib.redirect_stdout(output), contextlib.redirect_stderr(io.StringIO()):
            status = lease.main(kind)
        return status, json.loads(output.getvalue()) if output.getvalue() else None

    def test_exact_owner_token_and_explicit_release(self):
        status, owner = self.cli('build', 'acquire', '--owner', 'test', '--purpose', 'unit test')
        self.assertEqual(status, 0)
        self.assertEqual(self.cli('build', 'acquire', '--owner', 'other', '--purpose', 'test')[0], 1)
        self.assertEqual(self.cli('build', 'verify', '--owner', 'test', '--token', 'wrong')[0], 1)
        self.assertEqual(self.cli('build', 'release', '--owner', 'other', '--token', owner['token'])[0], 1)
        self.assertEqual(self.cli('build', 'verify', '--owner', 'test', '--token', owner['token'])[0], 0)
        self.assertEqual(self.cli('build', 'release', '--owner', 'test', '--token', owner['token'])[0], 0)
        self.assertIsNone(lease.read_lease())

    def test_foreground_and_build_are_independent_shared_resources(self):
        _, build = self.cli('build', 'acquire', '--owner', 'test', '--purpose', 'build')
        _, front = self.cli('foreground', 'acquire', '--owner', 'test', '--purpose', 'foreground')
        self.assertNotEqual(build['token'], front['token'])
        self.assertEqual(self.cli('foreground', 'release', '--owner', 'test', '--token', build['token'])[0], 1)
        self.assertEqual(self.cli('foreground', 'release', '--owner', 'test', '--token', front['token'])[0], 0)
        self.assertEqual(self.cli('build', 'verify', '--owner', 'test', '--token', build['token'])[0], 0)

    def test_torn_or_unknown_lock_is_never_stolen(self):
        root = lease.ROOT / 'build.lock'; root.mkdir()
        self.assertEqual(self.cli('build', 'acquire', '--owner', 'test', '--purpose', 'test')[0], 1)
        self.assertTrue(root.exists())
        root.rmdir()
        _, owner = self.cli('build', 'acquire', '--owner', 'test', '--purpose', 'test')
        (root / 'unknown-user-file').write_bytes(b'keep')
        self.assertEqual(self.cli('build', 'release', '--owner', 'test', '--token', owner['token'])[0], 1)
        self.assertTrue((root / 'unknown-user-file').exists())
        self.assertTrue((root / 'owner.json').exists())

    def test_arbitrary_clone_name_bootstraps_same_workspace_lock(self):
        project = lease.ROOT / "GaoCaoZuo clone '任意名字'"
        (project / 'Scripts').mkdir(parents=True)
        shutil.copyfile(Path(lease.__file__), project / 'Scripts/workspace_lease.py')
        root = bootstrap.setup(project)
        def invoke(kind, *args):
            result = subprocess.run([sys.executable, '-B', str(root / (kind + '_lease.py')), *args],
                                    stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)
        self.assertIsNone(invoke('build', 'status'))
        owner = invoke('build', 'acquire', '--owner', 'clone-test', '--purpose', 'synthetic clone')
        self.assertEqual(json.loads((root / 'build.lock/owner.json').read_text())['token'], owner['token'])
        self.assertEqual(invoke('build', 'verify', '--owner', 'clone-test', '--token', owner['token'])['owner'], 'clone-test')
        self.assertIsNone(invoke('foreground', 'status'))
        invoke('build', 'release', '--owner', 'clone-test', '--token', owner['token'])
        self.assertFalse((root / 'build.lock').exists())

    def test_legacy_shim_upgrade_preserves_active_lock_bytes(self):
        project = lease.ROOT / '搞操作'; project.mkdir()
        root = project.parent / '合并迁移-2026-11-02'; root.mkdir()
        for kind in ('build', 'foreground'):
            (root / (kind + '_lease.py')).write_text(bootstrap.legacy_entry_content(kind))
        lock = root / 'build.lock'; lock.mkdir()
        original = b'{"owner":"other-active-owner","token":"keep-exact-token"}\n'
        (lock / 'owner.json').write_bytes(original)
        bootstrap.setup(project)
        self.assertEqual((lock / 'owner.json').read_bytes(), original)
        self.assertEqual((root / 'build_lease.py').read_text(), bootstrap.entry_content('build', project.name))

    def test_bootstrap_refuses_foreign_entry_before_writing_anything(self):
        project = lease.ROOT / 'ArbitraryClone'; project.mkdir()
        root = project.parent / '合并迁移-2026-11-02'; root.mkdir()
        other = root / 'foreground_lease.py'; other.write_bytes(b'keep unrelated entry')
        with self.assertRaisesRegex(RuntimeError, 'refusing to overwrite'):
            bootstrap.setup(project)
        self.assertEqual(other.read_bytes(), b'keep unrelated entry')
        self.assertFalse((root / 'build_lease.py').exists())


if __name__ == '__main__':
    unittest.main()
