# AGENTS.md

## What this is

The Haltia package repositories, served by GitHub Pages at
https://haltia-de.github.io/packages/: apk for Alpine and postmarketOS
(`alpine/v3.24/<arch>/`), apt for Ubuntu 24.04, 26.04 and Debian 13
(`apt/`), and Flatpak (`flatpak/`). It collects the released files of the
organization's other repositories, adds its own meta packages, indexes and
signs everything. It has no program and no program id of its own. Decisions
and plans live in [haltia-de/haltia](https://github.com/haltia-de/haltia):
ADR 0004 and `docs/plans/desktop-packages.md`.

## Where things are

- `build.sh`: the apk repository, run inside `alpine:3.24`; downloads every
  `.apk` of every release in the organization, builds `meta/`, sorts by
  architecture (armv7, aarch64, x86_64), indexes and signs under both key
  names, writes `site/`.
- `keep-versions.py`: which files `build.sh` and `build-apt.sh` leave out:
  all but the three newest versions of each package, except the versions
  the devices' `packages.lock` pin (the `LOCKS` of both scripts).
- `build-appstream.py`: the AppStream catalog `appstream.xml.gz` next to the
  apk index, called by `build.sh`.
- `build-apt.sh`: the apt repository, run inside `debian:trixie` after
  `build.sh`; suites `noble`, `resolute`, `trixie`, amd64 and arm64.
- `build-flatpak.sh`: the OSTree repository at `site/flatpak/repo` with
  `haltia.flatpakrepo` and one `.flatpakref` per program.
- `publishers.conf`: who may publish what into apt and Flatpak. One line per
  repository of haltia-de: its allowed Debian package names (comma
  separated) and its Flatpak app id (`-` for none). Anything else a release
  carries is left out. A new program needs a line here.
- `meta/`: the meta packages (`haltia-desktop`, `haltia-desktop-ru`,
  `haltia-keys`, `postmarketos-ui-haltia`), one `APKBUILD` each.
- `keys/`: public keys only (apk keys under both names, the GPG key
  "Haltia packages" and its keyring).
- `site-index.html`: the page at the site's root.
- `.github/workflows/publish.yml`: runs the three builds and deploys Pages.

## Running

Everything runs in CI: `publish.yml` runs on a push to `main`, by hand and
every 30 minutes, so a new release anywhere shows up without a trigger. A
local run needs the signing secrets (`B8K_APK_PRIVKEY`,
`HALTIA_GPG_PRIVKEY`) and `GH_TOKEN`; the commands are in each script's
header comment. Do not try to run them without being asked.

## Releases

This repository has no tags and no `NEWS.md`: a merge to `main` is
published within minutes. Programs are released in their own repositories
(tag `vX.Y.Z`, `NEWS.md`, the reusable workflows of `haltia-de/ci`) and
picked up from there. Changing a meta package's `pkgver` or `pkgrel`, its
dependencies, the keys or `publishers.conf` reaches every installed
device, so it counts as a release and needs the user's approval.

## Rules

Follow the shared conventions:
https://github.com/haltia-de/haltia/blob/main/docs/conventions.md
