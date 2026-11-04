#!/usr/bin/env python3
"""Independently check serialized stitched DEM tiles against near-ground geometry."""
import argparse
import hashlib
import json
import math
from pathlib import Path

import shapely
from shapely.geometry import Point, Polygon, box
from shapely.strtree import STRtree

import road_terrain as rt
from terrain_clearance import road_occlusions


def _hash(p):return hashlib.sha256(Path(p).read_bytes()).hexdigest()


def _plane(x,z,tri):
    a,b,c=tri;det=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2])
    if abs(det)<1e-14:return None
    u=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/det
    v=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/det
    return u*a[1]+v*b[1]+(1-u-v)*c[1]


def validate(near_pkg, far_dir, spacing_m=2.0, seam_tolerance_m=.001):
    near_pkg,far_dir=Path(near_pkg),Path(far_dir)
    if not math.isfinite(spacing_m) or spacing_m<=0 or not math.isfinite(seam_tolerance_m) or seam_tolerance_m<=0:
        raise ValueError('spacing and seam tolerance must be finite and positive')
    route_path=near_pkg/'route/route.json';route=json.loads(route_path.read_text())
    near_manifest=json.loads((near_pkg/'manifest.json').read_text());far_manifest=json.loads((far_dir/'stitch_manifest.json').read_text())
    errors=[]
    if _hash(route_path)!=far_manifest['near_route_sha256']:errors.append('route hash differs from stitch input')
    for entry in far_manifest['near_inputs']:
        if _hash(near_pkg/entry['file'])!=entry['sha256']:errors.append('near tile hash differs: '+entry['file'])
    nearpoly=[];neartri=[];farpoly=[];fartri=[];far_meshes=[];flips=0;collapses=0
    def gather(path,polys,tris):
        nonlocal flips,collapses
        mesh=rt.read_glb(str(path));pos=rt._world(mesh)
        for prim in mesh['primitives']:
            ids=prim['indices']
            for i in range(0,len(ids),3):
                tri=[pos[j] for j in ids[i:i+3]]
                a,b,c=tri;cross=(b[2]-a[2])*(c[0]-a[0])-(b[0]-a[0])*(c[2]-a[2])
                if cross<0:flips+=1
                if cross==0:collapses+=1;continue
                polys.append(Polygon([(q[0],q[2]) for q in tri]));tris.append(tri)
        return mesh,pos
    for tile in near_manifest['tiles']:
        for layer in ('road','terrain'):
            gather(near_pkg/tile['files'][layer],nearpoly,neartri)
    for entry in far_manifest['tiles']:
        path=far_dir/entry['file']
        if _hash(path)!=entry['sha256']:errors.append('far tile hash differs: '+entry['file'])
        mesh,pos=gather(path,farpoly,fartri);far_meshes.append((entry['file'],mesh,pos))
    if not nearpoly or not farpoly:raise ValueError('missing near or far triangles')
    near=shapely.union_all(nearpoly);far=shapely.union_all(farpoly)
    nt=STRtree(nearpoly);ft=STRtree(farpoly)
    xmin,xmax,zmin,zmax=far_manifest['bounds'];domain=box(xmin,zmin,xmax,zmax)
    gap=domain.difference(shapely.union_all([near,far]));overlap=near.intersection(far)
    # Any gap beyond tolerance of both serialized surface boundaries is a material hole.
    material_gap=gap.difference(shapely.union_all([near.boundary,far.boundary]).buffer(seam_tolerance_m))
    road=road_occlusions(route['samples'],far_meshes)
    if road['blocked_probes']:errors.append('far terrain blocks road probes')
    if flips or collapses:errors.append('serialized triangles flipped or collapsed')
    if material_gap.area>1e-8:errors.append('coverage gap exceeds seam tolerance')
    segments=[]
    def collect(ring):
        coords=list(ring.coords);segments.extend((a,b) for a,b in zip(coords,coords[1:]) if a!=b)
    for part in ([near] if near.geom_type=='Polygon' else near.geoms):
        collect(part.exterior)
        for ring in part.interiors:collect(ring)
    deltas=[];planar=[];unverified=[];outside=0;internal_boundaries=0
    for a,b in segments:
        dx,dz=b[0]-a[0],b[1]-a[1];length=math.hypot(dx,dz)
        if length<1e-6:continue
        nx,nz=-dz/length,dx/length;n=max(1,math.ceil(length/spacing_m))
        for j in range(n):
            t=(j+.5)/n;x,z=a[0]+t*dx,a[1]+t*dz;boundary=Point(x,z)
            if not domain.covers(boundary):outside+=1;continue
            valid=[]
            for offset in (.002,.0005,.0001,.00002,.000002,.0000002,.00000002,.000000002,0.0000000002,0.00000000002,0.000000000002):
                valid=[q for sign in (-1,1) if near.covers(q:=Point(x+sign*nx*offset,z+sign*nz*offset))]
                if len(valid)==1:break
            if len(valid)!=1:
                if not len(ft.query(boundary,predicate='dwithin',distance=seam_tolerance_m)):
                    internal_boundaries+=1
                else:
                    local_near=[];local_far=[]
                    for i in nt.query(boundary,predicate='dwithin',distance=0.00001):
                        at=list(shapely.shortest_line(nearpoly[i],boundary).coords)[0]
                        h=_plane(at[0],at[1],neartri[i])
                        if h is not None:local_near.append(h)
                    for i in ft.query(boundary,predicate='dwithin',distance=0.00001):
                        at=list(shapely.shortest_line(farpoly[i],boundary).coords)[0]
                        h=_plane(at[0],at[1],fartri[i])
                        if h is not None:local_far.append((farpoly[i].distance(boundary),h))
                    if local_near and local_far:
                        distance=min(d for d,h in local_far);heights=[h for d,h in local_far if d<=distance+1e-8]
                        near_span=max(local_near)-min(local_near)
                        difference=max(abs(h-n) for h in heights for n in local_near)
                        if near_span<=seam_tolerance_m and difference<=seam_tolerance_m:
                            deltas.append(difference);planar.append(distance)
                        else:unverified.append([x,z,'ambiguous boundary has conflicting heights',near_span,difference,distance])
                    else:unverified.append([x,z,'ambiguous boundary lacks surface'])
                continue
            q=valid[0];owners=[]
            for i in nt.query(q,predicate='intersects'):
                h=_plane(q.x,q.y,neartri[i]);edge=_plane(x,z,neartri[i])
                if h is not None and edge is not None:owners.append((h,edge))
            if not owners:unverified.append([x,z,'no near surface']);continue
            near_y=max(owners)[1];candidates=[]
            for i in ft.query(boundary,predicate='dwithin',distance=seam_tolerance_m):
                distance=farpoly[i].distance(boundary)
                at=list(shapely.shortest_line(farpoly[i],boundary).coords)[0]
                h=_plane(at[0],at[1],fartri[i])
                if h is not None:candidates.append((distance,h))
            if not candidates:
                # Internal boundaries of overlapping near meshes need no far owner.
                # A material missing far region is rejected independently above.
                if material_gap.area<=1e-8:
                    internal_boundaries+=1
                else:unverified.append([x,z,'no far surface'])
                continue
            distance=min(d for d,h in candidates);far_y=max(h for d,h in candidates if d<=distance+1e-8)
            planar.append(distance);deltas.append(abs(far_y-near_y))
    if unverified:errors.append('some seam samples are unverified')
    if not deltas:errors.append('no seam samples were checked')
    if deltas and max(deltas)>seam_tolerance_m:errors.append('seam height exceeds tolerance')
    if planar and max(planar)>seam_tolerance_m:errors.append('seam gap exceeds tolerance')
    report={'status':'pass' if not errors else 'fail','errors':errors,'spacing_m':spacing_m,'seam_tolerance_m':seam_tolerance_m,
            'near_route_sha256':_hash(route_path),'far_manifest_sha256':_hash(far_dir/'stitch_manifest.json'),
            'serialized_flipped_faces':flips,'serialized_collapsed_faces':collapses,
            'coverage_domain_m2':domain.area,'gap_area_m2':gap.area,'overlap_area_m2':overlap.area,
            'gap_beyond_tolerance_area_m2':material_gap.area,'road_clearance':road,
            'seam_samples_checked':len(deltas),'seam_samples_unverified':len(unverified),'seam_samples_outside_bounds':outside,
            'near_only_boundary_samples_excluded':internal_boundaries,
            'max_seam_height_error_m':max(deltas,default=None),'max_seam_planar_gap_m':max(planar,default=None),
            'unverified_examples':unverified[:20],
            'scope':'Serialized coverage, road probes and near-to-far seam only. Internal near-only boundaries are excluded and not assessed for height continuity; not a skyline, grade, or whole-package acceptance.'}
    (far_dir/'validation.json').write_text(json.dumps(report,indent=2)+'\n')
    return report


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('near_package');parser.add_argument('far_candidate')
    parser.add_argument('--spacing-m',type=float,default=2.0);parser.add_argument('--seam-tolerance-m',type=float,default=.001)
    args=parser.parse_args();r=validate(args.near_package,args.far_candidate,args.spacing_m,args.seam_tolerance_m)
    print(json.dumps(r,indent=2));raise SystemExit(0 if r['status']=='pass' else 1)

if __name__=='__main__':main()
