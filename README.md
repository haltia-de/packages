# packages

The Haltia package repositories, served by GitHub Pages at
https://haltia-de.github.io/packages/: apk for Alpine and postmarketOS, apt
for Ubuntu 24.04 and Debian 13, and Flatpak.

## apk

The Haltia apk repository (ADR 0004 in
[haltia-de/haltia](https://github.com/haltia-de/haltia/blob/main/docs/adr/0004-de-apart-from-device.md)):
every released `.apk` of the organization's repositories plus the meta
packages of `meta/`, indexed, signed and served by GitHub Pages at
`https://haltia-de.github.io/packages/alpine/v3.24/<arch>/`.

```sh
wget -O /etc/apk/keys/haltia-de-6ad4bb12.rsa.pub https://haltia-de.github.io/packages/haltia-de-6ad4bb12.rsa.pub
echo https://haltia-de.github.io/packages/alpine/v3.24 >> /etc/apk/repositories
apk update && apk add haltia-desktop haltia-desktop-ru
```

- `haltia-desktop`: the shell, `kit` and the programs for everyone.
- `haltia-desktop-ru`: the programs for Russian services (MAX, Yandex Music,
  Gismeteo).
- `haltia-keys`: the signing key under the name `haltia-de-6ad4bb12` and
  `/etc/apk/repositories.d/haltia.list`.
- `postmarketos-ui-haltia`: Haltia as a postmarketOS user interface; greetd
  logs the first user straight into Haltia (`haltia-greetd-config` writes
  `/etc/greetd/haltia.toml` at every start of greetd), agreety after a
  logout.

Packages are built for armv7, aarch64 and x86_64. A release of a package
repository carries the foreign architectures' files as `name.<arch>.apk`;
this repository files each under the plain name apk asks for, in its
architecture's folder.

Both key files hold the same key. The index is signed under both names, so
either one trusts it, and apk checks each package against the index's hash.
Packages released so far carry the signature `trudenboy-b8k-6ad4bb12`, the
name installed tablets already trust. Signing switches to
`haltia-de-6ad4bb12` once `haltia-keys` is in every image. The index
keeps the three newest versions of each package and every version a
device's `packages.lock` pins (today `linux-port/apps/packages.lock` of
`haltia-de/device-lenovo-b8000h`, read at every build), so pinned versions
and recent downgrades keep working; the apt repository does the same. A
noarch package is a copy in each architecture's folder, since an
`APKINDEX.tar.gz` names files only in its own folder; `publish.yml` prints
the site's size and fails above 950 MB, under the 1 GB that Pages takes.

`build.sh` does the work inside `alpine:3.24`; `publish.yml` runs it, then
the apt and Flatpak builds, on a push, by hand and every 30 minutes.

## apt and Flatpak

`build-apt.sh` (inside `debian:trixie`) files the `.deb` files of the
releases into `apt/pool/main/<suite>` for `noble`, `resolute` and `trixie`, indexes them
with `apt-ftparchive` for amd64 and arm64 (arm64 gets the `all` packages)
and signs `InRelease` and `Release.gpg`. `build-flatpak.sh` imports each
program's newest bundle into an OSTree repository at `flatpak/repo` and
signs it; `flatpak/haltia.flatpakrepo` and one `.flatpakref` per program
point there, with the GNOME runtime from Flathub. The bundles' commits are
kept as they are, so a rebuild without a new release changes nothing for
installed programs.

```sh
sudo curl -fsSLo /usr/share/keyrings/haltia-archive-keyring.gpg https://haltia-de.github.io/packages/apt/haltia-archive-keyring.gpg
echo "deb [signed-by=/usr/share/keyrings/haltia-archive-keyring.gpg] https://haltia-de.github.io/packages/apt $(. /etc/os-release; echo $VERSION_CODENAME) main" | sudo tee /etc/apt/sources.list.d/haltia.list
sudo apt update && sudo apt install haltia-weather

flatpak remote-add --if-not-exists flathub https://dl.flathub.org/repo/flathub.flatpakrepo
flatpak remote-add --if-not-exists haltia https://haltia-de.github.io/packages/flatpak/haltia.flatpakrepo
flatpak install haltia io.github.haltia_de.Weather
```

Both are signed with the organization's GPG key "Haltia packages"
(`keys/haltia-packages.asc`, fingerprint
`1346 1D3E 8077 2926 0DD4 A614 61FC D08B BFE7 462F`, valid until 2031; the
private key is the organization secret `HALTIA_GPG_PRIVKEY`).
`publishers.conf` says which repository may publish which Debian package
names, which Flatpak app id and which apk package names; anything else a
release carries is left out, and every file must match its release
asset's sha256 digest. A new program needs a line there.
