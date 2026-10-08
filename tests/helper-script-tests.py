import importlib.machinery
import importlib.util
import io
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch
from xml.etree import ElementTree

sys.dont_write_bytecode = True
HELPERS = Path(__file__).resolve().parents[1] / "data/helpers"


def load_script(name):
    loader = importlib.machinery.SourceFileLoader(name, str(HELPERS / name))
    module = importlib.util.module_from_spec(importlib.util.spec_from_loader(name, loader))
    loader.exec_module(module)
    return module


history = load_script("deduplicate-history.py")
snapshot = load_script("apt-pre-snapshot")
nautilus = load_script("nautilus-actions.py")
shortcut = load_script("gnome-shortcut-helper")


class DDCMonitorCommands:
    def __init__(self, controls, report=None, failures=None, readback=None, unsupported_stderr=None):
        self.controls = controls
        self.failures = failures or {}
        self.readback = readback or {}
        self.unsupported_stderr = unsupported_stderr or {}
        self.values = {(selector, code): maximum // 2
                       for selector, features in controls.items()
                       for code, maximum in features.items()}
        self.writes = []
        self.reads = []
        if report is None:
            report = "".join(f"Display {number}\n" +
                             (f"   I2C bus: /dev/i2c-{selector[1]}\n"
                              if selector[0] == "--bus" else "   Monitor: Mock display\n")
                             for number, selector in enumerate(controls, 1))
        self.report = report

    def __call__(self, arguments, **kwargs):
        if arguments[0] != "/usr/bin/ddcutil":
            raise AssertionError(f"Unexpected command: {arguments}")
        arguments = arguments[1:]
        if arguments == ["detect", "--brief"]:
            return subprocess.CompletedProcess(arguments, 0, self.report, "")
        selector = tuple(arguments[:2])
        command = arguments[2]
        features = self.controls[selector]
        if command == "getvcp":
            terse = arguments[-1] == "--terse"
            codes = arguments[3:-1] if terse else arguments[3:]
            self.reads.append((selector, tuple(codes), terse))
            failure = self.failures.get((selector, "getvcp"))
            if failure:
                return subprocess.CompletedProcess(arguments, 1, "", failure)
            lines = []
            diagnostics = []
            unsupported = False
            for code in codes:
                if code not in features:
                    unsupported = True
                    suffix = self.unsupported_stderr.get((selector, code))
                    line = f"VCP code 0x{code.upper()} (Mock control): Unsupported feature code"
                    if suffix:
                        diagnostics.append(f"{line} {suffix}\n")
                    else:
                        lines.append(f"{line}\n")
                elif terse:
                    current = self.readback.get((selector, code), self.values[selector, code])
                    lines.append(f"VCP {code.upper()} C {current} {features[code]}\n")
                else:
                    lines.append(f"VCP code 0x{code.upper()} (Mock control): "
                                 f"current value = {self.values[selector, code]}, max value = {features[code]}\n")
            return subprocess.CompletedProcess(arguments, int(unsupported), "".join(lines), "".join(diagnostics))
        if command == "setvcp":
            code, value = arguments[3], int(arguments[4])
            if arguments[5:] != ["--verify"]:
                raise AssertionError(f"Unverified write: {arguments}")
            self.writes.append((selector, code, value))
            failure = self.failures.get((selector, code))
            if failure:
                return subprocess.CompletedProcess(arguments, 1, "", failure)
            if code not in features:
                raise AssertionError(f"Unsupported control written: {arguments}")
            self.values[selector, code] = value
            return subprocess.CompletedProcess(arguments, 0, "", "")
        raise AssertionError(f"Unexpected DDC command: {arguments}")


