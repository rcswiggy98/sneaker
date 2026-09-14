#!/usr/bin/env python3
"""Synthesise vscode-extensions bundles, good and hostile, for the smoke test.

Uses the bastion fetcher's own bundling code for the good case so the test
exercises the format that is actually produced, not a reimplementation of it.
"""
from __future__ import print_function

import gzip
import importlib.util
import json
import os
import shutil
import sys
import tarfile
import tempfile
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
_spec = importlib.util.spec_from_file_location(
    "fetch_vscode", os.path.join(ROOT, "bastion", "fetch-vscode-extensions.py"))
F = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(F)

ROOT_NAME = F.BUNDLE_ROOT
COMMIT = "a" * 40


def _sha(path):
    return F.sha256_file(path)


def _payload(stage):
    """A minimal but structurally real bundle: one local extension, one remote
    extension, and a server plus CLI for one commit."""
    os.makedirs(os.path.join(stage, "vsix", "win32-x64"))
    os.makedirs(os.path.join(stage, "vsix", "linux-x64"))
    os.makedirs(os.path.join(stage, "server", COMMIT))
    os.makedirs(os.path.join(stage, "catalog"))

    files = {
        "vsix/win32-x64/pub.local-1.0.0-win32-x64.vsix": b"PK\x03\x04local",
        "vsix/linux-x64/pub.remote-2.0.0-linux-x64.vsix": b"PK\x03\x04remote",
        "server/%s/vscode-server-linux-x64.tar.gz" % COMMIT: b"server-bytes",
        "server/%s/vscode_cli_linux_x64_cli.tar.gz" % COMMIT: b"cli-bytes",
    }
    for rel, blob in files.items():
        handle = open(os.path.join(stage, rel), "wb")
        try:
            handle.write(blob)
        finally:
            handle.close()

    # A real gzip so the offline search path is exercised, not just present.
    raw = open(os.path.join(stage, "catalog", "marketplace.tsv.gz"), "wb")
    try:
        gz = gzip.GzipFile(filename="", mode="wb", fileobj=raw, mtime=0)
        try:
            gz.write(b"# id\tinstalls\tverified\tdomain\tpublisher\tname\tdesc\n")
            gz.write(b"pub.yaml\t900\tverified\thttps://e.example\tE\tYAML\tyaml things\n")
            gz.write(b"pub.other\t10\t-\t-\tO\tOther\tsomething else\n")
        finally:
            gz.close()
    finally:
        raw.close()

    def ext(ident, version, platform, side, rel):
        return {"id": ident, "version": version, "platform": platform,
                "side": side, "path": rel, "engine": "^1.100.0",
                "kind": ["ui"] if side == "local" else ["workspace"],
                "sha256": _sha(os.path.join(stage, rel)),
                "bytes": os.path.getsize(os.path.join(stage, rel)),
                "extension_id": "EXT-" + ident, "publisher_id": "PUB-" + ident,
                "target_platform": platform, "prerelease": False,
                "pinned": False, "publisher_verified": True}

    def srv(kind, rel):
        return {"kind": kind, "commit": COMMIT, "platform": "linux-x64",
                "path": rel, "product_version": "1.133.0", "role": "installed",
                "sha256": _sha(os.path.join(stage, rel)),
                "published_sha256": None,
                "bytes": os.path.getsize(os.path.join(stage, rel))}

    doc = {
        "schema": 1, "tool": "sneaker/vscode-extensions", "tool_version": "0.1.0",
        "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(0)),
        "source_host": "fixture", "catalog_entries": 1, "warnings": [],
        "vscode": {"version": "1.133.0", "commit": COMMIT,
                   "client_platform": "win32-x64"},
        "platforms": ["win32-x64", "linux-x64"],
        "extensions": [
            ext("pub.local", "1.0.0", "win32-x64", "local",
                "vsix/win32-x64/pub.local-1.0.0-win32-x64.vsix"),
            ext("pub.remote", "2.0.0", "linux-x64", "remote",
                "vsix/linux-x64/pub.remote-2.0.0-linux-x64.vsix")],
        "servers": [
            srv("server", "server/%s/vscode-server-linux-x64.tar.gz" % COMMIT),
            srv("cli", "server/%s/vscode_cli_linux_x64_cli.tar.gz" % COMMIT)],
    }
    doc["content_id"] = "fixture"

    handle = open(os.path.join(stage, "MANIFEST.json"), "w")
    try:
        handle.write(json.dumps(doc, indent=2, sort_keys=True) + "\n")
    finally:
        handle.close()

    sums = {}
    for dirpath, dirnames, filenames in os.walk(stage):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            sums[os.path.relpath(full, stage)] = _sha(full)
    handle = open(os.path.join(stage, "SHA256SUMS"), "w")
    try:
        for rel in sorted(sums):
            handle.write("%s  %s\n" % (sums[rel], rel))
    finally:
        handle.close()
    return doc


def _tamper(stage, kind):
    if kind == "corrupt":
        path = os.path.join(stage, "vsix", "win32-x64",
                            "pub.local-1.0.0-win32-x64.vsix")
        handle = open(path, "wb")
        try:
            handle.write(b"different bytes entirely")
        finally:
            handle.close()


def _raw_tar(out_path, members):
    """Write a tar directly so members the bundler would never emit can be
    tested: traversal, absolute paths, symlinks and stray members."""
    tmp = tempfile.mkdtemp()
    try:
        tar = tarfile.open(out_path, "w:gz")
        try:
            for name, kind, data in members:
                if kind == "sym":
                    info = tarfile.TarInfo(name)
                    info.type = tarfile.SYMTYPE
                    info.linkname = data
                    tar.addfile(info)
                else:
                    blob = data.encode() if not isinstance(data, bytes) else data
                    info = tarfile.TarInfo(name)
                    info.size = len(blob)
                    info.mtime = 0
                    import io
                    tar.addfile(info, io.BytesIO(blob))
        finally:
            tar.close()
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


HOSTILE = {
    "traversal": [("%s/vsix/../../escape.vsix" % ROOT_NAME, "f", "x")],
    "absolute":  [("/etc/passwd", "f", "x")],
    "symlink":   [("%s/vsix/win32-x64/a.vsix" % ROOT_NAME, "sym", "/etc/passwd")],
    "stray":     [("%s/vsix/win32-x64/payload.sh" % ROOT_NAME, "f", "#!/bin/sh\n")],
    "outside":   [("elsewhere/thing.vsix", "f", "x")],
}


def main(argv):
    if len(argv) < 3:
        sys.stderr.write("usage: make_vscode_fixture.py <kind> <out.tar.gz>\n")
        return 2
    kind, out_path = argv[1], argv[2]

    if kind in HOSTILE:
        members = [("%s/MANIFEST.json" % ROOT_NAME, "f", "{}"),
                   ("%s/SHA256SUMS" % ROOT_NAME, "f", "")]
        members.extend(HOSTILE[kind])
        _raw_tar(out_path, members)
        return 0

    stage = tempfile.mkdtemp(prefix="vsfix-")
    try:
        _payload(stage)
        _tamper(stage, kind)
        F.build_bundle(stage, out_path)
    finally:
        shutil.rmtree(stage, ignore_errors=True)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
