"""Build a Blender scene from a Godot glTF export (tools/export_unity.gd output) and render one frame.

  /Applications/Blender.app/Contents/MacOS/Blender --background --python tools/blender_scene.py -- \
      <export_dir> <s_metres> <out.png> [CYCLES|EEVEE] [samples] [--blend out.blend] [--real-shore <shore.json>]
      [--east-dem <dem.json>] [--anim <seconds> [--fps 30] [--frames <first> <last>]]
      [--camera-json <godot course export dir> --cam-frames <first> <last> [--scale <percent>]]

Imports the route tiles, the repeated prototypes (placed from tile_XX_instances.json as linked duplicates), the real
terrain backdrop, adds the lake (route.json water_y), the HDRI sky turned so its sun matches the exported sun
direction, a thin aerial-perspective haze, and puts the runner camera at route offset s (1.65 m, looking 3 m ahead).
Cycles adds rounded edges (bevel shading) to every material. Godot space (Y up) -> Blender (Z up): (x, y, z) -> (x, -z, y).
--real-shore: dense real mountains with photo texture, crag displacement and scrub (tools/blender_real_band.py).
--east-dem <assets/terrain/<dem>.json>: a high-resolution DEM patch for the opposite shore, in the backdrop's frame.
--anim: the runner camera moves from s at the course pace (6:00 min/km, as in Godot) for that many seconds; OUT is a
directory that receives frame_####.png (encode with tools/frames_to_mp4.py or ffmpeg).
--camera-json: replay a Godot course export (tools/export_course.sh) exactly - per frame camera pose, fov, resolution,
fps and sun direction from its camera.json - into OUT/frame_#####.png numbered by camera.json frame index, for
tools/splice_highlights.py to cut into that export's video.mp4 (s_metres is ignored: the scene is built around the clip).
"""
import bpy, json, math, os, sys
from mathutils import Matrix, Quaternion, Vector

argv = sys.argv[sys.argv.index("--") + 1:]
blend_out = None
real_shore = None
east_dem = None
if "--east-dem" in argv:
    east_dem = os.path.abspath(argv[argv.index("--east-dem") + 1])
    argv = argv[:argv.index("--east-dem")] + argv[argv.index("--east-dem") + 2:]
if "--real-shore" in argv:
    real_shore = os.path.abspath(argv[argv.index("--real-shore") + 1])
    argv = argv[:argv.index("--real-shore")] + argv[argv.index("--real-shore") + 2:]
anim = None  # --anim <seconds> [--fps 30] [--frames <first> <last>]: OUT is a directory of PNG frames
if "--anim" in argv:
    k = argv.index("--anim")
    anim = {"seconds": float(argv[k + 1]), "fps": 30, "first": None, "last": None}
    argv = argv[:k] + argv[k + 2:]
    if "--fps" in argv:
        k = argv.index("--fps")
        anim["fps"] = int(argv[k + 1])
        argv = argv[:k] + argv[k + 2:]
    if "--frames" in argv:
        k = argv.index("--frames")
        anim["first"], anim["last"] = int(argv[k + 1]), int(argv[k + 2])
        argv = argv[:k] + argv[k + 3:]
camjson = None  # --camera-json <godot export dir> --cam-frames <first> <last> [--scale <percent>]
if "--camera-json" in argv:
    k = argv.index("--camera-json")
    camjson = {"dir": os.path.abspath(argv[k + 1]), "scale": 100}
    argv = argv[:k] + argv[k + 2:]
    k = argv.index("--cam-frames")
    camjson["first"], camjson["last"] = int(argv[k + 1]), int(argv[k + 2])
    argv = argv[:k] + argv[k + 3:]
    if "--scale" in argv:
        k = argv.index("--scale")
        camjson["scale"] = int(argv[k + 1])
        argv = argv[:k] + argv[k + 2:]
if "--blend" in argv:
    blend_out = argv[argv.index("--blend") + 1]
    argv = argv[:argv.index("--blend")]
EXP, S_M, OUT = os.path.abspath(argv[0]), float(argv[1]), os.path.abspath(argv[2])
ENGINE = argv[3] if len(argv) > 3 else "CYCLES"
if camjson:  # build the scene around the clip
    S_M = json.load(open(os.path.join(camjson["dir"], "camera.json")))["frames"]["s"][camjson["first"]]
