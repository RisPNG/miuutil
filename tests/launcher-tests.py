#!/usr/bin/env python3
import hashlib
import json
import os
from pathlib import Path
import shutil
import signal
import subprocess
import tempfile
import time
import unittest


LAUNCHER = Path(__file__).resolve().parents[1] / "run.sh"
STUB = r'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys
import time

root = Path(os.environ["MIUUTIL_LAUNCHER_FIXTURE"])
scenario = json.loads((root / "scenario.json").read_text())
state = json.loads((root / "state.json").read_text())
command = Path(sys.argv[0]).name
arguments = sys.argv[1:]
with (root / "events.jsonl").open("a") as log:
    log.write(json.dumps({"command": command, "arguments": arguments}) + "\n")

if command == "id":
    print(scenario.get("uid", 1000))
elif command == "gdbus":
    state["bus_calls"] = state.get("bus_calls", 0) + 1
    if state.get("external_app_open") and state.get("external_quit_requested") and (root / "allow-external-app-finish").exists():
        state["external_app_open"] = False
        with (root / "events.jsonl").open("a") as log:
            log.write(json.dumps({"command": "external-app-operation-finished", "arguments": []}) + "\n")
    (root / "state.json").write_text(json.dumps(state))
    external_owner = state.get("external_app_open") and not scenario.get("external_global_only")
    print("(true,)" if external_owner or scenario.get("active") or (scenario.get("opened_during_download") and state["bus_calls"] > 1) else "(false,)")
elif command == "pgrep":
    if state.get("external_app_open") and scenario.get("external_global_only") and (root / "allow-external-app-finish").exists():
        state["external_app_open"] = False
        (root / "state.json").write_text(json.dumps(state))
        with (root / "events.jsonl").open("a") as log:
            log.write(json.dumps({"command": "external-app-operation-finished", "arguments": []}) + "\n")
    if state.get("external_app_open") and scenario.get("external_global_only"):
        (root / "external-app-observed").touch()
    sys.exit(0 if state.get("external_app_open") else 1)
elif command == "gapplication":
    assert arguments == ["action", "com.rispeng.MiuUtil", "quit"]
    (root / "quit-requested").touch()
    if state.get("external_app_open"):
        state["external_quit_requested"] = True
        (root / "state.json").write_text(json.dumps(state))
elif command == "curl":
    address = next(value for value in arguments if value.startswith("https://"))
    destination = Path(arguments[arguments.index("-o") + 1])
    if address == "https://api.github.com/repos/RisPNG/miuutil":
        destination.write_text(json.dumps({"full_name": "RisPNG/miuutil", "default_branch": "main"}))
    elif "/commits/" in address:
        calls = state.get("head_calls", 0)
        heads = scenario["heads"]
        destination.write_text(json.dumps({"sha": heads[min(calls, len(heads) - 1)]}))
        state["head_calls"] = calls + 1
    elif address.endswith("/build.json"):
        calls = state.get("manifest_calls", 0)
        builds = scenario["builds"]
        state["build_index"] = min(calls, len(builds) - 1)
        destination.write_text(json.dumps(builds[state["build_index"]]))
        state["manifest_calls"] = calls + 1
        if scenario.get("publish_after_manifest") and calls == 0:
            state["publication_index"] = 1
    elif address.endswith("/SHA256SUMS"):
        generation = state.get("publication_index", state["build_index"])
        package = scenario["builds"][generation]["packages"][0]
        digest = "0" * 64 if scenario.get("wrong_checksums") else package["sha256"]
        destination.write_text(digest + "  " + package["file"] + "\n")
    else:
        name = address.rsplit("/", 1)[1]
        generation = state.get("publication_index", state["build_index"])
        published_package = scenario["builds"][generation]["packages"][0]["file"]
        if scenario.get("old_package_removed") and name != published_package:
            print("curl: (22) The requested package is no longer published: 404", file=sys.stderr)
            sys.exit(22)
        content = (root / "assets" / name).read_bytes()
        if scenario.get("corrupt_download"):
            content = b"!" + content[1:]
        destination.write_bytes(content)
    (root / "state.json").write_text(json.dumps(state))
elif command == "sleep":
    time.sleep(0.005)
elif command == "sudo":
    if arguments != ["-v"]:
        os.execvp(arguments[0], arguments)
