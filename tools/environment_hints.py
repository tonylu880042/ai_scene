#!/usr/bin/env python3
"""Scene facts for the environment stage (tools/environment.py), without Godot. Stdlib only.

    python3 tools/environment_hints.py scenes/MainScene_weissensee.tscn --course=rolling_hills \
        --package=export/packages/weissensee_rolling_hills

Writes <package>/environment/hints.json, the same file tools/export_environment_hints.gd writes (the Godot fallback).
Reads the .tscn text ([sub_resource] / [node] property lines, @export defaults from the attached scripts), applies the
course template (CourseSetup courses_file: template node properties, tod, fog) and redoes what CourseSetup._update()
does at the start (sun placed relative to the route, warm / mist lerps). The route comes from tools/build_route.py
(scripts/route.gd's centre line), so water level offsets and backdrop yaw match route.gd.
"""
import ast
import json
import math
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_route as br  # noqa: E402

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
# Godot 4 built-in defaults for the properties read here (a .tscn only stores what differs)
ENV_DEFAULTS = {"ambient_light_energy": 1.0, "fog_density": 0.01, "fog_light_color": [0.518, 0.553, 0.608],
                "fog_aerial_perspective": 0.0, "fog_sun_scatter": 0.0, "fog_sky_affect": 1.0, "tonemap_mode": 0,
                "tonemap_exposure": 1.0, "adjustment_enabled": False, "adjustment_saturation": 1.0,
                "adjustment_contrast": 1.0, "glow_enabled": False}
SUN_DEFAULTS = {"light_color": [1.0, 1.0, 1.0], "light_energy": 1.0, "rotation_degrees": [0.0, 0.0, 0.0]}
TONEMAPS = ["linear", "reinhard", "filmic", "aces", "agx"]
_TOKEN = re.compile(r'"(?:[^"\\]|\\.)*"|&(?=")|\b(true|false|null|INF|Vector[23]\.ZERO)\b|\b([A-Z]\w*)\(')
_CONST = {"true": "True", "false": "False", "null": "None", "INF": "1e999", "Vector2.ZERO": "[0, 0]", "Vector3.ZERO": "[0, 0, 0]"}


def value(text):
    """Godot text value -> Python: Color(...) / Vector*(...) -> list (Color without alpha), ExtResource("id") ->
    ("ExtResource", "id"), NodePath("p") -> "p", dicts / arrays / numbers / strings as is."""
    def sub(m):
        if m.group(1):
            return _CONST[m.group(1)]
        if m.group(2):
            return f'("{m.group(2)}",'
        return "" if m.group(0) == "&" else m.group(0)

    def conv(v):
        if isinstance(v, tuple):
            if v[0] == "Color":
                return [float(x) for x in v[1:4]]
            if v[0].startswith(("Vector", "Transform", "Basis")):
                return [float(x) for x in v[1:]]
            if v[0] in ("NodePath", "StringName"):
                return v[1] if len(v) > 1 else ""
            return v
        if isinstance(v, list):
            return [conv(x) for x in v]
        if isinstance(v, dict):
            return {k: conv(x) for k, x in v.items()}
        return v
    return conv(ast.literal_eval(_TOKEN.sub(sub, text.strip())))


def res(p):
    return os.path.join(ROOT, p[len("res://"):]) if p.startswith("res://") else p


def script_defaults(path):  # @export var name := value  (or name: Type = value) of a GDScript
    out = {}
    with open(res(path)) as f:
        for ln in f:
            m = re.match(r"\s*@export(?:_\w+)?(?:\([^)]*\))?\s+var\s+(\w+)\s*(?::\s*[\w\[\]]+)?\s*:?=\s*(.+?)\s*(#.*)?$", ln)
            if m:
                try:
                    out[m.group(1)] = value(m.group(2))
                except (ValueError, SyntaxError):
                    pass  # ponytail: expressions (e.g. PI / 4) are skipped; set them in the scene if a hint needs them
            elif re.match(r"\s*@export\s+var\s+(\w+)\s*:\s*NodePath\s*$", ln):
                out[ln.split("var")[1].split(":")[0].strip()] = ""
    return out


