#!/usr/bin/env python3
"""Distant environment (P5) + atmosphere (P6) stage: environment/environment.json + its referenced assets. Stdlib only.

  python3 tools/environment.py build <package_dir> [--hints=<package>/environment/hints.json] [--max-grid=256]
  python3 tools/environment.py validate <package_dir>

Comes after route, road/terrain, semantics, vegetation and structures (all must exist and validate). Input: scene
facts as plain values (tools/environment_hints.py from a scene's text, tools/export_environment_hints.gd inside Godot,
or the same format from video / AI analysis). Output is environment DATA only - sun direction, intensities, fog density, sky reference, cloud coverage,
distant terrain mesh, water bodies, skyline; no shader code or engine settings. Format: docs/ENVIRONMENT.md.
"""
import array
import json
import math
import os
import shutil
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import road_terrain as rt  # noqa: E402
import route_model as rm  # noqa: E402
import semantics as sm  # noqa: E402
import structures as stc  # noqa: E402
import vegetation as vg  # noqa: E402

VERSION = "0.1"
EYE_M = 1.65
BACKDROP_YAW_WINDOW_M = 300.0   # the backdrop turns with the route direction smoothed over +-300 m (route.gd backdrop_yaw)
KOSCHMIEDER = 3.912             # visibility = 3.912 / extinction (5 % contrast)
ATTRIBUTION = {
    "dem": "Terrain elevation: AWS Terrain Tiles (https://registry.opendata.aws/terrain-tiles/, see its source attributions)",
    "s2": "Orthophoto: Sentinel-2 cloudless - https://s2maps.eu by EOX IT Services GmbH (Contains modified Copernicus Sentinel data 2016), CC BY 4.0",
    "swisstopo": "Orthophoto: (c) swisstopo, SWISSIMAGE",
    "polyhaven": "HDRI: Poly Haven (https://polyhaven.com), CC0",
}


def srgb_to_linear(c):
    return [round(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4, 5) for v in c]


def bearing_of(dx, dz):
    return math.degrees(math.atan2(dx, -dz)) % 360.0


def route_yaw(route, s, window=BACKDROP_YAW_WINDOW_M):
    """Backdrop turn (rad, + counter-clockwise from above) at s: the route's left vector smoothed over +-window,
    relative to the same at the start. Same rule as route.gd backdrop_yaw, from route.json alone."""
    smp = route["samples"]
    ss = smp["s"]

    def box(c):
        i0 = rm.bisect.bisect_left(ss, c - window)
        i1 = rm.bisect.bisect_right(ss, c + window)
        lx = lz = 0.0
        for i in range(i0, i1):
            x, z = rm.left_vector(smp["heading_deg"][i])
            lx, lz = lx + x, lz + z
        return lx, lz

    a = box(0.0)
    b = box(s)
    return math.atan2(-b[1], b[0]) - math.atan2(-a[1], a[0])


