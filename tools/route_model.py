#!/usr/bin/env python3
"""Canonical route model (route.json): derive, validate, convert. Engine-independent, stdlib only.

  python3 tools/route_model.py finalize <raw_or_route.json> [out.json]   derive grade/heading/curvature/y + markers, validate
  python3 tools/route_model.py legacy <old route.json> <out.json> --route-id=ID [--exaggeration=1.5] [--surface=asphalt]
  python3 tools/route_model.py validate <route.json>

Schema: schemas/route.schema.json, docs/ROUTE_SCHEMA.md. Derived fields are a pure function of s, x, z, elevation_m
(the formulas in derive()), so any producer can be checked by recomputing them.
"""
import bisect
import json
import math
import os
import sys

VERSION = "0.1"
SCHEMA_FILE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "schemas", "route.schema.json")
MAX_GRADE_PERCENT = 40.0   # steeper than any rideable road: treated as a data error
MAX_WIDTH_M = 100.0
TOL = {"grade": 0.02, "heading": 0.02, "curvature": 1e-4, "y": 1e-3, "marker": 0.01}
ROUND = {"s": 4, "x": 4, "y": 4, "z": 4, "elevation_m": 4, "grade_percent": 3, "heading_deg": 3, "curvature": 6,
         "width_left_m": 3, "width_right_m": 3}
FIELDS = ["s", "x", "y", "z", "elevation_m", "grade_percent", "heading_deg", "curvature", "width_left_m",
          "width_right_m", "surface_type"]


# ------------------------------------------------------------------ schema (the JSON Schema subset the file uses)
def check_schema(obj, schema, root=None, path="$"):
    root = root or schema
    if "$ref" in schema:
        node = root
        for part in schema["$ref"].lstrip("#/").split("/"):
            node = node[part]
        return check_schema(obj, node, root, path)
    errs = []
    types = schema.get("type")
    if types:
        py = {"object": dict, "array": list, "string": str, "boolean": bool, "null": type(None)}
        ok = False
        for t in (types if isinstance(types, list) else [types]):
            if t == "number":
                ok |= isinstance(obj, (int, float)) and not isinstance(obj, bool)
            else:
                ok |= isinstance(obj, py[t])
        if not ok:
            return [f"{path}: expected {types}"]
    if "const" in schema and obj != schema["const"]:
        errs.append(f"{path}: must be {schema['const']!r}")
    if "enum" in schema and obj not in schema["enum"]:
        errs.append(f"{path}: {obj!r} not in {schema['enum']}")
    if "minimum" in schema and obj < schema["minimum"]:
        errs.append(f"{path}: below {schema['minimum']}")
    if "exclusiveMinimum" in schema and obj <= schema["exclusiveMinimum"]:
        errs.append(f"{path}: must be > {schema['exclusiveMinimum']}")
    if "minLength" in schema and len(obj) < schema["minLength"]:
        errs.append(f"{path}: too short")
    if isinstance(obj, dict):
        for k in schema.get("required", []):
            if k not in obj:
                errs.append(f"{path}: missing {k}")
        for k, sub in schema.get("properties", {}).items():
            if k in obj:
                errs += check_schema(obj[k], sub, root, f"{path}.{k}")
    if isinstance(obj, list):
        if len(obj) < schema.get("minItems", 0):
            errs.append(f"{path}: needs >= {schema['minItems']} items")
        if "items" in schema:
            for i, v in enumerate(obj):
                e = check_schema(v, schema["items"], root, f"{path}[{i}]")
                if e:
                    return errs + e  # first bad item is enough
    return errs


# ------------------------------------------------------------------ derivation
def bearing(dx, dz):
    """Compass bearing (deg, clockwise from north = -Z) of a horizontal direction."""
    return math.degrees(math.atan2(dx, -dz)) % 360.0


def wrap180(a):
    return (a + 180.0) % 360.0 - 180.0


