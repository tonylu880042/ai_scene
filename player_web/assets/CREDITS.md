# Asset credits

All avatar assets are by **Quaternius** and released under **CC0 1.0 Universal** (public domain; commercial use allowed, no attribution required - credited here anyway).

| Asset | Used for | Source | License |
|---|---|---|---|
| Universal Base Characters [Standard] (free version): `Superhero_Male_FullBody`, `Superhero_Female_FullBody` glTF + textures (dark/light skin, normal, roughness, eyes) and hair meshes `Hair_Buzzed`, `Hair_SimpleParted`, `Hair_Beard`, `Hair_Long`, `Hair_Buns`, `Hair_BuzzedFemale` (+ hair textures) | the runners | https://quaternius.com/packs/universalbasecharacters.html (downloaded from https://quaternius.itch.io/universal-base-characters, file "Universal Base Characters[Standard].zip") | CC0 1.0 - https://creativecommons.org/publicdomain/zero/1.0/ (`chars/License_Standard.txt`) |
| Universal Animation Library [Standard] (free version), `Jog_Fwd_Loop` clip only is used (glTF mirror) | run animation, retargeted at load time onto the base characters (`retarget.js`) | https://quaternius.com/packs/universalanimationlibrary.html ; glTF-only mirror https://github.com/J-Ponzo/gltf-universal-animation-library (`glTF/AnimationLibrary_Godot_Standard.gltf/.bin`) | CC0 1.0 (`anim/LICENSE_CC0.txt`) |

Modifications: the clip is retargeted to the base characters' bone names at runtime; skin tone is switched between the supplied light/dark textures;
hair is tinted; the short-sleeve top / shorts / socks / shoes colours are painted in a shader (`avatars.js`) over the supplied underwear-only body texture.

Three.js (MIT, https://threejs.org) is loaded from the jsDelivr CDN (`three@0.170.0`).

Microsoft Rocketbox (MIT) was NOT used (stretch goal not attempted, see README).

The files in `assets/` are recreated by `../fetch_assets.py`.

## Realistic avatars (default; `?avatars=quaternius` switches back)

| Asset | Used for | Source | License |
|---|---|---|---|
| Microsoft Rocketbox avatars `Sports_Female_02`, `Sports_Male_02`, `Sports_Male_04`, `Female_Party_02` (FBX + body/head colour & normal textures, downscaled to 1024 px) | the runners | https://github.com/microsoft/Microsoft-Rocketbox (`Assets/Avatars/...`) | MIT - Copyright (c) 2020 Microsoft; full text in `rocketbox/LICENSE_Rocketbox_MIT.md` (must ship with the app) |
| Rocketbox animations `m_run_neutral`, `f_run_neutral` | run cycle (root motion removed, in place) | same repo, `Assets/Animations/all_animations_max_motextr_xy/` | MIT |

Converted FBX -> GLB with `tools/rocketbox_to_glb.gd` (Godot 4.7 headless).
