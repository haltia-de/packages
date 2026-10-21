#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""fetch-apks.py PUBLISHERS STORE OUT < ASSETS: the released apks to index.

ASSETS has one release asset per line: "REPOSITORY URL SHA256", the
repository of haltia-de that released it, its download URL and the
asset's digest. An asset is taken only when its repository has an apk
column in PUBLISHERS (publishers.conf), its bytes match the digest and
the pkgname of its .PKGINFO is one of that column's names; anything else
is left out with a warning. STORE keeps the files under their digest
(SHA256.apk): a file is downloaded into a temporary file and renamed only
when it matches, and what no current asset names is removed, so replaced
and withdrawn files go. OUT gets a link to each file taken. build.sh runs
it in alpine:3.24; tests/run.sh runs it with a fake asset list.
"""
import hashlib
import os
import re
import sys
import tarfile
import tempfile
import urllib.request


def publishers(path):
    """{repository: {apk names}} of publishers.conf's fourth column."""
    allowed = {}
    with open(path, encoding="utf-8") as conf:
        for line in conf:
            fields = line.split()
            if not fields or fields[0].startswith("#"):
                continue
            names = fields[3] if len(fields) > 3 else "-"
            allowed[fields[0]] = set() if names == "-" else set(names.split(","))
    return allowed


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def pkgname(path):
    """The pkgname of an .apk's .PKGINFO, or None."""
    try:
        with tarfile.open(path, "r:gz", ignore_zeros=True) as tar:
            for member in tar:
                if member.name == ".PKGINFO" and member.isfile():
                    for line in tar.extractfile(member).read().decode("utf-8", "replace").splitlines():
                        key, _sep, value = line.partition(" = ")
                        if key == "pkgname":
                            return value
                    return None
    except (tarfile.TarError, OSError, EOFError):
        return None
    return None


def download(url, store):
    """The asset at url, in a temporary file in store."""
    fd, part = tempfile.mkstemp(dir=store, prefix=".part-")
    with os.fdopen(fd, "wb") as out, urllib.request.urlopen(url, timeout=300) as response:
        for block in iter(lambda: response.read(1 << 20), b""):
            out.write(block)
    return part


def main():
    allowed = publishers(sys.argv[1])
    store, out = sys.argv[2], sys.argv[3]
    os.makedirs(store, exist_ok=True)
    os.makedirs(out, exist_ok=True)
    taken = set()
    for line in sys.stdin:
        fields = line.split()
        if len(fields) < 2:
            continue
        repo, url = fields[0], fields[1]
        digest = fields[2].lower() if len(fields) > 2 else ""
        asset = url.rsplit("/", 1)[-1]
        names = allowed.get(repo, set())
        if not names:
            print(f"skip {asset}: {repo} may publish no apk", file=sys.stderr)
            continue
        if not re.fullmatch(r"[0-9a-f]{64}", digest):
            print(f"skip {asset}: no sha256 digest", file=sys.stderr)
            continue
        if digest in taken:
            continue
        kept = os.path.join(store, digest + ".apk")
        if not (os.path.isfile(kept) and sha256(kept) == digest):
            part = download(url, store)
            if sha256(part) != digest:
                os.remove(part)
                print(f"skip {asset}: not the release's file", file=sys.stderr)
                continue
            os.replace(part, kept)
        name = pkgname(kept)
        if name not in names:
            os.remove(kept)
            print(f"skip {asset}: {repo} may not publish {name}", file=sys.stderr)
            continue
        link = os.path.join(out, digest + ".apk")
        if os.path.lexists(link):
            os.remove(link)
        os.symlink(os.path.abspath(kept), link)
        taken.add(digest)
    # The store keeps only what the current releases name.
    for entry in os.listdir(store):
        if entry[:-len(".apk")] not in taken or not entry.endswith(".apk"):
            os.remove(os.path.join(store, entry))
    print(f"released: {len(taken)} packages")
    return 0


if __name__ == "__main__":
    sys.exit(main())
