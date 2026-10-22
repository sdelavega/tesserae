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
import json
import os
import re
import shutil
import shlex
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[2]


class ReleaseWorkflowTests(unittest.TestCase):
    def setUp(self):
        self.workflow = json.loads(subprocess.check_output([
            "ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
            str(ROOT / ".github/workflows/release.yml")], text=True))
        self.steps = self.workflow["jobs"]["release"]["steps"]
        self.build_steps = self.workflow["jobs"].get("build", {}).get("steps", [])

    def step(self, name):
        return next(step for step in self.steps + self.build_steps if step.get("name") == name)

    def test_tag_only_public_guard_and_secret_scope(self):
        trigger = self.workflow.get("on", self.workflow.get("true"))
        self.assertEqual(trigger, {"push": {"tags": ["v*"]}})
        self.assertEqual(self.workflow["permissions"], {"contents": "read"})
        self.assertEqual(self.workflow["concurrency"],
                         {"group": "release-publish", "cancel-in-progress": False})
        self.assertEqual(list(self.workflow["jobs"]), ["build", "release"])
        self.assertEqual(self.workflow["jobs"]["build"]["permissions"], {"contents": "read"})
        self.assertEqual(self.workflow["jobs"]["release"]["permissions"], {"contents": "write", "actions": "read"})
        self.assertEqual(self.workflow["jobs"]["release"]["needs"], "build")
        job = self.workflow["jobs"]["release"]
        self.assertEqual(job["runs-on"], "macos-26")
        self.assertEqual(job["if"], "github.event.repository.private == false")
        self.assertEqual(job["env"]["DEVELOPER_DIR"], "/Applications/Xcode_26.6.app/Contents/Developer")
        self.assertEqual(self.build_steps[0]["with"]["fetch-depth"], 0)
        expected = {"DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD", "NOTARY_API_KEY_P8", "SPARKLE_ED_PRIVATE_KEY", "TAP_PUSH_TOKEN", "GITHUB_TOKEN"}
        seen = set()
        import re
        for step in self.steps:
            for key, value in step.items():
                if key == "env":
                    seen.update(re.findall(r"secrets\.([A-Z_0-9]+)", json.dumps(value)))
                else:
                    self.assertNotIn("secrets.", json.dumps(value))
        self.assertEqual(seen, expected)
        self.assertNotIn("secrets.", json.dumps(self.workflow["jobs"]["build"]))
        self.assertFalse(any("uses" in step for step in self.steps))
        self.assertEqual(self.step("Clean up signing material")["if"], "always()")
        self.assertIn("MetalToolchain", self.step("Metal toolchain")["run"])
        self.assertEqual(self.step("Upload Xcode results")["if"], "failure()")

    def test_all_actions_are_sha_pinned_with_version_comments(self):
        count = 0
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            for line in path.read_text().splitlines():
                if re.search(r"\buses:", line):
                    count += 1
                    self.assertRegex(line, r"uses: [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40} # v[0-9]+\.[0-9]+\.[0-9]+$")
        self.assertGreater(count, 15, "precondition: all workflow actions inspected")
        config = subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))",
                                          str(ROOT / ".github/dependabot.yml")], text=True)
        updates = json.loads(config)["updates"]
        self.assertIn({"package-ecosystem": "github-actions", "directory": "/", "schedule": {"interval": "weekly"}}, updates)

    def test_action_jobs_never_receive_signing_or_tap_secrets(self):
        for path in (ROOT / ".github/workflows").glob("*.yml"):
            workflow = json.loads(subprocess.check_output(["ruby", "-ryaml", "-rjson", "-e", "puts JSON.generate(YAML.load_file(ARGV[0]))", str(path)], text=True))
            for name, job in workflow["jobs"].items():
                if any("uses" in step for step in job.get("steps", [])) or "uses" in job:
                    self.assertNotRegex(json.dumps(job), r"secrets\.(?:DEVELOPER_ID_|NOTARY_|SPARKLE_|TAP_PUSH_TOKEN)")
        self.assertNotRegex(json.dumps({key: value for key, value in self.workflow.items() if key != "jobs"}),
                            r"secrets\.(?:DEVELOPER_ID_|NOTARY_|SPARKLE_|TAP_PUSH_TOKEN)")

    def test_tool_uses_fresh_environment_without_exported_functions(self):
        for inherited in (False, True):
            with self.subTest(inherited=inherited):
                environment = {"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
                               "UNRECOGNIZED_NAME": "inert-variable-credential"}
                if inherited:
                    environment["BASH_FUNC_fixture_credential_helper%%"] = "() { : inert-function-credential; }"
                    define = ""
                else:
                    define = "fixture_credential_helper() { : inert-function-credential; }; export -f fixture_credential_helper;"
                script = define + r'''
                    python3 -I -c 'import os; assert any("inert-function-credential" in v for k,v in os.environ.items() if k.startswith("BASH_FUNC_")), "precondition: exported helper reaches ordinary child"'
                    source scripts/release-tools.sh
                    tool python3 -I -c 'import os; assert os.read(3, 32) == b"private redactions"' 3< <(printf "%s" "private redactions")
                    tool python3 -I -c 'import os; assert not any(k.startswith("BASH_FUNC_") for k in os.environ); assert "UNRECOGNIZED_NAME" not in os.environ; assert os.environ["HOME"]; assert os.environ["PATH"]'
                '''
                result = subprocess.run(["bash", "--noprofile", "--norc", "-e", "-c", script],
                                        cwd=ROOT, env=environment, capture_output=True, text=True)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def check_printf_collision(self, mode):
        with tempfile.TemporaryDirectory(prefix="tesserae-printf-") as directory:
            root = Path(directory)
            observed = root / "interceptor-ran"
            child = root / "child-ran"
            environment = {"PATH": os.environ["PATH"], "HOME": str(root),
                           "UNRECOGNIZED_NAME": "inert-original-credential"}
            helper = ("import os,pathlib; "
                      "assert os.environ.get('UNRECOGNIZED_NAME') == 'inert-original-credential'; "
                      f"pathlib.Path({str(observed)!r}).write_text('observed')")
            function = ("printf() { python3 -I -c " + shlex.quote(helper) + "; "
                        "builtin printf '%s\\0' 'INJECTED_MARKER=inert-injected-credential'; "
                        "builtin printf \"$@\"; }")
            define = ""
            if mode == "exported":
                define = function + "; export -f printf; "
            elif mode == "imported":
                environment["BASH_FUNC_printf%%"] = function[len("printf"):]
            else:
                startup = root / "startup.sh"
                startup.write_text(function + "\n")
                environment["BASH_ENV"] = str(startup)
            def run(command, cwd=ROOT):
                return subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-c",
                                       define + command], cwd=cwd, env=environment,
                                      capture_output=True, text=True)
            # Prove each collision is active and can observe the original marker.
            precondition = run("printf '%s' precondition")
            self.assertEqual(precondition.returncode, 0, precondition.stderr)
            self.assertIn("INJECTED_MARKER=", precondition.stdout)
            self.assertEqual(observed.read_text(), "observed")
            observed.unlink()
            probe = ("import os,pathlib; assert 'INJECTED_MARKER' not in os.environ; "
                     "assert 'UNRECOGNIZED_NAME' not in os.environ; "
                     "assert not any(k.startswith('BASH_FUNC_') for k in os.environ); "
                     f"pathlib.Path({str(child)!r}).write_text('clean')")
            command = ("source " + shlex.quote(str(ROOT / "scripts/release-tools.sh")) +
                       "; tool python3 -I -c " + shlex.quote(probe))
            result = run(command)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            self.assertEqual(child.read_text(), "clean")
            self.assertFalse(observed.exists(), "interceptor saw the original environment")
            child.unlink()
            # Exercise the real recipes with harmless stand-ins for their scripts.
            shutil.copy(ROOT / "justfile", root / "justfile")
            (root / "scripts/tests").mkdir(parents=True)
            for name in ("scripts/release.sh", "scripts/tests/release_test.sh"):
                (root / name).write_text("set -euo pipefail\n" + ('[[ $# == 1 && $1 == "argument with spaces" ]]\n'
                                         if name == "scripts/release.sh" else "") +
                                        '[[ ! ${BASH_ENV+x} && -z $(builtin compgen -A function) ]]\n' +
                                        "python3 -I -c " + shlex.quote(probe) + "\n" + command + "\n")
                (root / name).chmod(0o755)
            for name in ("publish_test.py", "release_workflow_test.py", "release_input_test.py"):
                (root / "scripts/tests" / name).write_text(probe + "\n")
            for recipe in ("release 'argument with spaces'", "release-test"):
                result = run("exec just " + recipe, cwd=root)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertEqual(child.read_text(), "clean")
                self.assertFalse(observed.exists(), "recipe interceptor ran before isolation")
                child.unlink()
            # Direct invocation must refuse inherited state before any tool runs.
            result = run("exec /bin/bash --noprofile --norc scripts/release.sh invalid")
            self.assertNotEqual(result.returncode, 0)
            self.assertIn("Release requires no inherited shell state", result.stderr)
            self.assertFalse(observed.exists(), "refusal invoked an interceptor")

    def test_exported_printf_cannot_intercept_release_bootstrap(self):
        self.check_printf_collision("exported")

    def test_startup_imported_printf_cannot_intercept_release_bootstrap(self):
        self.check_printf_collision("imported")

    def test_bash_env_printf_cannot_intercept_release_bootstrap(self):
        self.check_printf_collision("startup")

    def test_release_refuses_even_an_empty_bash_env(self):
        result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "scripts/release.sh", "invalid"],
                                cwd=ROOT, env={"PATH": os.environ["PATH"], "HOME": os.environ["HOME"],
                                               "BASH_ENV": "/dev/null"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("Release requires no inherited shell state", result.stderr)

    def test_tool_revalidates_received_environment_names(self):
        source = (ROOT / "scripts/release-tools.sh").read_text()
        producer = "builtin printf '%s\\0' \"${allowed[@]}\""
        self.assertEqual(source.count(producer), 1, "precondition: replace only the transfer producer")
        with tempfile.TemporaryDirectory(prefix="tesserae-transfer-") as directory:
            transfer = Path(directory) / "release-tools.sh"
            # Supply hostile wire data even though the real producer is trusted.
            transfer.write_text(source.replace(producer, producer +
                                " 'INJECTED_MARKER=inert-injected-credential' 'GH_TOKEN=inert-gh'"))
            result = subprocess.run(["/bin/bash", "--noprofile", "--norc", "-e", "-c",
                                     "source " + shlex.quote(str(transfer)) + r"""
                tool python3 -I -c 'import os; assert "INJECTED_MARKER" not in os.environ; assert "GH_TOKEN" not in os.environ; assert os.environ["HOME"]'
                PUBLISH_GH_AUTH=1 GH=python3 tool python3 -I -c 'import os; assert "INJECTED_MARKER" not in os.environ; assert os.environ["GH_TOKEN"] == "inert-gh"'
            """], cwd=ROOT, env={"PATH": os.environ["PATH"], "HOME": directory},
                                    capture_output=True, text=True)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_setup_cleanup_and_stdin_with_fake_tools(self):
        for fault in ("", "import", "notary"):
            with self.subTest(fault=fault), tempfile.TemporaryDirectory(prefix="tesserae-workflow-") as directory:
                root = Path(directory).resolve()
                (root / "bin").mkdir()
                (root / "apple").mkdir()
                (root / "scripts").mkdir()
                shutil.copy(ROOT / "scripts/release-tools.sh", root / "scripts/release-tools.sh")
                (root / "fault").write_text(fault)
                fake = root / "bin/fake"
                fake.write_text(FAKE)
                fake.chmod(0o755)
                for name in ("security", "xcrun", "openssl", "base64", "rm", "git"):
                    (root / "bin" / name).symlink_to(fake)
                (root / "scripts/release.sh").symlink_to(fake)
                original = [str(root / "login with space.keychain-db"), str(root / "system.keychain")]
                state = root / "state.json"
                state.write_text(json.dumps(original))
                environment = dict(PATH=str(root / "bin") + ":" + os.environ["PATH"], HOME=str(root),
                                   RUNNER_TEMP=str(root), GITHUB_WORKSPACE=str(root), STATE=str(state),
                                   CALLS=str(root / "calls"), FAULT=fault, GITHUB_REF_NAME="v0.1.0",
                                   DEVELOPER_ID_P12_BASE64=base64.b64encode(b"inert fixture certificate").decode(),
                                   DEVELOPER_ID_P12_PASSWORD="fixture-p12-password", NOTARY_API_KEY_P8="fixture-api-private-key",
                                   NOTARY_KEY_ID="FIXTUREKEY", NOTARY_ISSUER_ID="fixture-issuer", ARBITRARY_UNRECOGNIZED_NAME="fixture-unknown-secret",
                                   DEVELOPMENT_TEAM="TESTTEAM", CODE_SIGN_IDENTITY="Developer ID Application: Fixture (TESTTEAM)",
                                   SPARKLE_ED_PRIVATE_KEY="fixture-sparkle-key", GH_TOKEN="fixture-github-token", TAP_PUSH_TOKEN="fixture-tap-token",
                                   TESSERAE_TAP_DIR=str(root / "tap"), NOTARY_KEYCHAIN=str(root / "tesserae-ci.keychain-db"))
                def run(name):
                    scoped = {k: environment[k] for k in ("PATH", "HOME", "RUNNER_TEMP", "GITHUB_WORKSPACE", "GITHUB_REF_NAME")}
                    scoped.update({k: environment[k] for k in self.step(name).get("env", {}) if k in environment})
                    scoped["ARBITRARY_UNRECOGNIZED_NAME"] = "fixture-unknown-secret"
                    return subprocess.run(["bash", "--noprofile", "--norc", "-e", "-o", "pipefail", "-c", self.step(name)["run"]],
                                          cwd=root, env=scoped, text=True, capture_output=True)
                setup = run("Set up signing and notarization")
                self.assertEqual(setup.returncode == 0, not fault, setup.stdout + setup.stderr)
                output = setup.stdout + setup.stderr
                if fault:
                    self.assertIn("security import" if fault == "import" else "xcrun notarytool", (root / "calls").read_text())
                if not fault:
                    self.assertFalse((root / "developer-id.p12").exists())
                    self.assertEqual(json.loads(state.read_text()), [str(root / "tesserae-ci.keychain-db"), *original])
                    config = run("Write release configuration")
                    self.assertEqual(config.returncode, 0, config.stdout + config.stderr)
                    output += config.stdout + config.stderr
                    text = (root / "apple/Release.local.xcconfig").read_text()
                    self.assertIn("NOTARY_PROFILE = tesserae-ci", text)
                    self.assertIn("DEVELOPMENT_TEAM = TESTTEAM", text)
                    self.assertIn(environment["CODE_SIGN_IDENTITY"], text)
                    publish = run("Sign, verify and publish")
                    self.assertEqual(publish.returncode, 0, publish.stdout + publish.stderr)
                    output += publish.stdout + publish.stderr
                    self.assertIn("STDIN_OK", (root / "calls").read_text())
                cleanup = run("Clean up signing material")
                self.assertEqual(cleanup.returncode, 0, cleanup.stdout + cleanup.stderr)
                self.assertEqual(json.loads(state.read_text()), original)
                for name in ("developer-id.p12", "tesserae-ci.keychain-db", "tesserae-keychains.txt", "notary-api.p8", "tap-credentials", "repository-credentials", "apple/Release.local.xcconfig"):
                    self.assertFalse((root / name).exists(), name)
                output += cleanup.stdout + cleanup.stderr
                for name in ("DEVELOPER_ID_P12_BASE64", "DEVELOPER_ID_P12_PASSWORD", "NOTARY_API_KEY_P8", "ARBITRARY_UNRECOGNIZED_NAME", "SPARKLE_ED_PRIVATE_KEY", "GH_TOKEN", "TAP_PUSH_TOKEN"):
                    self.assertNotIn(environment[name], output)


FAKE = r'''#!/usr/bin/env python3
import json, os, pathlib, sys
name = pathlib.Path(sys.argv[0]).name
args = sys.argv[1:]
root = pathlib.Path(__file__).resolve().parents[1]
state = root / "state.json"
fault = (root / "fault").read_text()
allowed = {"PATH", "HOME", "TMPDIR", "LANG", "USER", "DEVELOPER_DIR", "PWD", "SHLVL", "_", "__CF_USER_TEXT_ENCODING"}
if name == "release.sh":
    allowed.update({"GH_TOKEN", "CI", "GITHUB_REF_NAME", "TESSERAE_TAP_DIR", "NOTARY_KEYCHAIN"})
assert all(k in allowed or k.startswith("LC_") for k in os.environ), "Unrelated child inherited variables"
private_values = ["fixture-p12-password", "fixture-api-private-key", "fixture-sparkle-key", "fixture-github-token", "fixture-unknown-secret", "fixture-random-keychain-password", "fixture-tap-token"]
for value in private_values:
    for i, arg in enumerate(args):
        if value in arg:
            assert name == "security" and ((args[0] == "import" and i > 0 and args[i-1] == "-P" and value == "fixture-p12-password") or (args[0] in ("create-keychain", "unlock-keychain", "set-key-partition-list") and i > 0 and args[i-1] in ("-p", "-k") and value == "fixture-random-keychain-password")), "Secret in argv"
with (root / "calls").open("a") as log:
    log.write(name + " " + (args[0] if args else "") + "\n")
if name == "git":
    if "clone" in args:
        credential = root / "tap-credentials"
        assert credential.stat().st_mode & 0o077 == 0
        assert "fixture-tap-token" in credential.read_text()
        repository = root / "repository-credentials"
        assert repository.stat().st_mode & 0o077 == 0
        assert "fixture-github-token" in repository.read_text()
        assert "fixture-tap-token" not in repository.read_text()
        assert "fixture-github-token" not in credential.read_text()
        (root / args[-1]).mkdir(parents=True)
    else:
        assert "config" in args
elif name == "openssl":
    assert args == ["rand", "-base64", "32"]
    print("fixture-random-keychain-password")
elif name == "security":
    command = args[0]
    keychain = root / "tesserae-ci.keychain-db"
    if command == "list-keychains":
        assert args[1:3] == ["-d", "user"]
        if len(args) == 3:
            for item in json.loads(state.read_text()): print(json.dumps(item))
        else:
            assert args[3] == "-s"
            state.write_text(json.dumps(args[4:]))
    elif command == "create-keychain":
        assert args[1:] == ["-p", "fixture-random-keychain-password", str(keychain)]
        keychain.touch()
    elif command == "unlock-keychain":
        assert args[1:] == ["-p", "fixture-random-keychain-password", str(keychain)]
    elif command == "set-keychain-settings":
        assert args[-1] == str(keychain)
    elif command == "import":
        certificate = root / "developer-id.p12"
        assert args[1] == str(certificate) and certificate.read_bytes() == b"inert fixture certificate"
        assert certificate.stat().st_mode & 0o077 == 0
        assert args[args.index("-P") + 1] == "fixture-p12-password"
        if fault == "import": sys.exit(42)
    elif command == "set-key-partition-list":
        assert not (root / "developer-id.p12").exists()
        assert args[args.index("-S")+1] == "apple-tool:,apple:,codesign:"
        assert args[args.index("-k")+1] == "fixture-random-keychain-password"
    elif command == "delete-keychain":
        keychain.unlink(missing_ok=True)
    else: sys.exit(90)
elif name == "xcrun":
    assert args[:3] == ["notarytool", "store-credentials", "tesserae-ci"]
    assert args[args.index("--keychain")+1] == str(root / "tesserae-ci.keychain-db")
    assert "--password" not in args and "--apple-id" not in args
    assert args[args.index("--key-id")+1] == "FIXTUREKEY"
    assert args[args.index("--issuer")+1] == "fixture-issuer"
    key = pathlib.Path(args[args.index("--key")+1])
    assert key.read_text() == "fixture-api-private-key" and key.stat().st_mode & 0o077 == 0
    if fault == "notary": sys.exit(42)
elif name == "release.sh":
    assert args == ["0.1.0", "--ci-publish", "--prebuilt", "apple/build/release-input"]
    assert sys.stdin.read().strip() == "fixture-sparkle-key"
    assert os.environ["GH_TOKEN"] == "fixture-github-token"
    with (root / "calls").open("a") as log: log.write("STDIN_OK\n")
elif name == "base64":
    import base64
    assert args == ["--decode"]
    sys.stdout.buffer.write(base64.b64decode(sys.stdin.buffer.read()))
elif name == "rm":
    assert args[0] == "-f"
    for arg in args[1:]:
        path = pathlib.Path(arg).resolve()
        assert path.is_relative_to(root)
        path.unlink(missing_ok=True)
else: sys.exit(91)
'''

if __name__ == "__main__":
    unittest.main()
