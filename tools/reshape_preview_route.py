#!/usr/bin/env python3
"""Reshape a preview route with authored bends and rederive physical route fields.

Bends are estimated offsets, not GPS measurements. DTM elevation is sampled at
new coordinates, smoothed by the stated 7 m measurement filter, never clamped.
"""
import argparse
import json
import math
from pathlib import Path
import numpy as np
import route_model as rm
from projected_dtm import SouthTyrolDTM


def reshape(route, bends, dtm_dir):
    original=route['samples'];old_s=np.asarray(original['s'], dtype=float)
    xs=np.asarray(original['x'], dtype=float).copy();zs=np.asarray(original['z'],dtype=float).copy()
    for bend in bends:
        start,end,amplitude=map(float,(bend['from_s'],bend['to_s'],bend['amplitude_m']))
        if not (0 <= start < end <= old_s[-1]) or not all(map(math.isfinite,(start,end,amplitude))): raise ValueError('invalid bend')
        for i,s in enumerate(old_s):
            if start < s < end:
                t=(s-start)/(end-start)
                offset=amplitude*math.sin(2*math.pi*t)*math.sin(math.pi*t)**2
                lx,lz=rm.left_vector(original['heading_deg'][i]);xs[i]+=lx*offset;zs[i]+=lz*offset
    arc=np.r_[0.,np.cumsum(np.hypot(np.diff(xs),np.diff(zs)))]
    if np.any(np.diff(arc)<=0):raise ValueError('new route has repeated positions')
    length=float(arc[-1]);new_s=np.r_[np.arange(0.,math.floor(length)+1.),length]
    if new_s[-1]-new_s[-2] < .00005: new_s=new_s[:-1]
    new_x=np.interp(new_s,arc,xs);new_z=np.interp(new_s,arc,zs);old_at_new=np.interp(new_s,arc,old_s)
    r=json.loads(json.dumps(route));smp=r['samples'];smp['s']=new_s.tolist();smp['x']=new_x.tolist();smp['z']=new_z.tolist()
    for k in ('width_left_m','width_right_m'):smp[k]=np.interp(old_at_new,old_s,original[k]).tolist()
    idx=np.searchsorted(old_s,old_at_new,side='right')-1;idx=np.clip(idx,0,len(old_s)-1)
    smp['surface_type']=[original['surface_type'][i] for i in idx]
    dem=SouthTyrolDTM(dtm_dir,r);height=[]
    for x,z in zip(new_x,new_z):
        y=dem.sample_bilinear(float(x),float(z))
        if y is None: raise ValueError('DTM unavailable for reshaped route')
        height.append(y+dem.datum)
    # Equivalent to the prior route's 7 m centred, distance-weighted filter.
    heights=np.asarray(height);smooth=[]
    for t in new_s:
        values=np.interp(t+np.linspace(-3.5,3.5,29),new_s,heights)
        smooth.append(float((values.sum()-.5*(values[0]+values[-1]))*.25/7.))
    smp['elevation_m']=smooth
    def map_s(s):return float(np.interp(s,old_s,arc))
    for marker in [r['start'],r['finish']]+r['checkpoints']:marker['s']=min(round(length,4),map_s(marker['s']))
    for section in r.get('sections',[]):
        section['from_s']=map_s(section['from_s']);section['to_s']=map_s(section['to_s'])
    r['source']['geometry']='Artistically reshaped from estimated r36 route, with user-authorized bends; not real GPS or a measured road.'
    r['source']['elevation']='South Tyrol DTM 2.5m sampled bilinearly on reshaped coordinates; 7m centred distance-weighted mean; no grade clipping, vertical datum and actual road surface unverified.'
    r['source']['warning']='Provisional artistic route; not approved for trainer/treadmill physical use.'
    r['source']['reshape_bends']=bends
    for k in ('y','grade_percent','heading_deg','curvature'):smp.pop(k,None)
    r=rm.finalize(r);errors=rm.validate(r)
    return r, {'validation_errors':errors,'old_total_m':float(old_s[-1]),'new_total_m':r['total_length_m'],'dtm_samples':dem.hits,'missing_dtm_samples':dem.missing,'max_lateral_shift_m':float(max(np.hypot(xs-np.asarray(original['x']),zs-np.asarray(original['z'])))),'max_abs_grade_percent':max(abs(x) for x in r['samples']['grade_percent']),'old_to_new_station':[[round(float(a),4),round(float(b),4)] for a,b in zip(old_s,arc)]}


def main():
    parser=argparse.ArgumentParser(description=__doc__);parser.add_argument('route');parser.add_argument('bends');parser.add_argument('output');parser.add_argument('--dtm-dir',required=True);a=parser.parse_args()
    route,report=reshape(json.loads(Path(a.route).read_text()),json.loads(Path(a.bends).read_text()),a.dtm_dir)
    path=Path(a.output);path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(route,ensure_ascii=False,indent=2)+'\n');path.with_name('reshape_report.json').write_text(json.dumps(report,indent=2)+'\n');print(json.dumps({k:v for k,v in report.items() if k!='old_to_new_station'},indent=2))
    if report['validation_errors']:raise SystemExit(1)

if __name__=='__main__':main()
