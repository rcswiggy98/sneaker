#!/usr/bin/env python3
"""
sneaker / obsidian-plugins : vault-side JSON helper.

Runs wherever a vault lives (the laptop, or a remote host over ssh). Kept to
the same Python 3.6 floor as the bastion fetcher so one copy works everywhere.
Bash drives; this exists so JSON is parsed by something that understands JSON.
"""

from __future__ import print_function

import argparse
import json
import os
import sys

PLUGINS_SUBDIR = os.path.join(".obsidian", "plugins")
ENABLED_FILE = os.path.join(".obsidian", "community-plugins.json")


def die(msg):
    sys.stderr.write("fatal: %s\n" % msg)
    sys.exit(1)


def read_json(path):
    handle = open(path, "r")
    try:
        return json.loads(handle.read())
    finally:
        handle.close()


def write_text_lf(path, text):
    """Write atomically within the same directory, LF endings, no translation."""
    tmp = "%s.sneaker.%d" % (path, os.getpid())
    handle = open(tmp, "w", newline="\n")
    try:
        handle.write(text)
    finally:
        handle.close()
    os.replace(tmp, path)


def cmd_installed(args):
    """TSV of what a vault currently has: id, version, minAppVersion."""
    plugins_dir = os.path.join(args.vault, PLUGINS_SUBDIR)
    if not os.path.isdir(plugins_dir):
        return 0
    for name in sorted(os.listdir(plugins_dir)):
        manifest = os.path.join(plugins_dir, name, "manifest.json")
        if not os.path.isfile(manifest):
            continue
        try:
            doc = read_json(manifest)
        except ValueError:
            sys.stderr.write("warn: unreadable manifest in %s\n" % name)
            continue
        sys.stdout.write("%s\t%s\t%s\n" % (
            doc.get("id", name),
            doc.get("version", "?"),
            doc.get("minAppVersion", "")))
    return 0


def load_installed_tsv(path):
    state = {}
    if not path or path == "-" or not os.path.exists(path):
        return state
    handle = open(path, "r")
    try:
        for line in handle:
            parts = line.rstrip("\n").split("\t")
            if len(parts) >= 2 and parts[0]:
                state[parts[0]] = parts[1]
    finally:
        handle.close()
    return state


def cmd_request(args):
    """Build the JSON request the bastion fetcher reads on stdin."""
    handle = open(args.plugins, "r")
    try:
        lines = [ln.rstrip("\n") for ln in handle]
    finally:
        handle.close()
    doc = {
        "plugins": lines,
        "installed": load_installed_tsv(args.installed),
        "source": not args.no_source,
        "catalog": not args.no_catalog,
    }
    if args.only:
        doc["only"] = [s for s in args.only.split(",") if s]
    sys.stdout.write(json.dumps(doc))
    sys.stdout.write("\n")
    return 0


def version_key(text):
    parts = []
    for chunk in str(text).lstrip("v").replace("-", ".").split("."):
        if chunk.isdigit():
            parts.append((1, int(chunk), ""))
        else:
            parts.append((0, 0, chunk))
    return parts


def cmd_plan(args):
    """TSV plan: action, id, from, to, minAppVersion, name."""
    doc = read_json(args.manifest)
    have = load_installed_tsv(args.installed)
    only = set(s for s in (args.only or "").split(",") if s)
    for record in doc.get("plugins", []):
        pid = record.get("id")
        if only and pid not in only:
            continue
        new = record.get("version") or record.get("tag", "")
        old = have.get(pid)
        if old is None:
            action = "new"
        elif old == new:
            action = "same"
        elif version_key(old) < version_key(new):
            action = "update"
        else:
            action = "downgrade"
        sys.stdout.write("%s\t%s\t%s\t%s\t%s\t%s\n" % (
            action, pid, old or "-", new,
            record.get("minAppVersion") or "",
            record.get("name") or pid))
    return 0


