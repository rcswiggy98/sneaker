#!/usr/bin/env python3
"""Reject syntax and APIs newer than Python 3.6 in the files that ship to the
bastion and to remote vault hosts. RHEL 8 has 3.6.8 and no newer interpreter,
so a 3.7+ construct is a runtime failure we cannot reproduce locally."""
import ast
import re
import sys

TARGETS = ["bastion/fetch-obsidian-plugins.py", "lib/vaultinfo.py",
           "bastion/fetch-vscode-extensions.py", "lib/vscodeinfo.py",
           "tests/make_vscode_fixture.py"]

NEW_KWARGS = {"capture_output", "text", "encoding_errors"}
NEW_MODULES = {"dataclasses", "contextvars", "importlib.resources",
               "zoneinfo", "graphlib", "tomllib"}
NEW_ATTRS = {"removeprefix", "removesuffix", "cached_property", "prod",
             "nullcontext", "fromisoformat"}
GENERIC_BUILTINS = {"list", "dict", "set", "tuple", "type", "frozenset"}


def check(path):
    problems = []
    src = open(path).read()
    tree = ast.parse(src, path)

    for m in re.finditer(r'f["\'].*?[{][^{}]*=\s*[}:!]', src):
        problems.append("f-string '=' specifier (3.8) near offset %d" % m.start())

    for node in ast.walk(tree):
        name = type(node).__name__
        if name == "NamedExpr":
            problems.append("line %d: walrus operator (3.8)" % node.lineno)
        if name == "arguments" and getattr(node, "posonlyargs", None):
            problems.append("positional-only parameters (3.8)")
        if isinstance(node, ast.ImportFrom):
            if node.module == "__future__" and any(a.name == "annotations" for a in node.names):
                problems.append("line %d: from __future__ import annotations (3.7)" % node.lineno)
            if node.module in NEW_MODULES:
                problems.append("line %d: module %s" % (node.lineno, node.module))
        if isinstance(node, ast.Import):
            for a in node.names:
                if a.name in NEW_MODULES:
                    problems.append("line %d: module %s" % (node.lineno, a.name))
        if isinstance(node, ast.Call):
            for kw in node.keywords:
                if kw.arg in NEW_KWARGS:
                    problems.append("line %d: keyword %s= (3.7)" % (node.lineno, kw.arg))
        if isinstance(node, ast.Attribute) and node.attr in NEW_ATTRS:
            problems.append("line %d: .%s (3.8/3.9)" % (node.lineno, node.attr))
        if isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name):
            if node.value.id in GENERIC_BUILTINS:
                problems.append("line %d: builtin generic %s[...] (3.9)"
                                % (node.lineno, node.value.id))
    return problems


rc = 0
for target in TARGETS:
    found = check(target)
    if found:
        rc = 1
        print("  FAIL %s" % target)
        for line in found:
            print("       %s" % line)
    else:
        print("  ok   %s is 3.6-compatible" % target)
sys.exit(rc)
