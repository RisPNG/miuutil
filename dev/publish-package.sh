#!/usr/bin/env bash
set -euo pipefail

directory=$(realpath -- "$1")
: "${GITHUB_REPOSITORY:?}" "${GITHUB_REF:?}" "${BUILD_COMMIT:?}" "${DEFAULT_BRANCH:?}"
if [[ "$GITHUB_REF" == refs/tags/* ]]; then
    tag=${GITHUB_REF#refs/tags/}
    test "$tag" != latest-build
    test "$tag" != latest-release
    channel=tag
    alias=latest-release
    title='Latest tagged release'
    release_options=(--prerelease=false --latest=false)
elif [[ "$GITHUB_REF" == "refs/heads/$DEFAULT_BRANCH" ]]; then
    tag=latest-build
    channel=rolling
    alias=latest-build
    title='Latest default-branch build'
    release_options=(--prerelease --latest=false)
else
    printf 'Only the default branch and version tags publish packages.\n' >&2
    exit 1
fi

verify_release_package() {
    python3 - "$1" <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys

folder = Path(sys.argv[1])
record = json.loads((folder / 'build.json').read_text())
assert record['schema'] == 1
assert record['repository'] == os.environ['GITHUB_REPOSITORY']
assert record['commit'] == os.environ['BUILD_COMMIT']
assert re.fullmatch(r'[0-9a-f]{40}', record['commit'])
assert record['ref'] == os.environ['GITHUB_REF']
expected_tag = record['ref'][10:] if record['ref'].startswith('refs/tags/') else 'latest-build'
assert record['tag'] == expected_tag
assert re.fullmatch(re.escape('https://github.com/' + record['repository'] + '/actions/runs/') + r'[1-9][0-9]*', record['workflow_run'])
assert len(record['packages']) == 1
package = record['packages'][0]
assert package['package'] == 'miuutil' and package['architecture'] == 'amd64'
assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb', package['file'])
launcher = record['launcher']
assert launcher['file'] == 'run.sh'
expected = {}
for item in (package, launcher):
    assert re.fullmatch(r'[0-9a-f]{64}', item['sha256'])
    path = folder / item['file']
    assert path.stat().st_size == item['bytes']
    expected[item['file']] = item['sha256']
with (folder / 'build.json').open('rb') as data:
    expected['build.json'] = hashlib.file_digest(data, 'sha256').hexdigest()
checksums = {}
for line in (folder / 'SHA256SUMS').read_text().splitlines():
    match = re.fullmatch(r'([0-9a-f]{64})  ([A-Za-z0-9][A-Za-z0-9.+_~:-]*)', line)
    assert match
    assert match[2] not in checksums
    checksums[match[2]] = match[1]
assert checksums == expected
subprocess.run(['sha256sum', '--check', 'SHA256SUMS'], cwd=folder, check=True, stdout=sys.stderr)
identity = subprocess.check_output([
    'dpkg-deb', '--show', '--showformat=${Package}\t${Version}\t${Architecture}', str(folder / package['file']),
], text=True).split('\t')
assert identity == [package['package'], package['version'], package['architecture']]
print(package['file'])
PY
}

package=$(verify_release_package "$directory")
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
source_dir=$directory
if [[ "$channel" == tag ]]; then
    existing=false
    if gh release view "$tag" --repo "$GITHUB_REPOSITORY" --json isDraft,isPrerelease,assets > "$scratch/source-release.json"; then
        existing=true
    fi
    upload_options=()
    published=false
    if [[ "$existing" == true ]]; then
        read -r draft published < <(python3 - "$scratch/source-release.json" <<'PY'
import json
from pathlib import Path
import sys
record = json.loads(Path(sys.argv[1]).read_text())
print(str(record['isDraft']).lower(), str(any(asset['name'] == 'build.json' for asset in record['assets'])).lower())
PY
)
        if [[ "$draft" == false && "$published" == true ]]; then
            source_dir=$scratch/published
            mkdir "$source_dir"
            gh release download "$tag" --repo "$GITHUB_REPOSITORY" --pattern build.json --dir "$source_dir"
            package=$(python3 - "$source_dir/build.json" <<'PY'
import json
from pathlib import Path
import re
import sys
record = json.loads(Path(sys.argv[1]).read_text())
assert len(record['packages']) == 1
package = record['packages'][0]['file']
assert re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb', package)
print(package)
PY
)
            gh release download "$tag" --repo "$GITHUB_REPOSITORY" \
                --pattern "$package" --pattern SHA256SUMS --pattern run.sh --dir "$source_dir"
            package=$(verify_release_package "$source_dir")
            printf 'The tagged commit already has a published package; preserving its original assets.\n'
        elif [[ "$draft" == true ]]; then
            upload_options=(--clobber)
            published=false
        fi
    else
        gh release create "$tag" --repo "$GITHUB_REPOSITORY" --verify-tag --target "$BUILD_COMMIT" \
            --draft --title "$tag" --notes "Debian package built and tested from commit $BUILD_COMMIT. See build.json for its source, package and launcher checksums."
        upload_options=(--clobber)
    fi
    if [[ "$published" == false ]]; then
        gh release upload "$tag" "$source_dir/$package" "$source_dir/run.sh" "$source_dir/SHA256SUMS" "$source_dir/build.json" \
            --repo "$GITHUB_REPOSITORY" "${upload_options[@]}"
        remote_commit=$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" \
            "$GITHUB_REF" "${GITHUB_REF}^{}" | tail -n 1 | cut -f 1)
        test "$remote_commit" = "$BUILD_COMMIT"
        gh release edit "$tag" --repo "$GITHUB_REPOSITORY" --draft=false
    fi
fi

existing=false
if gh release view "$alias" --repo "$GITHUB_REPOSITORY" --json isDraft,isPrerelease,assets > "$scratch/alias-release.json"; then
    existing=true
fi
if [[ "$existing" == true ]]; then
    published_manifest=$(python3 - "$scratch/alias-release.json" "$channel" <<'PY'
import json
from pathlib import Path
import sys
record = json.loads(Path(sys.argv[1]).read_text())
assert record['isPrerelease'] == (sys.argv[2] == 'rolling')
print(str(any(asset['name'] == 'build.json' for asset in record['assets'])).lower())
PY
)
    if [[ "$published_manifest" == true ]]; then
        mkdir "$scratch/alias"
        gh release download "$alias" --repo "$GITHUB_REPOSITORY" --pattern build.json --dir "$scratch/alias"
        decision=$(python3 - "$scratch/alias/build.json" "$scratch/alias-release.json" "$source_dir/build.json" "$channel" <<'PY'
import hashlib
import json
from pathlib import Path
import re
import sys

previous = json.loads(Path(sys.argv[1]).read_text())
release = json.loads(Path(sys.argv[2]).read_text())
current = json.loads(Path(sys.argv[3]).read_text())
assets = {asset['name']: asset for asset in release['assets']}
package = previous['packages'][0] if len(previous.get('packages', [])) == 1 else {}
launcher = previous.get('launcher', {})
complete = (
    not release['isDraft']
    and previous.get('schema') == 1
    and previous.get('repository') == current['repository']
    and package.get('package') == 'miuutil' and package.get('architecture') == 'amd64'
    and re.fullmatch(r'[A-Za-z0-9][A-Za-z0-9.+_~:-]*\.deb', package.get('file', '')) is not None
    and re.fullmatch(r'[0-9a-f]{64}', package.get('sha256', '')) is not None
    and isinstance(package.get('bytes'), int) and package['bytes'] > 0
    and launcher.get('file') == 'run.sh'
    and re.fullmatch(r'[0-9a-f]{64}', launcher.get('sha256', '')) is not None
    and isinstance(launcher.get('bytes'), int) and launcher['bytes'] > 0
    and {'build.json', 'SHA256SUMS', 'run.sh', package.get('file', '')} <= assets.keys()
)
if complete:
    with Path(sys.argv[1]).open('rb') as data:
        manifest_digest = hashlib.file_digest(data, 'sha256').hexdigest()
    checksum_text = package['sha256'] + '  ' + package['file'] + '\n' + launcher['sha256'] + '  run.sh\n' + manifest_digest + '  build.json\n'
    expected = {package['file']: package['sha256'], 'run.sh': launcher['sha256'],
                'build.json': manifest_digest, 'SHA256SUMS': hashlib.sha256(checksum_text.encode()).hexdigest()}
    complete = (
        all(assets[name].get('digest') == 'sha256:' + digest for name, digest in expected.items())
        and assets[package['file']].get('size') == package['bytes']
        and assets['run.sh'].get('size') == launcher['bytes']
    )
if sys.argv[4] == 'rolling':
    matching = all(previous.get(key) == current[key] for key in ('commit', 'ref', 'tag'))
    decision = 'matching' if matching and complete else 'repair' if matching else 'publish'
else:
    assert previous['schema'] == 1 and previous['repository'] == current['repository']
    assert previous['ref'] == 'refs/tags/' + previous['tag']
    assert previous['tag'] not in ('latest-build', 'latest-release')
    assert re.fullmatch(r'[0-9a-f]{40}', previous['commit'])
    run_pattern = re.escape('https://github.com/' + current['repository'] + '/actions/runs/') + r'([1-9][0-9]*)'
    previous_run = re.fullmatch(run_pattern, previous['workflow_run'])
    current_run = re.fullmatch(run_pattern, current['workflow_run'])
    assert previous_run and current_run
    old_id, new_id = int(previous_run[1]), int(current_run[1])
    if old_id == new_id:
        assert previous == current
    decision = 'older' if old_id > new_id else 'matching' if old_id == new_id and complete else 'repair' if old_id == new_id else 'publish'
print(decision)
PY
)
        if [[ "$decision" == older ]]; then
            printf 'The alias already contains a newer tagged build; leaving it unchanged.\n'
            exit 0
        fi
        if [[ "$decision" == matching ]]; then
            alias_commit=$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" \
                "refs/tags/$alias" "refs/tags/${alias}^{}" | tail -n 1 | cut -f 1)
            if [[ "$alias_commit" == "$BUILD_COMMIT" ]]; then
                printf 'The alias already contains this build; leaving it unchanged.\n'
                exit 0
            fi
            printf 'The matching alias has incomplete assets or a mismatched reference; restoring its source build.\n'
        elif [[ "$decision" == repair ]]; then
            printf 'The matching alias has incomplete assets; restoring its source build.\n'
        fi
    fi
else
    gh release create "$alias" --repo "$GITHUB_REPOSITORY" --target "$BUILD_COMMIT" \
        "${release_options[@]}" --title "$title" \
        --notes 'Debian package alias. See build.json for the original source reference, workflow run, package and launcher checksums.'
fi

gh release upload "$alias" "$source_dir/$package" --repo "$GITHUB_REPOSITORY" --clobber
remote_commit=$(git ls-remote "https://github.com/$GITHUB_REPOSITORY.git" \
    "$GITHUB_REF" "${GITHUB_REF}^{}" | tail -n 1 | cut -f 1)
if [[ "$remote_commit" != "$BUILD_COMMIT" ]]; then
    if [[ "$channel" == rolling ]]; then
        printf 'The default branch advanced during publication; keeping the previous manifest.\n'
        exit 0
    fi
    printf 'The release tag moved during publication; keeping the previous alias manifest.\n' >&2
    exit 1
fi
gh release upload "$alias" "$source_dir/run.sh" "$source_dir/SHA256SUMS" --repo "$GITHUB_REPOSITORY" --clobber
gh api --method PATCH "repos/$GITHUB_REPOSITORY/git/refs/tags/$alias" \
    -f sha="$BUILD_COMMIT" -F force=true
gh release edit "$alias" --repo "$GITHUB_REPOSITORY" "${release_options[@]}" \
    --draft=false --target "$BUILD_COMMIT" --title "$title"
gh release upload "$alias" "$source_dir/build.json" --repo "$GITHUB_REPOSITORY" --clobber
gh release view "$alias" --repo "$GITHUB_REPOSITORY" --json assets \
    --jq '.assets[] | select(.name | startswith("miuutil_") and endswith(".deb")) | .name' \
    > "$scratch/packages"
while IFS= read -r previous; do
    if [[ "$previous" != "$package" ]]; then
        gh release delete-asset "$alias" "$previous" --repo "$GITHUB_REPOSITORY" --yes
    fi
done < "$scratch/packages"
