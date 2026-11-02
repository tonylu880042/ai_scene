#!/usr/bin/env python3
"""osm_context: frame round trip, tag widths, and P3 removal keeping every per-instance array aligned."""
import math
import json
import os
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import osm_context as oc


class OsmContextTest(unittest.TestCase):
    def test_roof_rectangles_and_concave_fallback(self):
        ring = [(0, 0), (16, 0), (16, 8), (0, 8)]
        plan = oc.roof_plan({'building': 'house'}, ring, 6.8)
        self.assertEqual(plan['shape'], 'hipped')
        self.assertEqual(len(plan['ridge']), 2)
        self.assertGreater(math.dist(*plan['ridge']), 0)
        concave = [(0, 0), (12, 0), (12, 4), (4, 4), (4, 12), (0, 12)]
        self.assertEqual(oc.roof_plan({'building': 'house'}, concave, 6.8)['shape'], 'flat')
        self.assertEqual(oc.roof_plan({'building': 'house'}, concave, 6.8)['method'], 'concave/irregular: flat with parapet')

    def test_shelter_is_open_under_thin_slab(self):
        m = oc.building_mesh()
        ring = [(0, 0), (12, 0), (12, 6), (0, 6)]
        record = oc.building_appearance({'building': 'roof'}, ring, 3.7, 'estimated from building class', 1)
        oc.extrude(m, ring, -.3, 3.7, record['wall_color_linear'], record['roof_color_linear'], False,
                   record=record, floor_y=0)
        self.assertEqual(record['geometry']['mode'], 'open_shelter')
        self.assertEqual(record['geometry']['slab_thickness_m'], .18)
        # No vertical enclosing face crossing the middle of the shelter edge.
        for group, ids in m['groups'].items():
            for k in range(0, len(ids), 3):
                p = [m['positions'][i] for i in ids[k:k+3]]
                self.assertFalse(min(x[1] for x in p) < 1 and max(x[1] for x in p) > 3 and
                                 max(x[0] for x in p)-min(x[0] for x in p) > 2)

    def test_wall_uv_restarts_and_ground_origin(self):
        m = oc.building_mesh()
        ring = [(0, 0), (10, 0), (10, 5), (0, 5)]
        rec = oc.building_appearance({'building': 'garage'}, ring, 4, 'estimated from building class', 1)
        oc.extrude(m, ring, -.3, 5, rec['wall_color_linear'], rec['roof_color_linear'], False,
                   record=rec, floor_y=1, segment_ground=[0, .5, 1, .2])
        self.assertEqual([w['uv_u_range_m'][0] for w in rec['walls']], [0]*4)
        self.assertEqual([w['uv_ground_y_m'] for w in rec['walls']], [.5, 1, 1, .2])
        for w in rec['walls']:
            self.assertEqual(w['window_count'], 0)
            a, b = w['vertex_range']
            self.assertAlmostEqual(m['uv'][a][1], 1-w['uv_ground_y_m'])
            self.assertEqual(b-a, 4)

    def test_hole_triangulation_area(self):
        outer = [(0, 0), (10, 0), (10, 10), (0, 10)]
        hole = [(3, 3), (7, 3), (7, 7), (3, 7)]
        tris = oc.surface_triangles(outer, [hole])
        self.assertAlmostEqual(sum(abs(oc.rt._polygon_area2_xz(t))/2 for t in tris), 84)
        for tri in tris:
            self.assertFalse(oc._point_in_ring(sum(p[0] for p in tri)/3, sum(p[1] for p in tri)/3, hole+[hole[0]]))

    def test_relation_stitching_and_part_minimum(self):
        origin = {'lat': 0., 'lon': 0.}
        ll = lambda ring: [dict(zip(('lat','lon'), oc.to_latlon(origin,*p))) for p in ring]
        outer = [(0,0),(20,0),(20,20),(0,20),(0,0)]
        inner = [(5,5),(15,5),(15,15),(5,15),(5,5)]
        elements = [{'type':'relation','id':10,'tags':{'type':'multipolygon','building':'apartments'},
                     'members':[{'type':'way','ref':11,'role':'outer','geometry':ll(outer[:3])},
                                {'type':'way','ref':12,'role':'outer','geometry':ll(outer[2:])},
                                {'type':'way','ref':13,'role':'inner','geometry':ll(inner)}]}]
        with tempfile.TemporaryDirectory() as d:
            p=os.path.join(d,'osm.json');json.dump({'elements':elements},open(p,'w'))
            found=list(oc.footprints_of(p,origin))
        self.assertEqual(len(found),1)
        self.assertEqual(len(found[0][0]['_inners']),1)
        self.assertEqual(oc.minimum_height({'building:min_level':'3'}), (9.3, 'osm building:min_level × 3.1 m (conversion estimated)'))

    def test_tagged_roof_planes_and_height_envelope(self):
        ring=[(0,0),(16,0),(16,8),(0,8)]
        for shape in ('gabled','hipped','skillion','flat','pyramidal'):
            with self.subTest(shape=shape):
                rec=oc.building_appearance({'building':'house','roof:shape':shape,'height':'10'},ring,10,'osm height tag',1)
                feature=({'type':'way','id':1,'_inners':[],'_outer_index':0},rec['osm_tags'] if 'osm_tags' in rec else {'building':'house','roof:shape':shape,'height':'10'},ring,(8,4))
                m=oc.building_mesh();out,_=oc._emit_feature(m,feature,10,'osm height tag',[0]*4,0,'P4')
                self.assertEqual(out['roof_shape'],shape)
                self.assertAlmostEqual(max(p[1] for p in m['positions']),10)
                self.assertTrue(all(math.isfinite(v) for p in m['positions'] for v in p))
        # The roof plane clipping honours a measured gable even on a concave outline.
        l=[(0,0),(12,0),(12,4),(4,4),(4,12),(0,12)]
        self.assertEqual(oc.roof_plan({'building':'house','roof:shape':'gabled'},l,6.8)['shape'],'gabled')

    def test_parts_cut_parent_walls_and_use_absolute_height(self):
        ring=[(0,0),(20,0),(20,10),(0,10)]
        part=[(10,0),(20,0),(20,10),(10,10)]
        spans=list(oc.wall_segments(ring,[part]))
        self.assertAlmostEqual(sum(math.dist(a,b) for a,b,_ in spans),30)
        tower=({'type':'way','id':2,'_inners':[],'_outer_index':0},
               {'building':'apartments','building:part':'yes','min_height':'9','height':'30'},part,(15,5))
        podium=({'type':'way','id':1,'_inners':[],'_outer_index':0,'_parts':[tower]},
                {'building':'apartments','height':'30'},ring,(10,5))
        m=oc.building_mesh();p,_=oc._emit_feature(m,podium,30,'osm height tag',[2]*4,0,'P4')
        self.assertEqual(p['segment_height_m'],9)
        self.assertEqual(p['height_m'],30)
        m=oc.building_mesh();t,_=oc._emit_feature(m,tower,30,'osm height tag',[2]*4,0,'P4')
        self.assertEqual(t['floor_origin_y_m'],11)
        self.assertAlmostEqual(max(v[1] for v in m['positions']),32)

    def test_short_walls_have_no_openings_and_colours_are_linear(self):
        ring=[(0,0),(10,0),(10,2),(0,2)]
        rec=oc.building_appearance({'building':'house','building:colour':'#808080','roof:colour':'red'},ring,6.8,'estimated',1)
        self.assertAlmostEqual(rec['wall_color_linear'][0],.215861,places=5)
        self.assertEqual(rec['roof_color_linear'],[1.,0.,0.])
        m=oc.building_mesh();oc.extrude(m,ring,-.3,6,rec['wall_color_linear'],rec['roof_color_linear'],False,record=rec,floor_y=0)
        self.assertTrue(all(w['window_count']==w['door_count']==0 for w in rec['walls'] if w['length_m']<2.5))
        self.assertTrue(any(w['door_count'] for w in rec['walls']))

    def test_pbr_assets_are_packaged_and_validated(self):
        from pathlib import Path
        import build_package_assets as bpa
        from PIL import Image
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);pkg=root/'package';pkg.mkdir();(pkg/'manifest.json').write_text('{}')
            image=root/'map.jpg';Image.new('RGB',(2,2),(128,128,255)).save(image)
            library={'_materials':{name:{'license':'CC0','attribution':'test','url':'https://polyhaven.com/license',
                                       'repeat_m':2,'diffuse':str(image),'normal':str(image),'roughness':str(image)}
                                    for name in ('osm_facade','osm_roof')}}
            bpa.build_material_assets(pkg,library)
            ring=[(0,0),(12,0),(12,6),(0,6)]
            m=oc.building_mesh();feature=({'type':'way','id':1,'_inners':[],'_outer_index':0},{'building':'house'},ring,(6,3))
            rec,_=oc._emit_feature(m,feature,6.8,'estimated from building class',[0]*4,0,'P4')
            rec['mesh_file']='building.glb';oc.write_buildings_glb(str(pkg/'building.glb'),'test',m,str(pkg),[rec])
            (pkg/'structures').mkdir();(pkg/'structures/osm_buildings.json').write_text(json.dumps({'buildings':[rec]}))
            self.assertEqual(oc.validate_buildings(str(pkg)),[])
            material=json.loads((pkg/'assets/materials/osm_buildings.json').read_text())['materials']['osm_facade']
            (pkg/material['diffuse']).unlink()
            self.assertTrue(oc.validate_buildings(str(pkg)))
            library['_materials']['osm_facade']['license']='CC-BY'
            with self.assertRaisesRegex(ValueError,'CC0'):bpa.build_material_assets(pkg,library)

    def test_foundation_includes_interior_terrain_extrema(self):
        # An interior dip is invisible to footprint-corner sampling.
        tris=[[(0,2,0),(10,2,0),(5,-1,5)],[(10,2,0),(10,2,10),(5,-1,5)],
              [(10,2,10),(0,2,10),(5,-1,5)],[(0,2,10),(0,2,0),(5,-1,5)]]
        class Ground:
            ground_xz_cell_m=64
            ground_triangles_xz={(0,0):[((0,10,0,10),t) for t in tris]}
            def ground_world(self,x,z,candidates=None):
                ys=[y for t in tris if (y:=oc.veg._bary_y(t,x,z)) is not None]
                return max(ys) if ys else None
        self.assertEqual(oc.footprint_ground_extrema(Ground(),[(0,0),(10,0),(10,10),(0,10)]),(-1,2))

    def test_apartment_parapet_and_floor_balcony_bands(self):
        ring=[(0,0),(12,0),(12,8),(0,8)]
        feature=({'type':'way','id':1,'_inners':[],'_outer_index':0},
                 {'building':'apartments','height':'14','building:levels':'4'},ring,(6,4))
        m=oc.building_mesh();r,_=oc._emit_feature(m,feature,14,'osm height tag',[0]*4,0,'P4')
        self.assertEqual(r['parapet_height_m'],.9)
        self.assertAlmostEqual(max(p[1] for p in m['positions']),14)
        # Projecting slabs on each of the three upper floors are physical mesh vertices.
        for y in (3.1,6.2,9.3):
            self.assertTrue(any(abs(p[1]-y)<1e-5 and abs(p[2]+.6)<1e-5 for p in m['positions']))

    def test_fully_segmented_outline_emits_no_duplicate_parent_block(self):
        ring=[(0,0),(12,0),(12,8),(0,8)]
        part=({'type':'way','id':2,'_inners':[],'_outer_index':0},
              {'building':'apartments','building:part':'yes','height':'15'},ring,(6,4))
        outline=({'type':'way','id':1,'_inners':[],'_outer_index':0,'_parts':[part]},
                 {'building':'apartments','height':'15'},ring,(6,4))
        m=oc.building_mesh();r,_=oc._emit_feature(m,outline,15,'osm height tag',[0]*4,0,'P4')
        self.assertEqual(m['positions'],[])
        self.assertEqual(r['geometry']['mode'],'outline_replaced_by_parts')
        self.assertEqual(r['height_m'],15)  # measured parent retained as identity/provenance

    def test_residential_has_one_estimated_entrance(self):
        ring=[(0,0),(12,0),(12,8),(0,8)]
        rec=oc.building_appearance({'building':'house'},ring,6.8,'estimated',1)
        m=oc.building_mesh()
        oc.extrude(m,ring,-.3,6,rec['wall_color_linear'],rec['roof_color_linear'],False,record=rec,floor_y=0)
        self.assertEqual(sum(w['door_count'] for w in rec['walls']),1)
        self.assertGreater(sum(w['window_count'] for w in rec['walls']),0)

    def test_exact_osm_landmark_replaces_duplicate_geometry_only(self):
        objects=[{'object_id':'chapel','importance':'high','attributes':{'osm_way_id':'42'}},
                 {'object_id':'generic','importance':'low','attributes':{'osm_way_id':'43'}}]
        index=oc.osm_landmark_index(objects)
        self.assertEqual(index, {'way/42':'chapel'})
        ring=[(0,0),(12,0),(12,6),(0,6)]
        f=({'type':'way','id':42,'_inners':[],'_outer_index':0},{'building':'chapel'},ring,(6,3))
        mesh=oc.building_mesh();record,footprint=oc._emit_feature(mesh,f,4.1,'osm building:levels',[0]*4,10,'P4',landmark_id=index['way/42'])
        self.assertEqual(mesh['positions'],[])
        self.assertEqual(record['osm_id'],'way/42')
        self.assertEqual(record['represented_by_structure'],'chapel')
        self.assertEqual(record['height_source'],'osm building:levels')
        self.assertTrue(footprint)

    def test_frame_round_trip(self):
        origin = {"lat": -27.93465, "lon": 153.40685}
        x, z = oc.to_xz(origin, -27.94, 153.41)
        self.assertGreater(x, 0)   # east
        self.assertGreater(z, 0)   # south is +Z
        lat, lon = oc.to_latlon(origin, x, z)
        self.assertAlmostEqual(lat, -27.94, places=9)
        self.assertAlmostEqual(lon, 153.41, places=9)

    def test_width_tags(self):
        self.assertEqual(oc.way_width({"highway": "primary", "width": "9 m"}), 9.0)
        self.assertAlmostEqual(oc.way_width({"highway": "primary", "lanes": "2"}), 7.4)
        self.assertEqual(oc.way_width({"highway": "service"}), oc.CLASS_WIDTH_M["service"])

    def test_building_height_precedence(self):
        self.assertEqual(oc.building_height({"building": "yes", "height": "21 m", "building:levels": "3"}), (21.0, "osm height tag"))
        self.assertAlmostEqual(oc.building_height({"building": "yes", "building:levels": "4"})[0], 4 * oc.LEVEL_M + 1.0)
        height, source = oc.building_height({"building": "apartments"})
        self.assertEqual(source, "estimated from building class")
        self.assertAlmostEqual(height, oc.CLASS_LEVELS["apartments"] * oc.LEVEL_M + 0.6)

    def test_neighbour_height_is_bounded(self):
        towers = [38.2, 38.2, 25.8]
        self.assertEqual(oc.building_height({"building": "yes"}, towers, 400.0),
                         (oc.NEIGHBOUR_MAX_M, "estimated: median of measured OSM neighbours"))
        for tags, area in (({"building": "yes", "amenity": "shelter"}, 400.0), ({"building": "yes"}, 85.0),
                           ({"building": "garage"}, 400.0)):
            self.assertEqual(oc.building_height(tags, towers, area)[1], "estimated from building class")
        self.assertEqual(oc.building_height({"building": "yes"}, towers[:2], 400.0)[1], "estimated from building class")

    def test_water_sides(self):
        origin = {"lat": 0.0, "lon": 0.0}
        to_ll = lambda x, z: dict(zip(("lat", "lon"), oc.to_latlon(origin, x, z)))
        with tempfile.TemporaryDirectory() as d:
            path = os.path.join(d, "water.json")
            # Coastline running north (-z) along x = 0: OSM keeps land on the left (west), water on the right (east).
            coast = {"type": "way", "tags": {"natural": "coastline"}, "geometry": [to_ll(0, 100), to_ll(0, -100)]}
            pond = {"type": "way", "tags": {"natural": "water"},
                    "geometry": [to_ll(-60, -5), to_ll(-50, -5), to_ll(-50, 5), to_ll(-60, 5), to_ll(-60, -5)]}
            json.dump({"elements": [coast, pond]}, open(path, "w"))
            water = oc.Water(path, origin)
            self.assertTrue(water(20, 0))
            self.assertFalse(water(-20, 0))
            self.assertTrue(water(-55, 0))   # inside the pond, on the land side of the coast

    def test_coastal_water_band(self):
        import road_terrain as rt
        coast = {"water_edge_m": 10.0, "water_level_m": 0.0, "bank_width_m": 4.0}
        band = dict(coast, water_far_m=30.0)
        for u in (2.0, 20.0, 60.0):  # without water_far_m the profile is unchanged by the new option
            self.assertEqual(rt.coastal_height(3.0, 3.0, 1.6, u, coast), rt.coastal_height(3.0, 3.0, 1.6, u, dict(coast, water_far_m=None)))
        self.assertAlmostEqual(rt.coastal_height(3.0, 3.0, 1.6, 20.0, band), -0.8)  # inside the band: water bed
        self.assertAlmostEqual(rt.coastal_height(3.0, 3.0, 1.6, 60.0, band), 3.0)   # land again beyond it
        self.assertAlmostEqual(rt.coastal_height(3.0, 3.0, 1.6, 60.0, coast), -0.8)
        self.assertTrue(rt.coastal_sand(band, 29.0) and not rt.coastal_sand(band, 31.0) and rt.coastal_sand(coast, 40.0))
        self.assertFalse(rt.coastal_sand(band, 29.0, y=1.5))     # land-height face inside a band stays ground
        self.assertTrue(rt.coastal_sand(coast, 40.0, y=1.5))     # plain coast profiles ignore height (unchanged)

    def test_vegetation_removal_keeps_arrays_aligned(self):
        with tempfile.TemporaryDirectory() as pkg:
            os.makedirs(os.path.join(pkg, "tiles", "00"))
            group = {"proto": "tree", "category": "deciduous_tree", "count": 3,
                     "data": [v for x in (1.0, 5.0, 9.0) for v in (x, 0, 0.5, 0, 0, 0, 1, 1, 1, 1)],
                     "s": [1, 5, 9], "lateral_offset_m": [3, 3, 3], "zone": ["a", "b", "c"]}
            path = os.path.join(pkg, "tiles", "00", "vegetation.json")
            json.dump({"groups": [group]}, open(path, "w"))
            man = {"tiles": [{"id": "00", "files": {"vegetation": "tiles/00/vegetation.json"}}]}
            street = [((4.0, 0.0), (6.0, 0.0), (6.0, 1.0)), ((4.0, 0.0), (6.0, 1.0), (4.0, 1.0))]  # covers x=5 only
            self.assertEqual(oc.remove_covered_vegetation(pkg, man, {"00": street}), 1)
            kept = json.load(open(path))["groups"][0]
            self.assertEqual(kept["count"], 2)
            self.assertEqual(kept["s"], [1, 9])
            self.assertEqual(kept["zone"], ["a", "c"])
            self.assertEqual(len(kept["data"]), 20)
            self.assertEqual(kept["data"][10], 9.0)


if __name__ == "__main__":
    unittest.main()