SAMPLES = int(argv[4]) if len(argv) > 4 else 128

C = Matrix.Rotation(math.radians(90.0), 4, "X")  # Godot -> Blender
CI = C.inverted()
g2b = lambda v: Vector((v[0], -v[2], v[1]))

bpy.ops.wm.read_factory_settings(use_empty=True)
scene = bpy.context.scene
env = json.load(open(os.path.join(EXP, "environment.json")))
route = json.load(open(os.path.join(EXP, "route.json")))


def import_glb(path):
    before = set(bpy.data.objects)
    bpy.ops.import_scene.gltf(filepath=path)
    return [o for o in bpy.data.objects if o not in before]


# --- geometry
tile_objs = []
for t in env["tiles"]:
    tile_objs += import_glb(os.path.join(EXP, t["file"]))
backdrop_objs = import_glb(os.path.join(EXP, "backdrop.glb"))
protos = {}
for o in import_glb(os.path.join(EXP, env["prototypes_file"])):
    if o.type == "MESH":
        protos[o.name.split(".")[0]] = o
        o.hide_render = True
        o.hide_viewport = True
inst_col = bpy.data.collections.new("instances")
scene.collection.children.link(inst_col)
n_inst = 0
for t in env["tiles"]:
    groups = json.load(open(os.path.join(EXP, t["instances"])))["groups"]
    for g in groups:
        src = protos.get(g["proto"])
        if src is None:
            print("missing prototype", g["proto"])
            continue
        d = g["data"]
        for k in range(g["count"]):
            px, py, pz, qx, qy, qz, qw, sx, sy, sz = d[k * 10:k * 10 + 10]
            tg = Matrix.LocRotScale(Vector((px, py, pz)), Quaternion((qw, qx, qy, qz)), Vector((sx, sy, sz)))
            o = bpy.data.objects.new(g["proto"], src.data)
            o.matrix_world = C @ tg @ CI @ src.matrix_world
            inst_col.objects.link(o)
            n_inst += 1
print("instances", n_inst)
if real_shore or east_dem:
    sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
    import blender_real_band
if east_dem:
    blender_real_band.east_patch(east_dem, next(o for o in backdrop_objs if o.type == "MESH"))
if real_shore:
    blender_real_band.cut_godot_terrain(tile_objs, route, env["route_from_m"], env["route_to_m"])
    blender_real_band.build(real_shore, route, env, S_M - 200.0, S_M + 2500.0,
                            [o for name, o in protos.items() if name.startswith("shrub")])

# --- camera on the route
i = min(int(S_M), len(route["x"]) - 4)
pos = g2b((route["x"][i], route["y"][i] + env["camera"]["height_m"], route["z"][i]))
aim = g2b((route["x"][i + 3], route["y"][i + 3] + env["camera"]["height_m"], route["z"][i + 3]))
cam_data = bpy.data.cameras.new("runner")
cam_data.sensor_fit = "VERTICAL"
cam_data.lens_unit = "FOV"
cam_data.angle = math.radians(env["camera"]["fov_y_deg"])
cam_data.clip_end = 30000.0
cam = bpy.data.objects.new("runner", cam_data)
scene.collection.objects.link(cam)
cam.location = pos
cam.rotation_euler = (aim - pos).to_track_quat("-Z", "Y").to_euler()
scene.camera = cam

# --- lake: a large plane at the water level under the camera, gentle wind ripples
wy = route.get("water_y", [env.get("sea_y", -1.0)] * len(route["x"]))[i]
bpy.ops.mesh.primitive_plane_add(size=40000.0, location=(pos.x, pos.y, wy))
lake = bpy.context.active_object
lake.name = "lake"
m = bpy.data.materials.new("lake")
m.use_nodes = True
nt = m.node_tree
bsdf = nt.nodes["Principled BSDF"]
bsdf.inputs["Base Color"].default_value = (0.01, 0.07, 0.13, 1)
bsdf.inputs["Roughness"].default_value = 0.03
bsdf.inputs["IOR"].default_value = 1.33
noise = nt.nodes.new("ShaderNodeTexNoise")
noise.inputs["Scale"].default_value = 0.6
noise.inputs["Detail"].default_value = 8.0
coord = nt.nodes.new("ShaderNodeTexCoord")
mapping = nt.nodes.new("ShaderNodeMapping")
mapping.inputs["Scale"].default_value = (1.0, 3.0, 1.0)  # ripples stretched across the wind
nt.links.new(coord.outputs["Object"], mapping.inputs["Vector"])
nt.links.new(mapping.outputs["Vector"], noise.inputs["Vector"])
bump = nt.nodes.new("ShaderNodeBump")
bump.inputs["Strength"].default_value = 0.12
bump.inputs["Distance"].default_value = 0.05
nt.links.new(noise.outputs["Fac"], bump.inputs["Height"])
nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
lake.data.materials.append(m)