def derive(s, x, z, e):
    """grade_percent, heading_deg, curvature from samples (central differences, one-sided at the ends).
    s is horizontal distance, so grade = d(elevation) / d(horizontal distance) * 100."""
    n = len(s)
    grade, heading, curv = [0.0] * n, [0.0] * n, [0.0] * n
    for i in range(n):
        lo, hi = max(i - 1, 0), min(i + 1, n - 1)
        grade[i] = (e[hi] - e[lo]) / (s[hi] - s[lo]) * 100.0
        heading[i] = bearing(x[hi] - x[lo], z[hi] - z[lo])
    for i in range(n):
        lo, hi = max(i - 1, 0), min(i + 1, n - 1)
        curv[i] = -math.radians(wrap180(heading[hi] - heading[lo])) / (s[hi] - s[lo])  # + = turning left
    return grade, heading, curv


def sample(route, s):
    """Every per-sample field linearly interpolated at distance s (heading by the shortest angle)."""
    smp = route["samples"]
    ss = smp["s"]
    s = min(max(s, ss[0]), ss[-1])
    i = min(max(bisect.bisect_right(ss, s) - 1, 0), len(ss) - 2)
    t = (s - ss[i]) / (ss[i + 1] - ss[i])
    out = {}
    for k in FIELDS:
        a, b = smp[k][i], smp[k][i + 1]
        if k == "surface_type":
            out[k] = a if t < 0.5 else b
        elif k == "heading_deg":
            out[k] = (a + wrap180(b - a) * t) % 360.0
        else:
            out[k] = a + (b - a) * t
    out["s"] = s
    return out


def left_vector(heading_deg):
    """Horizontal unit vector to the left of travel (x, z)."""
    b = math.radians(heading_deg)
    return -math.cos(b), -math.sin(b)


# ------------------------------------------------------------------ building
def finalize(raw):
    """Complete a route from its primary facts: samples s, x, z, elevation_m, widths, surface_type, and markers given
    by s only (start, finish, checkpoints). Adds y, grade, heading, curvature and marker positions; rounds."""
    r = json.loads(json.dumps(raw))  # deep copy
    smp = r["samples"]
    r["version"] = VERSION
    r.setdefault("units", {"length": "m", "angle": "deg", "grade": "percent", "curvature": "1/m"})
    cs = r.setdefault("coordinate_system", {})
    for k, v in {"handedness": "right", "up": "+Y", "east": "+X", "north": "-Z", "elevation_datum_m": 0.0,
                 "elevation_reference": "route_local", "origin": None}.items():
        cs.setdefault(k, v)
    smp["y"] = [v - cs["elevation_datum_m"] for v in smp["elevation_m"]]
    for k in ["s", "x", "y", "z", "elevation_m", "width_left_m", "width_right_m"]:
        smp[k] = [round(v, ROUND[k]) for v in smp[k]]
    smp["grade_percent"], smp["heading_deg"], smp["curvature"] = derive(smp["s"], smp["x"], smp["z"], smp["elevation_m"])
    for k in ["grade_percent", "heading_deg", "curvature"]:
        smp[k] = [round(v, ROUND[k]) for v in smp[k]]
    r["samples"] = {k: smp[k] for k in FIELDS}
    r["total_length_m"] = smp["s"][-1]
    r.setdefault("start", {"id": "start", "s": 0.0})
    r.setdefault("finish", {"id": "finish", "s": r["total_length_m"]})
    r.setdefault("checkpoints", [])
    for m in [r["start"], r["finish"]] + r["checkpoints"]:
        p = sample(r, m["s"])
        m["position"] = [round(p["x"], 4), round(p["y"], 4), round(p["z"], 4)]
    order = ["route_id", "version", "coordinate_system", "units", "total_length_m", "sample_interval_m", "closed",
             "start", "finish", "checkpoints", "sections", "visual", "source", "samples"]
    return {k: r[k] for k in order if k in r} | {k: v for k, v in r.items() if k not in order}


