#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""build-appstream.py FOLDER OUT: the AppStream catalog of the repository.

Every component (usr/share/metainfo/*.xml) of the newest version of each
package in FOLDER (*.apk), with its <pkgname>, as one gzipped catalog
(<components>, AppStream's collection format) at OUT. build.sh puts it next
to the apk index, as alpine/<release>/appstream.xml.gz: haltia-update reads
what is new in a version from it (the <releases>, which the repositories
write from their NEWS.md) instead of downloading the package, and software
centres can read it as well. Run where apk is (alpine:3.24): versions are
compared by apk itself.
"""
import glob
import gzip
import os
import subprocess
import sys
import tarfile
import xml.etree.ElementTree as ET
import xml.parsers.expat as xml_parsers


def package(path):
    """(name, version, [metainfo bytes]) of an .apk."""
    name = version = None
    metas = []
    with tarfile.open(path, "r:gz", ignore_zeros=True) as tar:
        for member in tar:
            if not member.isfile():
                continue
            if member.name == ".PKGINFO":
                for line in tar.extractfile(member).read().decode("utf-8", "replace").splitlines():
                    key, _sep, value = line.partition(" = ")
                    if key == "pkgname":
                        name = value
                    elif key == "pkgver":
                        version = value
            elif member.name.startswith("usr/share/metainfo/") and member.name.endswith(".xml"):
                metas.append(tar.extractfile(member).read())
    return name, version, metas


def parse_xml(data):
    """A metainfo, refused when it declares a document type or an entity
    (expat looks first, in whatever encoding it is)."""
    def refuse(*_args):
        raise ET.ParseError("no DTDs or entities")
    scan = xml_parsers.ParserCreate()
    scan.StartDoctypeDeclHandler = refuse
    scan.EntityDeclHandler = refuse
    scan.Parse(data, True)
    return ET.fromstring(data)


def compare(a, b):
    out = subprocess.run(["apk", "version", "-t", a, b], capture_output=True,
                         text=True).stdout.strip()
    return {"<": -1, ">": 1}.get(out, 0)


def main():
    folder, out = sys.argv[1], sys.argv[2]
    newest = {}
    for path in glob.glob(os.path.join(folder, "*.apk")):
        try:
            name, version, metas = package(path)
        except (OSError, tarfile.TarError) as exc:
            sys.stderr.write("skip %s: %s\n" % (path, exc))
            continue
        if not name or not version or not metas:
            continue
        have = newest.get(name)
        if have is None or compare(version, have[0]) > 0:
            newest[name] = (version, metas)
    catalog = ET.Element("components", version="1.0", origin="haltia")
    for name in sorted(newest):
        for xml in newest[name][1]:
            try:
                comp = parse_xml(xml)
            except (ET.ParseError, xml_parsers.ExpatError) as exc:
                sys.stderr.write("skip %s: %s\n" % (name, exc))
                continue
            if comp.tag != "component":
                continue
            if comp.find("pkgname") is None:
                pkg = ET.Element("pkgname")
                pkg.text = name
                comp.insert(1, pkg)
            catalog.append(comp)
    ET.indent(catalog)
    data = ('<?xml version="1.0" encoding="utf-8"?>\n'
            + ET.tostring(catalog, encoding="unicode")).encode("utf-8")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    # No time in the gzip header: an unchanged catalog stays the same file.
    with open(out + ".new", "wb") as raw, \
            gzip.GzipFile(fileobj=raw, mode="wb", mtime=0, filename="") as fh:
        fh.write(data + b"\n")
    os.replace(out + ".new", out)
    print("appstream: %d components from %d packages" % (len(catalog), len(newest)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
