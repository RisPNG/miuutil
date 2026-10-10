# Data

This folder defines the selectable changes MiuUtil applies from Miubian's setup on top of Debian testing and GNOME. Miubian's maintained `variants/miubian/dev/setup-manual-steps.md`, integration defaults and software inputs are the reference. Keep each change that can be applied to an existing installation available as an option. When that setup changes, update the affected catalogue entries, payloads, dependencies and detection together.

An existing account can have settings that differ from the defaults Miubian relies on. Those defaults need to be explicit where they determine the selected outcome. For example, ArcMenu must open beside its left panel button rather than retain a forced screen-centre position. Dash to Panel needs the bottom position and size `48`, while records for disconnected monitors remain in place. Blur My Shell needs Default artefact handling (`hacks-level=1`) to repaint application blur without window-button hover flashing. It also needs both DING application identifiers and the legacy `gjs` class excluded; that class also excludes other `gjs` windows. Check the installed extension's schema and behaviour when its version changes.

Apply only the preferences that define the selected outcome. Preserve unrelated settings and existing personal data, including browser profiles, sign-ins, bookmarks, history, extensions and custom panels. A clean Miubian profile is a reference for the intended preferences, so it must not replace an existing user's profile.

Rounded popup blur uses Blur My Shell's static mode and Default rounded pipeline for menus and notification banners. It blurs the desktop wallpaper rather than live windows behind the popup. This avoids the rectangular backing produced by dynamic popup blur when the rounded blur library is absent. The choice preserves existing corner radii and is unavailable when the installed extension has no popup blur schema. Miubian saves the same preferences for extension versions that provide it.

Default applications are separate choices: Vivaldi for browsers, mpv for video, Harmonoid with mpv fallback for audio, qView for images, Evince for PDFs, and Nautilus for folders. Media choices expand registered MIME families and aliases through GIO, while preserving unrelated associations. Reapply a choice after installing new MIME definitions.

The audio preference lists Harmonoid first and mpv next. mpv handles audio while Harmonoid's desktop entry is unavailable; installing a package that registers `harmonoid.desktop` makes Harmonoid preferred without reapplying the saved associations.

Harmonoid's optional installation downloads its verified official Debian package directly from the publisher; its binary is not bundled in MiuUtil or the Miubian ISO.

The mpv preference installs ModernZ and thumbfast before selecting the controller. It uses the default layout, Fluent icon theme with mixed icon style, medium seek bar and triangle chapter markers. Timestamps show milliseconds by default; right-clicking the timestamp toggles them. Audio and subtitle selector buttons appear when the file has corresponding tracks and the window has enough room. ModernZ's native thumbfast integration shows seek previews. Existing mpv and ModernZ settings outside this preset, thumbfast configuration, scripts and fonts are preserved. The native repeated `watch-later-options-remove` directives retain existing exclusions while adding `sub-pos`, so ModernZ's temporary subtitle position is not saved for playback resume. Conflicting uosc controller scripts are moved into the account's MiuUtil backups so both controllers do not load together. Restart mpv after applying.

The Console default selects its native New Tab action for generic and GNOME terminal requests and uses `kgx --tab` for desktop launches. Super+T activates Console's New Tab action over D-Bus, preserving its most recently active tab's directory. The system terminal alternative uses `xdg-terminal-exec` to share that preference. Browser alternatives are a separate system choice. `BROWSER` and `TERMINAL` environment changes take effect in a new session.

The Nautilus tab choice enables the packaged native extension through the account's `miu/nautilus-tabs.conf` file. Installing MiuUtil alone leaves it disabled; Miubian enables the same preference system-wide. It handles ordinary folder launches and FileManager1 file reveals, including Vivaldi's Show in File Manager, through native navigation and selection. Restart Files or sign out and in to load it. Nautilus's command runner also uses a Console tab.

## Configuration and build inputs

| File | Purpose |
| --- | --- |
| `catalogue.json` | Option descriptions, desired values, dependencies and typed operations used for detection and application. |
| `upstreams.json` | Official download URLs, exact versions, or commits and SHA-256 digests for downloaded software. GNOME extension records select compatible releases by Shell major version. |
| `com.rispeng.MiuUtil.desktop` | Registers the application with the desktop. |
| `com.rispeng.MiuUtil.metainfo.xml` | AppStream description, project links, licensing and releases. |
| `com.rispeng.MiuUtil.gschema.xml` | Stores MiuUtil's window size and maximised state. Setup preferences belong to their own application schemas. |
| `com.rispeng.MiuUtil.policy.in` | Polkit permissions for the fixed helper's system changes and read-only inspection. |
| `meson.build` | Installs desktop integration, schemas, Polkit policy, helpers, recovery files and icons, then updates the relevant caches. |

