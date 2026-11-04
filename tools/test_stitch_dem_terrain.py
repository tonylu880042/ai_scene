"""Regression tests for building DEM terrain around an existing road footprint."""
import json, tempfile, unittest
from pathlib import Path
from PIL import Image
from tools import road_terrain as rt
from tools import route_model as rm
try:
    import shapely
except ImportError:
    shapely = None
if shapely is not None:
    from tools import stitch_dem_terrain as stitch
    from tools import validate_stitched_dem as validator

@unittest.skipIf(shapely is None, 'optional Shapely terrain dependency is unavailable')
class StitchDemTerrainTest(unittest.TestCase):
    def test_joins_demo_ground_and_preserves_road(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'dem/0/0').mkdir(parents=True)
            Image.new('RGB',(256,256),(128,110,0)).save(root/'dem/0/0/0.png')
            raw={'route_id':'test','sample_interval_m':1.0,
                 'coordinate_system':{'origin':{'lat':0.0,'lon':0.0,'altitude_m':0.0},'elevation_reference':'msl'},
                 'samples':{'s':list(range(21)),'x':list(range(21)),'z':[0.0]*21,'elevation_m':[100.0]*21,
                            'width_left_m':[3.0]*21,'width_right_m':[3.0]*21,'surface_type':['gravel']*21}}
            route=rm.finalize(raw);pkg=root/'near';(pkg/'route').mkdir(parents=True)
            (pkg/'route/route.json').write_text(json.dumps(route))
            rt.build(str(pkg),terrain={'columns_m':[0,.6,2,5,10],'blend_to_m':5,
                     'dem':{'tile_dir':str(root/'dem'),'zoom':0,'source':'fixture'}})
            before=(pkg/'tiles/00/road.glb').read_bytes()
            report=stitch.build(pkg,root/'far',(-40,60,-40,40),10,40)
            self.assertEqual(before,(pkg/'tiles/00/road.glb').read_bytes())
            self.assertGreater(report['far_triangles'],0)
            self.assertEqual(report['unresolved_boundary_vertices'],0)
            self.assertEqual(report['road_clearance']['blocked_probes'],0,report['road_clearance'])
            self.assertLess(report['unsaved_area_error_m2'],0.001)
            checked=validator.validate(pkg,root/'far')
            self.assertEqual(checked['status'],'pass',checked['errors'])
            self.assertEqual(checked['road_clearance']['blocked_probes'],0)
            self.assertGreater(checked['seam_samples_checked'],0)
            for tile in report['tiles']:
                mesh=rt.read_glb(str(root/'far'/tile['file']))
                self.assertEqual(rt._face_up(rt._world(mesh),rt._tris(mesh)),0)
            manifest_path=root/'far/stitch_manifest.json'
            saved=json.loads(manifest_path.read_text())
            import hashlib
            points=[(0,102,-10),(0,102,10),(20,102,-10)];indices=[0,1,2]
            obstacle=root/'far/injected.glb'
            rt.write_glb(str(obstacle),{'name':'occluding_ground','translation':[0,0,0],
              'primitives':[{'material':rt.TERRAIN_MATERIAL,'indices':indices}],
              'attributes':{'POSITION':points,'NORMAL':rt._normals(points,indices),'TEXCOORD_0':[(0,0)]*3,'_ROUTE_S':[0]*3}})
            broken=json.loads(json.dumps(saved));broken['tiles'].append({'file':'injected.glb','sha256':hashlib.sha256(obstacle.read_bytes()).hexdigest()})
            manifest_path.write_text(json.dumps(broken))
            blocked=validator.validate(pkg,root/'far')
            self.assertEqual(blocked['status'],'fail')
            self.assertGreater(blocked['road_clearance']['blocked_probes'],0)
            saved['tiles'][0]['sha256']='0'*64
            manifest_path.write_text(json.dumps(saved))
            checked=validator.validate(pkg,root/'far')
            self.assertEqual(checked['status'],'fail')
            self.assertTrue(any('hash differs' in error for error in checked['errors']))

    def test_nonempty_output_is_rejected(self):
        with tempfile.TemporaryDirectory() as tmp:
            out=Path(tmp)/'far';out.mkdir();(out/'keep').write_text('keep')
            with self.assertRaisesRegex(ValueError,'empty'):
                stitch.build(Path(tmp)/'absent',out,(-10,10,-10,10),10,20)
