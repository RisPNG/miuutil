import hashlib
import json
import os
from pathlib import Path
import shutil
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
        self.launcher = self.output / "run.sh"
        self.launcher.write_text("#!/usr/bin/env bash\nprintf 'tagged launcher fixture\\n'\n")
        self.stub_state = self.root / "state.json"
        self.log = self.root / "commands.jsonl"
        self.bin = self.root / "bin"
        self.bin.mkdir()
        stub = self.bin / "commands"
        stub.write_text("""#!/usr/bin/env python3
import json
import hashlib
import os
from pathlib import Path
import sys

state_file = Path(os.environ['CI_STUB_STATE'])
state = json.loads(state_file.read_text())
name = Path(sys.argv[0]).name
args = sys.argv[1:]
target = args[2] if name == 'gh' and args[0] == 'release' else None
release = state.get('releases', {}).get(target, {'existing': False} if target == 'latest-release' else state)

def release_files():
    record = release.get('published_manifest', json.loads(Path(os.environ['CI_STUB_MANIFEST']).read_text()))
    record['commit'] = release.get('published_commit', record['commit'])
    files = {
        record['packages'][0]['file']: Path(os.environ['CI_STUB_PACKAGE']).read_bytes(),
        'run.sh': Path(os.environ['CI_STUB_LAUNCHER']).read_bytes(),
        'build.json': (json.dumps(record, indent=2) + '\\n').encode(),
    }
    files['SHA256SUMS'] = ''.join(hashlib.sha256(data).hexdigest() + '  ' + filename + '\\n'
                                  for filename, data in files.items()).encode()
    for filename, path in release.get('files', {}).items():
        files[filename] = Path(path).read_bytes()
    return files

with Path(os.environ['CI_STUB_LOG']).open('a') as log:
    log.write(json.dumps([name, *args]) + '\\n')
if name == 'git':
    if args[2] in ('refs/tags/latest-build', 'refs/tags/latest-release'):
        print(state.get('alias_commit', os.environ['BUILD_COMMIT']) + '\\t' + args[2])
    else:
        index = state.get('reads', 0)
        heads = state.get('heads', [os.environ['BUILD_COMMIT']])
        state['reads'] = index + 1
        state_file.write_text(json.dumps(state))
        print(heads[min(index, len(heads) - 1)] + '\\t' + os.environ['GITHUB_REF'])
elif args[:2] == ['release', 'view']:
    if not release.get('existing', True):
        sys.exit(1)
    if '--jq' in args:
        for asset in release.get('assets', []):
            if asset['name'].startswith('miuutil_') and asset['name'].endswith('.deb'):
                print(asset['name'])
    else:
        files = release_files()
        assets = []
        for item in release.get('assets', []):
            asset = dict(item)
            if asset['name'] in files:
                asset['digest'] = 'sha256:' + hashlib.sha256(files[asset['name']]).hexdigest()
                asset['size'] = len(files[asset['name']])
            assets.append(asset)
        print(json.dumps({'isDraft': release.get('draft', False),
                          'isPrerelease': release.get('prerelease', target == 'latest-build'),
                          'assets': assets}))
elif args[:2] == ['release', 'download']:
    directory = Path(args[args.index('--dir') + 1])
    files = release_files()
    for index, argument in enumerate(args):
        if argument == '--pattern':
            filename = args[index + 1]
            (directory / filename).write_bytes(files[filename])
elif args[:2] == ['release', 'create']:
    if target == 'latest-release':
        state.setdefault('releases', {})[target] = {'existing': True, 'prerelease': False}
    else:
        state['existing'] = True
    state_file.write_text(json.dumps(state))
elif args[:2] == ['release', 'upload']:
    uploads = state.setdefault('uploads', [])
    for argument in args[3:]:
        path = Path(argument)
        if path.is_file():
            uploads.append({'tag': target, 'file': path.name,
                            'sha256': hashlib.sha256(path.read_bytes()).hexdigest()})
    state_file.write_text(json.dumps(state))
""")
        stub.chmod(0o755)
        (self.bin / "git").symlink_to(stub)
        (self.bin / "gh").symlink_to(stub)
        self.environment.update(PATH=str(self.bin) + os.pathsep + os.environ["PATH"],
                                CI_STUB_STATE=str(self.stub_state), CI_STUB_LOG=str(self.log),
                                CI_STUB_MANIFEST=str(self.output / "build.json"),
                                CI_STUB_PACKAGE=str(self.archive), CI_STUB_LAUNCHER=str(self.launcher))

    def manifest(self, commit=COMMIT):
        ref = self.environment["GITHUB_REF"]
        return subprocess.run([
            sys.executable, "-B", str(PROJECT / "dev/package-manifest.py"), str(self.output),
            "--repository", "RisPNG/miuutil", "--commit", commit, "--ref", ref,
            "--tag", ref[10:] if ref.startswith("refs/tags/") else "latest-build",
            "--source-date-epoch", "1791507661",
            "--workflow-run", "https://github.com/RisPNG/miuutil/actions/runs/" + self.environment.get("GITHUB_RUN_ID", "123"),
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
        self.assertEqual(record["launcher"], {"file": "run.sh", "bytes": self.launcher.stat().st_size,
                                              "sha256": hashlib.sha256(self.launcher.read_bytes()).hexdigest()})
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

    def test_changed_launcher_is_rejected_before_contacting_github(self):
        self.assertEqual(self.manifest().returncode, 0)
        self.launcher.write_text("#!/usr/bin/env bash\nexit 1\n")
        self.stub_state.write_text(json.dumps({}))
        result = subprocess.run(["bash", str(PROJECT / "dev/publish-package.sh"), str(self.output)],
                                env=self.environment, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_non_numeric_workflow_run_cannot_publish_first_release(self):
        self.environment.update(GITHUB_REF="refs/tags/v0.1.4", GITHUB_RUN_ID="local")
        result = self.publish({"existing": False})
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.commands(), [])

    def test_branch_advance_during_upload_preserves_manifest_and_checksums(self):
        result = self.publish({"heads": [COMMIT, OTHER_COMMIT]})
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = [command for command in self.commands() if command[1:3] == ["release", "upload"]]
        self.assertEqual(len(uploads), 1)
        self.assertIn(str(self.archive), uploads[0])
        self.assertFalse(any(command[1:2] == ["api"] for command in self.commands()))

    def test_rolling_release_publishes_manifest_last_then_removes_old_package(self):
        result = self.publish({"assets": [{"name": "miuutil_old_amd64.deb"}, {"name": self.archive.name}]})
        self.assertEqual(result.returncode, 0, result.stderr)
        commands = self.commands()
        uploads = [command for command in commands if command[1:3] == ["release", "upload"]]
        self.assertEqual([Path(command[4]).name for command in uploads], [self.archive.name, "run.sh", "build.json"])
        self.assertIn(str(self.output / "SHA256SUMS"), uploads[1])
        deletion = next(command for command in commands if command[1:3] == ["release", "delete-asset"])
        self.assertGreater(commands.index(deletion), commands.index(uploads[-1]))

    def test_rolling_release_cannot_replace_a_stable_release(self):
        result = self.publish({"prerelease": False})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command[1:3] == ["release", "upload"] for command in self.commands()))

    def test_rolling_release_rerun_preserves_the_published_commit_assets(self):
        result = self.publish({"assets": [{"name": name} for name in
                                         ("build.json", "SHA256SUMS", "run.sh", self.archive.name)]})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("leaving it unchanged", result.stdout)
        self.assertTrue(all(command[0] == "git" or command[1:3] in
                            (["release", "view"], ["release", "download"])
                            for command in self.commands()))
        downloads = [command for command in self.commands() if command[1:3] == ["release", "download"]]
        self.assertEqual(len(downloads), 1)
        self.assertEqual(downloads[0][downloads[0].index("--pattern") + 1], "build.json")

    def test_rolling_release_older_manifest_receives_the_new_commit(self):
        result = self.publish({"published_commit": OTHER_COMMIT,
                               "assets": [{"name": name} for name in
                                          ("build.json", "SHA256SUMS", "run.sh", "miuutil_old_amd64.deb")]})
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = [command for command in self.commands() if command[1:3] == ["release", "upload"]]
        self.assertEqual([Path(command[4]).name for command in uploads], [self.archive.name, "run.sh", "build.json"])

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
        result = self.publish({"draft": False, "assets": [{"name": "build.json"}],
                               "releases": {"latest-release": {"prerelease": False,
                                             "assets": [{"name": name} for name in
                                                        ("build.json", "SHA256SUMS", "run.sh", self.archive.name)]}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[1:3] in (["release", "upload"], ["release", "edit"])
                             for command in self.commands()))

    def test_published_release_without_ci_assets_receives_them_without_overwrite(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        result = self.publish({"draft": False})
        self.assertEqual(result.returncode, 0, result.stderr)
        upload = next(command for command in self.commands() if command[1:3] == ["release", "upload"])
        self.assertNotIn("--clobber", upload)

    def test_tag_publishes_identical_assets_to_source_release_and_alias(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        result = self.publish({"existing": False})
        self.assertEqual(result.returncode, 0, result.stderr)
        state = json.loads(self.stub_state.read_text())
        original = {item["file"]: item["sha256"] for item in state["uploads"] if item["tag"] == "v0.1.4"}
        alias = {item["file"]: item["sha256"] for item in state["uploads"] if item["tag"] == "latest-release"}
        self.assertEqual(original, alias)
        self.assertEqual(set(alias), {self.archive.name, "run.sh", "SHA256SUMS", "build.json"})
        record = json.loads((self.output / "build.json").read_text())
        self.assertEqual(record["tag"], "v0.1.4")
        self.assertEqual(record["ref"], "refs/tags/v0.1.4")
        commands = self.commands()
        creation = next(command for command in commands if command[1:4] == ["release", "create", "latest-release"])
        self.assertIn("--prerelease=false", creation)
        self.assertIn("--latest=false", creation)
        uploads = [command for command in commands if command[1:4] == ["release", "upload", "latest-release"]]
        self.assertEqual([Path(command[4]).name for command in uploads], [self.archive.name, "run.sh", "build.json"])

    def test_tag_alias_uses_workflow_run_order_instead_of_version_or_commit_date(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.0.1"
        self.assertEqual(self.manifest().returncode, 0)
        previous = json.loads((self.output / "build.json").read_text())
        previous.update(tag="v99.0.0", ref="refs/tags/v99.0.0", commit=OTHER_COMMIT,
                        workflow_run="https://github.com/RisPNG/miuutil/actions/runs/122",
                        source_date_epoch=1999999999)
        result = self.publish({"existing": False, "releases": {"latest-release": {
            "prerelease": False, "published_manifest": previous,
            "assets": [{"name": name} for name in ("build.json", "SHA256SUMS", "run.sh", self.archive.name)],
        }}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(command[1:4] == ["release", "upload", "latest-release"]
                            for command in self.commands()))

    def test_older_successful_tag_still_publishes_version_without_replacing_newer_alias(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        self.assertEqual(self.manifest().returncode, 0)
        previous = json.loads((self.output / "build.json").read_text())
        previous.update(tag="v0.2.0", ref="refs/tags/v0.2.0", commit=OTHER_COMMIT,
                        workflow_run="https://github.com/RisPNG/miuutil/actions/runs/200")
        result = self.publish({"existing": False, "releases": {"latest-release": {
            "prerelease": False, "published_manifest": previous,
            "assets": [{"name": name} for name in ("build.json", "SHA256SUMS", "run.sh", self.archive.name)],
        }}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any(command[1:4] == ["release", "upload", "v0.1.4"] for command in self.commands()))
        self.assertFalse(any(command[1:4] in (["release", "upload", "latest-release"],
                                            ["release", "edit", "latest-release"])
                             or command[1:2] == ["api"] for command in self.commands()))

    def test_old_tag_rerun_keeps_original_run_order_and_preserves_newer_alias(self):
        self.environment.update(GITHUB_REF="refs/tags/v0.1.4", GITHUB_RUN_ID="300")
        self.assertEqual(self.manifest().returncode, 0)
        original = json.loads((self.output / "build.json").read_text())
        original["workflow_run"] = "https://github.com/RisPNG/miuutil/actions/runs/100"
        previous = dict(original, tag="v0.2.0", ref="refs/tags/v0.2.0", commit=OTHER_COMMIT,
                        workflow_run="https://github.com/RisPNG/miuutil/actions/runs/200")
        result = self.publish({"published_manifest": original, "assets": [{"name": "build.json"}],
                               "releases": {"latest-release": {"prerelease": False,
                                            "published_manifest": previous,
                                            "assets": [{"name": name} for name in
                                                       ("build.json", "SHA256SUMS", "run.sh", self.archive.name)]}}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(any(command[1:3] in (["release", "upload"], ["release", "edit"])
                             or command[1:2] == ["api"] for command in self.commands()))

    def test_tag_rerun_repairs_alias_using_original_published_package_bytes(self):
        self.environment.update(GITHUB_REF="refs/tags/v0.1.4", GITHUB_RUN_ID="100")
        self.assertEqual(self.manifest().returncode, 0)
        original_record = json.loads((self.output / "build.json").read_text())
        saved = self.root / "immutable"
        shutil.copytree(self.output, saved)
        (self.root / "package/rebuild-proof").write_text("different native archive, unchanged package version\n")
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(self.root / "package"), str(self.archive)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.assertNotEqual(hashlib.sha256(self.archive.read_bytes()).hexdigest(), original_record["packages"][0]["sha256"])
        self.environment["GITHUB_RUN_ID"] = "300"
        result = self.publish({"published_manifest": original_record, "assets": [{"name": "build.json"}],
                               "files": {path.name: str(path) for path in saved.iterdir()}})
        self.assertEqual(result.returncode, 0, result.stderr)
        uploads = json.loads(self.stub_state.read_text())["uploads"]
        self.assertTrue(all(item["tag"] == "latest-release" for item in uploads))
        expected = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in saved.iterdir()}
        self.assertEqual({item["file"]: item["sha256"] for item in uploads}, expected)

    def test_matching_tag_rerun_repairs_partial_alias_asset_overwrite(self):
        self.environment.update(GITHUB_REF="refs/tags/v0.1.4", GITHUB_RUN_ID="100")
        self.assertEqual(self.manifest().returncode, 0)
        original_record = json.loads((self.output / "build.json").read_text())
        saved = self.root / "immutable"
        shutil.copytree(self.output, saved)
        (self.root / "package/partial-generation").write_text("same native version, different candidate build\n")
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(self.root / "package"), str(self.archive)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.launcher.write_text("#!/usr/bin/env bash\nprintf 'interrupted newer launcher\\n'\n")
        self.environment["GITHUB_RUN_ID"] = "300"
        result = self.publish({"published_manifest": original_record, "assets": [{"name": "build.json"}],
                               "files": {path.name: str(path) for path in saved.iterdir()},
                               "releases": {"latest-release": {
                                   "prerelease": False, "published_manifest": original_record,
                                   "assets": [{"name": name} for name in
                                              ("build.json", "SHA256SUMS", "run.sh", self.archive.name)],
                                   "files": {self.archive.name: str(self.archive),
                                             "run.sh": str(self.launcher),
                                             "SHA256SUMS": str(self.output / "SHA256SUMS")},
                               }}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("restoring its source build", result.stdout)
        uploads = json.loads(self.stub_state.read_text())["uploads"]
        self.assertTrue(all(item["tag"] == "latest-release" for item in uploads))
        expected = {path.name: hashlib.sha256(path.read_bytes()).hexdigest() for path in saved.iterdir()}
        self.assertEqual({item["file"]: item["sha256"] for item in uploads}, expected)

    def test_matching_tag_rerun_repairs_alias_reference_mismatch(self):
        self.environment.update(GITHUB_REF="refs/tags/v0.1.4", GITHUB_RUN_ID="300")
        self.assertEqual(self.manifest().returncode, 0)
        original = json.loads((self.output / "build.json").read_text())
        original["workflow_run"] = "https://github.com/RisPNG/miuutil/actions/runs/100"
        result = self.publish({"published_manifest": original, "assets": [{"name": "build.json"}],
                               "alias_commit": OTHER_COMMIT,
                               "releases": {"latest-release": {
                                   "prerelease": False, "published_manifest": original,
                                   "assets": [{"name": name} for name in
                                              ("build.json", "SHA256SUMS", "run.sh", self.archive.name)],
                               }}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("restoring its source build", result.stdout)
        uploads = json.loads(self.stub_state.read_text())["uploads"]
        self.assertTrue(all(item["tag"] == "latest-release" for item in uploads))
        update = next(command for command in self.commands() if command[1:2] == ["api"])
        self.assertIn("sha=" + COMMIT, update)

    def test_matching_rolling_alias_preserves_valid_original_bytes_after_rebuild(self):
        self.environment["GITHUB_RUN_ID"] = "100"
        self.assertEqual(self.manifest().returncode, 0)
        original_record = json.loads((self.output / "build.json").read_text())
        saved = self.root / "immutable"
        shutil.copytree(self.output, saved)
        (self.root / "package/rebuild-proof").write_text("same source commit with different rebuilt bytes\n")
        subprocess.run(["dpkg-deb", "--build", "--root-owner-group", str(self.root / "package"), str(self.archive)],
                       check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.environment["GITHUB_RUN_ID"] = "300"
        result = self.publish({"published_manifest": original_record,
                               "assets": [{"name": path.name} for path in saved.iterdir()],
                               "files": {path.name: str(path) for path in saved.iterdir()}})
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("leaving it unchanged", result.stdout)
        self.assertFalse(any(command[1:3] in (["release", "upload"], ["release", "edit"])
                             or command[1:2] == ["api"] for command in self.commands()))

    def test_published_source_tag_with_wrong_commit_cannot_promote_alias(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        result = self.publish({"published_commit": OTHER_COMMIT, "assets": [{"name": "build.json"}]})
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(command[1:3] in (["release", "upload"], ["release", "edit"])
                             or command[1:2] == ["api"] for command in self.commands()))

    def test_tag_move_during_alias_upload_preserves_previous_alias_manifest(self):
        self.environment["GITHUB_REF"] = "refs/tags/v0.1.4"
        result = self.publish({"existing": False, "heads": [COMMIT, COMMIT, OTHER_COMMIT]})
        self.assertNotEqual(result.returncode, 0)
        alias_uploads = [command for command in self.commands()
                         if command[1:4] == ["release", "upload", "latest-release"]]
        self.assertEqual(len(alias_uploads), 1)
        self.assertEqual(Path(alias_uploads[0][4]).name, self.archive.name)
        self.assertFalse(any(command[1:2] == ["api"] for command in self.commands()))

    def test_reserved_alias_tags_cannot_publish_as_version_releases(self):
        for name in ("latest-build", "latest-release"):
            with self.subTest(name=name):
                self.environment["GITHUB_REF"] = "refs/tags/" + name
                result = self.publish({})
                self.assertNotEqual(result.returncode, 0)
                self.assertEqual(self.commands(), [])


if __name__ == "__main__":
    unittest.main()
