#!/usr/bin/python3
"""Keep the last occurrence of each Bash history entry. Caller holds the lock."""

import os
from pathlib import Path
import re
import sys
import tempfile


def deduplicate(data):
    entries = []
    timestamp = b""
    command = []
    lines = data.split(b"\n")
    for index, part in enumerate(lines):
        if index == len(lines) - 1 and not part:
            continue
        line = part + (b"\n" if index < len(lines) - 1 else b"")
        if re.fullmatch(rb"#[0-9]+\n?", line):
            if command:
                entries.append((timestamp, b"".join(command)))
            timestamp, command = line, []
        elif timestamp:
            command.append(line)
        else:
            # Older history without timestamps stores one entry per line.
            entries.append((b"", line))
    if command:
        entries.append((timestamp, b"".join(command)))

    seen, newest = set(), []
    for stamp, text in reversed(entries):
        key = text[:-1] if text.endswith(b"\n") else text
        if key and key not in seen:
            seen.add(key)
            newest.append(stamp + key + b"\n")
    return b"".join(reversed(newest))


def main():
    path = Path(sys.argv[1]).resolve()
    if not path.exists():
        return
    original = path.read_bytes()
    result = deduplicate(original)
    if result == original:
        return
    temporary = None
    try:
        with tempfile.NamedTemporaryFile(dir=path.parent, prefix=".bash-history-", delete=False) as output:
            temporary = output.name
            os.fchmod(output.fileno(), 0o600)
            output.write(result)
            output.flush()
            os.fsync(output.fileno())
        os.replace(temporary, path)
        temporary = None
    finally:
        if temporary is not None:
            os.unlink(temporary)


if __name__ == "__main__":
    main()
