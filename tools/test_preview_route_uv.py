"""Ensure preview road/terrain UVs never change physical geometry."""
import json
import tempfile
import unittest
from pathlib import Path
from tools import route_model as rm, road_terrain as rt, add_preview_route_uv as uv


class PreviewRouteUVTest(unittest.TestCase):
    def test_uv_addition_preserves_geometry_and_encodes_edge_distance(self):
        with tempfile.TemporaryDirectory() as tmp:
            pkg=Path(tmp);(pkg/'route').mkdir()
            raw={'route_id':'uv_test','sample_interval_m':1.,'coordinate_system':{'origin':{'lat':0.,'lon':0.,'altitude_m':0.},'elevation_reference':'msl'},'samples':{'s':list(range(21)),'x':list(range(21)),'z':[0.]*21,'elevation_m':[100.]*21,'width_left_m':[3.]*21,'width_right_m':[3.]*21,'surface_type':['gravel']*21}}
            (pkg/'route/route.json').write_text(json.dumps(rm.finalize(raw)))
            rt.build(str(pkg),tile_m=50)
            manifest=json.loads((pkg/'manifest.json').read_text());road=rt.read_glb(str(pkg/manifest['tiles'][0]['files']['road']))
            terrain=rt.read_glb(str(pkg/manifest['tiles'][0]['files']['terrain']))
            uv.add_uvs(pkg,include_roads=True,terrain_edge_distance=True)
            updated=json.loads((pkg/'manifest.json').read_text())
            for layer,original in [('road',road),('terrain',terrain)]:
                rebuilt=rt.read_glb(str(pkg/updated['tiles'][0]['files'][layer]))
                self.assertEqual(rebuilt['translation'],original['translation'])
                for field in ['POSITION','NORMAL','TEXCOORD_0','_ROUTE_S','_ROUTE_U']: self.assertEqual(rebuilt['attributes'][field],original['attributes'][field])
                self.assertEqual([p['indices'] for p in rebuilt['primitives']],[p['indices'] for p in original['primitives']])
                self.assertIn('TEXCOORD_1',rebuilt['attributes'])
                if layer=='road':
                    for (edge,width),offset in zip(rebuilt['attributes']['TEXCOORD_1'],rebuilt['attributes']['_ROUTE_U']):
                        self.assertAlmostEqual(edge,max(0,3-abs(offset)),places=4)
                        self.assertAlmostEqual(width,3,places=4)
                else:
                    for (edge,_),offset in zip(rebuilt['attributes']['TEXCOORD_1'],rebuilt['attributes']['_ROUTE_U']):
                        self.assertAlmostEqual(edge,max(0,abs(offset)-3),places=4)

if __name__=='__main__':unittest.main()
