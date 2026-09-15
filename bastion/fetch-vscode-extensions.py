#!/usr/bin/env python3
"""
sneaker / vscode-extensions : bastion-side fetcher.

Runs on the internet-facing staging host. Resolves pinned Marketplace
identities to the newest version compatible with the VS Code that is actually
installed, downloads the VSIXs for each requested target platform, downloads
the VS Code Server and CLI tarballs for the commits that will be needed, and
emits one verified tarball into a staging directory. It knows nothing about the
receiving side and performs no transfer: the bundle is carried by a human over
an interactively authenticated session.

Constraints, deliberately:
  * Python 3.6 (RHEL 8). No walrus, no dataclasses, no f-string '=', no
    subprocess capture_output.
  * All network I/O shells out to curl, so TLS trust, proxy handling and
    redirect behaviour match the rest of the box.
  * Resolution is done from gallery metadata before anything is downloaded.
    Four rules are enforced because violating any of them is silent - see
    resolve_version() and docs/vscode-extensions.md.

The bastion cannot be scheduled and authentication is interactive, so a run
that dies partway must not start over. --workdir is a durable cache keyed by
immutable artifact names; anything already present and hashing clean is reused,
and partial downloads resume in place.
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

BUNDLE_ROOT = "sneaker-vscode-extensions"
GALLERY = ("https://marketplace.visualstudio.com/_apis/public/gallery"
           "/extensionquery")
GALLERY_ACCEPT = "application/json;api-version=3.0-preview.1"
UPDATE = "https://update.code.visualstudio.com"

# Gallery query flags. Resolution needs version history, the file list and the
# per-version property bag; the catalogue needs statistics and only the latest
# version of each extension.
FLAGS_RESOLVE = 0x1 | 0x2 | 0x10 | 0x80
FLAGS_CATALOG = 0x100 | 0x200

# Gallery filter types.
FT_EXTENSION_NAME = 7
FT_INSTALLATION_TARGET = 8
FT_SEARCH_TEXT = 10
FT_EXCLUDE_WITH_FLAGS = 12
SORT_INSTALL_COUNT = 4
UNPUBLISHED = "4096"
VSCODE_TARGET = "Microsoft.VisualStudio.Code"

VSIX_ASSET = "Microsoft.VisualStudio.Services.VSIXPackage"
P_ENGINE = "Microsoft.VisualStudio.Code.Engine"
P_KIND = "Microsoft.VisualStudio.Code.ExtensionKind"
P_PACK = "Microsoft.VisualStudio.Code.ExtensionPack"
P_DEPS = "Microsoft.VisualStudio.Code.ExtensionDependencies"
P_PRERELEASE = "Microsoft.VisualStudio.Code.PreRelease"

# VS Code's own bundled extensions are published under the reserved publisher
# "vscode" - vscode.git, vscode.powershell, vscode.json. They ship inside the
# product, they are not on the Marketplace (a query for any of them returns
# nothing), and an extension that depends on one does not need it staged:
# ms-vscode.powershell declares vscode.powershell and installs without it.
# Demanding one be added to extensions.txt is a dead end, since adding it only
# produces "not found on the Marketplace" on the next run.
BUILTIN_PUBLISHER = "vscode"

# The id becomes a path component in the bundle and on the receiving side, so
# it is validated rather than trusted. Publisher names are alphanumeric with
# hyphens; extension names additionally allow dots and underscores.
ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9-]*\.[A-Za-z0-9][A-Za-z0-9._-]*$")
COMMIT_RE = re.compile(r"^[0-9a-f]{40}$")
VERSION_RE = re.compile(r"^[0-9]+\.[0-9]+\.[0-9]+")

# Platforms the Marketplace and update service actually publish. An unknown
# value here is a typo in config, and a typo that reaches resolution produces
# "no compatible version" rather than "you spelled it wrong".
KNOWN_PLATFORMS = (
    "win32-x64", "win32-arm64",
    "linux-x64", "linux-arm64", "linux-armhf",
    "alpine-x64", "alpine-arm64",
    "darwin-x64", "darwin-arm64",
)

CURL_EXIT_HINTS = {
    5: "could not resolve proxy",
    6: "DNS resolution failed - no name server, or egress DNS is blocked",
    7: "connection refused or unreachable - egress filtering is the usual cause",
    22: "server returned an HTTP error",
    28: "timed out",
    33: "server does not support resumed transfers",
    35: "TLS handshake failed",
    36: "could not resume - the partial file is unusable",
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

# Connection-level failures curl exits on without retrying. --retry covers
# transient *HTTP* responses and timeouts; covering resets and handshake
# failures too needs --retry-all-errors, which arrived in curl 7.71. RHEL 8
# ships 7.61, so the retry loop lives here instead of in the flags.
TRANSIENT_RC = frozenset([6, 7, 16, 18, 28, 35, 52, 55, 56, 92])


def curl(args, timeout_s=300, attempts=3):
    cmd = ["curl", "--silent", "--show-error", "--fail", "--location",
           "--retry", "3", "--retry-delay", "2",
           "--connect-timeout", "15", "--max-time", str(timeout_s)]
    cmd.extend(args)
    delay = 2
    for attempt in range(1, attempts + 1):
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE,
                                stderr=subprocess.PIPE)
        out, errout = proc.communicate()
        rc = proc.returncode
        if rc == 0 or rc not in TRANSIENT_RC or attempt == attempts:
            return rc, out, errout
        emit("  transient: %s - retrying in %ds (%d/%d)"
             % (curl_hint(rc, errout), delay, attempt, attempts - 1))
        time.sleep(delay)
        delay *= 2
    return rc, out, errout


def curl_hint(rc, errout):
    hint = CURL_EXIT_HINTS.get(rc, "curl exit %d" % rc)
    detail = errout.decode("utf-8", "replace").strip()
    if detail:
        return "%s (%s)" % (hint, detail.splitlines()[0])
    return hint


def unlink_quietly(path):
    try:
        os.unlink(path)
    except OSError as exc:
        if exc.errno != errno.ENOENT:
            raise


def curl_json(url, timeout_s=60):
    rc, out, errout = curl(["--compressed", url], timeout_s=timeout_s)
    if rc != 0:
        raise Fail("GET %s: %s" % (url, curl_hint(rc, errout)))
    try:
        return json.loads(out.decode("utf-8", "replace"))
    except ValueError as exc:
        raise Fail("GET %s returned unparseable JSON: %s" % (url, exc))


def curl_post_json(url, body, accept, timeout_s=120):
    """POST a JSON body from a temp file rather than argv: gallery queries are
    large enough to matter and this keeps them out of the process table."""
    handle, body_path = tempfile.mkstemp(prefix="sneaker-query-")
    try:
        os.write(handle, json.dumps(body).encode("utf-8"))
        os.close(handle)
        rc, out, errout = curl([
            "--compressed",
            "--request", "POST",
            "--header", "Content-Type: application/json",
            "--header", "Accept: " + accept,
            "--header", "User-Agent: VSCode sneaker",
            "--data-binary", "@" + body_path,
            url], timeout_s=timeout_s)
    finally:
        unlink_quietly(body_path)
    if rc != 0:
        raise Fail("POST %s: %s" % (url, curl_hint(rc, errout)))
    try:
        return json.loads(out.decode("utf-8", "replace"))
    except ValueError as exc:
        raise Fail("POST %s returned unparseable JSON: %s" % (url, exc))


def download(url, dest, timeout_s=1800, resume=True, compressed=False):
    """Resumable download through a .part file.

    A complete artifact is only ever visible under its final name, so a
    truncated transfer from an earlier run cannot be mistaken for a cache hit.
    update.code.visualstudio.com answers range requests, so a server tarball
    that dies at 80MB resumes rather than restarting - which matters when every
    session costs a typed password.

    `compressed` and `resume` are mutually exclusive and deliberately so. The
    vspackage endpoint serves Content-Encoding: gzip, and a fetcher that
    ignores it writes a double-gzipped file that stays valid-looking until VS
    Code rejects it; --compressed makes curl decode the stream. A decoded
    stream cannot be resumed by byte offset, so only the large, uncompressed
    tarballs take the resume path.
    """
    part = dest + ".part"
    base = ["--compressed"] if compressed else []
    attempts = []
    if resume and not compressed and os.path.exists(part):
        attempts.append(base + ["--continue-at", "-", "--output", part, url])
    else:
        unlink_quietly(part)
    attempts.append(base + ["--output", part, url])

    last = None
    for i, args in enumerate(attempts):
        rc, _out, errout = curl(args, timeout_s=timeout_s)
        if rc == 0:
            os.rename(part, dest)
            return
        last = curl_hint(rc, errout)
        if i < len(attempts) - 1:
            emit("  resume failed (%s), restarting transfer" % last)
            unlink_quietly(part)
    unlink_quietly(part)
    raise Fail(last)


def download_any(urls, dest, timeout_s=1800, resume=True, compressed=False):
    """Try each candidate URL in turn.

    Marketplace assets are published under several hostnames that serve the
    same bytes, and an allowlisted DMZ commonly permits some and not others.
    Failing only when every one of them is unreachable turns a firewall gap
    into a slower fetch rather than a dead tool.
    """
    errors = []
    for url in urls:
        try:
            download(url, dest, timeout_s=timeout_s, resume=resume,
                     compressed=compressed)
            return url
        except Fail as exc:
            errors.append("%s: %s" % (host_of(url), exc))
    raise Fail("no reachable source:\n    %s" % "\n    ".join(errors))


def host_of(url):
    match = re.match(r"^https?://([^/]+)", url)
    return match.group(1) if match else url


def preflight():
    """Diagnose egress before doing dozens of downloads that fail identically.

    Three different hostnames are involved and an allowlisted DMZ can permit
    any subset of them: the update service serves the server tarballs, the
    gallery API answers resolution queries, and the VSIXs themselves come from
    a separate asset CDN. Checking the CDN needs a real asset URL, so the probe
    resolves one rather than guessing at a path.
    """
    emit("preflight: update.code.visualstudio.com")
    curl_json(UPDATE + "/api/update/win32-x64/stable/latest", timeout_s=30)

    emit("preflight: marketplace.visualstudio.com (gallery api)")
    probe = "ms-vscode-remote.remote-ssh"
    body = {"filters": [{"criteria": [
        {"filterType": FT_EXTENSION_NAME, "value": probe},
        {"filterType": FT_INSTALLATION_TARGET, "value": VSCODE_TARGET}],
        "pageSize": 1, "pageNumber": 1}], "flags": FLAGS_RESOLVE}
    doc = curl_post_json(GALLERY, body, GALLERY_ACCEPT, timeout_s=60)
    results = doc.get("results") or [{}]
    exts = results[0].get("extensions") or []
    if not exts:
        raise Fail("the gallery API answered but returned nothing for %s - the "
                   "query reached something that is not the Marketplace" % probe)
    versions = exts[0].get("versions") or []
    if not versions:
        raise Fail("gallery response carried no versions; the query flags were "
                   "not honoured")

    emit("preflight: asset hosts")
    reachable = []
    blocked = []
    for url in vsix_urls(probe, versions[0]):
        rc, _out, errout = curl(["--range", "0-0", "--output", os.devnull, url],
                                timeout_s=30)
        if rc == 0:
            reachable.append(host_of(url))
        else:
            blocked.append("%s (%s)" % (host_of(url), curl_hint(rc, errout)))
    for line in blocked:
        emit("  unreachable %s" % line)
    if not reachable:
        raise Fail("the gallery API is reachable but no host serving VSIX "
                   "assets is. Ask for these to be allowlisted:\n    %s"
                   % "\n    ".join(host_of(u) for u in vsix_urls(probe, versions[0])))
    emit("  reachable   %s" % ", ".join(reachable))
    emit("preflight: ok")


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


# ------------------------------------------------------------------- semver

def ver_tuple(text):
    """Leading numeric triple of a version. Pre-release and build suffixes are
    dropped: VS Code's own '1.133.0-insider' orders with 1.133.0 for the
    purposes of an engine constraint."""
    head = re.split(r"[-+]", str(text).strip(), 1)[0]
    parts = head.split(".")
    out = []
    for i in range(3):
        try:
            out.append(int(parts[i]))
        except (IndexError, ValueError):
            out.append(0)
    return tuple(out)


def satisfies(constraint, version):
    """Does `version` satisfy an engines.vscode constraint?

    The grammar published to the Marketplace is small: '*', a caret range, a
    bare comparator, or a space-separated conjunction of comparators. Anything
    outside it is rejected rather than guessed at, because guessing produces an
    extension that installs and does not load.
    """
    text = (constraint or "*").strip()
    if text in ("", "*", "x", "X"):
        return True
    have = ver_tuple(version)
    for part in text.split():
        match = re.match(r"^(\^|~|>=|<=|>|<|=)?v?([0-9]+(?:\.[0-9xX*]+){0,2}.*)$",
                         part)
        if not match:
            raise Fail("unsupported engine constraint %r" % constraint)
        op = match.group(1) or "="
        base = ver_tuple(match.group(2).replace("x", "0").replace("X", "0")
                         .replace("*", "0"))
        if op == "^":
            if not (have >= base and have[0] == base[0]):
                return False
        elif op == "~":
            if not (have >= base and have[:2] == base[:2]):
                return False
        elif op == ">=":
            if not have >= base:
                return False
        elif op == "<=":
            if not have <= base:
                return False
        elif op == ">":
            if not have > base:
                return False
        elif op == "<":
            if not have < base:
                return False
        else:
            if have != base:
                return False
    return True


# -------------------------------------------------------------------- inputs

def parse_extensions_text(text):
    """One 'publisher.name[@version] [flag ...]' per line.

    Flags are 'pre' and 'on=...'. '#' comments and blank lines are ignored.
    """
    specs = []
    seen = {}
    for lineno, raw in enumerate(text.splitlines(), 1):
        line = raw.split("#", 1)[0].strip()
        if not line:
            continue
        fields = line.split()
        head = fields[0]
        pin = None
        if "@" in head:
            head, pin = head.split("@", 1)
            pin = pin.strip() or None
            if pin and not VERSION_RE.match(pin):
                raise Fail("extensions line %d: %r is not a version" % (lineno, pin))
        ident = head.strip()
        if not ID_RE.match(ident):
            raise Fail("extensions line %d is not publisher.name: %r"
                       % (lineno, raw.strip()))
        if is_builtin(ident):
            raise Fail("extensions line %d: %s is built into VS Code. The "
                       "publisher 'vscode' is the product's own, is not on the "
                       "Marketplace, and needs no staging - remove the line."
                       % (lineno, ident))
        if ident.lower() in seen:
            raise Fail("extensions line %d: %s already listed on line %d"
                       % (lineno, ident, seen[ident.lower()]))
        seen[ident.lower()] = lineno

        spec = {"id": ident, "pin": pin, "pre": False, "on": None,
                "lineno": lineno}
        for field in fields[1:]:
            if field == "pre":
                spec["pre"] = True
            elif field.startswith("on="):
                value = field[3:].strip()
                if not value:
                    raise Fail("extensions line %d: empty on=" % lineno)
                spec["on"] = [s for s in value.split(",") if s]
            else:
                raise Fail("extensions line %d: unknown field %r" % (lineno, field))
        specs.append(spec)
    if not specs:
        raise Fail("no extensions listed")
    return specs


def read_lock_identities(path):
    """Marketplace GUIDs seen previously, keyed by lowercase id.

    A publisher name can be released and re-registered by someone else; the
    GUID behind it cannot. Recording it on first use turns a silent identity
    swap into a refusal.
    """
    known = {}
    if not path or not os.path.exists(path):
        return known
    handle = open(path, "r")
    try:
        for line in handle:
            if line.startswith("#"):
                continue
            cols = line.rstrip("\n").split("\t")
            if len(cols) < 8:
                continue
            ident, ext_guid, pub_guid = cols[2], cols[6], cols[7]
            if ident and ext_guid:
                known[ident.lower()] = (ext_guid, pub_guid)
    finally:
        handle.close()
    return known


# ---------------------------------------------------------------- resolution

def query_extension(ident):
    body = {"filters": [{"criteria": [
        {"filterType": FT_EXTENSION_NAME, "value": ident},
        {"filterType": FT_INSTALLATION_TARGET, "value": VSCODE_TARGET}],
        "pageSize": 1, "pageNumber": 1}], "flags": FLAGS_RESOLVE}
    doc = curl_post_json(GALLERY, body, GALLERY_ACCEPT)
    results = doc.get("results") or [{}]
    exts = results[0].get("extensions") or []
    if not exts:
        raise Fail("%s: not found on the Marketplace - check the publisher and "
                   "name character by character" % ident)
    return exts[0]


def version_props(version):
    props = {}
    for item in version.get("properties") or []:
        props[item.get("key")] = item.get("value")
    return props


def resolve_version(ext, ident, platform, target_version, spec):
    """Pick the version to stage for one extension on one platform.

    Four rules, each of which exists because violating it fails silently:

    1. Never index the version list. It interleaves target platforms, so
       versions[0] for a multi-platform extension is an arbitrary architecture.
    2. Exclude pre-releases unless the line opted in. They sort ahead of stable
       releases and are not otherwise distinguished.
    3. Match the engine constraint against the VS Code actually installed.
    4. Never fall back across architectures. Exact platform, then a universal
       build if the publisher ships one, then refuse.
    """
    exact = []
    universal = []
    for version in ext.get("versions") or []:
        props = version_props(version)
        if props.get(P_PRERELEASE) == "true" and not spec["pre"]:
            continue
        if spec["pin"] and version.get("version") != spec["pin"]:
            continue
        if not satisfies(props.get(P_ENGINE), target_version):
            continue
        target_platform = version.get("targetPlatform")
        entry = (ver_tuple(version.get("version")), version, props)
        if target_platform is None:
            universal.append(entry)
        elif target_platform == platform:
            exact.append(entry)

    for pool in (exact, universal):
        if pool:
            pool.sort(key=lambda item: item[0], reverse=True)
            return pool[0][1], pool[0][2]

    if spec["pin"]:
        raise Fail("%s: version %s is not published for %s, or does not "
                   "support VS Code %s" % (ident, spec["pin"], platform,
                                           target_version))
    published = sorted(set(
        v.get("targetPlatform") or "universal" for v in ext.get("versions") or []))
    raise Fail("%s: nothing published for %s that supports VS Code %s "
               "(platforms published: %s). Extensions wrapping native binaries "
               "frequently ship x64 only."
               % (ident, platform, target_version, ", ".join(published)))


def vsix_urls(ident, version):
    """Every hostname that serves this exact VSIX, most canonical first.

    The `source` the gallery publishes lives on gallerycdn.vsassets.io. The
    same artifact is also reachable through the per-publisher gallery host and
    through marketplace.visualstudio.com itself. They are listed together
    because which of them an isolated network permits is not knowable from
    here.
    """
    publisher, name = ident.split(".", 1)
    number = version.get("version")
    urls = []
    for item in version.get("files") or []:
        if item.get("assetType") == VSIX_ASSET and item.get("source"):
            urls.append(item["source"])
    urls.append("https://%s.gallery.vsassets.io/_apis/public/gallery/publisher/"
                "%s/extension/%s/%s/assetbyname/%s"
                % (publisher, publisher, name, number, VSIX_ASSET))
    vspackage = ("https://marketplace.visualstudio.com/_apis/public/gallery/"
                 "publishers/%s/vsextensions/%s/%s/vspackage"
                 % (publisher, name, number))
    target_platform = version.get("targetPlatform")
    if target_platform:
        vspackage += "?targetPlatform=" + target_platform
    urls.append(vspackage)
    # The gallery does not always publish the same asset host for the same
    # artifact, so the constructed form can coincide with the published one.
    unique = []
    for url in urls:
        if url not in unique:
            unique.append(url)
    return unique


def verify_vsix(path, ident, expect_version):
    """Open the VSIX and confirm it is the artifact we asked for.

    A VSIX is a zip carrying extension/package.json. Reading it back closes the
    gap between what the gallery said and what arrived: a truncated transfer, a
    double-gzipped body, an asset served from the wrong version, or a
    republished artifact under a version already in the lock all show up here
    rather than at install time on a host with no way to diagnose it.
    """
    import zipfile
    if not zipfile.is_zipfile(path):
        raise Fail("%s: downloaded file is not a zip. The vspackage endpoint "
                   "serves gzip-encoded bodies; an undecoded one looks exactly "
                   "like this." % ident)
    archive = zipfile.ZipFile(path)
    try:
        try:
            raw = archive.read("extension/package.json")
        except KeyError:
            raise Fail("%s: no extension/package.json in the VSIX" % ident)
        try:
            manifest = json.loads(raw.decode("utf-8", "replace"))
        except ValueError as exc:
            raise Fail("%s: unreadable package.json in the VSIX: %s" % (ident, exc))
    finally:
        archive.close()

    got = "%s.%s" % (manifest.get("publisher", ""), manifest.get("name", ""))
    if got.lower() != ident.lower():
        raise Fail("%s: the VSIX identifies itself as %s" % (ident, got))
    if str(manifest.get("version", "")) != str(expect_version):
        raise Fail("%s: gallery offered %s but the VSIX contains %s"
                   % (ident, expect_version, manifest.get("version")))
    engines = manifest.get("engines") or {}
    return {"engine": engines.get("vscode"),
            "kind": manifest.get("extensionKind")}


def split_ids(value):
    return [s.strip() for s in (value or "").split(",") if s.strip()]


def is_builtin(ident):
    """Does this id name an extension bundled with VS Code itself?"""
    return ident.split(".", 1)[0].lower() == BUILTIN_PUBLISHER


# ------------------------------------------------------------------- servers

def server_meta(commit, platform_slug):
    """Metadata for one artifact at one exact commit, including the sha256
    Microsoft publishes for it. Verifying against an upstream hash is stronger
    than recording our own, so we do both."""
    url = "%s/api/versions/commit:%s/%s/stable" % (UPDATE, commit, platform_slug)
    doc = curl_json(url)
    if not doc.get("url"):
        raise Fail("no %s build published for commit %s" % (platform_slug, commit))
    return doc


def latest_stable_commit(client_platform):
    """The commit the managed install is most likely to move to next.

    This endpoint answers 'what would this build update to', so asking it about
    the commit in use returns current latest stable.
    """
    url = "%s/api/update/%s/stable/latest" % (UPDATE, client_platform)
    doc = curl_json(url)
    commit = doc.get("version")
    if not commit or not COMMIT_RE.match(commit):
        raise Fail("could not determine latest stable commit from %s" % url)
    return commit, doc.get("productVersion") or doc.get("name")


# ------------------------------------------------------------------ catalogue

def fetch_catalog(dest_path, limit):
    """Top extensions by install count as a TSV, gzipped.

    The Marketplace is the only catalogue and it is not reachable from the
    isolated network, so an id has to be discoverable offline or it has to be
    remembered. The full listing is ~114k extensions across ~570 requests and
    its tail is abandoned; ranking by installs and truncating keeps this to
    seconds and a couple of megabytes.
    """
    pagesize = 200
    rows = []
    page = 1
    while len(rows) < limit:
        body = {"filters": [{"criteria": [
            {"filterType": FT_INSTALLATION_TARGET, "value": VSCODE_TARGET},
            {"filterType": FT_EXCLUDE_WITH_FLAGS, "value": UNPUBLISHED}],
            "pageSize": pagesize, "pageNumber": page,
            "sortBy": SORT_INSTALL_COUNT, "sortOrder": 0}],
            "flags": FLAGS_CATALOG}
        doc = curl_post_json(GALLERY, body, GALLERY_ACCEPT)
        results = doc.get("results") or [{}]
        exts = results[0].get("extensions") or []
        if not exts:
            break
        for ext in exts:
            pub = ext.get("publisher") or {}
            stats = {}
            for item in ext.get("statistics") or []:
                stats[item.get("statisticName")] = item.get("value")
            ident = "%s.%s" % (pub.get("publisherName", ""),
                               ext.get("extensionName", ""))
            rows.append("\t".join([
                ident,
                str(int(stats.get("install", 0) or 0)),
                "verified" if pub.get("isDomainVerified") else "-",
                (pub.get("domain") or "-"),
                _clean(pub.get("displayName")),
                _clean(ext.get("displayName")),
                _clean(ext.get("shortDescription")),
            ]))
        emit("  catalog page %d (%d entries)" % (page, len(rows)))
        page += 1
    rows = rows[:limit]

    raw = open(dest_path, "wb")
    try:
        gz = gzip.GzipFile(filename="", mode="wb", compresslevel=9,
                           fileobj=raw, mtime=0)
        try:
            gz.write(("# id\tinstalls\tverified\tdomain\tpublisher\tname"
                      "\tdescription\n").encode("utf-8"))
            for row in rows:
                gz.write((row + "\n").encode("utf-8"))
        finally:
            gz.close()
    finally:
        raw.close()
    return len(rows)


def _clean(value):
    """Flatten to one TSV-safe line. The catalogue is grep fodder on a host
    with no Marketplace, so it must survive cut(1) and read in a terminal."""
    text = (value or "").replace("\t", " ").replace("\n", " ").replace("\r", " ")
    return re.sub(r"\s+", " ", text).strip()


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
    gzip header with no embedded name or timestamp."""
    names = []
    for dirpath, dirnames, filenames in os.walk(stage_root):
        dirnames.sort()
        for name in sorted(filenames):
            full = os.path.join(dirpath, name)
            names.append(os.path.relpath(full, stage_root))
    names.sort()

    raw = open(out_path, "wb")
    try:
        gz = gzip.GzipFile(filename="", mode="wb", compresslevel=6,
                           fileobj=raw, mtime=0)
        try:
            tar = tarfile.open(fileobj=gz, mode="w", format=tarfile.GNU_FORMAT)
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
    """Hash of the payload, independent of when it was fetched."""
    digest = hashlib.sha256()
    for rel in sorted(files.keys()):
        digest.update(rel.encode("utf-8"))
        digest.update(b"\0")
        digest.update(files[rel].encode("ascii"))
        digest.update(b"\n")
    return digest.hexdigest()


