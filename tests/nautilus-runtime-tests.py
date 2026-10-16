import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import pty
import select
import shlex
import signal
import subprocess
import sys
import tempfile
import time
import unittest
from unittest.mock import patch
from urllib.parse import urlsplit


sys.dont_write_bytecode = True
FIXTURE = sys.argv.pop(1)
SOURCE_HELPER = Path(__file__).resolve().parents[1] / "data/helpers/nautilus-actions.py"
NATIVE_DIRECTORIES = (
    Path("/usr/share/nautilus-python/extensions/actions-for-nautilus"),
    Path("/usr/local/share/nautilus-python/extensions/actions-for-nautilus"),
)
NATIVE_DIRECTORY = next((path for path in NATIVE_DIRECTORIES
                         if (path / "afn_shell_tools.py").is_file()), None)
GUI_BOUNDARY = '''import importlib.machinery
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import sys
from unittest.mock import MagicMock, patch

sys.dont_write_bytecode = True
helper_path, uri, command = sys.argv[1:]
loader = importlib.machinery.SourceFileLoader("account_nautilus_actions", helper_path)
helper = importlib.util.module_from_spec(importlib.util.spec_from_loader("account_nautilus_actions", loader))
loader.exec_module(helper)
original_popen = subprocess.Popen
children = []

def ask(arguments, **kwargs):
    assert arguments[:2] == ["/usr/bin/zenity", "--entry"], arguments
    return subprocess.CompletedProcess(arguments, 0, stdout=command + "\\n", stderr="")

def terminal(arguments, **kwargs):
    assert arguments[0] == "/usr/bin/blackbox-terminal", arguments
    Path(os.environ["HOME"], "terminal-arguments.json").write_text(json.dumps(arguments))
    shell_command = next(value.removeprefix("--command=") for value in arguments
                         if value.startswith("--command="))
    child = original_popen(["/bin/bash", "-c", shell_command], cwd=kwargs["cwd"])
    children.append(child)
    request = MagicMock()
    request.wait.return_value = 0
    return request

with patch.object(subprocess, "run", side_effect=ask), patch.object(subprocess, "Popen", side_effect=terminal):
    helper.perform("execute", [uri])
raise SystemExit(children[0].wait())
'''


