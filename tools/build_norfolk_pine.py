#!/usr/bin/env python3
"""Procedural Norfolk Island pine (Araucaria heterophylla) for the preview prototype library.
Tiered whorls of 6 near-horizontal branches carrying alpha-cut frond pads, on a straight tapered trunk.
No reference pixels: the frond texture is drawn here, the bark is the CC0 Poly Haven pine_bark set.
  python3 tools/build_norfolk_pine.py [out_dir]     (default assets/models/norfolk_pine; needs Blender.app)
The same file runs inside Blender (`blender -b --python tools/build_norfolk_pine.py -- <out_dir>`) to build the mesh.
"""
import math
import random
import sys
from pathlib import Path

HEIGHT_M = 21.8  # matches the package prototype; the adapter refits to the package mesh anyway
SEED = 7


def frond_texture(path, size=512):
    """A feather-like branch tip along +u: central rachis, angled branchlets densely clothed in short needles."""
    from PIL import Image, ImageDraw
    rng = random.Random(SEED)
    image = Image.new("RGBA", (size, size), (34, 62, 34, 0))
    draw = ImageDraw.Draw(image)
    mid = size / 2
    for i in range(46):
        x0 = size * (0.02 + 0.94 * i / 46)
        for side in (-1, 1):
            reach = mid * (0.92 - 0.45 * x0 / size) * rng.uniform(0.8, 1.0)
            angle = math.radians(rng.uniform(38, 55))
            x1, y1 = x0 + reach * math.cos(angle), mid + side * reach * math.sin(angle)
            for k in range(14):  # needles along the branchlet
                t = k / 13
                px, py = x0 + (x1 - x0) * t, mid + (y1 - mid) * t
                for needle_side in (-1, 1):
                    n_angle = angle * side + needle_side * math.radians(rng.uniform(50, 70))
                    length = size * 0.036 * (1.0 - 0.4 * t)
                    shade = rng.uniform(0.75, 1.25)
                    colour = (int(36 * shade), int(70 * shade), int(36 * shade), 255)
                    draw.line([(px, py), (px + length * math.cos(n_angle), py + length * math.sin(n_angle))], fill=colour, width=4)
            draw.line([(x0, mid), (x1, y1)], fill=(52, 66, 34, 255), width=4)
    draw.line([(0, mid), (size, mid)], fill=(70, 58, 38, 255), width=7)
    image.save(path)


