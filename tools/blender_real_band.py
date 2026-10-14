"""Real mountains for tools/blender_scene.py (--real-shore <assets/terrain/<dem>_shore.json>).

Same mapping as route.gd real_shore: route offset s and distance d inland -> the real point d metres inland of the
real shoreline at s (tools/real_shore.py), height = lake level at s (route.json water_y) + DEM height above the lake.
Built here much denser than in Godot (4 m near the path, 25 m far out) with the orthophoto as an image texture, crag
displacement on bare rock (Cycles adaptive subdivision) and shrubs scattered where the photo is green. The Godot
terrain is cut back to CUT_M from the path so the two do not overlap.
"""
import bpy, bmesh, json, math, os
import numpy as np
from mathutils import Vector, kdtree

CUT_M = 115.0


def _smooth(x0, x1, x):
    t = np.clip((x - x0) / (x1 - x0), 0.0, 1.0)
    return t * t * (3.0 - 2.0 * t)


def cut_godot_terrain(objs, route, s_from, s_to):
    """Delete vertices farther than CUT_M from the route centre line (Godot's coarse far terrain)."""
    tree = kdtree.KDTree(int(s_to - s_from) + 1)
    for n, s in enumerate(range(int(s_from), int(s_to) + 1)):
        tree.insert((route["x"][s], -route["z"][s], 0.0), n)
    tree.balance()
    for o in objs:
        if o.type != "MESH" or max(o.dimensions) < 300.0:  # only the big terrain ribbons
            continue
        bm = bmesh.new()
        bm.from_mesh(o.data)
        mw = o.matrix_world
        far = [v for v in bm.verts if tree.find(((mw @ v.co).x, (mw @ v.co).y, 0.0))[2] > CUT_M]
        bmesh.ops.delete(bm, geom=far, context="VERTS")
        bm.to_mesh(o.data)
        bm.free()
        print("cut", o.name, "removed", len(far), "verts")


