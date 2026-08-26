#!/usr/bin/env python3
"""
sneaker / obsidian-plugins : bastion-side fetcher.

Runs on the internet-facing staging host. Resolves pinned plugin repos to their
current release, downloads the release assets (and, by default, the tagged
source archive), records hashes, and emits one verified tarball into a staging
directory. It knows nothing about the receiving side and performs no transfer: the
bundle is carried by a human over an interactively authenticated session.

Constraints, deliberately:
  * Python 3.6 (RHEL 8). No walrus, no dataclasses, no f-string '=', no
    subprocess capture_output.
  * All network I/O shells out to curl, so TLS trust, proxy handling and
    redirect behaviour match the rest of the box.
  * Version resolution follows the /releases/latest redirect rather than
    calling api.github.com, whose unauthenticated limit of 60 requests/hour is
    per source IP and therefore shared with everyone else behind the bastion.
"""

from __future__ import print_function

import argparse
import errno
import gzip
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys
import tarfile
import tempfile
import time

BUNDLE_ROOT = "sneaker-obsidian-plugins"
CATALOG_URL = ("https://raw.githubusercontent.com/obsidianmd/"
               "obsidian-releases/master/community-plugins.json")

# Obsidian restricts plugin ids to lowercase letters, digits and hyphens. We
# enforce it because the id becomes a directory name on the receiving side; an
# unvalidated id is a path-traversal primitive.
ID_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
REPO_RE = re.compile(r"^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$")

ASSETS_REQUIRED = ("manifest.json", "main.js")
ASSETS_OPTIONAL = ("styles.css",)

CURL_EXIT_HINTS = {
    5: "could not resolve proxy",
    6: "DNS resolution failed - no name server, or egress DNS is blocked",
    7: "connection refused or unreachable - egress filtering is the usual cause",
    22: "server returned an HTTP error (404 for a missing asset)",
    28: "timed out",
    35: "TLS handshake failed",
    56: "connection reset mid-transfer",
    60: "certificate not trusted - a corporate root CA may be missing",
    77: "could not read the CA bundle",
}


class Fail(Exception):
    pass


def emit(msg):
    """Human-readable progress. stderr only: stdout carries the result line."""
    sys.stderr.write(msg + "\n")
    sys.stderr.flush()


# --------------------------------------------------------------------- curl

def curl(args, timeout_s=300):
    cmd = ["curl", "--silent", "--show-error", "--fail", "--location",
           "--retry", "3", "--retry-delay", "2",
           "--connect-timeout", "15", "--max-time", str(timeout_s)]
    cmd.extend(args)
    proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    out, errout = proc.communicate()
    return proc.returncode, out, errout


def curl_hint(rc, errout):
    hint = CURL_EXIT_HINTS.get(rc, "curl exit %d" % rc)
    detail = errout.decode("utf-8", "replace").strip()
    if detail:
        return "%s (%s)" % (hint, detail.splitlines()[0])
    return hint


def preflight():
    """Diagnose egress before doing 40 downloads that all fail the same way."""
    emit("preflight: checking egress to github.com")
    rc, out, errout = curl(["--head", "--output", os.devnull,
                            "--write-out", "%{http_code}",
                            "https://github.com/"], timeout_s=30)
    if rc != 0:
        raise Fail("no egress to github.com: %s" % curl_hint(rc, errout))
    emit("preflight: ok (HTTP %s)" % out.decode("ascii", "replace").strip())


# ------------------------------------------------------------ resolution

def resolve_tag(repo):
    """Current release tag, via the /releases/latest redirect. No API call."""
    url = "https://github.com/%s/releases/latest" % repo
    rc, out, errout = curl(["--head", "--output", os.devnull,
                            "--write-out", "%{url_effective}", url],
                           timeout_s=60)
    if rc != 0:
        # A few proxies mangle HEAD; retry as a discarded GET before giving up.
        rc, out, errout = curl(["--output", os.devnull,
                                "--write-out", "%{url_effective}", url],
                               timeout_s=60)
    if rc != 0:
        raise Fail("could not resolve latest release for %s: %s"
                   % (repo, curl_hint(rc, errout)))
    final = out.decode("utf-8", "replace").strip()
    match = re.search(r"/releases/tag/(.+?)/?$", final)
    if not match:
        raise Fail("no release found for %s (landed on %s) - the repo may have "
                   "no published releases" % (repo, final))
    tag = match.group(1)
    try:
        from urllib.parse import unquote
    except ImportError:  # pragma: no cover
        from urllib import unquote  # type: ignore
    return unquote(tag)


