"""Global road priority: clip terrain against nonadjacent road triangles and probe shipped terrain.
Pure package-frame metres. No route edits; independent from engine / scene names.
"""
import math


def cross(a,b): return a[0]*b[1]-a[1]*b[0]


class RoadCorridors:
    CELL=16.
    def __init__(self,positions,indices,distances):
        self.tris=[];self.grid={};self.boxes=[]
        for k in range(0,len(indices),3):
            ids=indices[k:k+3];tri=[positions[i] for i in ids]
            box=(min(p[0] for p in tri),min(p[2] for p in tri),max(p[0] for p in tri),max(p[2] for p in tri))
            self.boxes.append((*box,min(p[1] for p in tri),max(p[1] for p in tri)))
            tid=len(self.tris)
            self.tris.append((tri,min(distances[i] for i in ids),max(distances[i] for i in ids)))
            for x in range(math.floor(box[0]/self.CELL),math.floor(box[2]/self.CELL)+1):
                for z in range(math.floor(box[1]/self.CELL),math.floor(box[3]/self.CELL)+1):
                    self.grid.setdefault((x,z),[]).append(tid)

    def contains_foreign(self,x,z,s,clearance):
        ids=set()
        for gx in range(math.floor((x-clearance)/self.CELL),math.floor((x+clearance)/self.CELL)+1):
            for gz in range(math.floor((z-clearance)/self.CELL),math.floor((z+clearance)/self.CELL)+1):
                ids.update(self.grid.get((gx,gz),()))
        for tid in ids:
            triangle,s0,s1=self.tris[tid]
            if s0-3<=s<=s1+3:continue
            box=self.boxes[tid]
            if not box[0]-clearance<=x<=box[2]+clearance or not box[1]-clearance<=z<=box[3]+clearance:continue
            signs=[];nearest=math.inf
            for a,b in zip(triangle,triangle[1:]+triangle[:1]):
                dx,dz=b[0]-a[0],b[2]-a[2]
                signs.append(dx*(z-a[2])-dz*(x-a[0]))
                t=min(1.,max(0.,((x-a[0])*dx+(z-a[2])*dz)/max(dx*dx+dz*dz,1e-16)))
                nearest=min(nearest,math.hypot(x-a[0]-t*dx,z-a[2]-t*dz))
            if min(signs)>=-1e-8 or max(signs)<=1e-8 or nearest<clearance:return True
        return False


def road_occlusions(smp,terrain_meshes,tolerance=.01):
    """Probe every canonical row at centre / 80% width against ALL shipped terrain triangles, not only local s.
    terrain_meshes: iterable of (tile_id, mesh attributes + primitives, world positions).
    """
    grid={};probes=[];cell=10.
    for i,s in enumerate(smp['s']):
        h=math.radians(smp['heading_deg'][i]);lx,lz=-math.cos(h),-math.sin(h)
        for u in (-.8*smp['width_right_m'][i],0.,.8*smp['width_left_m'][i]):
            x,z=smp['x'][i]+lx*u,smp['z'][i]+lz*u
            pid=len(probes);probes.append((s,u,x,smp['y'][i],z))
            grid.setdefault((math.floor(x/cell),math.floor(z/cell)),[]).append(pid)
    blocked={}
    for tid,mesh,pos in terrain_meshes:
        for primitive in mesh['primitives']:
            idx=primitive['indices']
            for k in range(0,len(idx),3):
                ids=idx[k:k+3];(ax,ay,az),(bx,by,bz),(cx,cy,cz)=[pos[j] for j in ids]
                det=(bz-cz)*(ax-cx)+(cx-bx)*(az-cz)
                if abs(det)<1e-12:continue
                xmin,xmax=min(ax,bx,cx),max(ax,bx,cx);zmin,zmax=min(az,bz,cz),max(az,bz,cz)
                for gx in range(math.floor(xmin/cell),math.floor(xmax/cell)+1):
                    for gz in range(math.floor(zmin/cell),math.floor(zmax/cell)+1):
                        for pid in grid.get((gx,gz),()):
                            s,u,x,y,z=probes[pid]
                            if not xmin-1e-6<=x<=xmax+1e-6 or not zmin-1e-6<=z<=zmax+1e-6:continue
                            a=((bz-cz)*(x-cx)+(cx-bx)*(z-cz))/det
                            b=((cz-az)*(x-cx)+(ax-cx)*(z-cz))/det
                            c=1-a-b
                            if min(a,b,c)<-1e-6:continue
                            height=a*ay+b*by+c*cy
                            delta=height-y
                            if delta>tolerance and delta>blocked.get(pid,{}).get('above_road_m',0):
                                blocked[pid]={'s':round(s,3),'u':round(u,3),'terrain_tile':tid,
                                    'terrain_source_s':round(sum(mesh['attributes']['_ROUTE_S'][j] for j in ids)/3,3),
                                    'above_road_m':round(delta,5)}
    return {'probe_count':len(probes),'blocked_probes':len(blocked),
            'max_above_road_m':max((v['above_road_m'] for v in blocked.values()),default=0),
            'examples':sorted(blocked.values(),key=lambda v:-v['above_road_m'])[:20]}