def build_mesh(out_dir):
    import bpy
    import bmesh
    from mathutils import Vector
    rng = random.Random(SEED)
    bpy.ops.wm.read_factory_settings(use_empty=True)

    def material(name, texture, alpha):
        mat = bpy.data.materials.new(name)
        mat.use_nodes = True
        bsdf = mat.node_tree.nodes["Principled BSDF"]
        node = mat.node_tree.nodes.new("ShaderNodeTexImage")
        node.image = bpy.data.images.load(str(texture))
        mat.node_tree.links.new(node.outputs["Color"], bsdf.inputs["Base Color"])
        if alpha: mat.node_tree.links.new(node.outputs["Alpha"], bsdf.inputs["Alpha"])
        bsdf.inputs["Roughness"].default_value = 0.85
        return mat

    mesh = bpy.data.meshes.new("norfolk_pine")
    obj = bpy.data.objects.new("norfolk_pine", mesh)
    bpy.context.collection.objects.link(obj)
    obj.data.materials.append(material("norfolk_bark", out_dir / "norfolk_bark.jpg", False))
    obj.data.materials.append(material("norfolk_frond", out_dir / "norfolk_frond.png", True))
    bm = bmesh.new()
    uv = bm.loops.layers.uv.new()

    def quad(points, uvs, mat_index):
        face = bm.faces.new([bm.verts.new(p) for p in points])
        face.material_index = mat_index
        for loop, coord in zip(face.loops, uvs): loop[uv].uv = coord

    # Trunk: 8-sided tapered cylinder, bark tiled every 2 m.
    sides, rings = 8, 12
    radius = lambda z: 0.34 * (1 - z / HEIGHT_M) ** 0.8 + 0.03
    for j in range(rings):
        z0, z1 = HEIGHT_M * j / rings, HEIGHT_M * (j + 1) / rings
        for i in range(sides):
            a0, a1 = 2 * math.pi * i / sides, 2 * math.pi * (i + 1) / sides
            ring = lambda a, z: Vector((radius(z) * math.cos(a), radius(z) * math.sin(a), z))
            quad([ring(a0, z0), ring(a1, z0), ring(a1, z1), ring(a0, z1)],
                 [(i / sides * 2, z0 / 2), ((i + 1) / sides * 2, z0 / 2), ((i + 1) / sides * 2, z1 / 2), (i / sides * 2, z1 / 2)], 0)

    # Whorls from 28 % of the height to the top, ~0.8 m apart, 6 branches each, golden-angle offset per tier.
    z = HEIGHT_M * 0.28
    tier = 0
    while z < HEIGHT_M * 0.97:
        rise = (z - HEIGHT_M * 0.28) / (HEIGHT_M * 0.69)  # 0 at the lowest whorl, 1 at the top
        length = (5.6 * (1 - rise) ** 0.85 + 0.35) * rng.uniform(0.88, 1.08)
        elevation = math.radians(-10 + 30 * rise)  # lower branches droop, upper ones sweep up
        for b in range(6):
            heading = tier * 2.39996 + b * 2 * math.pi / 6 + rng.uniform(-0.15, 0.15)
            out = Vector((math.cos(heading), math.sin(heading), 0))
            side = Vector((-out.y, out.x, 0))
            def along(t):
                return Vector((0, 0, z)) + out * (length * t * math.cos(elevation)) + Vector((0, 0, length * t * math.sin(elevation) + 0.12 * length * t * t))
            width = max(0.5, min(2.3, 0.52 * length))
            steps = 4
            for k in range(steps):
                t0, t1 = 0.05 + 0.95 * k / steps, 0.05 + 0.95 * (k + 1) / steps
                w0, w1 = width * (1 - 0.55 * t0), width * (1 - 0.55 * t1)
                droop0, droop1 = Vector((0, 0, -0.18 * w0)), Vector((0, 0, -0.18 * w1))  # pad edges hang slightly
                # Flat pad (the tiered look) and a narrow vertical pad (volume from the side).
                quad([along(t0) - side * w0 / 2 + droop0, along(t1) - side * w1 / 2 + droop1, along(t1) + side * w1 / 2 + droop1, along(t0) + side * w0 / 2 + droop0],
                     [(t0, 0.5 - w0 / width / 2), (t1, 0.5 - w1 / width / 2), (t1, 0.5 + w1 / width / 2), (t0, 0.5 + w0 / width / 2)], 1)
                up0, up1 = Vector((0, 0, w0 * 0.38)), Vector((0, 0, w1 * 0.38))
                quad([along(t0) - up0, along(t1) - up1, along(t1) + up1, along(t0) + up0],
                     [(t0, 0.28), (t1, 0.28), (t1, 0.72), (t0, 0.72)], 1)
        z += rng.uniform(0.7, 0.95)
        tier += 1
    bm.to_mesh(mesh)
    bm.free()
    print("NORFOLK_PINE_TRIS", sum(len(p.vertices) - 2 for p in mesh.polygons), "dims", tuple(round(d, 2) for d in obj.dimensions))
    bpy.ops.export_scene.gltf(filepath=str(out_dir / "norfolk_pine_raw.glb"), export_format="GLB", export_yup=True)


def finish_glb(raw, out):
    """Blender exports alpha as BLEND; foliage needs MASK (no sorting) and both materials double-sided."""
    import json
    import struct
    data = raw.read_bytes()
    n = struct.unpack("<I", data[12:16])[0]
    gltf = json.loads(data[20:20 + n])
    for m in gltf["materials"]:
        m["doubleSided"] = True
        if m["name"] == "norfolk_frond":
            m["alphaMode"], m["alphaCutoff"] = "MASK", 0.4
    js = json.dumps(gltf, separators=(",", ":")).encode()
    js += b" " * ((4 - len(js) % 4) % 4)
    body = struct.pack("<II", len(js), 0x4E4F534A) + js + data[20 + n:]
    out.write_bytes(struct.pack("<III", 0x46546C67, 2, 12 + len(body)) + body)
    raw.unlink()


if __name__ == "__main__":
    try:
        import bpy  # noqa: F401  (inside Blender)
        build_mesh(Path(sys.argv[sys.argv.index("--") + 1]))
    except ImportError:
        import subprocess
        from PIL import Image
        root = Path(__file__).resolve().parent.parent
        out_dir = Path(sys.argv[1]) if len(sys.argv) > 1 else root / "assets/models/norfolk_pine"
        out_dir.mkdir(parents=True, exist_ok=True)
        frond_texture(out_dir / "norfolk_frond.png")
        Image.open(root / "assets/textures/pine_bark_diff.jpg").convert("RGB").resize((512, 512)).save(out_dir / "norfolk_bark.jpg", quality=90)
        blender = "/Applications/Blender.app/Contents/MacOS/Blender"
        subprocess.run([blender, "-b", "--python", __file__, "--", str(out_dir)], check=True)
        finish_glb(out_dir / "norfolk_pine_raw.glb", out_dir / "norfolk_pine.glb")
        print("wrote", out_dir / "norfolk_pine.glb")
