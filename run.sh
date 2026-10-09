#!/usr/bin/env bash
set -euo pipefail
umask 077

channel=latest-build
if (( $# != 0 )); then
    if [[ $# == 1 && "$1" == --release ]]; then
        channel=latest-release
    else
        printf 'Usage: bash run.sh [--release]\n' >&2
        exit 2
    fi
fi

if [[ $(id -u) == 0 ]]; then
    printf 'Run this launcher from your desktop account, without sudo.\n' >&2
    exit 1
fi
for command in curl python3 dpkg dpkg-query dpkg-deb apt-get apt-mark sudo flock gdbus gapplication pgrep sha256sum; do
    if ! command -v "$command" >/dev/null; then
        printf 'The launcher requires %s.\n' "$command" >&2
        exit 1
    fi
done
architecture=$(dpkg --print-architecture)
if [[ "$architecture" != amd64 ]]; then
    printf 'The latest build is currently available for Debian 13 amd64 only.\n' >&2
    exit 1
fi
owner=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.rispeng.MiuUtil)
if [[ "$owner" == '(true,)' ]] || pgrep -x miuutil >/dev/null; then
    printf 'Close the running MiuUtil instance before starting the temporary build.\n' >&2
    exit 1
fi

state_directory=${XDG_STATE_HOME:-"$HOME/.local/state"}/miuutil/launcher
mkdir -p "$state_directory"
exec 9>"$state_directory/session.lock"
if ! flock -n 9; then
    printf 'A temporary MiuUtil session is already running.\n' >&2
    exit 1
fi
session_directory=$(mktemp -d "$state_directory/session.XXXXXXXX")
previous_package=''
previous_version=''
previous_selection=manual
previous_hold=false
package_changed=false
application_pid=''
stop_requested=0

complete_package_transaction() {
    local transaction_pid transaction_result
    (trap '' INT TERM HUP; exec "$@") &
    transaction_pid=$!
    while true; do
        if wait "$transaction_pid"; then
            return 0
        else
            transaction_result=$?
            if ! kill -0 "$transaction_pid" 2>/dev/null; then
                return "$transaction_result"
            fi
        fi
    done
}

resolve_source_commit() {
    local reference=$1 encoded_reference response response_result=0
    encoded_reference=$(python3 - "${reference#refs/}" <<'PY'
import sys
import urllib.parse

print(urllib.parse.quote(sys.argv[1], safe=""))
PY
)
    response=$(curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 --write-out '%{http_code}' "https://api.github.com/repos/$repository/commits/$encoded_reference" -o "$session_directory/commit.json") || response_result=$?
    if (( response_result != 0 )); then
        if [[ "$reference" == refs/tags/latest-release && "$response" == 404 ]]; then
            printf 'No successful tagged release has been published yet.\n' >&2
        fi
        return "$response_result"
    fi
    python3 - "$session_directory/commit.json" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    commit = json.load(source)["sha"]
if not re.fullmatch(r"[0-9a-f]{40}", commit):
    raise SystemExit("GitHub returned an invalid commit identifier.")
print(commit)
PY
}

request_stop() {
    stop_requested=$1
    printf '\nFinishing the current operation before closing MiuUtil.\n' >&2
    if [[ -n "$application_pid" ]] && kill -0 "$application_pid" 2>/dev/null; then
        if ! gapplication action com.rispeng.MiuUtil quit; then
            printf 'Close the MiuUtil window to finish this temporary session.\n' >&2
        fi
    fi
}

finish_session() {
    local result=$?
    local owner transaction_result
    trap - EXIT
    trap '' INT TERM HUP
    if (( stop_requested != 0 )); then
        result=$stop_requested
    fi
    if [[ "$package_changed" == true ]]; then
        owner=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.rispeng.MiuUtil)
        if [[ "$owner" == '(true,)' ]] || pgrep -x miuutil >/dev/null; then
            printf 'Waiting for the open MiuUtil instance to finish before restoring the package.\n' >&2
            if [[ "$owner" == '(true,)' ]]; then
                if ! gapplication action com.rispeng.MiuUtil quit; then
                    printf 'Close the MiuUtil window to finish this temporary session.\n' >&2
                fi
            else
                printf 'Close the other MiuUtil instance to finish this temporary session.\n' >&2
            fi
            while [[ "$owner" == '(true,)' ]] || pgrep -x miuutil >/dev/null; do
                sleep 1
                owner=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.rispeng.MiuUtil)
            done
        fi
        transaction_result=0
        if [[ -n "$previous_package" ]]; then
            printf 'Restoring MiuUtil %s.\n' "$previous_version"
            if complete_package_transaction sudo apt-get --yes --no-remove --reinstall --allow-downgrades --allow-change-held-packages install "$previous_package"; then
                if ! sudo apt-mark "$previous_selection" miuutil; then
                    transaction_result=1
                fi
                if [[ "$previous_hold" == true ]]; then
                    if ! sudo apt-mark hold miuutil; then
                        transaction_result=1
                    fi
                elif ! sudo apt-mark unhold miuutil; then
                    transaction_result=1
                fi
            else
                transaction_result=$?
            fi
        else
            printf 'Removing the temporary MiuUtil package.\n'
            if complete_package_transaction sudo dpkg --remove miuutil; then
                transaction_result=0
            else
                transaction_result=$?
            fi
        fi
        if (( transaction_result != 0 )); then
            printf 'Package cleanup failed. The recovery package and session record remain in %s\n' "$session_directory" >&2
            exit 1
        fi
    fi
    rm -rf "$session_directory"
    exit "$result"
}

trap finish_session EXIT
trap 'request_stop 130' INT
trap 'request_stop 143' TERM
trap 'request_stop 129' HUP

repository=RisPNG/miuutil
release=https://github.com/$repository/releases/download/$channel
if [[ "$channel" == latest-release ]]; then
    channel_ref=refs/tags/latest-release
    source_name=latest-release
else
    curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 "https://api.github.com/repos/$repository" -o "$session_directory/repository.json"
    source_name=$(python3 - "$session_directory/repository.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    repository = json.load(source)
if repository["full_name"] != "RisPNG/miuutil":
    raise SystemExit("GitHub returned a different repository.")
branch = repository["default_branch"]
print(branch)
PY
)
    channel_ref=refs/heads/$source_name
fi
commit=$(resolve_source_commit "$channel_ref")
deadline=$((SECONDS + 1200))
waiting_polls=0
while true; do
    if (( stop_requested != 0 )); then
        exit "$stop_requested"
    fi
    if (( SECONDS >= deadline )); then
        printf 'The current %s commit has no matching published package yet. Try again after its GitHub Actions build finishes.\n' "$source_name" >&2
        exit 1
    fi
    if (( waiting_polls >= 6 )); then
        commit=$(resolve_source_commit "$channel_ref")
        waiting_polls=0
    fi
    if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 "$release/build.json" -o "$session_directory/build.json"; then
        manifest_result=0
        python3 - "$session_directory/build.json" "$channel" "$channel_ref" "$commit" "$session_directory/package.txt" <<'PY' || manifest_result=$?
import json
import re
import sys
import urllib.parse

with open(sys.argv[1], encoding="utf-8") as source:
    build = json.load(source)
if (build["schema"] != 1 or build["repository"] != "RisPNG/miuutil"
        or not re.fullmatch(r"[0-9a-f]{40}", build["commit"])
        or not isinstance(build["source_date_epoch"], int)
        or not re.fullmatch(r"https://github.com/RisPNG/miuutil/actions/runs/[0-9]+", build["workflow_run"])):
    raise SystemExit("The latest build has invalid source provenance.")
if sys.argv[2] == "latest-build":
    if build["tag"] != "latest-build" or build["ref"] != sys.argv[3]:
        raise SystemExit("The latest build has invalid branch provenance.")
elif (not isinstance(build["tag"], str) or not build["tag"]
        or build["tag"] in ("latest-build", "latest-release")
        or build["ref"] != "refs/tags/" + build["tag"]):
    raise SystemExit("The latest release does not identify an original source tag.")
if build["commit"] != sys.argv[4]:
    raise SystemExit(75)
if len(build["packages"]) != 1:
    raise SystemExit("The latest build does not identify one native package.")
package = build["packages"][0]
if (package["package"] != "miuutil" or package["architecture"] != "amd64"
        or not re.fullmatch(r"miuutil_[A-Za-z0-9.+:~_-]+_amd64\.deb", package["file"])
        or not re.fullmatch(r"[0-9a-f]{64}", package["sha256"])
        or not isinstance(package["bytes"], int) or package["bytes"] <= 0
        or not re.fullmatch(r"[A-Za-z0-9.+:~_-]+", package["version"])):
    raise SystemExit("The latest build has invalid package metadata.")
launcher = build["launcher"]
if (launcher["file"] != "run.sh" or not re.fullmatch(r"[0-9a-f]{64}", launcher["sha256"])
        or not isinstance(launcher["bytes"], int) or launcher["bytes"] <= 0):
    raise SystemExit("The latest build has invalid launcher metadata.")
with open(sys.argv[5], "w", encoding="utf-8") as destination:
    destination.write("\n".join(str(package[field]) for field in ("file", "version", "sha256", "bytes")) + "\n")
    destination.write(build["ref"] + "\nhttps://github.com/RisPNG/miuutil/releases/download/" + urllib.parse.quote(build["tag"], safe="") + "\n")
PY
        if (( manifest_result != 0 && manifest_result != 75 )); then
            exit "$manifest_result"
        fi
        if (( manifest_result == 0 )); then
            mapfile -t package_fields <"$session_directory/package.txt"
            package_file=${package_fields[0]}
            package_version=${package_fields[1]}
            package_digest=${package_fields[2]}
            package_bytes=${package_fields[3]}
            artifact_release=${package_fields[5]}
            download_result=0
            if [[ "$channel" == latest-release ]]; then
                original_commit=$(resolve_source_commit "${package_fields[4]}") || download_result=$?
                if (( download_result == 0 )) && [[ "$original_commit" != "$commit" ]]; then
                    printf 'The original release tag does not match the latest-release commit.\n' >&2
                    download_result=1
                fi
                if (( download_result == 0 )); then
                    if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 "$artifact_release/build.json" -o "$session_directory/original-build.json"; then
                        if ! cmp --silent "$session_directory/build.json" "$session_directory/original-build.json"; then
                            printf 'The latest-release record does not match its immutable source release.\n' >&2
                            download_result=1
                        fi
                    else
                        download_result=$?
                    fi
                fi
            fi
            if (( download_result == 0 )); then
                if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 "$artifact_release/SHA256SUMS" -o "$session_directory/SHA256SUMS" \
                    && curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 "$artifact_release/$package_file" -o "$session_directory/$package_file"; then
                    python3 - "$session_directory/SHA256SUMS" "$package_file" "$package_digest" "$session_directory/build.json" <<'PY' || download_result=$?
import hashlib
import json
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    records = [line.rstrip("\n") for line in source]
with open(sys.argv[4], "rb") as source:
    manifest_digest = hashlib.file_digest(source, "sha256").hexdigest()
with open(sys.argv[4], encoding="utf-8") as source:
    launcher_digest = json.load(source)["launcher"]["sha256"]
for digest, name in ((sys.argv[3], sys.argv[2]), (launcher_digest, "run.sh"), (manifest_digest, "build.json")):
    if records.count(digest + "  " + name) != 1:
        raise SystemExit("SHA256SUMS does not agree with the build manifest.")
PY
                    if (( download_result == 0 )) && [[ $(stat -c %s "$session_directory/$package_file") != "$package_bytes" ]]; then
                        printf 'The downloaded package size does not match its build manifest.\n' >&2
                        download_result=1
                    fi
                    if (( download_result == 0 )); then
                        (cd "$session_directory"; printf '%s  %s\n' "$package_digest" "$package_file" | sha256sum --check --status) || download_result=$?
                    fi
                    if (( download_result == 0 )) && [[ $(dpkg-deb --field "$session_directory/$package_file" Package) != miuutil || $(dpkg-deb --field "$session_directory/$package_file" Version) != "$package_version" || $(dpkg-deb --field "$session_directory/$package_file" Architecture) != "$architecture" ]]; then
                        printf 'The package control metadata does not match its build manifest.\n' >&2
                        download_result=1
                    fi
                else
                    download_result=$?
                fi
            fi
            generation_changed=false
            if [[ "$channel" == latest-release ]]; then
                if curl --fail --silent --show-error --location --proto '=https' --tlsv1.2 --max-time 60 "$release/build.json" -o "$session_directory/current-build.json"; then
                    if ! cmp --silent "$session_directory/build.json" "$session_directory/current-build.json"; then
                        generation_changed=true
                    fi
                else
                    download_result=$?
                fi
            fi
            current_commit=$(resolve_source_commit "$channel_ref")
            if [[ "$current_commit" != "$commit" ]]; then
                commit=$current_commit
            elif [[ "$generation_changed" == true ]]; then
                waiting_polls=0
            elif (( download_result != 0 )); then
                exit "$download_result"
            else
                break
            fi
        fi
    elif [[ "$channel" == latest-release ]]; then
        printf 'No successful tagged release is available at latest-release yet.\n' >&2
        exit 1
    fi
    printf 'Waiting for the latest build of %s (%s).\n' "$source_name" "${commit:0:12}"
    sleep 10
    waiting_polls=$((waiting_polls + 1))
done

owner=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.rispeng.MiuUtil)
if [[ "$owner" == '(true,)' ]] || pgrep -x miuutil >/dev/null; then
    printf 'MiuUtil was opened during the download. Close it and run the launcher again.\n' >&2
    exit 1
