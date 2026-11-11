#!/usr/bin/env python3
"""One explicit owner/token lease per workspace resource; never steals a lock."""
import argparse
import datetime
import json
import os
from pathlib import Path
import secrets
import stat
import sys

ROOT = Path(__file__).resolve().parents[2] / "合并迁移-2026-11-02"


def lock_path(kind):
    if kind not in ('build', 'foreground'):
        raise RuntimeError('Unknown lease kind')
    return ROOT / (kind + '.lock')


def read_lease(kind='build'):
    lock = lock_path(kind)
    if not lock.exists() and not lock.is_symlink():
        return None
    info = lock.lstat()
    if not stat.S_ISDIR(info.st_mode) or lock.is_symlink() or info.st_uid != os.getuid():
        raise RuntimeError('Lease container is not an owned real directory')
    receipt = lock / 'owner.json'
    if receipt.is_symlink() or not receipt.is_file() or receipt.stat().st_uid != os.getuid():
        raise RuntimeError('Lease exists without a valid owner receipt; it will not be stolen')
    data = json.loads(receipt.read_text())
    if (data.get('kind') != kind or not isinstance(data.get('owner'), str) or not data['owner']
            or not isinstance(data.get('token'), str) or len(data['token']) != 64):
        raise RuntimeError('Invalid owner receipt; it will not be stolen')
    return data


def verify(kind, owner, token):
    data = read_lease(kind)
    if not data or not owner or not token or data['owner'] != owner or not secrets.compare_digest(data['token'], token):
        raise RuntimeError('Exact current lease owner/token required')
    return data


def main(kind):
    parser = argparse.ArgumentParser(description='Explicit workspace ' + kind + ' lease; no automatic expiry or lock stealing')
    subs = parser.add_subparsers(dest='action', required=True)
    acquire = subs.add_parser('acquire')
    acquire.add_argument('--owner', required=True)
    acquire.add_argument('--purpose', required=True)
    acquire.add_argument('--title', default='')
    subs.add_parser('status')
    for action in ('release', 'verify'):
        command = subs.add_parser(action)
        command.add_argument('--owner', default=os.environ.get('GAO_' + kind.upper() + '_LEASE_OWNER', ''))
        command.add_argument('--token', default=os.environ.get('GAO_' + kind.upper() + '_LEASE_TOKEN', ''))
    args = parser.parse_args()
    try:
        lock = lock_path(kind)
        if args.action == 'acquire':
            if not args.owner.strip() or not args.purpose.strip():
                raise RuntimeError('Owner and purpose cannot be empty')
            try:
                lock.mkdir(mode=0o700)
            except FileExistsError:
                raise RuntimeError('Lease already exists; refusing to steal or remove it')
            data = dict(kind=kind, owner=args.owner, token=secrets.token_hex(32), purpose=args.purpose,
                        title=args.title, acquiredAt=datetime.datetime.now(datetime.timezone.utc).isoformat(),
                        callerPID=os.getppid())
            # Atomic mkdir owns this new container. A torn receipt intentionally
            # blocks later acquisition until its creator resolves it explicitly.
            with (lock / 'owner.json').open('x') as stream:
                os.chmod(lock / 'owner.json', 0o600)
                json.dump(data, stream, ensure_ascii=False, indent=2)
                stream.write('\n')
                stream.flush()
                os.fsync(stream.fileno())
        elif args.action == 'status':
            data = read_lease(kind)
        else:
            data = verify(kind, args.owner, args.token)
            if args.action == 'release':
                if set(child.name for child in lock.iterdir()) != {'owner.json'}:
                    raise RuntimeError('Lease container contains unknown files; refusing to remove them')
                (lock / 'owner.json').unlink()
                lock.rmdir()
                data = dict(released=True, kind=kind, owner=args.owner)
        print(json.dumps(data, ensure_ascii=False))
        return 0
    except (RuntimeError, OSError, ValueError) as error:
        print(str(error), file=sys.stderr)
        return 1


if __name__ == "__main__":
    if len(sys.argv) < 2 or sys.argv[1] not in ("build", "foreground"):
        raise SystemExit("Usage: workspace_lease.py {build|foreground} {acquire|status|verify|release}")
    kind = sys.argv.pop(1)
    sys.exit(main(kind))
