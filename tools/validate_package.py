#!/usr/bin/env python3
"""Validate a whole AI Scene Package: every stage validator in pipeline order, then the manifest's file references.

  python3 tools/validate_package.py <package_dir>

Stages that have not been generated yet (no layer file) are reported as missing, and so is everything after them:
the pipeline order is route -> road/terrain -> semantics -> vegetation -> structures -> environment.
"""
import glob
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import osm_context as oc
import environment as en  # noqa: E402
import road_terrain as rt  # noqa: E402
import route_model as rm  # noqa: E402
import semantics as sm  # noqa: E402
import structures as stc  # noqa: E402
import vegetation as vg  # noqa: E402


def _route(pkg):
    with open(os.path.join(pkg, "route", "route.json")) as f:
        return rm.validate(json.load(f))


def _semantics(pkg):
    route, sem = sm._load_pkg(pkg)
    return sm.validate(sem, route)


STAGES = [  # name, file that marks the stage as generated, validator
    ("route", "route/route.json", _route),
    ("road + terrain", "manifest.json", lambda p: rt.validate(p)[0]),
    ("semantics", "semantics/semantics.json", _semantics),
    ("vegetation", "vegetation/zones.json", lambda p: vg.validate(p)[0]),
    ("structures", "structures/structures.json", lambda p: stc.validate(p)[0]),
    ("environment", "environment/environment.json", lambda p: en.validate(p)[0]),
]


def validate(pkg):
    """[(stage, status, errors)], status in VALID / INVALID / MISSING."""
    out, ok = [], True
    for name, marker, fn in STAGES:
        if not ok or not os.path.isfile(os.path.join(pkg, marker)):
            out.append((name, "MISSING", [] if ok else ["an earlier stage is missing or invalid"]))
            ok = False
            continue
        errs = fn(pkg)
        out.append((name, "VALID" if not errs else "INVALID", errs))
        ok = not errs
    if os.path.isfile(os.path.join(pkg, "structures/osm_buildings.json")):
        errs = oc.validate_buildings(pkg)
        out.append(("OSM buildings", "VALID" if not errs else "INVALID", errs))
    # package integrity: every file the manifest lists exists
    errs = []
    mp = os.path.join(pkg, "manifest.json")
    if os.path.isfile(mp):
        with open(mp) as f:
            man = json.load(f)
        for layer, d in man.get("layers", {}).items():
            for pat in d.get("files", []):
                if not glob.glob(os.path.join(pkg, pat)):
                    errs.append(f"{layer}: {pat} listed in the manifest but not found")
        for pat in man.get("prototype_assets", {}).get("files", []):
            if not glob.glob(os.path.join(pkg, pat)):
                errs.append(f"prototype assets: {pat} listed but not found")
        for layer in ("vegetation", "structures"):
            pp = os.path.join(pkg, layer, "prototypes.json")
            if os.path.isfile(pp):
                with open(pp) as f:
                    protos = json.load(f)
                for proto in protos.get("prototypes", []):
                    mesh = proto.get("mesh_file")
                    if mesh and not os.path.isfile(os.path.join(pkg, mesh)):
                        errs.append(f"{layer} prototype {proto['id']}: mesh {mesh} missing")
        for t in man.get("tiles", []):
            for k, v in t.get("files", {}).items():
                if not os.path.isfile(os.path.join(pkg, v)):
                    errs.append(f"tile {t['id']}: {k} file {v} missing")
    out.append(("package integrity", "VALID" if not errs else "INVALID", errs))
    if os.path.isfile(mp) and man.get("acceptance"):
        ap = os.path.join(pkg, man["acceptance"])
        if not os.path.isfile(ap):
            out.append(("acceptance", "INVALID", ["declared acceptance file missing"]))
        else:
            with open(ap) as f:
                acceptance = json.load(f)
            accepted = acceptance.get("status") == "accepted"
            messages = [] if accepted else [b.get("reason", str(b)) for b in acceptance.get("blockers", [])]
            out.append(("acceptance", "VALID" if accepted else "INVALID", messages or ([] if accepted else ["candidate not accepted"])))
    return out


def main(argv):
    if len(argv) != 1:
        print(__doc__)
        return 2
    res = validate(argv[0])
    for name, status, errs in res:
        print(f"  {status:8} {name}")
        for e in errs[:10]:
            print(f"           {e}")
    good = all(s == "VALID" for _, s, _ in res)
    print(f"{argv[0]}: {'VALID' if good else 'NOT VALID'}")
    return 0 if good else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