def split_polygon(polygon, signed_distance):
    """Partition a convex polygon, carrying all per-vertex attributes through edge intersections."""
    positive,negative=[],[]
    for a,b in zip(polygon,polygon[1:]+polygon[:1]):
        da,db=signed_distance(a),signed_distance(b)
        (positive if da>=0 else negative).append(a)
        if (da>1e-10 and db < -1e-10) or (da < -1e-10 and db>1e-10):
            t=da/(da-db);p=tuple(x+(y-x)*t for x,y in zip(a,b))
            positive.append(p);negative.append(p)
        elif abs(da)<=1e-10:
            # Shared clip boundary belongs to both sides, with zero area counted only once later.
            (negative if da>=0 else positive).append(a)
    return positive,negative


def subtract_road(polygon,triangle,clearance=.02):
    """Subtract only the area over a foreign road where terrain would be at/above its surface."""
    a,b,c=triangle
    orientation=1 if cross((b[0]-a[0],b[2]-a[2]),(c[0]-a[0],c[2]-a[2]))>0 else -1
    outside=[];inside=polygon
    for start,end in zip(triangle,triangle[1:]+triangle[:1]):
        ex,ez=end[0]-start[0],end[2]-start[2]
        inside,kept=split_polygon(inside,lambda p:orientation*(ex*(p[2]-start[2])-ez*(p[0]-start[0])))
        if len(kept)>=3:outside.append(kept)
        if len(inside)<3:return outside
    ax,ay,az=a;bx,by,bz=b;cx,cy,cz=c
    det=(bz-cz)*(ax-cx)+(cx-bx)*(az-cz)
    def above(p):
        x,y,z=p[:3]
        l1=((bz-cz)*(x-cx)+(cx-bx)*(z-cz))/det
        l2=((cz-az)*(x-cx)+(ax-cx)*(z-cz))/det
        return y-(l1*ay+l2*by+(1-l1-l2)*cy)+clearance
    _,below=split_polygon(inside,above)
    if len(below)>=3:outside.append(below)
    return outside


