# MiuUtil

MiuUtil, Debian GNOME cheat utility specifically built for MiuOS' Miubian.

Miubian starts with Debian testing and GNOME, then adds its desktop setup, software and preferences. MiuUtil lets you choose those additions on an existing Debian GNOME installation, so you can bring over only the parts you want as per the option and category:

- A desktop with Miubian's menu, panel, themes, fonts and window behaviour.
- Applications and development tools from their official package sources.
- Browser, file-manager, terminal and shell preferences.
- System and memory preferences, with snapshot recovery where supported.

## Installation

Install the MiuUtil Debian package and open MiuUtil from your applications menu or run:

```sh
curl -fsSL https://raw.githubusercontent.com/RisPNG/miuutil/main/run.sh | bash
```

Close any open MiuUtil window first. The launcher gets the current commit's build and asks for administrator access to install it temporarily.

## Development

[Development and installation](dev/README.md), [data maintenance](data/README.md) and [test coverage](tests/README.md) are documented separately.

MiuUtil is available under the [BSD Zero Clause licence](LICENSE). Included software and downloaded applications retain their own licences.
