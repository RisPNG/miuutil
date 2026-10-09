#!/usr/bin/python3
"""Local context-menu helpers; filenames arrive as URI arguments, never shell code."""
import argparse
import html
import os
from pathlib import Path
import subprocess
import sys
import tempfile
from urllib.parse import unquote_to_bytes, urlsplit

COMMAND_RUNNER = r'''
builtin history -s "$1"
if declare -F _bash_history_sync >/dev/null; then
    _bash_history_sync
else
    builtin history -a
fi
( builtin eval -- "$1" )
_action_status=$?
printf '\nExit status: %s.\nPress any key to close this tab...' "$_action_status"
IFS= builtin read -r -s -n 1
printf '\n'
exit "$_action_status"
'''


def local_path(uri):
    parsed = urlsplit(uri)
    if parsed.scheme != "file" or parsed.hostname not in (None, "", "localhost"):
        raise ValueError("This action requires a local file or folder.")
    path = os.fsdecode(unquote_to_bytes(parsed.path))
    if not os.path.isabs(path) or "\0" in path:
        raise ValueError("Invalid local file URI.")
    return path


def copy_values(kind, uris):
    if kind == "copy-uri":
        return "\n".join(uris)
    paths = [local_path(uri) for uri in uris]
    if kind == "copy-name":
        return "\n".join(os.path.basename(path.rstrip(os.sep)) or os.sep for path in paths)
    return "\n".join(paths)


def copy_to_clipboards(text):
    data = os.fsencode(text)
    if os.environ.get("WAYLAND_DISPLAY"):
        commands = [
            ["/usr/bin/wl-copy", "--type", "text/plain;charset=utf-8"],
            ["/usr/bin/wl-copy", "--primary", "--type", "text/plain;charset=utf-8"],
        ]
    elif os.environ.get("DISPLAY"):
        commands = [
            ["/usr/bin/xclip", "-selection", "clipboard", "-in"],
            ["/usr/bin/xclip", "-selection", "primary", "-in"],
        ]
    else:
        raise RuntimeError("No graphical clipboard is available in this session.")
    for index, command in enumerate(commands):
        subprocess.run(command, input=data, check=(index == 0),
                       stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def selected_directory(uris):
    if len(uris) != 1:
        raise ValueError("Select one folder for this action.")
    directory = local_path(uris[0])
    if not os.path.isdir(directory):
        raise ValueError("The selected item is not a folder.")
    return directory


def launch_console(directory, command=None):
    arguments = ["/usr/bin/kgx", "--tab", "--working-directory=" + directory]
    if command is not None:
        arguments.extend(["--", "/bin/bash", "-ic", COMMAND_RUNNER, "nautilus-command", command])
    # Report fast CLI failures while allowing the GUI to run independently.
    with tempfile.TemporaryFile() as diagnostics:
        process = subprocess.Popen(arguments, cwd=directory,
                                   stdout=subprocess.DEVNULL, stderr=diagnostics)
        try:
            status = process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            return
        if status != 0:
            diagnostics.seek(0)
            detail = diagnostics.read().decode("utf-8", errors="replace").strip()
            raise RuntimeError("Console could not start (exit %s).\n%s" % (status, detail[-2000:]))


def ask_command(directory):
    result = subprocess.run(
        ["/usr/bin/zenity", "--entry", "--title=Execute command here", "--width=800",
         "--text=" + html.escape(directory) + "\nEnter a Bash command. After it finishes, press any key to close the Console tab."],
        capture_output=True, text=True,
    )
    if result.returncode != 0:
        return None
    command = result.stdout.removesuffix("\n")
    return command if command.strip() else None


def perform(action, uris):
    if action.startswith("copy-"):
        copy_to_clipboards(copy_values(action, uris))
        return
    directory = selected_directory(uris)
    if action == "terminal":
        launch_console(directory)
    elif action == "execute":
        command = ask_command(directory)
        if command is not None:
            launch_console(directory, command)
    elif action == "code":
        subprocess.Popen(["/usr/bin/code", "--new-window", directory], cwd=directory)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("action", choices=("copy-name", "copy-path", "copy-uri", "terminal", "execute", "code"))
    parser.add_argument("uris", nargs="+")
    args = parser.parse_args()
    try:
        perform(args.action, args.uris)
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        message = str(exc)
        print("Nautilus action failed: " + message, file=sys.stderr)
        subprocess.run(["/usr/bin/zenity", "--error", "--title=Nautilus action",
                        "--text=" + html.escape(message)], check=False)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
