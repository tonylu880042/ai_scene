"""Checks for optional DEM-based near-road ground without changing the road."""
import json
import tempfile
import unittest
from pathlib import Path
from PIL import Image
from tools import road_terrain as rt

class DemTerrainTest(unittest.TestCase):
    def test_dem_blend_preserves_road_edge_and_reaches_measured_ground(self):
        params = dict(rt.DEFAULT_TERRAIN)
        sampler = lambda x, z: 120.0
        self.assertAlmostEqual(rt.dem_terrain_height(100.0, 0.0, 0.0, 0.0, params, sampler), 100.0)
        self.assertAlmostEqual(rt.dem_terrain_height(100.0, 60.0, 5.0, 10.0, params, sampler), 120.0)
        middle = rt.dem_terrain_height(100.0, 30.0, 5.0, 10.0, params, sampler)
        self.assertGreater(middle, 99.95)
        self.assertLess(middle, 120.0)

    def test_sampler_uses_datum_and_refuses_missing_coverage(self):
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp);(root/'0'/'0').mkdir(parents=True)
            Image.new('RGB',(256,256),(128,42,0)).save(root/'0'/'0'/'0.png')
            route={'coordinate_system':{'origin':{'lat':0.0,'lon':0.0},'elevation_datum_m':10.0}}
            sample=rt.make_dem_height_sampler(route,{'tile_dir':str(root),'zoom':0,'source':'fixture'})
            self.assertAlmostEqual(sample(0,0),32.0,places=5)
            (root/'0'/'0'/'0.png').unlink()
            with self.assertRaisesRegex(ValueError,'DEM'):
                rt.make_dem_height_sampler(route,{'tile_dir':str(root),'zoom':0,'source':'fixture'})

    def test_build_keeps_physical_road_and_produces_dem_outer_height(self):
        from tools import route_model as rm
        with tempfile.TemporaryDirectory() as tmp:
            root=Path(tmp); (root/'dem/0/0').mkdir(parents=True)
            Image.new('RGB',(256,256),(128,110,0)).save(root/'dem/0/0/0.png')
            raw={'route_id':'dem_test','sample_interval_m':1.0,
                 'coordinate_system':{'origin':{'lat':0.0,'lon':0.0,'altitude_m':0.0},'elevation_reference':'msl'},
                 'samples':{'s':list(range(21)),'x':list(range(21)),'z':[0.0]*21,'elevation_m':[100.0]*21,
                            'width_left_m':[3.0]*21,'width_right_m':[3.0]*21,'surface_type':['gravel']*21}}
            route=rm.finalize(raw)
            packages=[]
            for name in ('default','dem'):
                pkg=root/name;(pkg/'route').mkdir(parents=True);(pkg/'route/route.json').write_text(json.dumps(route));packages.append(pkg)
            rt.build(str(packages[0]),tile_m=50)
            man=rt.build(str(packages[1]),tile_m=50,terrain={'dem':{'tile_dir':str(root/'dem'),'zoom':0,'source':'fixture'}})
            self.assertEqual((packages[0]/'tiles/00/road.glb').read_bytes(),(packages[1]/'tiles/00/road.glb').read_bytes())
            self.assertEqual(rt.validate(str(packages[1]))[0],[])
            self.assertEqual(man['layers']['P1_terrain']['status'],'dem_estimated')
            terrain=rt.read_glb(str(packages[1]/'tiles/00/terrain.glb'))
            world=rt._world(terrain)
            outer=[world[i][1] for i,u in enumerate(terrain['attributes']['_ROUTE_U']) if abs(u)>=63]
            self.assertTrue(outer)
            self.assertTrue(all(abs(y-110.0)<0.01 for y in outer))

    def test_sampler_requires_explicit_source_attribution(self):
        route={'coordinate_system':{'origin':{'lat':0.0,'lon':0.0}}}
        with self.assertRaisesRegex(ValueError,'source attribution'):
            rt.make_dem_height_sampler(route,{'tile_dir':'unused','zoom':0})

    def test_reach_transition_only_reduces_reach_and_obeys_rate(self):
        stations=[0.0,1.0,2.0,3.0,4.0]
        raw=[10.0,10.0,2.0,10.0,10.0]
        out=rt.limit_reach_change(stations,raw,2.0)
        self.assertEqual(out,[6.0,4.0,2.0,4.0,6.0])
        self.assertTrue(all(a<=b for a,b in zip(out,raw)))
        self.assertTrue(all(abs(b-a)<=2.0 for a,b in zip(out,out[1:])))
        with self.assertRaisesRegex(ValueError,'positive'):
            rt.limit_reach_change(stations,raw,0)

    def test_sampler_rejects_missing_geographic_origin(self):
        with self.assertRaisesRegex(ValueError,'origin'):
            rt.make_dem_height_sampler({'coordinate_system':{}},{'tile_dir':'unused','zoom':0})
