#!/usr/bin/env python3
"""Shared procedural glTF prototypes for an AI Scene Package. No private reference pixels.
Writes one reusable mesh per used prototype, plus engine-neutral mesh_file references.
Runtimes may substitute richer assets; declared geometry is an estimated reconstruction.
  python3 tools/build_package_assets.py <package> [library.json] [--only=<prototype-id>]
"""
import json
import math
import random
import shutil
import struct
import sys
from pathlib import Path
import road_terrain as rt


def sub(a,b): return tuple(x-y for x,y in zip(a,b))
def add(a,b): return tuple(x+y for x,y in zip(a,b))
def mul(a,s): return tuple(x*s for x in a)
def cross(a,b): return (a[1]*b[2]-a[2]*b[1],a[2]*b[0]-a[0]*b[2],a[0]*b[1]-a[1]*b[0])
def dot(a,b): return sum(x*y for x,y in zip(a,b))
def norm(a): return mul(a,1/max(math.sqrt(dot(a,a)),1e-9))

class Mesh:
    def __init__(self): self.pos=[]; self.groups={}
    def tri(self,pts,color,normal=None):
        a,b,c=pts
        if normal and dot(cross(sub(b,a),sub(c,a)),normal)<0: pts=[a,c,b]
        base=len(self.pos);self.pos.extend(pts)
        self.groups.setdefault(tuple(color),[]).extend([base,base+1,base+2])
    def quad(self,points,color,normal=None):
        self.tri([points[0],points[1],points[2]],color,normal)
        self.tri([points[0],points[2],points[3]],color,normal)
    def box(self,c,size,col):
        x,y,z=c;w,h,d=[v/2 for v in size]
        for axis,sg in [(0,-1),(0,1),(1,-1),(1,1),(2,-1),(2,1)]:
            n=[0,0,0];n[axis]=sg
            if axis==0: pts=[(x+sg*w,y-h,z-d),(x+sg*w,y+h,z-d),(x+sg*w,y+h,z+d),(x+sg*w,y-h,z+d)]
            elif axis==1: pts=[(x-w,y+sg*h,z-d),(x+w,y+sg*h,z-d),(x+w,y+sg*h,z+d),(x-w,y+sg*h,z+d)]
            else: pts=[(x-w,y-h,z+sg*d),(x+w,y-h,z+sg*d),(x+w,y+h,z+sg*d),(x-w,y+h,z+sg*d)]
            self.quad(pts,col,n)
    def cylinder(self,a,b,r1,r2,col,n=8):
        axis=norm(sub(b,a)); right=norm(cross(axis,(0,0,1) if abs(axis[2])<.9 else (1,0,0)));front=cross(axis,right)
        for i in range(n):
            radial=lambda k:add(mul(right,math.cos(k*2*math.pi/n)),mul(front,math.sin(k*2*math.pi/n)))
            v,w=radial(i),radial(i+1)
            p,q=add(a,mul(v,r1)),add(a,mul(w,r1));u,t=add(b,mul(v,r2)),add(b,mul(w,r2))
            self.quad([p,u,t,q],col,add(v,w))
        # caps
        for i in range(n):
            for center,r,sg in [(a,r1,-1),(b,r2,1)]:
                v=add(center,mul(radial(i),r));w=add(center,mul(radial(i+1),r))
                self.tri([center,v,w],col,mul(axis,sg))
    def ellipsoid(self,c,size,col,segments=9,rings=6):
        def pt(i,j):
            a=2*math.pi*i/segments;b=-math.pi/2+math.pi*j/rings
            return add(c,(size[0]*math.cos(a)*math.cos(b),size[1]*math.sin(b),size[2]*math.sin(a)*math.cos(b)))
        for j in range(rings):
            for i in range(segments):
                pts=[pt(i,j),pt(i+1,j),pt(i+1,j+1),pt(i,j+1)]
                if j>0:self.tri(pts[:3],col,sub(pts[1],c))
                if j<rings-1:self.tri([pts[0],pts[2],pts[3]],col,sub(pts[2],c))
    def save(self,path,name):
        idx=[i for g in self.groups.values() for i in g]
        rt.write_glb(str(path),dict(name=name,translation=[0,0,0],primitives=[
            {'material':{'name':f'{name}_{j}','color':list(c),'roughness':.8},'indices':ii}
            for j,(c,ii) in enumerate(self.groups.items())],attributes={'POSITION':self.pos,'NORMAL':rt._normals(self.pos,idx)}))

