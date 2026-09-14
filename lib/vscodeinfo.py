#!/usr/bin/env python3
"""Read a staged vscode-extensions MANIFEST.json for the shell.

Emits TSV so the caller stays in awk/read territory. Runs on the laptop only:
the receiving hosts are asked for nothing but sh, tar and sha256sum, so a
target with no Python is still a valid target.
"""
from __future__ import print_function

import json
import sys


def load(path):
    handle = open(path, "r")
    try:
        return json.loads(handle.read())
    finally:
        handle.close()


def cmd_summary(doc, _args):
    out = [("created", doc.get("created_utc", "")),
           ("content_id", doc.get("content_id", "")),
           ("vscode_version", doc.get("vscode", {}).get("version", "")),
           ("vscode_commit", doc.get("vscode", {}).get("commit", "")),
           ("client_platform", doc.get("vscode", {}).get("client_platform", "")),
           ("platforms", ",".join(doc.get("platforms", []))),
           ("catalog_entries", str(doc.get("catalog_entries", 0)))]
    for line in doc.get("warnings", []):
        out.append(("warning", line))
    for key, value in out:
        print("%s\t%s" % (key, value))


def cmd_extensions(doc, args):
    """extensions <side> [platform] -> id, version, platform, path, sha256"""
    side = args[0] if args else "remote"
    platform = args[1] if len(args) > 1 else None
    for ext in doc.get("extensions", []):
        if ext.get("side") != side:
            continue
        if platform and ext.get("platform") != platform:
            continue
        print("\t".join([ext.get("id", ""), ext.get("version", ""),
                         ext.get("platform", ""), ext.get("path", ""),
                         ext.get("sha256", ""), ext.get("engine", ""),
                         ext.get("extension_id", ""),
                         ext.get("publisher_id", "")]))


def cmd_servers(doc, args):
    """servers <platform> [commit] -> kind, commit, path, sha256, version"""
    platform = args[0] if args else None
    commit = args[1] if len(args) > 1 else None
    for item in doc.get("servers", []):
        if platform and item.get("platform") != platform:
            continue
        if commit and item.get("commit") != commit:
            continue
        print("\t".join([item.get("kind", ""), item.get("commit", ""),
                         item.get("path", ""), item.get("sha256", ""),
                         item.get("product_version", ""), item.get("role", "")]))


def cmd_commits(doc, args):
    """commits [platform] -> commit, version, role  (one row per commit)"""
    platform = args[0] if args else None
    seen = []
    for item in doc.get("servers", []):
        if platform and item.get("platform") != platform:
            continue
        key = item.get("commit")
        if key in [s[0] for s in seen]:
            continue
        seen.append((key, item.get("product_version", ""), item.get("role", "")))
    for row in seen:
        print("\t".join(row))


COMMANDS = {"summary": cmd_summary, "extensions": cmd_extensions,
            "servers": cmd_servers, "commits": cmd_commits}


def main(argv):
    if len(argv) < 3 or argv[1] not in COMMANDS:
        sys.stderr.write("usage: vscodeinfo.py <%s> MANIFEST.json [args]\n"
                         % "|".join(sorted(COMMANDS)))
        return 2
    COMMANDS[argv[1]](load(argv[2]), argv[3:])
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
