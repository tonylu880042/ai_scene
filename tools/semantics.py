#!/usr/bin/env python3
"""Near-route spatial semantics (semantics/semantics.json): validate and query. Engine-independent, stdlib only.

  python3 tools/semantics.py validate <package_dir>
  python3 tools/semantics.py describe <package_dir> <s> [<s> ...]     what is around the route at distance s

Format: schemas/semantics.schema.json, docs/SEMANTICS.md. Every zone is a box in route coordinates:
[from_s, to_s] x lateral_offset_m [min, max] (signed from the centreline, + left), on one side of the route.
Vegetation / building stages place objects only inside zones they get from zones_at() / zones_in().
"""
import bisect
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import route_model as rm  # noqa: E402

VERSION = "0.1"
SCHEMA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schemas", "semantics.schema.json")
# the route itself and what carries it: the only types allowed inside the playable band (route widths)
SURFACE = {"road", "trail", "sidewalk", "bridge", "tunnel"}
# ground cover: at most one of these at any (s, lateral) spot
EXCLUSIVE = {"road", "trail", "sidewalk", "grass", "water", "open_space"}
# occupied space that must not share ground with these
CONFLICTS = {("forest", t) for t in ("water", "road", "trail", "sidewalk")} | \
            {("building_zone", t) for t in ("water", "forest", "road", "trail", "sidewalk")}
TOL = 0.01


def _overlap(a, b):
    return (min(a["to_s"], b["to_s"]) - max(a["from_s"], b["from_s"]) > TOL and
            min(a["lateral_offset_m"][1], b["lateral_offset_m"][1]) - max(a["lateral_offset_m"][0], b["lateral_offset_m"][0]) > TOL)


def validate(sem, route):
    """List of problems (empty = valid)."""
    with open(SCHEMA_FILE) as f:
        errs = rm.check_schema(sem, json.load(f))
    if errs:
        return errs
    if sem["route_id"] != route["route_id"]:
        errs.append(f"route_id {sem['route_id']!r} != route.json {route['route_id']!r}")
    smp = route["samples"]
    s, wl, wr = smp["s"], smp["width_left_m"], smp["width_right_m"]
    total, ext = route["total_length_m"], sem["extent_m"]
    zones = sem["zones"]
    ids = [z["id"] for z in zones]
    if len(set(ids)) != len(ids):
        errs.append("zone ids not unique")
    for z in zones:
        zid, t, side = z["id"], z["semantic_type"], z["side"]
        a, b = z["lateral_offset_m"][:2]
        if len(z["lateral_offset_m"]) != 2 or a >= b:
            errs.append(f"{zid}: lateral_offset_m must be [min, max] with min < max")
            continue
        if not 0.0 <= z["from_s"] < z["to_s"] <= total + 1e-6:
            errs.append(f"{zid}: need 0 <= from_s < to_s <= total_length_m ({z['from_s']}..{z['to_s']})")
        if max(abs(a), abs(b)) > ext + 1e-6:
            errs.append(f"{zid}: lateral offset beyond extent_m {ext}")
        if side == "left" and a < -TOL or side == "right" and b > TOL:
            errs.append(f"{zid}: side {side} but lateral_offset_m {[a, b]} (+ is left)")
        if side == "both" and not (t in SURFACE and a < 0.0 < b):
            errs.append(f"{zid}: side both is only for {sorted(SURFACE)} spanning the centreline")
        if z["confidence"] > 1.0:
            errs.append(f"{zid}: confidence must be in [0, 1]")
        v = z.get("vertical_offset_m")
        if v is not None and (len(v) != 2 or v[0] > v[1]):
            errs.append(f"{zid}: vertical_offset_m must be [min, max] or null")
        if t not in SURFACE:  # nothing but route surfaces inside the playable band
            i0, i1 = bisect.bisect_left(s, z["from_s"]), bisect.bisect_right(s, z["to_s"])
            bad = [s[i] for i in range(i0, i1) if (a < wl[i] - TOL if side == "left" else b > -wr[i] + TOL)]
            if bad:
                errs.append(f"{zid}: {t} intrudes into the playable band at s={bad[0]} ({len(bad)} samples)")
    # the route surface itself is described everywhere
    cover = sorted((z["from_s"], z["to_s"]) for z in zones
                   if z["semantic_type"] in SURFACE and z["lateral_offset_m"][0] <= 0.0 <= z["lateral_offset_m"][1])
    reach, gaps = 0.0, []
    for a, b in cover:
        if a > reach + TOL:
            gaps.append((reach, a))
        reach = max(reach, b)
    if reach < total - TOL:
        gaps.append((reach, total))
    if gaps:
        errs.append(f"route surface not described over s={[(round(a, 1), round(b, 1)) for a, b in gaps[:3]]}")
    # one ground cover per spot; occupied space off water / road surfaces
    for i, za in enumerate(zones):
        for zb in zones[i + 1:]:
            ta, tb = za["semantic_type"], zb["semantic_type"]
            clash = (ta in EXCLUSIVE and tb in EXCLUSIVE) or (ta, tb) in CONFLICTS or (tb, ta) in CONFLICTS
            if clash and _overlap(za, zb):
                errs.append(f"{za['id']} ({ta}) overlaps {zb['id']} ({tb})")
    return errs