The resource manifests under `src/` embed the catalogue, download records, configuration payloads, public keys, recovery sources and application icons. Keep those manifests and installation paths consistent when adding or moving files. System operations accept predefined option IDs through the privileged helper.

## Folders

`helpers/` contains the programs used by the selected setup: Home and terminal tab actions, DDC/CI brightness controls, Nautilus actions, Bash history deduplication and Timeshift scheduling and APT hooks. Keep their arguments consistent with the catalogue and payloads. Nautilus passes URI arguments, and history processing must retain multiline entries and timestamps.

The monitor shortcut zeros supported brightness, contrast and RGB gain controls. Its restore action uses each control's reported maximum, with contrast at 75%. Probe the controls directly because a monitor's capabilities list can be incomplete, and read back the result because older `ddcutil` versions do not always honour `--verify`.

`icons/` contains the application and symbolic SVG icons under the standard `hicolor` layout, including the select-all action icon. The desktop entry and resource manifests use these names.

`keys/` contains the official Microsoft and Vivaldi public APT signing keys. Their sources and verification details are recorded below.

`payloads/` contains the configuration adapted from Miubian's integration defaults:

- `bash/` supplies the interactive prompt, tools and history setup through a managed block, preserving the rest of `.bashrc`. `mise/` supplies tool selections, and `git.ini` sets the credential helper without adding a personal name, email, or credentials.
- `firefox/` supplies separate preference and theme blocks in the selected installation's default profile. Keep their full-line markers distinct, hold the native profile lock while writing and preserve existing add-ons. Close Firefox before applying and restart it afterwards.
- `vivaldi/` supplies selected preferences, launcher flags and the persistent horizontal-menu stylesheet. Merge custom panel and toolbar entries, and retain search-engine metadata, sign-in data and dashboard widgets. Check the stylesheet against Vivaldi's current UI structure after an update.
- `mc/` and `mpv/` supply the selected terminal file-manager skin and playback preferences. Merge the defined settings with existing configuration.
- The remaining files supply Nautilus menus, default application and terminal associations, CopyQ autostart, Gear Lever preferences and qView registration. Resolve account and installed-helper paths when applying them. Restart Files or start a new session after installing its extension.

`recovery/` contains the bundled grub-btrfs sources and configuration. Recovery options require an existing compatible Btrfs `@` and `@home` layout; GRUB previews also require `/boot` inside the root subvolume. The snapshot preview holds root writes in RAM while separately mounted data remains writable. Permanent restoration is a separate Timeshift action.

Installed extension files and saved enabled settings can match before GNOME Shell loads them. Sign out and sign in after installing or replacing extension code. Enabling selected extensions must clear the global disable switch and remove their UUIDs from the disabled list, while preserving unrelated enabled and disabled extensions.

## Signing Keys

Public signing keys that should be maintained. APT uses a source-specific `Signed-By` keyring for each vendor repository. These bundled keys were verified on 8 October 2026.