elif command == "dpkg":
    if arguments == ["--print-architecture"]:
        print(scenario.get("architecture", "amd64"))
    elif arguments == ["--remove", "miuutil"]:
        if scenario.get("remove_fail"):
            sys.exit(2)
        state["installed"] = False
        state["version"] = ""
        (root / "state.json").write_text(json.dumps(state))
    else:
        raise SystemExit("Unexpected dpkg invocation")
elif command == "dpkg-query":
    if arguments[0] == "--show":
        if not state["installed"]:
            sys.exit(1)
        print("installed\t" + state["version"] + "\tamd64")
    elif arguments == ["--listfiles", "miuutil"]:
        time.sleep(scenario.get("listfiles_delay", 0))
        print(root / "bin" / "miuutil")
    else:
        raise SystemExit("Unexpected dpkg-query invocation")
elif command == "dpkg-deb":
    assert arguments[0] == "--field"
    package = json.loads(Path(arguments[1]).read_text())
    value = package[arguments[2]]
    if scenario.get("wrong_control") and "/previous/" not in arguments[1] and arguments[2] == "Package":
        value = "another-package"
    print(value)
elif command == "dpkg-repack":
    assert arguments == ["--tag=none", "miuutil"]
    package = {"Package": "miuutil", "Version": state["version"], "Architecture": "amd64", "files": state["files"]}
    Path("miuutil_" + state["version"] + "_amd64.deb").write_text(json.dumps(package))
elif command == "apt-mark":
    if arguments == ["showauto", "miuutil"]:
        if state["auto"]:
            print("miuutil")
    elif arguments == ["showhold", "miuutil"]:
        if state["held"]:
            print("miuutil")
    else:
        assert arguments[1] == "miuutil"
        assert arguments[0] in ("auto", "manual", "hold", "unhold")
        if arguments[0] in ("auto", "manual"):
            state["auto"] = arguments[0] == "auto"
        else:
            state["held"] = arguments[0] == "hold"
        (root / "state.json").write_text(json.dumps(state))
elif command == "apt-get":
    if arguments == ["update"]:
        if scenario.get("opened_during_preparation"):
            state["external_app_open"] = True
            (root / "state.json").write_text(json.dumps(state))
        sys.exit(0)
    assert "install" in arguments and "--no-remove" in arguments
    target = arguments[-1]
    if target == "dpkg-repack":
        os.symlink(root / "command-stub", root / "bin" / "dpkg-repack")
        sys.exit(0)
    restoring = "/previous/" in target
    if restoring and scenario.get("restore_fail"):
        sys.exit(100)
    if scenario.get("install_wait") and not restoring:
        (root / "install-started").touch()
        while not (root / "allow-install-finish").exists():
            time.sleep(0.01)
    package = json.loads(Path(target).read_text())
    if state["installed"] and state["version"] == package["Version"] and "--reinstall" not in arguments:
        sys.exit(0)
    state.update(installed=True, version=package["Version"], files=package["files"], auto=False, held=False)
    if scenario.get("opened_during_install") and not restoring:
        state["external_app_open"] = True
        (root / "external-app-started").touch()
    (root / "state.json").write_text(json.dumps(state))
    if scenario.get("install_fail") and not restoring:
        sys.exit(100)
elif command == "miuutil":
    (root / "app-started").touch()
    (root / "app-installed-files").write_text(state["files"])
    desired = root / "home" / ".config" / "miuutil" / "applied-setting"
    desired.parent.mkdir(parents=True, exist_ok=True)
    desired.write_text("user-selected outcome")
    if scenario.get("app_wait"):
        while not (root / "quit-requested").exists():
            time.sleep(0.01)
        time.sleep(0.05)
    with (root / "events.jsonl").open("a") as log:
        log.write(json.dumps({"command": "app-operation-finished", "arguments": []}) + "\n")
    sys.exit(scenario.get("app_result", 0))
else:
    raise SystemExit("Unexpected stub command: " + command)
