#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the Haltia apk repository (ADR 0004, phase B), inside alpine:3.24:
#   docker run --rm -v "$PWD:/src" -e GH_TOKEN -e B8K_APK_PRIVKEY \
#     alpine:3.24 sh /src/build.sh
# Every .apk of every release in the organization's repositories (old
# versions stay, so pinned versions and downgrades keep working), plus the
# meta packages of meta/, sorted by architecture (noarch into each), indexed
# and signed, and the AppStream catalog of their metainfo
# (build-appstream.py). Output: /src/site, served by GitHub Pages as
#   https://haltia-de.github.io/packages/alpine/v3.24/<arch>/
#   https://haltia-de.github.io/packages/alpine/v3.24/appstream.xml.gz
set -eu
ORG=${ORG:-haltia-de}
ALPINE=v3.24
ARCHES="armv7 aarch64 x86_64"
KEYNAME=trudenboy-b8k-6ad4bb12	# what installed tablets already trust
NEWKEY=haltia-de-6ad4bb12	# the same key under the organization's name
SITE=/src/site
CACHE=/src/cache

apk add -q --no-cache alpine-sdk curl jq tar python3
mkdir -p /root/.abuild "$CACHE" /tmp/meta
printf '%s\n' "${B8K_APK_PRIVKEY:?the signing key}" >/root/.abuild/$KEYNAME.rsa
chmod 600 /root/.abuild/$KEYNAME.rsa
cp /root/.abuild/$KEYNAME.rsa /root/.abuild/$NEWKEY.rsa
cp /src/keys/$KEYNAME.rsa.pub /root/.abuild/
cp /src/keys/$KEYNAME.rsa.pub /etc/apk/keys/
{
	echo "PACKAGER_PRIVKEY=/root/.abuild/$KEYNAME.rsa"
	echo 'PACKAGER="Haltia <noreply@github.com>"'
} >/root/.abuild/abuild.conf

api() {
	curl -fsSL ${GH_TOKEN:+-H "Authorization: Bearer $GH_TOKEN"} \
		-H "Accept: application/vnd.github+json" "https://api.github.com/$1"
}

# Sign an index under both key names, as abuild-sign does for one: each
# signature covers the bare index, so they are made first and then put in
# front of it together (signing twice would cover the first signature).
sign_both() {
	idx=$1
	sigs=$(mktemp)
	for k in $KEYNAME $NEWKEY; do
		s=.SIGN.RSA.$k.rsa.pub
		openssl dgst -sha1 -sign /root/.abuild/$k.rsa -out "$s" "$idx"
		tar -c --owner=0 --group=0 --numeric-owner "$s" | abuild-tar --cut | gzip -n -9 >>"$sigs"
		rm -f "$s"
	done
	cat "$sigs" "$idx" >"$idx.signed"
	rm -f "$sigs"
	mv "$idx.signed" "$idx"
	chmod 644 "$idx"
}

# The released packages.
repo_page=1
while :; do
	repositories=$(api "orgs/$ORG/repos?per_page=100&page=$repo_page")
	[ "$(printf '%s\n' "$repositories" | jq 'length')" -gt 0 ] || break
	repos=$(printf '%s\n' "$repositories" | jq -r '.[] | select(.archived | not) | .name')
	for repo in $repos; do
		page=1
		while :; do
			releases=$(api "repos/$ORG/$repo/releases?per_page=100&page=$page")
			[ "$(printf '%s\n' "$releases" | jq 'length')" -gt 0 ] || break
			urls=$(printf '%s\n' "$releases" |
				jq -r '.[] | select(.draft | not) | .assets[] | select(.name | endswith(".apk")) | .browser_download_url')
			for u in $urls; do
				f=$CACHE/${u##*/}
				[ -s "$f" ] || curl -fsSL -o "$f" "$u"
			done
			page=$((page + 1))
		done
	done
	repo_page=$((repo_page + 1))
done

# The meta packages.
for d in /src/meta/*/; do
	n=$(basename "$d")
	rm -rf "/tmp/meta/$n"
	cp -r "$d" "/tmp/meta/$n"
	( cd "/tmp/meta/$n" && abuild -F checksum && abuild -F -d -P /tmp/metarepo )
done
find /tmp/metarepo -name '*.apk' -exec cp {} "$CACHE/" \;

# Sort, index, sign.
rm -rf "$SITE"
for a in $ARCHES; do mkdir -p "$SITE/alpine/$ALPINE/$a"; done
for f in "$CACHE"/*.apk; do
	arch=$(gzip -dc "$f" | tar -xOif - .PKGINFO 2>/dev/null | sed -n 's/^arch = //p' | head -1)
	case $arch in
		noarch) targets=$ARCHES ;;
		armv7|aarch64|x86_64) targets=$arch ;;
		*) echo "skip $f: arch '$arch'" >&2; continue ;;
	esac
	# Under the plain name apk asks for (a release names the foreign
	# architectures' files name.<arch>.apk).
	name=$(gzip -dc "$f" | tar -xOif - .PKGINFO 2>/dev/null | sed -n 's/^pkgname = //p' | head -1)
	ver=$(gzip -dc "$f" | tar -xOif - .PKGINFO 2>/dev/null | sed -n 's/^pkgver = //p' | head -1)
	for a in $targets; do cp "$f" "$SITE/alpine/$ALPINE/$a/$name-$ver.apk"; done
done
for a in $ARCHES; do
	( cd "$SITE/alpine/$ALPINE/$a"
	  ls ./*.apk >/dev/null 2>&1 || continue
	  apk index --no-warnings --quiet --output APKINDEX.tar.gz \
		--description "Haltia $ALPINE $(date -u +%Y-%m-%d)" --rewrite-arch "$a" ./*.apk
	  sign_both APKINDEX.tar.gz
	  echo "$a: $(ls ./*.apk | wc -l) packages" )
done
# What is new in each version, for haltia-update and software centres: the
# AppStream catalog of the newest packages, next to the indexes.
python3 /src/build-appstream.py "$CACHE" "$SITE/alpine/$ALPINE/appstream.xml.gz"
cp /src/keys/*.rsa.pub "$SITE/"
cp /src/site-index.html "$SITE/index.html"
