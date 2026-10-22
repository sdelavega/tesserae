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

"""Snapshot HEAD names, blob sizes and last commit dates, never blob contents.

Run with python3 -I, or just demo-tesserae-snapshot. The working tree and
staging area do not supply file sizes or dates. scripts/demo/ and historical
docs/superpowers/ plans and specs are excluded.
"""

import csv
import io
from pathlib import Path
import subprocess

ROOT = Path(__file__).resolve().parents[2]
OUTPUT = ROOT / 'scripts/demo/tesserae-tree.tsv'


def collect(repo=ROOT):
    def git(*args, input=None):
        return subprocess.check_output(['git', '-C', str(repo), *args], input=input)

    # --with-tree restores staged deletions; intersecting HEAD removes additions.
    head = set(git('ls-tree', '-r', '--name-only', '-z', 'HEAD').decode().split('\0')[:-1])
    tracked = set(git('ls-files', '-z', '--with-tree=HEAD').decode().split('\0')[:-1])
    paths = sorted(p for p in head & tracked
                   if not p.startswith(('scripts/demo/', 'docs/superpowers/')))
    if any(any(c in p for c in '\n\r\t') for p in paths):
        raise ValueError('unsupported control character in snapshot path')
    # --batch-check is cat-file -s for every HEAD:path in one process; it does
    # not retrieve blobs. One history walk supplies log -1 dates for all paths.
    sizes = git('cat-file', '--batch-check=%(objectsize)',
                input=''.join('HEAD:' + p + '\n' for p in paths).encode()).decode().splitlines()
    dates = {}
    tokens = iter(git('log', 'HEAD', '--format=%x00%cI', '-z', '--name-only', '--no-renames').decode().split('\0'))
    date = None
    first = False
    for token in tokens:
        if not token:
            date = next(tokens, '')
            first = True
        else:
            path = token.removeprefix('\n') if first else token
            first = False
            dates.setdefault(path, date)
    return [(p, int(size), dates[p]) for p, size in zip(paths, sizes)]


def write_snapshot(output, rows):
    buffer = io.StringIO(newline='')
    writer = csv.writer(buffer, delimiter='\t', lineterminator='\n')
    writer.writerow(['path', 'bytes', 'mtime'])
    for row in rows:
        if any(str(Path.home()) in str(value) for value in row):
            raise ValueError('refusing home directory string in snapshot')
        writer.writerow(row)
    output.write_text(buffer.getvalue(), encoding='utf-8')


if __name__ == '__main__':
    write_snapshot(OUTPUT, collect())