BARK=(.19,.12,.065);LEAF=(.095,.24,.075);WHITE=(.72,.74,.70);METAL=(.36,.40,.40);BLUE=(.10,.22,.28)


def vegetation(proto):
    m=Mesh();rng=random.Random(proto)
    if proto in ('norfolk_pine','conifer_spruce','conifer_larch'):
        m.cylinder((0,0,0),(0,21,0),.32,.07,BARK,10)
        for tier in range(12):
            y=5+tier*1.28;r=5.2*(1-tier/13)**.8
            for branch in range(7):
                a=branch*math.tau/7+tier*.53
                end=(math.cos(a)*r,y+.22,math.sin(a)*r)
                m.cylinder((0,y,0),end,.075,.012,BARK,5)
                for f in (.35,.62,.88):
                    c=(end[0]*f,y+.1+.4*f,end[2]*f)
                    # Distinct whorls; narrow needle sprays, not a solid Christmas-tree cone.
                    col=(.065+.015*(branch%3),.18+.02*(tier%4),.065)
                    m.ellipsoid(c,(r*.25,.32,r*.25),col,7,4)
        m.ellipsoid((0,20.8,0),(.55,1,.55),LEAF,8,5)
    elif proto=='tropical_palm':
        for i in range(18):
            y=i*.6;x=.45*(y/10.8)**2
            m.cylinder((x,y,0),(.45*((y+.6)/10.8)**2,y+.6,0),.23-i*.004,.225-i*.004,(.27,.23,.14),9)
        for f in range(11):
            a=f*math.tau/11;origin=(.45,10.8,0)
            prev=origin
            for j in range(1,10):
                t=j/9;r=5*t;p=add(origin,(math.cos(a)*r,2.6*math.sin(math.pi*t*.85)-2.3*t,math.sin(a)*r))
                m.cylinder(prev,p,.035*(1-t)+.008,.025*(1-t)+.005,LEAF,4)
                # pinnate leaflets, two sides of the rachis
                for sg in (-1,1):
                    ll=1.0*math.sin(math.pi*t)**.6
                    tip=add(p,(math.cos(a+sg*1.0)*ll,-.38*ll,math.sin(a+sg*1.0)*ll))
                    root=add(p,(-math.cos(a)*.3,0,-math.sin(a)*.3))
                    m.tri([root,p,tip],(.10,.29,.065));m.tri([tip,p,root],(.10,.29,.065))
                prev=p
    elif proto in ('deciduous_broadleaf','shrub_broadleaf'):
        small=proto=='shrub_broadleaf';base=1 if small else 8;r=1.7 if small else 4.4
        m.cylinder((0,0,0),(.25,base+1,0),.14 if small else .48,.08,BARK,10)
        for i in range(13):
            a=i*2.4;rr=r*rng.uniform(.25,.85);c=(math.cos(a)*rr,base+rng.uniform(0,r*.9),math.sin(a)*rr)
            m.cylinder((0,base*.55,0),c,.09,.025,BARK,6)
            m.ellipsoid(c,(r*.62,r*.48,r*.6),(.08+rng.random()*.06,.20+rng.random()*.1,.055+rng.random()*.04),12,7)
    elif proto in ('rock_small','rock_boulder'):
        m.ellipsoid((0,.35,0),(.7,.5,.55),(.30,.29,.25),7,4)
    else:
        height=1.7 if proto=='reed_clump' else .3
        for i in range(10):
            a=i*2.4;r=rng.uniform(.02,.22);p=(math.cos(a)*r,0,math.sin(a)*r)
            tip=add(p,(.12*math.cos(a),height*rng.uniform(.5,1.1),.12*math.sin(a)))
            m.tri([p,add(p,(.035,0,.035)),tip],(.18,.30,.075));m.tri([tip,add(p,(.035,0,.035)),p],(.18,.30,.075))
    return m