# --- world: HDRI sky turned so its photographed sun sits where the exported sun is; faint aerial haze
world = bpy.data.worlds.new("sky")
scene.world = world
world.use_nodes = True
wn = world.node_tree
bg = wn.nodes["Background"]
tex = wn.nodes.new("ShaderNodeTexEnvironment")
tex.image = bpy.data.images.load(os.path.join(EXP, env["sky"]["hdri"]))
wmap = wn.nodes.new("ShaderNodeMapping")
wco = wn.nodes.new("ShaderNodeTexCoord")
wn.links.new(wco.outputs["Generated"], wmap.inputs["Vector"])
wn.links.new(wmap.outputs["Vector"], tex.inputs["Vector"])
# the camera sees the photo; lighting sees it clamped (like hdri_sky.gdshader's ambient_clamp) and a sun lamp
# carries the direct sunlight, so both engines get the same crisp shadows
clamp = wn.nodes.new("ShaderNodeVectorMath")
clamp.operation = "MINIMUM"
clamp.inputs[1].default_value = (3.0, 3.0, 3.0)
wn.links.new(tex.outputs["Color"], clamp.inputs[0])
lp = wn.nodes.new("ShaderNodeLightPath")
mix = wn.nodes.new("ShaderNodeMix")
mix.data_type = "RGBA"
# the sky as seen (directly and in reflections) is graded toward the reference's deep autumn blue: more saturated, a
# little darker, bluer toward the zenith. Light falling on the scene keeps the photo's own colour.
seen = wn.nodes.new("ShaderNodeMath")
seen.operation = "MAXIMUM"
wn.links.new(lp.outputs["Is Camera Ray"], seen.inputs[0])
wn.links.new(lp.outputs["Is Glossy Ray"], seen.inputs[1])
hsv = wn.nodes.new("ShaderNodeHueSaturation")
hsv.inputs["Saturation"].default_value = 1.7
hsv.inputs["Value"].default_value = 0.85
wn.links.new(tex.outputs["Color"], hsv.inputs["Color"])
zen = wn.nodes.new("ShaderNodeSeparateXYZ")
wn.links.new(wco.outputs["Generated"], zen.inputs["Vector"])
up = wn.nodes.new("ShaderNodeMapRange")
up.inputs["From Min"].default_value = 0.02
up.inputs["From Max"].default_value = 0.7
wn.links.new(zen.outputs["Z"], up.inputs["Value"])
deep = wn.nodes.new("ShaderNodeMix")
deep.data_type = "RGBA"
deep.blend_type = "MULTIPLY"
wn.links.new(up.outputs["Result"], deep.inputs["Factor"])
wn.links.new(hsv.outputs["Color"], deep.inputs["A"])
deep.inputs["B"].default_value = (0.65, 0.8, 1.0, 1.0)
wn.links.new(seen.outputs["Value"], mix.inputs["Factor"])
wn.links.new(clamp.outputs["Vector"], mix.inputs["A"])
wn.links.new(deep.outputs["Result"], mix.inputs["B"])
wn.links.new(mix.outputs["Result"], bg.inputs["Color"])
HDRI_SUN_U = 0.6005  # kloofendal_43d_clear_puresky (see MainScene_garda.tscn hdri_sun_u)
sun = g2b(env["sun"]["direction_to_sun"])
# Blender equirect: u = atan2(y, -x) / 2pi + 0.5; a Z rotation by r of the lookup vector lowers atan2(y, -x) by r
wmap.inputs["Rotation"].default_value[2] = math.atan2(sun.y, -sun.x) - (HDRI_SUN_U - 0.5) * 2.0 * math.pi
sun_data = bpy.data.lights.new("sun", "SUN")
sun_data.energy = 4.5
sun_data.angle = math.radians(0.6)
sun_data.color = env["sun"]["color"]
sun_obj = bpy.data.objects.new("sun", sun_data)
scene.collection.objects.link(sun_obj)
sun_obj.rotation_euler = (-sun).to_track_quat("-Z", "Y").to_euler()
# aerial haze in a bounded layer above the lake (a World volume would be infinitely deep and swallow the sky)
bpy.ops.mesh.primitive_cube_add(size=1.0, location=(pos.x, pos.y, wy + 400.0))
haze = bpy.context.active_object
haze.name = "haze"
haze.scale = (30000.0, 30000.0, 800.0)
hm = bpy.data.materials.new("haze")
hm.use_nodes = True
hn = hm.node_tree
hn.nodes.remove(hn.nodes["Principled BSDF"])
vol = hn.nodes.new("ShaderNodeVolumePrincipled")
vol.inputs["Color"].default_value = (*env["fog"]["color"], 1.0)
vol.inputs["Density"].default_value = 0.00005  # clear autumn air: distant shores stay crisp
hn.links.new(vol.outputs["Volume"], hn.nodes["Material Output"].inputs["Volume"])
haze.data.materials.append(hm)