def cmd_enable(args):
    """Add plugin ids to the vault's enabled list, preserving what is there.

    Obsidian owns this file and rewrites it on its own schedule, so editing it
    underneath a running Obsidian can be silently reverted. The caller checks
    for a running instance before calling this.
    """
    path = os.path.join(args.vault, ENABLED_FILE)
    if not os.path.exists(path):
        die("no %s - open the vault in Obsidian and turn on community plugins "
            "once before using --enable" % ENABLED_FILE)
    try:
        current = read_json(path)
    except ValueError:
        die("%s is not valid JSON; refusing to rewrite it" % path)
    if not isinstance(current, list):
        die("%s is not a JSON array; refusing to rewrite it" % path)

    added = []
    for pid in args.ids:
        if pid not in current:
            current.append(pid)
            added.append(pid)
    if added:
        write_text_lf(path, json.dumps(current, indent=2) + "\n")
    for pid in added:
        sys.stdout.write("%s\n" % pid)
    return 0


def cmd_summary(args):
    """One-line-per-field summary of a bundle manifest, for the report."""
    doc = read_json(args.manifest)
    sys.stdout.write("created\t%s\n" % doc.get("created_utc", "?"))
    sys.stdout.write("content_id\t%s\n" % doc.get("content_id", "?"))
    sys.stdout.write("count\t%d\n" % len(doc.get("plugins", [])))
    for line in doc.get("warnings", []):
        sys.stdout.write("warning\t%s\n" % line)
    for line in doc.get("failures", []):
        sys.stdout.write("failure\t%s\n" % line)
    for line in doc.get("skipped_current", []):
        sys.stdout.write("skipped\t%s\n" % line)
    return 0


def cmd_files(args):
    """TSV of every payload file: plugin id, filename, sha256."""
    doc = read_json(args.manifest)
    only = set(s for s in (args.only or "").split(",") if s)
    for record in doc.get("plugins", []):
        pid = record.get("id")
        if only and pid not in only:
            continue
        files = record.get("files", {})
        for name in sorted(files.keys()):
            sys.stdout.write("%s\t%s\t%s\n" % (pid, name, files[name]["sha256"]))
    return 0


def cmd_record(args):
    """One plugin's provenance, for the lockfile: repo, tag, version, main.js hash."""
    doc = read_json(args.manifest)
    for record in doc.get("plugins", []):
        if record.get("id") != args.id:
            continue
        main_hash = record.get("files", {}).get("main.js", {}).get("sha256", "")
        sys.stdout.write("%s\t%s\t%s\t%s\n" % (
            record.get("repo", ""), record.get("tag", ""),
            record.get("version", ""), main_hash))
        return 0
    return 1


def main(argv):
    parser = argparse.ArgumentParser(description="sneaker vault helper")
    sub = parser.add_subparsers(dest="cmd")

    p = sub.add_parser("installed"); p.add_argument("vault"); p.set_defaults(fn=cmd_installed)

    p = sub.add_parser("request")
    p.add_argument("plugins"); p.add_argument("installed")
    p.add_argument("--only", default=None)
    p.add_argument("--no-source", action="store_true")
    p.add_argument("--no-catalog", action="store_true")
    p.set_defaults(fn=cmd_request)

    p = sub.add_parser("plan")
    p.add_argument("manifest"); p.add_argument("installed")
    p.add_argument("--only", default=None)
    p.set_defaults(fn=cmd_plan)

    p = sub.add_parser("enable")
    p.add_argument("vault"); p.add_argument("ids", nargs="+")
    p.set_defaults(fn=cmd_enable)

    p = sub.add_parser("record")
    p.add_argument("manifest"); p.add_argument("id")
    p.set_defaults(fn=cmd_record)

    p = sub.add_parser("summary"); p.add_argument("manifest"); p.set_defaults(fn=cmd_summary)

    p = sub.add_parser("files")
    p.add_argument("manifest"); p.add_argument("--only", default=None)
    p.set_defaults(fn=cmd_files)

    args = parser.parse_args(argv[1:])
    if not getattr(args, "fn", None):
        parser.print_help()
        return 1
    return args.fn(args)


if __name__ == "__main__":
    sys.exit(main(sys.argv))
