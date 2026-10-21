#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""keep-versions.py apk|deb KEEP < LIST: what to leave out of a repository.

LIST has one package file per line: "GROUP VERSION PINNED PATH", GROUP
being what versions are counted in (a package name in one architecture's
folder or suite), PINNED 1 for a version a device's packages.lock pins
and 0 otherwise. Printed are the PATHs that are neither among the newest
KEEP versions of their GROUP nor pinned. Versions are compared by apk
(build.sh, in alpine:3.24) or dpkg (build-apt.sh, in debian:trixie).
"""
import functools
import subprocess
import sys


def compare_apk(a, b):
    out = subprocess.run(["apk", "version", "-t", a, b], capture_output=True,
                         text=True).stdout.strip()
    return {"<": -1, ">": 1}.get(out, 0)


def compare_deb(a, b):
    if subprocess.run(["dpkg", "--compare-versions", a, "lt", b]).returncode == 0:
        return -1
    if subprocess.run(["dpkg", "--compare-versions", a, "gt", b]).returncode == 0:
        return 1
    return 0


def main():
    compare = {"apk": compare_apk, "deb": compare_deb}[sys.argv[1]]
    keep = int(sys.argv[2])
    groups = {}
    for line in sys.stdin:
        fields = line.split(None, 3)
        if len(fields) != 4:
            continue
        group, version, pinned, path = fields
        groups.setdefault(group, []).append((version, pinned == "1", path.rstrip("\n")))
    for group in sorted(groups):
        files = groups[group]
        versions = sorted({v for v, _p, _f in files},
                          key=functools.cmp_to_key(compare), reverse=True)
        newest = set(versions[:keep])
        for version, pinned, path in files:
            if version not in newest and not pinned:
                print(path)
    return 0


if __name__ == "__main__":
    sys.exit(main())