def structure(proto,dims,asset_parameters=None):
    m=Mesh();w,h,d=dims
    if proto == 'rotary_chapel_gable':
        asset_parameters=asset_parameters or {}
        cupola_end=asset_parameters.get('cupola_end','positive_z')
        if cupola_end not in ('positive_z','negative_z'):
            raise ValueError(f"unsupported cupola_end for {proto}: {cupola_end}")
        # OSM outline is long across this route frame: eaves span local X and ridge runs along local Z.
        bd=d-2.0
        eave=3.55;ridge=5.45
        body_w=w-.16  # recess the walls so siding and glazed side windows remain visible outside the body.
        m.box((0,eave/2,0),(body_w,eave,bd),(.83,.84,.82))
        # Pale weatherboards are represented by narrow, repeated trim strips.
        for y in [0.42+i*.34 for i in range(9)]:
            for sg in (-1,1):m.box((0,y,sg*(bd/2+.025)),(w-.15,.035,.035),(.91,.91,.88))
            for sg in (-1,1):m.box((sg*(w/2-.02),y,0),(.035,.035,bd-.15),(.91,.91,.88))
        # Gable ends are on Z end planes; ridge follows the long, OSM-aligned local Z axis.
        for sg in (-1,1):m.tri([(-w/2,eave,sg*bd/2),(0,ridge,sg*bd/2),(w/2,eave,sg*bd/2)],(.84,.85,.83),(0,0,sg))
        m.quad([(-w/2,eave,-bd/2),(0,ridge,-bd/2),(0,ridge,bd/2),(-w/2,eave,bd/2)],(.38,.40,.39),(-.7,.7,0))
        m.quad([(0,ridge,-bd/2),(w/2,eave,-bd/2),(w/2,eave,bd/2),(0,ridge,bd/2)],(.42,.43,.41),(.7,.7,0))
        # Narrow side windows face the route on the long side walls.
        for xsg in (-1,1):
            for z in (-4.5,-1.5,1.5,4.5):m.box((xsg*(w/2-.025),2.15,z),(.04,1.48,.72),(.24,.39,.43))
        # Small square louvered cupola with a simple cross, offset toward one roof end.
        cz=(1 if cupola_end=='positive_z' else -1)*d*.27
        m.box((0,5.95,cz),(1.45,1.0,1.35),(.86,.86,.82))
        for sg in (-1,1):
            for i in range(4):m.box((sg*.74,5.95,cz-.46+i*.30),(.04,.58,.055),(.36,.38,.36))
        m.box((0,6.52,cz),(1.7,.08,1.55),(.42,.43,.41))
        m.box((0,7.04,cz),(.09,.95,.09),(.25,.26,.24));m.box((0,7.15,cz),(.48,.08,.09),(.25,.26,.24))
        # Entry deck and a short accessible ramp, kept inside the estimated object footprint.
        deck_d=1.0;deck_z=bd/2+deck_d/2
        m.box((0,.18,deck_z),(w*.62,.22,deck_d),(.55,.53,.48))
        endz=d/2-.1
        m.quad([(-w*.24,.26,bd/2+deck_d/2),(w*.24,.26,bd/2+deck_d/2),(w*.24,0,endz),(-w*.24,0,endz)],(.61,.59,.53),(0,1,0))
        for x in (-w*.24,w*.24):m.cylinder((x,.28,bd/2+deck_d/2),(x,.32,endz),.035,.025,WHITE,6)
    elif proto == 'sky_broadwater_podium':
        top=h-.16
        # The authored P4 object is a complete estimated white podium mass from terrain to 40 m.
        # OSM's tagged 10..40 m part describes only one mapped vertical interval; it is not added twice.
        body_w=w-.4;body_d=d-4.0;body_z=-2.0
        m.box((0,top/2,body_z),(body_w,top,body_d),(.82,.84,.83))
        # White balcony bands on the road-facing side. The upper Sky tower is outside this P4 crop.
        for y in [2.7+i*3.0 for i in range(13) if 2.7+i*3.0 < top-.5]:
            m.box((0,y, d/2-.90),(w*.88,.22,1.65),(.91,.92,.90))
            m.box((0,y+.52,d/2-.16),(w*.88,.075,.07),(.48,.54,.52))
            for x in (-w*.43,w*.43):m.box((x,y+.28,d/2-.16),(.06,.55,.07),(.48,.54,.52))
        # Three small, vertically staggered openings on the broad blank podium end wall.
        for y,z in ((6.0,d*.20),(20.0,0.0),(34.0,-d*.20)):
            # Overlap the inset body slightly, with the remaining window projection outside it.
            m.box((-w/2+.21,y,z),(.07,1.05,1.30),(.22,.35,.39))
        # A shallow slab cap joins the facade without inventing the upper tower mass.
        m.box((0,top+.08,0),(w-.2,.16,d-.2),(.89,.90,.88))
    elif proto == 'coastal_house_gable':
        body_h=h*.68; eave=body_h; ridge=h
        m.box((0,body_h/2,0),(w,body_h,d),(.78,.79,.76))
        # A simple pale pitched roof, with the ridge running along the facade width.
        m.quad([(-w/2,eave,-d/2),(w/2,eave,-d/2),(w/2,ridge,0),(-w/2,ridge,0)],(.69,.70,.67),(0,.7,-.7))
        m.quad([(-w/2,ridge,0),(w/2,ridge,0),(w/2,eave,d/2),(-w/2,eave,d/2)],(.72,.73,.70),(0,.7,.7))
        m.tri([(-w/2,eave,-d/2),(-w/2,ridge,0),(-w/2,eave,d/2)],(.75,.76,.73),(-1,0,0))
        m.tri([(w/2,eave,-d/2),(w/2,eave,d/2),(w/2,ridge,0)],(.75,.76,.73),(1,0,0))
        for x in (-w*.27,w*.27):
            m.box((x,body_h*.58,d/2+.015),(1.1,1.25,.04),(.28,.39,.43))
    elif proto.startswith('coastal_apartment') and (asset_parameters or {}).get('facade_style') == 'terraced_coastal':
        # Generic estimated apartment massing: facade projections stay within the
        # declared footprint. This is a visual proxy, not a measured named facade.
        body_w, body_d = w * .90, d * .78
        m.box((0,h/2,-d*.04),(body_w,h,body_d),(.78,.79,.76))
        floors=max(1,int(h/3))
        for floor in range(floors):
            y=(floor+.5)*h/floors
            for x in (-w*.29,0,w*.29):
                m.box((x,y,d*.351),(w*.21,h/floors*.60,.04),(.12,.24,.29))
            # Segmented balcony fronts suggest rounded corners without requiring a texture.
            slab_y=y-h/floors*.33
            m.box((0,slab_y,d*.405),(w*.72,.18,d*.17),(.91,.91,.88))
            m.box((-w*.40,slab_y,d*.38),(w*.09,.18,d*.12),(.88,.89,.86))
            m.box((w*.40,slab_y,d*.38),(w*.09,.18,d*.12),(.88,.89,.86))
            m.box((0,slab_y+.62,d*.485),(w*.72,1.0,.045),(.34,.47,.49))
            for x in (-w*.36,-w*.12,w*.12,w*.36):
                m.box((x,slab_y+.62,d*.486),(.045,1.03,.05),(.8,.81,.78))
            for x in (-w*.45,w*.45):
                m.box((x,y,-d*.04),(.04,h/floors*.58,d*.33),(.18,.29,.32))
        m.box((0,h-.08,0),(w*.92,.16,d*.90),(.88,.89,.86))
    elif proto.startswith('coastal_apartment') or proto in ('lodge','house_chalet','camp_cabin'):
        body_w = w - 4.0 if proto == 'coastal_apartment_corner_36' else w
        m.box((0,h/2,0),(body_w,h,d),(.64,.65,.61))
        floors=max(1,int(h/3))
        for f in range(floors):
            y=1.5+f*3
            for x in range(-int(w/2)+2,int(w/2),3):
                for sg in (-1,1):m.box((x,y,sg*(d/2+.015)),(1.7,1.9,.035),BLUE)
            if proto.startswith('coastal_apartment'):
                for sg in (-1,1):
                    m.box((0,y-.8,sg*(d/2+.6)),(w+.4,.2,1.5),WHITE)
                    m.box((0,y-.15,sg*(d/2+1.3)),(w,.65,.08),(.45,.54,.54))
                if proto == 'coastal_apartment_corner_36':
                    body_edge = body_w / 2
                    for sg in (-1,1):
                        m.box((sg*(body_edge+.02),y,0),(.04,1.7,1.7),BLUE)
                        m.box((sg*(w/2-1.0),y-.8,0),(2.0,.2,d),WHITE)
                        m.box((sg*(w/2-.25),y-.15,0),(.08,.65,d),(.45,.54,.54))
        m.box((0,h+.1,0),(w+.3,.25,d+.3),WHITE)
    elif proto=='white_chapel':
        m.box((0,2.5,0),(w,5,d),WHITE)
        for sg in (-1,1):
            pts=[(0,h,-d/2-.5),(sg*(w/2+.5),4.8,-d/2-.5),(sg*(w/2+.5),4.8,d/2+.5),(0,h,d/2+.5)]
            m.quad(pts,(.38,.40,.37),(sg,.8,0))
        for z in (-d/2,d/2):m.tri([(-w/2,5,z),(w/2,5,z),(0,h,z)],WHITE,(0,0,z))
        m.box((0,1.4,d/2+.02),(2,2.8,.08),(.28,.21,.13))
        for sg in (-1,1):
            for z in range(-4,5,3):m.box((sg*(w/2+.015),2.8,z),(.05,1.5,1),BLUE)
    elif proto=='park_shelter':
        for x in (-w/2+.3,w/2-.3):
            for z in (-d/2+.3,d/2-.3):m.box((x,1.7,z),(.18,3.4,.18),WHITE)
        m.box((0,.1,0),(w,.2,d),(.44,.44,.42))
        for sg in (-1,1):m.quad([(-w/2,3.4,sg*d/2),(-w/2,h,0),(w/2,h,0),(w/2,3.4,sg*d/2)],(.12,.27,.31),(0,1,sg))
    elif proto=='park_art_cylinder':
        # Source review shows a pale tapered plinth, a perforated green trunk, and
        # irregular branch/leaf silhouettes above the cylinder. Estimated generic
        # proportions; no frame pixels are used in the mesh.
        radius=min(w,d)*.38
        sand=(.61,.55,.38); green=(.075,.29,.095); lime=(.43,.62,.12); dark=(.045,.19,.065)
        body_top=min(3.15,h*.68)
        # Broad, low conical plinth (the source has a light-colored splayed foot).
        m.cylinder((0,0,0),(0,1.05,0),radius*.78,radius*.56,sand,24)
        # Openwork trunk: dark vertical rails, a waist ring, and repeated tree motifs.
        m.cylinder((0,1.02,0),(0,1.16,0),radius*.57,radius*.57,green,24)
        m.cylinder((0,body_top-.10,0),(0,body_top,0),radius*.57,radius*.57,green,24)
        for i in range(20):
            a=i*math.tau/20
            x,z=math.cos(a)*radius*.57,math.sin(a)*radius*.57
            m.cylinder((x,1.12,z),(x,body_top-.08,z),.075,.075,dark,6)
        for i in range(10):
            a=i*math.tau/10
            radial=(math.cos(a),0,math.sin(a)); tangent=(-math.sin(a),0,math.cos(a))
            def point(t,y,r=radius*.57): return (radial[0]*r+tangent[0]*t,y,radial[2]*r+tangent[2]*t)
            m.cylinder(point(0,1.20),point(0,body_top-.13),.085,.07,lime,7)
            for y in (1.62,2.22,2.78):
                if y >= body_top-.22: continue
                for side in (-1,1):
                    branch_end=point(side*.48,min(y+.36,body_top-.14))
                    m.cylinder(point(0,y),branch_end,.065,.045,lime,6)
                    m.cylinder(branch_end,point(side*.66,min(y+.63,body_top-.10)),.045,.025,green,6)
        # Uneven upper tree crown breaks the cylinder outline like the source sculpture.
        crown_base=body_top-.04
        for i in range(12):
            a=i*math.tau/12
            radial=(math.cos(a),0,math.sin(a)); tangent=(-math.sin(a),0,math.cos(a))
            r=radius*.28
            trunk=(radial[0]*r,crown_base,radial[2]*r)
            top_y=min(h-.22,3.65+(i%4)*.28)
            top=(radial[0]*(r+.05),top_y,radial[2]*(r+.05))
            m.cylinder(trunk,top,.065,.035,dark,6)
            for side in (-1,1):
                end=(top[0]+tangent[0]*side*.30, min(h-.13,top_y+.20), top[2]+tangent[2]*side*.30)
                m.cylinder((top[0]*.68+trunk[0]*.32,top_y-.25,top[2]*.68+trunk[2]*.32),end,.035,.02,green,5)
                m.ellipsoid(end,(.12,.13,.12),lime,7,4)
    elif proto=='broadwater_jetty':
        # Estimated low timber jetty. Object origin is existing P1 seabed (-0.8 m);
        # deck is +0.4 m absolute at the current datum (1.2 m local).
        deck_y=1.2
        tan=(.47,.34,.20); edge=(.36,.25,.14); dark=(.27,.19,.12)
        m.box((0,deck_y-.10,0),(w,.20,d),tan)
        for i in range(24):
            x=-w/2+(i+.5)*w/24
            m.box((x,deck_y+.012,0),(w/24-.025,.025,d-.12),edge if i%5==0 else tan)
        # Four pile rows; bottom vertices are the physical P1 support probes.
        asset_parameters=asset_parameters or {}
        layout=asset_parameters.get('pile_layout_xz_m',[[x,z] for x in (-10.0,-3.3,3.3,10.0) for z in (-4.4,-1.5,1.5,4.4)])
        corner_offsets=asset_parameters.get('pile_bottom_corner_offsets_m',[[0.0]*4 for _ in layout])
        if len(layout)!=16 or len(corner_offsets)!=16 or any(len(row)!=4 for row in corner_offsets):
            raise ValueError('broadwater_jetty needs 16 piles with four P1 corner offsets each')
        half=.14; top=deck_y-.10
        for (x,z),offsets in zip(layout,corner_offsets):
            offsets=[float(v) for v in offsets]
            if any(v<-.02 or v>.75 for v in offsets):
                raise ValueError('broadwater_jetty pile offsets must remain between -0.02 and +0.75 m')
            a=(float(x)-half,offsets[0],float(z)-half); b=(float(x)+half,offsets[1],float(z)-half)
            c=(float(x)+half,offsets[2],float(z)+half); d0=(float(x)-half,offsets[3],float(z)+half)
            A=(a[0],top,a[2]);B=(b[0],top,b[2]);C=(c[0],top,c[2]);D=(d0[0],top,d0[2])
            m.quad([A,B,C,D],dark,(0,1,0));m.quad([d0,c,b,a],dark,(0,-1,0))
            m.quad([a,b,B,A],dark,(0,0,-1));m.quad([b,c,C,B],dark,(1,0,0))
            m.quad([c,d0,D,C],dark,(0,0,1));m.quad([d0,a,A,D],dark,(-1,0,0))
        # A low outer rail and a short landward return leave the water side open.
        z=d/2-.20
        for x in (-w/2+.2,w/2-.2):m.box((x,1.62,z),(.24,.82,.24),edge)
        m.box((0,1.96,z),(w-.35,.12,.14),edge)
        m.box((0,1.67,z),(w-.35,.10,.12),edge)
        for x in (-w/2+.2,w/2-.2):m.box((x,1.85,-d/2+.15),(.12,.12,1.3),edge)
    elif proto=='playground_sails':
        colors=[(.12,.35,.53),(.64,.34,.04),(.45,.12,.20)]
        for i in range(3):
            cx=-w/3+i*w/3
            pts=[(cx-w/4,4,-d/3),(cx+w/4,5,d/4),(cx,6,-d/2)]
            for p in pts:m.cylinder((p[0],0,p[2]),p,.07,.07,METAL,6)
            m.tri(pts,colors[i]);m.tri(pts[::-1],colors[i])
        m.box((0,.1,0),(w,.2,d),(.33,.27,.13))
    elif proto in ('coastal_lamp','lamp_lantern'):
        m.cylinder((0,0,0),(0,h-.4,0),.055,.04,WHITE,10)
        m.cylinder((0,h-.4,0),(.65,h,0),.04,.035,WHITE,8)
        m.ellipsoid((.65,h,0),(.4,.10,.18),(.55,.57,.52),9,5)
    elif proto in ('bench_wood','picnic_table'):
        for x in (-.65,.65):
            m.box((x,.27,0),(.08,.55,.55),METAL)
        for z in (-.22,-.08,.08,.22):m.box((0,.5,z),(1.8,.07,.10),(.34,.19,.075))
        for y in (.68,.83):m.box((0,y,-.25),(1.8,.1,.065),(.34,.19,.075))
    elif proto.startswith('gate_'):
        # Gameplay gates remain data; small neutral posts render without covering the reference path.
        for x in (-3,3):m.box((x,.6,0),(.12,1.2,.12),WHITE)
    else:
        m.cylinder((0,0,0),(0,1.8,0),.035,.035,METAL,7)
        m.box((0,1.8,0),(.35,.3,.035),(.23,.35,.37))
    return m


