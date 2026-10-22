#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the Haltia apk repository (ADR 0004, phase B), inside the image
# haltia-apk that publish.yml builds (alpine:3.24 with the tools; nothing is
# installed here, where the signing key is):
#   docker run --rm -v "$PWD:/src" -e GH_TOKEN -e B8K_APK_PRIVKEY \
#     haltia-apk sh /src/build.sh
# Every .apk of every release in the organization's repositories that
# publishers.conf lets its repository publish and that matches its asset's
# digest (fetch-apks.py), plus the meta packages of meta/, sorted by architecture (noarch into each), the
# three newest versions of each package and every version a device's
# packages.lock pins (keep-versions.py), checked (every pinned version is
# there and every file passes apk verify, or the build fails and the old
# site stays), indexed and signed, and the
# AppStream catalog of their metainfo (build-appstream.py). Output:
# /src/site, served by GitHub Pages as
#   https://haltia-de.github.io/packages/alpine/v3.24/<arch>/
#   https://haltia-de.github.io/packages/alpine/v3.24/appstream.xml.gz
set -eu
ORG=${ORG:-haltia-de}
ALPINE=v3.24
ARCHES="armv7 aarch64 x86_64"
KEYNAME=trudenboy-b8k-6ad4bb12	# what installed tablets already trust
NEWKEY=haltia-de-6ad4bb12	# the same key under the organization's name
SITE=/src/site
STORE=/src/cache/apk	# the released files, by digest (fetch-apks.py)
APKS=/tmp/apks.d	# what this build indexes: the released and meta packages
KEEP=3	# versions of each package in the index
# The devices' packages.lock (name repository version file sha256): the
# versions their images pin stay installable.
LOCKS="haltia-de/device-lenovo-b8000h/main/linux-port/apps/packages.lock"

for c in abuild apk curl git jq python3; do
	command -v "$c" >/dev/null || { echo "build.sh: no $c, run it in the image of publish.yml" >&2; exit 1; }
done
rm -rf "$APKS"
rm -f /src/cache/*.apk	# the cache by file name of older builds
mkdir -p /root/.abuild "$STORE" "$APKS" /tmp/meta /src/cache/meta
printf '%s\n' "${B8K_APK_PRIVKEY:?the signing key}" >/root/.abuild/$KEYNAME.rsa
chmod 600 /root/.abuild/$KEYNAME.rsa
cp /root/.abuild/$KEYNAME.rsa /root/.abuild/$NEWKEY.rsa
cp /src/keys/$KEYNAME.rsa.pub /root/.abuild/
cp /src/keys/*.rsa.pub /etc/apk/keys/	# apk verify: both names
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

# The released packages: the current release assets of every repository,
# taken by fetch-apks.py only when publishers.conf lets the repository
# publish the package's name and the file matches the asset's digest.
: >/tmp/assets
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
			printf '%s\n' "$releases" |
				jq -r --arg repo "$repo" '.[] | select(.draft | not) | .assets[] | select(.name | endswith(".apk")) | $repo + " " + .browser_download_url + " " + (.digest // "" | ltrimstr("sha256:"))' >>/tmp/assets
			page=$((page + 1))
		done
	done
	repo_page=$((repo_page + 1))
done
python3 /src/fetch-apks.py /src/publishers.conf "$STORE" "$APKS" </tmp/assets
# The versions the devices pin, as "repository file", under the plain name
# (a release names the foreign architectures' files name.<arch>.apk).
: >/tmp/locked
for l in $LOCKS; do
	curl -fsSL -o /tmp/packages.lock "https://raw.githubusercontent.com/$l"
	awk '!/^#/ && NF >= 4 { print $2, $4 }' /tmp/packages.lock |
		sed -e 's/\.armv7\.apk$/.apk/' -e 's/\.aarch64\.apk$/.apk/' -e 's/\.x86_64\.apk$/.apk/' >>/tmp/locked
done
cut -d' ' -f2 /tmp/locked >/tmp/pinned
echo "pinned: $(wc -l </tmp/pinned) packages"

# The meta packages, the same file as long as their folder is the same:
# kept in cache/meta under the sha256 of the folder and built only when it
# changes, reproducibly (SOURCE_DATE_EPOCH is the folder's last commit).
# A new file under the same name in every build would let a client get the
# index of one build and the package of the next, and fail the checksum.
: >/tmp/meta-kept
for d in /src/meta/*/; do
	n=$(basename "$d")
	sum=$(cd "$d" && find . -type f | LC_ALL=C sort | xargs sha256sum | sha256sum | cut -d' ' -f1)
	kept=/src/cache/meta/$n-$sum.apk
	if [ ! -s "$kept" ]; then
		epoch=$(git -C /src -c safe.directory=/src log -1 --format=%ct -- "meta/$n")
		[ -n "$epoch" ] || { echo "build.sh: meta/$n has no commit" >&2; exit 1; }
		rm -rf "/tmp/meta/$n" /tmp/metarepo
		cp -r "$d" "/tmp/meta/$n"
		( cd "/tmp/meta/$n" && abuild -F checksum &&
		  SOURCE_DATE_EPOCH=$epoch abuild -F -d -P /tmp/metarepo )
		find /tmp/metarepo -name '*.apk' -exec cp {} "$kept.part" \;
		mv "$kept.part" "$kept"
		echo "$n: built"
	fi
	cp "$kept" "$APKS/meta-$n.apk"
	echo "${kept##*/}" >>/tmp/meta-kept
