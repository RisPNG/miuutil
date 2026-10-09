# MiuUtil

MiuUtil, Debian GNOME cheat utility specifically built for MiuOS' Miubian.

Miubian starts with Debian testing and GNOME, then adds its desktop setup, software and preferences. MiuUtil lets you choose those additions on an existing Debian GNOME installation, so you can bring over only the parts you want as per the option and category:

- A desktop with Miubian's menu, panel, themes, fonts and window behaviour.
- Applications and development tools from their official package sources.
- Browser, file-manager, terminal and shell preferences.
- System and memory preferences, with snapshot recovery where supported.

## Installation

Install the MiuUtil Debian package and open MiuUtil from your applications menu. For a temporary session, choose the latest tagged release or the current development build.

Latest tagged release:

```sh
curl -fsSL https://github.com/RisPNG/miuutil/releases/download/latest-release/run.sh | bash -s -- --release
```

Current development build:

```sh
curl -fsSL https://raw.githubusercontent.com/RisPNG/miuutil/main/run.sh | bash
```

Close any open MiuUtil window first. Both commands ask for administrator access to install MiuUtil temporarily. Closing MiuUtil restores your previous installation, or removes the temporary package if it wasn't installed. Your applied changes remain.

The release command becomes available after the first version-tag build succeeds.

## Development

[Development and installation](dev/README.md), [data maintenance](data/README.md) and [test coverage](tests/README.md) are documented separately.

MiuUtil is available under the [BSD Zero Clause licence](LICENSE). Included software and downloaded applications retain their own licences.