# ----------------------------------------------------------------------- main

def cached(workdir, name, urls, expect_sha=None, label="", verify=None,
           compressed=False, resume=True):
    """Fetch into the durable cache, reusing anything already verified there.

    Artifact names are immutable, so a cache hit is a genuine hit. It is still
    re-verified on every run: a cached file that no longer matches its
    published hash, or no longer reads as the artifact it claims to be, is
    discarded rather than carried across the boundary.
    """
    path = os.path.join(workdir, name)
    if os.path.exists(path):
        digest = sha256_file(path)
        ok = expect_sha is None or digest == expect_sha
        if ok and verify is not None:
            try:
                verify(path)
            except Fail:
                ok = False
        if ok:
            emit("  cached  %s" % (label or name))
            return path, digest
        emit("  cached copy of %s did not verify, refetching" % name)
        unlink_quietly(path)

    emit("  fetch   %s" % (label or name))
    source = download_any(urls, path, compressed=compressed, resume=resume)
    if len(urls) > 1 and source != urls[0]:
        emit("            via %s" % host_of(source))
    digest = sha256_file(path)
    if expect_sha is not None and digest != expect_sha:
        unlink_quietly(path)
        raise Fail("%s: sha256 %s does not match the published %s"
                   % (name, digest, expect_sha))
    if verify is not None:
        try:
            verify(path)
        except Fail:
            unlink_quietly(path)
            raise
    return path, digest


