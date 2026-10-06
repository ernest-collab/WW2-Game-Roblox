#!/usr/bin/env python3
"""Static cross-subsystem contract check for WW2 Frontlines.

Reports:
  1. Remotes used on the client (Net.event/func/unreliable) that the server never creates,
     or creates only lazily (outside module level / Init / Start), which would make the
     client's WaitForChild hang.
  2. Remotes whose kind differs between client and server (event vs unreliable vs func).
  3. Bus events connected but never fired (and fired but never connected) per VM side.
  4. Attributes read (GetAttribute / GetAttributeChangedSignal) that nothing ever writes.
  5. Cross-module API calls (`X.fn` / `X:fn` on a required/aliased Service, Controller, UI or Util
     module, and string helpers like callService("X", "fn")) to members the module does not define,
     and `.` vs `:` call-style mismatches.

Heuristic, regex based (the code is StyLua-formatted with tabs). Exit code 1 on errors (1-2).
Usage: python3 scripts/contracts_check.py [--verbose]
"""

import os
import re
import sys

ROOT = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src")
NET_RE = re.compile(r'Net\.(event|func|unreliable)\(\s*"([A-Za-z0-9_]+)"')
BUS_FIRE_RE = re.compile(r'Bus\.fire\(\s*"([A-Za-z0-9_]+)"')
BUS_CONN_RE = re.compile(r'Bus\.(?:connect|get)\(\s*"([A-Za-z0-9_]+)"')
ATTR_SET_RE = re.compile(r'SetAttribute\(\s*"([A-Za-z0-9_]+)"')
ATTR_GET_RE = re.compile(r'(?:GetAttribute|GetAttributeChangedSignal)\(\s*"([A-Za-z0-9_]+)"')
UIREM_RE = re.compile(r'Remotes\.(onEvent|fire|invoke|wait|find)\(\s*"([A-Za-z0-9_]+)"')
TOPFN_RE = re.compile(r"^(?:local\s+)?function\s+([A-Za-z0-9_.:]+)")


def side_of(path):
    rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    if rel.startswith("server/"):
        return "server"
    if rel.startswith("client/"):
        return "client"
    return "shared"


def scan():
    files = []
    for dirpath, _, names in os.walk(ROOT):
        for n in names:
            if n.endswith(".luau"):
                files.append(os.path.join(dirpath, n))
    files.sort()
    remotes = {}  # name -> list of (side, kind, file, line, scope)
    bus = {"server": ({}, {}), "client": ({}, {}), "shared": ({}, {})}
    attr_set, attr_get = {}, {}
    for path in files:
        side = side_of(path)
        rel = os.path.relpath(path, os.path.join(ROOT, "..")).replace(os.sep, "/")
        scope = "<module>"
        with open(path, encoding="utf-8") as fh:
            for i, line in enumerate(fh, 1):
                m = TOPFN_RE.match(line)
                if m:
                    scope = m.group(1)
                elif line.startswith("end"):
                    scope = "<module>"
                indent0 = not line.startswith("\t")
                for km in NET_RE.finditer(line):
                    s = "<module>" if indent0 and not m else scope
                    remotes.setdefault(km.group(2), []).append((side, km.group(1), rel, i, s))
                for km in UIREM_RE.finditer(line):
                    kind = {"fire": "event", "invoke": "func"}.get(km.group(1), "any")
                    remotes.setdefault(km.group(2), []).append((side, kind, rel, i, "ui"))
                for bm in BUS_FIRE_RE.finditer(line):
                    bus[side][0].setdefault(bm.group(1), []).append(f"{rel}:{i}")
                for bm in BUS_CONN_RE.finditer(line):
                    bus[side][1].setdefault(bm.group(1), []).append(f"{rel}:{i}")
                for am in ATTR_SET_RE.finditer(line):
                    attr_set.setdefault(am.group(1), []).append(f"{rel}:{i}")
                for am in ATTR_GET_RE.finditer(line):
                    attr_get.setdefault(am.group(1), []).append(f"{rel}:{i}")
    return remotes, bus, attr_set, attr_get


