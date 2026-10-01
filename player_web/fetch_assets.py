#!/usr/bin/env python3
"""Recreate player_web/assets/ (Quaternius CC0 characters + animations). Downloads only the files needed:
 - Universal Base Characters [Standard] (free, CC0) from itch.io via HTTP Range reads of the zip (no 122 MB download)
 - Universal Animation Library [Standard] glTF mirror (CC0) from GitHub
Usage: python3 player_web/fetch_assets.py
"""
import os, json, urllib.request, sys
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from itch_zip import ItchZip

HERE = os.path.dirname(os.path.abspath(__file__))
A = os.path.join(HERE, "assets")
os.makedirs(A + "/chars", exist_ok=True); os.makedirs(A + "/anim", exist_ok=True)

# --- animation library (glTF mirror of Quaternius' free Universal Animation Library) ---
RAW = "https://raw.githubusercontent.com/J-Ponzo/gltf-universal-animation-library/main/"
for src, dst in [("glTF/AnimationLibrary_Godot_Standard.gltf", "anim/AnimationLibrary_Godot_Standard.gltf"),
                 ("glTF/AnimationLibrary_Godot_Standard.bin", "anim/AnimationLibrary_Godot_Standard.bin"),
                 ("LICENSE", "anim/LICENSE_CC0.txt")]:
    if not os.path.exists(f"{A}/{dst}"):
        print("get", dst)
        open(f"{A}/{dst}", "wb").write(urllib.request.urlopen(RAW + src).read())

# --- base characters ---
z = ItchZip("https://quaternius.itch.io/universal-base-characters")
P = "Universal Base Characters[Standard]/"
GE = P + "Base Characters/Godot - UE/"
HG = P + "Hairstyles/Origin at 0/glTF (Godot)/"
TX = P + "Base Characters/Textures/"
files = {  # zip path -> local name
    GE + "Superhero_Male_FullBody.gltf": None, GE + "Superhero_Male_FullBody.bin": None,
    GE + "Superhero_Female_FullBody.gltf": None, GE + "Superhero_Female_FullBody.bin": None,
    GE + "T_Superhero_Male_Dark.png": None, GE + "T_Superhero_Male_Normal.png": None, GE + "T_Superhero_Male_Roughness.png": None,
    GE + "T_Superhero_Female_Dark_BaseColor.png": None, GE + "T_Superhero_Female_Normal.png": None, GE + "T_Superhero_Female_Roughness.png": None,
    GE + "T_Eye_Brown.png": None, GE + "T_Eye_Normal.png": None,
    TX + "T_Superhero_Male_Ligh.png": "T_Superhero_Male_Light.png",
    TX + "T_Superhero_Female_Light_BaseColor.png": None,
    HG + "T_Hair_1_BaseColor.png": None, HG + "T_Hair_1_Normal.png": None,
    HG + "T_Hair_2_BaseColor.png": None, HG + "T_Hair_2_Normal.png": None,
    P + "License_Standard.txt": "License_Standard.txt",
}
for h in ["Hair_Buzzed", "Hair_SimpleParted", "Hair_Beard", "Hair_Long", "Hair_Buns", "Hair_BuzzedFemale"]:
    files[HG + h + ".gltf"] = None; files[HG + h + ".bin"] = None
for k, name in files.items():
    name = name or os.path.basename(k)
    if not os.path.exists(f"{A}/chars/{name}"):
        print("get", name)
        open(f"{A}/chars/{name}", "wb").write(z.read(k))

# the glTFs reference a couple of texture names that are not in the pack: map to the files that are
FIX = {"T_Hair_1_Normal_png.png": "T_Hair_1_Normal.png", "T_Eye_Normal_png.png": "T_Eye_Normal.png"}
for f in os.listdir(A + "/chars"):
    if f.endswith(".gltf"):
        p = f"{A}/chars/{f}"; d = json.load(open(p))
        for im in d.get("images", []): im["uri"] = FIX.get(im["uri"], im["uri"])
        json.dump(d, open(p, "w"))
print("done")