def clip_terrain(positions,distances,offsets,indices,corridors,origin):
    """Cut terrain against canonical P0 road triangles; preserve the road and interpolate P1 attributes.
    The original vertices remain available for exact tile-edge bookkeeping. Ground consumers must use indices.
    """
    import struct
    out=[];vertices={tuple(round(v,8) for v in (*p,s,u)):i for i,(p,s,u) in enumerate(zip(positions,distances,offsets))}
    added=0;cut=0
    def vertex(p):
        nonlocal added
        key=tuple(round(v,8) for v in p)
        if key not in vertices:
            vertices[key]=len(positions);positions.append(p[:3]);distances.append(p[3]);offsets.append(p[4]);added+=1
        return vertices[key]
    for k in range(0,len(indices),3):
        ids=indices[k:k+3];triangle=[positions[i] for i in ids]
        xmin,xmax=min(p[0] for p in triangle),max(p[0] for p in triangle)
        zmin,zmax=min(p[2] for p in triangle),max(p[2] for p in triangle)
        s0,s1=min(distances[i] for i in ids),max(distances[i] for i in ids)
        candidates=set()
        for gx in range(math.floor(xmin/corridors.CELL),math.floor(xmax/corridors.CELL)+1):
            for gz in range(math.floor(zmin/corridors.CELL),math.floor(zmax/corridors.CELL)+1):
                candidates.update(corridors.grid.get((gx,gz),()))
        polys=[[(positions[i][0],positions[i][1],positions[i][2],distances[i],offsets[i]) for i in ids]]
        modified=False
        for rid in sorted(candidates):
            road,rs0,rs1=corridors.tris[rid]
            if rs0<=s1+2 and rs1>=s0-2:continue
            box=corridors.boxes[rid]
            if box[2]<xmin or box[0]>xmax or box[3]<zmin or box[1]>zmax:continue
            if max(p[1] for p in triangle)<box[4]-.02:continue
            changed=[]
            for poly in polys:changed.extend(subtract_road(poly,road))
            polys=changed;modified=True
            if not polys:break
        if not modified:out.extend(ids);continue
        cut+=1
        for poly in polys:
            for j in range(1,len(poly)-1):
                pts=[poly[0],poly[j],poly[j+1]]
                # Test in the float32 coordinates actually shipped. Exact clip-boundary contacts may collapse.
                qp=[struct.unpack('<3f',struct.pack('<3f',*(p[d]-origin[d] for d in range(3)))) for p in pts]
                area=(qp[1][2]-qp[0][2])*(qp[2][0]-qp[0][0])-(qp[1][0]-qp[0][0])*(qp[2][2]-qp[0][2])
                if abs(area)<1e-7:continue
                if area<0:
                    if abs(area)<1e-4:continue  # sub-millimetre boundary sliver at float32 precision
                    raise ValueError('Terrain clipping produced a reversed polygon')
                mapped=[vertex(p) for p in pts]
                if len(set(mapped))==3:out.extend(mapped)
    return out,{'tested_triangles':len(indices)//3,'candidate_triangles':cut,'added_vertices':added}


def bank_envelopes(smp,reaches,extent,max_grade):
    """Reference planes outside physical road edges. Their elevations constrain P1 only, never P0."""
    positions=[];distances=[];indices=[]
    n=len(smp['s'])
    for side in (-1,1):
        base=len(positions)
        for i,h in enumerate(smp['heading_deg']):
            angle=math.radians(h);lx,lz=-math.cos(angle),-math.sin(angle)
            w=smp['width_left_m' if side>0 else 'width_right_m'][i]
            reach=min(extent,reaches[side][i])
            ds=[0.,reach] if side>0 else [reach,0.]
            for d in ds:
                u=side*(w+d)
                positions.append((smp['x'][i]+lx*u,smp['y'][i]-.05+max_grade*d,smp['z'][i]+lz*u))
                distances.append(smp['s'][i])
        for i in range(n-1):
            a=base+2*i;b=a+2
            for tri in ([a,b,a+1],[b,b+1,a+1]):
                p,q,r=[positions[j] for j in tri]
                area=cross((q[0]-p[0],q[2]-p[2]),(r[0]-p[0],r[2]-p[2]))
                if abs(area)>1e-9:indices.extend(tri)
    return RoadCorridors(positions,indices,distances)


def _float32_clip_sliver(double_area,packed_area,quantization_bound):
    """Drop only a near-zero facet whose winding flips under float32 XZ quantization."""
    error=abs(packed_area-double_area)
    return double_area>=0.0 and packed_area<0.0 and abs(double_area)<=quantization_bound and error<=quantization_bound


def conform_banks(positions,distances,offsets,indices,envelopes,smp,origin,canonical_float32=False):
    """Lower overlapping P1 banks onto graded transition planes. Keep each source road edge pinned.
    Splitting at the envelope boundary / cap plane avoids missing an intrusion between sparse grid vertices.
    """
    import bisect
    import struct
    def f32(value):
        return struct.unpack('<f',struct.pack('<f',float(value)))[0]
    def packed_local(p):
        return tuple(f32(p[d]-origin[d]) for d in range(3))
    def cache_key(p):
        if canonical_float32:
            return (*packed_local(p),f32(p[3]),f32(p[4]))
        return tuple(round(v,8) for v in p)
    out=[];vertices={cache_key((*p,s,u)):i for i,(p,s,u) in enumerate(zip(positions,distances,offsets))}
    changed_count=0;max_drop=0.;degenerate=0
    def vertex(p):
        key=cache_key(p)
        if key not in vertices:
            vertices[key]=len(positions)
            if canonical_float32:
                local=packed_local(p)
                positions.append(tuple(origin[d]+local[d] for d in range(3)))
                distances.append(f32(p[3]));offsets.append(f32(p[4]))
            else:
                positions.append(p[:3]);distances.append(p[3]);offsets.append(p[4])
        return vertices[key]
    def edge_weight(p):
        s,u=p[3:5];ss=smp['s'];i=min(max(bisect.bisect_right(ss,s)-1,0),len(ss)-2)
        t=min(1.,max(0.,(s-ss[i])/(ss[i+1]-ss[i])))
        ww=smp['width_left_m' if u>0 else 'width_right_m'];w=ww[i]+(ww[i+1]-ww[i])*t
        t=min(1.,max(0.,(abs(u)-w)/.6))
        return t*t*(3-2*t)
    def lower(poly,plane):
        nonlocal max_drop
        (ax,ay,az),(bx,by,bz),(cx,cy,cz)=plane
        det=(bz-cz)*(ax-cx)+(cx-bx)*(az-cz)
        def height(p):
            x,_,z=p[:3];a=((bz-cz)*(x-cx)+(cx-bx)*(z-cz))/det;b=((cz-az)*(x-cx)+(ax-cx)*(z-cz))/det
            return a*ay+b*by+(1-a-b)*cy
        if max(p[1]-height(p) for p in poly)<=1e-8:return [poly],False
        orientation=1 if cross((bx-ax,bz-az),(cx-ax,cz-az))>0 else -1
        outside=[];inside=poly
        for a,b in zip(plane,plane[1:]+plane[:1]):
            ex,ez=b[0]-a[0],b[2]-a[2]
            inside,kept=split_polygon(inside,lambda p:orientation*(ex*(p[2]-a[2])-ez*(p[0]-a[0])))
            if len(kept)>=3:outside.append(kept)
            if len(inside)<3:return [poly],False
        if max(p[1]-height(p) for p in inside)<=1e-8:return [poly],False
        above,below=split_polygon(inside,lambda p:p[1]-height(p))
        if len(below)>=3:outside.append(below)
        if len(above)>=3:
            adjusted=[]
            for p in above:
                drop=max(0.,p[1]-height(p))*edge_weight(p)
                max_drop=max(max_drop,drop);adjusted.append((p[0],p[1]-drop,*p[2:]))
            outside.append(adjusted)
        return outside,True
    for k in range(0,len(indices),3):
        ids=indices[k:k+3];tri=[positions[i] for i in ids]
        xmin,xmax=min(p[0] for p in tri),max(p[0] for p in tri);zmin,zmax=min(p[2] for p in tri),max(p[2] for p in tri)
        s0,s1=min(distances[i] for i in ids),max(distances[i] for i in ids)
        candidates=set()
        for gx in range(math.floor(xmin/envelopes.CELL),math.floor(xmax/envelopes.CELL)+1):
            for gz in range(math.floor(zmin/envelopes.CELL),math.floor(zmax/envelopes.CELL)+1):candidates.update(envelopes.grid.get((gx,gz),()))
        polys=[[(positions[i][0],positions[i][1],positions[i][2],distances[i],offsets[i]) for i in ids]];modified=False
        for rid in sorted(candidates):
            plane,rs0,rs1=envelopes.tris[rid];box=envelopes.boxes[rid]
            if rs0<=s1+2 and rs1>=s0-2:continue
            if box[2]<xmin or box[0]>xmax or box[3]<zmin or box[1]>zmax or max(p[1] for p in tri)<box[4]:continue
            result=[]
            for poly in polys:
                pieces,changed=lower(poly,plane);result.extend(pieces);modified|=changed
            polys=result
        if not modified:out.extend(ids);continue
        changed_count+=1
        for poly in polys:
            for j in range(1,len(poly)-1):
                pts=[poly[0],poly[j],poly[j+1]]
                # The optional coastal overlay uses the exact positions that will be serialized;
                # the default bank-transition path retains its previous behavior.
                qp=( [packed_local(p) for p in pts] if canonical_float32 else
                     [struct.unpack('<3f',struct.pack('<3f',*(p[d]-origin[d] for d in range(3)))) for p in pts] )
                area=(qp[1][2]-qp[0][2])*(qp[2][0]-qp[0][0])-(qp[1][0]-qp[0][0])*(qp[2][2]-qp[0][2])
                edge_lengths=[math.hypot(qp[a][0]-qp[b][0],qp[a][2]-qp[b][2])
                              for a,b in ((0,1),(1,2),(2,0))]
                double_area=(pts[1][2]-pts[0][2])*(pts[2][0]-pts[0][0])-(pts[1][0]-pts[0][0])*(pts[2][2]-pts[0][2])
                scale=max(1.0,max(abs(q[0]) for q in qp),max(abs(q[2]) for q in qp))
                quantization_bound=4.0*1.1920928955078125e-7*scale*max(1.0,sum(edge_lengths))
                if canonical_float32 and _float32_clip_sliver(double_area,area,quantization_bound):
                    degenerate+=1;continue
                if abs(area)<1e-7:degenerate+=1;continue
                if area<0:
                    if abs(area)<1e-4:degenerate+=1;continue
                    raise ValueError(f'Bank transition reversed: target_tri={k//3} envelope_tri={rid} double_area_f64={double_area:.12g} double_area_f32={area:.12g} points={qp}')
                mapped=[vertex(p) for p in pts]
                if len(set(mapped))==3:out.extend(mapped)
    return out,{'modified_triangles':changed_count,'max_terrain_lowering_m':round(max_drop,5),'degenerate_triangles_dropped':degenerate}


def _segment_distance(a,b,c,d):
    def orient(p,q,r): return cross((q[0]-p[0],q[1]-p[1]),(r[0]-p[0],r[1]-p[1]))
    def on_segment(p,q,r):
        return min(p[0],q[0])-1e-10<=r[0]<=max(p[0],q[0])+1e-10 and min(p[1],q[1])-1e-10<=r[1]<=max(p[1],q[1])+1e-10
    o1,o2,o3,o4=orient(a,b,c),orient(a,b,d),orient(c,d,a),orient(c,d,b)
    if o1*o2<=1e-10 and o3*o4<=1e-10 and on_segment(a,b,c) or o1*o2<=1e-10 and o3*o4<=1e-10 and on_segment(a,b,d) or o1*o2<=1e-10 and o3*o4<=1e-10 and on_segment(c,d,a) or o1*o2<=1e-10 and o3*o4<=1e-10 and on_segment(c,d,b):
        return 0.0
    def point_segment(p,x,y):
        dx,dy=y[0]-x[0],y[1]-x[1]
        t=min(1.,max(0.,((p[0]-x[0])*dx+(p[1]-x[1])*dy)/max(dx*dx+dy*dy,1e-20)))
        return math.hypot(p[0]-x[0]-t*dx,p[1]-x[1]-t*dy)
    return min(point_segment(a,c,d),point_segment(b,c,d),point_segment(c,a,b),point_segment(d,a,b))


def _triangles_within(a,b,distance):
    """Exact XZ triangle overlap/clearance test; avoids sample-only road safety checks."""
    def inside(p,tri):
        signs=[cross((q[0]-p[0],q[1]-p[1]),(r[0]-p[0],r[1]-p[1]))
               for q,r in zip(tri,tri[1:]+tri[:1])]
        return min(signs)>=-1e-9 or max(signs)<=1e-9
    if any(inside(p,b) for p in a) or any(inside(p,a) for p in b):return True
    return min(_segment_distance(p,q,r,s) for p,q in zip(a,a[1:]+a[:1]) for r,s in zip(b,b[1:]+b[:1]))<distance


def _mask_triangle_hits_road(triangle,s0,s1,corridors,clearance):
    pad=clearance;lo_x=min(p[0] for p in triangle)-pad;hi_x=max(p[0] for p in triangle)+pad
    lo_z=min(p[2] for p in triangle)-pad;hi_z=max(p[2] for p in triangle)+pad
    ids=set()
    for gx in range(math.floor(lo_x/corridors.CELL),math.floor(hi_x/corridors.CELL)+1):
        for gz in range(math.floor(lo_z/corridors.CELL),math.floor(hi_z/corridors.CELL)+1):ids.update(corridors.grid.get((gx,gz),()))
    xz=[(p[0],p[2]) for p in triangle]
    for rid in ids:
        road,rs0,rs1=corridors.tris[rid]
        if rs0<=s1+3 and rs1>=s0-3:continue
        box=corridors.boxes[rid]
        if box[2]<lo_x or box[0]>hi_x or box[3]<lo_z or box[1]>hi_z:continue
        if _triangles_within(xz,[(p[0],p[2]) for p in road],clearance):return True
    return False


def coastal_owner_envelopes(meshes,profiles,smp,corridors,road_clearance_m=2.0,surface_clearance_m=0.02):
    """Extract explicit, bounded coast-owner surfaces from their own terrain meshes.

    Only profiles with overlap_priority=true participate. Their existing generated P1 triangles
    define both the footprint and height envelope; no world-water area is guessed or filled.
    """
    import bisect
    positions=[];distances=[];offsets=[];indices=[];protected=0
    ss=smp['s']
    def interp(values,s):
        i=min(max(bisect.bisect_right(ss,s)-1,0),len(ss)-2);t=min(1.,max(0.,(s-ss[i])/(ss[i+1]-ss[i])))
        return values[i]+(values[i+1]-values[i])*t
    def keep_positive(poly,fn):
        positive,_=split_polygon(poly,fn)
        return positive if len(positive)>=3 else []
    for _,mesh,world in meshes:
        attrs=mesh['attributes'];source_s=attrs['_ROUTE_S'];source_u=attrs['_ROUTE_U']
        for profile in profiles:
            if not profile.get('overlap_priority',False):continue
            side=1 if profile['side']=='left' else -1 if profile['side']=='right' else 0
            if not side:continue
            extent=float(profile['max_distance_m']);edge=float(profile['water_edge_m']);bank=float(profile.get('bank_width_m',4.0))
            lo_s=max(float(profile['from_s']),float(profile.get('ownership_from_s',profile['from_s'])))
            hi_s=min(float(profile['to_s']),float(profile.get('ownership_to_s',profile['to_s'])))
            if hi_s<=lo_s:continue
            for primitive in mesh['primitives']:
                ix=primitive['indices']
                for k in range(0,len(ix),3):
                    ids=ix[k:k+3]
                    poly=[(*world[j],source_s[j],source_u[j]) for j in ids]
                    poly=keep_positive(poly,lambda p:p[3]-lo_s)
                    if not poly:continue
                    poly=keep_positive(poly,lambda p:hi_s-p[3])
                    if not poly:continue
                    poly=keep_positive(poly,lambda p:side*p[4]-max(edge-bank,interp(smp['width_left_m' if side>0 else 'width_right_m'],p[3])+road_clearance_m))
                    if not poly:continue
                    poly=keep_positive(poly,lambda p:extent-side*p[4])
                    if not poly:continue
                    for j in range(1,len(poly)-1):
                        tri=[poly[0],poly[j],poly[j+1]]
                        a,b,c=[(p[0],p[2]) for p in tri]
                        if abs(cross((b[0]-a[0],b[1]-a[1]),(c[0]-a[0],c[1]-a[1])))<1e-8:continue
                        s0=min(p[3] for p in tri);s1=max(p[3] for p in tri)
                        if _mask_triangle_hits_road([(p[0],p[1],p[2]) for p in tri],s0,s1,corridors,road_clearance_m):
                            protected+=1;continue
                        base=len(positions)
                        for p in tri:positions.append((p[0],p[1]-surface_clearance_m,p[2]));distances.append(p[3]);offsets.append(p[4])
                        indices.extend((base,base+1,base+2))
    env=RoadCorridors(positions,indices,distances)
    return env,{'mask_triangles':len(indices)//3,'protected_by_road':protected}