def build(shore_path, route, env, s_from, s_to, shrub_objs):
    sh = json.load(open(shore_path))
    tdir = os.path.dirname(shore_path)
    meta = json.load(open(os.path.join(tdir, sh["dem"] + ".json")))
    g, size = meta["grid"], meta["size_m"]
    H = np.fromfile(os.path.join(tdir, sh["dem"] + "_h.f32"), "<f4").reshape(g, g)
    P, N = np.array(sh["points"]), np.array(sh["normals"])
    rx, ry, rz = (np.array(route[k]) for k in ("x", "y", "z"))
    wy = np.array(route["water_y"])
    S = np.arange(max(s_from, 0.0), min(s_to, len(rx) - 3), 3.0)
    D = np.concatenate([np.arange(100.0, 400.0, 4.0), np.arange(400.0, 1200.0, 10.0), np.arange(1200.0, 3201.0, 25.0)])
    i = S.astype(int)
    f = S - i
    px, pz = rx[i] * (1 - f) + rx[i + 1] * f, rz[i] * (1 - f) + rz[i + 1] * f
    fx, fz = rx[i + 2] - rx[i], rz[i + 2] - rz[i]
    nrm = np.hypot(fx, fz)
    fx, fz = fx / nrm, fz / nrm
    sgn = 1.0 if env.get("sea_side", "left") == "right" else -1.0
    ix, iz = sgn * fz, -sgn * fx  # inland, Godot x/z
    # real shore point and inland normal for each route offset
    k = np.clip(S / sh["step"], 0, len(P) - 1.001)
    k0 = k.astype(int)
    kt = (k - k0)[:, None]
    sp = P[k0] * (1 - kt) + P[k0 + 1] * kt
    sn = N[k0] * (1 - kt) + N[k0 + 1] * kt
    sn /= np.linalg.norm(sn, axis=1, keepdims=True)
    real = sp[:, None, :] + sn[:, None, :] * D[None, :, None]           # (S, D, 2) DEM-local metres
    step = size / (g - 1)
    c = np.clip(real[..., 0] / step + (g - 1) / 2, 0, g - 1.001)
    r = np.clip(real[..., 1] / step + (g - 1) / 2, 0, g - 1.001)
    c0, r0 = c.astype(int), r.astype(int)
    fc, fr = c - c0, r - r0
    h = (H[r0, c0] * (1 - fc) + H[r0, c0 + 1] * fc) * (1 - fr) + (H[r0 + 1, c0] * (1 - fc) + H[r0 + 1, c0 + 1] * fc) * fr
    height = wy[i][:, None] + np.maximum(h - sh["lake_m"], 0.0)
    gx = px[:, None] + ix[:, None] * D[None, :]
    gz = pz[:, None] + iz[:, None] * D[None, :]
    u = real[..., 0] / size + 0.5
    v = 1.0 - (real[..., 1] / size + 0.5)                                  # image row 0 is north (z negative)
    ns, nd = len(S), len(D)
    verts = np.stack([gx, -gz, height], -1).reshape(-1, 3)                # Godot -> Blender
    a = (np.arange(ns - 1)[:, None] * nd + np.arange(nd - 1)[None, :]).reshape(-1)
    faces = np.stack([a, a + 1, a + nd + 1, a + nd], 1)
    me = bpy.data.meshes.new("real_mountains")
    me.from_pydata(verts.tolist(), [], faces.tolist())
    uvl = me.uv_layers.new(name="UVMap")
    loop_v = np.zeros(len(me.loops), int)
    me.loops.foreach_get("vertex_index", loop_v)
    uv = np.stack([u.reshape(-1), v.reshape(-1)], 1)[loop_v]
    uvl.data.foreach_set("uv", uv.reshape(-1))
    # vegetation weight per vertex from the photo (green and dark = scrub / forest), for the shrub scatter
    img_path = os.path.join(tdir, sh["dem"] + "_albedo.jpg")
    img = bpy.data.images.load(img_path)
    w_, h_ = img.size
    pix = np.array(img.pixels[:]).reshape(h_, w_, 4)                      # Blender pixels: row 0 at the bottom
    pxi = np.clip((u * w_).astype(int), 0, w_ - 1)
    pyi = np.clip((v * h_).astype(int), 0, h_ - 1)
    col = pix[pyi, pxi, :3]
    lum = col @ np.array([0.2126, 0.7152, 0.0722])
    green = col[..., 1] - (col[..., 0] + col[..., 2]) * 0.5
    veg = (_smooth(0.0, 0.03, green) * (1.0 - _smooth(0.25, 0.4, lum)) * (1.0 - _smooth(500.0, 700.0, D)[None, :]))
    attr = me.attributes.new("veg", "FLOAT", "POINT")
    attr.data.foreach_set("value", veg.reshape(-1).astype(np.float32))
    me.update()
    obj = bpy.data.objects.new("real_mountains", me)
    bpy.context.scene.collection.objects.link(obj)
    for p in me.polygons:
        p.use_smooth = True
    obj.data.materials.append(_material(img))
    if shrub_objs:
        _scatter(obj, shrub_objs)
    _adaptive(obj)
    print("real mountains:", len(verts), "verts")
    return obj


