#!/usr/bin/env python3
"""Create thin workspace entries; only exact legacy shims may be upgraded, never locks."""
import os
from pathlib import Path

def entry_content(kind, project_name):
    return '''#!/usr/bin/env python3
from pathlib import Path
import runpy
import sys
_source = Path(__file__).resolve().parents[1] / %r / 'Scripts/workspace_lease.py'
_api = runpy.run_path(str(_source))

def read_lease():
    return _api["read_lease"]("%s")

if __name__ == "__main__":
    sys.exit(_api["main"]("%s"))
''' % (project_name, kind, kind)


def legacy_entry_content(kind):
    """Recognize only the exact previously shipped bootstrap, never other code."""
    return '''#!/usr/bin/env python3
from pathlib import Path
import runpy
import sys
_api = runpy.run_path(str(Path(__file__).resolve().parents[1] / "搞操作/Scripts/workspace_lease.py"))

def read_lease():
    return _api["read_lease"]("%s")

if __name__ == "__main__":
    sys.exit(_api["main"]("%s"))
''' % (kind, kind)


def setup(project):
    project = project.resolve(strict=True)
    root = project.parent / '合并迁移-2026-11-02'
    if root.is_symlink():
        raise RuntimeError('Workspace lease root cannot be a symlink')
    root.mkdir(exist_ok=True, mode=0o700)
    # Validate every existing entry before writing either one. A legacy shim can
    # be upgraded only for its original package, keeping another checkout intact.
    for kind in ('build', 'foreground'):
        path = root / (kind + '_lease.py')
        if path.exists() or path.is_symlink():
            allowed = [entry_content(kind, project.name)]
            if project.name == '搞操作':
                allowed.append(legacy_entry_content(kind))
            if path.is_symlink() or not path.is_file() or path.read_text() not in allowed:
                raise RuntimeError('Existing workspace entry differs; refusing to overwrite: ' + str(path))
    for kind in ('build', 'foreground'):
        path = root / (kind + '_lease.py')
        content = entry_content(kind, project.name)
        if path.exists():
            if path.read_text() != content:
                temporary = root / ('.' + kind + '_lease.new')
                descriptor = os.open(temporary, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o700)
                with os.fdopen(descriptor, 'w') as stream:
                    stream.write(content)
                    stream.flush()
                    os.fsync(stream.fileno())
                os.replace(temporary, path)
            continue
        descriptor = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o700)
        with os.fdopen(descriptor, 'w') as stream:
            stream.write(content)
    return root


if __name__ == '__main__':
    setup(Path(__file__).resolve().parents[1])
    print('Workspace lease entries verified; all callers use the same build.lock/foreground.lock.')
