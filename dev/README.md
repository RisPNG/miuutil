# Development

MiuUtil uses Vala, GTK 4, libadwaita, GLib/GIO and Meson. Blueprint files define the interface beside the Vala files that control it. The minimum native libraries are GLib 2.84, GTK 4.18, libadwaita 1.7 and JSON-GLib 1.8.

File paths refer to the source checkout, and build commands run from the project root.

## Tools and building

`mise.toml` pins Meson, Ninja and the GitHub CLI used for release publication. Python stays with Debian because Blueprint and the desktop checks need its GNOME bindings. Vala, Blueprint, the C compiler and Debian packaging tools also come from the distribution.

The Debian 13 build environment uses the following versions. These are the tested baseline; the requirements in `meson.build` and `debian/control` determine which later versions are compatible.

| Tool | Version | Provided by |
| --- | --- | --- |
| Meson | 1.7.0 | Mise |
| Ninja | 1.12.1 | Mise |
| GitHub CLI | 2.102.0 | Mise |
| Vala | 0.56.18 | Debian |
| Blueprint | 0.16.0 | Debian |
| Python | 3.13.5 | Debian |
| GCC | 14.2.0 | Debian |
| pkgconf | 1.8.1 | Debian |
| debhelper | 13.24.2 | Debian |
| dpkg | 1.22.22 | Debian |

Install the native dependencies on Debian 13 or a newer compatible system, then run the project tasks:

```sh
sudo apt install valac build-essential pkg-config blueprint-compiler \
  libgtk-4-dev libadwaita-1-dev libjson-glib-dev gettext \
  debhelper desktop-file-utils appstream dbus-x11 xvfb xauth \
  python3 python3-gi python3-venv pipx
mise trust
mise install
mise run configure
mise run build
mise run test
mise run run
```

Running from the build directory uses its compiled settings schema. Administrator operations and installed shortcut helpers require the Debian package to be installed. The source build and installed application use the same implementation.

## Debian package

Install Debian's `meson` and `ninja-build` packages as well before building a package, since debhelper checks the declared build dependencies. Run these commands from the project root:

```sh
sudo apt install meson ninja-build
mise run package
sudo apt install ../miuutil_0.1.4-1_amd64.deb
miuutil
```

Use the filename produced by the build if its version or architecture differs. The package installs the application, administrator helper, polkit policy, desktop entry, icons, settings schema and support scripts through Meson and debhelper. `debian/` contains the package metadata and build rules.

## CI and releases

[Build Debian package](../.github/workflows/build-deb.yml) builds when a tag is pushed or the default branch changes. It checks out the triggering commit and uses [build-package.sh](build-package.sh) to export that exact Git tree into the existing Debian 13 build container. Uncommitted files are excluded. Native Debian packaging runs the Meson tests before exporting the amd64 package.

Tag builds retain the package version in the tagged commit's `debian/changelog`. Update that version and `meson.build` when preparing a new application release. The tag must point to a commit that contains the workflow. For example, replace `<commit-sha>` with the intended release commit:

```sh
git tag v0.1.4 <commit-sha>
git push origin v0.1.4
```

Each tagged GitHub release contains its `.deb`, the launcher from that commit, `SHA256SUMS` and `build.json` with the source commit, package and launcher identities, and digests. Releases remain drafts until their files upload successfully. A failed draft can be retried; a published tagged package and its launcher are preserved.

Successful version-tag builds also update `latest-release`. Its manifest retains the original version tag and source commit. The original build's workflow run determines which tagged release is newer, so an older build that finishes later or a rerun of an older release cannot replace the newer alias. Tagged publication jobs share a [GitHub concurrency queue](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency) because they update the same alias.

Default-branch builds use the `latest-build` prerelease. Their package version adds the commit timestamp and short hash in the disposable build tree. Publication checks the current branch head, so a delayed older build cannot replace the current build. Both aliases upload their manifest after the package, launcher and checksums. A repeated successful build of the same commit preserves its published files.

`latest-build` and `latest-release` are reserved for CI. Do not create or move them manually. The workflow excludes them from tag triggers. CI artifacts are retained for 14 days; the published release files remain available separately.

The package build has read-only repository access. The separate publication job receives release permissions. Official workflow actions use recorded commit hashes; update their hashes and the pinned host tools when maintaining CI.

## Temporary launcher

[run.sh](../run.sh) is the shared curl entry point. With no arguments, it resolves the repository's current default-branch commit and waits up to 20 minutes for its matching `latest-build` manifest. With `--release`, it resolves `latest-release`, checks the original version tag and downloads the package from that tag's preserved release. A newer commit on the default branch does not change the selected tagged release.

