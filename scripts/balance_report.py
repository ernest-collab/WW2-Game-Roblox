#!/usr/bin/env python3
"""WW2 Frontlines balance report.

Loads the real config modules (src/shared/Config/{Weapons,Vehicles,Classes,GameModes,Progression,
Factions}.luau) by running them in the Luau CLI with a tiny Roblox mock, then computes:

  * infantry: shots-to-kill (body/head/limb) at 10/25/50/100/200 studs, TTK, DPS, mag dump,
    sustained DPS, ADS time, per-category/faction parity and unlock side-grade checks;
  * explosives: grenade lethal / damage radius, launcher infantry splash;
  * vehicles: AT hits-to-kill per facing, tank-vs-tank shots per facing, time-to-kill;
  * classes: level-1 loadout coverage per faction;
  * modes: modelled round length;
  * progression: XP curve vs modelled XP/min -> hours per level and per unlock.

Usage:
    python3 scripts/balance_report.py              # full report to stdout (markdown)
    python3 scripts/balance_report.py --check      # only target violations, exit 1 if any
    python3 scripts/balance_report.py --section ttk|parity|explosive|vehicles|classes|modes|progression
    python3 scripts/balance_report.py --update-doc # rewrite the generated half of docs/BALANCE.md

The Luau CLI is found via $LUAU, PATH ("luau"), ./.tools/luau or /tmp/claude-0/tools/luau.
Damage math mirrors src/shared/Util/Ballistics.luau, CombatService and VehicleService.ApplyDamage;
keep the two in sync when the formulas change.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import re
import shutil
import subprocess
import sys
import tempfile
from collections import defaultdict

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CONFIG = os.path.join(ROOT, "src", "shared", "Config")
MODULES = ["Classes", "Factions", "Weapons", "Vehicles", "GameModes", "Progression"]

# ------------------------------------------------------------------------------------------------
# Loading configs through the Luau CLI
# ------------------------------------------------------------------------------------------------

PRELUDE = r"""
local function rgb(r, g, b) return { r = r, g = g, b = b } end
Color3 = { fromRGB = rgb, new = function(r, g, b) return rgb(r * 255, g * 255, b * 255) end }
Vector3 = { new = function(x, y, z) return { x = x, y = y, z = z } end }
Enum = setmetatable({}, { __index = function(_, k)
	return setmetatable({}, { __index = function(_, k2) return k .. "." .. k2 end })
end })
warn = function(...) end
local MODS = {}
local LOADERS = {}
local Parent = setmetatable({}, { __index = function(_, name)
	return { Name = name, IsA = function() return true end, __mod = name }
end })
Parent.FindFirstChild = function(_, name) return Parent[name] end
local function req(x)
	local name = type(x) == "table" and x.__mod or x
	if MODS[name] == nil then MODS[name] = LOADERS[name]() end
	return MODS[name]
end
"""

POSTLUDE = r"""
local function enc(v, depth)
	depth = depth or 0
	if depth > 12 then return "null" end
	local t = type(v)
	if t == "number" then
		if v ~= v or v == math.huge or v == -math.huge then return "null" end
		return string.format("%.17g", v)
	elseif t == "string" then
		return '"' .. v:gsub('[%c"\\]', function(c) return string.format("\\u%04x", string.byte(c)) end) .. '"'
	elseif t == "boolean" then
		return tostring(v)
	elseif t == "table" then
		local n = #v
		local isArr = n > 0 or next(v) == nil
		if isArr then
			for k in v do if type(k) ~= "number" then isArr = false break end end
		end
		local parts = {}
		if isArr then
			for i = 1, n do parts[i] = enc(v[i], depth + 1) end
			return "[" .. table.concat(parts, ",") .. "]"
		end
		for k, x in v do
			if type(x) ~= "function" then
				table.insert(parts, enc(tostring(k)) .. ":" .. enc(x, depth + 1))
			end
		end
		return "{" .. table.concat(parts, ",") .. "}"
	end
	return "null"