def _material(img):
    m = bpy.data.materials.new("real_mountains")
    m.use_nodes = True
    nt = m.node_tree
    nodes, links = nt.nodes, nt.links
    bsdf = nodes["Principled BSDF"]
    tex = nodes.new("ShaderNodeTexImage")
    tex.image = img
    tex.interpolation = "Cubic"
    # bare rock where the photo is pale and not green
    sep = nodes.new("ShaderNodeSeparateColor")
    links.new(tex.outputs["Color"], sep.inputs["Color"])
    lum = nodes.new("ShaderNodeRGBToBW")
    links.new(tex.outputs["Color"], lum.inputs["Color"])
    rock = nodes.new("ShaderNodeMapRange")
    rock.inputs["From Min"].default_value = 0.24
    rock.inputs["From Max"].default_value = 0.42
    links.new(lum.outputs["Val"], rock.inputs["Value"])
    # crags: cellular rock blocks + finer noise, strongest on bare rock
    coord = nodes.new("ShaderNodeTexCoord")
    vor = nodes.new("ShaderNodeTexVoronoi")
    vor.inputs["Scale"].default_value = 0.06
    vor.feature = "F1"
    links.new(coord.outputs["Object"], vor.inputs["Vector"])
    noi = nodes.new("ShaderNodeTexNoise")
    noi.inputs["Scale"].default_value = 0.25
    noi.inputs["Detail"].default_value = 10.0
    noi.inputs["Roughness"].default_value = 0.65
    links.new(coord.outputs["Object"], noi.inputs["Vector"])
    crag = nodes.new("ShaderNodeMath")
    crag.operation = "MULTIPLY_ADD"
    links.new(vor.outputs["Distance"], crag.inputs[0])
    crag.inputs[1].default_value = 1.0
    links.new(noi.outputs["Fac"], crag.inputs[2])
    amount = nodes.new("ShaderNodeMath")
    amount.operation = "MULTIPLY_ADD"
    links.new(rock.outputs["Result"], amount.inputs[0])
    amount.inputs[1].default_value = 5.0   # metres of relief on bare rock
    amount.inputs[2].default_value = 1.2   # ... and on vegetated slopes
    hgt = nodes.new("ShaderNodeMath")
    hgt.operation = "MULTIPLY"
    links.new(crag.outputs["Value"], hgt.inputs[0])
    links.new(amount.outputs["Value"], hgt.inputs[1])
    disp = nodes.new("ShaderNodeDisplacement")
    disp.inputs["Midlevel"].default_value = 1.0  # about the average crag height: the surface moves both ways
    links.new(hgt.outputs["Value"], disp.inputs["Height"])
    links.new(disp.outputs["Displacement"], nodes["Material Output"].inputs["Displacement"])
    # colour: the photo, a little brighter and varied by the fine noise (rock grain, scrub clumps)
    var = nodes.new("ShaderNodeMix")
    var.data_type = "RGBA"
    var.blend_type = "MULTIPLY"
    var.inputs["Factor"].default_value = 0.35
    links.new(tex.outputs["Color"], var.inputs["A"])
    links.new(noi.outputs["Color"], var.inputs["B"])
    gain = nodes.new("ShaderNodeMix")
    gain.data_type = "RGBA"
    gain.blend_type = "MULTIPLY"
    gain.inputs["Factor"].default_value = 1.0
    links.new(var.outputs["Result"], gain.inputs["A"])
    gain.inputs["B"].default_value = (1.5, 1.5, 1.45, 1.0)
    links.new(gain.outputs["Result"], bsdf.inputs["Base Color"])
    bsdf.inputs["Roughness"].default_value = 0.9
    try:
        m.displacement_method = "BOTH"
    except AttributeError:
        m.cycles.displacement_method = "BOTH"
    return m


def _adaptive(obj):
    """Cycles adaptive subdivision so the displacement has vertices to move (falls back to plain bump)."""
    mod = obj.modifiers.new("subdiv", "SUBSURF")
    mod.subdivision_type = "SIMPLE"
    mod.levels = 0
    mod.render_levels = 4
    for owner, attr in ((mod, "use_adaptive_subdivision"), (getattr(obj, "cycles", None), "use_adaptive_subdivision")):
        if owner is not None and hasattr(owner, attr):
            try:
                bpy.context.scene.cycles.feature_set = "EXPERIMENTAL"
            except Exception:
                pass
            setattr(owner, attr, True)
            print("adaptive subdivision on via", type(owner).__name__)
            return
    print("adaptive subdivision not available; using", mod.render_levels, "render levels")


