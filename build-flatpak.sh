#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the Haltia Flatpak repository (docs/plan-desktop-packages.md in
# haltia-de/device-lenovo-b8000h) on the Ubuntu runner, after build.sh:
#   GH_TOKEN=… HALTIA_GPG_PRIVKEY=… sh build-flatpak.sh
# The bundle of each program's newest release (made by haltia-de/ci's
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

command -v flatpak >/dev/null || { sudo apt-get -qq update && sudo apt-get -qq install -y flatpak >/dev/null; }
export GNUPGHOME=$(mktemp -d)
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
for repo in $(api "orgs/$ORG/repos?per_page=100" | jq -r '.[] | select(.archived | not) | .name'); do
	# The newest release that has a bundle.
	u=$(api "repos/$ORG/$repo/releases?per_page=30" |
		jq -r '[.[] | select(.draft | not) | select(any(.assets[]; .name | endswith(".flatpak")))][0].assets[]? | select(.name | endswith(".flatpak")) | .browser_download_url' | head -1)
	[ -n "$u" ] || continue
	f=$CACHE/${u##*/}
	[ -s "$f" ] || curl -fsSL -o "$f" "$u"
	app=${f##*/}
	app=${app%%-[0-9]*}
	echo "$repo: $app from ${u##*/}"
	flatpak build-import-bundle --gpg-sign="$KEY" --gpg-homedir="$GNUPGHOME" "$OUT/repo" "$f"
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