def main(argv):
    parser = argparse.ArgumentParser(
        description="Fetch VS Code extensions and server builds into a "
                    "verified bundle.")
    parser.add_argument("--out", required=True,
                        help="staging directory for the bundle")
    parser.add_argument("--workdir", default=None,
                        help="durable cache; defaults to <out>/cache")
    parser.add_argument("--extensions", required=True,
                        help="extensions.txt of pinned publisher.name lines")
    parser.add_argument("--lock", default=None,
                        help="extensions.lock, for Marketplace identity pinning")
    parser.add_argument("--vscode-version", required=True,
                        help="version from `code --version`, e.g. 1.133.0")
    parser.add_argument("--vscode-commit", required=True,
                        help="commit from `code --version`")
    parser.add_argument("--client-platform", default="win32-x64",
                        help="platform of the machine running VS Code")
    parser.add_argument("--platform", action="append", default=[],
                        dest="platforms",
                        help="target platform to stage; repeatable")
    parser.add_argument("--no-hedge", dest="hedge", action="store_false",
                        default=True,
                        help="stage only the current commit's server, not "
                             "latest stable as well")
    parser.add_argument("--no-catalog", dest="catalog", action="store_false",
                        default=True, help="omit the Marketplace index")
    parser.add_argument("--catalog-size", type=int, default=5000,
                        help="how many extensions the index carries")
    parser.add_argument("--skip-preflight", action="store_true")
    args = parser.parse_args(argv[1:])

    if not COMMIT_RE.match(args.vscode_commit):
        raise Fail("--vscode-commit %r is not a 40-character commit hash"
                   % args.vscode_commit)
    if not VERSION_RE.match(args.vscode_version):
        raise Fail("--vscode-version %r is not a version" % args.vscode_version)

    platforms = []
    for item in args.platforms:
        for value in item.split(","):
            value = value.strip()
            if value and value not in platforms:
                platforms.append(value)
    if args.client_platform not in platforms:
        platforms.insert(0, args.client_platform)
    for value in platforms:
        if value not in KNOWN_PLATFORMS:
            raise Fail("unknown platform %r (known: %s)"
                       % (value, ", ".join(KNOWN_PLATFORMS)))
    server_platforms = [p for p in platforms if p != args.client_platform]

    handle = open(args.extensions, "r")
    try:
        specs = parse_extensions_text(handle.read())
    finally:
        handle.close()
    known_ids = read_lock_identities(args.lock)

    if not args.skip_preflight:
        preflight()

    out_dir = os.path.expanduser(args.out)
    if not os.path.isdir(out_dir):
        os.makedirs(out_dir)
    workdir = os.path.expanduser(args.workdir or os.path.join(out_dir, "cache"))
    for sub in ("vsix", "server"):
        target = os.path.join(workdir, sub)
        if not os.path.isdir(target):
            os.makedirs(target)

    stage_root = tempfile.mkdtemp(prefix="sneaker-bundle-", dir=out_dir)
    warnings = []
    records = []
    listed = set(s["id"].lower() for s in specs)
    required_by = {}
    builtin_by = {}

    try:
        # --- resolve everything before downloading anything ------------------
        emit("")
        emit("resolving against VS Code %s (%s)"
             % (args.vscode_version, args.vscode_commit[:12]))
        resolved = []
        for spec in specs:
            ident = spec["id"]
            emit("resolve  %s" % ident)
            ext = query_extension(ident)
            pub = ext.get("publisher") or {}
            real = "%s.%s" % (pub.get("publisherName", ""),
                              ext.get("extensionName", ""))
            if real.lower() != ident.lower():
                raise Fail("%s: the Marketplace returned %s - the query matched "
                           "a different extension" % (ident, real))

            guids = (ext.get("extensionId") or "", pub.get("publisherId") or "")
            seen = known_ids.get(ident.lower())
            if seen and seen[0] and seen[0] != guids[0]:
                raise Fail("%s: Marketplace extension id changed from %s to %s. "
                           "The name now points at a different extension; "
                           "review it before continuing."
                           % (ident, seen[0], guids[0]))
            if seen and seen[1] and guids[1] and seen[1] != guids[1]:
                raise Fail("%s: publisher id changed from %s to %s. The "
                           "publisher name has changed hands; review it before "
                           "continuing." % (ident, seen[1], guids[1]))
            if not pub.get("isDomainVerified"):
                warnings.append("%s: publisher %s is not domain-verified"
                                % (ident, pub.get("publisherName")))

            per_platform = {}
            kinds = set()
            for platform in platforms:
                version, props = resolve_version(ext, ident, platform,
                                                 args.vscode_version, spec)
                per_platform[platform] = (version, props)
                kinds.update(split_ids(props.get(P_KIND)))
                for dep in split_ids(props.get(P_PACK)) + split_ids(props.get(P_DEPS)):
                    if is_builtin(dep):
                        builtin_by.setdefault(dep.lower(), set()).add(ident)
                        continue
                    required_by.setdefault(dep.lower(), set()).add(ident)

            kinds = kinds or set(["workspace"])
            sample = per_platform[platforms[0]]
            emit("  %s  engine %s  kind %s"
                 % (sample[0].get("version"), sample[1].get(P_ENGINE) or "*",
                    ",".join(sorted(kinds))))
            resolved.append({"spec": spec, "ext": ext, "guids": guids,
                             "kinds": kinds, "per_platform": per_platform,
                             "publisher": pub})

        # --- packs and dependencies are resolved, never fetched implicitly ---
        for dep in sorted(builtin_by):
            emit("  %s is built into VS Code; required by %s, nothing to stage"
                 % (dep, ", ".join(sorted(builtin_by[dep]))))
        missing = sorted(dep for dep in required_by if dep not in listed)
        if missing:
            lines = []
            for dep in missing:
                lines.append("    %s   (required by %s)"
                             % (dep, ", ".join(sorted(required_by[dep]))))
            raise Fail("extensions.txt is missing required entries. Review each "
                       "on the Marketplace, then add:\n%s" % "\n".join(lines))

        # --- VSIXs -----------------------------------------------------------
        emit("")
        for item in resolved:
            ident = item["spec"]["id"]
            wanted = item["spec"]["on"]
            for platform in platforms:
                version, props = item["per_platform"][platform]
                is_local = platform == args.client_platform
                kinds = item["kinds"]
                if wanted is None:
                    want = ("ui" in kinds) if is_local else ("workspace" in kinds)
                elif wanted == ["local"]:
                    want = is_local
                elif wanted == ["remote"]:
                    want = not is_local
                else:
                    want = not is_local
                if not want:
                    continue

                number = version.get("version")
                name = "%s-%s-%s.vsix" % (ident, number, platform)
                path, digest = cached(
                    os.path.join(workdir, "vsix"), name,
                    vsix_urls(ident, version),
                    label="%s %s (%s)" % (ident, number, platform),
                    verify=lambda p, i=ident, n=number: verify_vsix(p, i, n),
                    compressed=True, resume=False)
                inner = verify_vsix(path, ident, number)
                if inner["engine"] and inner["engine"] != props.get(P_ENGINE):
                    warnings.append(
                        "%s %s: gallery advertises engine %s but the VSIX "
                        "declares %s" % (ident, number, props.get(P_ENGINE),
                                         inner["engine"]))
                rel = os.path.join("vsix", platform, os.path.basename(name))
                final = os.path.join(stage_root, rel)
                if not os.path.isdir(os.path.dirname(final)):
                    os.makedirs(os.path.dirname(final))
                shutil.copyfile(path, final)
                records.append({
                    "id": ident,
                    "version": version.get("version"),
                    "platform": platform,
                    "target_platform": version.get("targetPlatform") or "universal",
                    "engine": props.get(P_ENGINE) or "*",
                    "vsix_engine": inner["engine"],
                    "kind": sorted(item["kinds"]),
                    "prerelease": props.get(P_PRERELEASE) == "true",
                    "pinned": bool(item["spec"]["pin"]),
                    "extension_id": item["guids"][0],
                    "publisher_id": item["guids"][1],
                    "publisher_verified": bool(item["publisher"].get("isDomainVerified")),
                    "side": "local" if is_local else "remote",
                    "path": rel.replace(os.sep, "/"),
                    "sha256": digest,
                    "bytes": os.path.getsize(final),
                })

        # --- server and CLI tarballs -----------------------------------------
        commits = [(args.vscode_commit, args.vscode_version, "installed")]
        if args.hedge:
            try:
                hedge_commit, hedge_version = latest_stable_commit(args.client_platform)
                if hedge_commit != args.vscode_commit:
                    commits.append((hedge_commit, hedge_version, "latest-stable"))
                else:
                    emit("")
                    emit("hedge    already on latest stable, nothing to pre-stage")
            except Fail as exc:
                warnings.append("hedge: %s" % exc)

        servers = []
        if server_platforms:
            emit("")
            for commit, version, role in commits:
                emit("server   %s %s (%s)" % (version, commit[:12], role))
                for platform in server_platforms:
                    for kind, slug, filename in (
                            ("server", "server-" + platform,
                             "vscode-server-%s.tar.gz" % platform),
                            ("cli", "cli-" + platform,
                             "vscode_cli_%s_cli.tar.gz" % platform.replace("-", "_"))):
                        try:
                            meta = server_meta(commit, slug)
                        except Fail as exc:
                            if kind == "cli":
                                # The CLI is only needed by the newer bootstrap
                                # layout; its absence degrades rather than
                                # blocks.
                                warnings.append(str(exc))
                                continue
                            raise Fail(
                                "no VS Code Server build is published for %s at "
                                "commit %s. Microsoft does not ship a server for "
                                "every architecture - armhf was discontinued - "
                                "and a host on this platform cannot run "
                                "Remote-SSH at all. Drop it from HOST_PLATFORM "
                                "rather than staging a bundle that omits it."
                                % (platform, commit[:12]))
                        name = "%s-%s-%s" % (commit[:12], kind, filename)
                        path, digest = cached(
                            os.path.join(workdir, "server"), name,
                            [meta["url"]],
                            expect_sha=meta.get("sha256hash"),
                            label="%s %s" % (kind, platform))
                        rel = "server/%s/%s" % (commit, filename)
                        final = os.path.join(stage_root, rel)
                        if not os.path.isdir(os.path.dirname(final)):
                            os.makedirs(os.path.dirname(final))
                        shutil.copyfile(path, final)
                        servers.append({
                            "commit": commit,
                            "product_version": meta.get("productVersion") or version,
                            "role": role,
                            "kind": kind,
                            "platform": platform,
                            "path": rel,
                            "sha256": digest,
                            "published_sha256": meta.get("sha256hash"),
                            "bytes": os.path.getsize(final),
                        })

        # --- catalogue --------------------------------------------------------
        catalog_entries = 0
        if args.catalog:
            emit("")
            emit("catalog  top %d by install count" % args.catalog_size)
            cat_dir = os.path.join(stage_root, "catalog")
            os.makedirs(cat_dir)
            try:
                catalog_entries = fetch_catalog(
                    os.path.join(cat_dir, "marketplace.tsv.gz"),
                    args.catalog_size)
            except Fail as exc:
                warnings.append("catalog: %s" % exc)
                shutil.rmtree(cat_dir, ignore_errors=True)

        # --- manifest, sums, bundle -------------------------------------------
        payload = {}
        for dirpath, dirnames, filenames in os.walk(stage_root):
            dirnames.sort()
            for name in sorted(filenames):
                full = os.path.join(dirpath, name)
                payload[os.path.relpath(full, stage_root)] = sha256_file(full)

        manifest_doc = {
            "schema": 1,
            "tool": "sneaker/vscode-extensions",
            "tool_version": "0.1.0",
            "created_utc": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
            "source_host": os.uname()[1],
            "content_id": content_id(payload),
            "vscode": {"version": args.vscode_version,
                       "commit": args.vscode_commit,
                       "client_platform": args.client_platform},
            "platforms": platforms,
            "extensions": records,
            "servers": servers,
            "catalog_entries": catalog_entries,
            "builtin_dependencies": dict(
                (dep, sorted(builtin_by[dep])) for dep in sorted(builtin_by)),
            "warnings": warnings,
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
        bundle_path = os.path.join(out_dir,
                                   "vscode-extensions-%s.tar.gz" % stamp)
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
    emit("extensions %d vsix across %s" % (len(records), ", ".join(platforms)))
    emit("servers    %d tarballs for %d commit(s)"
         % (len(servers), len(set(s["commit"] for s in servers))))
    if catalog_entries:
        emit("catalog    %d entries" % catalog_entries)
    for line in warnings:
        emit("warning    %s" % line)

    sys.stdout.write("SNEAKER_BUNDLE %s %s %d\n" % (bundle_path, digest, size))
    return 0


if __name__ == "__main__":
    try:
        sys.exit(main(sys.argv))
    except Fail as exc:
        sys.stderr.write("fatal: %s\n" % exc)
        sys.exit(1)
    except KeyboardInterrupt:
        sys.stderr.write("interrupted\n")
        sys.exit(130)