def parse_tscn(path):
    """{"ext": {id: path}, "sub": {id: {type, props}}, "nodes": {node path: {type, props}}}; node props include the
    attached script's @export defaults. ponytail: instanced sub-scenes are not expanded (no hint lives in one yet)."""
    ext, sub, nodes = {}, {}, {}
    cur, buf, key = None, "", None
    with open(path) as f:
        lines = f.read().splitlines()
    for ln in lines + ["[end]"]:
        if key is not None:  # multi-line value (dicts / arrays)
            buf += "\n" + ln
            if buf.count("{") + buf.count("[") + buf.count("(") <= buf.count("}") + buf.count("]") + buf.count(")"):
                cur[key] = buf
                key = None
            continue
        if ln.startswith("["):
            hdr = dict(re.findall(r'(\w+)=("[^"]*"|\S+?)(?=\s|\]$)', ln))
            hdr = {k: v.strip('"') for k, v in hdr.items()}
            kind = ln[1:].split()[0].rstrip("]")
            cur = {}
            if kind == "ext_resource":
                ext[hdr["id"]] = hdr["path"]
            elif kind == "sub_resource":
                sub[hdr["id"]] = {"type": hdr["type"], "props": cur}
            elif kind == "node":
                p = hdr.get("parent")
                npath = "" if p is None else (hdr["name"] if p == "." else f"{p}/{hdr['name']}")
                nodes[npath] = {"type": hdr.get("type"), "props": cur}
            continue
        m = re.match(r"^([\w/]+) = (.*)$", ln)
        if m and cur is not None:
            k, v = m.groups()
            o = v.count("{") + v.count("[") + v.count("(")
            if o > v.count("}") + v.count("]") + v.count(")"):
                key, buf = k, v
            else:
                cur[k] = v
    for d in list(sub.values()) + list(nodes.values()):
        d["props"] = {k: value(v) for k, v in d["props"].items()}
    for n in nodes.values():
        s = n["props"].get("script")
        if s:
            n["props"] = script_defaults(ext[s[1]]) | n["props"]
    return {"ext": ext, "sub": sub, "nodes": nodes}


def smoothstep(a, b, x):
    t = min(max((x - a) / (b - a), 0.0), 1.0)
    return t * t * (3.0 - 2.0 * t)


def lerp(a, b, t):
    return [x + (y - x) * t for x, y in zip(a, b)] if isinstance(a, list) else a + (b - a) * t


def _c(c):
    return [round(v, 4) for v in c[:3]]