# ------------------------------------------------------------------ real DEM backdrop
class Dem:
    """tools/fetch_real_terrain.py output placed like scripts/real_terrain.gd: pivot-local metres (x east, z south at
    yaw 0), heights relative to the pivot (the runner's water level)."""

    def __init__(self, rtd):
        d = rtd["dir"]
        with open(os.path.join(d, rtd["name"] + ".json")) as f:
            self.meta = json.load(f)
        self.g = self.meta["grid"]
        self.size = self.meta["size_m"]
        self.step = self.size / (self.g - 1)
        self.h = array.array("f")
        with open(os.path.join(d, rtd["name"] + "_h.f32"), "rb") as f:
            self.h.frombytes(f.read())
        if sys.byteorder != "little":
            self.h.byteswap()
        self.p = rtd
        self.rot = math.radians(rtd["rotation_deg"])
        self.albedo = os.path.join(d, rtd["name"] + "_albedo.jpg")

    def _shape(self, x, z, v):  # sunk centre disc / sunk side, as real_terrain.gd
        p = self.p
        k = vg.rt.smoothstep(p["hole_radius"] * 0.75, p["hole_radius"], math.hypot(x, z))
        if p.get("sink_west_of") is not None:
            a = math.radians(p["sink_axis_deg"])
            k *= vg.rt.smoothstep(p["sink_west_of"] - 300.0, p["sink_west_of"], x * math.cos(a) + z * math.sin(a))
        return p["hole_depth"] + (v - p["hole_depth"]) * k

    def dem_y(self, r, c):
        x, z = (c - (self.g - 1) * 0.5) * self.step, (r - (self.g - 1) * 0.5) * self.step
        return x, z, self._shape(x, z, self.h[r * self.g + c] - self.meta["centre_m"] + self.p["height_offset"])

    def to_pivot(self, x, z):  # DEM-local -> pivot-local: rotate about Y by rotation_deg, anchor under the pivot
        ax, az = self.p["anchor"]
        dx, dz = x - ax, z - az
        cr, sr = math.cos(self.rot), math.sin(self.rot)
        return dx * cr + dz * sr, -dx * sr + dz * cr

    def height_at_pivot(self, px, pz):
        """Height relative to the pivot at pivot-local (px, pz) (bilinear on the full DEM), None outside it."""
        ax, az = self.p["anchor"]
        cr, sr = math.cos(self.rot), math.sin(self.rot)
        x, z = px * cr - pz * sr + ax, px * sr + pz * cr + az
        c = x / self.step + (self.g - 1) * 0.5
        r = z / self.step + (self.g - 1) * 0.5
        if not (0 <= c < self.g - 1 and 0 <= r < self.g - 1):
            return None
        c0, r0 = int(c), int(r)
        fc, fr = c - c0, r - r0
        h = self.h
        g = self.g
        v = (h[r0 * g + c0] * (1 - fc) + h[r0 * g + c0 + 1] * fc) * (1 - fr) + (h[(r0 + 1) * g + c0] * (1 - fc) + h[(r0 + 1) * g + c0 + 1] * fc) * fr
        return self._shape(x, z, v - self.meta["centre_m"] + self.p["height_offset"])

    def mesh(self, max_grid):
        stride = max(1, math.ceil((self.g - 1) / (max_grid - 1)))
        idx = list(range(0, self.g, stride))
        if idx[-1] != self.g - 1:
            idx.append(self.g - 1)
        n = len(idx)
        pos, uv = [], []
        for r in idx:
            for c in idx:
                x, z, y = self.dem_y(r, c)
                px, pz = self.to_pivot(x, z)
                pos.append((px, y, pz))
                uv.append((c / (self.g - 1), r / (self.g - 1)))
        tris = []
        for i in range(n - 1):
            for j in range(n - 1):
                a = i * n + j
                tris += [a, a + n, a + 1, a + 1, a + n, a + n + 1]  # front faces up (counter-clockwise from above)
        with open(self.albedo, "rb") as f:
            jpg = f.read()
        return {"name": "distant_terrain", "translation": [0.0, 0.0, 0.0], "texture": {"bytes": jpg, "mime": "image/jpeg"},
                "primitives": [{"material": {"name": "distant_terrain_orthophoto", "color": [1.0, 1.0, 1.0], "roughness": 1.0}, "indices": tris}],
                "attributes": {"POSITION": pos, "NORMAL": rt._normals(pos, tris), "TEXCOORD_0": uv}}, n

    def skyline(self, eye_y, step_deg=2.0, max_m=None):
        """[bearing_deg, elevation_deg, distance_m] of the horizon from the pivot, eye_y above the pivot."""
        max_m = max_m or self.size * 0.75
        out = []
        for k in range(int(360 / step_deg)):
            b = math.radians(k * step_deg)
            dx, dz = math.sin(b), -math.cos(b)
            best, at, d = -90.0, 0.0, 50.0
            while d < max_m:
                y = self.height_at_pivot(dx * d, dz * d)
                if y is None:
                    break
                e = math.degrees(math.atan2(y - eye_y, d))
                if e > best:
                    best, at = e, d
                d *= 1.03
            out.append([round(k * step_deg, 1), round(best, 2), round(at, 0)])
        return out