'''


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.workspace = tempfile.TemporaryDirectory(prefix="miuutil-launcher-test-")
        self.addCleanup(self.workspace.cleanup)
        self.root = Path(self.workspace.name)
        for name in ("bin", "home", "assets", "state"):
            (self.root / name).mkdir()
        stub = self.root / "command-stub"
        stub.write_text(STUB)
        stub.chmod(0o755)
        for name in ("id", "curl", "dpkg", "dpkg-query", "dpkg-deb", "dpkg-repack", "apt-get", "apt-mark", "sudo", "gdbus", "gapplication", "pgrep", "sleep", "miuutil"):
            (self.root / "bin" / name).symlink_to(stub)
        for name in ("python3", "mkdir", "mktemp", "flock", "stat", "sha256sum", "rm"):
            (self.root / "bin" / name).symlink_to(shutil.which(name))
        self.scenario = {"heads": ["a" * 40], "builds": [self.build("a" * 40)]}
        self.initial = {"installed": False, "version": "", "files": "original modified installation", "auto": False, "held": False}
        self.personal = self.root / "home" / "personal-profile"
        self.personal.write_bytes(b"sign-in, bookmarks and extensions fixture\x00\xff")
        self.environment = os.environ | {
            "PATH": str(self.root / "bin"),
            "HOME": str(self.root / "home"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "MIUUTIL_LAUNCHER_FIXTURE": str(self.root),
        }

    def build(self, commit):
        version = "0.1.4-1+git20261009120000." + commit[:12]
        filename = "miuutil_" + version + "_amd64.deb"
        content = json.dumps({"Package": "miuutil", "Version": version, "Architecture": "amd64", "files": "new files for " + commit}).encode()
        (self.root / "assets" / filename).write_bytes(content)
        return {
            "schema": 1, "repository": "RisPNG/miuutil", "commit": commit,
            "ref": "refs/heads/main", "tag": "latest-build", "source_date_epoch": 1791547200,
            "workflow_run": "https://github.com/RisPNG/miuutil/actions/runs/12345",
            "packages": [{"file": filename, "package": "miuutil", "version": version, "architecture": "amd64", "sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)}],
        }

    def start(self):
        (self.root / "scenario.json").write_text(json.dumps(self.scenario))
        (self.root / "state.json").write_text(json.dumps(self.initial))
        process = subprocess.Popen(["/bin/bash", str(LAUNCHER)], env=self.environment, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, start_new_session=True)
        self.addCleanup(self.stop_process, process)
        return process

    def stop_process(self, process):
        if process.poll() is None:
            (self.root / "quit-requested").touch()
            (self.root / "allow-install-finish").touch()
            (self.root / "allow-external-app-finish").touch()
            process.terminate()
            try:
                process.communicate(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(process.pid, signal.SIGKILL)
                process.communicate(timeout=5)

    def finish(self, process, expected=0):
        output, error = process.communicate(timeout=15)
        self.assertEqual(process.returncode, expected, output + error)
        self.assertEqual(self.personal.read_bytes(), b"sign-in, bookmarks and extensions fixture\x00\xff")
        return output, error

    def events(self):
        path = self.root / "events.jsonl"
        return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []

    def state(self):
        return json.loads((self.root / "state.json").read_text())

    def await_marker(self, marker):
        deadline = time.monotonic() + 5
        while not (self.root / marker).exists():
            if time.monotonic() >= deadline:
                self.fail("Launcher did not reach " + marker)
            time.sleep(0.01)

    def sessions(self):
        return [path for path in (self.root / "state" / "miuutil" / "launcher").glob("session.*") if path.is_dir()]

    def test_new_install_is_removed_without_reverting_setup(self):
        self.finish(self.start())
        self.assertFalse(self.state()["installed"])
        self.assertEqual(self.sessions(), [])
        events = self.events()
        self.assertIn({"command": "dpkg", "arguments": ["--remove", "miuutil"]}, events)
        self.assertFalse(any("purge" in event["arguments"] or "autoremove" in event["arguments"] for event in events))
        self.assertEqual((self.root / "home" / ".config" / "miuutil" / "applied-setting").read_text(), "user-selected outcome")

    def test_existing_modified_package_and_selections_are_restored(self):
        self.initial.update(installed=True, version="0.1.2-1", auto=True, held=True)
        self.finish(self.start())
        for field in ("installed", "version", "files", "auto", "held"):
            self.assertEqual(self.state()[field], self.initial[field], field)
        self.assertIn({"command": "dpkg-repack", "arguments": ["--tag=none", "miuutil"]}, self.events())
        self.assertEqual(self.sessions(), [])

    def test_manual_unheld_package_is_restored(self):
        self.initial.update(installed=True, version="0.1.3-1")
        self.finish(self.start())
        self.assertFalse(self.state()["auto"])
        self.assertFalse(self.state()["held"])
        self.assertIn({"command": "apt-mark", "arguments": ["manual", "miuutil"]}, self.events())
        self.assertIn({"command": "apt-mark", "arguments": ["unhold", "miuutil"]}, self.events())

    def test_same_version_runs_verified_build_and_restores_modified_files(self):
        self.initial.update(installed=True, version=self.scenario["builds"][0]["packages"][0]["version"])
        self.finish(self.start())
        self.assertEqual((self.root / "app-installed-files").read_text(), "new files for " + "a" * 40)
        self.assertEqual(self.state()["files"], self.initial["files"])

    def test_missing_repack_tool_is_installed_before_backup(self):
        (self.root / "bin" / "dpkg-repack").unlink()
        self.initial.update(installed=True, version="0.1.3-1")
        self.finish(self.start())
        events = self.events()
        bootstrap = next(index for index, event in enumerate(events) if event["command"] == "apt-get" and event["arguments"][-1] == "dpkg-repack")
        repack = next(index for index, event in enumerate(events) if event["command"] == "dpkg-repack")
        self.assertLess(bootstrap, repack)
        self.assertEqual(self.state()["version"], "0.1.3-1")

    def test_stale_manifest_waits_for_exact_head(self):
        self.scenario["builds"] = [self.build("0" * 40), self.build("a" * 40)]
        output, _ = self.finish(self.start())
        self.assertIn("Waiting for the latest build", output)
        installs = [event for event in self.events() if event["command"] == "apt-get" and "install" in event["arguments"]]
        self.assertEqual(len(installs), 1)
        self.assertIn("aaaaaaaaaaaa", installs[0]["arguments"][-1])

    def test_skipped_old_commit_refreshes_head_while_waiting(self):
        self.scenario["heads"] = ["a" * 40, "b" * 40]
        self.scenario["builds"] = [self.build("b" * 40)]
        output, _ = self.finish(self.start())
        installs = [event for event in self.events() if event["command"] == "apt-get" and "install" in event["arguments"]]
        self.assertEqual(len(installs), 1)
        self.assertIn("bbbbbbbbbbbb", installs[0]["arguments"][-1])
        self.assertEqual(output.count("Waiting for the latest build"), 6)

    def test_head_that_moves_during_download_is_resolved_again(self):
        self.scenario["heads"] = ["a" * 40, "b" * 40]
        self.scenario["builds"] = [self.build("a" * 40), self.build("b" * 40)]
        self.finish(self.start())
        installs = [event for event in self.events() if event["command"] == "apt-get" and "install" in event["arguments"]]
        self.assertEqual(len(installs), 1)
        self.assertIn("bbbbbbbbbbbb", installs[0]["arguments"][-1])

    def test_checksums_replaced_after_manifest_retry_the_new_head(self):
        self.scenario = {
            "heads": ["a" * 40, "b" * 40],
            "builds": [self.build("a" * 40), self.build("b" * 40)],
            "publish_after_manifest": True,
        }
        _, error = self.finish(self.start())
        self.assertIn("SHA256SUMS does not agree", error)
        installs = [event for event in self.events() if event["command"] == "apt-get" and "install" in event["arguments"]]
        self.assertEqual(len(installs), 1)
        self.assertIn("bbbbbbbbbbbb", installs[0]["arguments"][-1])
        self.assertEqual(json.loads((self.root / "state.json").read_text())["manifest_calls"], 2)

    def test_removed_old_package_retries_the_new_publication(self):
        self.scenario = {
            "heads": ["a" * 40, "b" * 40],
            "builds": [self.build("a" * 40), self.build("b" * 40)],
            "publish_after_manifest": True,
            "old_package_removed": True,
        }
        _, error = self.finish(self.start())
        self.assertIn("404", error)
        installs = [event for event in self.events() if event["command"] == "apt-get" and "install" in event["arguments"]]
        self.assertEqual(len(installs), 1)
        self.assertIn("bbbbbbbbbbbb", installs[0]["arguments"][-1])
        self.assertEqual(self.sessions(), [])

    def test_failed_publication_download_with_unchanged_head_never_installs(self):
        self.scenario = {
            "heads": ["a" * 40],
            "builds": [self.build("a" * 40), self.build("b" * 40)],
            "publish_after_manifest": True,
            "old_package_removed": True,
        }
        self.finish(self.start(), 22)
        self.assertFalse(any(event["command"] == "sudo" for event in self.events()))
        self.assertEqual(self.state()["head_calls"], 2)
        self.assertEqual(self.sessions(), [])

    def test_provenance_checksums_and_control_mismatch_never_install(self):
        for issue in ("wrong_checksums", "corrupt_download", "wrong_control", "wrong_repository"):
            with self.subTest(issue=issue):
                self.scenario = {"heads": ["a" * 40], "builds": [self.build("a" * 40)]}
                if issue == "wrong_repository":
                    self.scenario["builds"][0]["repository"] = "another/project"
                else:
                    self.scenario[issue] = True
                (self.root / "events.jsonl").unlink(missing_ok=True)
                process = self.start()
                output, error = process.communicate(timeout=15)
                self.assertNotEqual(process.returncode, 0, output + error)
                self.assertFalse(any(event["command"] == "sudo" for event in self.events()))
                self.assertEqual(self.sessions(), [])

    def test_active_or_newly_opened_application_is_not_replaced(self):
        for issue in ("active", "opened_during_download"):
            with self.subTest(issue=issue):
                self.scenario = {"heads": ["a" * 40], "builds": [self.build("a" * 40)], issue: True}
                (self.root / "events.jsonl").unlink(missing_ok=True)
                self.finish(self.start(), 1)
                self.assertFalse(any(event["command"] == "sudo" for event in self.events()))

    def test_application_opened_during_preparation_is_not_replaced(self):
        self.initial.update(installed=True, version="0.1.3-1", auto=True, held=True)
        self.scenario["opened_during_preparation"] = True
        self.finish(self.start(), 1)
        for field in ("installed", "version", "files", "auto", "held"):
            self.assertEqual(self.state()[field], self.initial[field], field)
        self.assertTrue(self.state()["external_app_open"])
        self.assertFalse((self.root / "app-started").exists())
        self.assertFalse(any(event["command"] == "apt-get" and "install" in event["arguments"] for event in self.events()))
        self.assertFalse(any(event["command"] == "gapplication" for event in self.events()))
        self.assertEqual(self.sessions(), [])

    def test_application_opened_during_install_finishes_before_restoration(self):
        self.initial.update(installed=True, version="0.1.3-1", auto=True, held=True)
        self.scenario["opened_during_install"] = True
        process = self.start()
        self.await_marker("quit-requested")
        self.assertIsNone(process.poll())
        self.assertFalse((self.root / "app-started").exists())
        self.assertFalse(any(event["command"] == "apt-get" and "/previous/" in event["arguments"][-1] for event in self.events()))
        (self.root / "allow-external-app-finish").touch()
        self.finish(process, 1)
        for field in ("installed", "version", "files", "auto", "held"):
            self.assertEqual(self.state()[field], self.initial[field], field)
        commands = [event["command"] for event in self.events()]
        restore = next(index for index, event in enumerate(self.events()) if event["command"] == "apt-get" and "/previous/" in event["arguments"][-1])
        self.assertLess(commands.index("external-app-operation-finished"), restore)
        self.assertEqual(self.sessions(), [])

    def test_other_account_instance_opened_during_install_is_allowed_to_finish(self):
        self.scenario.update(opened_during_install=True, external_global_only=True, listfiles_delay=0.25)
        process = self.start()
        self.await_marker("external-app-started")
        self.await_marker("external-app-observed")
        self.assertIsNone(process.poll())
        self.assertFalse((self.root / "app-started").exists())
        self.assertFalse(any(event["command"] == "gapplication" for event in self.events()))
        self.assertFalse(any(event["command"] == "dpkg" and "--remove" in event["arguments"] for event in self.events()))
        (self.root / "allow-external-app-finish").touch()
        self.finish(process, 1)
        commands = [event["command"] for event in self.events()]
        removal = next(index for index, event in enumerate(self.events()) if event["command"] == "dpkg" and "--remove" in event["arguments"])
        self.assertLess(commands.index("external-app-operation-finished"), removal)
        self.assertFalse(self.state()["installed"])
        self.assertEqual(self.sessions(), [])

    def test_root_and_unsupported_architecture_are_rejected(self):
        for issue, value in (("uid", 0), ("architecture", "arm64")):
            with self.subTest(issue=issue):
                self.scenario = {"heads": ["a" * 40], "builds": [self.build("a" * 40)], issue: value}
                (self.root / "events.jsonl").unlink(missing_ok=True)
                self.finish(self.start(), 1)
                self.assertFalse(any(event["command"] in ("curl", "sudo") for event in self.events()))

    def test_signals_wait_for_native_quit_before_cleanup(self):
        for interruption in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            with self.subTest(signal=interruption):
                self.scenario = {"heads": ["a" * 40], "builds": [self.build("a" * 40)], "app_wait": True}
                for name in ("events.jsonl", "app-started", "quit-requested"):
                    (self.root / name).unlink(missing_ok=True)
                process = self.start()
                self.await_marker("app-started")
                os.killpg(process.pid, interruption)
                self.finish(process, 128 + interruption)
                commands = [event["command"] for event in self.events()]
                self.assertLess(commands.index("gapplication"), commands.index("app-operation-finished"))
                removal = next(index for index, event in enumerate(self.events()) if event["command"] == "dpkg" and event["arguments"][0] == "--remove")
                self.assertLess(commands.index("app-operation-finished"), removal)
                self.assertFalse(self.state()["installed"])

    def test_signal_during_install_waits_for_transaction_then_removes(self):
        self.scenario["install_wait"] = True
        process = self.start()
        self.await_marker("install-started")
        os.killpg(process.pid, signal.SIGTERM)
        time.sleep(0.05)
        self.assertIsNone(process.poll())
        self.assertFalse(any(event["command"] == "dpkg" and "--remove" in event["arguments"] for event in self.events()))
        (self.root / "allow-install-finish").touch()
        self.finish(process, 143)
        self.assertFalse(self.state()["installed"])
        self.assertFalse((self.root / "app-started").exists())

    def test_interrupted_install_waits_for_externally_opened_application(self):
        self.initial.update(installed=True, version="0.1.3-1", auto=True, held=True)
        self.scenario.update(install_wait=True, opened_during_install=True)
        process = self.start()
        self.await_marker("install-started")
        os.killpg(process.pid, signal.SIGTERM)
        (self.root / "allow-install-finish").touch()
        self.await_marker("quit-requested")
        self.assertIsNone(process.poll())
        self.assertFalse((self.root / "app-started").exists())
        self.assertFalse(any(event["command"] == "apt-get" and "/previous/" in event["arguments"][-1] for event in self.events()))
        (self.root / "allow-external-app-finish").touch()
        self.finish(process, 143)
        for field in ("installed", "version", "files", "auto", "held"):
            self.assertEqual(self.state()[field], self.initial[field], field)
        self.assertEqual(self.sessions(), [])

    def test_failed_install_restores_existing_package(self):
        self.initial.update(installed=True, version="0.1.3-1", auto=True)
        self.scenario["install_fail"] = True
        self.finish(self.start(), 100)
        for field in ("installed", "version", "files", "auto", "held"):
            self.assertEqual(self.state()[field], self.initial[field], field)

    def test_application_failure_still_cleans_up(self):
        self.scenario["app_result"] = 17
        self.finish(self.start(), 17)
        self.assertFalse(self.state()["installed"])
        self.assertEqual(self.sessions(), [])

    def test_failed_restore_keeps_native_recovery_archive(self):
        self.initial.update(installed=True, version="0.1.3-1")
        self.scenario["restore_fail"] = True
        _, error = self.finish(self.start(), 1)
        self.assertIn("Package cleanup failed", error)
        sessions = self.sessions()
        self.assertEqual(len(sessions), 1)
        backups = list((sessions[0] / "previous").glob("*.deb"))
        self.assertEqual(len(backups), 1)
        self.assertEqual(json.loads(backups[0].read_text())["files"], self.initial["files"])
        record = json.loads((sessions[0] / "session.json").read_text())
        self.assertEqual(record["previous_version"], self.initial["version"])


if __name__ == "__main__":
    unittest.main()