def is_eager(scope):
    s = scope.split(":")[-1].split(".")[-1]
    return scope == "<module>" or s in ("Init", "Start")


# --- 5. cross-module API calls -------------------------------------------------------------------
API_DIRS = ("server/Services", "client/Controllers", "client/UI", "shared/Util", "shared/WeaponModels",
            "shared/VehicleModels", "shared/GameState", "shared/Cosmetics", "server/Maps/MapKit")
ALIAS_RE = re.compile(
    r'local\s+([A-Za-z_][A-Za-z0-9_]*)\s*(?::\s*[A-Za-z_.]+\s*)?=\s*(?:\(?\s*)?'
    r'(?:[A-Za-z_]+\(\s*"([A-Za-z0-9_]+)"\s*\)|require\([^)]*?\.?([A-Za-z0-9_]+)\s*\)|'
    r'require\([^)]*?WaitForChild\(\s*"([A-Za-z0-9_]+)"[^)]*\)\s*\))'
)
CALLSTR_RE = re.compile(r'[A-Za-z_]+\(\s*"([A-Za-z0-9_]+(?:Service|Controller))"\s*,\s*"([A-Za-z_][A-Za-z0-9_]*)"')
INLINE_RE = re.compile(r'[A-Za-z_]+\(\s*"([A-Za-z0-9_]+(?:Service|Controller))"\s*\)\s*\)?\s*([.:])([A-Za-z_][A-Za-z0-9_]*)')


styles = {}


def module_api():
    mods = {}
    for dirpath, _, names in os.walk(ROOT):
        rel = os.path.relpath(dirpath, ROOT).replace(os.sep, "/")
        for n in names:
            if not n.endswith(".luau"):
                continue
            path = os.path.join(dirpath, n)
            relf = (rel + "/" + n)
            if not any(relf.startswith(d) for d in API_DIRS):
                continue
            name = os.path.basename(dirpath) if n == "init.luau" else n[:-5]
            src = open(path, encoding="utf-8").read()
            rets = re.findall(r"(?m)^return\s+([A-Za-z_][A-Za-z0-9_]*)\s*$", src)
            if not rets:
                continue
            t = rets[-1]
            members = set(re.findall(r"(?m)^function\s+" + t + r"[.:]([A-Za-z_][A-Za-z0-9_]*)", src))
            members |= set(re.findall(r"(?m)^" + t + r"\.([A-Za-z_][A-Za-z0-9_]*)\s*=", src))
            # fields in the constructor `local T = { a = ..., b = ... }` (top-level keys only, rough)
            m = re.search(r"(?ms)^local\s+" + t + r"\b[^=\n]*=\s*\{(.*?)^\}", src)
            if m:
                members |= set(re.findall(r"(?m)^\t([A-Za-z_][A-Za-z0-9_]*)\s*=", m.group(1)))
            members |= set(re.findall(r"(?m)^export\s+type\s+([A-Za-z_][A-Za-z0-9_]*)", src))
            if re.search(r"setmetatable\(\s*" + t, src):
                members.add("*")
            for sep, fn in re.findall(r"(?m)^function\s+" + t + r"([.:])([A-Za-z_][A-Za-z0-9_]*)", src):
                styles.setdefault(name, {})[fn] = sep
            mods.setdefault(name, members)
    return mods


