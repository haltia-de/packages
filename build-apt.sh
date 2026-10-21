#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the Haltia apt repository (docs/plans/desktop-packages.md in
# haltia-de/haltia), inside debian:trixie, after build.sh:
#   docker run --rm -v "$PWD:/src" -e GH_TOKEN -e HALTIA_GPG_PRIVKEY \
#     debian:trixie sh /src/build-apt.sh
# Every .deb of every release in the organization's repositories (named
# name_version_arch.<codename>.deb by haltia-de/ci's deb.yml), per suite:
# Ubuntu 24.04 noble, Ubuntu 26.04 resolute and Debian 13 trixie, component main, amd64 and arm64
# (arm64 gets the Architecture: all packages). Indexed by apt-ftparchive,
# signed (InRelease, Release.gpg). Output: /src/site/apt, served as
#   deb [signed-by=/usr/share/keyrings/haltia-archive-keyring.gpg] https://haltia-de.github.io/packages/apt <suite> main
set -eu
ORG=${ORG:-haltia-de}
SUITES="noble resolute trixie"
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
rm -rf "$APT" /tmp/allowed
mkdir -p /tmp/allowed
# Only the repositories of publishers.conf, only their own package names,
# and only files whose content is the release's (the asset's digest).
grep -v '^#' /src/publishers.conf | while read -r repo debs _app; do
	[ -n "$repo" ] || continue
	page=1
	while :; do
		releases=$(api "repos/$ORG/$repo/releases?per_page=100&page=$page")
		[ "$(printf '%s\n' "$releases" | jq 'length')" -gt 0 ] || break
		assets=$(printf '%s\n' "$releases" |
			jq -r '.[] | select(.draft | not) | .assets[] | select(.name | endswith(".deb")) | select(.name | startswith("SHA256SUMS") | not) | .browser_download_url + " " + (.digest // "" | ltrimstr("sha256:"))')
		echo "$assets" | while read -r u digest; do
			[ -n "$u" ] || continue
			f=$CACHE/${u##*/}
			if [ -s "$f" ] && [ -n "$digest" ] && [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$digest" ]; then
				rm -f "$f"
			fi
			[ -s "$f" ] || curl -fsSL -o "$f" "$u"
			if [ -z "$digest" ] || [ "$(sha256sum "$f" | cut -d' ' -f1)" != "$digest" ]; then
				echo "skip ${u##*/}: not the release's file"; rm -f "$f"; continue
			fi
			pkg=$(dpkg-deb -f "$f" Package)
			case ",$debs," in
				*",$pkg,"*) ln -sf "$f" /tmp/allowed/ ;;
				*) echo "skip ${u##*/}: $repo may not publish $pkg" ;;
			esac
		done
		page=$((page + 1))
	done
done

for s in $SUITES; do
	pool=$APT/pool/main/$s
	mkdir -p "$pool"
	for f in /tmp/allowed/*."$s".deb; do
		[ -e "$f" ] || continue
		b=${f##*/}
		case $b in *-dbgsym_*) continue ;; esac	# debug symbols: not for this archive
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