| Vendor | Source | Fingerprint | SHA-256 | Expiry |
| --- | --- | --- | --- | --- |
| [Microsoft](https://code.visualstudio.com/docs/setup/linux) | [microsoft.asc](https://packages.microsoft.com/keys/microsoft.asc) | `BC528686B50D79E339D3721CEB3E94ADBE1229CF` | `2fa9c05d591a1582a9aba276272478c262e95ad00acf60eaee1644d93941e3c6` | N/A |
| [Vivaldi](https://help.vivaldi.com/desktop/install-update/manual-setup-vivaldi-linux-repositories/) | [linux_signing_key.pub](https://repo.vivaldi.com/archive/linux_signing_key.pub) | `8D1FA52AEF58A09D889DD4221256C34716BD9233` | `5c67d85c0aca9c0d166edb5bc5e6ebc21d67bce4e67c645e7bd76d299fd337ef` | 2027-02-07 |

The local files are `keys/microsoft.asc` and `keys/vivaldi.asc`; `N/A` means no expiry. When a vendor rotates a key, verify its official source, primary fingerprint, expiry and digest before replacing the file and updating this table.

## Downloaded software

The account installers download selected software from these official projects. Their exact references and digests are maintained in `upstreams.json`; incompatible GNOME extension releases remain unavailable. Verify the downloaded input when updating a record.

Fluent cursor themes are linked from `~/.icons/fluent` and `~/.icons/fluent-dark`, where native Xcursor applications look for them. Their files remain under the account's data folder or an existing `/usr/share/icons` installation. The icon installer reuses installed assets when repairing these links. Selected cursor folders or links are backed up before replacement, and unrelated themes remain in place. Restart affected applications after applying the cursor setup.

| Input | Official project |
| --- | --- |
| Fluent GTK | [Fluent-gtk-theme](https://github.com/vinceliuice/Fluent-gtk-theme) |
| Fluent icons and cursors | [Fluent-icon-theme](https://github.com/vinceliuice/Fluent-icon-theme) |
| ble.sh | [ble.sh](https://github.com/akinomyoga/ble.sh) |
| Starship | [Starship](https://github.com/starship/starship) |
| Mise | [Mise](https://github.com/jdx/mise) |
| easyvenv | [easyvenv](https://github.com/RisPNG/easyvenv) |
| fetch | [fetch](https://github.com/areofyl/fetch) |
| qView | [qView](https://github.com/jurplel/qView) |
| ModernZ | [ModernZ](https://github.com/Samillion/ModernZ) |
| thumbfast | [thumbfast](https://github.com/po5/thumbfast) |
| Harmonoid | [Official downloads](https://harmonoid.com/downloads/) and [release licence](https://github.com/harmonoid/harmonoid/blob/v0.3.32/LICENSE) |
| Actions for Nautilus | [Actions for Nautilus](https://github.com/bassmanitram/actions-for-nautilus) |
| Homebrew | [Homebrew](https://github.com/Homebrew/brew) |
| rustup | [rustup installation](https://rust-lang.github.io/rustup/installation/other.html) |
| GNOME extensions | [GNOME Extensions](https://extensions.gnome.org/) |

Homebrew retains its native Git checkout for normal updates, with the locked commit verified before first use. Rustup uses its versioned archive endpoint. APT and Flatpak install the versions supplied by the configured repositories when applied. Pacstall's fixed release URL and digest are maintained in the privileged operation.

### Biscuit Firefox theme

**Biscuit {Mojas84}**, version **1.0**, is created by **Mojas84** and published on [Mozilla Add-ons](https://addons.mozilla.org/en-US/firefox/addon/biscuit-mojas84/). Its extension ID is `{9e0d0c26-e659-4f2d-bbeb-25b86baae860}`. The [official metadata](https://addons.mozilla.org/api/v5/addons/addon/biscuit-mojas84/) identifies its licence as **All Rights Reserved**, so MiuUtil downloads the XPI directly for the account applying the option and does not bundle or redistribute it.

- Download: [biscuit_mojas84-1.0.xpi](https://addons.mozilla.org/firefox/downloads/file/4307110/biscuit_mojas84-1.0.xpi)
- SHA-256: `ccb168560029fe7bb9d4a57a956d20068665895a3b18ef5f1d996129494e79b5`
- Size recorded by Mozilla: 7,658 bytes.

The digest is checked before installing a new add-on. A valid existing theme with the same ID is reused without replacing its files; an existing add-on that cannot be verified is retained. `payloads/firefox/theme.js` contains only the preference selecting that theme.

### Bundled grub-btrfs sources

`recovery/grub-btrfs/41_snapshots-btrfs` and `grub-btrfsd` are the upstream source from [grub-btrfs v4.14](https://github.com/Antynea/grub-btrfs/tree/v4.14), retained from Miubian's recovery integration. They retain their copyright notices and **GNU General Public License version 3**, with the complete licence in `recovery/grub-btrfs/grub-btrfs.LICENSE`.

The `config` file derives from Miubian's recovery configuration under the same licence. It selects the Timeshift submenu and overlayroot previews, with its version marker set to `4.14`. Keep the source files, configuration, licence and recorded digests together when updating the integration.

| File | SHA-256 |
| --- | --- |
| `41_snapshots-btrfs` | `7a5dd2a1518856a9071f752fb25770300268c07e314da22d7f9fb214dfa51496` |
| `grub-btrfsd` | `bb8f58e78ff7b9ee056a837d41a923b3c069d558d54765fb4eed16cde49c3fab` |
| `grub-btrfs.LICENSE` | `e1c0ad728983d8a57335e52cf1064f1affd1d454173d8cebd3ed8b4a72b48704` |