def _scatter(obj, shrub_objs):
    """Geometry-nodes scatter of the exported shrub prototypes on a separate object (the mountain's own modifier stack
    must end with the adaptive subdivision), density from the 'veg' attribute."""
    col = bpy.data.collections.new("scrub_src")  # not linked to the scene: only instanced
    for o in shrub_objs:
        col.objects.link(bpy.data.objects.new("src_" + o.name, o.data))
    ng = bpy.data.node_groups.new("scrub", "GeometryNodeTree")
    ng.interface.new_socket("Geometry", in_out="INPUT", socket_type="NodeSocketGeometry")
    ng.interface.new_socket("Geometry", in_out="OUTPUT", socket_type="NodeSocketGeometry")
    n, l = ng.nodes, ng.links
    gi, go = n.new("NodeGroupInput"), n.new("NodeGroupOutput")
    oi = n.new("GeometryNodeObjectInfo")
    oi.inputs["Object"].default_value = obj
    attr = n.new("GeometryNodeInputNamedAttribute")
    attr.data_type = "FLOAT"
    attr.inputs["Name"].default_value = "veg"
    dens = n.new("ShaderNodeMath")
    dens.operation = "MULTIPLY"
    dens.inputs[1].default_value = 0.012  # shrubs per square metre on fully green slopes
    l.new(attr.outputs["Attribute"], dens.inputs[0])
    dist = n.new("GeometryNodeDistributePointsOnFaces")
    l.new(oi.outputs["Geometry"], dist.inputs["Mesh"])
    l.new(dens.outputs["Value"], dist.inputs["Density"])
    ci = n.new("GeometryNodeCollectionInfo")
    ci.inputs["Collection"].default_value = col
    ci.inputs["Separate Children"].default_value = True
    ci.inputs["Reset Children"].default_value = True
    inst = n.new("GeometryNodeInstanceOnPoints")
    inst.inputs["Pick Instance"].default_value = True
    l.new(dist.outputs["Points"], inst.inputs["Points"])
    l.new(ci.outputs["Instances"], inst.inputs["Instance"])
    rot = n.new("FunctionNodeRandomValue")
    rot.data_type = "FLOAT_VECTOR"
    rot.inputs["Max"].default_value = (0.0, 0.0, 6.283)
    l.new(rot.outputs["Value"], inst.inputs["Rotation"])
    scl = n.new("FunctionNodeRandomValue")
    scl.data_type = "FLOAT"
    scl.inputs["Min"].default_value = 2.0
    scl.inputs["Max"].default_value = 5.0
    l.new(scl.outputs["Value"], inst.inputs["Scale"])
    l.new(inst.outputs["Instances"], go.inputs[0])
    holder = bpy.data.objects.new("scrub", bpy.data.meshes.new("scrub"))
    bpy.context.scene.collection.objects.link(holder)
    mod = holder.modifiers.new("scrub", "NODES")
    mod.node_group = ng


# --- the opposite shore: a high-resolution DEM patch placed in the coarse backdrop's own frame ---------------------
# Same placement as Godot's RealTerrain (MainScene_garda.tscn): height = DEM - backdrop centre altitude + HEIGHT_OFFSET,
# everything west of SINK_WEST_OF (measured across the lake axis SINK_AXIS_DEG) sunk - route.gd real_shore owns that side.
HEIGHT_OFFSET, SINK_WEST_OF, SINK_AXIS_DEG = -1.5, -900.0, 27.0


def east_patch(patch_json, backdrop_obj):
    tdir = os.path.dirname(patch_json)
    pm = json.load(open(patch_json))
    bm_ = json.load(open(os.path.join(tdir, "garda.json")))  # the coarse backdrop exported from Godot
    g, size = pm["grid"], pm["size_m"]
    H = np.fromfile(os.path.join(tdir, pm["name"] + "_h.f32"), "<f4").reshape(g, g)
    lat0 = math.radians(bm_["lat"])
    dx = (pm["lon"] - bm_["lon"]) * math.cos(lat0) * 111320.0   # patch centre in the backdrop's DEM frame (x east)
    dz = -(pm["lat"] - bm_["lat"]) * 111320.0                    # (z south)
    step = size / (g - 1)
    ax = (np.arange(g) - (g - 1) / 2) * step
    X = dx + ax[None, :].repeat(g, 0)
    Z = dz + ax[:, None].repeat(g, 1)
    a = math.radians(SINK_AXIS_DEG)
    keep_side = _smooth(SINK_WEST_OF - 300.0, SINK_WEST_OF, X * math.cos(a) + Z * math.sin(a))
    Y = np.where(keep_side > 0.0, (H - bm_["centre_m"] + HEIGHT_OFFSET) * keep_side + (-600.0) * (1 - keep_side), -600.0)
    verts = np.stack([X, -Z, Y], -1).reshape(-1, 3)                 # Godot local -> Blender local
    q = (np.arange(g - 1)[:, None] * g + np.arange(g - 1)[None, :]).reshape(-1)
    faces = np.stack([q, q + 1, q + g + 1, q + g], 1)
    above = (Y.reshape(-1) > -1.0)
    faces = faces[above[faces].any(1)]                               # drop the lake floor and the sunk west side
    me = bpy.data.meshes.new("east_shore")
    me.from_pydata(verts.tolist(), [], faces.tolist())
    uvl = me.uv_layers.new(name="UVMap")
    lv = np.zeros(len(me.loops), int)
    me.loops.foreach_get("vertex_index", lv)
    u = (np.arange(g) / (g - 1))[None, :].repeat(g, 0).reshape(-1)
    v = 1.0 - (np.arange(g) / (g - 1))[:, None].repeat(g, 1).reshape(-1)
    uvl.data.foreach_set("uv", np.stack([u, v], 1)[lv].reshape(-1))
    for p in me.polygons:
        p.use_smooth = True
    me.update()
    obj = bpy.data.objects.new("east_shore", me)
    bpy.context.scene.collection.objects.link(obj)
    obj.matrix_world = backdrop_obj.matrix_world.copy()
    obj.data.materials.append(_photo_material(os.path.join(tdir, pm["name"] + "_albedo.jpg")))
    # cut the coarse backdrop where the patch covers it
    bm = bmesh.new()
    bm.from_mesh(backdrop_obj.data)
    half = size / 2 - 50.0
    inside = [vv for vv in bm.verts if abs(vv.co.x - dx) < half and abs(-vv.co.y - dz) < half]
    bmesh.ops.delete(bm, geom=inside, context="VERTS")
    bm.to_mesh(backdrop_obj.data)
    bm.free()
    print("east shore:", len(me.vertices), "verts,", len(faces), "faces; backdrop cut", len(inside))
    return obj


