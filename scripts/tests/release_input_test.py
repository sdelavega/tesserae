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
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program.  If not, see <https://www.gnu.org/licenses/>.


import hashlib
import io
import os
import shlex
import zipfile
import json
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseInputTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(dir=ROOT / "apple/build")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        (self.root / "scripts").mkdir()
        script = ROOT / "scripts/verify-release-input.py"
        if script.is_file():
            shutil.copy(script, self.root / "scripts/verify-release-input.py")
        self.input = self.root / "input"
        self.app = self.input / "Tesserae.app/Contents"
        self.app.mkdir(parents=True)
        self.tools = self.input / "sparkle-tools"
        self.tools.mkdir()
        self.info = dict(CFBundleShortVersionString="0.1.0", CFBundleVersion="100",
                         SUPublicEDKey="inert-public-key", SUVerifyUpdateBeforeExtraction=True,
                         SURequireSignedFeed=True)
        (self.app / "Info.plist").write_bytes(plistlib.dumps(self.info))
        source = self.root / "apple/Tesserae"
        source.mkdir(parents=True)
        (source / "Info.plist").write_bytes(plistlib.dumps(self.info))
        self.proof = self.input / "build.json"
        self.proof.write_text(json.dumps(dict(version="0.1.0", commit="fixture-commit")))
        pins = []
        for name in ("generate_appcast", "sign_update"):
            data = ("inert tool " + name).encode()
            (self.tools / name).write_bytes(data)
            pins.append(hashlib.sha256(data).hexdigest() + "  " + name)
        (self.root / "scripts/sparkle-tools.sha256").write_text("\n".join(pins) + "\n")

    def verify(self, success):
        result = subprocess.run(["python3", "-I", str(self.root / "scripts/verify-release-input.py"),
                                 str(self.input), "0.1.0", "fixture-commit"], capture_output=True, text=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)

    def test_download_checks_digest_and_refuses_archive_escape(self):
        shutil.copy(ROOT / "scripts/release-tools.sh", self.root / "scripts/release-tools.sh")
        fake = self.root / "curl"
        fake.write_text("""#!/usr/bin/env python3
import os, pathlib, shutil, sys
assert 'GH_TOKEN' not in os.environ
assert sys.stdin.read() == 'header = "Authorization: Bearer fixture-artifact-token"\\n'
root = pathlib.Path(__file__).parent
shutil.copyfile(root / 'download.zip', sys.argv[sys.argv.index('--output') + 1])
""")
        fake.chmod(0o755)
        script = (ROOT / "scripts/download-release-input.sh").read_text()
        self.assertEqual(script.count("tool /usr/bin/curl"), 1, "precondition: replace only network transport")
        script = script.replace("tool /usr/bin/curl", "tool " + shlex.quote(str(fake)))
        target = self.root / "scripts/download-release-input.sh"
        target.write_text(script)
        temporary = self.root / "temporary"
        temporary.mkdir()
        environment = dict(PATH=os.environ["PATH"], HOME=str(self.root), TMPDIR=str(temporary),
                           RUNNER_TEMP=str(temporary), GH_TOKEN="fixture-artifact-token")
        def archive(name):
            inner = io.BytesIO()
            with zipfile.ZipFile(inner, "w") as zipped:
                zipped.writestr(name, "fixture")
            outer = self.root / "download.zip"
            with zipfile.ZipFile(outer, "w") as zipped:
                zipped.writestr("release-input.zip", inner.getvalue())
            return hashlib.sha256(outer.read_bytes()).hexdigest()
        def run(digest, success):
            result = subprocess.run(["bash", str(target), "123", digest], cwd=self.root,
                                    env=environment, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        digest = archive("release-input/build.json")
        run(digest, True)
        self.assertEqual((self.root / "apple/build/release-input/build.json").read_text(), "fixture")
        run("0" * 64, False)
        run(archive("../escape"), False)
        self.assertFalse((self.root / "escape").exists())

    def test_release_input_is_bound_to_version_and_source_commit(self):
        self.verify(True)
        for key in ("version", "commit"):
            proof = dict(version="0.1.0", commit="fixture-commit")
            proof[key] = "wrong"
            self.proof.write_text(json.dumps(proof))
            self.verify(False)

    def test_release_input_requires_matching_app_and_update_policy(self):
        self.verify(True)
        for key in self.info:
            changed = dict(self.info)
            changed[key] = False if isinstance(changed[key], bool) else "wrong"
            (self.app / "Info.plist").write_bytes(plistlib.dumps(changed))
            self.verify(False)

    def test_release_input_requires_the_pinned_sparkle_tools(self):
        self.verify(True)
        path = self.tools / "sign_update"
        original = path.read_bytes()
        self.assertGreater(len(original), 0, "precondition: tool is present")
        path.write_bytes(b"hostile replacement")
        self.verify(False)
        path.write_bytes(original)
        path.rename(self.tools / "saved")
        path.symlink_to("saved")
        self.verify(False)


if __name__ == "__main__":
    unittest.main()
