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

import contextlib
import csv
import datetime as dt
import importlib.util
import io
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

sys.dont_write_bytecode = True
ROOT = Path(__file__).resolve().parents[2]
# Leave room for the current source-tree snapshot while retaining a small fixture.
SMALL_BYTES = 32 * 1024**2


def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


snapshot = load('snapshot', ROOT / 'scripts/demo/snapshot-tesserae-tree.py')
demo = load('demo', ROOT / 'scripts/make-demo-volume.py')


class SnapshotTests(unittest.TestCase):
    def test_committed_snapshot(self):
        rows = demo.tesserae_entries()
        self.assertGreater(len(rows), 200)
        paths = {str(e.path.relative_to('Projects/tesserae')) for e in rows}
        # The generator reads HEAD; pending renames in the index are not its input.
        tracked = set(subprocess.check_output(
            ['git', 'ls-tree', '-rz', '--name-only', 'HEAD'], cwd=ROOT).decode().split('\0')[:-1])
        self.assertLessEqual(paths, tracked)
        self.assertFalse(any(p.startswith('scripts/demo/') for p in paths))
        self.assertNotIn(str(Path.home()), demo.TESSERAE_SNAPSHOT.read_text())

    def test_head_metadata_only(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'apple/build') as directory:
            repo = Path(directory)
            def git(*args, **kwargs):
                return subprocess.check_output(['git', '-C', str(repo), *args], **kwargs)
            git('init', '-q')
            git('config', 'user.name', 'Demo Test')
            git('config', 'user.email', 'demo@example.invalid')
            for name, data in [('source file.rs', 'original source'), ('empty', ''),
                               ('.gitignore', 'ignored\n'), ('ignored', 'private'),
                               ('scripts/demo/hidden', 'excluded'),
                               ('docs/superpowers/plans/history.md', 'historical planning')]:
                path = repo / name
                path.parent.mkdir(parents=True, exist_ok=True)
                path.write_text(data)
            git('add', '.')
            git('commit', '-qm', 'fixture')
            expected_time = git('log', '-1', '--format=%cI', '--', 'source file.rs').decode().strip()
            (repo / 'later.swift').write_text('second commit')
            git('add', 'later.swift')
            git('commit', '-qm', 'later', env={'PATH': '/usr/bin:/bin', 'GIT_COMMITTER_DATE': '2025-01-01T00:00:00Z'})
            later_time = git('log', '-1', '--format=%cI', '--', 'later.swift').decode().strip()
            self.assertNotEqual(later_time, expected_time)
            (repo / 'source file.rs').write_text('dirty contents are longer')
            (repo / 'staged').write_text('not committed')
            git('add', 'staged', 'source file.rs')
            git('rm', '--cached', '-q', 'empty')
            rows = snapshot.collect(repo)
            self.assertEqual({r[0] for r in rows}, {'.gitignore', 'empty', 'source file.rs', 'later.swift'})
            self.assertIn(('source file.rs', len('original source'), expected_time), rows)
            self.assertIn(('empty', 0, expected_time), rows)
            self.assertIn(('later.swift', len('second commit'), later_time), rows)
            output = repo / 'snapshot.tsv'
            snapshot.write_snapshot(output, rows)
            self.assertNotIn('original source', output.read_text())
            with output.open() as stream:
                self.assertEqual(next(csv.reader(stream, delimiter='\t')), ['path', 'bytes', 'mtime'])

    def test_home_refusal_before_write(self):
        with tempfile.TemporaryDirectory(dir=ROOT / 'apple/build') as directory:
            output = Path(directory) / 'snapshot.tsv'
            output.write_text('preserve')
            for rows in [[('prefix' + str(Path.home()) + '/file', 1, 'date')],
                         [('safe', 1, str(Path.home()))]]:
                with self.assertRaisesRegex(ValueError, 'home'):
                    snapshot.write_snapshot(output, rows)
                self.assertEqual(output.read_text(), 'preserve')

    def test_tree_exact_and_synthetic(self):
        rows = demo.tesserae_entries()
        self.assertGreater(len(rows), 200)
        expected = {e.path: e for e in rows}
        with demo.TESSERAE_SNAPSHOT.open() as stream:
            recorded = {demo.PurePosixPath('Projects/tesserae') / r['path']:
                        (int(r['bytes']), int(dt.datetime.fromisoformat(r['mtime']).timestamp()))
                        for r in csv.DictReader(stream, delimiter='\t')}
        self.assertEqual({e.path: (e.size, e.mtime) for e in rows}, recorded)
        for total in (SMALL_BYTES, demo.DEFAULT_BYTES):
            planned = {e.path: e for e in demo.plan(total)}
            self.assertEqual(sum(e.size for e in planned.values()), total)
            self.assertTrue(all(planned[p] == e for p, e in expected.items()))
        with tempfile.TemporaryDirectory(dir=ROOT / 'apple/build') as directory:
            root = Path(directory)
            with contextlib.redirect_stderr(io.StringIO()):
                demo.write_tree(root, rows)
            for e in rows:
                actual = root / e.path
                self.assertEqual(actual.stat().st_size, e.size)
                self.assertEqual(actual.stat().st_mtime_ns, e.mtime * 10**9)
            sample = root / 'Projects/tesserae/scripts/make-demo-volume.py'
            self.assertGreater(sample.stat().st_size, 100)
            self.assertNotEqual(sample.read_bytes(), (ROOT / 'scripts/make-demo-volume.py').read_bytes())
            self.assertIn(b'synthetic', sample.read_bytes())
            binary = next(e for e in rows if e.path.suffix == '.png')
            self.assertGreater(binary.size, 0)
            self.assertEqual((root / binary.path).read_bytes(), bytes(binary.size))

    def test_git_layout_and_dates(self):
        rows = demo.tesserae_entries()
        entries = [e for e in demo.plan() if str(e.path).startswith('Projects/tesserae/.git/')]
        self.assertGreater(len(entries), 5)
        self.assertTrue(2 * demo.MIB <= sum(e.size for e in entries) <= 30 * demo.MIB)
        paths = {str(e.path) for e in entries}
        self.assertIn('Projects/tesserae/.git/refs/heads/main', paths)
        self.assertTrue(any(p.endswith('.pack') for p in paths))
        self.assertTrue(any(p.endswith('.idx') for p in paths))
        self.assertTrue({e.mtime for e in entries} <= {e.mtime for e in rows})


if __name__ == '__main__':
    unittest.main()