# ------------------------------------------------------------------ build
def _inputs(pkg):
    route, man, sem = vg._load(pkg)
    errs = rm.validate(route) + sm.validate(sem, route) + rt.validate(pkg)[0] + vg.validate(pkg)[0] + stc.validate(pkg)[0]
    return route, man, sem, errs


def build(pkg, hints_path=None, max_grid=256):
    for need in ("route/route.json", "manifest.json", "semantics/semantics.json", "vegetation/zones.json",
                 "structures/structures.json"):
        if not os.path.isfile(os.path.join(pkg, need)):
            raise ValueError(f"environment needs {need} first (... -> vegetation -> structures -> environment)")
    route, man, sem, errs = _inputs(pkg)
    if errs:
        raise ValueError("inputs invalid, not building the environment:\n  " + "\n  ".join(errs[:10]))
    with open(hints_path or os.path.join(pkg, "environment", "hints.json")) as f:
        h = json.load(f)
    edir = os.path.join(pkg, "environment")
    os.makedirs(edir, exist_ok=True)
    L = route["total_length_m"]
    georef = route["coordinate_system"].get("origin") is not None
    attribution = []
    # follow-runner anchoring: pivot under the runner at the water level, turning with the smoothed route direction
    off = h.get("water_offset_m") or [[0.0, 0.0], [L, 0.0]]
    follow = {"s": [o[0] for o in off], "pivot_y_offset_m": [o[1] for o in off],
              "yaw_deg": [round(math.degrees(route_yaw(route, o[0])), 3) for o in off],
              "rule": "pivot = (runner x, route y(s) + pivot_y_offset_m(s), runner z), rotated yaw_deg(s) about +Y "
                      "(counter-clockwise from above); linear in s between samples"}
    distant = {"anchors": {"follow_runner": follow} if not georef else {}, "terrain": [], "water": []}
    rtd = h.get("real_terrain")
    if rtd:
        dem = Dem(rtd)
        mesh, n = dem.mesh(max_grid)
        rt.write_glb(os.path.join(edir, "distant_terrain.glb"), mesh)
        meta = dem.meta
        ys = [p[1] for p in mesh["attributes"]["POSITION"]]
        img = "s2" if "garda" in rtd["name"] or "weissensee" in rtd["name"] else "swisstopo"
        distant["terrain"].append({
            "id": rtd["name"], "kind": "real_dem", "file": "environment/distant_terrain.glb", "anchor": "follow_runner" if not georef else "world",
            "frame": "pivot-local metres: x east / z south at yaw 0, y relative to the pivot",
            "grid": n, "size_m": meta["size_m"], "height_range_m": [round(min(ys), 1), round(max(ys), 1)],
            "material": {"base_color": "orthophoto (embedded texture)", "roughness": 1.0},
            "source": {"kind": "dem", "ref": f"assets/terrain/{rtd['name']} (tools/fetch_real_terrain.py)", "lat": meta.get("lat"),
                       "lon": meta.get("lon"), "placement": {k: rtd[k] for k in ("rotation_deg", "height_offset", "anchor", "sink_west_of", "sink_axis_deg")}},
            "attribution": ["dem", img]})
        attribution += ["dem", img]
        distant["skyline"] = {"at_s": 0.0, "eye_height_above_pivot_m": round(-off[0][1] + EYE_M, 3),
                              "samples": dem.skyline(-off[0][1] + EYE_M), "columns": ["bearing_deg", "elevation_deg", "distance_m"],
                              "note": "horizon of the distant terrain seen from the start, bearings in the world frame"}
    for w in h.get("water", []):
        distant["water"].append({
            "id": w["name"].lower(), "kind": "lake", "geometry": {"type": "plane", "size_m": w["size_m"]},
            "anchor": "follow_runner" if w.get("follows_route_water") else "world",
            "level_offset_m": w.get("base_y", 0.0),
            "appearance": {k: v for k, v in {"deep_color_linear": srgb_to_linear(w["deep_color"]) if "deep_color" in w else None,
                                              "shallow_color_linear": srgb_to_linear(w["shallow_color"]) if "shallow_color" in w else None,
                                              "roughness": w.get("roughness")}.items() if v is not None}})
    # atmosphere
    sun = h["sun"]
    d = sun["direction_to_sun"]
    ln = math.sqrt(sum(v * v for v in d))
    d = [v / ln for v in d]
    elev = math.degrees(math.asin(d[1]))
    sky = None
    if h.get("sky"):
        src = h["sky"]["hdri"]
        name = os.path.basename(src)
        shutil.copyfile(src, os.path.join(edir, "sky.hdr"))
        sky = {"type": "hdri", "file": "environment/sky.hdr", "projection": "equirectangular",
               "source": {"kind": "polyhaven", "name": os.path.splitext(name)[0], "file": name},
               "sun_in_image": {"u": h["sky"]["sun_u"], "elevation_deg": h["sky"]["sun_elevation_deg"]},
               "align": "rotate the panorama about +Y so its sun lies at sun.azimuth_deg",
               "intensity_relative": h["sky"].get("energy", 1.0), "attribution": ["polyhaven"]}
        attribution.append("polyhaven")
    coverage = 0.05 if sky and "clear" in sky["source"]["name"] else (0.4 if sky and "cloudy" in sky["source"]["name"] else 0.2)
    fog = h["fog"]
    clouds = [{"kind": "sky_dome", "coverage": coverage, "source": "HDRI" if sky else "estimate"}]
    for c in h.get("cloud_volumes", []):
        clouds.append({"kind": "cloud_sea", "top_below_route_m": c["y_below_route_m"], "thickness_m": 120.0, "coverage": 1.0})
    ph = h["time_of_day"]["phase"]
    env = {
        "version": VERSION, "route_id": route["route_id"],
        "distant": distant,
        "atmosphere": {
            "sun": {"direction_to_sun": [round(v, 6) for v in d], "elevation_deg": round(elev, 3),
                    "azimuth_deg": round(bearing_of(d[0], d[2]), 3), "azimuth_mode": sun["mode"],
                    "left_of_travel_deg": sun.get("left_of_travel_deg"),
                    "elevation_source": "hdri" if sun.get("elevation_from_hdri") else "time_of_day",
                    "color_linear": srgb_to_linear(sun["color"]), "intensity_relative": round(sun["energy"], 4),
                    "note": "direction at s = 0; relative_to_route keeps the sun left_of_travel_deg left of the run direction"},
            "sky": sky,
            "ambient": {"source": h["ambient"]["source"], "intensity_relative": round(h["ambient"]["energy"], 4)},
            "fog": {"model": "exponential", "density_per_m": fog["density"], "color_linear": srgb_to_linear(fog["color"]),
                    "visibility_m": round(KOSCHMIEDER / fog["density"]) if fog["density"] > 0 else None,
                    "aerial_perspective": round(fog["aerial_perspective"], 3), "sun_scatter": round(fog["sun_scatter"], 3),
                    "sky_affect": round(fog["sky_affect"], 3)},
            "clouds": clouds,
            "weather": {"condition": "clear" if coverage < 0.1 else ("partly_cloudy" if coverage < 0.6 else "overcast"),
                        "precipitation": "none", "visibility_m": round(KOSCHMIEDER / fog["density"]) if fog["density"] > 0 else None,
                        "mist_episodes": {"base_density_per_m": fog["mist"][0], "extra_density_per_m": fog["mist"][1]} if fog.get("mist") else None},
            "time_of_day": {"phase_start": round(ph[0], 4), "phase_end": round(ph[1], 4), "convention": "0 sunrise, 0.5 noon, 1 sunset",
                            "approx_local_time": [_clock(ph[0]), _clock(ph[1])]},
            "grading": {"tonemap_hint": h["grading"]["tonemap"], "exposure_ev": round(math.log2(h["grading"]["exposure"]), 3),
                        "saturation": round(h["grading"]["saturation"], 3), "contrast": round(h["grading"]["contrast"], 3),
                        "bloom": h["grading"]["glow"], "note": "look intent; runtimes may restyle"},
        },
        "attribution": [{"id": a, "text": ATTRIBUTION[a]} for a in dict.fromkeys(attribution)],
        "source": {"kind": "scene_generator", "ref": h.get("scene"), "course": h.get("course")},
    }
    with open(os.path.join(edir, "environment.json"), "w") as f:
        json.dump(env, f, indent=1)
    man["layers"]["P5_distant"] = {"status": "generated" if distant["terrain"] or distant["water"] else "absent",
                                   "files": ["environment/environment.json"] + [t["file"] for t in distant["terrain"]]}
    man["layers"]["P6_atmosphere"] = {"status": "generated", "files": ["environment/environment.json"] + ([sky["file"]] if sky else [])}
    man["environment"] = "environment/environment.json"
    with open(os.path.join(pkg, "manifest.json"), "w") as f:
        json.dump(man, f, indent=1)
    return env


