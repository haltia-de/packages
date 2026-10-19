# packages

The Haltia apk repository (ADR 0004 in
[device-lenovo-b8000h](https://github.com/haltia-de/device-lenovo-b8000h)):
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

Both key files hold the same key. The index is signed under both names, so
either one trusts it, and apk checks each package against the index's hash.
Packages released so far carry the signature `trudenboy-b8k-6ad4bb12`, the
name installed tablets already trust. Signing switches to
`haltia-de-6ad4bb12` once `haltia-keys` is in every image. Old
versions stay in the index, so pinned versions and downgrades keep working.

`build.sh` does the work inside `alpine:3.24`; `publish.yml` runs it on a
push, by hand and every 30 minutes.