end
local W = req("Weapons")
local P = req("Progression")
local xp = {}
for l = 1, P.MAX_LEVEL do xp[l] = P.xpToNext(l) end
local out = {
	weapons = W.byId or {},
	weaponOrder = W.order or {},
	vehicles = req("Vehicles").byId,
	vehicleOrder = req("Vehicles").order,
	damage = req("Vehicles").DAMAGE,
	classes = req("Classes").byId,
	classOrder = req("Classes").order,
	factions = req("Factions").byId,
	factionOrder = req("Factions").order,
	modes = req("GameModes").byId,
	progression = { MAX_LEVEL = P.MAX_LEVEL, SCORE = P.SCORE, ROUND_XP = P.ROUND_XP, xpToNext = xp },
}
print(enc(out))
"""


def find_luau() -> str:
    for cand in (
        os.environ.get("LUAU"),
        shutil.which("luau"),
        os.path.join(ROOT, ".tools", "luau"),
        "/tmp/claude-0/tools/luau",
    ):
        if cand and os.path.isfile(cand) and os.access(cand, os.X_OK):
            return cand
    sys.exit("balance_report: Luau CLI not found (set $LUAU)")


def load_configs() -> dict:
    chunks = [PRELUDE]
    for name in MODULES:
        with open(os.path.join(CONFIG, name + ".luau"), encoding="utf-8") as f:
            src = f.read()
        # `export type` is only legal at chunk top level; local aliases are fine inside a function.
        src = re.sub(r"^export type\b", "type", src, flags=re.M)
        chunks.append(
            f'LOADERS["{name}"] = function()\n'
            f"local script = {{ Parent = Parent, Name = \"{name}\" }}\n"
            f"local require = req\n{src}\nend\n"
        )
    chunks.append(POSTLUDE)
    with tempfile.NamedTemporaryFile("w", suffix=".luau", delete=False) as tmp:
        tmp.write("\n".join(chunks))
        path = tmp.path if hasattr(tmp, "path") else tmp.name
    try:
        res = subprocess.run([find_luau(), path], capture_output=True, text=True, timeout=60)
    finally:
        os.unlink(path)
    if res.returncode != 0 or not res.stdout.strip():
        sys.exit("balance_report: luau failed:\n" + res.stderr[-2000:])
    # Old weapons modules may expose the registry differently; fall back to module fields.
    data = json.loads(res.stdout.strip().splitlines()[-1])
    return data


# ------------------------------------------------------------------------------------------------
# Model constants (mirrors Constants.luau / CombatService / VehicleService; see docs/BALANCE.md)
# ------------------------------------------------------------------------------------------------

HP = 100.0  # Constants.DEFAULT_HEALTH
RANGES = [10, 25, 50, 100, 200]
FIREARM_CATS = ["SMG", "AssaultRifle", "MachineGun", "SemiAuto", "BoltAction", "Sniper", "Shotgun", "Pistol"]
NON_LOADOUT = {"Melee"}
# Effective body silhouette (studs^2) used to estimate the fraction of shotgun pellets that land.
PELLET_TARGET_AREA = 7.0

# Category targets: (reference ranges, TTK band ms) - None band = checked by a custom rule.
TTK_BANDS = {
    "SMG": ([10, 25], (220, 330)),
    "AssaultRifle": ([25, 50], (250, 360)),
    "MachineGun": ([25, 50], (240, 380)),
    "SemiAuto": ([25, 50], (300, 450)),
    "Pistol": ([10], (400, 600)),
}
PARITY_RANGE = {
    "SMG": 25,
    "AssaultRifle": 50,
    "MachineGun": 50,
    "SemiAuto": 50,
    "BoltAction": 100,
    "Sniper": 200,
    "Shotgun": 15,
    "Pistol": 10,
}
PARITY_TOLERANCE = 0.10  # max(best L1 TTK) <= min(best L1 TTK) * 1.10

# Modelled player behaviour (per player, per minute of play) - documented in docs/BALANCE.md.
XP_MODEL = {
    "kills": 0.70,
    "headshotShare": 0.20,
    "assists": 0.35,
    "capturesPerRound": 3.0,
    "neutralizesPerRound": 1.5,
    "defends": 0.10,
    "classActionXP": 15.0,  # heals / resupplies / revives / repairs / spot assists
    "squadSpawns": 0.30,
    "vehicleKills": 0.02,
    "winRate": 0.5,
}
MODE_MODEL = {
    # deaths per player per minute, share of deaths revived (refunds the ticket)
    "deathsPerMin": 0.70,
    "reviveShare": 0.12,
    # Conquest: average point deficit of the losing side while it is behind, and the share of the
    # round that it is behind.
    "conquestDeficit": 1.0,
    "conquestBehindShare": 0.7,
    # Frontline: captures per minute (whole server) and the losing side's share of them.
    "frontlineCapturesPerMin": 0.30,
    "frontlineLoserCaptureShare": 0.35,
    # TDM: kills per player per minute (smaller maps, faster respawn).
    "tdmKillsPerMin": 1.0,
}


def falloff(w: dict, d: float) -> float:
    curve = w.get("damageFalloff") or []
    if not curve:
        return 1.0
    if d <= curve[0]["range"]:
        return curve[0]["multiplier"]
    for i in range(1, len(curve)):
        b = curve[i]
        if d <= b["range"]:
            a = curve[i - 1]
            span = b["range"] - a["range"]
            alpha = (d - a["range"]) / span if span > 0 else 1
            return a["multiplier"] + (b["multiplier"] - a["multiplier"]) * alpha
    return curve[-1]["multiplier"]


def zone_mult(w: dict, zone: str) -> float:
    if zone == "head":
        return w.get("headshotMultiplier", 1.5)
    if zone == "limb":
        return w.get("limbMultiplier", 0.9)
    return 1.0


def pellet_fraction(w: dict, d: float) -> float:
    if not w.get("pellets"):
        return 1.0
    spread = (w.get("pelletSpread") or 0) + (w.get("adsSpread") or 0)
    r = d * math.tan(math.radians(spread))
    area = math.pi * r * r
    return 1.0 if area <= PELLET_TARGET_AREA else PELLET_TARGET_AREA / area


def shot_damage(w: dict, d: float, zone: str) -> float:
    per = w["damage"] * falloff(w, d) * zone_mult(w, zone)
    if w.get("pellets"):
        return per * w["pellets"] * pellet_fraction(w, d)
    return per


def shots_to_kill(w: dict, d: float, zones) -> int | None:
    """zones: a zone name, or a list consumed in order (last one repeats)."""
    if isinstance(zones, str):
        zones = [zones]
    hp = HP
    for n in range(1, 16):  # >15 shots = "does not kill" for table purposes
        hp = max(0.0, hp - shot_damage(w, d, zones[min(n - 1, len(zones) - 1)]))
        if hp <= 0:
            return n
    return None


def interval(w: dict) -> float:
    return 60.0 / max(w["rpm"], 1)


def reload_time(w: dict, empty: bool = True) -> float:
    if w.get("reloadType") == "single":
        first = w.get("emptyReloadTime") or w["reloadTime"] if empty else w["reloadTime"]
        return first + w["reloadTime"] * (w["magazine"] - 1)
    if empty and w.get("emptyReloadTime"):
        return w["emptyReloadTime"]
    return w["reloadTime"]


def ttk_ms(w: dict, stk: int | None) -> float | None:
    if stk is None:
        return None
    gaps = stk - 1
    t = gaps * interval(w)
    mag = max(w["magazine"], 1)
    reloads = (stk - 1) // mag
    if reloads:
        per = w.get("emptyReloadTime") or w["reloadTime"]
        if w.get("reloadType") == "single":
            per = w.get("emptyReloadTime") or w["reloadTime"]
        t += reloads * max(per - interval(w), 0)
    return t * 1000


def firearm_stats(w: dict) -> dict:
    out = {"stk": {}, "ttk": {}, "dps": {}}
    for d in RANGES + [8, 15]:
        b, h, l = (shots_to_kill(w, d, z) for z in ("body", "head", "limb"))
        hb = shots_to_kill(w, d, ["head", "body"])
        out["stk"][d] = (b, h, l, hb)
        out["ttk"][d] = (ttk_ms(w, b), ttk_ms(w, h), ttk_ms(w, l), ttk_ms(w, hb))
        out["dps"][d] = shot_damage(w, d, "body") * w["rpm"] / 60
    body10 = shot_damage(w, 10, "body")
    out["magDump"] = body10 * w["magazine"]
    cycle = w["magazine"] * interval(w) + reload_time(w)
    out["sustained"] = out["magDump"] / cycle
    return out


def is_firearm(w: dict) -> bool:
    return (
        w.get("projectile") is None
        and (w.get("damage") or 0) > 0
        and w["category"] in FIREARM_CATS
    )


def fmt_ms(x) -> str:
    return "-" if x is None else f"{x:.0f}"


def fmt_n(x) -> str:
    return "-" if x is None else str(x)


# ------------------------------------------------------------------------------------------------
# Report sections. Each returns (markdown lines, violations).
# ------------------------------------------------------------------------------------------------


def factions_of(w: dict, data: dict) -> list:
    f = w.get("factions") or []
    return f if f else data["factionOrder"]


def short_factions(w: dict, data: dict) -> str:
    f = factions_of(w, data)
    return "ALL" if len(f) == len(data["factionOrder"]) else ",".join(f)


def firearms(data: dict) -> list:
    return [data["weapons"][i] for i in data["weaponOrder"] if is_firearm(data["weapons"][i])]


def section_ttk(data: dict):
    lines, bad = [], []
    lines.append("## Infantry firearms\n")
    lines.append(
        "STK = shots to kill (body/head/limb), TTK in ms (body; head in brackets) from first shot, "
        "all hits. DPS = body damage x RPM at 10 studs; Sust = mag dump / (mag time + empty reload).\n"
    )
    for cat in FIREARM_CATS + ["AntiTank"]:
        ws = [w for w in firearms(data) if w["category"] == cat] if cat != "AntiTank" else [
            data["weapons"][i]
            for i in data["weaponOrder"]
            if data["weapons"][i]["category"] == "AntiTank" and data["weapons"][i].get("projectile") is None
        ]
        if not ws:
            continue
        lines.append(f"### {cat}\n")
        hdr = "| Weapon | Fac | Lvl | Dmg | RPM | Mag | ADS s | " + " | ".join(
            f"{r} STK b/h/l | {r} TTK" for r in RANGES
        ) + " | DPS | Dump | Sust |"
        lines.append(hdr)
        lines.append("|" + "---|" * (hdr.count("|") - 1))
        for w in ws:
            s = firearm_stats(w)
            cells = []
            for r in RANGES:
                b, h, l, _ = s["stk"][r]
                tb, th, _, _ = s["ttk"][r]
                cells.append(f"{fmt_n(b)}/{fmt_n(h)}/{fmt_n(l)} | {fmt_ms(tb)} ({fmt_ms(th)})")
            dmg = f"{w['damage']}x{w['pellets']}" if w.get("pellets") else f"{w['damage']}"
            lines.append(
                f"| {w['id']} | {short_factions(w, data)} | {w['unlockLevel']} | {dmg} | {w['rpm']} | "
                f"{w['magazine']} | {w['adsTime']:.2f} | " + " | ".join(cells)
                + f" | {s['dps'][10]:.0f} | {s['magDump']:.0f} | {s['sustained']:.0f} |"
            )
            bad += check_weapon(w, s)
        lines.append("")
    return lines, bad


def check_weapon(w: dict, s: dict) -> list:
    bad = []
    cat, wid = w["category"], w["id"]
    if cat in TTK_BANDS:
        rngs, (lo, hi) = TTK_BANDS[cat]
        for r in rngs:
            t = s["ttk"][r][0]
            if t is None or t < lo or t > hi:
                bad.append(f"{wid}: {cat} body TTK {fmt_ms(t)} ms at {r} studs outside {lo}-{hi}")
        if cat == "SemiAuto":
            for r in rngs:
                b, _, _, hb = s["stk"][r]
                if b not in (2, 3) or hb is None or hb > 2:
                    bad.append(f"{wid}: semi-auto at {r} studs body STK {b}, head+body STK {hb} (want 2-3 / 2)")
        if cat == "MachineGun":
            if w["adsTime"] < 0.35:
                bad.append(f"{wid}: LMG ADS {w['adsTime']} < 0.35 s")
            if w["walkSpeedMult"] > 0.93:
                bad.append(f"{wid}: LMG walkSpeedMult {w['walkSpeedMult']} > 0.93 (heavy move penalty)")
    if cat == "BoltAction":
        for r in (10, 25, 50, 100):
            b, h, _, _ = s["stk"][r]
            if h != 1 or b != 2:
                bad.append(f"{wid}: bolt-action at {r} studs body {b} / head {h} (want 2 / 1)")
    if cat == "Sniper":
        for r in RANGES:
            b, h, _, _ = s["stk"][r]
            if b is not None and b < 2:
                bad.append(f"{wid}: scoped rifle one-shots the body at {r} studs")
        if "Bolt" in w["fireModes"] and s["stk"][100][1] != 1:
            bad.append(f"{wid}: scoped rifle does not one-shot a headshot at 100 studs")
    if cat == "Shotgun":
        if s["stk"][8][0] != 1:
            bad.append(f"{wid}: shotgun body STK {s['stk'][8][0]} at 8 studs (want 1)")
        if s["stk"][15][0] is None or s["stk"][15][0] > 2:
            bad.append(f"{wid}: shotgun body STK {s['stk'][15][0]} at 15 studs (want <=2)")
        if s["stk"][15][0] == 1:
            bad.append(f"{wid}: shotgun still one-shots at 15 studs")
    return bad


def parity_ttk(w: dict, r: int) -> float | None:
    s = firearm_stats(w)
    if w["category"] == "Shotgun":
        # Close range: one-shot everywhere inside 8 studs, so compare the 15-stud follow-up.
        return s["ttk"][15][0]
    return s["ttk"][r][0]


def section_parity(data: dict):
    lines, bad = ["## Faction parity (best level-1 option per category)\n"], []
    facs = data["factionOrder"]
    lines.append("| Category | @studs | " + " | ".join(facs) + " | spread |")
    lines.append("|" + "---|" * (len(facs) + 3))
    for cat in FIREARM_CATS:
        r = PARITY_RANGE[cat]
        best = {}
        for f in facs:
            opts = [
                w for w in firearms(data)
                if w["category"] == cat and w["unlockLevel"] <= 1 and f in factions_of(w, data)
            ]
            scored = [(parity_ttk(w, r), w["id"]) for w in opts]
            scored = [x for x in scored if x[0] is not None]
            if scored:
                best[f] = min(scored)
        vals = [v[0] for v in best.values()]
        spread = (max(vals) / min(vals) - 1) if vals and min(vals) > 0 else 0
        cells = [f"{best[f][1]} {best[f][0]:.0f}" if f in best else "**none**" for f in facs]
        lines.append(f"| {cat} | {r} | " + " | ".join(cells) + f" | {spread * 100:.0f}% |")
        missing = [f for f in facs if f not in best]
        if missing:
            bad.append(f"parity {cat}: no level-1 option for {missing}")
        if spread > PARITY_TOLERANCE + 1e-9:
            bad.append(f"parity {cat}: best level-1 TTK spread {spread * 100:.0f}% > {PARITY_TOLERANCE * 100:.0f}%")
    lines.append("")

    # Unlocks must be side-grades: not >10% faster TTK at every range than the level-1 option they
    # compete with (same faction, same category).
    lines.append("### Unlock side-grade check\n")
    lines.append("| Unlock | Lvl | vs (L1) | TTK ratio @10/25/50/100/200 | ADS | Mag | Verdict |")
    lines.append("|---|---|---|---|---|---|---|")
    for u in firearms(data):
        if u["unlockLevel"] <= 1:
            continue
        for f in factions_of(u, data):
            base = [
                w for w in firearms(data)
                if w["category"] == u["category"] and w["unlockLevel"] <= 1 and f in factions_of(w, data)
            ]
            if not base:
                continue
            b = min(base, key=lambda w: parity_ttk(w, PARITY_RANGE[u["category"]]) or 1e9)
            ratios = []
            for rr in RANGES:
                tu, tb = firearm_stats(u)["ttk"][rr][0], firearm_stats(b)["ttk"][rr][0]
                if tu is None or tb is None or tb == 0:
                    ratios.append(None if tu is None or tb is None else (1.0 if tu == 0 else 2.0))
                else:
                    ratios.append(tu / tb)
            valid = [x for x in ratios if x is not None]
            # Head-shot TTK must not be worse anywhere either, otherwise the unlock trades
            # precision reward for body TTK (e.g. semi-auto vs bolt scoped rifles).
            head_worse = any(
                (firearm_stats(u)["ttk"][rr][1] or 0) > (firearm_stats(b)["ttk"][rr][1] or 0) for rr in RANGES
            )
            dominant = bool(valid) and all(x <= 0.9 for x in valid) and not head_worse
            handling_ok = u["adsTime"] <= b["adsTime"] and u["magazine"] >= b["magazine"]
            if dominant:
                verdict = "**UPGRADE**"
                bad.append(f"unlock {u['id']} ({f}) is >10% faster than {b['id']} at every range")
            elif valid and all(x <= 1.0 for x in valid) and handling_ok and not head_worse:
                verdict = "upgrade (<10%)"
            else:
                verdict = "side-grade"
            rs = "/".join("-" if x is None else f"{x:.2f}" for x in ratios)
            lines.append(
                f"| {u['id']} | {u['unlockLevel']} | {b['id']} ({f}) | {rs} | "
                f"{u['adsTime']:.2f} vs {b['adsTime']:.2f} | {u['magazine']} vs {b['magazine']} | {verdict} |"
            )
            break  # one representative faction per unlock keeps the table readable
    lines.append("")
    return lines, bad


def explosion_damage(max_d: float, d: float, radius: float) -> float:
    if radius <= 0 or d >= radius:
        return 0.0
    core = radius * 0.2
    if d <= core:
        return max_d
    t = 1 - (d - core) / (radius - core)
    return max_d * (t * (0.35 + 0.65 * t))


def radius_for(max_d: float, radius: float, dmg: float) -> float:
    """Largest distance at which an explosion still deals >= dmg."""
    lo, hi = 0.0, radius
    if explosion_damage(max_d, 0, radius) < dmg:
        return 0.0
    for _ in range(60):
        mid = (lo + hi) / 2
        if explosion_damage(max_d, mid, radius) >= dmg:
            lo = mid
        else:
            hi = mid
    return lo


def section_explosive(data: dict):
    lines, bad = ["## Explosives vs infantry\n"], []
    lines.append(
        "Distances are to the nearest body-part box (CombatService uses distanceToBox), i.e. roughly "
        "1 stud less than to the torso centre. Lethal = >=100 dmg, wound = >=25 dmg.\n"
    )
    lines.append("| Item | Cat | Fac | Lvl | Radius | MaxDmg | Lethal r | 50 dmg r | 25 dmg r | Carried |")
    lines.append("|---|---|---|---|---|---|---|---|---|---|")
    for i in data["weaponOrder"]:
        w = data["weapons"][i]
        if not w.get("projectile") or not w.get("blastRadius"):
            continue
        R, D = w["blastRadius"], w.get("blastDamage") or 0
        lr = radius_for(D, R, 100)
        lines.append(
            f"| {i} | {w['category']} | {short_factions(w, data)} | {w['unlockLevel']} | {R} | {D} | "
            f"{lr:.1f} | {radius_for(D, R, 50):.1f} | {radius_for(D, R, 25):.1f} | {w['magazine']} |"
        )
        if w["category"] == "Grenade" and w.get("projectile") == "frag":
            if not (3.5 <= lr <= 5.5) or not (10 <= R <= 14):
                bad.append(f"{i}: frag lethal radius {lr:.1f} / damage radius {R} (want ~4-5 / ~12)")
        if w["category"] == "Grenade" and w.get("projectile") == "impact" and lr > 5.5:
            bad.append(f"{i}: impact grenade lethal radius {lr:.1f} > 5.5")
    lines.append("")
    return lines, bad


# ------------------------------------------------------------------------------------------------
# Vehicles
# ------------------------------------------------------------------------------------------------

FACINGS = ["front", "side", "rear"]
# Typical impact obliquity per facing for tank duels: frontal shots usually land ~25 deg off the
# normal (angleFactor = 1/cos^0.6), side/rear shots on a flanking approach are near-perpendicular.
FACING_OBLIQUITY = {"front": 25, "side": 10, "rear": 0}


def vlist(data: dict, cls=None) -> list:
    return [data["vehicles"][i] for i in data["vehicleOrder"] if cls is None or data["vehicles"][i]["class"] in cls]


def main_gun(v: dict):
    w = v.get("weapons")
    return w.get("main") if isinstance(w, dict) else None


def explosive_hits(data: dict, v: dict, amount: float, facing: str) -> int:
    dmg = amount * data["damage"]["EXPLOSIVE_FACING_MULT"][facing]
    return math.ceil(v["maxHealth"] / dmg - 1e-9) if dmg > 0 else 999


def shell_per_hit(data: dict, shell: dict, target: dict, facing: str) -> tuple:
    D = data["damage"]
    armor = target["armor"][facing]
    cos = math.cos(math.radians(FACING_OBLIQUITY[facing]))
    effective = armor / (max(cos, 0.35) ** 0.6)
    if shell["penetration"] >= effective:
        dmg, res = shell["damage"] * D["PEN_FACING_MULT"][facing], "P"
    else:
        dmg, res = shell["damage"] * D["NONPEN_FRACTION"][shell["kind"]], "n"
    # HE splash also hits the struck vehicle (CombatService.Explode, ~0.5 stud from the hull).
    if shell.get("splashVehicle"):
        r = max(shell.get("splashRadius") or 1, 1)
        dmg += shell["splashVehicle"] * max(0.0, 1 - 0.5 / r) ** 1.5 * D["EXPLOSIVE_FACING_MULT"][facing]
    return dmg, res


def shell_hits(data: dict, shell: dict, target: dict, facing: str) -> tuple:
    dmg, res = shell_per_hit(data, shell, target, facing)
    return (math.ceil(target["maxHealth"] / dmg - 1e-9) if dmg > 0 else 999), res


def gun_time(gun: dict, hits: int) -> float:
    mag = gun.get("magazine") or 1
    if mag > 1:
        inter = gun.get("fireInterval") or 0.25
        full_mags = (hits - 1) // mag
        return full_mags * gun["reload"] + (hits - 1 - full_mags) * inter
    return (hits - 1) * gun["reload"]


def section_vehicles(data: dict):
    lines, bad = ["## Vehicles\n"], []
    at = [
        data["weapons"][i]
        for i in data["weaponOrder"]
        if (data["weapons"][i].get("vehicleDamage") or 0) > 0
        and data["weapons"][i]["category"] in ("AntiTank", "Explosive")
        and data["weapons"][i].get("projectile")
    ]
    armored = vlist(data, ("Tank", "Light"))
    lines.append("### Infantry anti-tank: hits to kill (front/side/rear)\n")
    lines.append(
        "Direct hits; damage = vehicleDamage x EXPLOSIVE_FACING_MULT (front "
        f"{data['damage']['EXPLOSIVE_FACING_MULT']['front']}, side {data['damage']['EXPLOSIVE_FACING_MULT']['side']}, "
        f"rear {data['damage']['EXPLOSIVE_FACING_MULT']['rear']}).\n"
    )
    hdr = "| Vehicle | Class | HP | " + " | ".join(f"{w['id']} ({w['vehicleDamage']})" for w in at) + " |"
    lines.append(hdr)
    lines.append("|" + "---|" * (len(at) + 3))
    for v in armored:
        cells = []
        for w in at:
            hs = [explosive_hits(data, v, w["vehicleDamage"], f) for f in FACINGS]
            cells.append("/".join(map(str, hs)))
        lines.append(f"| {v['id']} | {v['class']} | {v['maxHealth']} | " + " | ".join(cells) + " |")
    lines.append("")
    # Targets on medium tanks (level-1 'Tank' class with front armor < 110) and light vehicles.
    mediums = [v for v in vlist(data, ("Tank",)) if v["armor"]["front"] < 110]
    for w in at:
        if w["category"] != "AntiTank":
            continue
        is_faust = w["id"] in ("Panzerfaust", "LungeMine")
        for v in mediums:
            f, s, r = (explosive_hits(data, v, w["vehicleDamage"], x) for x in FACINGS)
            ok = r <= 3 and s <= 4 and (5 if is_faust else 6) <= f <= 8 and s >= (3 if is_faust else 4) and r >= 2
            if not ok:
                bad.append(f"AT {w['id']} vs medium {v['id']}: {f}/{s}/{r} hits (want 6-8/4/3)")
        for v in vlist(data, ("Light",)):
            s = explosive_hits(data, v, w["vehicleDamage"], "side")
            if s > 2:
                bad.append(f"AT {w['id']} vs light {v['id']}: {s} side hits (want 2)")

    # Tank vs tank (AP, default ammo)
    tanks = vlist(data, ("Tank", "Light", "AT"))
    shooters = [v for v in tanks if main_gun(v)]
    targets = vlist(data, ("Tank", "Light"))
    lines.append("### Tank guns: AP shots to kill (front/side/rear) and time to kill (s, side)\n")
    lines.append(
        f"Front shots assume {FACING_OBLIQUITY['front']} deg obliquity, side {FACING_OBLIQUITY['side']}, rear 0. "
        "`n` marks a non-penetration (10 % damage).\n"
    )
    lines.append("| Shooter \\ Target | pen/dmg/rl | " + " | ".join(t["id"] for t in targets) + " |")
    lines.append("|" + "---|" * (len(targets) + 2))
    for sv in shooters:
        g = main_gun(sv)
        ap = g["ammo"][0]
        cells = []
        for t in targets:
            parts = []
            for f in FACINGS:
                n, res = shell_hits(data, ap, t, f)
                parts.append(f"{n}{'n' if res == 'n' else ''}")
            side_n = shell_hits(data, ap, t, "side")[0]
            cells.append("/".join(parts) + f" ({gun_time(g, side_n):.0f}s)")
        lines.append(f"| {sv['id']} | {ap['penetration']}/{ap['damage']}/{g['reload']} | " + " | ".join(cells) + " |")
    lines.append("")

    # Targets: level-1 medium vs level-1 medium.
    l1_mediums = [v for v in mediums if v["unlockLevel"] <= 1]
    for a in l1_mediums:
        ap = main_gun(a)["ammo"][0]
        for b in l1_mediums:
            f = shell_hits(data, ap, b, "front")[0]
            s = shell_hits(data, ap, b, "side")[0]
            r = shell_hits(data, ap, b, "rear")[0]
            if not (3 <= f <= 5 and 2 <= s <= 3 and 1 <= r <= 2):
                bad.append(f"tank {a['id']} vs {b['id']}: {f}/{s}/{r} AP shots (want 3-5/2-3/1-2)")
    heavies = [v for v in vlist(data, ("Tank",)) if v["armor"]["front"] >= 110]
    for h in heavies:
        for a in l1_mediums:
            ap = main_gun(a)["ammo"][0]
            n, res = shell_hits(data, ap, h, "front")
            if res == "P" and h["unlockLevel"] > 1:
                bad.append(f"heavy {h['id']} front is penetrated by level-1 {a['id']} (should need flanking)")
            ns, ress = shell_hits(data, ap, h, "side")
            if ress != "P":
                bad.append(f"heavy {h['id']} side not penetrable by {a['id']} (flanking must work)")

    # Infantry vs tank shells
    lines.append("### Tank shells vs infantry\n")
    lines.append("| Vehicle | Shell | Direct | Splash r | Splash max | Lethal r |")
    lines.append("|---|---|---|---|---|---|")
    seen = set()
    for v in shooters:
        for sh in main_gun(v)["ammo"]:
            key = (sh["kind"], sh["directDamage"], sh["splashRadius"], sh["splashDamage"])
            if key in seen:
                continue
            seen.add(key)
            lr = radius_for(sh["splashDamage"], sh["splashRadius"], 100)
            lines.append(
                f"| {v['id']} | {sh['kind']} | {sh['directDamage']} | {sh['splashRadius']:.1f} | "
                f"{sh['splashDamage']:.0f} | {lr:.1f} |"
            )
            if sh["directDamage"] < 100 and (main_gun(v).get("magazine") or 1) <= 1:
                bad.append(f"{v['id']} {sh['kind']} direct hit does not one-shot infantry")
    lines.append("")
    return lines, bad


# ------------------------------------------------------------------------------------------------
# Classes, modes, progression
# ------------------------------------------------------------------------------------------------


def available(data: dict, class_id: str, slot: str, faction: str, level: int | None) -> list:
    cats = data["classes"][class_id]["slots"][slot]
    out = []
    for i in data["weaponOrder"]:
        w = data["weapons"][i]
        if w["category"] in cats and faction in factions_of(w, data) and (level is None or w["unlockLevel"] <= level):
            out.append(w)
    return out


def section_classes(data: dict):
    lines, bad = ["## Class loadout coverage (level 1)\n"], []
    facs = data["factionOrder"]
    lines.append("Number of level-1 choices per slot (primary/secondary/gadget1/gadget2).\n")
    lines.append("| Class | " + " | ".join(facs) + " |")
    lines.append("|" + "---|" * (len(facs) + 1))
    for c in data["classOrder"]:
        cells = []
        for f in facs:
            counts = [len(available(data, c, s, f, 1)) for s in ("primary", "secondary", "gadget1", "gadget2")]
            cells.append("/".join(map(str, counts)))
            for s, n in zip(("primary", "secondary", "gadget1", "gadget2"), counts):
                if n == 0:
                    bad.append(f"class {c} ({f}) has no level-1 {s}")
        lines.append(f"| {c} | " + " | ".join(cells) + " |")
    lines.append("")
    return lines, bad


def mode_lengths(data: dict) -> dict:
    m, M = MODE_MODEL, data["modes"]
    res = {}
    c = M.get("Conquest")
    if c:
        per_side = 16
        deaths = per_side * m["deathsPerMin"] * (1 - m["reviveShare"])
        bleed = (c.get("ticketBleedPerSecond") or 0) * 60 * m["conquestDeficit"] * m["conquestBehindShare"]
        res["Conquest"] = (min(c["tickets"] / (deaths + bleed), c["timeLimit"] / 60), deaths, bleed)
    f = M.get("Frontline")
    if f:
        per_side = 16
        deaths = per_side * m["deathsPerMin"] * (1 - m["reviveShare"]) * (8 / max(f["respawnTime"], 1)) ** 0.25
        gain = m["frontlineCapturesPerMin"] * m["frontlineLoserCaptureShare"] * (f.get("ticketsOnCapture") or 0)
        net = max(deaths - gain, 0.01)
        res["Frontline"] = (min(f["tickets"] / net, f["timeLimit"] / 60), deaths, gain)
    t = M.get("TDM")
    if t:
        rate = 12 * m["tdmKillsPerMin"]
        res["TDM"] = (min(t["scoreLimit"] / rate, t["timeLimit"] / 60), rate, 0)
    return res


MODE_TARGETS = {"Conquest": (15, 20), "Frontline": (20, 25), "TDM": (8, 11)}


def section_modes(data: dict):
    lines, bad = ["## Game modes (modelled round length)\n"], []
    m = MODE_MODEL
    lines.append(
        f"Model: {m['deathsPerMin']} deaths/player/min, {m['reviveShare'] * 100:.0f}% revived; Conquest loser "
        f"behind by {m['conquestDeficit']} point(s) {m['conquestBehindShare'] * 100:.0f}% of the time; Frontline "
        f"{m['frontlineCapturesPerMin']} captures/min, loser makes {m['frontlineLoserCaptureShare'] * 100:.0f}%; "
        f"TDM {m['tdmKillsPerMin']} kills/player/min, 12v12. Conquest/Frontline 16v16.\n"
    )
    lines.append("| Mode | Tickets / limit | Time cap | Drain (tickets/min) | Offset | Modelled length (min) | Target |")
    lines.append("|---|---|---|---|---|---|---|")
    for k, (mins, a, b) in mode_lengths(data).items():
        d = data["modes"][k]
        lo, hi = MODE_TARGETS[k]
        cap = d["timeLimit"] / 60
        lim = d.get("tickets") or d.get("scoreLimit")
        lines.append(f"| {k} | {lim} | {cap:.0f} | {a:.1f} | {b:.1f} | {mins:.1f} | {lo}-{hi} |")
        if not (lo <= mins <= hi):
            bad.append(f"mode {k}: modelled length {mins:.1f} min outside {lo}-{hi}")
    lines.append("")
    return lines, bad


def xp_per_min(data: dict) -> float:
    S, R, m = data["progression"]["SCORE"], data["progression"]["ROUND_XP"], XP_MODEL
    rnd = mode_lengths(data).get("Conquest", (18, 0, 0))[0] + 0.6  # + intermission/round-end screens
    xp = (
        m["kills"] * S["Kill"]
        + m["kills"] * m["headshotShare"] * S["Headshot"]
        + m["assists"] * S["Assist"]
        + (m["capturesPerRound"] * S["Capture"] + m["neutralizesPerRound"] * S["Neutralize"]) / rnd
        + m["defends"] * S["Defend"]
        + m["classActionXP"]
        + m["squadSpawns"] * S["SquadSpawn"]
        + m["vehicleKills"] * S["VehicleDestroyed"]
        + (m["winRate"] * R["Win"] + (1 - m["winRate"]) * R["Loss"]) / rnd
    )
    return xp


def hours_to(data: dict, level: int, rate: float) -> float:
    xp = data["progression"]["xpToNext"]
    total = sum(xp[i] for i in range(0, max(level - 1, 0)))  # xpToNext[1..level-1] (0-based list)
    return total / rate / 60


def section_progression(data: dict):
    lines, bad = ["## Progression pacing\n"], []
    rate = xp_per_min(data)
    lines.append(f"Modelled XP/min (Conquest, average player, no boosts): **{rate:.0f}** ({rate * 60:.0f}/h).\n")
    lines.append("| Level | XP to next | Total XP | Hours |")
    lines.append("|---|---|---|---|")
    xp = data["progression"]["xpToNext"]
    for lvl in (2, 3, 4, 5, 6, 8, 10, 12, 14, 16, 18, 20, 22, 24, 30, 40, 50):
        total = sum(xp[i] for i in range(0, lvl - 1))
        lines.append(f"| {lvl} | {xp[lvl - 1]} | {total} | {hours_to(data, lvl, rate):.2f} |")
    lines.append("")
    h10, h30 = hours_to(data, 10, rate), hours_to(data, 30, rate)
    if not (2 <= h10 <= 3):
        bad.append(f"progression: level 10 after {h10:.2f} h (want 2-3)")
    if not (25 <= h30 <= 35):
        bad.append(f"progression: level 30 after {h30:.1f} h (want 25-35)")

    facs = data["factionOrder"]
    lines.append("### First unlock per class (minutes of play): primary weapon / any slot\n")
    lines.append("| Class | " + " | ".join(facs) + " |")
    lines.append("|" + "---|" * (len(facs) + 1))
    for c in data["classOrder"]:
        cells = []
        for f in facs:
            lv_primary = min(
                [w["unlockLevel"] for w in available(data, c, "primary", f, None) if w["unlockLevel"] > 1] or [99]
            )
            lv_any = min(
                [
                    w["unlockLevel"]
                    for s in ("primary", "secondary", "gadget1", "gadget2")
                    for w in available(data, c, s, f, None)
                    if w["unlockLevel"] > 1
                ]
                or [99]
            )
            mp = hours_to(data, lv_primary, rate) * 60 if lv_primary < 99 else None
            ma = hours_to(data, lv_any, rate) * 60 if lv_any < 99 else None
            cells.append(f"L{lv_primary} {fmt_ms(mp)} / L{lv_any} {fmt_ms(ma)}")
            if ma is None or ma > 60:
                bad.append(f"class {c} ({f}): first unlock after {fmt_ms(ma)} min (want <=60)")
            elif ma < 30:
                bad.append(f"class {c} ({f}): first unlock after only {ma:.0f} min (want >=30)")
        lines.append(f"| {c} | " + " | ".join(cells) + " |")
    lines.append("")

    lines.append("### Unlock track (hours of play to reach each unlock level)\n")
    by_level = defaultdict(list)
    for i in data["weaponOrder"]:
        w = data["weapons"][i]
        if w["unlockLevel"] > 1:
            by_level[w["unlockLevel"]].append(f"{i} ({short_factions(w, data)})")
    for i in data["vehicleOrder"]:
        v = data["vehicles"][i]
        if v["unlockLevel"] > 1:
            by_level[v["unlockLevel"]].append(f"*{i}* ({','.join(v['factions'])})")
    lines.append("| Level | Hours | Unlocks (*vehicles* in italics) |")
    lines.append("|---|---|---|")
    for lvl in sorted(by_level):
        lines.append(f"| {lvl} | {hours_to(data, lvl, rate):.1f} | {', '.join(by_level[lvl])} |")
    lines.append("")
    return lines, bad


DOC = os.path.join(ROOT, "docs", "BALANCE.md")
DOC_MARKER = "<!-- GENERATED BY scripts/balance_report.py --update-doc: do not edit below -->"

SECTIONS = {
    "ttk": section_ttk,
    "parity": section_parity,
    "explosive": section_explosive,
    "vehicles": section_vehicles,
    "classes": section_classes,
    "modes": section_modes,
    "progression": section_progression,
}


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--check", action="store_true", help="print only target violations; exit 1 if any")
    ap.add_argument("--section", choices=sorted(SECTIONS), action="append")
    ap.add_argument("--update-doc", action="store_true", help=f"rewrite the generated part of {DOC}")
    args = ap.parse_args()
    data = load_configs()
    names = args.section or list(SECTIONS)
    out, bad = [], []
    for n in names:
        lines, b = SECTIONS[n](data)
        out += lines
        bad += b
    if args.check:
        for b in bad:
            print("-", b)
        print(f"{len(bad)} target violation(s)")
        return 1 if bad else 0
    out.append("## Target violations\n")
    out.append("\n".join(f"- {b}" for b in bad) if bad else "None - every automated target is met.")
    text = "\n".join(out) + "\n"
    if args.update_doc:
        with open(DOC, encoding="utf-8") as f:
            doc = f.read()
        head = doc.split(DOC_MARKER)[0]
        with open(DOC, "w", encoding="utf-8") as f:
            f.write(head + DOC_MARKER + "\n\n" + text)
        print(f"updated {os.path.relpath(DOC, ROOT)} ({len(bad)} violation(s))")
        return 0
    print(text)
    return 0


if __name__ == "__main__":
    sys.exit(main())