class HelperScriptTest(unittest.TestCase):
    def test_brightness_zero_updates_every_control_and_unique_monitor(self):
        controls = {code: 100 for code in ("10", "12", "16", "18", "1a")}
        first, second = ("--bus", "6"), ("--display", "2")
        commands = DDCMonitorCommands({first: controls, second: controls}, report=
                                     "Display 1\n   I2C bus: /dev/i2c-6\n"
                                     "Display 2\n   Monitor: Mock display without bus details\n"
                                     "Display 3\n   I2C bus: /dev/i2c-6\n")
        with tempfile.TemporaryDirectory() as runtime, \
                patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                patch.object(shortcut.subprocess, "run", side_effect=commands):
            shortcut.brightness(0)
        self.assertCountEqual(commands.writes, [(selector, code, 0)
                                              for selector in (first, second) for code in controls])
        self.assertEqual({value for value in commands.values.values()}, {0})

    def test_brightness_hundred_restores_contrast_and_colour_gains(self):
        selector = ("--bus", "6")
        commands = DDCMonitorCommands({selector: {code: 100 for code in ("10", "12", "16", "18", "1a")}})
        with tempfile.TemporaryDirectory() as runtime, \
                patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                patch.object(shortcut.subprocess, "run", side_effect=commands):
            shortcut.brightness(100)
        self.assertCountEqual(commands.writes, [(selector, "10", 100), (selector, "12", 75),
                                              (selector, "16", 100), (selector, "18", 100),
                                              (selector, "1a", 100)])

    def test_brightness_scales_each_monitors_native_control_ranges(self):
        first, second = ("--bus", "6"), ("--bus", "7")
        controls = {first: {"10": 255, "12": 254, "16": 65535, "18": 80, "1a": 1023},
                    second: {"10": 80, "12": 101, "16": 200, "18": 255, "1a": 50}}
        for percent in (0, 100):
            with self.subTest(percent=percent):
                commands = DDCMonitorCommands(controls)
                with tempfile.TemporaryDirectory() as runtime, \
                        patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                        patch.object(shortcut.subprocess, "run", side_effect=commands):
                    shortcut.brightness(percent)
                expected = ([(first, "10", 255), (first, "12", 191), (first, "16", 65535),
                             (first, "18", 80), (first, "1a", 1023), (second, "10", 80),
                             (second, "12", 76), (second, "16", 200), (second, "18", 255),
                             (second, "1a", 50)] if percent else
                            [(selector, code, 0) for selector, features in controls.items() for code in features])
                self.assertCountEqual(commands.writes, expected)

    def test_brightness_skips_only_controls_unsupported_by_each_monitor(self):
        first, second = ("--bus", "6"), ("--bus", "7")
        commands = DDCMonitorCommands({first: {"10": 100, "12": 100},
                                       second: {"10": 255, "16": 100, "18": 100, "1a": 100}})
        with tempfile.TemporaryDirectory() as runtime, \
                patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                patch.object(shortcut.subprocess, "run", side_effect=commands):
            shortcut.brightness(100)
        self.assertCountEqual(commands.writes, [(first, "10", 100), (first, "12", 75),
                                              (second, "10", 255), (second, "16", 100),
                                              (second, "18", 100), (second, "1a", 100)])
        for selector, codes, terse in commands.reads:
            if terse:
                self.assertEqual(set(codes), set(commands.controls[selector]))

    def test_brightness_accepts_unsupported_diagnostics_on_stderr(self):
        selector = ("--bus", "6")
        for percent in (0, 100):
            with self.subTest(percent=percent):
                commands = DDCMonitorCommands({selector: {"10": 255}}, unsupported_stderr={
                    (selector, "12"): "(Null response)",
                    (selector, "16"): "(All zero response)",
                    (selector, "18"): "(EIO)"})
                with tempfile.TemporaryDirectory() as runtime, \
                        patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                        patch.object(shortcut.subprocess, "run", side_effect=commands):
                    shortcut.brightness(percent)
                self.assertEqual(commands.writes, [(selector, "10", 255 if percent else 0)])
                self.assertEqual(commands.reads[-1], (selector, ("10",), True))

    def test_brightness_reports_failures_after_updating_other_controls_and_displays(self):
        first, second, broken = ("--bus", "6"), ("--bus", "7"), ("--bus", "8")
        controls = {code: 100 for code in ("10", "12", "16", "18", "1a")}
        commands = DDCMonitorCommands({first: controls, second: controls, broken: controls},
                                       failures={(first, "12"): "Contrast write failed",
                                                 (broken, "getvcp"): "Display communication failed"})
        with tempfile.TemporaryDirectory() as runtime, \
                patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                patch.object(shortcut.subprocess, "run", side_effect=commands):
            with self.assertRaises(RuntimeError) as failure:
                shortcut.brightness(0)
        self.assertIn("Contrast write failed", str(failure.exception))
        self.assertIn("Display communication failed", str(failure.exception))
        self.assertCountEqual(commands.writes, [(selector, code, 0)
                                              for selector in (first, second) for code in controls])
        self.assertEqual(commands.values[first, "12"], 50)
        for selector in (first, second):
            for code in controls:
                if (selector, code) != (first, "12"):
                    self.assertEqual(commands.values[selector, code], 0)
        self.assertTrue(all(commands.values[broken, code] == 50 for code in controls))

    def test_brightness_rejects_a_successful_write_with_different_readback(self):
        first, second = ("--bus", "6"), ("--bus", "7")
        controls = {code: 100 for code in ("10", "12", "16", "18", "1a")}
        commands = DDCMonitorCommands({first: controls, second: controls}, readback={(first, "16"): 32})
        with tempfile.TemporaryDirectory() as runtime, \
                patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                patch.object(shortcut.subprocess, "run", side_effect=commands):
            with self.assertRaises(RuntimeError):
                shortcut.brightness(0)
        self.assertCountEqual(commands.writes, [(selector, code, 0)
                                              for selector in (first, second) for code in controls])

    def test_brightness_without_displays_does_not_write_controls(self):
        commands = DDCMonitorCommands({}, report="No DDC/CI displays found.\n")
        with tempfile.TemporaryDirectory() as runtime, \
                patch.dict(os.environ, {"XDG_RUNTIME_DIR": runtime}), \
                patch.object(shortcut.subprocess, "run", side_effect=commands):
            with self.assertRaisesRegex(RuntimeError, "No DDC/CI displays found"):
                shortcut.brightness(0)
        self.assertEqual(commands.writes, [])
        self.assertEqual(commands.reads, [])

    def test_policy_separates_apply_and_read_only_inspection(self):
        policy = ElementTree.parse(HELPERS.parent / "com.rispeng.MiuUtil.policy.in")
        actions = {action.attrib["id"]: action for action in policy.findall("action")}
        apply = actions["com.rispeng.MiuUtil.apply"]
        inspect = actions["com.rispeng.MiuUtil.inspect"]
        self.assertEqual(apply.find("defaults/allow_active").text, "auth_admin_keep")
        self.assertEqual(inspect.find("defaults/allow_active").text, "yes")
        for action, argument in [(apply, "--apply"), (inspect, "--inspect")]:
            annotations = {item.attrib["key"]: item.text for item in action.findall("annotate")}
            self.assertEqual(annotations["org.freedesktop.policykit.exec.argv1"], argument)
            self.assertEqual(annotations["org.freedesktop.policykit.exec.path"], "@HELPER_PATH@")

    @unittest.skipUnless(os.environ.get("MIUUTIL_TEST_HELPER"), "The compiled helper path is supplied by Meson")
    def test_helper_rejects_implicit_apply_extra_arguments_and_shell_input(self):
        helper = os.environ["MIUUTIL_TEST_HELPER"]
        for arguments in [["apps-copyq"], ["--inspect", "apps-copyq", "--apply"],
                          ["--apply", "apps-copyq; touch /tmp/should-not-exist"], ["--shell", "apps-copyq"]]:
            result = subprocess.run([helper, *arguments], capture_output=True, text=True)
            self.assertNotEqual(result.returncode, 0)

    def test_history_keeps_newest_duplicate_with_timestamp(self):
        self.assertEqual(history.deduplicate(b"#1\necho a\n#2\necho b\n#3\necho a\n"),
                         b"#2\necho b\n#3\necho a\n")

    def test_history_keeps_multiline_commands_together(self):
        self.assertEqual(history.deduplicate(b"#1\necho a\necho b\n#2\necho x\n#3\necho a\necho b\n"),
                         b"#2\necho x\n#3\necho a\necho b\n")

    def test_legacy_history_without_timestamps(self):
        self.assertEqual(history.deduplicate(b"echo a\necho b\necho a\n"), b"echo b\necho a\n")

    def test_nautilus_rejects_remote_paths_and_shell_shaped_filenames_are_data(self):
        with self.assertRaises(ValueError):
            nautilus.local_path("file://remote.example/home/user")
        with self.assertRaises(ValueError):
            nautilus.local_path("https://example.com/home/user")
        self.assertEqual(nautilus.copy_values("copy-name", ["file:///home/user/$(touch%20bad).txt"]),
                         "$(touch bad).txt")

    def test_snapshot_failure_stops_package_transaction(self):
        class SystemFile:
            def __init__(self, path):
                self.path = path

            def exists(self):
                return True

            def read_text(self):
                return '{"btrfs_mode":"true"}' if self.path.endswith("json") else "root=UUID=test"

        transaction = "VERSION 2\n\npkg 1 < 2 /tmp/pkg.deb\n"
        with patch.object(snapshot, "Path", SystemFile), \
                patch.object(snapshot.os, "fdopen", return_value=io.StringIO(transaction)), \
                patch.object(snapshot.subprocess, "check_output", return_value="btrfs /@\n"), \
                patch.object(snapshot.subprocess, "run", side_effect=subprocess.CalledProcessError(1, "timeshift")) as run:
            with self.assertRaises(subprocess.CalledProcessError):
                snapshot.main()
            self.assertIn("--create", run.call_args.args[0])
            self.assertEqual(run.call_args.args[0][run.call_args.args[0].index("--tags") + 1], "D")
            self.assertTrue(run.call_args.kwargs["check"])

    def test_snapshot_preview_does_not_create_nested_apt_snapshot(self):
        class SystemFile:
            def __init__(self, path):
                self.path = path

            def exists(self):
                return True

            def read_text(self):
                return '{"btrfs_mode":"true"}' if self.path.endswith("json") else "root=UUID=test overlayroot=tmpfs:recurse=0"

        with patch.object(snapshot, "Path", SystemFile), \
                patch.object(snapshot.os, "fdopen", return_value=io.StringIO("VERSION 2\n\npkg 1 < 2 /tmp/pkg.deb\n")), \
                patch.object(snapshot.subprocess, "run") as run:
            snapshot.main()
            run.assert_not_called()


if __name__ == "__main__":
    unittest.main()
