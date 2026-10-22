#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the Haltia Flatpak repository (docs/plans/desktop-packages.md in
# haltia-de/haltia) on the Ubuntu runner, after build.sh, with flatpak and
# ostree installed (publish.yml does that before the key is here):
#   GH_TOKEN=… HALTIA_GPG_PRIVKEY=… sh build-flatpak.sh
# The newest valid bundle of each program (made by haltia-de/ci's
# flatpak.yml) is imported into an OSTree repository and signed. The
# commits come from the bundles, so a rebuild without a new release gives
# the same commits and clients see no update. Output: site/flatpak, with
# haltia.flatpakrepo and one .flatpakref per program; the GNOME runtime
# comes from Flathub.
set -eu
ORG=${ORG:-haltia-de}
URL=https://haltia-de.github.io/packages/flatpak
OUT=${OUT:-$PWD/site/flatpak}
CACHE=${CACHE:-$PWD/cache/flatpak}

for c in flatpak ostree; do	# installed by publish.yml before the key is here
	command -v "$c" >/dev/null || { echo "build-flatpak.sh: no $c" >&2; exit 1; }
done
GNUPGHOME=$(mktemp -d)
export GNUPGHOME
printf '%s\n' "${HALTIA_GPG_PRIVKEY:?the signing key}" | gpg --batch --quiet --import
KEY=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')
GPGKEY=$(base64 -w0 keys/haltia-archive-keyring.gpg)

api() {
	curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
		-H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

mkdir -p "$CACHE"
rm -rf "$OUT"
mkdir -p "$OUT"
ostree init --mode=archive-z2 --repo="$OUT/repo"
# Only the repositories of publishers.conf, and only a bundle whose one
# ref is that repository's own app: it is imported into a scratch
# repository first and checked there.
grep -v '^#' publishers.conf | while read -r repo _debs app _apks; do
	[ -n "$repo" ] && [ "$app" != - ] || continue
	# Try bundles newest-first until one passes the digest and ref checks.
	page=1
	found=false
	while :; do
		releases=$(api "repos/$ORG/$repo/releases?per_page=100&page=$page")
		[ "$(printf '%s\n' "$releases" | jq 'length')" -gt 0 ] || break
		assets=$(printf '%s\n' "$releases" |
			jq -r '.[] | select(.draft | not) | .assets[] | select(.name | endswith(".flatpak")) | .browser_download_url + " " + (.digest // "" | ltrimstr("sha256:"))')
		while read -r u digest; do
			[ -n "$u" ] || continue
			f=$CACHE/${u##*/}
			if [ -s "$f" ] && [ -n "$digest" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$digest" ]; then
				rm -f "$f"
			fi
			[ -s "$f" ] || curl -fsSL -o "$f" "$u"
			if [ -z "$digest" ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$digest" ]; then
				echo "skip ${u##*/}: not the release's file"; rm -f "$f"; continue
			fi
			scratch=$(mktemp -d)
			ostree init --mode=archive-z2 --repo="$scratch"
			flatpak build-import-bundle --no-update-summary "$scratch" "$f" >/dev/null
			refs=$(ostree refs --repo="$scratch" | grep -v '^appstream' | sort)
			want=$(printf 'app/%s/x86_64/master' "$app")
			if [ "$refs" != "$want" ]; then
				echo "skip ${u##*/}: carries $(echo "$refs" | paste -sd' '), not $want"; rm -rf "$scratch"; continue
			fi
			rm -rf "$scratch"
			echo "$repo: $app from ${u##*/}"
			flatpak build-import-bundle --gpg-sign="$KEY" --gpg-homedir="$GNUPGHOME" "$OUT/repo" "$f"
			found=true
			break
		done <<ASSETS
$assets
ASSETS
		[ "$found" = false ] || break
		page=$((page + 1))
	done
	[ "$found" = true ] || continue
	cat >"$OUT/$app.flatpakref" <<REF
[Flatpak Ref]
Name=$app
Branch=master
Title=$app from Haltia
Url=$URL/repo/
SuggestRemoteName=haltia
Homepage=https://github.com/$ORG/$repo
RuntimeRepo=https://dl.flathub.org/repo/flathub.flatpakrepo
IsRuntime=false
GPGKey=$GPGKEY
REF
done
flatpak build-update-repo --gpg-sign="$KEY" --gpg-homedir="$GNUPGHOME" \
	--title=Haltia --default-branch=master "$OUT/repo"
cat >"$OUT/haltia.flatpakrepo" <<REPO
[Flatpak Repo]
Title=Haltia
Url=$URL/repo/
Homepage=https://github.com/$ORG
Comment=Programs of Haltia, a calm touch desktop
DefaultBranch=master
GPGKey=$GPGKEY
REPO
rm -rf "$GNUPGHOME"
