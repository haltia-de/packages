#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# The tests of this repository, offline: sh tests/run.sh
# fetch-apks.py with a fake asset list (file:// URLs): every apk name of
# publishers.conf is taken from its repository, a foreign name, an unlisted
# repository, a wrong digest and a missing digest are left out, and the
# store keeps only the files taken. The build scripts call the scripts of
# this repository with the arguments their usage names. The build scripts
# parse, install nothing where a signing key is, and build.sh checks the
# pinned versions and apk verify before it signs.
set -eu
cd "$(dirname "$0")/.."
tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
fail() { echo "FAIL: $*"; exit 1; }

# A minimal apk: a gzipped tar with a .PKGINFO.
mkapk() {
	d=$tmp/src/$1-$2
	mkdir -p "$d"
	printf 'pkgname = %s\npkgver = %s\narch = noarch\n' "$1" "$2" >"$d/.PKGINFO"
	tar -czf "$tmp/files/$1-$2.apk" -C "$d" .PKGINFO
	echo "$tmp/files/$1-$2.apk"
}
asset() {	# repository file [digest]
	echo "$1 file://$2 ${3-$(sha256sum "$2" | cut -d' ' -f1)}" >>"$tmp/assets"
}

mkdir -p "$tmp/files" "$tmp/store"
: >"$tmp/assets"
grep -v '^#' publishers.conf | while read -r repo _debs _app apks; do
	[ -n "$repo" ] && [ "$apks" != - ] || continue
	for n in $(echo "$apks" | tr , ' '); do
		asset "$repo" "$(mkapk "$n" 1.0.0-r0)"
	done
done
expected=$(wc -l <"$tmp/assets")
[ "$expected" -eq 41 ] || fail "publishers.conf: $expected apk names, not 41"
# The same file in two releases is taken once.
head -1 "$tmp/assets" >>"$tmp/assets"
# A name of another repository, an unlisted repository, a file that is not
# the release's and one without a digest.
asset paint "$(mkapk haltia-shell 9.9.9-r0)"
asset device-lenovo-b8000h "$(mkapk haltia-shell 9.9.8-r0)"
asset text "$(mkapk haltia-text 2.0.0-r0)" 0000000000000000000000000000000000000000000000000000000000000000
asset text "$(mkapk haltia-text 2.0.1-r0)" ""
# Left over from earlier builds: a withdrawn file and a broken download.
echo old >"$tmp/store/1111111111111111111111111111111111111111111111111111111111111111.apk"
echo part >"$tmp/store/.part-x"

python3 fetch-apks.py publishers.conf "$tmp/store" "$tmp/out" <"$tmp/assets" >"$tmp/log" 2>&1 ||
	{ cat "$tmp/log"; fail "fetch-apks.py exited with an error"; }
cat "$tmp/log"
grep -qx "released: $expected packages" "$tmp/log" || fail "released: not $expected"
for w in "haltia-shell-9.9.9-r0.apk: paint may not publish haltia-shell" \
	"haltia-shell-9.9.8-r0.apk: device-lenovo-b8000h may publish no apk" \
	"haltia-text-2.0.0-r0.apk: not the release's file" \
	"haltia-text-2.0.1-r0.apk: no sha256 digest"; do
	grep -qxF "skip $w" "$tmp/log" || fail "no warning: $w"
