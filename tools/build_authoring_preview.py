#!/usr/bin/env python3
"""Build a provisional Godot authoring preview; never changes the canonical package."""
import argparse
import json
import math
import random
import shutil
from pathlib import Path

import route_model as rm
import vegetation


def read(path):
    return json.loads(Path(path).read_text())


def write(path, data):
    Path(path).write_text(json.dumps(data, ensure_ascii=False, indent=2) + "\n")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('config')
    args = parser.parse_args()
    cfg = read(args.config)
    dest = Path(cfg['output'])
    if dest.exists():
        raise SystemExit(f'Output already exists: {dest}; choose a new directory')
    shutil.copytree(cfg['near_package'], dest)
    man = read(dest / 'manifest.json')
    route = read(dest / 'route/route.json')
    # Empty semantics means only road and other traversals are excluded. The result is
    # explicitly visual authoring data, not a semantic or validated vegetation layer.
    space = vegetation.Space(str(dest), route, man, {'zones': []})
    rng = random.Random(cfg.get('seed', 42))
    model_dir = dest / 'preview_models'
    model_dir.mkdir()
    prototype_rows = []
    for proto, source in cfg['models'].items():
        model_config = source if isinstance(source, dict) else {'file': source}
        model = Path(model_config['file'])
        if model.suffix.lower() == '.gltf':
            # Keep glTF external buffers/textures; its first root is one asset variant.
            target_dir = model_dir / proto
            shutil.copytree(model.parent, target_dir, ignore=shutil.ignore_patterns('*.import'))
            model_json = read(target_dir / model.name)
            for scene in model_json.get('scenes', []):
                nodes = scene.get('nodes', [])
                selected = int(model_config.get('root_index', 0))
                if selected < 0 or selected >= len(nodes): raise ValueError(f'Invalid root index for {model}')
                scene['nodes'] = [nodes[selected]]
            write(target_dir / model.name, model_json)
            mesh_file = f'preview_models/{proto}/{model.name}'
        else:
            shutil.copy2(model, model_dir / model.name)
            mesh_file = 'preview_models/' + model.name
        license_file = model.parent / 'LICENSE'
        if license_file.exists(): shutil.copy2(license_file, model_dir / (proto + '_LICENSE'))
        prototype_rows.append({'id': proto, 'mesh_file': mesh_file})
    (dest / 'vegetation').mkdir(exist_ok=True)
    write(dest / 'vegetation/prototypes.json', {'prototypes': prototype_rows})
    totals = {}
    spacing_cell_m = 5.0
    tree_cells = {}
    def cell_for(x,z): return (math.floor(x/spacing_cell_m),math.floor(z/spacing_cell_m))
    avoid_ids = set(cfg.get('spacing_avoid_prototypes', []))
    preserved = set(cfg.get('preserved_existing_prototypes', [])) if cfg.get('preserve_vegetation_from') else set()
    if cfg.get('preserve_vegetation_from') and avoid_ids:
        for tile in man['tiles']:
            base = Path(cfg['preserve_vegetation_from']) / f"tiles/{tile['id']}/preview_vegetation.json"
            for group in read(base)['groups']:
                if group['proto'] not in avoid_ids: continue
                for i in range(group['count']):
                    x,_,z = group['data'][i*10:i*10+3]
                    tree_cells.setdefault(cell_for(x,z),[]).append((x,z))
    for tile in man['tiles']:
        groups = {proto: [] for proto in cfg['models']}
        stations = {proto: [] for proto in cfg['models']}
        offsets = {proto: [] for proto in cfg['models']}
        for zone in cfg['zones']:
            lo = max(tile['from_s'], zone['from_s'])
            hi = min(tile['to_s'], zone['to_s'])
            if lo >= hi: continue
            for proto, setting in zone['scatter'].items():
                if proto in preserved: continue
                for _ in range(round((hi-lo) * setting['per_m'])):
                    s = rng.uniform(lo, hi)
                    p = rm.sample(route, s)
                    u = rng.choice([-1, 1]) * rng.uniform(*setting['offset_m'])
                    category = setting.get('category', 'conifer' if proto == 'conifer' else 'grass')
                    if space.excluded(s, u, category, margin=0.1): continue
                    x, z = space.world_xz(s, u)
                    y = space.ground(s, u, x, z)
                    if y is None: continue
                    angle = rng.uniform(0, math.tau)
                    scale = rng.uniform(*setting['scale'])
                    axis_scale = setting.get('scale_xyz', [1, 1, 1])
                    radius = float(setting.get('crown_radius_m', 0.0)) * scale * max(axis_scale[0], axis_scale[2])
                    if radius:
                        if abs(u) < space.width(s,u) + radius + .3: continue
                        if space.road_corridors.contains_foreign(x,z,s,radius+.3): continue
                    spacing = float(setting.get('min_tree_spacing_m',0.0))
                    if spacing:
                        cell = cell_for(x,z)
                        reach = math.ceil(spacing/spacing_cell_m)
                        if any((x-a)**2+(z-b)**2 < spacing**2 for dx in range(-reach,reach+1) for dz in range(-reach,reach+1) for a,b in tree_cells.get((cell[0]+dx,cell[1]+dz),())): continue
                        tree_cells.setdefault(cell,[]).append((x,z))
                    stations[proto].append(round(s, 4))
                    offsets[proto].append(round(u, 4))
                    groups[proto].extend([round(x, 3), round(y-0.04, 3), round(z, 3), 0, math.sin(angle/2), 0, math.cos(angle/2), *[scale * v for v in axis_scale]])
        rows = [{'proto': p, 'count': len(a)//10, 'data': a, 's': stations[p], 'lateral_offset_m': offsets[p]} for p, a in groups.items() if a]
        if cfg.get('preserve_vegetation_from'):
            base = Path(cfg['preserve_vegetation_from']) / f"tiles/{tile['id']}/preview_vegetation.json"
            existing = [g for g in read(base)['groups'] if g['proto'] in preserved]
            rows = existing + [g for g in rows if g['proto'] not in preserved]
        for row in rows: totals[row['proto']] = totals.get(row['proto'], 0) + row['count']
        filename = f"tiles/{tile['id']}/preview_vegetation.json"
        write(dest / filename, {'groups': rows, 'source': 'estimated visual placement; not surveyed'})
        tile['files']['vegetation'] = filename
    write(dest / 'manifest.json', man)
    far = read(Path(cfg['far_terrain']) / 'stitch_manifest.json')
    distant = dest / 'preview_far'
    distant.mkdir()
    mesh_files = []
    for tile in far['tiles']:
        name = tile['file']
        shutil.copy2(Path(cfg['far_terrain']) / name, distant / name)
        mesh_files.append('preview_far/' + name)
    sidecar = {'load_all_tiles': True, 'complete_prototype_meshes': True, 'distant_preview_meshes': mesh_files, 'overrides': []}
    sidecar.update(cfg.get('preview_appearance', {}))
    write(str(dest) + '.godot_preview.json', sidecar)
    if sidecar.get('snow_pockets'):
        from build_preview_snow_uv import build as build_snow
        build_snow(dest, dest / 'preview_far_snow')
        sidecar['distant_preview_meshes'] = ['preview_far_snow/' + Path(f).name for f in mesh_files]
        write(str(dest) + '.godot_preview.json', sidecar)
    write(dest / 'PREVIEW_PROVENANCE.json', {'status': 'provisional authoring preview; not a validated scene package', 'config': cfg, 'vegetation_counts': totals, 'far_source': far['dem'], 'note': 'Route and grade are estimated; not suitable for fitness resistance or incline.'})
    if sidecar.get('shoulder_ground'):
        from add_preview_route_uv import add_uvs
        add_uvs(dest, include_roads=bool(sidecar.get('road_edge')), terrain_edge_distance=bool(sidecar.get('road_edge_natural')))
    if cfg.get('preview_bark'):
        from apply_preview_bark import apply_package
        apply_package(dest, cfg['preview_bark'])
    print('Preview created:', dest, totals, 'far meshes:', len(mesh_files))


if __name__ == '__main__':
    main()