def from_legacy(old, route_id, vertical_exaggeration=1.0, surface="unknown"):
    """Today's export route.json (tools/export_unity.gd: s, x, y, z, half_left, half_right; y as rendered).
    Physical elevation = rendered rise / vertical_exaggeration (Route.grade_scale of the scene that exported it)."""
    y0 = old["y"][0]
    raw = {
        "route_id": route_id,
        "sample_interval_m": float(old.get("step", 1.0)),
        "closed": False,
        "visual": {"vertical_exaggeration": vertical_exaggeration, "relief_amplitude_m": 0.0},
        "source": {"producer": "route_model.py legacy", "legacy_length_m": old.get("length"),
                   "note": "legacy samples stop at floor(length); legacy water_y / backdrop_yaw are not route data"},
        "samples": {
            "s": [float(v) for v in old["s"]], "x": old["x"], "z": old["z"],
            "elevation_m": [y0 + (y - y0) / vertical_exaggeration for y in old["y"]],
            "width_left_m": old["half_left"], "width_right_m": old["half_right"],
            "surface_type": [surface] * len(old["s"]),
        },
    }
    return finalize(raw)


# ------------------------------------------------------------------ validation
def validate(r):
    """List of problems (empty = valid)."""
    with open(SCHEMA_FILE) as f:
        errs = check_schema(r, json.load(f))
    if errs:
        return errs
    smp = r["samples"]
    n = len(smp["s"])
    for k in FIELDS:
        if len(smp[k]) != n:
            errs.append(f"samples.{k}: {len(smp[k])} entries, s has {n}")
        elif k != "surface_type" and not all(math.isfinite(v) for v in smp[k]):
            errs.append(f"samples.{k}: non-finite value")
    if errs:
        return errs
    s, x, y, z, e = smp["s"], smp["x"], smp["y"], smp["z"], smp["elevation_m"]
    step = r["sample_interval_m"]
    total = r["total_length_m"]

    def first(msg, bad):  # report the first failing index of a check
        if bad:
            errs.append(f"{msg} (first at s={s[bad[0]]}, {len(bad)} samples)")

    # distance continuity
    if abs(s[0]) > 1e-9:
        errs.append(f"s must start at 0, got {s[0]}")
    first("s not strictly increasing", [i for i in range(1, n) if s[i] <= s[i - 1]])
    first(f"sample interval != {step} m", [i for i in range(1, n - 1) if abs(s[i] - s[i - 1] - step) > 1e-6])
    if s[-1] - s[-2] > step + 1e-6:
        errs.append("last sample interval longer than sample_interval_m")
    if abs(total - s[-1]) > 1e-3:
        errs.append(f"total_length_m {total} != last s {s[-1]}")
    first("centreline gap: horizontal distance between samples != delta s",
          [i for i in range(1, n) if abs(math.hypot(x[i] - x[i - 1], z[i] - z[i - 1]) - (s[i] - s[i - 1]))
           > 0.01 + 0.002 * (s[i] - s[i - 1])])
    # elevation continuity
    datum = r["coordinate_system"]["elevation_datum_m"]
    first("y != elevation_m - elevation_datum_m", [i for i in range(n) if abs(y[i] - (e[i] - datum)) > TOL["y"]])
    first(f"elevation jump steeper than {MAX_GRADE_PERCENT}%",
          [i for i in range(1, n) if abs(e[i] - e[i - 1]) > MAX_GRADE_PERCENT / 100.0 * (s[i] - s[i - 1]) + 1e-3])
    # derived fields
    g, h, c = derive(s, x, z, e)
    first("grade_percent != d(elevation)/d(horizontal distance)",
          [i for i in range(n) if abs(smp["grade_percent"][i] - g[i]) > TOL["grade"]])
    first(f"|grade_percent| > {MAX_GRADE_PERCENT}", [i for i in range(n) if abs(smp["grade_percent"][i]) > MAX_GRADE_PERCENT])
    first("heading_deg out of [0, 360)", [i for i in range(n) if not 0.0 <= smp["heading_deg"][i] < 360.0])
    first("heading_deg inconsistent with x/z", [i for i in range(n) if abs(wrap180(smp["heading_deg"][i] - h[i])) > TOL["heading"]])
    first("curvature inconsistent with heading", [i for i in range(n) if abs(smp["curvature"][i] - c[i]) > TOL["curvature"]])
    # widths
    for k in ["width_left_m", "width_right_m"]:
        first(f"{k} must be in (0, {MAX_WIDTH_M}]", [i for i in range(n) if not 0.0 < smp[k][i] <= MAX_WIDTH_M])
    # start / finish / checkpoints
    st, fi, cps = r["start"], r["finish"], r["checkpoints"]
    if not 0.0 <= st["s"] < fi["s"] <= total + 1e-6:
        errs.append(f"need 0 <= start.s ({st['s']}) < finish.s ({fi['s']}) <= total_length_m ({total})")
    prev = st["s"]
    for cp in cps:
        if not prev < cp["s"] < fi["s"]:
            errs.append(f"checkpoint {cp['id']} at s={cp['s']} not in order between start and finish")
        prev = cp["s"]
    ids = [m["id"] for m in [st, fi] + cps]
    if len(set(ids)) != len(ids):
        errs.append("marker ids not unique")
    for m in [st, fi] + cps:
        p = sample(r, m["s"])
        if max(abs(a - b) for a, b in zip(m["position"], (p["x"], p["y"], p["z"]))) > TOL["marker"]:
            errs.append(f"{m['id']}.position does not match the route at s={m['s']}")
    # sections (optional): cover [0, total] without gaps
    secs = r.get("sections", [])
    if secs:
        if abs(secs[0]["from_s"]) > 1e-3 or abs(secs[-1]["to_s"] - total) > 1e-3:
            errs.append("sections must cover 0 .. total_length_m")
        for a, b in zip(secs, secs[1:]):
            if abs(a["to_s"] - b["from_s"]) > 1e-3:
                errs.append(f"gap between sections {a['id']} and {b['id']}")
        for sec in secs:
            if sec["to_s"] <= sec["from_s"]:
                errs.append(f"section {sec['id']} is empty")
    return errs


