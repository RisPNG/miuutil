# MiuUtil

MiuUtil, Debian GNOME cheat utility specifically built for MiuOS' Miubian.

Miubian starts with Debian testing and GNOME, then adds its desktop setup, software and preferences. MiuUtil lets you choose those additions on an existing Debian GNOME installation, so you can bring over only the parts you want.

## What you can choose

- A desktop with Miubian's menu, panel, themes, fonts and window behaviour.
- Applications and development tools from their official package sources.
- Browser, file-manager, terminal and shell preferences.
- System and memory preferences, with snapshot recovery where supported.

You can browse by category, search for an option and compare it with your current setup. Select individual choices or select everything eligible in the current view. Your selections stay in the queue when you change categories or filters.

## Getting started

Install the MiuUtil Debian package, then open MiuUtil from your applications menu. It supports Debian 13 and newer compatible Debian GNOME installations, including Debian testing.

Choose your options, open **Review**, then **Apply** when the listed changes are what you want. Review includes anything the selected options need and shows which changes require administrator access. If you stop, MiuUtil finishes the current change and keeps the remaining choices selected.

Close Firefox or Vivaldi before applying their profile preferences. MiuUtil keeps existing bookmarks, history, logins and extensions, and retains unrelated preferences. If a change fails, completed changes remain in place and you can review the remaining choices again.

Recovery options need an existing compatible disk layout. MiuUtil checks whether they are available before you can select them.

## Try the latest build

On a supported Debian GNOME desktop with an amd64 processor, run:

```sh
curl -fsSL https://raw.githubusercontent.com/RisPNG/miuutil/main/run.sh | bash
```

Close any open MiuUtil window first. The launcher gets the current commit's build and asks for administrator access to install it temporarily. If that build is still running, it waits for it to finish.

When you close MiuUtil, the launcher restores the version you already had or removes the temporary package. Dependencies and any setup changes you apply remain. For a permanent installation, use a [tagged Debian package](https://github.com/RisPNG/miuutil/releases).

## Development

[Development and installation](dev/README.md), [data maintenance](data/README.md) and [test coverage](tests/README.md) are documented separately.



MiuUtil is available under the [BSD Zero Clause licence](LICENSE). Included software and downloaded applications retain their own licences.
