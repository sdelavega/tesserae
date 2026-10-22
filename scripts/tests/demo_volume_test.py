#!/usr/bin/env python3
# Tesserae: a disk-space visualizer.
# Copyright (C) 2026 Stephen de la Vega
#
# This program is free software: you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation, either version 3 of the License, or
# (at your option) any later version.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE. See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program. If not, see <https://www.gnu.org/licenses/>.

import ctypes
import errno
import os
import csv
from collections import defaultdict
import contextlib
import io
import datetime as dt
import importlib.util
import pathlib
import plistlib
import re
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

SCRIPT = pathlib.Path(__file__).resolve().parents[1] / 'make-demo-volume.py'
UUID = '12345678-1234-1234-1234-123456789ABC'
# The refreshed source tree plus curated text exceed the former 16 MiB fixture.
SMALL_BYTES = 32 * 1024**2
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location('demo', SCRIPT)
demo = importlib.util.module_from_spec(spec)
spec.loader.exec_module(demo)


class DemoTests(unittest.TestCase):
    def test_dry_runs(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            for name in ('first.tsv', 'second.tsv'):
                subprocess.run([sys.executable, '-I', str(SCRIPT), '--target', str(root / 'absent'),
                                '--volume-uuid', UUID, '--bytes', str(SMALL_BYTES), '--dry-run',
                                '--manifest', str(root / name)], check=True, capture_output=True)
            self.assertEqual(sorted(p.name for p in root.iterdir()), ['first.tsv', 'second.tsv'])
            self.assertEqual((root / 'first.tsv').read_bytes(), (root / 'second.tsv').read_bytes())
            with (root / 'first.tsv').open() as stream:
                rows = list(csv.DictReader(stream, delimiter='\t'))
            self.assertGreater(len(rows), 1000)
            self.assertTrue(all(int(r['bytes']) >= (0 if r['path'].startswith('Projects/tesserae/') else 1) for r in rows))
            self.assertLessEqual(abs(sum(int(r['bytes']) for r in rows) - SMALL_BYTES), SMALL_BYTES * .02)
            self.assertTrue(all(not re.search(r'file_?\d{3,}', r['path']) for r in rows))
            dates = [dt.datetime.fromisoformat(r['mtime']) for r in rows]
            self.assertGreaterEqual(min(dates).year, 1985)
            self.assertLessEqual(max(dates), dt.datetime.now(dt.timezone.utc))

    def test_realistic_default(self):
        entries = demo.plan(18 * 1024**3)
        self.assertEqual(sum(e.size for e in entries), 18 * 1024**3)
        self.assertTrue(40000 <= len(entries) <= 60000)
        for folder, low, high in [('Photos', 2500, 3500), ('Music', 500, 750),
                                  ('Desktop', 20, 40), ('Downloads', 60, 120),
                                  ('Documents', 400, 900)]:
            subset = [e for e in entries if e.path.parts[0] == folder]
            self.assertTrue(low <= len(subset) <= high, (folder, len(subset)))
        photos = [e for e in entries if e.path.parts[0] == 'Photos']
        self.assertTrue(25 <= len({e.path.parts[1] for e in photos}) <= 40)
        self.assertEqual(len({dt.datetime.fromtimestamp(e.mtime, dt.timezone.utc).year for e in photos}), 8)
        tracks = [e for e in entries if e.path.parts[0] == 'Music' and e.path.suffix == '.m4a']
        self.assertTrue(500 <= len(tracks) <= 700)
        self.assertTrue(45 <= len({e.path.parent for e in tracks}) <= 60)
        self.assertTrue(25 <= len({e.path.parts[1] for e in tracks}) <= 35)
        for e in entries:
            bounds = {'.HEIC': (.4, 6), '.ARW': (18, 70), '.m4a': (2, 15)}
            if e.path.suffix in bounds:
                low, high = bounds[e.path.suffix]
                self.assertTrue(low * demo.MIB <= e.size <= high * demo.MIB, str(e.path))
        self.assertEqual(len({e.path for e in entries}), len(entries))
        self.assertEqual({e.path.parts[0] for e in entries if len(e.path.parts) > 1},
                         set('Documents Downloads Desktop Photos Music Movies Projects Archive Backups'.split()))
        raw = [e for e in entries if e.path.suffix == '.ARW']
        self.assertTrue(raw)
        paths = {e.path for e in entries}
        self.assertTrue(all(e.path.with_suffix('.xmp') in paths for e in raw))
        pixels = [e for e in entries if e.path.name.startswith('PXL_')]
        self.assertTrue(pixels)
        self.assertTrue(all(e.path.name[4:12] == dt.datetime.fromtimestamp(e.mtime, dt.timezone.utc).strftime('%Y%m%d') for e in pixels))

    def test_package_layouts(self):
        entries = demo.plan()
        packages = defaultdict(set)
        footprints = defaultdict(int)
        dates = []
        for e in entries:
            if 'node_modules' not in e.path.parts:
                continue
            if e.path.name == '.package-lock.json':
                self.assertNotEqual(e.mtime, demo.NPM_MTIME)
                continue
            parts = e.path.parts
            offset = len(parts) - 1 - list(reversed(parts)).index('node_modules') + 1
            package = parts[offset]
            if package.startswith('@'):
                package += '/' + parts[offset + 1]
            packages[package].add(e.path.name)
            footprints[parts[1]] += 1
            dates.append(e.mtime)
        self.assertGreaterEqual(len(packages), 15)
        self.assertTrue(dates)
        self.assertEqual(demo.NPM_MTIME, int(dt.datetime(1985, 10, 26, 8, 15, tzinfo=dt.timezone.utc).timestamp()))
        self.assertEqual(set(dates), {demo.NPM_MTIME})
        self.assertTrue(all(10000 <= n <= 25000 for n in footprints.values()), footprints)
        owners = defaultdict(set)
        for package, names in packages.items():
            self.assertTrue({'package.json', 'README.md', 'LICENSE'} <= names, package)
            for name in names:
                owners[name].add(package)
        standard = {'package.json', 'README.md', 'LICENSE', 'index.js', 'CHANGELOG.md'}
        self.assertTrue(all(len(pkgs) <= 4 for name, pkgs in owners.items() if name not in standard),
                        {name: pkgs for name, pkgs in owners.items() if name not in standard and len(pkgs) > 4})
        by_path = {str(e.path): e for e in entries}
        for project in footprints:
            base = f'Projects/{project}/'
            self.assertEqual(by_path[base + 'package-lock.json'].mtime,
                             by_path[base + 'node_modules/.package-lock.json'].mtime)
        icons = [e for e in entries if '@mui' in e.path.parts and e.path.name.endswith('.d.ts')]
        self.assertGreater(len(icons), 1000)
        self.assertTrue(all(100 <= e.size <= 700 for e in icons))
        self.assertGreater(by_path['Projects/field-journal/node_modules/lodash/lodash.js'].size, 300000)
        paths = set(by_path)
        base = 'Projects/field-journal/node_modules/'
        for path in ['lodash/flatten.js', 'react/cjs/react.development.js',
                     'typescript/lib/lib.es2020.d.ts', 'typescript/lib/tsc.js',
                     'esbuild/bin/esbuild', 'semver/classes/range.js',
                     'semver/functions/compare.js', 'semver/ranges/intersects.js',
                     'vite/node_modules/semver/package.json']:
            self.assertIn(base + path, paths)

    def test_dates_and_sizes(self):
        entries = demo.plan()
        outside = [e for e in entries if 'node_modules' not in e.path.parts and e.path.parts[:2] != ('Projects', 'tesserae')]
        self.assertGreater(len(outside), 4000)
        self.assertGreater(len({e.mtime for e in outside}) / len(outside), .98)
        self.assertEqual(demo.NOW, int(dt.datetime(2026, 10, 21, 12, tzinfo=dt.timezone.utc).timestamp()))
        self.assertLessEqual(max(e.mtime for e in outside), demo.NOW)
        self.assertTrue(all(e.size % demo.MIB and e.size & (e.size - 1) for e in entries if e.path.suffix not in ('.dmg', '.iso') and e.path.parts[:2] != ('Projects', 'tesserae')))
        screens = [e for e in outside if e.path.name.startswith('Screenshot ')]
        self.assertGreater(len(screens), 10)
        for e in screens:
            date = dt.datetime.strptime(e.path.stem, 'Screenshot %Y-%m-%d at %H.%M.%S').replace(tzinfo=dt.timezone.utc)
            self.assertEqual(int(date.timestamp()), e.mtime)
        for folder in {e.path.parent for e in outside if e.path.suffix == '.HEIC'}:
            shots = sorted((e for e in outside if e.path.parent == folder and e.path.suffix == '.HEIC'), key=lambda e: e.mtime)
            numbers = [int(e.path.stem[4:]) for e in shots]
            self.assertEqual(numbers, sorted(numbers))
            intervals = [b.mtime - a.mtime for a, b in zip(shots, shots[1:])]
            self.assertGreater(len(intervals), 30)
            self.assertLessEqual(min(intervals), 7)
            self.assertGreater(max(intervals), 600)
            self.assertLess(shots[-1].mtime - shots[0].mtime, 86400)
        objects = [e for e in outside if '.git/objects/' in str(e.path)]
        self.assertGreater(len(objects), 1000)
        self.assertGreater(max(e.mtime for e in objects) - min(e.mtime for e in objects), 365 * 86400)

    def test_minimum_budget(self):
        with self.assertRaisesRegex(ValueError, r'at least (\d+)') as error:
            demo.plan(0)
        minimum = int(re.search(r'at least (\d+)', str(error.exception)).group(1))
        self.assertGreater(minimum, 1000000)
        for total in (minimum, minimum + 1, minimum + 1000):
            entries = demo.plan(total)
            self.assertTrue(entries)
            self.assertEqual(sum(e.size for e in entries), total)
            self.assertTrue(all(e.size >= (len(e.text) if e.path.parts[:2] == ('Projects', 'tesserae') else max(1, len(e.text))) for e in entries))
            self.assertTrue(all(e.size % demo.MIB and e.size & (e.size - 1) for e in entries if e.path.suffix not in ('.dmg', '.iso') and e.path.parts[:2] != ('Projects', 'tesserae')))

    def test_provenance_removed_from_written_and_skipped_files(self):
        libc = ctypes.CDLL(None, use_errno=True)
        libc.setxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                                 ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        libc.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p,
                                 ctypes.c_size_t, ctypes.c_uint32, ctypes.c_int]
        attribute = b'com.apple.provenance'
        entry = demo.Entry(demo.PurePosixPath('note.txt'), 19, demo.NOW, b'hello')
        with tempfile.TemporaryDirectory() as directory, contextlib.ExitStack() as cleanup, contextlib.redirect_stderr(io.StringIO()):
            fixture = pathlib.Path(directory)
            image = fixture / 'demo.dmg'
            mount = fixture / 'mount'
            mount.mkdir()
            subprocess.run(['hdiutil', 'create', '-size', '32m', '-fs', 'ExFAT',
                            '-volname', 'TESSTEST', str(image)], check=True, capture_output=True)
            subprocess.run(['hdiutil', 'attach', '-nobrowse', '-mountpoint', str(mount),
                            str(image)], check=True, capture_output=True)
            cleanup.callback(subprocess.run, ['hdiutil', 'detach', str(mount)],
                             check=True, capture_output=True)
            root = mount / 'fixture'
            root.mkdir()
            path = os.fsencode(root / 'note.txt')
            demo.write_tree(root, [entry])
            self.assertEqual((root / 'note.txt').stat().st_size, 19)
            self.assertEqual(libc.getxattr(path, attribute, None, 0, 0, 0), -1)
            self.assertEqual(ctypes.get_errno(), errno.ENOATTR)
            # Stamp an existing matching file: the skipped branch must clean it too.
            self.assertEqual(libc.setxattr(path, attribute, b'test', 4, 0, 0), 0)
            self.assertGreater(libc.getxattr(path, attribute, None, 0, 0, 0), 0, 'precondition: provenance exists')
            demo.write_tree(root, [entry])
            self.assertEqual(libc.getxattr(path, attribute, None, 0, 0, 0), -1)
            self.assertEqual(ctypes.get_errno(), errno.ENOATTR)
            self.assertEqual(list(root.iterdir()), [root / 'note.txt'])
            other = b'com.tesserae.test'
            self.assertEqual(libc.setxattr(path, other, b'keep', 4, 0, 0), 0)
            self.assertEqual(libc.getxattr(path, other, None, 0, 0, 0), 4, 'precondition')
            demo.write_tree(root, [entry])
            self.assertEqual(libc.getxattr(path, other, None, 0, 0, 0), 4, 'preserve other metadata')
            self.assertEqual((root / 'note.txt').read_bytes(), b'hello' + b' ' * 14)

    def test_provenance_cleanup_ignores_only_missing_or_unsupported_attributes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'note').write_bytes(b'hello')
            parent = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            fd = os.open(root / 'note', os.O_RDONLY)
            try:
                for error in (errno.ENOATTR, errno.ENOTSUP):
                    with mock.patch.object(demo.os, 'removexattr', create=True,
                                           side_effect=OSError(error, 'test')) as remove:
                        demo.remove_provenance(fd, parent, 'note')
                        remove.assert_called_once_with(fd, 'com.apple.provenance')
                with mock.patch.object(demo.os, 'removexattr', create=True,
                                       side_effect=OSError(errno.EIO, 'test')):
                    with self.assertRaises(OSError) as raised:
                        demo.remove_provenance(fd, parent, 'note')
                    self.assertEqual(raised.exception.errno, errno.EIO)
            finally:
                os.close(fd)
                os.close(parent)

    def test_provenance_cleanup_preserves_unrelated_dot_underscore_file(self):
        libc = ctypes.CDLL(None, use_errno=True)
        with tempfile.TemporaryDirectory() as directory:
            root = pathlib.Path(directory)
            (root / 'note').write_bytes(b'hello')
            sidecar = root / '._note'
            sidecar.write_bytes(b'unrelated user file')
            parent = os.open(root, os.O_RDONLY | os.O_DIRECTORY)
            fd = os.open(root / 'note', os.O_RDONLY)
            try:
                self.assertEqual(libc.fsetxattr(fd, b'com.apple.provenance', b'test', 4, 0, 0), 0)
                self.assertGreater(libc.fgetxattr(fd, b'com.apple.provenance', None, 0, 0, 0), 0,
                                   'precondition: cleanup sees provenance')
                demo.remove_provenance(fd, parent, 'note')
                self.assertTrue(sidecar.exists(), 'unrelated dot-underscore file must survive')
                self.assertEqual(sidecar.read_bytes(), b'unrelated user file')
            finally:
                os.close(fd)
                os.close(parent)

    def test_progress(self):
        entries = [demo.Entry(demo.PurePosixPath(f'note-{i}.txt'), 19, demo.NOW - i, b'hello') for i in range(40)]
        with tempfile.TemporaryDirectory() as directory, contextlib.redirect_stderr(io.StringIO()) as progress:
            demo.write_tree(pathlib.Path(directory), entries)
            self.assertEqual(len(list(pathlib.Path(directory).iterdir())), 40)
        self.assertEqual([int(p) for p in re.findall(r'(\d+)%', progress.getvalue())], list(range(5, 101, 5)))

    def test_refusals(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory)
            info = {'VolumeUUID': UUID, 'MountPoint': str(target), 'APFSVolumeRole': []}
            with mock.patch.object(demo.os.path, 'ismount', return_value=True), mock.patch.object(
                    demo.subprocess, 'check_output', return_value=plistlib.dumps(info)):
                with self.assertRaisesRegex(ValueError, 'UUID does not match'):
                    demo.validate_target(target, 'FFFFFFFF-FFFF-FFFF-FFFF-FFFFFFFFFFFF', 1)
                for bad in (pathlib.Path('/'), pathlib.Path('/System/Volumes/Data'), pathlib.Path.home(), pathlib.Path.home() / 'demo'):
                    with self.assertRaisesRegex(ValueError, 'system or home'):
                        demo.validate_target(bad, UUID, 1)
                info['APFSVolumeRole'] = ['Data']
                with mock.patch.object(demo.subprocess, 'check_output', return_value=plistlib.dumps(info)):
                    with self.assertRaisesRegex(ValueError, 'APFS boot/Data'):
                        demo.validate_target(target, UUID, 1)
                with mock.patch.object(demo.shutil, 'disk_usage', return_value=mock.Mock(free=0)):
                    with self.assertRaisesRegex(ValueError, 'insufficient free space'):
                        demo.validate_target(target, UUID, 1)
            with mock.patch.object(demo.subprocess, 'check_output', side_effect=AssertionError('diskutil called for non-mount')) as diskutil:
                with self.assertRaisesRegex(ValueError, 'mount point'):
                    demo.validate_target(target, UUID, 1)
                diskutil.assert_not_called()

    def test_write_and_conflicts(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory)
            entries = demo.plan(SMALL_BYTES)
            self.assertGreater(len(entries), 1000)
            info = plistlib.dumps({'VolumeUUID': UUID, 'MountPoint': str(target)})
            # Only test mocks can override mount/UUID discovery; no production bypass.
            with mock.patch.object(demo.os.path, 'ismount', return_value=True), mock.patch.object(
                    demo.subprocess, 'check_output', return_value=info):
                demo.validate_target(target, UUID, sum(e.size for e in entries))
                self.assertEqual(demo.pending_bytes(target, entries), sum(e.size for e in entries))
                progress = io.StringIO()
                with contextlib.redirect_stderr(progress):
                    demo.write_tree(target, entries)
                percentages = re.findall(r'(\d+)%', progress.getvalue())
                self.assertEqual([int(p) for p in percentages], list(range(5, 101, 5)))
            self.assertEqual(demo.pending_bytes(target, entries), 0)
            for e in entries:
                self.assertEqual((target / e.path).stat().st_size, e.size)
                self.assertEqual(int((target / e.path).stat().st_mtime), e.mtime)
            sample = next(e for e in entries if e.path.name == 'package.json')
            self.assertIn(b'"name"', (target / sample.path).read_bytes())
            # Cleanup may change metadata, but a matching file must never be rewritten.
            with mock.patch.object(demo.os, 'fdopen', side_effect=AssertionError('matching files must be skipped')):
                demo.write_tree(target, entries)
            self.assertEqual((target / sample.path).stat().st_mtime_ns, sample.mtime * 10**9)
            event = pathlib.Path('Photos/2018-02 Cabin weekend')
            expected = max(e.mtime for e in entries if str(e.path).startswith(str(event) + '/'))
            self.assertEqual(int((target / event).stat().st_mtime), expected)
            (target / sample.path).write_text('keep this')
            with self.assertRaises(ValueError):
                demo.write_tree(target, entries)
            self.assertEqual((target / sample.path).read_text(), 'keep this')
            with self.assertRaises(ValueError):
                demo.pending_bytes(target, entries)

    def test_symlinks_and_subdirs(self):
        with tempfile.TemporaryDirectory() as directory:
            target = pathlib.Path(directory)
            (target / 'Documents').symlink_to(target, target_is_directory=True)
            entries = demo.plan(SMALL_BYTES)
            with self.assertRaises((ValueError, OSError)):
                demo.write_tree(target, entries)
            for name in ('../escape', '/absolute', '.', 'a/b'):
                with self.assertRaises(ValueError):
                    demo.root_subdir(name)
            self.assertEqual(demo.root_subdir('Demo Disk'), 'Demo Disk')


if __name__ == '__main__':
    unittest.main()