# ------------------------------------------------------------------ CLI
def _load(p):
    with open(p) as f:
        return json.load(f)


def _save(r, p):
    os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True)
    with open(p, "w") as f:
        json.dump(r, f, separators=(",", ":"))


def _report(r, path):
    errs = validate(r)
    for msg in errs:
        print("  FAIL", msg)
    smp = r["samples"]
    print(f"{path}: {r['route_id']} {r['total_length_m']:.1f} m, {len(smp['s'])} samples, grade "
          f"{min(smp['grade_percent']):.2f}..{max(smp['grade_percent']):.2f} %, elevation "
          f"{min(smp['elevation_m']):.1f}..{max(smp['elevation_m']):.1f} m -> {'VALID' if not errs else 'INVALID'}")
    return 1 if errs else 0


def main(argv):
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    args = [a for a in argv if not a.startswith("--")]
    if len(args) >= 2 and args[0] == "finalize":
        r = finalize(_load(args[1]))
        _save(r, args[2] if len(args) > 2 else args[1])
        return _report(r, args[2] if len(args) > 2 else args[1])
    if len(args) == 3 and args[0] == "legacy":
        r = from_legacy(_load(args[1]), opts.get("route-id", "legacy"), float(opts.get("exaggeration", 1.0)),
                        opts.get("surface", "unknown"))
        _save(r, args[2])
        return _report(r, args[2])
    if len(args) == 2 and args[0] == "validate":
        return _report(_load(args[1]), args[1])
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
