import hashlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest


PROJECT = Path(__file__).resolve().parents[1]
COMMIT = "0123456789abcdef0123456789abcdef01234567"
OTHER_COMMIT = "abcdef0123456789abcdef0123456789abcdef01"


class PackagePublicationTest(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="miuutil-ci-test-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.output = self.root / "output"
        self.output.mkdir()
        self.environment = dict(os.environ, BUILD_COMMIT=COMMIT,
                                GITHUB_REPOSITORY="RisPNG/miuutil", GITHUB_REF="refs/heads/main",
                                DEFAULT_BRANCH="main")
        package = self.root / "package/DEBIAN"
        package.mkdir(parents=True)
        (package / "control").write_text(
            "Package: miuutil\nVersion: 0.1.4-1+git20261009010101.0123456789ab\n"
            "Architecture: amd64\nMaintainer: Ris Peng <hello@rispeng.com>\n"
            "Description: CI metadata fixture\n")
        self.archive = self.output / "miuutil_0.1.4-1+git20261009010101.0123456789ab_amd64.deb"
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(package.parent), str(self.archive)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.stub_state = self.root / "state.json"
        self.log = self.root / "commands.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        stub = self.bin / "commands"
        stub.write_text("""#!/usr/bin/env python3
import json
import os
from pathlib import Path
import sys

state_file = Path(os.environ['CI_STUB_STATE'])
state = json.loads(state_file.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with Path(os.environ['CI_STUB_LOG']).open('a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
if name == 'git':
    index = state.get('reads', 0)
    heads = state.get('heads', [os.environ['BUILD_COMMIT']])
    state['reads'] = index + 1
    state_file.write_text(json.dumps(state))
    print(heads[min(index, len(heads) - 1)] + '\\t' + os.environ['GITHUB_REF'])
elif args[:2] == ['release', 'view']:
    if not state.get('existing', True):
        sys.exit(1)
    if '--jq' in args:
        for asset in state.get('assets', []):
            print(asset['name'])
    else:
        print(json.dumps({'isDraft': state.get('draft', False),
                          'isPrerelease': state.get('prerelease', True),
                          'assets': state.get('assets', [])}))
elif args[:2] == ['release', 'download']:
    directory = Path(args[args.index('--dir') + 1])
    record = state.get('published_manifest', json.loads(Path(os.environ['CI_STUB_MANIFEST']).read_text()))
    record['commit'] = state.get('published_commit', os.environ['BUILD_COMMIT'])
    (directory / 'build.json').write_text(json.dumps(record))
elif args[:2] == ['release', 'create']:
    state['existing'] = True
    state_file.write_text(json.dumps(state))
""")
        stub.chmod(0o755)
        (self.bin / "git").symlink_to(stub)
        (self.bin / "gh").symlink_to(stub)
        self.environment.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                CI_STUB_STATE=str(self.stub_state), CI_STUB_LOG=str(self.log),
                                CI_STUB_MANIFEST=str(self.output / "build.json"))

    def manifest(self, commit=COMMIT):
        ref = self.environment["GITHUB_REF"]
        return subprocess.run([
            sys.executable, "-B", str(PROJECT / "dev/package-manifest.py"), str(self.output),
            "--repository", "RisPNG/miuutil", "--commit", commit, "--ref", ref,
            "--tag", ref[10:] if ref.startswith("refs/tags/") else "latest-build",
            "--source-date-epoch", "1791507661",
            "--workflow-run", "https://github.com/RisPNG/miuutil/actions/runs/123",
        ], text=True, capture_output=True)

    def publish(self, state):
        self.assertEqual(self.manifest().returncode, 0)
        self.stub_state.write_text(json.dumps(state))
        return subprocess.run(["bash", str(PROJECT / "dev/publish-package.sh"), str(self.output)],
                              env=self.environment, text=True, capture_output=True)

    def commands(self):
        return [json.loads(line) for line in self.log.read_text().splitlines()] if self.log.exists() else []

    def test_manifest_binds_native_metadata_bytes_and_source(self):
        result = self.manifest()
        self.assertEqual(result.returncode, 0, result.stderr)
        record = json.loads((self.output / "build.json").read_text())
        self.assertEqual(record["commit"], COMMIT)
        self.assertEqual(record["schema"], 1)
        self.assertEqual(record["tag"], "latest-build")
        self.assertEqual(record["packages"][0], {
            "file": self.archive.name, "package": "miuutil",
            "version": "0.1.4-1+git20261009010101.0123456789ab", "architecture": "amd64",
            "sha256": hashlib.sha256(self.archive.read_bytes()).hexdigest(),
            "bytes": self.archive.stat().st_size,
        })
        checksum = subprocess.run(["sha256sum", "--check", "SHA256SUMS"], cwd=self.output,
                                  text=True, capture_output=True)
        self.assertEqual(checksum.returncode, 0, checksum.stderr)

    def test_manifest_rejects_incomplete_commit_and_ambiguous_packages(self):
        self.assertNotEqual(self.manifest("1234").returncode, 0)
        duplicate = self.output / "miuutil_extra_amd64.deb"
        duplicate.write_bytes(self.archive.read_bytes())
        self.assertNotEqual(self.manifest().returncode, 0)

    def test_stale_branch_build_never_changes_release(self):
        result = self.publish({"heads": [OTHER_COMMIT]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(all(command[0] == "git" for command in self.commands()))

    def test_changed_package_is_rejected_before_contacting_github(self):
        self.assertEqual(self.manifest().returncode, 0)
        content = self.archive.read_bytes()
        self.archive.write_bytes(content[:-1] + bytes([content[-1] ^ 1]))
        self.stub_state.write_text(json.dumps({}))
        result = subprocess.run(["bash", str(PROJECT / "dev/publish-package.sh"), str(self.output)],
                                env=self.environment, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_branch_advance_during_upload_preserves_manifest_and_checksums(self):
        result = self.publish({"heads": [COMMIT, OTHER_COMMIT]})
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = [command for command in self.commands() if command[1:3] == ["release", "upload"]]
        self.assertEqual(len(uploads), 1)
        self.assertIn(self.archive.name, uploads[0])
        self.assertFalse(any(command[1:2] == ["api"] for command in self.commands()))

    def test_rolling_release_publishes_manifest_last_then_removes_old_package(self):
        result = self.publish({"assets": [{"name": "miuutil_old_amd64.deb"}, {"name": self.archive.name}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        uploads = [command for command in commands if command[1:3] == ["release", "upload"]]
        self.assertEqual([command[4] for command in uploads], [self.archive.name, "SHA256SUMS", "build.json"])
        deletion = next(command for command in commands if command[1:3] == ["release", "delete-asset"])
        self.assertGreater(commands.index(deletion), commands.index(uploads[-1]))

    def test_rolling_release_cannot_replace_a_stable_release(self):
        result = self.publish({"prerelease": False})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command[1:3] == ["release", "upload"] for command in self.commands()))

    def test_rolling_release_rerun_preserves_the_published_commit_assets(self):
        result = self.publish({"assets": [{"name": name} for name in
                                         ("build.json", "SHA256SUMS", self.archive.name)]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("already has a published package", result.stdout)
        self.assertTrue(all(command[0] == "git" or command[1:3] in
                            (["release", "view"], ["release", "download"])
                            for command in self.commands()))

    def test_rolling_release_older_manifest_receives_the_new_commit(self):
        result = self.publish({"published_commit": OTHER_COMMIT,
                               "assets": [{"name": name} for name in
                                          ("build.json", "SHA256SUMS", "miuutil_old_amd64.deb")]})
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = [command for command in self.commands() if command[1:3] == ["release", "upload"]]
        self.assertEqual([command[4] for command in uploads], [self.archive.name, "SHA256SUMS", "build.json"])

    def test_rolling_release_incomplete_same_commit_does_not_skip_publication(self):
        result = self.publish({"assets": [{"name": "build.json"}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(command[1:3] == ["release", "upload"] for command in self.commands()))

    def test_moved_release_tag_is_rejected(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        result = self.publish({"heads": [OTHER_COMMIT]})
        self.assertNotEqual(result.returncode, 0)
        self.assertTrue(all(command[0] == "git" for command in self.commands()))

    def test_tag_draft_can_resume_but_published_tag_stays_immutable(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        result = self.publish({"draft": True})
        self.assertEqual(result.returncode, 0, result.stderr)
        upload = next(command for command in self.commands() if command[1:3] == ["release", "upload"])
        self.assertIn("--clobber", upload)
        self.log.unlink()
        result = self.publish({"draft": False, "assets": [{"name": "build.json"}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[1:3] in (["release", "upload"], ["release", "edit"])
                             for command in self.commands()))

    def test_published_release_without_ci_assets_receives_them_without_overwrite(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        result = self.publish({"draft": False})
        self.assertEqual(result.returncode, 0, result.stderr)
        upload = next(command for command in self.commands() if command[1:3] == ["release", "upload"])
        self.assertNotIn("--clobber", upload)


if __name__ == "__main__":
    unittest.main()