# --- vertex colours: the glTF importer leaves the node's layer empty, which EEVEE resolves but Cycles renders black
for mat in bpy.data.materials:
    if mat.use_nodes:
        for n in mat.node_tree.nodes:
            if n.bl_idname == "ShaderNodeVertexColor" and not n.layer_name:
                n.layer_name = "Color"

# --- route terrain: the exporter flattens Godot's terrain shader to plain "meadow" grass; give it dry Mediterranean
# grass on gentle ground and box-projected limestone on steep faces (switched by surface steepness, as in Godot)
for mat in [m for m in bpy.data.materials if m.name.startswith("meadow")]:
    nt = mat.node_tree
    p = next(n for n in nt.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled")
    grass_img = next((n for n in nt.nodes if n.bl_idname == "ShaderNodeTexImage"), None)
    co = nt.nodes.new("ShaderNodeTexCoord")
    rock = nt.nodes.new("ShaderNodeTexImage")
    rock.image = bpy.data.images.load(os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), "assets/textures/rock_boulder_dry_diff.jpg"))
    rock.projection = "BOX"
    rock.projection_blend = 0.3
    rmap = nt.nodes.new("ShaderNodeMapping")
    rmap.inputs["Scale"].default_value = (0.12, 0.12, 0.12)
    nt.links.new(co.outputs["Object"], rmap.inputs["Vector"])
    nt.links.new(rmap.outputs["Vector"], rock.inputs["Vector"])
    grey = nt.nodes.new("ShaderNodeRGBToBW")
    nt.links.new(rock.outputs["Color"], grey.inputs["Color"])
    lime = nt.nodes.new("ShaderNodeMix")
    lime.data_type = "RGBA"
    lime.blend_type = "MULTIPLY"
    lime.inputs["Factor"].default_value = 1.0
    nt.links.new(grey.outputs["Val"], lime.inputs["A"])
    lime.inputs["B"].default_value = (1.25, 1.2, 1.1, 1.0)
    grass = nt.nodes.new("ShaderNodeMix")
    grass.data_type = "RGBA"
    grass.blend_type = "MULTIPLY"
    grass.inputs["Factor"].default_value = 1.0
    if grass_img:
        nt.links.new(grass_img.outputs["Color"], grass.inputs["A"])
    grass.inputs["B"].default_value = (0.75, 0.72, 0.42, 1.0)  # dry olive, not lawn green
    geo = nt.nodes.new("ShaderNodeNewGeometry")
    sepn = nt.nodes.new("ShaderNodeSeparateXYZ")
    nt.links.new(geo.outputs["Normal"], sepn.inputs["Vector"])
    steep = nt.nodes.new("ShaderNodeMapRange")
    steep.inputs["From Min"].default_value = 0.8   # normal.z: 1 = flat
    steep.inputs["From Max"].default_value = 0.55
    nt.links.new(sepn.outputs["Z"], steep.inputs["Value"])
    mixc = nt.nodes.new("ShaderNodeMix")
    mixc.data_type = "RGBA"
    nt.links.new(steep.outputs["Result"], mixc.inputs["Factor"])
    nt.links.new(grass.outputs["Result"], mixc.inputs["A"])
    nt.links.new(lime.outputs["Result"], mixc.inputs["B"])
    nt.links.new(mixc.outputs["Result"], p.inputs["Base Color"])
    p.inputs["Roughness"].default_value = 0.95
    # crags on the steep faces (Cycles displacement; the terrain objects get adaptive subdivision below)
    vor = nt.nodes.new("ShaderNodeTexVoronoi")
    vor.inputs["Scale"].default_value = 0.35
    nt.links.new(co.outputs["Object"], vor.inputs["Vector"])
    noi = nt.nodes.new("ShaderNodeTexNoise")
    noi.inputs["Scale"].default_value = 0.8
    noi.inputs["Detail"].default_value = 8.0
    nt.links.new(co.outputs["Object"], noi.inputs["Vector"])
    crag = nt.nodes.new("ShaderNodeMath")
    crag.operation = "ADD"
    nt.links.new(vor.outputs["Distance"], crag.inputs[0])
    nt.links.new(noi.outputs["Fac"], crag.inputs[1])
    amt = nt.nodes.new("ShaderNodeMath")
    amt.operation = "MULTIPLY"
    nt.links.new(crag.outputs["Value"], amt.inputs[0])
    nt.links.new(steep.outputs["Result"], amt.inputs[1])
    disp = nt.nodes.new("ShaderNodeDisplacement")
    disp.inputs["Midlevel"].default_value = 0.0
    disp.inputs["Scale"].default_value = 1.6  # metres of crag relief on vertical faces
    nt.links.new(amt.outputs["Value"], disp.inputs["Height"])
    nt.links.new(disp.outputs["Displacement"], nt.nodes["Material Output"].inputs["Displacement"])
    mat.displacement_method = "BOTH"
    for o in bpy.data.objects:
        if o.type == "MESH" and mat.name in [ms.name for ms in o.data.materials if ms] and not any(md.type == "SUBSURF" for md in o.modifiers):
            md = o.modifiers.new("subdiv", "SUBSURF")
            md.subdivision_type = "SIMPLE"
            md.levels = 0
            md.use_adaptive_subdivision = True

