#!/usr/bin/env python3
import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess


parser = argparse.ArgumentParser(description="Record the native Debian package and its exact source commit.")
parser.add_argument("directory", type=Path)
parser.add_argument("--repository", required=True)
parser.add_argument("--commit", required=True)
parser.add_argument("--ref", required=True)
parser.add_argument("--tag", required=True)
parser.add_argument("--source-date-epoch", required=True, type=int)
parser.add_argument("--workflow-run", required=True)
arguments = parser.parse_args()
if not re.fullmatch(r"[0-9a-f]{40}", arguments.commit):
    parser.error("The source commit must be a complete Git commit hash.")
packages = list(arguments.directory.glob("*.deb"))
if len(packages) != 1:
    parser.error("Expected exactly one application package.")
archive = packages[0]
if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb", archive.name):
    parser.error("The package must have a safe native archive filename.")
identity = subprocess.check_output([
    "dpkg-deb", "--show", "--showformat=${Package}\t${Version}\t${Architecture}", str(archive),
], text=True).split("\t")
package, version, architecture = identity
if package != "miuutil" or architecture != "amd64":
    parser.error("Expected the native miuutil amd64 application package.")
with archive.open("rb") as stream:
    package_digest = hashlib.file_digest(stream, "sha256").hexdigest()
manifest = {
    "schema": 1,
    "repository": arguments.repository,
    "commit": arguments.commit,
    "ref": arguments.ref,
    "tag": arguments.tag,
    "source_date_epoch": arguments.source_date_epoch,
    "workflow_run": arguments.workflow_run,
    "packages": [{
        "file": archive.name, "package": package, "version": version,
        "architecture": architecture, "sha256": package_digest, "bytes": archive.stat().st_size,
    }],
}
record = arguments.directory / "build.json"
record.write_text(json.dumps(manifest, indent=2) + "\n")
with record.open("rb") as stream:
    record_digest = hashlib.file_digest(stream, "sha256").hexdigest()
(arguments.directory / "SHA256SUMS").write_text(
    f"{package_digest}  {archive.name}\n{record_digest}  build.json\n")
