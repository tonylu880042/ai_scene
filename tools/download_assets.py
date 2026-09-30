#!/usr/bin/env python3
"""Download the CC0 Poly Haven assets the project uses into ./assets (run from the project root)."""
import json, os, urllib.request

def get(u):
    return urllib.request.urlopen(urllib.request.Request(u, headers={"User-Agent": "Mozilla/5.0"})).read()

def save(url, path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    open(path, "wb").write(get(url))

MODELS = ["island_tree_02", "grass_medium_01", "fern_02", "celandine_01", "periwinkle_plant",
          "dandelion_01", "boulder_01", "namaqualand_boulder_03", "dutch_ship_medium"]
TEXTURES = ["asphalt_02", "coast_sand_01", "aerial_grass_rock", "brown_planks_09",
            "beige_wall_001", "clay_roof_tiles", "rock_boulder_dry"]

for m in MODELS:
    g = json.loads(get(f"https://api.polyhaven.com/files/{m}"))["gltf"]["1k"]["gltf"]
    d = f"assets/models/{m}/"
    save(g["url"], d + os.path.basename(g["url"]))
    for rel, v in g["include"].items():
        save(v["url"], d + rel)
    print("model", m)
for t in TEXTURES:
    f = json.loads(get(f"https://api.polyhaven.com/files/{t}"))
    for key, suffix in [("Diffuse", "diff"), ("nor_gl", "nor"), ("Rough", "rough")]:
        save(f[key]["1k"]["jpg"]["url"], f"assets/textures/{t}_{suffix}.jpg")
    print("texture", t)