class NautilusRuntimeTests(unittest.TestCase):
    def setUp(self):
        temporary = tempfile.TemporaryDirectory(prefix="miuutil-nautilus-runtime-")
        self.addCleanup(temporary.cleanup)
        self.root = Path(temporary.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.data = self.home / "data space 'single' \"double\" \\backslash $(literal) %U"
        self.helper = self.data / "miuutil/helpers/nautilus-actions.py"
        self.configuration = self.home / ".local/share/actions-for-nautilus/config.json"
        self.backups = self.root / "state/miuutil/backups/files-nautilus-actions"
        self.environment = {
            **os.environ,
            "HOME": str(self.home),
            "XDG_DATA_HOME": str(self.data),
            "XDG_CONFIG_HOME": str(self.root / "configuration"),
            "XDG_STATE_HOME": str(self.root / "state"),
            "XDG_CACHE_HOME": str(self.root / "cache"),
            "PYTHONDONTWRITEBYTECODE": "1",
            "TERM": "xterm-256color",
        }

    def configure(self, action):
        result = subprocess.run([FIXTURE, action], env=self.environment, check=True,
                                capture_output=True, text=True, timeout=10)
        report = json.loads(result.stdout)
        report["state"] = report["state"].rsplit("_", 1)[-1]
        return report

    def menu_commands(self):
        pending = list(json.loads(self.configuration.read_text())["actions"])
        commands = {}
        while pending:
            action = pending.pop()
            if action["type"] == "menu":
                pending.extend(action["actions"])
            else:
                self.assertFalse(action["use_shell"])
                self.assertFalse(action["use_v1_interpolation"])
                commands[action["label"]] = action["command_line"]
        return commands

    def run_menu_command(self):
        folder = self.home / "selected 'folder' $(literal) %U"
        folder.mkdir(exist_ok=True)
        (self.home / ".bashrc").write_text(
            "HISTFILE=\"$HOME/.bash_history\"\n"
            "shopt -s histappend\n"
            "alias report=runner_probe\n"
            "runner_probe() { printf '%s\\n' \"$PWD\" \"$@\" > result; return 23; }\n"
        )
        command = "report 'spaces; $(literal)' \"double 'quotes'\" $'line\\nbreak'"
        tokens = shlex.split(self.menu_commands()["Execute command here"])
        self.assertEqual(tokens, ["/usr/bin/python3", str(self.helper).replace("%", "%%"), "execute", "%U"])
        master, slave = pty.openpty()
        output = b""
        try:
            with subprocess.Popen([sys.executable, "-c", GUI_BOUNDARY,
                                   str(self.helper), folder.as_uri(), command],
                                  env=self.environment, stdin=slave, stdout=slave, stderr=slave,
                                  start_new_session=True) as process:
                try:
                    deadline = time.monotonic() + 10
                    while b"Press any key" not in output and time.monotonic() < deadline:
                        if select.select([master], [], [], 0.1)[0]:
                            output += os.read(master, 65536)
                    self.assertIn(b"Exit status: 23.", output)
                    self.assertIn(b"Press any key", output)
                    self.assertIsNone(process.poll())
                    self.assertEqual((folder / "result").read_text(),
                                     str(folder) + "\nspaces; $(literal)\ndouble 'quotes'\nline\nbreak\n")
                    self.assertIn(command, (self.home / ".bash_history").read_text())
                    arguments = json.loads((self.home / "terminal-arguments.json").read_text())
                    self.assertIn("--working-directory=" + str(folder), arguments)
                    os.write(master, b"x")
                    self.assertEqual(process.wait(timeout=5), 23)
                finally:
                    try:
                        os.killpg(process.pid, signal.SIGKILL)
                    except ProcessLookupError:
                        pass
                    process.wait()
        finally:
            os.close(master)
            os.close(slave)

    def test_catalogue_installs_durable_helper_and_quotes_every_menu_action(self):
        report = self.configure("apply")
        self.assertEqual(report["state"], "MATCHING")
        self.assertEqual(self.helper.read_bytes(), SOURCE_HELPER.read_bytes())
        self.assertFalse((self.data / "actions-for-nautilus/config.json").exists())
        commands = self.menu_commands()
        expected = {
            "Copy name": "copy-name", "Copy path": "copy-path", "Copy URI": "copy-uri",
            "Open in Terminal": "terminal", "Execute command here": "execute", "Open in Code": "code",
        }
        self.assertEqual(set(commands), set(expected))
        for label, action in expected.items():
            with self.subTest(action=action):
                self.assertEqual(shlex.split(commands[label]),
                                 ["/usr/bin/python3", str(self.helper).replace("%", "%%"), action, "%U"])
                self.assertNotIn(report["libexec"], commands[label])
                self.assertNotIn("$HELPER", commands[label])

    def test_missing_or_stale_helper_is_partial_and_reapply_backs_up_changes(self):
        self.configure("apply")
        original_menu = self.configuration.read_bytes()
        self.helper.unlink()
        self.assertEqual(self.configure("inspect")["state"], "PARTIAL")
        self.assertEqual(self.configure("apply")["state"], "MATCHING")
        self.helper.write_bytes(b"previous helper sentinel\n")
        self.assertEqual(self.configure("inspect")["state"], "PARTIAL")
        self.assertEqual(self.configure("apply")["state"], "MATCHING")
        helper_backups = list(self.backups.rglob("nautilus-actions.py"))
        self.assertTrue(any(path.read_bytes() == b"previous helper sentinel\n" for path in helper_backups))
        self.assertEqual(self.helper.read_bytes(), SOURCE_HELPER.read_bytes())
        self.assertEqual(self.configuration.read_bytes(), original_menu)
        personal_menu = b'{"actions":[],"personal":true}\n'
        self.configuration.write_bytes(personal_menu)
        self.assertEqual(self.configure("inspect")["state"], "PARTIAL")
        self.assertEqual(self.configure("apply")["state"], "MATCHING")
        self.assertEqual(self.configuration.read_bytes(), original_menu)
        self.assertTrue(any(path.read_bytes() == personal_menu for path in self.backups.rglob("config.json")))

    def test_menu_runs_after_temporary_package_helper_removal_and_restoration(self):
        package_helper = self.root / "package/libexec/miuutil/nautilus-actions.py"
        package_helper.parent.mkdir(parents=True)
        package_helper.write_bytes(b"temporary package helper sentinel\n")
        self.configuration.parent.mkdir(parents=True)
        self.configuration.write_text(json.dumps({"actions": [{
            "type": "command", "label": "Execute command here",
            "command_line": "/usr/bin/python3 " + shlex.quote(str(package_helper)) + " execute %U",
        }]}))
        self.assertEqual(self.configure("apply")["state"], "MATCHING")
        durable_bytes = self.helper.read_bytes()
        package_helper.unlink()
        self.run_menu_command()
        package_helper.write_bytes(b"restored package helper sentinel\n")
        self.run_menu_command()
        self.assertEqual(self.helper.read_bytes(), durable_bytes)
        self.assertEqual(self.configure("inspect")["state"], "MATCHING")

    @unittest.skipUnless(NATIVE_DIRECTORY, "Actions for Nautilus native parser is not installed")
    def test_installed_native_interpolation_resolves_durable_helper_and_selected_uri(self):
        self.configure("apply")
        loader = importlib.machinery.SourceFileLoader("afn_shell_tools", str(NATIVE_DIRECTORY / "afn_shell_tools.py"))
        native = importlib.util.module_from_spec(importlib.util.spec_from_loader("afn_shell_tools", loader))
        with patch.object(sys, "path", [str(NATIVE_DIRECTORY), *sys.path]):
            loader.exec_module(native)
        selected = self.home / "native selected 'folder' %U"
        selected.mkdir()
        files = [{"uri": urlsplit(selected.as_uri())}]
        for command in self.menu_commands().values():
            with self.subTest(command=command):
                arguments, _ = native.resolve2(native.tokenize_for_native(command), 0, files, False, None)
                self.assertEqual(arguments[0], "/usr/bin/python3")
                self.assertEqual(arguments[1], str(self.helper))
                self.assertEqual(arguments[3:], [selected.as_uri()])


if __name__ == "__main__":
    unittest.main()