def copy_gltf_asset(pkg, spec):
    """Copy a static glTF or self-contained GLB library asset into the package."""
    src=Path(spec['file'])
    if src.suffix.lower() == '.glb':
        if spec.get('scale',1) != 1:
            raise ValueError('GLB library scale must be 1; export it at the desired size')
        raw=src.read_bytes()
        if len(raw)<20:
            raise ValueError('Invalid GLB header')
        magic,version,total=struct.unpack_from('<4sII',raw)
        size,kind=struct.unpack_from('<II',raw,12)
        if magic!=b'glTF' or version!=2 or total!=len(raw) or kind!=0x4e4f534a or size>len(raw)-20:
            raise ValueError('Invalid GLB header or JSON chunk')
        data=json.loads(raw[20:20+size])
        if any(item.get('uri') and not item['uri'].startswith('data:') for item in data.get('buffers',[])+data.get('images',[])):
            raise ValueError('GLB library assets must embed all buffers and images')
        dst=pkg/'assets/library'/src.parent.name;dst.mkdir(parents=True,exist_ok=True)
        output=dst/src.name;shutil.copyfile(src,output)
        return output.relative_to(pkg).as_posix()
    data=json.loads(src.read_text())
    dst=pkg/'assets/library'/src.parent.name;dst.mkdir(parents=True,exist_ok=True)
    for item in data.get('buffers',[])+data.get('images',[]):
        uri=item.get('uri')
        if not uri: continue
        relative=Path(uri)
        if relative.is_absolute() or '..' in relative.parts: raise ValueError('Library asset URI must stay local')
        target=dst/uri;target.parent.mkdir(parents=True,exist_ok=True)
        shutil.copyfile(src.parent/uri,target)
    # Library size -> the prototype's declared metre scale, not route scale.
    factor=spec.get('scale',1)
    scaled=set()
    for mesh in data['meshes']:
        for primitive in mesh['primitives']:
            index=primitive['attributes']['POSITION']
            if index in scaled: continue
            scaled.add(index)
            acc=data['accessors'][index]
            view=data['bufferViews'][acc['bufferView']]
            buffer=dst/data['buffers'][view['buffer']]['uri']
            raw=bytearray(buffer.read_bytes())
            stride=view.get('byteStride',12);off=view.get('byteOffset',0)+acc.get('byteOffset',0)
            for i in range(acc['count']):
                pos=struct.unpack_from('<3f',raw,off+i*stride)
                struct.pack_into('<3f',raw,off+i*stride,*[v*factor for v in pos])
            for key in ('min','max'):
                if key in acc:acc[key]=[v*factor for v in acc[key]]
            buffer.write_bytes(raw)
    output=dst/src.name;output.write_text(json.dumps(data,separators=(',',':'))+'\n')
    return output.relative_to(pkg).as_posix()


