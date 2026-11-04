#!/usr/bin/env python3
"""Mark estimated alpine hollows on preview far meshes without moving vertices."""
import argparse
import hashlib
import json
from pathlib import Path
import road_terrain as rt


def sha(path): return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def build(package, out_dir):
    package, out_dir = Path(package), Path(out_dir)
    config = json.loads(Path(str(package)+'.godot_preview.json').read_text())
    sources = [package/p for p in config['distant_preview_meshes']]
    if out_dir.exists() and any(out_dir.iterdir()): raise ValueError('output directory must be empty')
    meshes=[];grid={}
    for path in sources:
        mesh=rt.read_glb(str(path));positions=rt._world(mesh)
        meshes.append((path,mesh,positions))
        for x,y,z in positions:
            if y>=2000: grid[(round(x,2),round(z,2))]=y
    def mask(x,y,z):
        if y<2000:return 0.
        candidates=[]
        for dx,dz in ((40,0),(0,40),(40,40),(40,-40),(80,0),(0,80)):
            a=grid.get((round(x+dx,2),round(z+dz,2)))
            b=grid.get((round(x-dx,2),round(z-dz,2)))
            if a is not None and b is not None:candidates.append((a+b)*.5-y)
        if not candidates:return 0.
        return max(0.,min(1.,(max(candidates)-18.)/55.))
    out_dir.mkdir(parents=True,exist_ok=True);tiles=[];nonzero=0;count=0
    for source,mesh,positions in meshes:
        scores=[mask(*p) for p in positions];count+=len(scores);nonzero+=sum(v>0 for v in scores)
        mesh['attributes']['TEXCOORD_1']=[(v,0.) for v in scores]
        target=out_dir/source.name;rt.write_glb(str(target),mesh);check=rt.read_glb(str(target))
        if check['translation'] != mesh['translation']:raise ValueError('translation changed')
        for name in ('POSITION','NORMAL','TEXCOORD_0','_ROUTE_S'):
            if check['attributes'][name]!=mesh['attributes'][name]:raise ValueError(f'changed {name}: {source}')
        if [p['indices'] for p in check['primitives']] != [p['indices'] for p in mesh['primitives']]:raise ValueError('topology changed')
        tiles.append({'file':source.name,'source_sha256':sha(source),'preview_sha256':sha(target)})
    report={'status':'preview material estimate, not measured snow','method':'multi-direction height concavity over 40m/80m neighboring DEM vertices; shader also filters elevation, slope and noise','mesh_geometry':'positions, normals, original UVs, indices and translations unchanged','vertices':count,'hollow_mask_nonzero_vertices':nonzero,'tiles':tiles}
    (out_dir/'snow_manifest.json').write_text(json.dumps(report,indent=2)+'\n');return report


if __name__=='__main__':
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('package');parser.add_argument('output');args=parser.parse_args()
    report=build(args.package,args.output);print('preview snow mask:',report['vertices'],'vertices;',report['hollow_mask_nonzero_vertices'],'eligible; geometry unchanged')