done
for f in /src/cache/meta/*; do
	grep -qxF "${f##*/}" /tmp/meta-kept || rm -f "$f"
done

# Sort, index, sign.
rm -rf "$SITE"
: >/tmp/apks
for a in $ARCHES; do mkdir -p "$SITE/alpine/$ALPINE/$a"; done
for f in "$APKS"/*.apk; do
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
	pinned=0
	if grep -qxF "$name-$ver.apk" /tmp/pinned; then pinned=1; fi
	for a in $targets; do
		cp "$f" "$SITE/alpine/$ALPINE/$a/$name-$ver.apk"
		echo "$a/$name $ver $pinned $SITE/alpine/$ALPINE/$a/$name-$ver.apk" >>/tmp/apks
	done
done
# Older versions go from the folders, and so from the indexes made of them.
# A noarch package stays a copy in each folder: an APKINDEX.tar.gz cannot
# point to a file outside its own folder.
python3 /src/keep-versions.py apk "$KEEP" </tmp/apks >/tmp/old
echo "older versions left out: $(wc -l </tmp/old) files"
xargs -r rm -f </tmp/old
# Nothing is signed unless every version a device of the organization pins
# is there and every file passes apk verify: a failed build keeps the old
# site.
bad=0
for p in $(awk -v org="$ORG/" 'index($1, org) == 1 { print $2 }' /tmp/locked | sort -u); do
	ls "$SITE/alpine/$ALPINE"/*/"$p" >/dev/null 2>&1 ||
		{ echo "build.sh: pinned $p is not in the repository" >&2; bad=1; }
done
for f in "$SITE/alpine/$ALPINE"/*/*.apk; do
	[ -e "$f" ] || continue
	apk verify "$f" >/dev/null 2>&1 ||
		{ echo "build.sh: $f fails apk verify" >&2; bad=1; }
done
[ "$bad" = 0 ] || exit 1
for a in $ARCHES; do
	ls "$SITE/alpine/$ALPINE/$a"/*.apk >/dev/null 2>&1 || continue
	( cd "$SITE/alpine/$ALPINE/$a"
	  apk index --no-warnings --quiet --output APKINDEX.tar.gz \
		--description "Haltia $ALPINE $(date -u +%Y-%m-%d)" --rewrite-arch "$a" ./*.apk
	  sign_both APKINDEX.tar.gz
	  echo "$a: $(ls ./*.apk | wc -l) packages" )
done
# What is new in each version, for haltia-update and software centres: the
# AppStream catalog of the newest packages, next to the indexes.
python3 /src/build-appstream.py "$APKS" "$SITE/alpine/$ALPINE/appstream.xml.gz"
cp /src/keys/*.rsa.pub "$SITE/"
cp /src/site-index.html "$SITE/index.html"