fi
if (( stop_requested != 0 )); then
    exit "$stop_requested"
fi
previous_status=$(dpkg-query --show --showformat='${db:Status-Status}\t${Version}\t${Architecture}\n' miuutil 2>/dev/null || true)
if [[ "$previous_status" == installed$'\t'* ]]; then
    IFS=$'\t' read -r _ previous_version previous_architecture <<<"$previous_status"
    if [[ -n $(apt-mark showauto miuutil) ]]; then
        previous_selection=auto
    fi
    if [[ -n $(apt-mark showhold miuutil) ]]; then
        previous_hold=true
    fi
fi
sudo -v
complete_package_transaction sudo apt-get update
if (( stop_requested != 0 )); then
    exit "$stop_requested"
fi
if [[ -n "$previous_version" ]]; then
    if ! command -v dpkg-repack >/dev/null; then
        complete_package_transaction sudo apt-get --yes --no-remove install dpkg-repack
    fi
    mkdir "$session_directory/previous"
    (cd "$session_directory/previous"; sudo dpkg-repack --tag=none miuutil)
    previous_packages=("$session_directory"/previous/miuutil_*.deb)
    if [[ ${#previous_packages[@]} != 1 || ! -f "${previous_packages[0]}" ]]; then
        printf 'The existing installation could not be repacked. It has not been replaced.\n' >&2
        exit 1
    fi
    previous_package=${previous_packages[0]}
    if [[ $(dpkg-deb --field "$previous_package" Version) != "$previous_version" || $(dpkg-deb --field "$previous_package" Architecture) != "$previous_architecture" ]]; then
        printf 'The recovery package does not match the existing installation.\n' >&2
        exit 1
    fi
fi
python3 - "$session_directory/session.json" "$previous_version" "$previous_selection" "$previous_hold" "$commit" "$package_version" <<'PY'
import json
import sys

with open(sys.argv[1], "w", encoding="utf-8") as destination:
    json.dump({"previous_version": sys.argv[2], "previous_selection": sys.argv[3], "previous_hold": sys.argv[4] == "true", "commit": sys.argv[5], "temporary_version": sys.argv[6]}, destination, indent=2)
PY
if (( stop_requested != 0 )); then
    exit "$stop_requested"
fi
owner=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.rispeng.MiuUtil)
if [[ "$owner" == '(true,)' ]] || pgrep -x miuutil >/dev/null; then
    printf 'MiuUtil was opened while preparing the package. Close it and run the launcher again.\n' >&2
    exit 1
fi
printf 'Installing temporary MiuUtil %s from commit %s.\n' "$package_version" "${commit:0:12}"
printf 'Recovery files for this session: %s\n' "$session_directory"
package_changed=true
complete_package_transaction sudo apt-get --yes --no-remove --reinstall --allow-downgrades --allow-change-held-packages install "$session_directory/$package_file"
if (( stop_requested != 0 )); then
    exit "$stop_requested"
fi
installed_files=$(dpkg-query --listfiles miuutil)
application=''
while IFS= read -r installed_file; do
    case "$installed_file" in
        */bin/miuutil) application=$installed_file ;;
    esac
done <<<"$installed_files"
if [[ -z "$application" ]]; then
    printf 'The installed package does not provide the MiuUtil application.\n' >&2
    exit 1
fi
owner=$(gdbus call --session --dest org.freedesktop.DBus --object-path /org/freedesktop/DBus --method org.freedesktop.DBus.NameHasOwner com.rispeng.MiuUtil)
if [[ "$owner" == '(true,)' ]] || pgrep -x miuutil >/dev/null; then
    printf 'MiuUtil was opened during installation. The temporary session will close without launching another instance.\n' >&2
    exit 1
fi
printf 'Close MiuUtil when finished. Dependencies and applied setup changes will remain.\n'
(trap '' INT TERM HUP; exec "$application") &
application_pid=$!
if (( stop_requested != 0 )); then
    request_stop "$stop_requested"
fi
while true; do
    if wait "$application_pid"; then
        application_pid=''
        break
    else
        application_result=$?
        if ! kill -0 "$application_pid" 2>/dev/null; then
            application_pid=''
            exit "$application_result"
        fi
    fi
done