def build_library_source(pkg, spec, src):
    """Record the declared licence and carry non-CC0 notices alongside the asset."""
    license_name=spec.get('license','CC0')
    source={'kind':'library','ref':spec['attribution'],'license':license_name,
            'note':'Original image bytes retained; static model dimensions estimated'}
    if license_name != 'CC0':
        if not spec.get('license_file'):
            raise ValueError('Non-CC0 library asset requires license_file')
        notice=Path(spec['license_file'])
        if not notice.is_file():
            raise ValueError('library license_file does not exist')
        dst=pkg/'assets/library'/src.parent.name;dst.mkdir(parents=True,exist_ok=True)
        output=dst/notice.name
        shutil.copyfile(notice,output)
        source['license_file']=output.relative_to(pkg).as_posix()
    return source


def build_material_assets(pkg, library):
    """Copy only declared CC0 material sets; never rebuild P3/P4 prototype meshes."""
    import hashlib
    specs = library.get('_materials', {})
    out = pkg/'assets/materials';out.mkdir(parents=True, exist_ok=True)
    catalog = {'version':'0.1','materials':{}}
    credits = pkg/'CREDITS.md'
    text = credits.read_text() if credits.exists() else '# Sources and licences\n'
    for name,spec in specs.items():
        if spec.get('license') != 'CC0':
            raise ValueError('Package building material must be explicitly CC0: '+name)
        record = {'repeat_m':spec['repeat_m'],'source':{'kind':'library','license':'CC0','ref':spec['attribution'],
                                                       'url':spec['url'],'estimated':False},'sha256':{}}
        folder = out/name;folder.mkdir(exist_ok=True)
        for key in ('diffuse','normal','roughness'):
            src=Path(spec[key]);dest=folder/src.name
            shutil.copyfile(src,dest)
            record[key]=dest.relative_to(pkg).as_posix()
            record['sha256'][key]=hashlib.sha256(dest.read_bytes()).hexdigest()
        catalog['materials'][name]=record
        line=f"- {name}: {spec['attribution']} — CC0; {spec['url']} (diffuse, OpenGL normal, roughness; original source bytes).\n"
        if line not in text:text=text.rstrip()+'\n'+line
    (out/'osm_buildings.json').write_text(json.dumps(catalog,indent=1)+'\n')
    credits.write_text(text)
    man=json.loads((pkg/'manifest.json').read_text());man['building_material_assets']={
        'catalog':'assets/materials/osm_buildings.json','license':'CC0','files':[p.relative_to(pkg).as_posix() for p in sorted(out.rglob('*')) if p.is_file()]}
    (pkg/'manifest.json').write_text(json.dumps(man,indent=1)+'\n')
    print(f"{len(specs)} CC0 building PBR material sets copied; existing prototypes unchanged")


