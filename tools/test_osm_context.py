#!/usr/bin/env python3
"""osm_context: frame round trip, tag widths, and P3 removal keeping every per-instance array aligned."""
import json
import os
import tempfile
import unittest

import osm_context as oc


class OsmContextTest(unittest.TestCase):
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
