"""Verify preview tree density additions keep existing trees and road clearance."""
import json
import math
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
from tools import build_authoring_preview as build


class Corridor:
    def contains_foreign(self,x,z,s,clearance): return False


class Space:
    def __init__(self,*args): self.road_corridors=Corridor()
    def excluded(self,*args,**kwargs): return None
    def width(self,s,u): return 2.0
    def world_xz(self,s,u): return s,u
    def ground(self,s,u,x,z): return 100.


class PreviewScatterTest(unittest.TestCase):
    def test_new_trees_respect_existing_trees_and_canopy_clearance(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);near=root/'near';(near/'route').mkdir(parents=True);(near/'tiles/00').mkdir(parents=True)
            (near/'manifest.json').write_text(json.dumps({'tiles':[{'id':'00','from_s':0.,'to_s':100.,'files':{}}]}))
            (near/'route/route.json').write_text('{}')
            base=root/'base/tiles/00';base.mkdir(parents=True)
            old={'proto':'conifer','count':1,'data':[50.,100.,10.,0.,0.,0.,1.,1.,1.,1.]}
            (base/'preview_vegetation.json').write_text(json.dumps({'groups':[old]}))
            far=root/'far';far.mkdir();(far/'stitch_manifest.json').write_text(json.dumps({'tiles':[],'dem':{'source':'fixture'}}))
            mesh=root/'tree.glb';mesh.write_bytes(b'test')
            config={'near_package':str(near),'far_terrain':str(far),'output':str(root/'output'),'models':{'conifer':str(mesh),'conifer_fill':str(mesh)},'preserve_vegetation_from':str(root/'base'),'preserved_existing_prototypes':['conifer'],'spacing_avoid_prototypes':['conifer'],'zones':[{'from_s':0,'to_s':100,'scatter':{'conifer_fill':{'per_m':3,'offset_m':[3,15],'scale':[1,1],'category':'conifer','crown_radius_m':3.,'min_tree_spacing_m':2.5}}}]}
            cfg=root/'config.json';cfg.write_text(json.dumps(config))
            with patch.object(build.vegetation,'Space',Space),patch.object(build.rm,'sample',return_value={}),patch('sys.argv',['build_authoring_preview.py',str(cfg)]): build.main()
            rows=json.loads((root/'output/tiles/00/preview_vegetation.json').read_text())['groups']
            self.assertEqual(rows[0],old)
            fill=rows[1];self.assertGreater(fill['count'],0)
            points=[(50.,10.)]
            for i,u in enumerate(fill['lateral_offset_m']):
                x,_,z=fill['data'][10*i:10*i+3]
                self.assertGreaterEqual(abs(u)+.001,5.3)
                self.assertTrue(all(math.hypot(x-a,z-b)>=2.498 for a,b in points))
                points.append((x,z))

if __name__=='__main__': unittest.main()
