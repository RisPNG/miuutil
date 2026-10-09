#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
cd "$project_dir"
commit=$(git rev-parse "${GITHUB_SHA:-HEAD}^{commit}")
test "$(git rev-parse HEAD)" = "$commit"
source_epoch=$(git show -s --format=%ct "$commit")
repository=${GITHUB_REPOSITORY:-RisPNG/miuutil}
ref=${GITHUB_REF:-refs/heads/main}
if [[ "$ref" == refs/tags/* ]]; then
    tag=${ref#refs/tags/}
    channel=tag
else
    tag=latest-build
    channel=rolling
fi
run_url="https://github.com/$repository/actions/runs/${GITHUB_RUN_ID:-local}"
output_dir=$project_dir/dist/ci/$commit
mkdir -p "$output_dir"
scratch=$(mktemp -d)
image=miuutil-ci-build:$commit-$$
container=miuutil-ci-build-$commit-$$
docker_command=(docker)
if ! docker info >/dev/null 2>&1; then
    docker_command=(sudo -n docker)
fi
trap '"${docker_command[@]}" rm --force "$container" >/dev/null 2>&1 || true; rm -rf "$scratch"; "${docker_command[@]}" image rm "$image" >/dev/null 2>&1 || true' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
git archive "$commit" | tar --extract --directory "$scratch"
"${docker_command[@]}" build --file "$scratch/tests/Containerfile" --tag "$image" \
    --build-arg "BUILD_UID=$(id -u)" --build-arg "BUILD_GID=$(id -g)" "$scratch"
"${docker_command[@]}" run --rm --interactive --name "$container" --memory 4g --cpus 2 \
    --user "$(id -u):$(id -g)" \
    --mount "type=bind,src=$scratch,dst=/source,readonly" \
    --mount "type=bind,src=$output_dir,dst=/output" \
    --mount "type=bind,src=$(command -v mise),dst=/usr/local/bin/mise,readonly" \
    --env HOME=/tmp/miuutil-home --env SOURCE_DATE_EPOCH="$source_epoch" \
    --env MISE_DISABLE_TOOLS=python,aqua:cli/cli \
    --env BUILD_COMMIT="$commit" --env BUILD_CHANNEL="$channel" \
    "$image" bash -seu <<'BUILD'
mkdir -p "$HOME"
work=$(mktemp -d)
mkdir "$work/miuutil"
cp -a /source/. "$work/miuutil/"
cd "$work/miuutil"
export MISE_TRUSTED_CONFIG_PATHS=$PWD
mise install
if [[ "$BUILD_CHANNEL" == rolling ]]; then
    mise exec -- python3 - <<'PY'
from datetime import datetime, timezone
import os
from pathlib import Path
import subprocess

version = subprocess.check_output(["dpkg-parsechangelog", "--show-field", "Version"], text=True).strip()
stamp = datetime.fromtimestamp(int(os.environ["SOURCE_DATE_EPOCH"]), timezone.utc).strftime("%Y%m%d%H%M%S")
rolling_version = version + "+git" + stamp + "." + os.environ["BUILD_COMMIT"][:12]
changelog = Path("debian/changelog")
text = changelog.read_text()
changelog.write_text(text.replace("(" + version + ")", "(" + rolling_version + ")", 1))
PY
fi
mise exec -- dpkg-buildpackage -us -uc -b
cp "$work"/miuutil_*.deb /output/
BUILD
cp "$scratch/run.sh" "$output_dir/run.sh"
mise exec -- python3 dev/package-manifest.py "$output_dir" \
    --repository "$repository" --commit "$commit" --ref "$ref" --tag "$tag" \
    --source-date-epoch "$source_epoch" --workflow-run "$run_url"
if [[ -n ${GITHUB_OUTPUT:-} ]]; then
    printf 'commit=%s\ndirectory=%s\n' "$commit" "$output_dir" >> "$GITHUB_OUTPUT"
fi
printf 'Built %s from %s\n' "$output_dir" "$commit"