def check_api():
    mods = module_api()
    problems = []
    checked = 0
    for dirpath, _, names in os.walk(ROOT):
        for n in names:
            if not n.endswith(".luau"):
                continue
            path = os.path.join(dirpath, n)
            rel = os.path.relpath(path, os.path.join(ROOT, "..")).replace(os.sep, "/")
            self_name = os.path.basename(dirpath) if n == "init.luau" else n[:-5]
            text = open(path, encoding="utf-8").read()
            text = re.sub(r"--\[(=*)\[.*?\]\1\]", lambda m: "\n" * m.group(0).count("\n"), text, flags=re.S)
            lines = text.split("\n")
            alias = {}
            for line in lines:
                for m in ALIAS_RE.finditer(line):
                    target = m.group(2) or m.group(3) or m.group(4)
                    if target in mods and target != self_name:
                        alias[m.group(1)] = target
            for i, line in enumerate(lines, 1):
                code = re.sub(r'"[^"]*"', '""', line.split("--")[0])
                for a, target in alias.items():
                    for m in re.finditer(r"(?<![A-Za-z0-9_.])" + a + r"([.:])([A-Za-z_][A-Za-z0-9_]*)", code):
                        mem = m.group(2)
                        checked += 1
                        want = styles.get(target, {}).get(mem)
                        after = code[m.end():].lstrip()
                        if want and after.startswith("(") and want != m.group(1):
                            if not (m.group(1) == "." and after[1:].lstrip().startswith(a)):
                                problems.append(f"{rel}:{i}: {a}{m.group(1)}{mem}( but defined as {target}{want}{mem}")
                        if "*" in mods[target] or mem in mods[target]:
                            continue
                        problems.append(f"{rel}:{i}: {a}{m.group(1)}{mem} -- {target} has no member '{mem}'")
                for m in CALLSTR_RE.finditer(line.split("--")[0]):
                    target, mem = m.group(1), m.group(2)
                    checked += 1
                    if target in mods and "*" not in mods[target] and mem not in mods[target]:
                        problems.append(f"{rel}:{i}: call {target}.{mem} -- no member '{mem}'")
                for m in INLINE_RE.finditer(code):
                    target, mem = m.group(1), m.group(3)
                    if target in mods and "*" not in mods[target] and mem not in mods[target]:
                        problems.append(f"{rel}:{i}: {target}{m.group(2)}{mem} -- no member '{mem}'")
    print(f"api: {checked} cross-module member references checked")
    return problems


def main():
    verbose = "--verbose" in sys.argv
    remotes, bus, attr_set, attr_get = scan()
    errors, warnings = [], []

    for name, uses in sorted(remotes.items()):
        server = [u for u in uses if u[0] == "server"]
        client = [u for u in uses if u[0] == "client"]
        kinds = {u[1] for u in uses if u[1] != "any"}
        if len(kinds) > 1:
            errors.append(f"remote {name}: mixed kinds {sorted(kinds)} " + ", ".join(f"{u[2]}:{u[3]}" for u in uses))
        if client and not server:
            errors.append(f"remote {name}: used by client ({client[0][2]}:{client[0][3]}) but never created by server")
        elif client and not any(is_eager(u[4]) for u in server):
            errors.append(
                f"remote {name}: server creates it only lazily ("
                + ", ".join(f"{u[2]}:{u[3]} in {u[4]}" for u in server)
                + ") -> client WaitForChild may hang"
            )
        if server and not client and verbose:
            warnings.append(f"remote {name}: server-only (no client listener)")

    for side in ("server", "client"):
        fired, conn = bus[side][0], bus[side][1]
        shared_fired = bus["shared"][0]
        for name, where in sorted(conn.items()):
            if name not in fired and name not in shared_fired:
                warnings.append(f"bus[{side}] {name}: connected ({where[0]}) but never fired on {side}")
        if verbose:
            for name, where in sorted(fired.items()):
                if name not in conn:
                    warnings.append(f"bus[{side}] {name}: fired ({where[0]}) but nobody listens")

    for name, where in sorted(attr_get.items()):
        if name not in attr_set:
            warnings.append(f"attribute {name}: read ({where[0]}) but never written via SetAttribute")

    for p in check_api():
        errors.append("api " + p)

    for w in warnings:
        print("WARN ", w)
    for e in errors:
        print("ERROR", e)
    print(f"contracts_check: {len(errors)} error(s), {len(warnings)} warning(s)")
    return 1 if errors else 0


if __name__ == "__main__":
    sys.exit(main())