Both modes verify the package's source, metadata and checksums, and recheck their selected reference after downloading. Release downloads use the original tagged assets so replacing the alias cannot mix packages from two releases, even when their native package filenames are the same. The release command needs a successful version-tag build containing this workflow and launcher; it reports an unavailable release if that channel hasn't been published yet.

Run it from the desktop account, without `sudo`. It requires Debian's APT and dpkg tools, Python 3, curl, sudo and GLib's `gapplication` and `gdbus` commands. It uses a native temporary package installation because the application's installed helper and polkit policy provide administrator operations.

If MiuUtil is already installed, the launcher uses `dpkg-repack` to preserve its current package files, then restores them with the previous automatic, manual and held package status when the session ends. It installs `dpkg-repack` if needed. If MiuUtil was absent, it removes only that temporary package. It does not purge settings, remove dependencies, or undo choices applied in the application.

Recovery files are held under `~/.local/state/miuutil/launcher/`, or the equivalent `$XDG_STATE_HOME` directory. Normal completion removes the session files. If package cleanup fails, its archive and session record remain there for recovery. Reinstall the archive in `previous/` and restore its package status from `session.json`; if there was no previous package, remove MiuUtil with `sudo dpkg --remove miuutil`. Interruptions request the application's normal quit action and wait for its current operation before restoring or removing the package. Close an already running MiuUtil before starting the launcher.

## Isolated checks

`tests/Containerfile` provides the Debian build dependencies and desktop testing tools. From the project root, with Docker and Mise available, build and run it as follows. These host commands leave the pinned tools for the container to install:

```sh
MISE_DISABLE_TOOLS=pipx:meson,aqua:ninja-build/ninja,python mise exec -- \
  docker build -f tests/Containerfile -t miuutil-build \
  --build-arg BUILD_UID="$(id -u)" --build-arg BUILD_GID="$(id -g)" .
MISE_DISABLE_TOOLS=pipx:meson,aqua:ninja-build/ninja,python mise exec -- \
  docker run --rm -v "$PWD:/work" \
  -v "$(command -v mise):/usr/local/bin/mise:ro" \
  -e MISE_DISABLE_TOOLS=python,aqua:cli/cli \
  -e MISE_TRUSTED_CONFIG_PATHS=/work miuutil-build \
  sh -ec '
    mise install
    mise exec -- meson setup build-container --prefix=/usr --libexecdir=libexec
    mise exec -- meson compile -C build-container -j 2
    mise exec -- meson test -C build-container --print-errorlogs
  '
```

The container account matches the host UID and GID so file ownership and session D-Bus work on local and hosted runners. The native interface tests use a temporary Xvfb display and isolated settings. [tests/README.md](../tests/README.md) describes the coverage and audit status. `upstream-smoke.vala` is a separate manual check that can download and install software, so it belongs in a disposable container or test account.

## Project layout

| Path | Responsibility |
| --- | --- |
| `src/core/` | Options, detection, dependency planning and sequential execution, without GTK |
| `src/core/operations/` | GSettings, account files, package managers and verified upstream installations |
| `src/ui/` | Native windows and rows, with `.vala` behaviour beside `.blp` layout |
| `src/privileged/` | Fixed system operations and the administrator helper entry point |
| `data/` | Catalogue, download records, configuration payloads and desktop integration |
| `debian/` | Debian package metadata and build rules |
| `po/` | Gettext translation infrastructure |
| `tests/` | Behaviour checks and the isolated build environment |
| `dev/` | Development instructions |
| `.github/` | Tagged and default-branch package workflows |
| `run.sh` | Temporary launcher for the latest tagged release or current default-branch build |

## Maintaining options

Miubian's maintained setup defines what each option should achieve on top of Debian testing and GNOME. [data/README.md](../data/README.md) explains the inputs and what needs to stay aligned, including defaults that Miubian relies on.

Account preferences and files are changed with the user's permissions. System changes go through the polkit-authorised helper, which accepts fixed option identifiers. Keep administrator operations in `src/privileged/` and account operations in `src/core/operations/`.

Direct upstream downloads use recorded versions and SHA-256 checksums. Debian and Flatpak packages keep their normal package-manager updates. Update the download records and their consumers together when changing an upstream version.

Replaced account files are backed up under `~/.local/state/miuutil/backups/`, or the equivalent `$XDG_STATE_HOME` directory. There is no automatic rollback of a complete plan. When an operation fails, completed changes remain applied and the remaining choices can be reviewed again.

Recovery options require a compatible existing Btrfs layout. Disk partitioning and filesystem selection belong to the Miubian installer.

## Licensing

The application uses the BSD Zero Clause licence in `LICENSE`. The Material Select All icon retains its Apache 2.0 notice, and bundled grub-btrfs source retains its GPL 3 licence and upstream notices. `debian/copyright` records included third-party material, and [data/README.md](../data/README.md) records its sources. Applications and themes downloaded when applying options retain their own licences.