# --- materials: rounded edges in Cycles (the procedural props are sharp boxes)
for mat in bpy.data.materials:
    if not mat.use_nodes or mat.name in ("lake", "haze"):
        continue
    p = next((n for n in mat.node_tree.nodes if n.bl_idname == "ShaderNodeBsdfPrincipled"), None)
    if p is None:
        continue
    bev = mat.node_tree.nodes.new("ShaderNodeBevel")
    bev.inputs["Radius"].default_value = 0.015
    if p.inputs["Normal"].is_linked:
        mat.node_tree.links.new(p.inputs["Normal"].links[0].from_socket, bev.inputs["Normal"])
    mat.node_tree.links.new(bev.outputs["Normal"], p.inputs["Normal"])

# --- render settings
scene.render.resolution_x, scene.render.resolution_y = 1280, 720
scene.view_settings.view_transform = "AgX"
scene.view_settings.look = "AgX - Medium High Contrast"
scene.view_settings.exposure = 0.0
if ENGINE == "CYCLES":
    scene.render.engine = "CYCLES"
    prefs = bpy.context.preferences.addons["cycles"].preferences
    prefs.compute_device_type = "METAL"
    prefs.get_devices()
    for dev in prefs.devices:
        dev.use = True
    scene.cycles.device = "GPU"
    scene.cycles.samples = SAMPLES
    scene.cycles.use_denoising = True
    scene.cycles.max_bounces = 6
else:
    scene.render.engine = "BLENDER_EEVEE"
    scene.eevee.taa_render_samples = SAMPLES
    scene.eevee.use_shadows = True
    scene.eevee.use_raytracing = True
    scene.eevee.use_volumetric_shadows = False
