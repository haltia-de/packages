#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the Haltia apt repository (docs/plan-desktop-packages.md in
# haltia-de/device-lenovo-b8000h), inside debian:trixie, after build.sh:
#   docker run --rm -v "$PWD:/src" -e GH_TOKEN -e HALTIA_GPG_PRIVKEY \
#     debian:trixie sh /src/build-apt.sh
# Every .deb of every release in the organization's repositories (named
# name_version_arch.<codename>.deb by haltia-de/ci's deb.yml), per suite:
# Ubuntu 24.04 noble and Debian 13 trixie, component main, amd64 and arm64
# (arm64 gets the Architecture: all packages). Indexed by apt-ftparchive,
# signed (InRelease, Release.gpg). Output: /src/site/apt, served as
#   deb [signed-by=/usr/share/keyrings/haltia-archive-keyring.gpg] https://haltia-de.github.io/packages/apt <suite> main
set -eu
ORG=${ORG:-haltia-de}
SUITES="noble trixie"
ARCHES="amd64 arm64"
APT=/src/site/apt
CACHE=/src/cache/deb

export DEBIAN_FRONTEND=noninteractive
apt-get -qq update
apt-get -qq install -y --no-install-recommends apt-utils ca-certificates curl gnupg jq >/dev/null
export GNUPGHOME=$(mktemp -d)
printf '%s\n' "${HALTIA_GPG_PRIVKEY:?the signing key}" | gpg --batch --quiet --import
KEY=$(gpg --batch --list-secret-keys --with-colons | awk -F: '/^fpr/{print $10; exit}')

api() {
	curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
		-H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

mkdir -p "$CACHE"
rm -rf "$APT"
for repo in $(api "orgs/$ORG/repos?per_page=100" | jq -r '.[] | select(.archived | not) | .name'); do
	page=1
	while :; do
		urls=$(api "repos/$ORG/$repo/releases?per_page=100&page=$page" |
			jq -r '.[] | select(.draft | not) | .assets[] | select(.name | endswith(".deb")) | .browser_download_url')
		[ -n "$urls" ] || break
		for u in $urls; do
			f=$CACHE/${u##*/}
			[ -s "$f" ] || curl -fsSL -o "$f" "$u"
		done
		page=$((page + 1))
	done
done

for s in $SUITES; do
	pool=$APT/pool/main/$s
	mkdir -p "$pool"
	for f in "$CACHE"/*."$s".deb; do
		[ -e "$f" ] || continue
		b=${f##*/}
		cp "$f" "$pool/${b%.$s.deb}.deb"	# back to the standard name
	done
	for a in $ARCHES; do
		d=$APT/dists/$s/main/binary-$a
		mkdir -p "$d"
		( cd "$APT" && apt-ftparchive --arch "$a" packages "pool/main/$s" ) >"$d/Packages"
		gzip -9n -k "$d/Packages"
		echo "$a: $(grep -c '^Package:' "$d/Packages") packages"
	done
	( cd "$APT/dists/$s" && apt-ftparchive \
		-o APT::FTPArchive::Release::Origin=Haltia \
		-o APT::FTPArchive::Release::Label=Haltia \
		-o APT::FTPArchive::Release::Suite="$s" \
		-o APT::FTPArchive::Release::Codename="$s" \
		-o APT::FTPArchive::Release::Architectures="$ARCHES" \
		-o APT::FTPArchive::Release::Components=main \
		-o APT::FTPArchive::Release::Description="Haltia, a calm touch desktop" \
		release . >Release )
	gpg --batch --yes --local-user "$KEY" --clearsign -o "$APT/dists/$s/InRelease" "$APT/dists/$s/Release"
	gpg --batch --yes --local-user "$KEY" -abs -o "$APT/dists/$s/Release.gpg" "$APT/dists/$s/Release"
done
cp /src/keys/haltia-archive-keyring.gpg /src/keys/haltia-packages.asc "$APT/"
rm -rf "$GNUPGHOME"
