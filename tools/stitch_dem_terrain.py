#!/usr/bin/env python3
"""Build a DEM ground mesh outside existing road/terrain footprints.

Requires Shapely >= 2.1 (GEOS >= 3.10), Pillow and cached Terrarium tiles.
The output is an authoring candidate, not a completed environment layer.
"""
import argparse
import hashlib
import json
import math
import struct
from pathlib import Path

import shapely
from shapely.geometry import LineString, Point, Polygon, box
from shapely.strtree import STRtree

import road_terrain as rt
from terrain_clearance import road_occlusions


def _hash(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _f32(value):
    return struct.unpack('<f', struct.pack('<f', value))[0]


def _cross(a, b, c):
    return (b[2]-a[2])*(c[0]-a[0]) - (b[0]-a[0])*(c[2]-a[2])


def _preserve_boundary_vertices(polygon, vertex_tree, vertex_points):
    """Retain near-mesh vertices on each cut edge, including collinear height breaks."""
    def rebuild(ring):
        coords=list(ring.coords);out=[]
        for a,b in zip(coords,coords[1:]):
            out.append(a);dx,dz=b[0]-a[0],b[1]-a[1];den=dx*dx+dz*dz
            if den<1e-20:continue
            line=LineString([a,b]);insert=[]
            for i in vertex_tree.query(line,predicate='dwithin',distance=1e-8):
                q=vertex_points[i];t=((q.x-a[0])*dx+(q.y-a[1])*dz)/den
                if 0.0001 < t*math.sqrt(den) < math.sqrt(den)-0.0001:
                    insert.append((t,(a[0]+dx*t,a[1]+dz*t)))
            previous=-1.0
            for t,point in sorted(insert):
                if (t-previous)*math.sqrt(den)>0.0001:out.append(point);previous=t
        return out
    return Polygon(rebuild(polygon.exterior),[rebuild(ring) for ring in polygon.interiors])


def build(near_pkg, output, bounds, step_m=40, tile_m=800, dtm_dir=None):
    """Create far tiles from strict DEM samples and the actual serialized near footprint.

    bounds is (min_x, max_x, min_z, max_z); dimensions and tile_m must be multiples
    of step_m. Existing roads and ground are read only. A separate validation of
    serialized coverage, seams and appearance is required before acceptance.
    """
    near_pkg, output = Path(near_pkg), Path(output)
    if output.exists() and any(output.iterdir()):
        raise ValueError('output directory must be empty')
    if not all(math.isfinite(x) for x in (*bounds, step_m, tile_m)) or step_m<=0 or tile_m<=0:
        raise ValueError('bounds and spacings must be finite and spacings positive')
    xmin,xmax,zmin,zmax=map(float,bounds)
    if xmin>=xmax or zmin>=zmax:
        raise ValueError('bounds must have positive area')
    def whole(value):
        n=round(value/step_m)
        if n<1 or abs(n*step_m-value)>1e-7:
            raise ValueError('bounds and tile size must be multiples of step')
        return n
    nx,nz,group=whole(xmax-xmin),whole(zmax-zmin),whole(tile_m)
    route_path=near_pkg/'route/route.json'
    route=json.loads(route_path.read_text())
    errors=rt.rm.validate(route)
    if errors:raise ValueError('route invalid: '+errors[0])
    manifest=json.loads((near_pkg/'manifest.json').read_text())
    dem=manifest.get('visual_terrain',{}).get('dem')
    if not dem:raise ValueError('near terrain must declare its DEM source')
    height=rt.make_dem_height_sampler(route,dem)
    dtm = None
    if dtm_dir:
        from projected_dtm import SouthTyrolDTM
        dtm = SouthTyrolDTM(dtm_dir, route)
        baseline = height
        def height(x,z):
            original = baseline(x,z)
            # Preserve the near-route seam and smoothly blend measured high ground.
            if original <= 1600: return original
            measured = dtm.sample(x,z)
            if measured is None: return original
            amount = rt.smoothstep(1600, 1800, original)
            return original*(1-amount) + measured*amount
    polygons=[];triangles=[];input_files=[];vertex_coords=set()
    for tile in manifest.get('tiles',[]):
        for layer in ('road','terrain'):
            path=near_pkg/tile['files'][layer];mesh=rt.read_glb(str(path));world=rt._world(mesh)
            input_files.append({'file':path.relative_to(near_pkg).as_posix(),'sha256':_hash(path)})
            vertex_coords.update((round(q[0],9),round(q[2],9)) for q in world)
            for primitive in mesh['primitives']:
                ids=primitive['indices']
                for i in range(0,len(ids),3):
                    tri=[world[j] for j in ids[i:i+3]]
                    poly=Polygon([(q[0],q[2]) for q in tri])
                    if poly.area>1e-9:polygons.append(poly);triangles.append(tri)
    if not polygons:raise ValueError('no near road or terrain triangles')
    near=shapely.union_all(polygons)
    if not near.is_valid:raise ValueError('invalid near footprint')
    ntree=STRtree(polygons);vertex_points=[Point(q) for q in sorted(vertex_coords)];vertex_tree=STRtree(vertex_points);segments=[]
    def ring_points(ring):
        points=list(ring.coords)
        segments.extend(LineString([a,b]) for a,b in zip(points,points[1:]) if a!=b)
    for part in ([near] if near.geom_type=='Polygon' else near.geoms):
        ring_points(part.exterior)
        for hole in part.interiors:ring_points(hole)
    boundary=STRtree(segments);positions=[];uv=[];indices=[];groups={};index={}
    stats={'near_boundary_vertices':0,'unresolved_boundary_vertices':0,'boundary_height_spread_max_m':0.0};boundary_samples=[]
    def vertex(x,z):
        key=(round(float(x),12),round(float(z),12))
        if key in index:return index[key]
        pt=Point(key)
        if len(boundary.query(pt,predicate='dwithin',distance=0.00001)):
            candidates=[]
            for i in ntree.query(pt,predicate='dwithin',distance=0.0015):
                coord=list(shapely.shortest_line(polygons[i],pt).coords)[0]
                h=rt._barycentric_height_xz(coord[0],coord[1],triangles[i],eps=1e-6)
                if h is not None:candidates.append((polygons[i].distance(pt),h))
            if not candidates:
                stats['unresolved_boundary_vertices']+=1
                raise ValueError(f'cannot resolve near boundary at {key}')
            closest=min(d for d,h in candidates)
            hs=[h for d,h in candidates if d<=closest+1e-8]
            y=max(hs);stats['near_boundary_vertices']+=1
            stats['boundary_height_spread_max_m']=max(stats['boundary_height_spread_max_m'],max(hs)-min(hs))
            boundary_samples.append([key[0],key[1],y,max(hs)-min(hs),closest])
        else:y=height(*key)
        index[key]=len(positions);positions.append((key[0],float(y),key[1]));uv.append((key[0]/100,key[1]/100))
        return index[key]
    target_area=triangle_area=0.0
    for ri in range(nz):
        za=zmin+ri*step_m;zb=za+step_m
        for ci in range(nx):
            xa=xmin+ci*step_m;rect=box(xa,za,xa+step_m,zb)
            region=rect.difference(near) if near.intersects(rect) else rect
            if region.is_empty:continue
            target_area+=region.area
            pieces=[region] if region.geom_type=='Polygon' else [q for q in getattr(region,'geoms',[]) if q.geom_type=='Polygon']
            for piece in pieces:
                if piece.area<1e-14:continue
                if near.intersects(rect):
                    piece=_preserve_boundary_vertices(piece,vertex_tree,vertex_points)
                for tri in shapely.constrained_delaunay_triangles(piece).geoms:
                    if tri.area<1e-14:continue
                    a,b,c=[vertex(x,z) for x,z in list(tri.exterior.coords)[:3]]
                    triple=(a,b,c) if _cross(positions[a],positions[b],positions[c])>0 else (a,c,b)
                    indices.extend(triple);groups.setdefault((ci//group,ri//group),[]).extend(triple);triangle_area+=tri.area
    mesh={'name':'distant_dem_candidate','translation':[0,0,0],
          'primitives':[{'material':rt.TERRAIN_MATERIAL,'indices':indices}],
          'attributes':{'POSITION':positions,'NORMAL':rt._normals(positions,indices),'TEXCOORD_0':uv,'_ROUTE_S':[0.0]*len(positions)}}
    clearance=road_occlusions(route['samples'],[('far_candidate',mesh,positions)])
    output.mkdir(parents=True,exist_ok=True);tiles=[];micro=0;collapsed_area=0.0;collapsed_count=0;exported_indices=set()
    def serialized_cross(tri,origin):
        return _cross(*[tuple(_f32(positions[i][k]-origin[k]) for k in range(3)) for i in tri])
    def runtime_cross(tri,origin):
        pts=[tuple(_f32(_f32(positions[i][k]-origin[k])+_f32(origin[k])) for k in range(3)) for i in tri]
        return _cross(*pts)
    def save(name,ids,origin):
        exported_indices.update(ids)
        remap={};points=[];tex=[];packed=[]
        for old in ids:
            if old not in remap:
                remap[old]=len(points);points.append(tuple(positions[old][k]-origin[k] for k in range(3)));tex.append(uv[old])
            packed.append(remap[old])
        file=output/(name+'.glb')
        rt.write_glb(str(file),{'name':name,'translation':origin,'primitives':[{'material':rt.TERRAIN_MATERIAL,'indices':packed}],
                                'attributes':{'POSITION':points,'NORMAL':rt._normals(points,packed),'TEXCOORD_0':tex,'_ROUTE_S':[0.0]*len(points)}})
        tiles.append({'file':file.name,'sha256':_hash(file),'origin':origin,'triangles':len(packed)//3})
    altitude=round(route['samples']['y'][0])
    for (cx,cz),items in sorted(groups.items()):
        origin=[xmin+cx*tile_m,altitude,zmin+cz*tile_m];regular=[]
        for i in range(0,len(items),3):
            tri=items[i:i+3]
            if serialized_cross(tri,origin)<=0 or runtime_cross(tri,origin)<=0:
                anchor=list(positions[tri[0]])
                if serialized_cross(tri,anchor)<=0 or runtime_cross(tri,anchor)<=0:
                    source_area=abs(_cross(*[positions[v] for v in tri]))/2
                    points=[positions[v] for v in tri]
                    longest=max(math.hypot(points[i][0]-points[j][0],points[i][2]-points[j][2]) for i,j in ((0,1),(1,2),(2,0)))
                    width=(2*source_area/longest) if longest else 0.0
                    if width>0.00025:
                        raise ValueError(f'material far triangle cannot be represented in float32: width={width}')
                    collapsed_count+=1;collapsed_area+=source_area
                    continue
                save(f'micro_{micro:05d}',tri,anchor);micro+=1
            else:regular.extend(tri)
        if regular:save(f'far_{cx:03d}_{cz:03d}',regular,origin)
    used_boundary_samples=[row for row in boundary_samples if index[(row[0],row[1])] in exported_indices]
    report={'status':'candidate_requires_serialized_and_visual_validation','near_route_sha256':_hash(route_path),
            'near_inputs':input_files,'dem':dem,'bounds':list(bounds),'grid_step_m':step_m,'tile_m':tile_m,
            'source_far_triangles':len(indices)//3,'far_triangles':sum(t['triangles'] for t in tiles),'far_vertices':len(positions),'near_footprint_m2':near.area,
            'unsaved_area_error_m2':abs(target_area-triangle_area),'road_clearance':clearance,
            'micro_tile_count':micro,'unrepresentable_subpixel_triangles':collapsed_count,
            'unrepresentable_source_area_m2':collapsed_area,'maximum_omitted_triangle_width_m':0.00025,'tiles':tiles,'boundary_samples':used_boundary_samples,
            'unused_boundary_sample_count':len(boundary_samples)-len(used_boundary_samples),**stats}
    if dtm:
        report['higher_resolution_dtm']={'source':'Autonomous Province of Bolzano, South Tyrol DTM 2.5m, WCS, CC0',
            'catalog':'https://data.civis.bz.it/it/dataset/modello-digitale-del-terreno-dtm-25m',
            'tile_dir':str(dtm_dir),'input_sha256':{p.name:_hash(p) for p in sorted(Path(dtm_dir).glob('*.tif'))},
            'sample':'nearest cell; ETRS89 approximated by WGS84 UTM32',
            'blend':'baseline Terrarium below 1600 m; smooth blend to DTM by 1800 m; fallback where DTM has no data',
            'valid_samples':dtm.hits,'missing_or_nodata_samples':dtm.missing,
            'vertical_datum':'not independently harmonized; preview only'}
    (output/'stitch_manifest.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('near_package');parser.add_argument('output')
    parser.add_argument('--bounds',type=float,nargs=4,required=True,metavar=('MIN_X','MAX_X','MIN_Z','MAX_Z'))
    parser.add_argument('--step-m',type=float,default=40);parser.add_argument('--tile-m',type=float,default=800)
    parser.add_argument('--dtm-dir',help='optional cached South Tyrol 2.5 m GeoTIFFs for distant terrain')
    args=parser.parse_args();r=build(args.near_package,args.output,args.bounds,args.step_m,args.tile_m,args.dtm_dir)
    print(f"candidate: {r['far_triangles']} triangles, {len(r['tiles'])} files, {r['road_clearance']['blocked_probes']} blocked road probes; serialized and visual checks required")

if __name__=='__main__':main()
