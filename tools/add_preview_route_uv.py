#!/usr/bin/env python3
"""Add route-relative UV2 to copied preview terrain without changing its geometry."""
import argparse
import json
from pathlib import Path
import road_terrain as rt
import route_model as rm


def add_uvs(package, include_roads=False, terrain_edge_distance=False):
    package = Path(package)
    manifest_path = package/'manifest.json'
    manifest = json.loads(manifest_path.read_text())
    route = json.loads((package/'route/route.json').read_text())
    def width_at(s,u):
        point = rm.sample(route, s)
        return point['width_left_m'] if u >= 0 else point['width_right_m']
    for tile in manifest['tiles']:
        source = package/tile['files']['terrain']
        target = package/'preview_ground'/f"{tile['id']}.glb"
        if target.exists(): raise ValueError(f'Preview mesh already exists: {target}')
        target.parent.mkdir(exist_ok=True)
        mesh = rt.read_glb(str(source))
        attrs = mesh['attributes']
        if terrain_edge_distance:
            attrs['TEXCOORD_1'] = [(max(0., abs(u)-width_at(s,u)),s) for s,u in zip(attrs['_ROUTE_S'],attrs['_ROUTE_U'])]
        else:
            attrs['TEXCOORD_1'] = list(zip(attrs['_ROUTE_U'],attrs['_ROUTE_S']))
        rt.write_glb(str(target),mesh)
        result = rt.read_glb(str(target))
        if result['translation'] != mesh['translation']: raise ValueError(f'Changed translation: {source}')
        for name in ('POSITION','NORMAL','TEXCOORD_0','_ROUTE_U','_ROUTE_S'):
            if result['attributes'][name] != attrs[name]: raise ValueError(f'Changed {name}: {source}')
        if [p['indices'] for p in result['primitives']] != [p['indices'] for p in mesh['primitives']]:
            raise ValueError(f'Changed topology: {source}')
        tile['files']['terrain'] = str(target.relative_to(package))
        if include_roads:
            road_source = package/tile['files']['road']
            road_target = package/'preview_road'/f"{tile['id']}.glb"
            if road_target.exists(): raise ValueError(f'Preview mesh already exists: {road_target}')
            road_target.parent.mkdir(exist_ok=True)
            road_mesh = rt.read_glb(str(road_source)); road_attrs = road_mesh['attributes']
            def edge_distance(s,u):
                return max(0., width_at(s,u) - abs(u))
            road_attrs['TEXCOORD_1'] = [(edge_distance(s,u),width_at(s,u)) for s,u in zip(road_attrs['_ROUTE_S'],road_attrs['_ROUTE_U'])]
            rt.write_glb(str(road_target),road_mesh)
            rebuilt = rt.read_glb(str(road_target))
            if rebuilt['translation'] != road_mesh['translation']: raise ValueError(f'Changed translation: {road_source}')
            for name in ('POSITION','NORMAL','TEXCOORD_0','_ROUTE_U','_ROUTE_S'):
                if rebuilt['attributes'][name] != road_attrs[name]: raise ValueError(f'Changed {name}: {road_source}')
            if [p['indices'] for p in rebuilt['primitives']] != [p['indices'] for p in road_mesh['primitives']]:
                raise ValueError(f'Changed topology: {road_source}')
            tile['files']['road'] = str(road_target.relative_to(package))
    manifest_path.write_text(json.dumps(manifest,indent=2)+'\n')


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('package');parser.add_argument('--include-roads',action='store_true');parser.add_argument('--terrain-edge-distance',action='store_true')
    args=parser.parse_args();add_uvs(args.package,args.include_roads,args.terrain_edge_distance)