def _clock(phase):  # 0 sunrise (06:00) .. 1 sunset (18:00), a 12 h day
    m = int(round((6.0 + 12.0 * phase) * 60))
    return f"{m // 60:02d}:{m % 60:02d}"


# ------------------------------------------------------------------ validation
def mesh_height_at(m, x, z):
    """Height of a read_glb mesh's triangle under (x, z) in its node frame, or None."""
    pos, idx = m["attributes"]["POSITION"], rt._tris(m)
    o = m["translation"]
    for k in range(0, len(idx), 3):
        tri = [pos[idx[k + j]] for j in range(3)]
        if min(p[0] for p in tri) + o[0] <= x <= max(p[0] for p in tri) + o[0] and min(p[2] for p in tri) + o[2] <= z <= max(p[2] for p in tri) + o[2]:
            y = vg._bary_y([(p[0] + o[0], p[1] + o[1], p[2] + o[2]) for p in tri], x, z)
            if y is not None:
                return y
    return None


def _num(v):
    return isinstance(v, (int, float)) and not isinstance(v, bool) and math.isfinite(v)


def validate(pkg):
    """(errors, report). Writes environment/validation.json."""
    with open(os.path.join(pkg, "route", "route.json")) as f:
        route = json.load(f)
    with open(os.path.join(pkg, "environment", "environment.json")) as f:
        env = json.load(f)
    with open(os.path.join(pkg, "manifest.json")) as f:
        man = json.load(f)
    errs = []
    for k in ("version", "route_id", "distant", "atmosphere", "attribution"):
        if k not in env:
            errs.append(f"missing {k}")
    if errs:
        return errs, {"errors": errs, "valid": False}
    if env["route_id"] != route["route_id"]:
        errs.append("route_id does not match route.json")
    if man.get("environment") != "environment/environment.json":
        errs.append("manifest does not reference environment/environment.json")
    att = {a["id"] for a in env["attribution"]}
    L = route["total_length_m"]
    georef = route["coordinate_system"].get("origin") is not None

    def ref(path, what, magic=None):
        p = os.path.join(pkg, path)
        if not os.path.isfile(p):
            errs.append(f"{what}: referenced file {path} missing")
            return None
        if magic:
            with open(p, "rb") as f:
                if not f.read(16).startswith(magic):
                    errs.append(f"{what}: {path} is not a {magic!r} file")
        return p

    dist, atm = env["distant"], env["atmosphere"]
    report = {}
    fol = dist["anchors"].get("follow_runner")
    uses_follow = any(t["anchor"] == "follow_runner" for t in dist["terrain"] + dist["water"])
    if uses_follow:
        if georef:
            errs.append("georeferenced route: distant geometry should be anchored to the world, not the runner")
        if not fol:
            errs.append("follow_runner geometry without anchors.follow_runner samples")
        else:
            ss = fol["s"]
            if not (len(ss) == len(fol["pivot_y_offset_m"]) == len(fol["yaw_deg"]) >= 2):
                errs.append("follow_runner arrays differ in length")
            elif abs(ss[0]) > 1e-6 or abs(ss[-1] - L) > 1e-3 or any(b <= a for a, b in zip(ss, ss[1:])):
                errs.append("follow_runner samples must run from 0 to total_length_m, increasing")
            else:
                worst = max(abs(math.degrees(route_yaw(route, s)) - y) for s, y in zip(ss, fol["yaw_deg"]))
                report["yaw_max_error_deg"] = round(worst, 4)
                if worst > 0.1:
                    errs.append(f"yaw_deg differs from the route's smoothed direction by {worst:.2f} deg")
                if max(fol["pivot_y_offset_m"]) > 0.0:
                    errs.append("pivot (water level) above the road somewhere along the route")
    for t in dist["terrain"]:
        p = ref(t["file"], f"terrain {t['id']}", b"glTF")
        for a in t.get("attribution", []):
            if a not in att:
                errs.append(f"terrain {t['id']}: attribution {a} not listed")
        if p:
            m = rt.read_glb(p)
            if not m["attributes"]["POSITION"] or m["images"] < 1:
                errs.append(f"terrain {t['id']}: mesh without vertices or orthophoto")
            if rt._face_up(m["attributes"]["POSITION"], rt._tris(m)):
                errs.append(f"terrain {t['id']}: triangles face down")
            if t["anchor"] == "follow_runner" and fol:
                # the runner must never be inside the distant terrain: the shipped mesh under the pivot stays below the road
                under = mesh_height_at(m, 0.0, 0.0)
                if under is None:
                    report["distant_terrain_clearance_under_runner_m"] = None  # no terrain under the runner
                else:
                    clear = min(-(under + o) for o in fol["pivot_y_offset_m"])
                    report["distant_terrain_clearance_under_runner_m"] = round(clear, 3)
                    if clear < 0.5:
                        errs.append(f"terrain {t['id']}: reaches {-clear:.1f} m above the road under the runner")
    for w in dist["water"]:
        if w["anchor"] == "follow_runner" and fol and max(o + w["level_offset_m"] for o in fol["pivot_y_offset_m"]) >= 0.0:
            errs.append(f"water {w['id']}: surface at or above the road")
        if w["geometry"]["type"] != "plane" or min(w["geometry"]["size_m"]) <= 0:
            errs.append(f"water {w['id']}: bad geometry")
    sk = dist.get("skyline")
    if sk and not all(len(r) == 3 and 0 <= r[0] < 360 and -90 <= r[1] <= 90 for r in sk["samples"]):
        errs.append("skyline samples must be [bearing 0..360, elevation -90..90, distance]")
    # sun / sky
    sun = atm["sun"]
    d = sun["direction_to_sun"]
    if abs(sum(v * v for v in d) - 1.0) > 1e-3:
        errs.append("sun.direction_to_sun is not a unit vector")
    else:
        if abs(math.degrees(math.asin(d[1])) - sun["elevation_deg"]) > 0.05:
            errs.append("sun.elevation_deg does not match its direction")
        if abs(rm.wrap180(bearing_of(d[0], d[2]) - sun["azimuth_deg"])) > 0.05:
            errs.append("sun.azimuth_deg does not match its direction")
    if sun["azimuth_mode"] == "relative_to_route":
        want = (route["samples"]["heading_deg"][0] - sun["left_of_travel_deg"]) % 360.0
        if abs(rm.wrap180(want - sun["azimuth_deg"])) > 1.0:
            errs.append(f"sun azimuth {sun['azimuth_deg']:.1f} is not {sun['left_of_travel_deg']} deg left of the start heading")
    elif sun["azimuth_mode"] != "world":
        errs.append("sun.azimuth_mode must be relative_to_route or world")
    if not -10.0 <= sun["elevation_deg"] <= 90.0 or sun["intensity_relative"] < 0:
        errs.append("sun elevation / intensity out of range")
    sky = atm.get("sky")
    if sky:
        ref(sky["file"], "sky", b"#?")
        for a in sky.get("attribution", []):
            if a not in att:
                errs.append(f"sky: attribution {a} not listed")
        if sun.get("elevation_source") == "hdri" and abs(sky["sun_in_image"]["elevation_deg"] - sun["elevation_deg"]) > 1.0:
            errs.append("sun elevation does not match the sun in the HDRI")
        if not 0 <= sky["sun_in_image"]["u"] <= 1:
            errs.append("sky.sun_in_image.u must be in [0, 1]")
    # ambient, fog, clouds, weather, time of day, colours
    if atm["ambient"]["intensity_relative"] < 0:
        errs.append("ambient intensity negative")
    fog = atm["fog"]
    if not 0 <= fog["density_per_m"] <= 0.05:
        errs.append("fog density out of range [0, 0.05] /m")
    elif fog["density_per_m"] > 0 and abs(fog["visibility_m"] - KOSCHMIEDER / fog["density_per_m"]) > 0.01 * fog["visibility_m"]:
        errs.append("fog visibility_m inconsistent with density")
    for c in atm["clouds"]:
        if not 0 <= c.get("coverage", 0) <= 1:
            errs.append(f"cloud layer {c['kind']}: coverage out of [0, 1]")
    tod = atm["time_of_day"]
    if not 0 <= tod["phase_start"] <= tod["phase_end"] <= 1:
        errs.append("time_of_day phases must satisfy 0 <= start <= end <= 1")
    for name, c in [("sun", sun["color_linear"]), ("fog", fog["color_linear"])]:
        if len(c) != 3 or not all(_num(v) and v >= 0 for v in c):
            errs.append(f"{name} colour must be 3 non-negative linear values")
    report.update(errors=errs, valid=not errs)
    with open(os.path.join(pkg, "environment", "validation.json"), "w") as f:
        json.dump(report, f, indent=1)
    return errs, report


def main(argv):
    opts = dict(a[2:].split("=", 1) for a in argv if a.startswith("--") and "=" in a)
    args = [a for a in argv if not a.startswith("--")]
    if len(args) == 2 and args[0] == "build":
        env = build(args[1], opts.get("hints"), int(opts.get("max-grid", 256)))
        a = env["atmosphere"]
        print(f"{args[1]}: {len(env['distant']['terrain'])} distant terrain, {len(env['distant']['water'])} water bodies; sun "
              f"{a['sun']['elevation_deg']:.1f} deg at {a['sun']['azimuth_deg']:.1f}; fog visibility {a['fog']['visibility_m']} m; "
              f"sky {(a['sky'] or {}).get('source', {}).get('name')}")
        args = ["validate", args[1]]
    if len(args) == 2 and args[0] == "validate":
        errs, rep = validate(args[1])
        for e in errs:
            print("  FAIL", e)
        print("  " + json.dumps({k: v for k, v in rep.items() if k not in ("errors", "valid")}))
        print("VALID" if not errs else f"INVALID ({len(errs)} problems)")
        return 0 if not errs else 1
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
