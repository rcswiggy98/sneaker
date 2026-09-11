#!/usr/bin/env python3
"""Resolution rules for the vscode-extensions domain. No network.

Every rule here exists because violating it produces an extension that
installs without complaint and then does not work. They are tested against
synthetic gallery responses so a change in behaviour fails here rather than on
a host with no way to diagnose it.
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
spec = importlib.util.spec_from_file_location(
    "fetch_vscode", os.path.join(ROOT, "bastion", "fetch-vscode-extensions.py"))
F = importlib.util.module_from_spec(spec)
spec.loader.exec_module(F)

CHECKS = []


def check(name, fn):
    CHECKS.append((name, fn))


def raises(fn, fragment):
    try:
        fn()
    except F.Fail as exc:
        assert fragment in str(exc), "wrong error: %s" % exc
        return
    raise AssertionError("expected a Fail mentioning %r" % fragment)


def version(number, platform=None, engine="*", pre=False, extra=None):
    props = [{"key": F.P_ENGINE, "value": engine}]
    if pre:
        props.append({"key": F.P_PRERELEASE, "value": "true"})
    for key, value in (extra or {}).items():
        props.append({"key": key, "value": value})
    doc = {"version": number, "properties": props,
           "files": [{"assetType": F.VSIX_ASSET,
                      "source": "https://cdn.example/%s" % number}]}
    if platform is not None:
        doc["targetPlatform"] = platform
    return doc


SPEC = {"pin": None, "pre": False, "on": None}


# ------------------------------------------------------------------- semver

def t_semver():
    assert F.satisfies("*", "1.133.0")
    assert F.satisfies(None, "1.133.0")
    assert F.satisfies("^1.133.0", "1.133.0")
    assert F.satisfies("^1.77.0", "1.133.0")
    # A caret range on VS Code is unbounded in practice: the major has been 1
    # for the product's whole life, so an engine constraint is a floor.
    assert F.satisfies("^1.63.0", "1.133.0")
    assert not F.satisfies("^1.137.0", "1.133.0")
    assert F.satisfies(">=1.74.0", "1.133.0")
    assert not F.satisfies(">=1.140.0", "1.133.0")
    assert F.satisfies(">=1.70.0 <1.140.0", "1.133.0")
    assert not F.satisfies(">=1.70.0 <1.100.0", "1.133.0")
    assert F.satisfies("~1.133.0", "1.133.4")
    assert not F.satisfies("~1.133.0", "1.134.0")
    # Insider builds order with their release for constraint purposes.
    assert F.satisfies("^1.133.0", "1.133.0-insider")
    raises(lambda: F.satisfies("not-a-range", "1.133.0"),
           "unsupported engine constraint")


check("semver ranges", t_semver)


# ------------------------------------------------------ rule 1: no indexing

def t_no_indexing():
    """The version list interleaves platforms. Indexing it yields an
    arbitrary architecture - versions[0] for a real multi-platform extension
    comes back alpine-x64."""
    ext = {"versions": [
        version("1.35.0", "alpine-x64"),
        version("1.35.0", "linux-arm64"),
        version("1.35.0", "linux-x64"),
    ]}
    got, _props = F.resolve_version(ext, "a.b", "linux-x64", "1.133.0", SPEC)
    assert got["targetPlatform"] == "linux-x64", got


check("rule 1: platform is filtered, never indexed", t_no_indexing)


# -------------------------------------------------- rule 2: pre-releases out

def t_prerelease():
    ext = {"versions": [
        version("0.129.0", None, "^1.133.0", pre=True),
        version("0.128.0", None, "^1.133.0"),
    ]}
    got, _ = F.resolve_version(ext, "a.b", "win32-x64", "1.133.0", SPEC)
    assert got["version"] == "0.128.0", got

    opted = dict(SPEC)
    opted["pre"] = True
    got, _ = F.resolve_version(ext, "a.b", "win32-x64", "1.133.0", opted)
    assert got["version"] == "0.129.0", got


check("rule 2: pre-releases excluded unless opted in", t_prerelease)


# ------------------------------------------------------- rule 3: engine floor

def t_engine():
    ext = {"versions": [
        version("2.0.0", None, "^1.137.0"),
        version("1.9.0", None, "^1.133.0"),
        version("1.0.0", None, "^1.60.0"),
    ]}
    got, _ = F.resolve_version(ext, "a.b", "win32-x64", "1.133.0", SPEC)
    assert got["version"] == "1.9.0", got


check("rule 3: newest version the engine admits", t_engine)


# ------------------------------------------- rule 4: no cross-arch fallback

def t_no_arch_fallback():
    ext = {"versions": [version("1.0.0", "linux-x64")]}
    raises(lambda: F.resolve_version(ext, "a.b", "linux-arm64", "1.133.0", SPEC),
           "nothing published for linux-arm64")


def t_universal_fallback():
    """A universal build is a legitimate answer for any platform; a build for
    a different architecture never is."""
    ext = {"versions": [version("1.0.0", "linux-x64"), version("1.0.0", None)]}
    got, _ = F.resolve_version(ext, "a.b", "linux-arm64", "1.133.0", SPEC)
    assert got.get("targetPlatform") is None, got


def t_exact_beats_universal():
    ext = {"versions": [version("1.0.0", None), version("1.0.0", "linux-arm64")]}
    got, _ = F.resolve_version(ext, "a.b", "linux-arm64", "1.133.0", SPEC)
    assert got.get("targetPlatform") == "linux-arm64", got


check("rule 4: no fallback across architectures", t_no_arch_fallback)
check("rule 4: universal build is an acceptable answer", t_universal_fallback)
check("rule 4: exact platform wins over universal", t_exact_beats_universal)


# ------------------------------------------------------------- pinned lines

def t_pin():
    ext = {"versions": [version("2.0.0", None, "^1.0.0"),
                        version("1.0.0", None, "^1.0.0")]}
    spec = dict(SPEC)
    spec["pin"] = "1.0.0"
    got, _ = F.resolve_version(ext, "a.b", "win32-x64", "1.133.0", spec)
    assert got["version"] == "1.0.0", got

    spec["pin"] = "9.9.9"
    raises(lambda: F.resolve_version(ext, "a.b", "win32-x64", "1.133.0", spec),
           "is not published")


check("pinned versions are honoured and missing pins refuse", t_pin)


# ------------------------------------------------------------- input parsing

def t_parse():
    specs = F.parse_extensions_text(
        "# comment\n"
        "ms-vscode-remote.remote-ssh\n"
        "ms-vscode.cpptools@1.34.4   on=armlab01,lab02\n"
        "pub.name  pre  on=local\n"
        "\n")
    assert [s["id"] for s in specs] == [
        "ms-vscode-remote.remote-ssh", "ms-vscode.cpptools", "pub.name"]
    assert specs[1]["pin"] == "1.34.4"
    assert specs[1]["on"] == ["armlab01", "lab02"]
    assert specs[2]["pre"] is True and specs[2]["on"] == ["local"]

    raises(lambda: F.parse_extensions_text("remote-ssh\n"),
           "is not publisher.name")
    raises(lambda: F.parse_extensions_text("a.b\na.b\n"), "already listed")
    raises(lambda: F.parse_extensions_text("a.b  nonsense\n"), "unknown field")
    raises(lambda: F.parse_extensions_text("a.b@notaversion\n"), "not a version")
    raises(lambda: F.parse_extensions_text("# only comments\n"),
           "no extensions listed")
    # The id becomes a path component on both sides of the boundary.
    raises(lambda: F.parse_extensions_text("../etc.passwd\n"),
           "is not publisher.name")


check("extensions.txt parsing", t_parse)


# --------------------------------------------------------- asset host list

def t_urls():
    v = version("1.0.0", "linux-x64")
    urls = F.vsix_urls("pub.name", v)
    hosts = [F.host_of(u) for u in urls]
    assert any("marketplace.visualstudio.com" in h for h in hosts), hosts
    assert any("gallery.vsassets.io" in h for h in hosts), hosts
    assert urls == list(dict.fromkeys(urls)), "candidate list must be deduped"
    assert "targetPlatform=linux-x64" in urls[-1], urls[-1]


check("VSIX candidate hosts are deduped and platform-qualified", t_urls)


# ------------------------------------------------------------ identity pins

def t_lock(tmp="/tmp/sneaker-lock-test.tsv"):
    handle = open(tmp, "w")
    try:
        handle.write("# utc\ttarget\tid\tversion\tplatform\tengine\text\tpub\tsha\n")
        handle.write("t\tlaptop\tpub.name\t1.0.0\twin32-x64\t*\tEXT\tPUB\tabc\n")
        handle.write("short\tline\n")
    finally:
        handle.close()
    try:
        known = F.read_lock_identities(tmp)
        assert known == {"pub.name": ("EXT", "PUB")}, known
        assert F.read_lock_identities("/nonexistent") == {}
    finally:
        os.unlink(tmp)


check("lock identities are read back for pinning", t_lock)


# --------------------------------------------------------------------- run

failed = 0
for name, fn in CHECKS:
    try:
        fn()
    except Exception as exc:
        failed += 1
        print("  FAIL %s: %s" % (name, exc))
    else:
        print("  ok   %s" % name)
print("%d checks, %d failed" % (len(CHECKS), failed))
sys.exit(1 if failed else 0)