def build(scene_path, course=None):
    sc = parse_tscn(res(scene_path))
    ext, sub, nodes = sc["ext"], sc["sub"], sc["nodes"]

    def node(name):
        return nodes[name]["props"] if name in nodes else None

    def resource(ref):  # ("SubResource", id) -> props; ("ExtResource", id) -> path
        return sub[ref[1]]["props"] if ref[0] == "SubResource" else ext[ref[1]]

    path3d = node("Path3D")
    setup = node("CourseSetup")
    course = course or path3d.get("course", "summit")
    tod, fogc = [0.4, 0.6], [0.0007, 0.0]
    if setup:
        with open(res(setup["courses_file"])) as f:
            cdata = json.load(f)
        c = cdata["courses"][course]
        tod = [float(x) for x in c["tod"]]
        if "fog" in c:
            fogc = [float(x) for x in c["fog"]]
        for name, props in cdata["templates"][c["template"]].items():  # CourseSetup._ready: template -> node properties
            if name in nodes:
                nodes[name]["props"].update(props)
    # the route as scripts/route.gd builds it
    secs = None
    if path3d.get("sections_file"):
        with open(res(path3d["sections_file"])) as f:
            secs = json.load(f)
    with open(os.path.join(ROOT, "data", "programs.json")) as f:
        segs = json.load(f)[course]
    r = br.Route(segs, secs, bend=path3d["bend"], start_height=path3d["start_height"], sea_right=path3d["sea_right"],
                 road_left=path3d["road_left"], road_right=path3d["road_right"], pace=path3d["pace_min_per_km"],
                 grade_scale=path3d["grade_scale"])
    sgn = -1.0 if r.sea_right else 1.0
    left = [(sgn * br.f32(math.sin(h)), sgn * -br.f32(math.cos(h))) for h in r.heading]  # (x, z): (f.z, -f.x)
    gap = [br.f32(float(r.section_at(i * br.ROW).get("water_gap", r.y[i] - path3d["sea_y"])) if secs else r.y[i] - path3d["sea_y"])
           for i in range(r.n)]
    if secs:
        gap = br.smooth(gap, 37)
    wy = [br.f32(y - g) for y, g in zip(r.y, gap)]
    cl = [(0.0, 0.0)]
    for lx, lz in left:  # prefix sums (route.gd _cleft, Vector3 f32)
        cl.append((br.f32(cl[-1][0] + lx), br.f32(cl[-1][1] + lz)))

    def box(i, k=int(300.0 / br.ROW)):
        a, b = max(i - k, 0), min(i + k + 1, r.n)
        return (cl[b][0] - cl[a][0]) / (b - a), (cl[b][1] - cl[a][1]) / (b - a)

    def at(a, s):
        i, t = r._row(s)
        return a[i] + (a[i + 1] - a[i]) * t

    def backdrop_yaw(s):
        a, b = box(0), box(min(max(r._row(s)[0], 0), r.n - 1))
        return math.atan2(-b[1], b[0]) - math.atan2(-a[1], a[0])

    # sun / sky / fog as CourseSetup._update() leaves them at the start (clock 0, runner at s = 0)
    env = ENV_DEFAULTS | resource(node("WorldEnvironment")["environment"])
    sun = SUN_DEFAULTS | node("Sun")
    if "transform" in sun:
        to_sun = sun["transform"][6:9]  # basis z column
    else:
        rx, ry = math.radians(sun["rotation_degrees"][0]), math.radians(sun["rotation_degrees"][1])
        to_sun = [math.sin(ry) * math.cos(rx), -math.sin(rx), math.cos(ry) * math.cos(rx)]
    sun_color, sun_energy = sun["light_color"], sun["light_energy"]
    fog_color, fog_density, sky_affect, ambient = env["fog_light_color"], env["fog_density"], env["fog_sky_affect"], env["ambient_light_energy"]
    if setup:
        elev = setup["hdri_sun_elev"] if setup["hdri_sky"] else 4.0 + 46.0 * math.sin(tod[0] * math.pi)
        lx, lz = left[0]
        n = math.hypot(lx, lz)
        fx, fz = -lz / n, lx / n
        a = math.radians(lerp(setup["sun_left_deg"][0], setup["sun_left_deg"][1], smoothstep(4.0, 35.0, elev)))
        sx, sz = fx * math.cos(a) + fz * math.sin(a), -fx * math.sin(a) + fz * math.cos(a)  # Basis(UP, a) * fwd
        yaw, e = math.atan2(sx, sz), math.radians(elev)
        to_sun = [math.sin(yaw) * math.cos(e), math.sin(e), math.cos(yaw) * math.cos(e)]
        warm = 1.0 - smoothstep(4.0, 28.0, elev)
        sun_color = lerp([1.0, 0.95, 0.88], [1.0, 0.6, 0.35], warm)
        sun_energy = lerp(1.5, 0.8, warm)
        fog_color = lerp([0.62, 0.75, 0.9], [0.95, 0.72, 0.58], warm)
        ambient = lerp(1.4, 0.9, warm)
        if setup["mist_enabled"]:
            m = smoothstep(0.35, 0.85, 0.5 + 0.22 * math.sin(1.3) + 0.12 * math.sin(2.0))  # clock() = 0
            fog_density = fogc[0] + fogc[1] * m
            fog_color = lerp(fog_color, [0.86, 0.89, 0.93], m)
            sky_affect = lerp(0.25, 1.0, m)
            sun_energy *= lerp(1.0, 0.45, m)
            ambient *= lerp(1.0, 0.8, m)
    h = {"scene": scene_path if scene_path.startswith("res://") else "res://" + os.path.relpath(res(scene_path), ROOT),
         "course": course}
    h["sun"] = {"direction_to_sun": to_sun, "color": _c(sun_color), "energy": sun_energy, "mode": "relative_to_route",
                "left_of_travel_deg": setup["sun_left_deg"][1] if setup else 45.0,
                "elevation_from_hdri": bool(setup["hdri_sky"]) if setup else False}
    sky = resource(env["sky"]) if env.get("sky") else None
    sky_mat = resource(sky["sky_material"]) if sky and sky.get("sky_material") else None
    if sky_mat and sky_mat.get("shader_parameter/pano"):
        h["sky"] = {"hdri": res(resource(sky_mat["shader_parameter/pano"])),
                    "sun_u": setup["hdri_sun_u"] if setup else 0.5, "sun_elevation_deg": setup["hdri_sun_elev"] if setup else 45.0,
                    "energy": float(sky_mat.get("shader_parameter/energy", 1.0))}
    h["ambient"] = {"source": "sky", "energy": ambient}
    h["fog"] = {"density": fog_density, "color": _c(fog_color), "aerial_perspective": env["fog_aerial_perspective"],
                "sun_scatter": env["fog_sun_scatter"], "sky_affect": sky_affect,
                "mist": fogc if setup and setup["mist_enabled"] else None}
    adj = env["adjustment_enabled"]
    h["grading"] = {"tonemap": TONEMAPS[env["tonemap_mode"]] if env["tonemap_mode"] < 5 else "other",
                    "exposure": env["tonemap_exposure"], "saturation": env["adjustment_saturation"] if adj else 1.0,
                    "contrast": env["adjustment_contrast"] if adj else 1.0, "glow": env["glow_enabled"]}
    h["time_of_day"] = {"phase": tod}
    rt, fb = node("RealBackdrop/RealTerrain"), node("RealBackdrop")
    if rt:
        h["real_terrain"] = {"name": rt["terrain_name"], "dir": res("res://assets/terrain/"), "rotation_deg": rt["rotation_deg"],
                             "height_offset": rt["height_offset"], "anchor": rt["anchor"], "hole_radius": rt["hole_radius"],
                             "hole_depth": rt["hole_depth"], "sink_west_of": None if math.isinf(rt["sink_west_of"]) else rt["sink_west_of"],
                             "sink_axis_deg": rt["sink_axis_deg"],
                             "follow": {"base_y": fb["base_y"], "route_water": bool(fb.get("route_water")), "route_yaw": fb["route_yaw"]}}
    waters = []
    for nm in ["LakeFar", "Ocean", "Sea"]:
        w = node(nm)
        mesh = resource(w["mesh"]) if w and w.get("mesh") else None
        if mesh is None or sub[w["mesh"][1]]["type"] != "PlaneMesh":
            continue
        wd = {"name": nm, "size_m": mesh.get("size", [2.0, 2.0]), "base_y": float(w.get("base_y", 0.0)),
              "follows_route_water": bool(w.get("route_water"))}
        m = resource(w["surface_material_override/0"]) if w.get("surface_material_override/0") else None
        if m:
            for k in ["deep_color", "shallow_color"]:
                if "shader_parameter/" + k in m:
                    wd[k] = _c(m["shader_parameter/" + k])
            if "shader_parameter/water_roughness" in m:
                wd["roughness"] = m["shader_parameter/water_roughness"]
        waters.append(wd)
    h["water"] = waters
    off, yaws, s = [], [], 0.0
    while True:  # follow-runner anchoring along the route: water level below the road, backdrop turn
        off.append([round(s, 2), round(at(wy, s) - at(r.y, s), 3)])
        yaws.append([round(s, 2), round(backdrop_yaw(s), 5)])
        if s >= r.length:
            break
        s = min(s + 25.0, r.length)
    h["water_offset_m"] = off
    h["godot_backdrop_yaw_rad"] = yaws
    clouds = []
    for npath, n in nodes.items():
        mo = n["props"].get("material_override")
        mat = resource(mo) if mo and mo[0] == "SubResource" else None
        shader = ext.get(mat["shader"][1], "") if mat and mat.get("shader") else ""
        if n["type"] == "MeshInstance3D" and "cloud" in shader:
            y = 0.0  # ponytail: sums parent positions' y, ignores parent rotation / scale (cloud seas sit unrotated)
            parts = npath.split("/")
            for k in range(1, len(parts) + 1):
                p = nodes.get("/".join(parts[:k]), {"props": {}})["props"]
                y += p["transform"][10] if "transform" in p else p.get("position", [0, 0, 0])[1]
            clouds.append({"node": parts[-1], "shader": os.path.basename(shader), "y_below_route_m": round(r.y[0] - y, 1)})
    h["cloud_volumes"] = clouds
    return h


def main(argv):
    opts = dict((a[2:].split("=", 1) + ["1"])[:2] for a in argv if a.startswith("--"))
    args = [a for a in argv if not a.startswith("--")]
    if len(args) != 1 or "package" not in opts:
        print(__doc__)
        return 2
    h = build(args[0], opts.get("course"))
    out = os.path.join(opts["package"], "environment", "hints.json")
    os.makedirs(os.path.dirname(out), exist_ok=True)
    with open(out, "w") as f:
        json.dump(h, f, indent=1)
    print("environment hints ->", out)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