def asset_url(repo, tag, filename):
    from urllib.parse import quote
    return "https://github.com/%s/releases/download/%s/%s" % (
        repo, quote(tag, safe=""), quote(filename, safe=""))


def source_url(repo, tag):
    from urllib.parse import quote
    return "https://github.com/%s/archive/refs/tags/%s.tar.gz" % (
        repo, quote(tag, safe=""))


def download(url, dest, optional=False):
    rc, _out, errout = curl(["--output", dest, url])
    if rc != 0:
        try:
            os.unlink(dest)
        except OSError as exc:
            if exc.errno != errno.ENOENT:
                raise
        if optional and rc == 22:
            return False
        raise Fail("download failed: %s: %s" % (url, curl_hint(rc, errout)))
    return True


# ------------------------------------------------------------------ hashing

def sha256_file(path):
    digest = hashlib.sha256()
    handle = open(path, "rb")
    try:
        while True:
            chunk = handle.read(1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    finally:
        handle.close()
    return digest.hexdigest()


# ------------------------------------------------------------------- inputs

def parse_plugins_text(text):
    """One 'owner/repo' or 'owner/repo@tag' per line. '#' comments, blanks ok."""
    specs = []
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        pin = None
        if "@" in line:
            line, pin = line.split("@", 1)
            line = line.strip()
            pin = pin.strip() or None
        if not REPO_RE.match(line):
            raise Fail("plugins line %d is not owner/repo: %r" % (lineno, raw))
        specs.append({"repo": line, "pin": pin})
    if not specs:
        raise Fail("no plugins listed")
    return specs


def read_request(path):
    if path == "-":
        return json.loads(sys.stdin.read())
    handle = open(path, "r")
    try:
        return json.loads(handle.read())
    finally:
        handle.close()


# -------------------------------------------------------------------- bundle

def _normalize(info):
    """Strip every source of nondeterminism from a tar member."""
    info.uid = 0
    info.gid = 0
    info.uname = ""
    info.gname = ""
    info.mtime = 0
    info.mode = 0o644
    return info


def build_bundle(stage_root, out_path):
    """Deterministic tar.gz: sorted members, zeroed mtimes and ownership, and a
    gzip header with no embedded name or timestamp. Two runs over identical
    inputs produce identical bytes."""
    names = []
    for dirpath, dirnames, filenames in os.walk(stage_root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            names.append(os.path.relpath(full, stage_root))
    names.sort()

    raw = open(out_path, "wb")
    try:
        gz = gzip.GzipFile(filename="", mode="wb", compresslevel=9,
                           fileobj=raw, mtime=0)
        try:
            tar = tarfile.open(fileobj=gz, mode="w",
                               format=tarfile.GNU_FORMAT)
            try:
                for rel in names:
                    tar.add(os.path.join(stage_root, rel),
                            arcname="%s/%s" % (BUNDLE_ROOT, rel),
                            filter=_normalize)
            finally:
                tar.close()
        finally:
            gz.close()
    finally:
        raw.close()
    return names


def content_id(files):
    """Hash of the payload, independent of when it was fetched. MANIFEST.json
    carries a timestamp, so the bundle's own hash changes every run; this does
    not. Compare content ids to answer 'did anything actually change'."""
    digest = hashlib.sha256()
    for rel in sorted(files.keys()):
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(files[rel].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


# ---------------------------------------------------------------------- main

def fetch_one(spec, stage_root, want_source, warnings):
    repo = spec["repo"]
    tag = spec["pin"] or resolve_tag(repo)

    tmpdir = tempfile.mkdtemp(prefix="sneaker-plugin-")
    try:
        got = {}
        for name in ASSETS_REQUIRED:
            dest = os.path.join(tmpdir, name)
            download(asset_url(repo, tag, name), dest)
            got[name] = dest
        for name in ASSETS_OPTIONAL:
            dest = os.path.join(tmpdir, name)
            if download(asset_url(repo, tag, name), dest, optional=True):
                got[name] = dest

        handle = open(got["manifest.json"], "r")
        try:
            manifest = json.loads(handle.read())
        finally:
            handle.close()

        plugin_id = manifest.get("id", "")
        if not ID_RE.match(plugin_id or ""):
            raise Fail("%s: manifest id %r is not a safe plugin id"
                       % (repo, plugin_id))

        version = str(manifest.get("version", "")).strip()
        if version and version != tag.lstrip("v"):
            warnings.append("%s: manifest version %s does not match release "
                            "tag %s" % (repo, version, tag))

        plugin_dir = os.path.join(stage_root, "plugins", plugin_id)
        os.makedirs(plugin_dir)
        files = {}
        for name in sorted(got.keys()):
            final = os.path.join(plugin_dir, name)
            shutil.copyfile(got[name], final)
            files[name] = {"sha256": sha256_file(final),
                           "bytes": os.path.getsize(final)}

        record = {
            "repo": repo,
            "tag": tag,
            "pinned": bool(spec["pin"]),
            "id": plugin_id,
            "version": version,
            "minAppVersion": manifest.get("minAppVersion"),
            "isDesktopOnly": manifest.get("isDesktopOnly"),
            "name": manifest.get("name"),
            "files": files,
        }

        if want_source:
            src_dir = os.path.join(stage_root, "source")
            if not os.path.isdir(src_dir):
                os.makedirs(src_dir)
            src_name = "%s-%s.tar.gz" % (plugin_id, tag.replace("/", "_"))
            src_path = os.path.join(src_dir, src_name)
            if download(source_url(repo, tag), src_path, optional=True):
                record["source"] = {
                    "path": "source/%s" % src_name,
                    "sha256": sha256_file(src_path),
                    "bytes": os.path.getsize(src_path),
                }
            else:
                warnings.append("%s: no source archive for tag %s" % (repo, tag))
        return record
    finally:
        shutil.rmtree(tmpdir, ignore_errors=True)


def main(argv):
    parser = argparse.ArgumentParser(
        description="Fetch pinned Obsidian plugins into a verified bundle.")
    parser.add_argument("--out", required=True,
                        help="staging directory for the bundle")
    parser.add_argument("--request", default=None,
                        help="JSON request on a path or '-' for stdin")
    parser.add_argument("--plugins", default=None,
                        help="plugins.txt of pinned owner/repo lines")
    parser.add_argument("--only", default=None,
                        help="comma-separated plugin ids or repos to fetch")
    parser.add_argument("--no-source", dest="source", action="store_false",
                        default=True, help="omit tagged source archives")
    parser.add_argument("--no-catalog", dest="catalog", action="store_false",
                        default=True, help="omit the community plugin index")
    parser.add_argument("--skip-preflight", action="store_true")
    args = parser.parse_args(argv[1:])

    request = {}
    if args.request:
        request = read_request(args.request)
    if request.get("plugins"):
        specs = parse_plugins_text("\n".join(request["plugins"]))
    elif args.plugins:
        handle = open(args.plugins, "r")
        try:
            specs = parse_plugins_text(handle.read())
        finally:
            handle.close()
    else:
        raise Fail("need --plugins or a --request carrying a plugins list")

    installed = request.get("installed") or {}
    want_source = request.get("source", args.source)
    want_catalog = request.get("catalog", args.catalog)
    only = request.get("only")
    if args.only:
        only = [s.strip() for s in args.only.split(",") if s.strip()]

    if not args.skip_preflight:
        preflight()

    out_dir = os.path.expanduser(args.out)
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    stage_root = tempfile.mkdtemp(prefix="sneaker-bundle-", dir=out_dir)

    records = []
    warnings = []
    failures = []
    skipped = []
    try:
        for spec in specs:
            repo = spec["repo"]
            short = repo.split("/")[-1]
            if only and not any(sel in (repo, short) for sel in only):
                continue
            emit("resolve  %s" % repo)
            try:
                record = fetch_one(spec, stage_root, want_source, warnings)
            except Fail as exc:
                failures.append(str(exc))
                emit("  FAILED %s" % exc)
                continue

            have = installed.get(record["id"])
            if only is None and have and have == record["version"]:
                # Already current everywhere. Drop it from the bundle rather
                # than carrying bytes across the boundary for no reason.
                shutil.rmtree(os.path.join(stage_root, "plugins", record["id"]),
                              ignore_errors=True)
                if record.get("source"):
                    try:
                        os.unlink(os.path.join(stage_root,
                                               record["source"]["path"]))
                    except OSError:
                        pass
                skipped.append("%s %s" % (record["id"], have))
                emit("  current %s %s" % (record["id"], have))
                continue

            records.append(record)
            emit("  fetched %s %s (%s)" % (record["id"], record["tag"],
                                           ", ".join(sorted(record["files"]))))

        if want_catalog:
            cat_dir = os.path.join(stage_root, "catalog")
            os.makedirs(cat_dir)
            cat_path = os.path.join(cat_dir, "community-plugins.json")
            emit("catalog  community-plugins.json")
            try:
                download(CATALOG_URL, cat_path)
            except Fail as exc:
                warnings.append("catalog: %s" % exc)
                shutil.rmtree(cat_dir, ignore_errors=True)

        if not records and not os.path.isdir(os.path.join(stage_root, "catalog")):
            emit("nothing to bundle: every requested plugin is already current")
            shutil.rmtree(stage_root, ignore_errors=True)
            sys.stdout.write("SNEAKER_EMPTY\n")
            return 0

        # Hash every payload file, then write MANIFEST.json, then SHA256SUMS
        # covering both. The bundle's own hash covers SHA256SUMS in turn.
        payload = {}
        for dirpath, dirnames, filenames in os.walk(stage_root):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                payload[os.path.relpath(full, stage_root)] = sha256_file(full)

        manifest_doc = {
            "schema": 1,
            "tool": "sneaker/obsidian-plugins",
            "tool_version": "0.1.0",
            "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "source_host": os.uname()[1],
            "content_id": content_id(payload),
            "plugins": records,
            "skipped_current": skipped,
            "warnings": warnings,
            "failures": failures,
        }
        man_path = os.path.join(stage_root, "MANIFEST.json")
        handle = open(man_path, "w")
        try:
            handle.write(json.dumps(manifest_doc, indent=2, sort_keys=True))
            handle.write("\n")
        finally:
            handle.close()
        payload["MANIFEST.json"] = sha256_file(man_path)

        sums_path = os.path.join(stage_root, "SHA256SUMS")
        handle = open(sums_path, "w")
        try:
            for rel in sorted(payload.keys()):
                handle.write("%s  %s\n" % (payload[rel], rel))
        finally:
            handle.close()

        stamp = time.strftime("%Y%m%dT%H%M%SZ", time.gmtime())
        bundle_path = os.path.join(out_dir, "obsidian-plugins-%s.tar.gz" % stamp)
        build_bundle(stage_root, bundle_path)
    finally:
        shutil.rmtree(stage_root, ignore_errors=True)

    digest = sha256_file(bundle_path)
    size = os.path.getsize(bundle_path)

    emit("")
    emit("bundle     %s" % bundle_path)
    emit("sha256     %s" % digest)
    emit("size       %d bytes (%.1f MiB)" % (size, size / 1048576.0))
    emit("content-id %s" % manifest_doc["content_id"])
    emit("plugins    %d fetched, %d already current"
         % (len(records), len(skipped)))
    for line in warnings:
        emit("warning    %s" % line)
    for line in failures:
        emit("FAILED     %s" % line)

    # The one line stdout carries, for the driver to parse.
    sys.stdout.write("SNEAKER_BUNDLE %s %s %d\n" % (bundle_path, digest, size))
    return 2 if failures else 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Fail as exc:
        sys.stderr.write("fatal: %s\n" % exc)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.stderr.write("interrupted\n")
        sys.exit(130)