# ------------------------------------------------------------------ queries (for later stages)
def zones_at(sem, s, side=None, types=None):
    """Zones covering distance s, nearest to the route first."""
    out = [z for z in sem["zones"] if z["from_s"] <= s <= z["to_s"]
           and (side is None or z["side"] == side) and (types is None or z["semantic_type"] in types)]
    return sorted(out, key=lambda z: min(abs(v) for v in z["lateral_offset_m"]) if z["side"] != "both" else 0.0)


def zones_in(sem, from_s, to_s, types):
    """Zones of the given types that overlap [from_s, to_s] (e.g. a vegetation chunk asking where it may plant)."""
    return [z for z in sem["zones"] if z["semantic_type"] in types and z["from_s"] < to_s and z["to_s"] > from_s]


def _label(z):
    a = z.get("attributes", {})
    words = [a[k] for k in ("density", "kind") if isinstance(a.get(k), str)]
    return " ".join(words + [z["semantic_type"].replace("_", " ")])


def _continued(sem, z, key, s):
    """True if a zone of the same type and side meets z at s (a zone split into pieces, not a real start / end)."""
    return any(o is not z and o["semantic_type"] == z["semantic_type"] and o["side"] == z["side"]
               and abs(o[key] - s) < TOL for o in sem["zones"])


def describe(sem, route, s):
    """Plain sentences for what is around the route at s."""
    p = rm.sample(route, s)
    surface = [z for z in zones_at(sem, s, types=SURFACE) if z["lateral_offset_m"][0] <= 0 <= z["lateral_offset_m"][1]]
    what = surface[0]["semantic_type"] if surface else "route"
    lines = []
    for z in zones_at(sem, s):
        a, b = z["lateral_offset_m"]
        if z["side"] == "both" or (z["semantic_type"] in SURFACE and a <= 0 <= b):
            lines.append(f"At s={s:.0f} m the route is on a {_label(z)} ({-a:.1f} m right to {b:.1f} m left of the centreline).")
            continue
        near, far = (a, b) if z["side"] == "left" else (-b, -a)
        edge = near - (p["width_left_m"] if z["side"] == "left" else p["width_right_m"])
        verb = "begins" if abs(z["from_s"] - s) < 1.0 and not _continued(sem, z, "to_s", z["from_s"]) else \
            ("ends" if abs(z["to_s"] - s) < 1.0 and not _continued(sem, z, "from_s", z["to_s"]) else "runs")
        lines.append(f"At s={s:.0f} m, {_label(z)} {verb} {near:.1f}-{far:.1f} m {z['side']} of the centreline "
                     f"({edge:.1f} m beyond the {what} edge; confidence {z['confidence']:.2f}).")
    return lines


def _load_pkg(pkg):
    with open(os.path.join(pkg, "route", "route.json")) as f:
        route = json.load(f)
    with open(os.path.join(pkg, "semantics", "semantics.json")) as f:
        sem = json.load(f)
    return route, sem


def main(argv):
    if len(argv) == 2 and argv[0] == "validate":
        route, sem = _load_pkg(argv[1])
        errs = validate(sem, route)
        for e in errs:
            print("  FAIL", e)
        counts = {}
        for z in sem["zones"]:
            counts[z["semantic_type"]] = counts.get(z["semantic_type"], 0) + 1
        print(f"{argv[1]}: {len(sem['zones'])} zones {dict(sorted(counts.items()))} -> {'VALID' if not errs else 'INVALID'}")
        return 1 if errs else 0
    if len(argv) >= 3 and argv[0] == "describe":
        route, sem = _load_pkg(argv[1])
        for v in argv[2:]:
            print("\n".join(describe(sem, route, float(v))))
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
