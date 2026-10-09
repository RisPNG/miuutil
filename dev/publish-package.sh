#!/usr/bin/env bash
set -euo pipefail

directory=$(realpath -- "$1")
: "${GITHUB_REPOSITORY:?}" "${GITHUB_REF:?}" "${BUILD_COMMIT:?}" "${DEFAULT_BRANCH:?}"
if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    tag=${GITHUB_REF#refs/tags/}
    channel=tag
elif [[ "$GITHUB_REF" == "refs/heads/$DEFAULT_BRANCH" ]]; then
    tag=latest-build
    channel=rolling
else
    printf 'Only the default branch and version tags publish packages.\n' >&2
    exit 1
fi
test "$tag" != latest-build || test "$channel" = rolling
package=$(python3 - "$directory/build.json" <<'PY'
import json
import os
from pathlib import Path
import re
import sys

record = json.loads(Path(sys.argv[1]).read_text())
assert record["schema"] == 1
assert record["repository"] == os.environ["GITHUB_REPOSITORY"]
assert record["commit"] == os.environ["BUILD_COMMIT"]
assert re.fullmatch(r"[0-9a-f]{40}", record["commit"])
assert record["ref"] == os.environ["GITHUB_REF"]
expected_tag = record["ref"][10:] if record["ref"].startswith("refs/tags/") else "latest-build"
assert record["tag"] == expected_tag
assert len(record["packages"]) == 1
package = record["packages"][0]
assert package["package"] == "miuutil" and package["architecture"] == "amd64"
assert re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb", package["file"])
print(package["file"])
PY
)
cd "$directory"
sha256sum --check SHA256SUMS
remote_commit=$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" \
    "$GITHUB_REF" "${GITHUB_REF}^{}" | tail -n 1 | cut -f 1)
if [[ "$remote_commit" != "$BUILD_COMMIT" ]]; then
    if [[ "$channel" == rolling ]]; then
        printf 'A newer default-branch commit exists; leaving the rolling release unchanged.\n'
        exit 0
    fi
    printf 'The release tag no longer points to the built commit.\n' >&2
    exit 1
fi
scratch=$(mktemp -d)
trap 'rm -rf "$scratch"' EXIT
existing=false
if gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft,isPrerelease,assets > "$scratch/release.json"; then
    existing=true
fi
if [[ "$channel" == rolling ]]; then
    if [[ "$existing" == true ]]; then
        python3 -c 'import json,sys; assert json.load(open(sys.argv[1]))["isPrerelease"]' "$scratch/release.json"
        published_manifest=$(python3 -c 'import json,sys; print(str(any(asset["name"] == "build.json" for asset in json.load(open(sys.argv[1]))["assets"])).lower())' "$scratch/release.json")
        if [[ "$published_manifest" == true ]]; then
            gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern build.json --dir "$scratch"
            already_published=$(python3 - "$scratch/build.json" "$scratch/release.json" <<'PY'
import json
import os
from pathlib import Path
import re
import sys

record = json.loads(Path(sys.argv[1]).read_text())
release = json.loads(Path(sys.argv[2]).read_text())
packages = record.get("packages", [])
package = packages[0] if len(packages) == 1 else {}
assets = {asset["name"] for asset in release["assets"]}
matching = (
    not release["isDraft"]
    and record.get("schema") == 1
    and record.get("repository") == os.environ["GITHUB_REPOSITORY"]
    and record.get("commit") == os.environ["BUILD_COMMIT"]
    and record.get("ref") == os.environ["GITHUB_REF"]
    and record.get("tag") == "latest-build"
    and package.get("package") == "miuutil"
    and package.get("architecture") == "amd64"
    and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb", package.get("file", "")) is not None
    and re.fullmatch(r"[0-9a-f]{64}", package.get("sha256", "")) is not None
    and isinstance(package.get("bytes"), int) and package["bytes"] > 0
    and {"build.json", "SHA256SUMS", package.get("file", "")} <= assets
)
print(str(matching).lower())
PY
)
            if [[ "$already_published" == true ]]; then
                printf 'The current default-branch commit already has a published package; leaving it unchanged.\n'
                exit 0
            fi
        fi
    else
        gh release create "$tag" --repo "$GITHUB_REPOSITORY" --target "$BUILD_COMMIT" \
            --prerelease --latest=false --title 'Latest default-branch build' \
            --notes 'Temporary Debian package from the current default-branch commit. See build.json for the exact source and package checksums.'
    fi
    gh release upload "$tag" "$package" --repo "$GITHUB_REPOSITORY" --clobber
    remote_commit=$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" "$GITHUB_REF" | cut -f 1)
    if [[ "$remote_commit" != "$BUILD_COMMIT" ]]; then
        printf 'The default branch advanced during publication; keeping the previous manifest.\n'
        exit 0
    fi
    gh release upload "$tag" SHA256SUMS --repo "$GITHUB_REPOSITORY" --clobber
    gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/tags/latest-build" \
        -f sha="$BUILD_COMMIT" -F force=true
    gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --prerelease --latest=false \
        --target "$BUILD_COMMIT" --title 'Latest default-branch build'
    gh release upload "$tag" build.json --repo "$GITHUB_REPOSITORY" --clobber
    gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json assets \
        --jq '.assets[] | select(.name | startswith("miuutil_") and endswith(".deb")) | .name' \
        > "$scratch/packages"
    while IFS= read -r previous; do
        if [[ "$previous" != "$package" ]]; then
            gh release delete-asset "$tag" "$previous" --repo "$GITHUB_REPOSITORY" --yes
        fi
    done < "$scratch/packages"
else
    upload_options=()
    if [[ "$existing" == true ]]; then
        draft=$(python3 -c 'import json,sys; print(str(json.load(open(sys.argv[1]))["isDraft"]).lower())' "$scratch/release.json")
        published_manifest=$(python3 -c 'import json,sys; print(str(any(asset["name"] == "build.json" for asset in json.load(open(sys.argv[1]))["assets"])).lower())' "$scratch/release.json")
        if [[ "$draft" == false && "$published_manifest" == true ]]; then
            gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern build.json --dir "$scratch"
            python3 -c 'import json,os,sys; assert json.load(open(sys.argv[1]))["commit"] == os.environ["BUILD_COMMIT"]' "$scratch/build.json"
            printf 'The tagged commit already has a published package; leaving it unchanged.\n'
            exit 0
        fi
        if [[ "$draft" == true ]]; then
            upload_options=(--clobber)
        fi
    else
        gh release create "$tag" --repo "$GITHUB_REPOSITORY" --verify-tag --target "$BUILD_COMMIT" \
            --draft --title "$tag" --notes "Debian package built and tested from commit $BUILD_COMMIT. See build.json for its source and checksums."
        upload_options=(--clobber)
    fi
    gh release upload "$tag" "$package" SHA256SUMS build.json --repo "$GITHUB_REPOSITORY" "${upload_options[@]}"
    remote_commit=$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" \
        "$GITHUB_REF" "${GITHUB_REF}^{}" | tail -n 1 | cut -f 1)
    test "$remote_commit" = "$BUILD_COMMIT"
    gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false
fi
