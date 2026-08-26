#!/usr/bin/env python3
"""Build synthetic bundles - well-formed and hostile - to exercise the unpacker.

Imports the real bundling code from the bastion fetcher so the tests cover the
code that actually ships, not a reimplementation of it.
"""
import hashlib
import importlib.util
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "fetcher", os.path.join(ROOT, "bastion", "fetch-obsidian-plugins.py"))
fetcher = importlib.util.module_from_spec(spec)
spec.loader.exec_module(fetcher)

BR = fetcher.BUNDLE_ROOT


def sha(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            h.update(chunk)
    return h.hexdigest()


def make_stage(tmp, plugins):
    """plugins: list of (id, version, minAppVersion, body)"""
    root = os.path.join(tmp, "stage")
    os.makedirs(os.path.join(root, "plugins"))
    records = []
    for pid, version, minapp, body in plugins:
        pdir = os.path.join(root, "plugins", pid)
        os.makedirs(pdir)
        manifest = {"id": pid, "name": pid.title(), "version": version,
                    "minAppVersion": minapp, "author": "test",
                    "description": "fixture", "isDesktopOnly": False}
        with open(os.path.join(pdir, "manifest.json"), "w") as fh:
            fh.write(json.dumps(manifest, indent=2) + "\n")
        with open(os.path.join(pdir, "main.js"), "w") as fh:
            fh.write(body)
        with open(os.path.join(pdir, "styles.css"), "w") as fh:
            fh.write("/* %s */\n" % pid)
        files = {}
        for name in ("main.js", "manifest.json", "styles.css"):
            full = os.path.join(pdir, name)
            files[name] = {"sha256": sha(full), "bytes": os.path.getsize(full)}
        records.append({"repo": "example/%s" % pid, "tag": version, "id": pid,
                        "version": version, "minAppVersion": minapp,
                        "isDesktopOnly": False, "name": pid.title(),
                        "pinned": False, "files": files})
    return root, records


def finalize(root, records, created="2026-01-01T00:00:00Z"):
    payload = {}
    for dirpath, dirnames, filenames in os.walk(root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            payload[os.path.relpath(full, root)] = sha(full)
    doc = {"schema": 1, "tool": "sneaker/obsidian-plugins", "tool_version": "0.1.0",
           "created_utc": created, "source_host": "fixture",
           "content_id": fetcher.content_id(payload), "plugins": records,
           "skipped_current": [], "warnings": [], "failures": []}
    man = os.path.join(root, "MANIFEST.json")
    with open(man, "w") as fh:
        fh.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    payload["MANIFEST.json"] = sha(man)
    with open(os.path.join(root, "SHA256SUMS"), "w") as fh:
        for rel in sorted(payload):
            fh.write("%s  %s\n" % (payload[rel], rel))


def build_good(out, plugins, created="2026-01-01T00:00:00Z"):
    tmp = tempfile.mkdtemp()
    try:
        root, records = make_stage(tmp, plugins)
        finalize(root, records, created)
        fetcher.build_bundle(root, out)
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def build_hostile(out, kind):
    """Bundles designed to be refused."""
    tmp = tempfile.mkdtemp()
    try:
        root, records = make_stage(tmp, [("dataview", "1.0.0", "1.4.0", "ok\n")])
        finalize(root, records)
        if kind == "corrupt":
            with open(os.path.join(root, "plugins", "dataview", "main.js"), "w") as fh:
                fh.write("tampered\n")
            fetcher.build_bundle(root, out)
            return
        tf = tarfile.open(out, "w:gz")
        try:
            for dirpath, dirnames, filenames in os.walk(root):
                for name in sorted(filenames):
                    full = os.path.join(dirpath, name)
                    tf.add(full, arcname="%s/%s" % (BR, os.path.relpath(full, root)))
            if kind == "traversal":
                extra = os.path.join(tmp, "evil")
                open(extra, "w").write("pwned\n")
                tf.add(extra, arcname="%s/plugins/../../evil" % BR)
            elif kind == "absolute":
                extra = os.path.join(tmp, "evil")
                open(extra, "w").write("pwned\n")
                ti = tf.gettarinfo(extra, arcname="/etc/evil")
                tf.addfile(ti, open(extra, "rb"))
            elif kind == "symlink":
                ti = tarfile.TarInfo("%s/plugins/dataview/link" % BR)
                ti.type = tarfile.SYMTYPE
                ti.linkname = "/etc/passwd"
                tf.addfile(ti)
            elif kind == "stray":
                extra = os.path.join(tmp, "evil.sh")
                open(extra, "w").write("#!/bin/sh\n")
                tf.add(extra, arcname="%s/plugins/dataview/evil.sh" % BR)
            elif kind == "outside":
                extra = os.path.join(tmp, "evil")
                open(extra, "w").write("pwned\n")
                tf.add(extra, arcname="somewhere-else/evil")
        finally:
            tf.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


if __name__ == "__main__":
    mode = sys.argv[1]
    out = sys.argv[2]
    if mode == "good":
        specs = []
        for arg in sys.argv[3:]:
            pid, version, minapp = arg.split(":")
            specs.append((pid, version, minapp, "// %s %s\n" % (pid, version)))
        build_good(out, specs)
    else:
        build_hostile(out, mode)