done
[ "$(ls -A "$tmp/store" | wc -l)" -eq "$expected" ] || fail "store: $(ls -A "$tmp/store" | wc -l) files, not $expected"
[ "$(ls -A "$tmp/out" | wc -l)" -eq "$expected" ] || fail "out: $(ls -A "$tmp/out" | wc -l) files, not $expected"
# Every name of publishers.conf is in out, nothing else.
for f in "$tmp"/out/*.apk; do
	tar -xOzf "$f" .PKGINFO | sed -n 's/^pkgname = //p'
done | sort >"$tmp/taken"
grep -v '^#' publishers.conf | awk 'NF >= 4 && $4 != "-" { print $4 }' | tr , '\n' | sort >"$tmp/names"
cmp -s "$tmp/taken" "$tmp/names" || { diff "$tmp/names" "$tmp/taken"; fail "taken names differ from publishers.conf"; }

# A second build: the store is reused, a withdrawn asset goes, and a
# cached file whose bytes changed is downloaded again.
left=$((expected - 1))
head -n "$left" "$tmp/assets" >"$tmp/assets2"
victim=$(head -1 "$tmp/assets2" | cut -d' ' -f3)
echo broken >"$tmp/store/$victim.apk"
rm -rf "$tmp/out"
python3 fetch-apks.py publishers.conf "$tmp/store" "$tmp/out" <"$tmp/assets2" >"$tmp/log" 2>&1 ||
	{ cat "$tmp/log"; fail "fetch-apks.py exited with an error the second time"; }
grep -qx "released: $left packages" "$tmp/log" || { cat "$tmp/log"; fail "second build: released not $left"; }
[ "$(ls -A "$tmp/store" | wc -l)" -eq "$left" ] || fail "second build: store has $(ls -A "$tmp/store" | wc -l) files, not $left"
[ "$(sha256sum "$tmp/store/$victim.apk" | cut -d' ' -f1)" = "$victim" ] || fail "a changed cached file was kept"
echo "ok: fetch-apks.py"

# Every call of a script of this repository in the build scripts passes as
# many arguments as the script's usage line names (two words run together
# would pass one).
grep -h '^[[:space:]]*python3 /src/[a-z-]*\.py' build.sh build-apt.sh | while read -r call; do
	script=$(echo "$call" | sed 's|^python3 /src/\([a-z-]*\.py\).*|\1|')
	want=$(sed -n '3s/^"""[^ ]* \([^:<]*\).*/\1/p' "$script" | wc -w)
	got=$(sh -c "python3() { echo \$((\$# - 1)); }; ${call%%[<>]*}")
	[ "$got" -eq "$want" ] || fail "$call: $got arguments, not $want"
	echo "ok: $script, $want arguments"
done

# The build scripts parse.
for s in build.sh build-apt.sh build-flatpak.sh; do
	sh -n "$s" || fail "$s does not parse"
done
echo "ok: the build scripts parse"

# The signing keys go only where nothing is installed: the build scripts
# install nothing, the images of publish.yml are pinned by digest, and no
# step that gets a secret installs anything.
if grep -nE 'apk add|apt-get|pip install' build.sh build-apt.sh build-flatpak.sh; then
	fail "a build script installs packages"
fi
grep -E '^[[:space:]]*FROM ' .github/workflows/publish.yml >"$tmp/from" ||
	fail "publish.yml builds no image"
if grep -vE 'FROM [a-z0-9.:/-]+@sha256:[0-9a-f]{64}$' "$tmp/from"; then
	fail "an image of publish.yml is not pinned by digest"
fi
if grep -nE 'docker run .* (alpine|debian|ubuntu)[:@ ]' .github/workflows/publish.yml; then
	fail "publish.yml runs a base image instead of its own"
fi
awk '/^      - /{ n++ } { print n, $0 }' .github/workflows/publish.yml >"$tmp/steps"
for n in $(grep 'secrets\.' "$tmp/steps" | cut -d' ' -f1 | sort -u); do
	if grep "^$n " "$tmp/steps" | grep -E 'apk add|apt-get|docker build|pip install'; then
		fail "publish.yml: a step with a secret installs packages"
	fi
done
echo "ok: nothing is installed where a key is"

# build.sh checks the pinned versions and runs apk verify before it signs
# an index, and builds the meta packages reproducibly.
signs=$(grep -n 'sign_both APKINDEX' build.sh | cut -d: -f1)
for c in 'pinned $p is not in the repository' 'apk verify "$f"' '[ "$bad" = 0 ] || exit 1'; do
	at=$(grep -nF "$c" build.sh | head -1 | cut -d: -f1)
	[ -n "$at" ] && [ "$at" -lt "$signs" ] || fail "build.sh: no '$c' before signing"
done
grep -qF 'SOURCE_DATE_EPOCH=$epoch abuild' build.sh || fail "build.sh: the meta packages are not reproducible"
echo "ok: build.sh checks before it signs"
