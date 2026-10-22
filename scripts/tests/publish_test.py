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


import base64
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = Path(__file__).resolve().parents[2]
NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
URL = "https://github.com/sdelavega/tesserae/releases/download/v0.1.0/Tesserae-0.1.0.dmg"


def signed_feed(data):
    # An inert digest stands in for EdDSA in the fake tools; production delegates
    # cryptographic verification to the resolved Sparkle sign_update executable.
    data = data.split(b"<!-- sparkle-signatures:")[0]
    signature = base64.b64encode(hashlib.sha512(data).digest())
    return data + b"<!-- sparkle-signatures:\nedSignature: " + signature + b"\nlength: " + str(len(data)).encode() + b"\n-->\n"


class PublishingTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="tesserae-publish-")
        self.addCleanup(self.temp.cleanup)
        self.base = Path(self.temp.name).resolve()
        self.repo = self.base / "repo space"
        self.repo.mkdir()
        shutil.copytree(ROOT / "scripts", self.repo / "scripts")
        shutil.copytree(ROOT / "packaging", self.repo / "packaging") if (ROOT / "packaging").exists() else None
        (self.repo / "dist").mkdir()
        (self.repo / "docs/releases").mkdir(parents=True)
        (self.repo / "docs/releases/0.1.0.md").write_text("# Release notes & fixes\nUse `<path>` and [help](https://example.invalid/help).\n")
        (self.repo / "apple/Tesserae").mkdir(parents=True)
        self.public = bytes(range(32))
        (self.repo / "apple/Tesserae/Info.plist").write_bytes(plistlib.dumps({"SUPublicEDKey": base64.b64encode(self.public).decode()}))
        self.dmg = self.repo / "dist/Tesserae-0.1.0.dmg"
        self.dmg.write_bytes(b"verified fake dmg")
        self.sha = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
        (self.repo / "dist/SHA256SUMS").write_text(self.sha + "  Tesserae-0.1.0.dmg\n")
        self.bin = self.base / "bin"
        self.bin.mkdir()
        self.calls = self.base / "calls"
        self.env = {k: v for k, v in os.environ.items() if not any(s in k for s in ("TOKEN", "KEY", "SECRET", "PASSWORD"))}
        self.env.update(PATH=str(self.bin) + ":" + os.environ["PATH"], HOME=str(self.base), CALLS=str(self.calls), TEST_BASE=str(self.base), REAL_GIT=shutil.which("git"), GIT_CONFIG_NOSYSTEM="1", GIT_AUTHOR_NAME="Test", GIT_AUTHOR_EMAIL="test@example.invalid", GIT_COMMITTER_NAME="Test", GIT_COMMITTER_EMAIL="test@example.invalid", GH_TOKEN="planted-gh-auth", GITHUB_TOKEN="planted-github-auth", OTHER_TOKEN="planted-token", OTHER_API_KEY="planted-api", OTHER_SECRET_VALUE="planted-secret", OTHER_PASSWORD_VALUE="planted-password")
        fake = self.bin / "fake"
        fake.write_text(FAKE.replace("__REAL_GIT__", self.env["REAL_GIT"]))
        fake.chmod(0o755)
        for name in ("git", "gh", "curl", "brew", "generate_appcast", "sign_update", "cp", "xcrun", "spctl", "sleep"):
            (self.bin / name).symlink_to(fake)
        tools = self.repo / "apple/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/bin"
        tools.mkdir(parents=True)
        for name in ("generate_appcast", "sign_update", "cp"):
            (tools / name).symlink_to(fake)
        self.git("init", "-b", "main")
        self.git("config", "user.name", "Test")
        self.git("config", "user.email", "test@example.invalid")
        self.git("add", ".")
        self.git("commit", "-m", "fixture")
        self.origin = self.base / "origin.git"
        self.git("init", "--bare", str(self.origin))
        self.git("remote", "add", "origin", str(self.origin))
        self.git("push", "-u", "origin", "main")
        self.tap = self.base / "tap space"
        self.tap.mkdir()
        self.git("init", "-b", "main", cwd=self.tap)
        self.git("config", "user.name", "Test", cwd=self.tap)
        self.git("config", "user.email", "test@example.invalid", cwd=self.tap)
        (self.tap / "README").write_text("tap\n")
        self.git("add", ".", cwd=self.tap)
        self.git("commit", "-m", "tap", cwd=self.tap)
        tap_remote = self.base / "tap.git"
        self.git("init", "--bare", str(tap_remote))
        self.git("remote", "add", "origin", str(tap_remote), cwd=self.tap)
        self.git("push", "-u", "origin", "main", cwd=self.tap)
        self.env["TESSERAE_TAP_DIR"] = str(self.tap)
        self.write_feed()
        self.manifest = self.repo / "dist/MANIFEST"
        self.proof = dict(version="0.1.0", commit=self.git("rev-parse", "HEAD"),
                          dmg_sha256=self.sha, verified_at="2026-10-21T12:00:00Z")
        self.manifest.write_text(json.dumps(self.proof))

    def git(self, *args, cwd=None):
        return subprocess.check_output([self.env["REAL_GIT"], *args], cwd=cwd or self.repo, env=self.env, stderr=subprocess.DEVNULL, text=True).strip()

    def write_feed(self, change=None):
        rss = ET.Element("rss")
        item = ET.SubElement(ET.SubElement(rss, "channel"), "item")
        ET.SubElement(item, "{" + NS + "}version").text = "100"
        ET.SubElement(item, "{" + NS + "}shortVersionString").text = "0.1.0"
        ET.SubElement(item, "{" + NS + "}minimumSystemVersion").text = "13.0"
        ET.SubElement(item, "description").text = "# Release notes & fixes\nUse `<path>` and [help](https://example.invalid/help).\n"
        enclosure = ET.SubElement(item, "enclosure", {"url": URL, "length": str(self.dmg.stat().st_size), "{" + NS + "}edSignature": "fake-signature"})
        if change:
            change(item, enclosure)
        ET.ElementTree(rss).write(self.repo / "dist/appcast.xml", encoding="utf-8", xml_declaration=True)
        path = self.repo / "dist/appcast.xml"
        path.write_bytes(signed_feed(path.read_bytes()))

    def run_script(self, script, *args, input="", success=True, standalone=False):
        command = ["bash", str(self.repo / "scripts" / script), "0.1.0", *args]
        if script == "publish.sh" and not args and not standalone:
            command = ["bash", "-c", 'source scripts/publish.sh; publish "0.1.0"']
        (self.base / "fault").write_text(self.env.get("FAULT", ""))
        result = subprocess.run(command, cwd=self.repo, env=self.env, input=input, text=True, capture_output=True)
        self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        return result.stdout + result.stderr

    def trace(self):
        return self.calls.read_text() if self.calls.exists() else ""

    def assert_no_publish(self):
        calls = self.trace()
        self.assertNotIn("git tag ", calls)
        self.assertNotIn("git push ", calls)
        self.assertNotIn("gh ", calls)
        self.assertEqual(self.git("tag", "--list"), "v0.1.0")
        self.assertEqual(self.git("--git-dir", str(self.origin), "for-each-ref", "--format=%(refname)", "refs/heads/gh-pages"), "")

    def test_no_mode_runs_no_tools(self):
        self.run_script("publish.sh", input="0.1.0\n", success=False, standalone=True)
        self.assertEqual(self.trace(), "")
        self.assertEqual(self.git("tag", "--list"), "")

    def test_all_publish_paths_require_verified_same_commit_artifacts(self):
        self.git("tag", "v0.1.0")
        self.git("push", "origin", "refs/tags/v0.1.0")
        self.env["CI"] = "true"
        for mode in ((), ("--resume",), ("--ci-publish",)):
            for fault in ("missing", "version", "commit", "tampered", "validate", "assess", "tag"):
                with self.subTest(mode=mode, fault=fault):
                    self.manifest.write_text(json.dumps(self.proof))
                    self.dmg.write_bytes(b"verified fake dmg")
                    (self.repo / "dist/SHA256SUMS").write_text(self.sha + "  Tesserae-0.1.0.dmg\n")
                    self.env["FAULT"] = fault
                    if fault == "missing":
                        self.manifest.unlink()
                    elif fault in ("version", "commit"):
                        self.manifest.write_text(json.dumps(dict(self.proof, **{fault: "other"})))
                    elif fault == "tampered":
                        self.dmg.write_bytes(b"tampered fake dmg")
                        # Keep the independent metadata consistent: only MANIFEST
                        # can detect replacement of the previously verified bytes.
                        digest = hashlib.sha256(self.dmg.read_bytes()).hexdigest()
                        (self.repo / "dist/SHA256SUMS").write_text(digest + "  Tesserae-0.1.0.dmg\n")
                    elif fault == "tag":
                        self.git("tag", "-f", "v0.1.0", self.git("commit-tree", "HEAD^{tree}", "-m", "other commit"))
                    self.calls.write_text("")
                    out = self.run_script("publish.sh", *mode, input="0.1.0\n", success=False)
                    if fault in ("missing", "version", "commit", "tampered", "tag"):
                        self.assertIn("MANIFEST", out)
                    self.assert_no_publish()
                    if fault == "validate":
                        self.assertIn("xcrun stapler validate", self.trace())
                    if fault == "assess":
                        self.assertIn("spctl --assess --type open --context context:primary-signature", self.trace())
                    self.git("tag", "-f", "v0.1.0", "HEAD")

    def test_unsigned_or_tampered_feed_refuses_verification_and_publishing(self):
        path = self.repo / "dist/appcast.xml"
        original = path.read_bytes()
        self.assertIn(b"<rss", original, "precondition: valid feed with a valid enclosure")
        self.assertIn(b"<!-- sparkle-signatures:", original, "precondition: initially signed")
        tampered = original.replace(b"<rss", b"<rss tampered=\"yes\"", 1)
        tampered = re.sub(rb"length: [0-9]+", b"length: " + str(len(tampered.split(b"<!-- sparkle-signatures:")[0])).encode(), tampered)
        for content in (original.split(b"<!-- sparkle-signatures:")[0], tampered):
            with self.subTest(content=content[:20]):
                path.write_bytes(content)
                self.calls.write_text("")
                self.run_script("appcast-check.sh", success=False)
                self.run_script("publish.sh", input="0.1.0\n", success=False)
                self.assertNotIn("gh ", self.trace())
                self.assertNotIn("git tag", self.trace())
                self.assertNotIn("git push", self.trace())

    def test_appcast_entry_matches_dmg_and_public_key(self):
        self.run_script("appcast-check.sh")
        self.assertIn("sign_update --verify", self.trace())
        self.assertIn("PUBLIC_KEY_OK", self.trace())
        for field in ("version", "shortVersionString", "minimumSystemVersion", "url", "length", "signature", "notes"):
            def change(item, enc):
                if field in ("url", "length"):
                    enc.set(field, "wrong")
                elif field == "signature":
                    enc.set("{" + NS + "}edSignature", "bad-signature")
                elif field == "notes":
                    item.find("description").text = "wrong notes"
                else:
                    item.find("{" + NS + "}" + field).text = "101" if field == "version" else "wrong"
            self.write_feed(change)
            self.run_script("appcast-check.sh", success=False)
        self.write_feed()
        plist = self.repo / "apple/Tesserae/Info.plist"
        original = plist.read_bytes()
        plist.write_bytes(plistlib.dumps({"SUPublicEDKey": base64.b64encode(bytes(32)).decode()}))
        self.run_script("appcast-check.sh", success=False)
        plist.write_bytes(original)
        (self.repo / "docs/releases/0.1.0.md").unlink()
        self.run_script("appcast-check.sh", success=False)

    def publish_feed(self, data):
        def git_input(args, content):
            return subprocess.check_output([self.env["REAL_GIT"], *args], cwd=self.repo,
                                           env=self.env, input=content).strip().decode()
        blob = git_input(["hash-object", "-w", "--stdin"], data)
        tree = git_input(["mktree"], f"100644 blob {blob}\tappcast.xml\n".encode())
        commit = self.git("commit-tree", tree, "-m", "published feed")
        self.git("push", "origin", commit + ":refs/heads/gh-pages")
        return commit

    def test_whole_feed_refuses_extra_duplicate_delta_and_changed_history(self):
        path = self.repo / "dist/appcast.xml"
        new = path.read_bytes()
        old_item = b'<item><version xmlns="http://www.andymatuschak.org/xml-namespaces/sparkle">99</version><title>Historical &amp; exact</title><enclosure url="https://example.invalid/old.dmg" /></item>'
        old = b'<rss><channel><title>Feed</title>' + old_item + b'</channel></rss>'
        self.publish_feed(old)
        # The new item is serialized independently so historical bytes stay exact.
        new_item = ET.tostring(ET.parse(path).find("./channel/item"))
        candidate = old.replace(b'</channel>', new_item + b'</channel>')
        path.write_bytes(signed_feed(candidate))
        self.run_script("appcast-check.sh")
        for fault in ("extra", "duplicate", "delta", "rebound-delta", "alternate-delta", "namespaced-enclosure", "rebound-version", "altered", "bytes", "removed", "metadata"):
            with self.subTest(fault=fault):
                raw = candidate
                if fault in ("extra", "duplicate"):
                    raw = raw.replace(b'</channel>', (old_item if fault == "extra" else new_item) + b'</channel>')
                elif fault == "delta":
                    raw = raw.replace(b'</item></channel>', b'<sparkle:deltas xmlns:sparkle="' + NS.encode() + b'" /></item></channel>')
                elif fault in ("rebound-delta", "alternate-delta"):
                    prefix = b"sparkle" if fault == "rebound-delta" else b"update"
                    uri = b"urn:unverified" if fault == "rebound-delta" else NS.encode()
                    payload = (b'<' + prefix + b':deltas xmlns:' + prefix + b'="' + uri + b'">'
                               b'<enclosure xmlns="urn:unverified" url="https://example.invalid/unverified.delta" '
                               b'length="1" ' + prefix + b':deltaFrom="99" ' + prefix + b':edSignature="INVALID" />'
                               b'</' + prefix + b':deltas>')
                    raw = raw.replace(b'</item></channel>', payload + b'</item></channel>')
                elif fault == "namespaced-enclosure":
                    raw = raw.replace(b'</item></channel>', b'<enclosure xmlns="urn:unverified" url="https://example.invalid/extra.dmg" /></item></channel>')
                elif fault == "rebound-version":
                    raw = raw.replace(b'</item></channel>', b'<other:version xmlns:other="urn:unverified">101</other:version></item></channel>')
                elif fault == "altered": raw = raw.replace(b'Historical', b'Altered')
                elif fault == "bytes": raw = raw.replace(b'url="https://example.invalid/old.dmg" /', b'url="https://example.invalid/old.dmg"  /')
                elif fault == "removed": raw = raw.replace(old_item, b'')
                else: raw = raw.replace(b'<title>Feed', b'<title>Changed')
                self.assertNotEqual(raw, candidate)
                path.write_bytes(signed_feed(raw))
                self.calls.write_text("")
                self.run_script("appcast-check.sh", success=False)
                self.run_script("publish.sh", input="0.1.0\n", success=False)
                self.assertNotIn("gh ", self.trace())
                self.assertNotIn("git tag", self.trace())
                self.assertNotIn("git push", self.trace())
        path.write_text("<rss>broken XML")
        self.run_script("appcast-check.sh", success=False)

    def test_alternative_prefix_for_real_sparkle_namespace_is_accepted(self):
        path = self.repo / "dist/appcast.xml"
        original = path.read_bytes()
        alternate = original.replace(b"ns0:", b"update:").replace(b"xmlns:ns0=", b"xmlns:update=")
        self.assertNotEqual(alternate, original)
        self.assertIn(b"update:edSignature", alternate)
        path.write_bytes(signed_feed(alternate))
        self.run_script("appcast-check.sh")

    def test_pinned_sparkle_parser_recognizes_rebound_delta(self):
        framework = ROOT / "apple/build/DerivedData/SourcePackages/artifacts/sparkle/Sparkle/Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework"
        self.assertTrue(framework.exists(), "precondition: pinned Sparkle artifact resolved by app build")
        executable = self.base / "appcast-parser-test"
        subprocess.run(["/usr/bin/xcrun", "clang", "-fobjc-arc", "-framework", "Foundation",
                        str(ROOT / "scripts/tests/AppcastParserTests.m"), "-o", str(executable)],
                       env=self.env, check=True, capture_output=True)
        result = subprocess.run([str(executable), str(framework)], env=self.env, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_generated_feed_preserves_exact_published_document(self):
        old_item = b'<item><title>Old &amp; immutable</title><enclosure url="https://example.invalid/old.dmg" /></item>'
        old = b'<rss><channel><title>Feed</title>' + old_item + b'</channel></rss>'
        baseline = self.repo / "dist/baseline.xml"
        baseline.write_bytes(old)
        path = self.repo / "dist/appcast.xml"
        item = ET.tostring(ET.parse(path).find("./channel/item"))
        generated = old.replace(b'</channel>', item + b'</channel>')
        tree = ET.fromstring(generated)
        ET.indent(tree)
        path.write_bytes(ET.tostring(tree))
        self.assertNotIn(old_item, path.read_bytes())  # Sparkle-style reserialization.
        def merge(success):
            result = subprocess.run(["python3", "-I", "scripts/appcast-history.py", "merge", str(baseline), str(path), "100"],
                                    cwd=self.repo, env=self.env, capture_output=True, text=True)
            self.assertEqual(result.returncode == 0, success, result.stdout + result.stderr)
        merge(True)
        result = path.read_bytes()
        self.assertIn(old_item, result)
        # Removing exactly the inserted item restores every original byte.
        parsed = ET.parse(path).findall("./channel/item")
        self.assertEqual(len(parsed), 2)
        self.assertTrue(result.startswith(old[:-len(b'</channel></rss>')]))
        self.publish_feed(old)
        path.write_bytes(signed_feed(path.read_bytes()))
        self.run_script("appcast-check.sh")
        for fault in ("altered", "extra", "metadata"):
            raw = generated.replace(b'immutable', b'changed') if fault == "altered" else generated
            if fault == "extra": raw = raw.replace(b'</channel>', old_item + b'</channel>')
            if fault == "metadata": raw = raw.replace(b'<title>Feed', b'<title>Changed')
            path.write_bytes(signed_feed(raw))
            merge(False)

    def test_confirmation_exact_and_preflight(self):
        for answer in ("yes\n", "0.1.0 \n", "", "0.2.0\n"):
            out = self.run_script("publish.sh", input=answer, success=False)
            self.assertIn("Tag: v0.1.0", out)
            self.assertNotIn("git push", self.trace())
        self.env.pop("TESSERAE_TAP_DIR")
        self.run_script("publish.sh", input="0.1.0\n", success=False)
        self.assertNotIn("git push", self.trace())

    def test_publish_order_orphan_cask_and_checksums(self):
        out = self.run_script("publish.sh", input="0.1.0\n")
        calls = self.trace()
        markers = ["git tag -a", "git push origin refs/tags/v0.1.0", "gh release create", "git worktree add", "git push origin HEAD:refs/heads/gh-pages", "git push origin HEAD", "curl --fail", "brew fetch --cask sdelavega/tap/tesserae"]
        positions = [calls.index(m) for m in markers]
        self.assertEqual(positions, sorted(positions))
        self.assertEqual(self.git("--git-dir", str(self.origin), "show", "gh-pages:appcast.xml"), (self.repo / "dist/appcast.xml").read_text().strip())
        cask = (self.tap / "Casks/tesserae.rb").read_text()
        for value in (self.sha, 'version "0.1.0"', 'auto_updates true', 'depends_on macos: ">= :ventura"', '~/Library/Caches/com.sdelavega.Tesserae', '~/Library/Saved Application State/com.sdelavega.Tesserae.savedState', URL):
            self.assertIn(value, cask)
        self.assertEqual(self.git("for-each-ref", "--format=%(refname)", "refs/heads/tesserae-pages-*"), "")
        self.assertNotIn("git checkout --orphan", calls)
        self.assertIn("Post-publish checks passed", out)
        self.assertIn("Skipping brew style/audit", out)
        self.assertNotIn("LEAK", calls)
        self.assertIn("GH_AUTH_OK", calls)

    def test_pages_retry_fetches_fresh_feed_before_confirmation(self):
        old = b'<rss><channel><title>Fresh remote feed</title></channel></rss>'
        fresh = self.publish_feed(old)
        self.git("update-ref", "refs/remotes/origin/gh-pages", "HEAD")
        self.assertNotEqual(self.git("rev-parse", "origin/gh-pages"), fresh)
        path = self.repo / "dist/appcast.xml"
        item = ET.tostring(ET.parse(path).find("./channel/item"))
        path.write_bytes(signed_feed(old.replace(b'</channel>', item + b'</channel>')))
        self.env["FAULT"] = "pages-propagation"
        out = self.run_script("publish.sh", input="0.1.0\n")
        self.assertIn("Fresh remote feed", out)
        calls = self.trace()
        self.assertLess(calls.index("git fetch origin"), calls.index("git tag -a"))
        self.assertEqual(calls.count("sleep 5"), 1)
        self.assertEqual(calls.count("sleep 10"), 1)
        self.assertEqual(calls.count("https://sdelavega.github.io/tesserae/appcast.xml"), 3)

    def test_failure_resume_and_atomic_cask(self):
        self.env["FAULT"] = "gh"
        out = self.run_script("publish.sh", input="0.1.0\n", success=False)
        self.assertIn("Resume: scripts/publish.sh 0.1.0 --resume", out)
        self.assertFalse((self.tap / "Casks/tesserae.rb").exists())
        self.assertEqual(self.git("rev-parse", "v0.1.0^{}"), self.git("rev-parse", "HEAD"))
        self.env.pop("FAULT")
        readme = self.tap / "README"
        readme.write_text("unrelated change\n")
        out = self.run_script("publish.sh", "--resume", input="0.1.0\n", success=False)
        self.assertIn("Tap must be clean", out)
        readme.write_text("tap\n")
        (self.tap / "Casks").mkdir()
        (self.tap / "Casks/tesserae.rb").write_text("wrong cask")
        out = self.run_script("publish.sh", "--resume", input="0.1.0\n", success=False)
        self.assertIn("Tap changes do not match", out)
        (self.tap / "Casks/tesserae.rb").unlink()
        self.run_script("publish.sh", "--resume", input="0.1.0\n")
        self.assertEqual(self.trace().count("git tag -a"), 1)

    def test_ci_workflow_configures_identity_for_pages_and_tap(self):
        workflow = json.loads(subprocess.check_output([
            "ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
            str(ROOT / ".github/workflows/release.yml")], text=True))
        step = next(s for s in workflow["jobs"]["release"]["steps"] if s.get("name") == "Build, verify and publish")
        self.git("tag", "v0.1.0")
        self.git("push", "origin", "refs/tags/v0.1.0")
        for repo in (self.repo, self.tap):
            self.git("config", "user.useConfigOnly", "true", cwd=repo)
            self.git("config", "--unset", "user.name", cwd=repo)
            self.git("config", "--unset", "user.email", cwd=repo)
        environment = dict(self.env)
        for key in list(environment):
            if key.startswith(("GIT_AUTHOR_", "GIT_COMMITTER_")):
                del environment[key]
        environment.update(GIT_CONFIG_NOSYSTEM="1", GIT_CONFIG_GLOBAL=str(self.base / ".gitconfig"),
                           GIT_CONFIG_COUNT="1", GIT_CONFIG_KEY_0="user.useConfigOnly", GIT_CONFIG_VALUE_0="true",
                           GITHUB_REF_NAME="v0.1.0", SPARKLE_ED_PRIVATE_KEY="fixture-sparkle-key")
        # The workflow drives real temporary Git repositories through publish.sh;
        # the release entry stub replaces only build/sign/notarize work.
        entry = self.repo / "scripts/release.sh"
        entry.write_text('#!/bin/bash\ncat >/dev/null\nexec bash scripts/publish.sh "$@"\n')
        entry.chmod(0o755)
        (self.base / "fault").write_text("")
        self.assertFalse((self.base / ".gitconfig").exists())
        result = subprocess.run(["bash", "-e", "-o", "pipefail", "-c", step["run"]],
                                cwd=self.repo, env=environment, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        for args in (("--git-dir", str(self.origin), "log", "-1", "--format=%an <%ae>", "gh-pages"),
                     ("-C", str(self.tap), "log", "-1", "--format=%an <%ae>")):
            self.assertEqual(self.git(*args), "github-actions[bot] <41898282+github-actions[bot]@users.noreply.github.com>")

    def test_ci_requires_remote_tag_and_head(self):
        self.env["CI"] = "false"
        self.run_script("publish.sh", "--ci-publish", success=False)
        self.env["CI"] = "true"
        self.run_script("publish.sh", "--ci-publish", success=False)
        self.git("tag", "v0.1.0")
        self.run_script("publish.sh", "--ci-publish", success=False)
        self.git("push", "origin", "refs/tags/v0.1.0")
        self.git("commit", "--allow-empty", "-m", "different HEAD")
        out = self.run_script("publish.sh", "--ci-publish", success=False)
        self.assertIn("commit", out)
        self.git("reset", "--hard", "v0.1.0")
        self.manifest.write_text(json.dumps(self.proof))
        self.env["CI"] = "false"
        out = self.run_script("publish.sh", "--ci-publish", success=False)
        self.assertIn("CI=true", out)
        self.env["CI"] = "true"
        self.run_script("publish.sh", "--ci-publish")
        self.assertNotIn("git tag -a", self.trace())

    def test_signed_tag_and_existing_pages_resume(self):
        self.git("config", "user.signingkey", "fake-signing-key")
        self.run_script("publish.sh", input="0.1.0\n")
        self.assertIn("git tag -s", self.trace())
        self.env["FAULT"] = "release-exists"
        self.run_script("publish.sh", "--resume", input="0.1.0\n")
        self.assertIn("gh release upload", self.trace())
        self.assertIn("git fetch origin gh-pages", self.trace())
        self.assertEqual(self.trace().count("git tag -s"), 1)
        self.assertEqual(self.git("worktree", "list", "--porcelain").count("worktree "), 1)

    def test_each_publish_failure_has_resume(self):
        for fault in ("pages", "tap-copy", "tap-commit", "tap-push", "curl", "brew"):
            with self.subTest(fault=fault):
                # Keep the tag from the first attempt and resume later steps.
                self.env["FAULT"] = fault
                mode = ("--resume",) if fault != "pages" else ()
                out = self.run_script("publish.sh", *mode, input="0.1.0\n", success=False)
                self.assertIn("Resume: scripts/publish.sh 0.1.0 --resume", out)
                if fault == "curl":
                    calls = self.trace()
                    self.assertEqual(calls.count("https://sdelavega.github.io/tesserae/appcast.xml"), 25)
                    self.assertEqual(calls.count("sleep "), 24)
                    self.assertIn("within ten minutes", out)
                if fault in ("pages", "tap-copy"):
                    self.assertFalse((self.tap / "Casks/tesserae.rb").exists())
                self.assertFalse(list(self.tap.glob("Casks/.tesserae.*")))
                self.assertEqual(self.git("for-each-ref", "--format=%(refname)", "refs/heads/tesserae-pages-*"), "")

    def test_bad_tap_and_download_failures(self):
        self.env["FAULT"] = "tap-origin"
        self.run_script("publish.sh", input="0.1.0\n", success=False)
        self.assertNotIn("git push", self.trace())
        self.env["FAULT"] = "download"
        out = self.run_script("publish.sh", input="0.1.0\n", success=False)
        self.assertIn("Resume:", out)
        self.assertNotIn("brew fetch", self.trace())


FAKE = r'''#!/usr/bin/env python3
import base64, os, pathlib, subprocess, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
base = pathlib.Path(__file__).resolve().parents[1]
log = base / "calls"
def record(text):
    with log.open("a") as out: out.write(text + "\n")
record(name + " " + " ".join(args[2:] if name == "git" and args[:1] == ["-C"] else args))
allowed = {"PATH", "HOME", "TMPDIR", "LANG", "USER", "DEVELOPER_DIR", "PWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"}
if name == "gh": allowed.add("GH_TOKEN")
assert all(k in allowed or k.startswith("LC_") for k in os.environ), "Unexpected child environment names: " + ", ".join(k for k in os.environ if k not in allowed and not k.startswith("LC_"))
if name == "gh": record("GH_AUTH_OK")
fault = (base / "fault").read_text()
if name == "git":
    # Every real git operation is confined to temporary fixture repositories.
    assert str(pathlib.Path.cwd()).startswith(str(base))
    if args == ["remote", "get-url", "origin"]:
        print("https://github.com/sdelavega/" + ("wrong" if fault == "tap-origin" else "homebrew-tap") + ".git")
    else:
        if fault == "tap-commit" and "commit" in args and any("tap space" in a for a in args):
            sys.exit(42)
        if "push" in args and ((fault == "pages" and "HEAD:refs/heads/gh-pages" in args) or (fault == "tap-push" and "HEAD" in args)):
            sys.exit(42)
        if args[:2] == ["tag", "-s"]:
            args[1] = "-a"  # Never invoke real GPG or access signing material.
        sys.exit(subprocess.run(["__REAL_GIT__", *args]).returncode)
elif name == "xcrun":
    assert args[:2] == ["stapler", "validate"]
    sys.exit(42 if fault == "validate" else 0)
elif name == "spctl":
    assert args[:5] == ["--assess", "--type", "open", "--context", "context:primary-signature"]
    sys.exit(42 if fault == "assess" else 0)
elif name == "cp":
    if fault == "tap-copy" and "/Casks/.tesserae." in args[-1]:
        pathlib.Path(args[-1]).write_text("partial")
        sys.exit(42)
    sys.exit(subprocess.run(["/bin/cp", *args]).returncode)
elif name == "sign_update":
    assert args[:1] == ["--verify"] and args[-2:] == ["--ed-key-file", "-"]
    raw = base64.b64decode(sys.stdin.readline())
    assert raw == bytes(64) + bytes(range(32))
    record("PUBLIC_KEY_OK")
    if args[1].endswith(".xml"):
        import hashlib
        data = pathlib.Path(args[1]).read_bytes()
        content = data.split(b"<!-- sparkle-signatures:")[0]
        signature = base64.b64encode(hashlib.sha512(content).digest())
        expected = content + b"<!-- sparkle-signatures:\nedSignature: " + signature + b"\nlength: " + str(len(content)).encode() + b"\n-->\n"
        sys.exit(0 if data == expected else 1)
    sys.exit(0 if args[2] == "fake-signature" else 1)
elif name == "gh":
    assert os.environ.get("GH_TOKEN") == "planted-gh-auth"
    if args[:2] == ["release", "create"]:
        assert "--verify-tag" in args
        assert pathlib.Path(args[3]).is_file() and pathlib.Path(args[4]).is_file()
        assert pathlib.Path(args[args.index("--notes-file") + 1]).is_file()
    sys.exit(1 if fault == "gh" or (args[:2] == ["release", "view"] and fault != "release-exists") else 0)
elif name == "curl":
    if args[-1].endswith("appcast.xml") and fault == "pages-propagation":
        counter = pathlib.Path(str(base)) / "curl-count"
        count = int(counter.read_text()) if counter.exists() else 0
        counter.write_text(str(count + 1))
        if count < 2:
            if count == 0: sys.exit(22)
            pathlib.Path(args[args.index("--output") + 1]).write_bytes(b"stale feed")
            sys.exit(0)
    if fault == "curl": sys.exit(22)
    assert "--fail" in args
    dest = pathlib.Path(args[args.index("--output") + 1])
    src = pathlib.Path.cwd() / "dist" / ("appcast.xml" if args[-1].endswith("appcast.xml") else "Tesserae-0.1.0.dmg")
    dest.write_bytes(b"corrupt" if fault == "download" else src.read_bytes())
elif name == "sleep":
    assert args in (["5"], ["10"], ["20"])
elif name == "brew":
    if fault == "brew": sys.exit(42)
    assert args == ["fetch", "--cask", "sdelavega/tap/tesserae"]
else:
    sys.exit(88)
'''

if __name__ == "__main__":
    unittest.main()