def _photo_material(path):
    m = bpy.data.materials.new("east_shore")
    m.use_nodes = True
    nt = m.node_tree
    bsdf = nt.nodes["Principled BSDF"]
    tex = nt.nodes.new("ShaderNodeTexImage")
    tex.image = bpy.data.images.load(path)
    tex.interpolation = "Cubic"
    # late-autumn grade (the reference was filmed in November; the imagery is summer): forest -> muted purple-brown,
    # bare limestone -> near white, with contrast so the pale gullies and strata stand out as in the video
    bw = nt.nodes.new("ShaderNodeRGBToBW")
    nt.links.new(tex.outputs["Color"], bw.inputs["Color"])
    rng = nt.nodes.new("ShaderNodeMapRange")
    rng.inputs["From Min"].default_value = 0.04  # linear luminance: forest ~0.02, bare limestone 0.08+
    rng.inputs["From Max"].default_value = 0.22
    nt.links.new(bw.outputs["Val"], rng.inputs["Value"])
    ramp = nt.nodes.new("ShaderNodeValToRGB")
    ramp.color_ramp.elements[0].color = (0.033, 0.019, 0.024, 1.0)  # linear values (sRGB ~0.20 0.15 0.17)
    ramp.color_ramp.elements[1].position = 0.75
    ramp.color_ramp.elements[1].color = (0.69, 0.66, 0.6, 1.0)
    mid = ramp.color_ramp.elements.new(0.35)
    mid.color = (0.107, 0.064, 0.06, 1.0)
    nt.links.new(rng.outputs["Result"], ramp.inputs["Fac"])
    keep = nt.nodes.new("ShaderNodeMix")
    keep.data_type = "RGBA"
    keep.inputs["Factor"].default_value = 0.15  # a little of the photo's own hue
    nt.links.new(ramp.outputs["Color"], keep.inputs["A"])
    nt.links.new(tex.outputs["Color"], keep.inputs["B"])
    nt.links.new(keep.outputs["Result"], bsdf.inputs["Base Color"])
    co = nt.nodes.new("ShaderNodeTexCoord")
    noi = nt.nodes.new("ShaderNodeTexNoise")
    noi.inputs["Scale"].default_value = 0.08
    noi.inputs["Detail"].default_value = 12.0
    nt.links.new(co.outputs["Object"], noi.inputs["Vector"])
    bump = nt.nodes.new("ShaderNodeBump")
    bump.inputs["Strength"].default_value = 0.4
    bump.inputs["Distance"].default_value = 4.0
    nt.links.new(noi.outputs["Fac"], bump.inputs["Height"])
    nt.links.new(bump.outputs["Normal"], bsdf.inputs["Normal"])
    bsdf.inputs["Roughness"].default_value = 0.92
    return m