def build(pkg, library=None, only=None):
    out=pkg/'assets/prototypes';out.mkdir(parents=True,exist_ok=True)
    count=0
    matched=set()
    for layer in ('vegetation','structures'):
        if only and layer != 'structures': continue
        path=pkg/layer/'prototypes.json';data=json.loads(path.read_text())
        used=set()
        for tile in sorted((pkg/'tiles').iterdir()):
            p=tile/(layer+'.json')
            if p.exists():used.update(g['proto'] for g in json.loads(p.read_text())['groups'])
        for p in data['prototypes']:
            if only and p['id'] != only: continue
            if p['id'] not in used: continue
            proto=p['id']
            if library and proto in library:
                spec=library[proto]
                source=build_library_source(pkg,spec,Path(spec['file']))
                p['mesh_file']=copy_gltf_asset(pkg,spec)
                (out/(proto+'.glb')).unlink(missing_ok=True)
                p['source']=source
                count+=1
                continue
            mesh=vegetation(proto) if layer=='vegetation' else structure(
                proto,p.get('dimensions_m',[3,3,3]),p.get('asset_parameters'))
            rel='assets/prototypes/'+proto+'.glb';mesh.save(pkg/rel,proto)
            p['mesh_file']=rel;p['source']={'kind':'procedural','estimated':True,'generator':'tools/build_package_assets.py',
                'note':'Shared estimated geometry; no reference video pixels or third-party textures'}
            count+=1
            matched.add(p['id'])
        if only:
            path.write_text(json.dumps(data,indent=1)+'\n')
            continue
        path.write_text(json.dumps(data,indent=1)+'\n')
    if only and only not in matched:
        raise ValueError(f'prototype {only} is not referenced by any package structure instance')
    if only:
        print(f'{count} structure prototype mesh updated; all other package assets unchanged')
        return
    man=json.loads((pkg/'manifest.json').read_text())
    man['prototype_assets']={'files':['assets/prototypes/*.glb']+['assets/library/'+p.relative_to(pkg/'assets/library').as_posix() for p in sorted((pkg/'assets/library').rglob('*')) if p.is_file()], 'source':'Procedural estimated geometry + declared library assets; see prototype sources'}
    (pkg/'manifest.json').write_text(json.dumps(man,indent=1)+'\n')
    print(f'{count} reusable prototype meshes; external textures retained once per library asset; reference images: 0')

if __name__=='__main__':
    args=sys.argv[1:]
    pkg=Path(args[0])
    library_path=next((a for a in args[1:] if not a.startswith('--')),None)
    only=next((a.split('=',1)[1] for a in args[1:] if a.startswith('--only=')),None)
    library = json.loads(Path(library_path).read_text()) if library_path else None
    if '--materials-only' in args:
        if not library: raise ValueError('--materials-only requires a library file')
        build_material_assets(pkg, library)
    else:
        if library and library.get('_materials'): build_material_assets(pkg, library)
        build(pkg, library, only)