if camjson:
    cj = json.load(open(os.path.join(camjson["dir"], "camera.json")))
    fr = cj["frames"]
    a, b = camjson["first"], camjson["last"]
    scene.render.resolution_x, scene.render.resolution_y = cj["width"], cj["height"]
    scene.render.resolution_percentage = camjson["scale"]
    scene.render.fps = cj["fps"]
    cam_data.angle = math.radians(cj["fov_y_deg"])
    cam.rotation_mode = "QUATERNION"
    qc = Quaternion((1.0, 0.0, 0.0), math.radians(90.0))  # Godot -> Blender; both cameras look down local -Z, Y up
    rot0 = wmap.inputs["Rotation"].default_value[2] - math.atan2(sun.y, -sun.x)  # sky yaw = rot0 + sun azimuth
    for f in range(a, b + 1):
        cam.location = g2b((fr["px"][f], fr["py"][f], fr["pz"][f]))
        cam.rotation_quaternion = qc @ Quaternion((fr["qw"][f], fr["qx"][f], fr["qy"][f], fr["qz"][f]))
        cam.keyframe_insert("location", frame=f)
        cam.keyframe_insert("rotation_quaternion", frame=f)
        sd = g2b((fr["sun_dx"][f], fr["sun_dy"][f], fr["sun_dz"][f]))  # Godot's sun follows the route heading
        sun_obj.rotation_euler = (-sd).to_track_quat("-Z", "Y").to_euler()
        sun_obj.keyframe_insert("rotation_euler", frame=f)
        wmap.inputs["Rotation"].default_value[2] = rot0 + math.atan2(sd.y, -sd.x)
        wmap.inputs["Rotation"].keyframe_insert("default_value", index=2, frame=f)
    scene.frame_start, scene.frame_end = a, b
    if ENGINE == "CYCLES":
        mid = (a + b) // 2
        dice = bpy.data.objects.new("dicing", cam_data)
        scene.collection.objects.link(dice)
        dice.location = g2b((fr["px"][mid], fr["py"][mid], fr["pz"][mid]))
        dice.rotation_mode = "QUATERNION"
        dice.rotation_quaternion = qc @ Quaternion((fr["qw"][mid], fr["qx"][mid], fr["qy"][mid], fr["qz"][mid]))
        scene.cycles.dicing_camera = dice
        scene.render.use_persistent_data = True
    os.makedirs(OUT, exist_ok=True)
    scene.render.filepath = os.path.join(OUT, "frame_#####")
    if blend_out:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend_out))
    bpy.ops.render.render(animation=True)
    print("rendered camera.json frames", a, "-", b, "to", OUT)
elif anim:
    # camera keyed every frame along the centre line (no head bob), looking 3 m ahead; dicing of the displaced rock is
    # done from one fixed camera so the tessellation does not change (and flicker) as the runner moves
    def at(s_, up_):
        j = min(int(s_), len(route["x"]) - 2)
        t_ = s_ - j
        lerp = lambda k_: route[k_][j] * (1 - t_) + route[k_][j + 1] * t_
        return g2b((lerp("x"), lerp("y") + up_, lerp("z")))
    fps, speed = anim["fps"], 1000.0 / (6.0 * 60.0)
    n = int(round(anim["seconds"] * fps))
    scene.render.fps = fps
    scene.frame_start, scene.frame_end = 1, n
    cam.rotation_mode = "QUATERNION"
    h = env["camera"]["height_m"]
    for f in range(1, n + 1):
        s_ = S_M + (f - 1) / fps * speed
        cam.location = at(s_, h)
        cam.rotation_quaternion = (at(s_ + 3.0, h) - cam.location).to_track_quat("-Z", "Y")
        cam.keyframe_insert("location", frame=f)
        cam.keyframe_insert("rotation_quaternion", frame=f)
    if ENGINE == "CYCLES":
        dice = bpy.data.objects.new("dicing", cam_data)
        scene.collection.objects.link(dice)
        mid = S_M + anim["seconds"] * speed * 0.5
        dice.location = at(mid, h)
        dice.rotation_euler = (at(mid + 3.0, h) - dice.location).to_track_quat("-Z", "Y").to_euler()
        scene.cycles.dicing_camera = dice
        scene.render.use_persistent_data = True
    if anim["first"]:
        scene.frame_start, scene.frame_end = anim["first"], anim["last"]
    os.makedirs(OUT, exist_ok=True)
    scene.render.filepath = os.path.join(OUT, "frame_####")
    if blend_out:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend_out))
    bpy.ops.render.render(animation=True)
    print("rendered frames", scene.frame_start, "-", scene.frame_end, "to", OUT)
else:
    scene.render.filepath = OUT
    if blend_out:
        bpy.ops.wm.save_as_mainfile(filepath=os.path.abspath(blend_out))
    bpy.ops.render.render(write_still=True)
    print("rendered", OUT)
