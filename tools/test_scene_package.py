#!/usr/bin/env python3
"""Tests for the canonical route (tools/route_model.py), the road/terrain stage (tools/road_terrain.py) and the
near-route semantics (tools/semantics.py), vegetation (tools/vegetation.py), structures (tools/structures.py) and environment (tools/environment.py).

  python3 -m unittest tools/test_scene_package.py -v
"""
import copy
import json
import math
import os
import shutil
import struct
import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_route as br  # noqa: E402
import build_semantics as bs  # noqa: E402
import build_package_assets as bpa  # noqa: E402
import road_terrain as rt  # noqa: E402
import route_model as rm  # noqa: E402
import semantics as sm  # noqa: E402
import environment as en  # noqa: E402
import environment_hints as eh  # noqa: E402
import validate_package as vp  # noqa: E402
import structures as stc  # noqa: E402
import gltf_mesh  # noqa: E402
import vegetation as vg  # noqa: E402
import candidate_workflow as cw  # noqa: E402


def raw_route(length=1200, grade=7.0, radius=None, step=1.0, width=(3.0, 3.0), surfaces=("asphalt",), datum_elev=100.0):
    """Primary facts of a synthetic route heading east, straight or bending LEFT with the given radius."""
    n = int(length / step)
    s = [i * step for i in range(n + 1)]
    if radius:
        x = [radius * math.sin(v / radius) for v in s]
        z = [-radius * (1 - math.cos(v / radius)) for v in s]  # left of east = north = -Z
    else:
        x, z = list(s), [0.0] * len(s)
    surf = [surfaces[min(int(v / length * len(surfaces)), len(surfaces) - 1)] for v in s]
    return {"route_id": "test", "sample_interval_m": step,
            "samples": {"s": s, "x": x, "z": z, "elevation_m": [datum_elev + v * grade / 100.0 for v in s],
                        "width_left_m": [width[0]] * len(s), "width_right_m": [width[1]] * len(s), "surface_type": surf},
            "checkpoints": [{"id": "cp1", "s": length / 2}]}


def errors_matching(route, text):
    return [e for e in rm.validate(route) if text in e]


class RouteModelTest(unittest.TestCase):
    def test_valid_route_passes(self):
        self.assertEqual(rm.validate(rm.finalize(raw_route())), [])

    # grade calculation
    def test_grade_is_vertical_change_over_horizontal_distance(self):
        r = rm.finalize(raw_route(grade=7.0))
        for g in r["samples"]["grade_percent"]:
            self.assertAlmostEqual(g, 7.0, places=2)

    def test_grade_on_a_bend_uses_horizontal_distance(self):
        r = rm.finalize(raw_route(grade=-6.0, radius=150))
        self.assertEqual(rm.validate(r), [])
        self.assertAlmostEqual(r["samples"]["grade_percent"][300], -6.0, places=2)

    def test_visual_exaggeration_never_changes_physical_grade(self):
        legacy = {"step": 1.0, "length": 500.0, "s": list(range(501)), "x": [float(v) for v in range(501)],
                  "y": [-0.2 + 1.5 * 0.07 * v for v in range(501)], "z": [0.0] * 501,
                  "half_left": [2.0] * 501, "half_right": [2.0] * 501}
        r = rm.from_legacy(legacy, "legacy_test", vertical_exaggeration=1.5, surface="asphalt")
        self.assertEqual(rm.validate(r), [])
        self.assertAlmostEqual(r["samples"]["grade_percent"][250], 7.0, places=2)
        self.assertAlmostEqual(r["samples"]["elevation_m"][-1] - r["samples"]["elevation_m"][0], 35.0, places=3)
        self.assertEqual(r["visual"]["vertical_exaggeration"], 1.5)

    def test_stored_grade_must_match_elevation(self):
        r = rm.finalize(raw_route())
        r["samples"]["grade_percent"][50] += 1.0
        self.assertTrue(errors_matching(r, "grade_percent != d(elevation)"))

    def test_heading_and_curvature(self):
        r = rm.finalize(raw_route(radius=200))
        self.assertAlmostEqual(r["samples"]["heading_deg"][0], 90.0, delta=0.5)  # east
        self.assertLess(r["samples"]["heading_deg"][100], 90.0)                   # turning left = towards north
        self.assertAlmostEqual(r["samples"]["curvature"][300], 1 / 200, delta=1e-4)  # + = left

    # distance continuity
    def test_s_must_increase(self):
        r = rm.finalize(raw_route())
        r["samples"]["s"][10] = r["samples"]["s"][9]
        self.assertTrue(errors_matching(r, "strictly increasing"))

    def test_s_must_start_at_zero(self):
        raw = raw_route()
        raw["samples"]["s"] = [v + 5 for v in raw["samples"]["s"]]
        self.assertTrue(errors_matching(rm.finalize(raw), "start at 0"))

    def test_centreline_gap_detected(self):
        raw = raw_route()
        raw["samples"]["x"] = [v + (5.0 if i > 600 else 0.0) for i, v in enumerate(raw["samples"]["x"])]
        self.assertTrue(errors_matching(rm.finalize(raw), "centreline gap"))

    def test_uneven_sampling_detected(self):
        r = rm.finalize(raw_route())
        r["samples"]["s"][10] += 0.5
        self.assertTrue(errors_matching(r, "sample interval"))

    # elevation continuity
    def test_elevation_jump_detected(self):
        raw = raw_route()
        raw["samples"]["elevation_m"] = [v + (5.0 if i >= 400 else 0.0) for i, v in enumerate(raw["samples"]["elevation_m"])]
        self.assertTrue(errors_matching(rm.finalize(raw), "elevation jump"))

    def test_non_finite_elevation_detected(self):
        r = rm.finalize(raw_route())
        r["samples"]["elevation_m"][3] = float("nan")
        self.assertTrue(errors_matching(r, "non-finite"))

    def test_y_must_follow_physical_elevation(self):
        r = rm.finalize(raw_route())
        r["samples"]["y"][20] *= 1.5
        self.assertTrue(errors_matching(r, "y != elevation_m"))

    # width validity
    def test_zero_or_negative_width_rejected(self):
        for bad in (0.0, -1.0):
            r = rm.finalize(raw_route())
            r["samples"]["width_right_m"][7] = bad
            self.assertTrue(errors_matching(r, "width_right_m must be"))

    # start / finish consistency
    def test_start_after_finish_rejected(self):
        r = rm.finalize(raw_route())
        r["start"]["s"], r["finish"]["s"] = r["finish"]["s"], r["start"]["s"]
        self.assertTrue(errors_matching(r, "start.s"))

    def test_finish_beyond_route_rejected(self):
        raw = raw_route()
        raw["finish"] = {"id": "finish", "s": 5000.0}
        self.assertTrue(errors_matching(rm.finalize(raw), "start.s"))

    def test_checkpoint_outside_start_finish_rejected(self):
        raw = raw_route()
        raw["start"] = {"id": "start", "s": 700.0}
        self.assertTrue(errors_matching(rm.finalize(raw), "checkpoint cp1"))

    def test_marker_position_must_match_route(self):
        r = rm.finalize(raw_route())
        r["finish"]["position"][1] += 1.0
        self.assertTrue(errors_matching(r, "finish.position"))

    def test_duplicate_marker_ids_rejected(self):
        raw = raw_route()
        raw["checkpoints"][0]["id"] = "start"
        self.assertTrue(errors_matching(rm.finalize(raw), "not unique"))

    def test_schema(self):
        r = rm.finalize(raw_route())
        r["samples"]["surface_type"][0] = "lava"
        self.assertTrue(errors_matching(r, "not in"))
        del r["route_id"]
        self.assertTrue(errors_matching(r, "missing route_id"))


class BuildRouteTest(unittest.TestCase):
    """tools/build_route.py: synthetic routes without Godot (scripts/route.gd's centre line, grade and widths)."""
    def test_weissensee_matches_godot_export(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
        with open(os.path.join(root, "weissensee_sections.json")) as f:
            secs = json.load(f)
        with open(os.path.join(root, "programs.json")) as f:
            segs = json.load(f)["rolling_hills"]
        # MainScene_weissensee.tscn's Path3D; values from tools/export_route.gd (Godot 4.7) on that scene
        r = br.build(segs, secs, bend=0.6, start_height=0.0, road_left=1.4, road_right=1.4)
        self.assertEqual(rm.validate(r), [])
        smp = r["samples"]
        for i, want in [(2500, [2344.3655, 139.1356, 56.48, 0.6, 0.6, "dirt"]),
                        (5000, [4735.6147, 402.5444, 113.34, 1.0, 1.0, "gravel"])]:
            got = [smp[k][i] for k in ["x", "z", "elevation_m", "width_left_m", "width_right_m", "surface_type"]]
            for g, w in zip(got[:3], want[:3]):
                self.assertAlmostEqual(g, w, delta=0.005)
            self.assertEqual(got[3:], want[3:])
        self.assertEqual((len(r["sections"]), r["checkpoints"][-1]["s"], r["finish"]["s"]), (71, 4000.0, 4988.0))

    def test_section_turns_grade_and_widths(self):
        secs = {"video_km": 3.0, "types": {"a": {"surface": "asphalt_02", "half": [1.0, 1.0]},
                                          "b": {"surface": "gravel_floor_02", "half": [3.0, 2.0], "road": 3.0}},
                "sections": [[0, "a"], [1, "b", {"turn": 90}], [2, "a", {"turn": [30, -30]}]]}
        r = br.build([[18, 4, "Climb"]], secs)  # 18 min at 6:00 / km = 3 km, 4 %
        smp = r["samples"]
        self.assertEqual(rm.validate(r), [])
        self.assertAlmostEqual(smp["heading_deg"][500], 90.0, places=3)  # straight east before the first turn
        self.assertAlmostEqual(rm.wrap180(smp["heading_deg"][2000] - smp["heading_deg"][1000]), -90.0, delta=0.5)
        self.assertAlmostEqual(rm.wrap180(smp["heading_deg"][3000] - smp["heading_deg"][2000]), 0.0, delta=0.5)
        self.assertLess(abs(smp["curvature"][1000]), 1e-3)  # each bend eases in: no kink where it starts
        self.assertAlmostEqual(smp["grade_percent"][1500], 4.0, places=2)  # physical: no grade_scale
        self.assertAlmostEqual(smp["elevation_m"][-1] + 0.2, 0.04 * 3000.0, delta=1.0)  # minus ~20 m of easing
        self.assertEqual((smp["width_left_m"][1500], smp["width_right_m"][1500], smp["surface_type"][1500]),
                         (3.0, 5.0, "gravel"))
        self.assertTrue(1.0 < smp["width_left_m"][1000] < 3.0)  # eased over ~14 m at the change
        self.assertEqual([(x["from_s"], x["to_s"]) for x in r["sections"]],
                         [(0.0, 1000.0), (1000.0, 2000.0), (2000.0, 3000.0)])


class EnvironmentHintsTest(unittest.TestCase):
    """tools/environment_hints.py: environment/hints.json from the .tscn text, without Godot."""
    def test_weissensee_matches_godot_adapter(self):
        h = eh.build("res://scenes/MainScene_weissensee.tscn", "rolling_hills")
        # values from tools/export_environment_hints.gd (Godot 4.7) on that scene / course
        for g, w in zip(h["sun"]["direction_to_sun"], [0.310525, 0.681998, -0.662157]):
            self.assertAlmostEqual(g, w, delta=1e-4)
        self.assertEqual((h["sun"]["color"], h["sun"]["left_of_travel_deg"], h["sun"]["elevation_from_hdri"]),
                         ([1.0, 0.95, 0.88], 75.0, True))
        self.assertAlmostEqual(h["sun"]["energy"], 1.5)
        self.assertAlmostEqual(h["ambient"]["energy"], 1.4)  # CourseSetup's lerp, not the scene's 1.2
        self.assertEqual((h["fog"]["color"], h["fog"]["mist"], h["grading"]["tonemap"]), ([0.62, 0.75, 0.9], None, "agx"))
        self.assertAlmostEqual(h["fog"]["density"], 0.00035)
        self.assertEqual([round(x, 4) for x in h["time_of_day"]["phase"]], [0.35, 0.6])
        self.assertTrue(h["sky"]["hdri"].endswith("assets/hdri/kloofendal_43d_clear_puresky_4k.hdr"))
        self.assertEqual((h["sky"]["sun_u"], h["sky"]["sun_elevation_deg"]), (0.6005, 43.0))
        rtd = h["real_terrain"]
        self.assertEqual((rtd["name"], rtd["anchor"], rtd["sink_west_of"], rtd["hole_depth"], rtd["follow"]),
                         ("weissensee", [3152.0, 1123.0], 1660.0, -600.0, {"base_y": 0.0, "route_water": True, "route_yaw": True}))
        self.assertEqual(h["water"], [{"name": "LakeFar", "size_m": [40000.0, 40000.0], "base_y": -0.08, "follows_route_water": True,
                                       "deep_color": [0.03, 0.34, 0.46], "shallow_color": [0.12, 0.6, 0.58], "roughness": 0.12}])
        self.assertEqual(len(h["water_offset_m"]), 201)
        self.assertEqual([h["water_offset_m"][i] for i in (0, 1, -1)], [[0.0, -4.773], [25.0, -4.607], [5000.0, -4.04]])
        self.assertEqual([h["godot_backdrop_yaw_rad"][i] for i in (1, -2, -1)], [[25.0, -0.00511], [4975.0, 0.57712], [5000.0, 0.59463]])
        self.assertEqual(h["cloud_volumes"], [])

    def test_value_parser(self):
        self.assertEqual(eh.value('Color(0.1, 0.2, 0.3, 1)'), [0.1, 0.2, 0.3])
        self.assertEqual(eh.value('NodePath("../Path3D")'), "../Path3D")
        self.assertEqual(eh.value('{"a": Vector2(1, 2), "b": true}'), {"a": [1.0, 2.0], "b": True})
        self.assertEqual((eh.value("-INF"), eh.value("Vector2.ZERO")), (-math.inf, [0, 0]))


class RoadTerrainTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.pkg = cls._package("base", raw_route(length=1200, grade=-6.0, radius=400, surfaces=("asphalt", "gravel")))
        cls.manifest = rt.build(cls.pkg, tile_m=500)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    @classmethod
    def _package(cls, name, raw):
        pkg = os.path.join(cls.tmp, name)
        os.makedirs(os.path.join(pkg, "route"))
        with open(os.path.join(pkg, "route", "route.json"), "w") as f:
            json.dump(rm.finalize(raw), f)
        return pkg

    def _copy(self, name):
        dst = os.path.join(self.tmp, name)
        shutil.copytree(self.pkg, dst)
        return dst

    def test_package_validates(self):
        errs, rep = rt.validate(self.pkg)
        self.assertEqual(errs, [])
        self.assertEqual({p["section"] for p in rep["probes"]}, {"start", "middle", "end"})

    def test_tiles_cover_route_with_metadata(self):
        tiles = self.manifest["tiles"]
        self.assertEqual([(t["from_s"], t["to_s"]) for t in tiles], [(0, 500), (500, 1000), (1000, 1200)])
        for t in tiles:
            self.assertTrue(all(os.path.isfile(os.path.join(self.pkg, f)) for f in t["files"].values()))
            self.assertEqual(len(t["bounds"]["min"]), 3)
            self.assertIn("surfaces", t["road"])
        self.assertEqual([r["surface_type"] for r in tiles[1]["road"]["surfaces"]], ["asphalt", "gravel"])

    def test_terrain_noise_never_moves_the_road(self):
        pkg2 = self._package("hilly", raw_route(length=1200, grade=-6.0, radius=400, surfaces=("asphalt", "gravel")))
        rt.build(pkg2, tile_m=500, terrain={"hill_amplitude_m": 80.0, "seed": 99, "vertical_exaggeration": 3.0})
        self.assertEqual(rt.validate(pkg2)[0], [])
        for t in ("00", "01", "02"):
            a = rt.read_glb(os.path.join(self.pkg, "tiles", t, "road.glb"))
            b = rt.read_glb(os.path.join(pkg2, "tiles", t, "road.glb"))
            self.assertEqual(a["attributes"]["POSITION"], b["attributes"]["POSITION"])
        ta = rt.read_glb(os.path.join(self.pkg, "tiles", "01", "terrain.glb"))
        tb = rt.read_glb(os.path.join(pkg2, "tiles", "01", "terrain.glb"))
        self.assertNotEqual(ta["attributes"]["POSITION"], tb["attributes"]["POSITION"])

    def test_coastal_level_root_is_found_between_sparse_lateral_samples(self):
        # The mesh samples a smooth bank at sparse, reach-scaled offsets. A true level anchor
        # must come from the analytic height function, rather than linear interpolation of those samples.
        def surface(d):
            return 2.2 * (1.0 - rt.smoothstep(9.0, 15.8, d)) - 0.8 * rt.smoothstep(9.0, 15.8, d)

        self.assertIsNone(rt._find_level_crossing(surface, 0.0, 0.0, 12.0))
        root = rt._find_level_crossing(surface, 0.0, 0.0, 16.0)
        self.assertIsNotNone(root)
        self.assertAlmostEqual(surface(root), 0.0, places=9)
        self.assertAlmostEqual(root, 13.3, delta=0.2)

    def test_coastal_anchor_strip_connects_ragged_rows_without_losing_projected_area(self):
        positions = []
        lateral = []
        row_a, row_b = [], []
        for x, values, anchor in ((0.0, [0.0, 2.0, 4.0, 6.0], 3.1),
                                  (1.0, [0.0, 1.5, 3.0, 4.5, 6.0], 3.4)):
            row = []
            for z in values:
                row.append(len(positions))
                positions.append((x, (z-anchor)*0.2, -z))
                lateral.append(z)
            row.append(len(positions))
            positions.append((x, 0.0, -anchor))
            lateral.append(anchor)
            row.sort(key=lambda index: lateral[index])
            if x == 0.0:
                row_a = row
            else:
                row_b = row
        anchor_a = min(row_a, key=lambda index: abs(lateral[index]-3.1))
        anchor_b = min(row_b, key=lambda index: abs(lateral[index]-3.4))
        indices = rt._shoreline_strip_indices(row_a, row_b, row_a.index(anchor_a),
                                               row_b.index(anchor_b), lateral, positions)
        self.assertTrue(any({indices[i], indices[i+1]} == {anchor_a, anchor_b}
                            for i in range(0, len(indices), 3)))
        area = sum(abs((positions[indices[i+1]][0]-positions[indices[i]][0]) *
                       (positions[indices[i+2]][2]-positions[indices[i]][2]) -
                       (positions[indices[i+1]][2]-positions[indices[i]][2]) *
                       (positions[indices[i+2]][0]-positions[indices[i]][0])) * 0.5
                   for i in range(0, len(indices), 3))
        self.assertAlmostEqual(area, 6.0, places=6)
        self.assertTrue(all(rt._face_up(positions, indices[i:i+3]) == 0 for i in range(0,len(indices),3)))
        incidence = {}
        for i in range(0, len(indices), 3):
            tri = indices[i:i+3]
            for a, b in ((tri[0],tri[1]),(tri[1],tri[2]),(tri[2],tri[0])):
                edge = tuple(sorted((a,b)))
                incidence[edge] = incidence.get(edge, 0) + 1
        boundary = {tuple(sorted((a,b))) for row in (row_a,row_b)
                    for a,b in zip(row,row[1:])}
        boundary.update((tuple(sorted((row_a[0],row_b[0]))),
                         tuple(sorted((row_a[-1],row_b[-1])))))
        self.assertEqual({edge for edge,count in incidence.items() if count == 1}, boundary)
        self.assertTrue(all(count in (1,2) for count in incidence.values()))
        self.assertEqual(len(indices)//3, len(row_a)+len(row_b)-2)

    def test_coastal_anchor_build_emits_connected_waterline_and_preserves_road(self):
        raw = raw_route(length=20, grade=0.0, step=1.0)
        route = rm.finalize(raw)
        legacy_pkg = self._package("coast_legacy", raw)
        anchored_pkg = self._package("coast_anchored", raw)
        profile = [{"side":"right", "from_s":0.0, "to_s":20.0,
                    "water_edge_m":15.8, "bank_width_m":6.8, "water_level_m":0.0}]
        terrain = {"columns_m":[0.0, 0.6, 2.0, 5.0, 10.0, 20.0],
                   "coast_profiles":profile, "hill_amplitude_m":25.0, "hill_wavelength_m":8.0}
        rt.build(legacy_pkg, tile_m=500, terrain=terrain)
        rt.build(anchored_pkg, tile_m=500, terrain={**terrain, "coastal_waterline_anchors":True})

        legacy_road = Path(legacy_pkg, "tiles/00/road.glb").read_bytes()
        anchored_road = Path(anchored_pkg, "tiles/00/road.glb").read_bytes()
        self.assertEqual(legacy_road, anchored_road)
        self.assertEqual(json.loads(Path(legacy_pkg, "route/route.json").read_text()),
                         json.loads(Path(anchored_pkg, "route/route.json").read_text()))

        mesh = rt.read_glb(os.path.join(anchored_pkg, "tiles", "00", "terrain.glb"))
        world = rt._world(mesh)
        attrs = mesh["attributes"]
        anchors = [i for i, p in enumerate(world)
                   if abs(p[1]) < 1e-5 and attrs["_ROUTE_U"][i] < -3.1]
        self.assertGreaterEqual(len(anchors), 19)  # endpoint samples are seam splits, not analytic roots
        anchor_pairs = set()
        triangle_edges = set()
        for primitive in mesh["primitives"]:
            inds = primitive["indices"]
            for j in range(0, len(inds), 3):
                tri = inds[j:j+3]
                for a,b in ((tri[0],tri[1]),(tri[1],tri[2]),(tri[2],tri[0])):
                    triangle_edges.add(tuple(sorted((a,b))))
                for a in tri:
                    for b in tri:
                        if a != b and a in anchors and b in anchors:
                            if abs(attrs["_ROUTE_S"][a]-attrs["_ROUTE_S"][b]) <= 1.001:
                                anchor_pairs.add(tuple(sorted((a,b))))
        self.assertGreater(len(anchor_pairs), 0)
        roots_by_s={}
        for index in anchors:
            roots_by_s.setdefault(round(attrs["_ROUTE_S"][index],4),[]).append(index)
        variable_root_edges=[]
        for s_value,root_ids in roots_by_s.items():
            for next_s,next_ids in roots_by_s.items():
                if abs(next_s-s_value-1.0)<1e-4:
                    for a in root_ids:
                        for b in next_ids:
                            if tuple(sorted((a,b))) in triangle_edges and abs(attrs["_ROUTE_U"][a]-attrs["_ROUTE_U"][b])>1e-5:
                                variable_root_edges.append((a,b))
        self.assertGreater(len(variable_root_edges), 0)
        self.assertEqual(rt.validate(anchored_pkg)[0], [])

    def test_coastal_anchor_build_preserves_tile_seams_and_exact_sand_band(self):
        raw = raw_route(length=20, grade=0.0, step=1.0)
        pkg = self._package("coast_anchored_seams", raw)
        profile = [{"side":"right", "from_s":5.0, "to_s":15.0,
                    "water_edge_m":15.8, "bank_width_m":6.8, "water_level_m":0.0,
                    "sand_width_m":2.0}]
        terrain = {"columns_m":[0.0, 0.6, 2.0, 5.0, 10.0, 20.0],
                   "coast_profiles":profile, "coastal_waterline_anchors":True,
                   "coastal_exact_sand_boundary":True}
        rt.build(pkg, tile_m=10, terrain=terrain)
        errs, _ = rt.validate(pkg)
        self.assertEqual(errs, [])
        manifest = json.loads(Path(pkg, "manifest.json").read_text())
        anchor_reports=[tile["coastal_waterline_anchors"] for tile in manifest["tiles"]]
        self.assertGreater(sum(item["seam_splits"] for item in anchor_reports), 0)
        self.assertGreater(sum(item["transition_splits"] for item in anchor_reports), 0)
        for tile in manifest["tiles"]:
            self.assertEqual(tile["coastal_exact_sand_boundary"]["status"], "applied")
            self.assertGreater(tile["coastal_exact_sand_boundary"]["triangles_reclassified"], 0)
            mesh = rt.read_glb(os.path.join(pkg, tile["files"]["terrain"]))
            self.assertNotIn("_ACTUAL_POSITION", mesh["attributes"])
            self.assertEqual(len(mesh["attributes"]["POSITION"]),
                             len(mesh["attributes"]["_ROUTE_S"]))
            attrs=mesh["attributes"]
            for primitive in mesh["primitives"]:
                if primitive["material"]["name"]!="shore_sand":
                    continue
                for j in range(0,len(primitive["indices"]),3):
                    tri=primitive["indices"][j:j+3]
                    center_s=sum(attrs["_ROUTE_S"][v] for v in tri)/3
                    center_outward=-sum(attrs["_ROUTE_U"][v] for v in tri)/3
                    self.assertGreaterEqual(center_s,4.99)
                    self.assertLessEqual(center_s,15.01)
                    self.assertGreaterEqual(center_outward,13.8-1e-5)
        mesh = rt.read_glb(os.path.join(pkg, manifest["tiles"][0]["files"]["terrain"]))
        support_indices=list(mesh["primitives"][0]["indices"][:3])
        support_material={"name":"support_skirt","color":[0.1,0.1,0.1],"roughness":0.9}
        mesh["primitives"].append({"material":support_material,"indices":support_indices})
        remapped, _ = rt._classify_coastal_sand_exact(mesh,profile,0.0,10.0)
        support=[p for p in remapped["primitives"] if p["material"]["name"]=="support_skirt"]
        self.assertEqual(len(support),1)
        self.assertEqual(support[0]["indices"],support_indices)

    def test_coastal_waterline_contour_is_continuous_across_shared_tile_seam(self):
        route=rm.finalize(raw_route(length=4,grade=0.0,step=1.0))
        smp=route["samples"]; D=[0.0,0.6,2.0,5.0,10.0,20.0]
        reaches={-1:[20.0]*len(smp["s"]),1:[20.0]*len(smp["s"])}
        profile=[{"side":"right","from_s":0.0,"to_s":4.0,"water_edge_m":15.8,
                  "bank_width_m":6.8,"water_level_m":0.0}]
        tp={"columns_m":D,"shoulder_drop_m":0.05,"flat_band_m":3.0,"blend_to_m":60.0,
            "hill_amplitude_m":25.0,"hill_wavelength_m":8.0,"vertical_exaggeration":1.0,
            "seed":7,"coast_profiles":profile,"coastal_waterline_anchors":True,
            "coastal_waterline_anchor_range_m":[1.0,3.0],
            "coastal_waterline_anchor_seam_mode":"analytic_level"}
        left=rt._terrain_grid_with_coastal_anchors(smp,[0,1,2],D,reaches,tp)
        right=rt._terrain_grid_with_coastal_anchors(smp,[2,3,4],D,reaches,tp)
        legacy_left=rt._terrain_grid_with_coastal_anchors(
            smp,[0,1,2],D,reaches,{**tp,"coastal_waterline_anchors":False,
                                  "coastal_waterline_anchor_seam_mode":"preserve_cross_section"})

        def row(mesh,station):
            pos,stations,lateral,_,_=mesh
            return sorted((lateral[i],pos[i][1],pos[i]) for i,s in enumerate(stations)
                          if abs(s-smp["s"][station])<1e-5 and lateral[i]<0.0)

        def level_u(points,level=0.0):
            for (u0,y0,_),(u1,y1,_) in zip(points,points[1:]):
                if min(y0,y1)-1e-9<=level<=max(y0,y1)+1e-9:
                    if abs(y1-y0)<1e-12:return u0
                    return u0+(u1-u0)*(level-y0)/(y1-y0)
            self.fail("serialized-style cross-section has no water-level contour")

        left_seam=row(left,2); right_seam=row(right,2)
        self.assertEqual(left_seam,right_seam)  # mesh seam itself is position-continuous
        self.assertGreater(left[4]["range_transition_roots"],0)
        self.assertEqual(row(left,0),row(legacy_left,0))  # range outside edge remains legacy
        u_before=level_u(row(left,1));u_seam=level_u(left_seam);u_after=level_u(row(right,3))
        analytic_distance=rt._coastal_waterline_distance(smp,2,-1,20.0,D,tp,profile[0])
        analytic_u=-(smp["width_right_m"][2]+analytic_distance)
        self.assertAlmostEqual(u_seam,analytic_u,places=6)
        # Distinguish a correct mesh seam from a waterline silhouette step.
        self.assertLess(abs(u_seam-u_before),1.0)
        self.assertLess(abs(u_after-u_seam),1.0)

    def test_coastal_anchor_scope_and_seam_mode_reject_invalid_values(self):
        route=rm.finalize(raw_route(length=4,grade=0.0,step=1.0))
        with self.assertRaisesRegex(ValueError,"seam_mode"):
            rt.build(self._package("bad_coast_seam_mode",raw_route(length=4,grade=0.0,step=1.0)),
                     tile_m=2,terrain={"coastal_waterline_anchor_seam_mode":"silently_ignore"})
        pkg=self._package("bad_coast_range",raw_route(length=4,grade=0.0,step=1.0))
        with self.assertRaisesRegex(ValueError,"route station bounds"):
            rt.build(pkg,tile_m=2,terrain={"coastal_waterline_anchors":True,
                                            "coastal_waterline_anchor_range_m":[0,5]})
        with self.assertRaisesRegex(ValueError,"requires coastal_waterline_anchors"):
            rt.build(self._package("unowned_coast_range",raw_route(length=4,grade=0.0,step=1.0)),
                     tile_m=2,terrain={"coastal_waterline_anchor_range_m":[1,3]})
        with self.assertRaisesRegex(ValueError,"coastal_waterline_capped_exit requires coastal_waterline_anchors"):
            rt.build(self._package("unowned_capped_exit",raw_route(length=4,grade=0.0,step=1.0)),
                     tile_m=2,terrain={"coastal_waterline_capped_exit":True})
        with self.assertRaisesRegex(ValueError,"coastal_waterline_capped_exit requires coastal_waterline_anchor_range_m"):
            rt.build(self._package("unscoped_capped_exit",raw_route(length=4,grade=0.0,step=1.0)),
                     tile_m=2,terrain={"coastal_waterline_anchors":True,
                                       "coastal_waterline_capped_exit":True})
        with self.assertRaisesRegex(ValueError,"requires analytic_level seam mode"):
            rt.build(self._package("preserved_capped_exit",raw_route(length=4,grade=0.0,step=1.0)),
                     tile_m=2,terrain={"coastal_waterline_anchors":True,
                                       "coastal_waterline_capped_exit":True,
                                       "coastal_waterline_anchor_range_m":[0,4]})

    def test_unreachable_coast_root_transition_preserves_capped_domain(self):
        route=rm.finalize(raw_route(length=20,grade=0.0,step=1.0))
        smp=route["samples"]; rows=list(range(len(smp["s"]))); D=[0.0,0.6,2.0,5.0,10.0,20.0]
        reaches={-1:[20.0]*len(rows),1:[20.0]*len(rows)}
        reaches[-1][10]=5.0  # this neighbor cannot reach the analytic crossing; do not widen it
        profile=[{"side":"right","from_s":0.0,"to_s":20.0,"water_edge_m":15.8,
                  "bank_width_m":6.8,"water_level_m":0.0}]
        tp={"columns_m":D,"shoulder_drop_m":0.05,"flat_band_m":3.0,"blend_to_m":60.0,
            "hill_amplitude_m":25.0,"hill_wavelength_m":8.0,"vertical_exaggeration":1.0,
            "seed":7,"coast_profiles":profile,"coastal_waterline_anchors":True}
        def area(pos,idx):
            return sum(abs((pos[idx[k+1]][0]-pos[idx[k]][0])*(pos[idx[k+2]][2]-pos[idx[k]][2])-
                           (pos[idx[k+1]][2]-pos[idx[k]][2])*(pos[idx[k+2]][0]-pos[idx[k]][0]))*0.5
                       for k in range(0,len(idx),3))
        anchored=rt._terrain_grid_with_coastal_anchors(smp,rows,D,reaches,tp)
        legacy=rt._terrain_grid_with_coastal_anchors(smp,rows,D,reaches,{**tp,"coastal_waterline_anchors":False})
        pos,_,_,indices,report=anchored
        self.assertGreater(report["unpaired_roots"],0)
        self.assertAlmostEqual(area(pos,indices),area(legacy[0],legacy[3]),delta=1e-7)
        self.assertTrue(all(rt._face_up(pos,indices[i:i+3])==0 for i in range(0,len(indices),3)))
        incidence={}
        for i in range(0,len(indices),3):
            tri=indices[i:i+3]
            for a,b in ((tri[0],tri[1]),(tri[1],tri[2]),(tri[2],tri[0])):
                edge=tuple(sorted((a,b)));incidence[edge]=incidence.get(edge,0)+1
        self.assertLessEqual(max(incidence.values()),2)

    def test_capped_waterline_exit_connects_root_to_original_outer_edge(self):
        route=rm.finalize(raw_route(length=20,grade=0.0,step=1.0))
        smp=route["samples"]; rows=list(range(len(smp["s"])))
        # The zero crossing is in the second outer cell, so a one-cell-only repair misses it.
        D=[0.0,0.6,2.0,5.0,10.0,15.0,20.0]
        reaches={-1:[20.0]*len(rows),1:[20.0]*len(rows)}
        reaches[-1][10]=5.0
        profile=[{"side":"right","from_s":0.0,"to_s":20.0,"water_edge_m":15.8,
                  "bank_width_m":6.8,"water_level_m":0.0}]
        tp={"columns_m":D,"shoulder_drop_m":0.05,"flat_band_m":3.0,"blend_to_m":60.0,
            "hill_amplitude_m":25.0,"hill_wavelength_m":8.0,"vertical_exaggeration":1.0,
            "seed":7,"coast_profiles":profile,"coastal_waterline_anchors":True,
            "coastal_waterline_anchor_range_m":[0.0,20.0],
            "coastal_waterline_anchor_seam_mode":"analytic_level"}
        legacy=rt._terrain_grid_with_coastal_anchors(smp,rows,D,reaches,tp)
        bounded=rt._terrain_grid_with_coastal_anchors(
            smp,rows,D,reaches,{**tp,"coastal_waterline_capped_exit":True})
        pos,stations,lateral,indices,report=bounded
        self.assertEqual(report["capped_exit_roots"],2)
        self.assertEqual([item["rows"] for item in report["capped_exit_pairs"]],[[9,10],[10,11]])
        self.assertEqual(legacy[4]["unpaired_roots"],2)
        self.assertTrue(all(point in pos for point in legacy[0]))
        self.assertEqual(reaches[-1][10],5.0)  # do not widen the capped row
        def area(points,idx):
            return sum(abs((points[idx[k+1]][0]-points[idx[k]][0])*(points[idx[k+2]][2]-points[idx[k]][2])-
                           (points[idx[k+1]][2]-points[idx[k]][2])*(points[idx[k+2]][0]-points[idx[k]][0]))*0.5
                       for k in range(0,len(idx),3))
        self.assertAlmostEqual(area(pos,indices),area(legacy[0],legacy[3]),delta=1e-7)
        self.assertTrue(all(rt._face_up(pos,indices[k:k+3])==0 for k in range(0,len(indices),3)))
        for pair in report["capped_exit_pairs"]:
            exit_id=pair["exit_vertex"]
            root_id=pair["root_vertex"]
            zero_edges={}
            for k in range(0,len(indices),3):
                tri=indices[k:k+3]
                for a,b in ((tri[0],tri[1]),(tri[1],tri[2]),(tri[2],tri[0])):
                    if abs(pos[a][1])<1e-8 and abs(pos[b][1])<1e-8:
                        zero_edges.setdefault(a,set()).add(b)
                        zero_edges.setdefault(b,set()).add(a)
            reached={root_id};pending=[root_id]
            while pending:
                for neighbor in zero_edges.get(pending.pop(),set())-reached:
                    reached.add(neighbor);pending.append(neighbor)
            self.assertIn(exit_id,reached)
            self.assertLess(pair["analytic_height_residual_m"],1e-9)
            self.assertGreater(pair["root_cell_index"],pair["cap_cell_index"])
            self.assertGreater(pair["line_intersections"],0)
            midpoint=tuple((pos[root_id][k]+pos[exit_id][k])*0.5 for k in range(3))
            def surface_height(points,idx,x,z):
                for q in range(0,len(idx),3):
                    ia,ib,ic=idx[q:q+3];a,b,c=(points[j] for j in (ia,ib,ic))
                    den=(b[2]-c[2])*(a[0]-c[0])+(c[0]-b[0])*(a[2]-c[2])
                    if abs(den)<1e-14:continue
                    wa=((b[2]-c[2])*(x-c[0])+(c[0]-b[0])*(z-c[2]))/den
                    wb=((c[2]-a[2])*(x-c[0])+(a[0]-c[0])*(z-c[2]))/den
                    wc=1-wa-wb
                    if min(wa,wb,wc)>=-1e-8:
                        return wa*a[1]+wb*b[1]+wc*c[1]
                return None
            bounded_mid=surface_height(pos,indices,midpoint[0],midpoint[2])
            legacy_mid=surface_height(legacy[0],legacy[3],midpoint[0],midpoint[2])
            self.assertAlmostEqual(bounded_mid,0.0,delta=1e-8)
            self.assertIsNotNone(legacy_mid)
            self.assertGreater(abs(legacy_mid),1.0)
        incidence={}
        for k in range(0,len(indices),3):
            tri=indices[k:k+3]
            for a,b in ((tri[0],tri[1]),(tri[1],tri[2]),(tri[2],tri[0])):
                edge=tuple(sorted((a,b)));incidence[edge]=incidence.get(edge,0)+1
        self.assertLessEqual(max(incidence.values()),2)

    def test_capped_waterline_split_retains_positive_subthreshold_faces(self):
        eps=1e-15
        positions=[(0.0,0.0,eps),(0.0,0.0,0.0),(0.0,0.0,-eps),
                   (1.0,0.0,eps),(1.0,0.0,-eps),(0.5,0.0,eps)]
        stations=[0.0,0.0,0.0,1.0,1.0,0.5]
        lateral=[-1.0,0.0,1.0,-1.0,1.0,-1.0]
        indices,stats=rt._capped_exit_strip_indices(
            [0,1,2],[3,4],0,3,1,5,0.0,positions,stations,lateral)
        face_areas=[]
        packed=[tuple(struct.unpack("<f",struct.pack("<f",v))[0] for v in p) for p in positions]
        packed_areas=[]
        for k in range(0,len(indices),3):
            a,b,c=(positions[i] for i in indices[k:k+3])
            face_areas.append((b[2]-a[2])*(c[0]-a[0])-(b[0]-a[0])*(c[2]-a[2]))
            a,b,c=(packed[i] for i in indices[k:k+3])
            packed_areas.append((b[2]-a[2])*(c[0]-a[0])-(b[0]-a[0])*(c[2]-a[2]))
        self.assertTrue(all(area>0.0 for area in face_areas))
        self.assertTrue(any(0.0<area<1e-14 for area in face_areas))
        self.assertTrue(any(0.0<area<1e-14 for area in packed_areas))
        self.assertGreater(stats["clipped_triangles"],0)

    def test_capped_waterline_on_cut_vertex_keeps_original_and_adds_level_split(self):
        positions=[(4.0,2.5,-6.0)];stations=[13083.25];lateral=[-15.5]
        original=tuple(positions[0]);cache={}
        split=rt._waterline_copy_vertex(0,0.0,positions,stations,lateral,cache)
        self.assertNotEqual(split,0)
        self.assertEqual(positions[0],original)
        self.assertEqual(positions[split],(4.0,0.0,-6.0))
        self.assertEqual(stations[split],stations[0])
        self.assertEqual(lateral[split],lateral[0])

    def test_exact_coast_material_clip_guards_restored_actual_float32_facets(self):
        mesh={"translation":[0.0,0.0,0.0],"attributes":{
            "POSITION":[(0.0,0.0,0.0),(1.0,0.0,0.0),(0.0,0.0,1.0)],
            "_ACTUAL_POSITION":[(100.0,0.0,100.0),(100.001,0.0,100.0),(100.0,0.0,100.001)]},
            "primitives":[{"material":dict(rt.TERRAIN_MATERIAL),"indices":[0,1,2]}]}
        tiny=1e-4
        region=[[(0.0,0.0,0.0),(tiny,0.0,0.0),(0.0,0.0,tiny)]]
        updated,stats=rt.reclassify_surface_mesh_exact(mesh,region,
            {"name":"shore_sand","color":[0.68,0.59,0.39],"roughness":0.95},
            preserve_source_winding=True)
        self.assertGreater(stats["actual_float32_collapsed_facets_removed"],0)
        self.assertEqual(stats["float32_collapsed_facets_removed"],0)
        self.assertGreater(stats["actual_float32_removed_projected_area_m2"],0.0)
        self.assertTrue(all(len(p["indices"])%3==0 for p in updated["primitives"]))

    def test_local_ground_support_pad_is_indexed_as_shipped_p1_without_moving_road(self):
        pkg = self._copy("local_support_pad")
        road_before = Path(os.path.join(pkg, "tiles", "01", "road.glb")).read_bytes()
        terrain_before = rt.read_glb(os.path.join(pkg, "tiles", "01", "terrain.glb"))
        polygon = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        report = rt.add_local_ground_support_pad(pkg, "01", polygon_xz=polygon, top_y_m=115.0, s_center_m=600.0,
                                                grid_m=5.0,
                                                source={"kind": "test_engineered_pad", "estimated": True})
        self.assertGreater(report["added_vertices"], 4)
        self.assertEqual(Path(os.path.join(pkg, "tiles", "01", "road.glb")).read_bytes(), road_before)
        mesh = rt.read_glb(os.path.join(pkg, "tiles", "01", "terrain.glb"))
        world = rt._world(mesh)
        self.assertTrue(any(abs(p[1] - 115.0) < 1e-4 and 410 <= p[0] <= 420 and -390 <= p[2] <= -380 for p in world))
        self.assertEqual(mesh["attributes"]["NORMAL"][:len(terrain_before["attributes"]["NORMAL"])], terrain_before["attributes"]["NORMAL"])
        with open(os.path.join(pkg,"route/route.json")) as f: route=json.load(f)
        with open(os.path.join(pkg,"manifest.json")) as f: manifest=json.load(f)
        space=vg.Space(pkg,route,manifest,{"zones":[]})
        self.assertIsNotNone(space.ground_world(409.99,-385.0))
        self.assertEqual(rt.validate(pkg)[0], [])

    def test_local_ground_support_pad_rejects_any_canonical_road_triangle_overlap(self):
        pkg = self._copy("road_overlap_support_pad")
        with open(os.path.join(pkg, "route/route.json")) as f:
            route = json.load(f)
        i = min(range(len(route["samples"]["s"])), key=lambda k: abs(route["samples"]["s"][k] - 600))
        x, z = route["samples"]["x"][i], route["samples"]["z"][i]
        polygon = [[x-3,z-3],[x+3,z-3],[x+3,z+3],[x-3,z+3]]
        with self.assertRaisesRegex(ValueError, "overlaps canonical road"):
            rt.add_local_ground_support_pad(pkg, "01", polygon_xz=polygon, top_y_m=10.0, s_center_m=600,
                                            grid_m=2.0, source={"kind":"test","estimated":True})

    def test_local_support_skirt_uses_reference_ground_without_duplicate_top_faces_or_road_changes(self):
        reference = self._copy("skirt_reference")
        target = self._copy("skirt_target")
        polygon = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        top_y = 66.0
        rt.add_local_ground_support_pad(target, "01", polygon_xz=polygon, top_y_m=top_y, s_center_m=600,
                                        grid_m=2.0, source={"kind":"test_engineered_pad","estimated":True})
        terrain_path = os.path.join(target, "tiles", "01", "terrain.glb")
        before = rt.read_glb(terrain_path)
        road_before = Path(os.path.join(target, "tiles", "01", "road.glb")).read_bytes()
        base_triangles = sum(len(p["indices"]) // 3 for p in before["primitives"])
        report = rt.add_local_ground_support_skirt(
            target, "01", reference_pkg=reference, polygon_xz=polygon, top_y_m=top_y, grid_m=2.0,
            source={"kind":"test_reference_terrain","estimated":True}, s_center_m=600,
            max_drop_m=5.0)
        after = rt.read_glb(terrain_path)
        self.assertEqual(Path(os.path.join(target, "tiles", "01", "road.glb")).read_bytes(), road_before)
        self.assertEqual(sum(len(p["indices"]) // 3 for p in after["primitives"]) - base_triangles,
                         report["added_triangles"])
        self.assertGreater(report["added_triangles"], 0)
        self.assertEqual(after["attributes"]["POSITION"][:len(before["attributes"]["POSITION"])],
                         before["attributes"]["POSITION"])
        self.assertEqual(sum(1 for p in after["primitives"] if p["material"]["name"] == "support_skirt"), 1)
        for key, values in before["attributes"].items():
            self.assertEqual(after["attributes"][key][:len(values)], values)
        self.assertEqual(after["primitives"][:-1], before["primitives"])
        skirt_ys = [p[1] + after["translation"][1] for p in after["attributes"]["POSITION"][len(before["attributes"]["POSITION"]):]]
        self.assertAlmostEqual(max(skirt_ys), top_y, places=4)
        self.assertLess(min(skirt_ys), top_y - 0.01)
        new_primitive = after["primitives"][-1]
        world = rt._world(after)
        center_x = sum(p[0] for p in polygon) / 4
        center_z = sum(p[1] for p in polygon) / 4
        for i in range(0, len(new_primitive["indices"]), 3):
            tri = [world[new_primitive["indices"][i+j]] for j in range(3)]
            self.assertGreater(max(p[1] for p in tri) - min(p[1] for p in tri), 0.001)
            a, b, c = tri
            nx = (b[1]-a[1])*(c[2]-a[2])-(b[2]-a[2])*(c[1]-a[1])
            nz = (b[0]-a[0])*(c[1]-a[1])-(b[1]-a[1])*(c[0]-a[0])
            face_x = sum(p[0] for p in tri)/3
            face_z = sum(p[2] for p in tri)/3
            self.assertGreater(nx*(face_x-center_x)+nz*(face_z-center_z), 0.0)
        with open(os.path.join(reference, "route", "route.json")) as f:
            reference_route = json.load(f)
        with open(os.path.join(reference, "manifest.json")) as f:
            reference_manifest = json.load(f)
        reference_space = vg.Space(reference, reference_route, reference_manifest, {"zones": []})
        for p in world[len(before["attributes"]["POSITION"]):]:
            if p[1] < top_y - 0.001:
                self.assertAlmostEqual(reference_space.ground_world(p[0], p[2]), p[1], places=4)
        self.assertEqual(rt.validate(target)[0], [])

    def test_local_support_skirt_rejects_road_overlap_without_writing(self):
        reference = self._copy("skirt_road_reference")
        target = self._copy("skirt_road_target")
        pad = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        rt.add_local_ground_support_pad(target, "01", polygon_xz=pad, top_y_m=66.0, s_center_m=600,
                                        grid_m=2.0, margin_m=0.0,
                                        source={"kind":"test_engineered_pad","estimated":True})
        with open(os.path.join(target, "route", "route.json")) as f:
            route = json.load(f)
        i = min(range(len(route["samples"]["s"])), key=lambda k: abs(route["samples"]["s"][k]-600))
        x, z = route["samples"]["x"][i], route["samples"]["z"][i]
        road_polygon = [[x-3,z-3],[x+3,z-3],[x+3,z+3],[x-3,z+3]]
        terrain_path = os.path.join(target, "tiles", "01", "terrain.glb")
        manifest_path = os.path.join(target, "manifest.json")
        before_terrain, before_manifest = Path(terrain_path).read_bytes(), Path(manifest_path).read_bytes()
        with self.assertRaisesRegex(ValueError, "overlaps canonical road"):
            rt.add_local_ground_support_skirt(
                target, "01", reference_pkg=reference, polygon_xz=road_polygon, top_y_m=66.0,
                grid_m=2.0, s_center_m=600, source={"kind":"test","estimated":True})
        self.assertEqual(Path(terrain_path).read_bytes(), before_terrain)
        self.assertEqual(Path(manifest_path).read_bytes(), before_manifest)

    def test_local_support_skirt_rejects_incompatible_ground_height_without_writing(self):
        reference = self._copy("skirt_height_reference")
        target = self._copy("skirt_height_target")
        polygon = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        rt.add_local_ground_support_pad(target, "01", polygon_xz=polygon, top_y_m=66.0, s_center_m=600,
                                        grid_m=2.0, margin_m=0.0,
                                        source={"kind":"test_engineered_pad","estimated":True})
        terrain_path = os.path.join(target, "tiles", "01", "terrain.glb")
        manifest_path = os.path.join(target, "manifest.json")
        before_terrain, before_manifest = Path(terrain_path).read_bytes(), Path(manifest_path).read_bytes()
        with self.assertRaisesRegex(ValueError, "height incompatible"):
            rt.add_local_ground_support_skirt(
                target, "01", reference_pkg=reference, polygon_xz=polygon, top_y_m=66.0,
                grid_m=2.0, s_center_m=600, max_drop_m=0.01,
                source={"kind":"test","estimated":True}, margin_m=0.0)
        self.assertEqual(Path(terrain_path).read_bytes(), before_terrain)
        self.assertEqual(Path(manifest_path).read_bytes(), before_manifest)

    def test_local_support_skirt_rejects_a_ground_hole_inside_a_triangle_interval(self):
        reference = self._copy("skirt_interval_reference")
        target = self._copy("skirt_interval_target")
        polygon = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        rt.add_local_ground_support_pad(target, "01", polygon_xz=polygon, top_y_m=66.0, s_center_m=600,
                                        grid_m=2.0, margin_m=0.0,
                                        source={"kind":"test_engineered_pad","estimated":True})
        manifest_path = os.path.join(reference, "manifest.json")
        reference_manifest = json.loads(Path(manifest_path).read_text())
        reference_manifest["tiles"] = [t for t in reference_manifest["tiles"] if str(t["id"]).zfill(2) == "01"]
        Path(manifest_path).write_text(json.dumps(reference_manifest))
        # Two tiny source triangles touch a single pad-edge interval while leaving its center unsupported.
        positions = [(409.9,65.0,-390.1),(410.3,65.0,-390.1),(410.1,65.0,-389.8),
                     (411.7,65.0,-390.1),(412.1,65.0,-390.1),(411.9,65.0,-389.8)]
        mesh = {"name":"terrain_gap_fixture", "translation":[0,0,0],
                "attributes":{"POSITION":positions,"NORMAL":[(0,1,0)]*6,"TEXCOORD_0":[(p[0],p[2]) for p in positions],
                              "_ROUTE_S":[600.0]*6,"_ROUTE_U":[10.0]*6},
                "primitives":[{"material":dict(rt.TERRAIN_MATERIAL),"indices":[0,1,2,3,4,5]}]}
        rt.write_glb(os.path.join(reference, "tiles", "01", "terrain.glb"), mesh)
        terrain_path = os.path.join(target, "tiles", "01", "terrain.glb")
        target_manifest_path = os.path.join(target, "manifest.json")
        before_terrain, before_manifest = Path(terrain_path).read_bytes(), Path(target_manifest_path).read_bytes()
        with self.assertRaisesRegex(ValueError, "no reference ground inside"):
            rt.add_local_ground_support_skirt(
                target, "01", reference_pkg=reference, polygon_xz=polygon, top_y_m=66.0,
                grid_m=2.0, s_center_m=600, source={"kind":"test","estimated":True}, margin_m=0.0)
        self.assertEqual(Path(terrain_path).read_bytes(), before_terrain)
        self.assertEqual(Path(target_manifest_path).read_bytes(), before_manifest)

    def test_local_support_skirt_buries_overlapping_ground_endpoint_without_floating(self):
        reference = self._copy("skirt_overlap_reference")
        target = self._copy("skirt_overlap_target")
        polygon = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        rt.add_local_ground_support_pad(target, "01", polygon_xz=polygon, top_y_m=66.0, s_center_m=600,
                                        grid_m=2.0, margin_m=0.0,
                                        source={"kind":"test_engineered_pad","estimated":True})

        # Replace the single reference tile with an explicit two-level terrain overlap.
        # The low plane covers the pad; the higher plane starts inside its south edge.
        reference_path = os.path.join(reference, "tiles", "01", "terrain.glb")
        origin = [123.0, 17.0, -91.0]
        positions, indices = [], []
        for xmin, xmax, ymin in ((400.0, 430.0, 63.0), (415.25, 430.0, 64.0)):
            base = len(positions)
            positions.extend([(xmin,ymin,-400.0), (xmax,ymin,-400.0),
                              (xmax,ymin,-370.0), (xmin,ymin,-370.0)])
            indices.extend((base,base+1,base+2, base,base+2,base+3))
        local_positions = [(x-origin[0],y-origin[1],z-origin[2]) for x,y,z in positions]
        ground = {"name":"terrain_ground", "color":list(rt.TERRAIN_MATERIAL["color"]),
                  "roughness":rt.TERRAIN_MATERIAL["roughness"]}
        rt.write_glb(reference_path, {"name":"stacked_ground_fixture", "translation":origin,
            "attributes":{"POSITION":local_positions,"NORMAL":[(0.0,1.0,0.0)]*len(positions),
                          "TEXCOORD_0":[(x,z) for x,y,z in positions],
                          "_ROUTE_S":[600.0]*len(positions),"_ROUTE_U":[10.0]*len(positions)},
            "primitives":[{"material":ground,"indices":indices}]})
        manifest_path = os.path.join(reference, "manifest.json")
        manifest = json.loads(Path(manifest_path).read_text())
        manifest["tiles"] = [tile for tile in manifest["tiles"] if str(tile["id"]).zfill(2) == "01"]
        manifest["tiles"][0]["bounds"] = {"min":[400.0,63.0,-400.0],"max":[430.0,64.0,-370.0]}
        Path(manifest_path).write_text(json.dumps(manifest))

        target_path = os.path.join(target, "tiles", "01", "terrain.glb")
        before_skirt = rt.read_glb(target_path)
        first_skirt_vertex = len(before_skirt["attributes"]["POSITION"])
        patch = rt.add_local_ground_support_skirt(
            target, "01", reference_pkg=reference, polygon_xz=polygon, top_y_m=66.0,
            grid_m=2.0, s_center_m=600, max_drop_m=5.0, margin_m=0.0,
            source={"kind":"test_overlapping_ground_layers","estimated":True})

        # The serialized bottom edge has two copies at this owner transition. They must
        # share the low-plane height even though the other adjacent interval follows y=64.
        written = rt.read_glb(target_path)
        world = rt._world(written)
        transition = [world[i] for i in range(first_skirt_vertex, len(world))
                      if abs(world[i][0]-415.25) < 1e-4 and abs(world[i][2]+390.0) < 1e-4
                      and world[i][1] < 65.9]
        self.assertGreaterEqual(len(transition), 2, "both serialized skirt intervals must retain the shared endpoint")
        self.assertTrue(all(abs(point[1]-63.0) < 1e-4 for point in transition), transition)

        # Independently check each serialized bottom span against the piecewise planar fixture.
        bottom = []
        for i in range(first_skirt_vertex, len(world), 4):
            bottom.extend((world[i+3], world[i+2]))
        for a, b in zip(bottom[::2], bottom[1::2]):
            for fraction in (0.1, 0.5, 0.9):
                x = a[0] + (b[0]-a[0])*fraction
                ground_y = 64.0 if x > 415.25 else 63.0
                self.assertLessEqual(a[1] + (b[1]-a[1])*fraction, ground_y + 0.001)
        self.assertLessEqual(patch["max_ground_gap_m"], 0.001)
        self.assertGreater(patch["max_ground_burial_m"], 0.1)
        self.assertLess(patch["max_ground_burial_m"], 5.0)

    def test_local_support_skirt_validator_still_rejects_a_horizontal_downward_face(self):
        reference = self._copy("skirt_winding_reference")
        target = self._copy("skirt_winding_target")
        polygon = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        rt.add_local_ground_support_pad(target, "01", polygon_xz=polygon, top_y_m=66.0, s_center_m=600,
                                        grid_m=2.0, margin_m=0.0,
                                        source={"kind":"test_engineered_pad","estimated":True})
        rt.add_local_ground_support_skirt(
            target, "01", reference_pkg=reference, polygon_xz=polygon, top_y_m=66.0,
            grid_m=2.0, s_center_m=600, max_drop_m=5.0, margin_m=0.0,
            source={"kind":"test_reference_terrain","estimated":True})
        path = os.path.join(target, "tiles", "01", "terrain.glb")
        mesh = rt.read_glb(path)
        offset = len(mesh["attributes"]["POSITION"])
        origin = mesh["translation"]
        points = [(411.0,66.0,-389.0),(413.0,66.0,-389.0),(411.0,66.0,-387.0)]
        mesh["attributes"]["POSITION"].extend([(x-origin[0],y-origin[1],z-origin[2]) for x,y,z in points])
        mesh["attributes"]["NORMAL"].extend([(0.0,-1.0,0.0)]*3)
        mesh["attributes"]["TEXCOORD_0"].extend([(x,z) for x,y,z in points])
        mesh["attributes"]["_ROUTE_S"].extend([600.0]*3)
        mesh["attributes"]["_ROUTE_U"].extend([10.0]*3)
        mesh["primitives"][-1]["indices"].extend([offset,offset+1,offset+2])
        rt.write_glb(path, mesh)
        errs, _ = rt.validate(target)
        self.assertTrue(any("terrain triangles folded / facing down" in error for error in errs), errs)

    def test_local_support_skirt_rejects_missing_reference_ground_without_writing(self):
        reference = self._copy("skirt_missing_reference")
        target = self._copy("skirt_missing_target")
        polygon = [[410.0, -390.0], [420.0, -390.0], [420.0, -380.0], [410.0, -380.0]]
        rt.add_local_ground_support_pad(target, "01", polygon_xz=polygon, top_y_m=115.0, s_center_m=600,
                                        grid_m=2.0, source={"kind":"test_engineered_pad","estimated":True})
        mesh_path = os.path.join(reference, "tiles", "01", "terrain.glb")
        os.remove(mesh_path)
        terrain_path = os.path.join(target, "tiles", "01", "terrain.glb")
        before = Path(terrain_path).read_bytes()
        manifest_path = os.path.join(target, "manifest.json")
        manifest_before = Path(manifest_path).read_bytes()
        with self.assertRaisesRegex(ValueError, "no reference ground"):
            rt.add_local_ground_support_skirt(
                target, "01", reference_pkg=reference, polygon_xz=polygon, top_y_m=66.0, grid_m=2.0,
                source={"kind":"test_reference_terrain","estimated":True}, s_center_m=600)
        self.assertEqual(Path(terrain_path).read_bytes(), before)
        self.assertEqual(Path(manifest_path).read_bytes(), manifest_before)

    def test_coast_profile_preserves_road_and_edge_but_submerges_water_ground(self):
        pkg = self._package("coast", raw_route(length=30, grade=0, width=(2, 2), datum_elev=4))
        rt.build(pkg, tile_m=20, terrain={"hill_amplitude_m": 0})
        with open(os.path.join(pkg, "tiles/00/road.glb"), "rb") as f: original = f.read()
        rt.build(pkg, tile_m=20, terrain={"hill_amplitude_m": 0, "coast_profiles": [
            {"from_s": 0, "to_s": 30, "side": "left", "water_edge_m": 10, "water_level_m": 0}]})
        with open(os.path.join(pkg, "tiles/00/road.glb"), "rb") as f: self.assertEqual(f.read(), original)
        mesh = rt.read_glb(os.path.join(pkg, "tiles/00/terrain.glb"))
        pos = rt._world(mesh)
        for u, p in zip(mesh["attributes"]["_ROUTE_U"], pos):
            if abs(u - 2) < .001: self.assertAlmostEqual(p[1], 4, places=5)
            if u > 25: self.assertLess(p[1], 0)
            if u < -25: self.assertGreater(p[1], 3)
        self.assertEqual(rt.validate(pkg)[0], [])

    def test_rebuild_retains_existing_acceptance_reference(self):
        pkg = self._package("reviewed_candidate", raw_route(length=20, grade=0))
        with open(os.path.join(pkg,"acceptance.json"),"w") as f:
            json.dump({"status":"blocked"}, f)
        self.assertEqual(rt.build(pkg)["acceptance"], "acceptance.json")

    def test_tight_bend_terrain_does_not_fold(self):
        pkg = self._package("hairpin", raw_route(length=400, grade=3.0, radius=40))
        rt.build(pkg, tile_m=250)
        self.assertEqual([e for e in rt.validate(pkg)[0] if "fold" in e], [])

    def test_tight_walkway_terrain_can_be_narrower_than_legacy_verge(self):
        pkg = self._package("tight_walkway", raw_route(length=10, grade=3.0, radius=2.5,
                                                     step=0.25, width=(2.0, 2.0)))
        with open(os.path.join(pkg, "route", "route.json")) as handle:
            original = handle.read()
        rt.build(pkg, tile_m=5, terrain={"hill_amplitude_m": 0.0})
        self.assertEqual(rt.validate(pkg)[0], [])
        with open(os.path.join(pkg, "route", "route.json")) as handle:
            self.assertEqual(handle.read(), original)

    def test_impossible_offset_corridor_is_rejected_before_export(self):
        pkg = self._package("impossible_corridor", raw_route(length=5, grade=0.0, radius=1.0,
                                                            step=0.1, width=(2.0, 2.0)))
        with self.assertRaisesRegex(ValueError, "corridor|offset"):
            rt.build(pkg, tile_m=5)
        self.assertFalse(os.path.exists(os.path.join(pkg, "manifest.json")))

    def _tamper_road(self, pkg, tile, fn):
        path = os.path.join(pkg, "tiles", tile, "road.glb")
        mesh = rt.read_glb(path)
        mesh["attributes"]["POSITION"] = [fn(i, p, mesh) for i, p in enumerate(mesh["attributes"]["POSITION"])]
        rt.write_glb(path, mesh)

    def test_detects_road_elevation_error(self):
        pkg = self._copy("bad_elev")
        self._tamper_road(pkg, "01", lambda i, p, m: (p[0], p[1] + (0.2 if i == 300 else 0.0), p[2]))
        self.assertTrue([e for e in rt.validate(pkg)[0] if "elevation differs" in e])

    def test_detects_road_slope_error(self):
        pkg = self._copy("bad_slope")  # tilt one tile's road: 2 % steeper than the route says
        self._tamper_road(pkg, "01", lambda i, p, m: (p[0], p[1] - 0.02 * (m["attributes"]["_ROUTE_S"][i] - 500), p[2]))
        self.assertTrue([e for e in rt.validate(pkg)[0] if "slope_pp differs" in e])

    def test_detects_tile_gap(self):
        pkg = self._copy("gap")
        man_path = os.path.join(pkg, "manifest.json")
        with open(man_path) as f:
            man = json.load(f)
        del man["tiles"][1]
        with open(man_path, "w") as f:
            json.dump(man, f)
        self.assertTrue([e for e in rt.validate(pkg)[0] if "road gap" in e])

    def test_detects_seam_discontinuity(self):
        pkg = self._copy("seam")
        self._tamper_road(pkg, "01", lambda i, p, m: (p[0] + (0.05 if m["attributes"]["_ROUTE_S"][i] == 500 else 0.0), p[1], p[2]))
        self.assertTrue([e for e in rt.validate(pkg)[0] if "seam 00|01" in e])

    def test_detects_width_mismatch(self):
        pkg = self._copy("width")
        rp = os.path.join(pkg, "route", "route.json")
        with open(rp) as f:
            r = json.load(f)
        r["samples"]["width_left_m"] = [w + 0.5 for w in r["samples"]["width_left_m"]]
        with open(rp, "w") as f:
            json.dump(r, f)
        self.assertTrue([e for e in rt.validate(pkg)[0] if "width differs" in e])

    def test_glb_round_trip(self):
        mesh = rt.read_glb(os.path.join(self.pkg, "tiles", "00", "road.glb"))
        path = os.path.join(self.tmp, "copy.glb")
        rt.write_glb(path, copy.deepcopy(mesh))
        self.assertEqual(rt.read_glb(path), mesh)


def zone(zid, t, side, a, b, lat, conf=0.8, **attrs):
    return {"id": zid, "semantic_type": t, "side": side, "from_s": a, "to_s": b, "lateral_offset_m": list(lat),
            "confidence": conf, "attributes": attrs, "source": {"kind": "manual", "ref": "test"}}


class SemanticsTest(unittest.TestCase):
    """2000 m route, 3 m either side; the three statements from the brief as zones."""

    def setUp(self):
        self.route = rm.finalize(raw_route(length=2000, grade=2.0, width=(3.0, 3.0)))
        self.sem = {"version": "0.1", "route_id": "test", "extent_m": 150, "zones": [
            zone("road", "trail", "both", 0, 2000, (-3, 3)),
            zone("forest", "forest", "right", 1250, 1600, (-60, -4), density="dense"),
            zone("houses", "building_zone", "left", 1380, 1500, (12, 25), kind="chalets"),
            zone("bank", "grass", "left", 1500, 2000, (3, 5)),
            zone("lake", "water", "left", 1520, 2000, (5, 150), kind="lake"),
            zone("rail", "guardrail", "right", 1700, 1800, (-3.4, -3.1)),
        ]}

    def errs(self, text):
        return [e for e in sm.validate(self.sem, self.route) if text in e]

    def test_valid(self):
        self.assertEqual(sm.validate(self.sem, self.route), [])

    def test_append_zones_preserves_existing_zones_and_is_idempotent(self):
        original = copy.deepcopy(self.sem["zones"])
        addition = zone("local_fence", "fence", "left", 800, 840, (8, 9), kind="timber_rail")
        self.assertEqual(sm.append_zones(self.sem, [addition], self.route), 1)
        self.assertEqual(self.sem["zones"][:len(original)], original)
        self.assertEqual(sm.append_zones(self.sem, [addition], self.route), 0)
        self.assertEqual(self.sem["zones"][:len(original)], original)
        self.assertEqual(sm.validate(self.sem, self.route), [])

    def test_append_invalid_zone_rolls_back(self):
        original = copy.deepcopy(self.sem["zones"])
        invalid = zone("outside", "fence", "left", 1990, 2010, (8, 9), kind="timber_rail")
        with self.assertRaises(ValueError):
            sm.append_zones(self.sem, [invalid], self.route)
        self.assertEqual(self.sem["zones"], original)

    def test_split_surface_region_preserves_verge_and_clips_future_vegetation(self):
        route = rm.finalize(raw_route(length=100, width=(2, 2)))
        sem = {"version":"0.1", "route_id":route["route_id"], "extent_m":150,
               "zones":[zone("road","trail","both",0,100,(-2,2)),
                        zone("lawn","grass","left",20,80,(2,30),kind="park"),
                        zone("trees","vegetation_zone","left",20,80,(4,60),kind="scattered_trees"),
                        zone("far_trees","vegetation_zone","left",20,80,(50,60),kind="scattered_trees")]}
        mapping = sm.split_surface_region(sem, from_s=40, to_s=60, side="left",
                 lateral_offset_m=(8,40), surface_type="open_space",
                 attributes={"kind":"parking apron","surface":"asphalt"},
                 source={"kind":"map","estimated":True,"ref":"OSM ways","note":"estimated bounds"})
        self.assertEqual(len(mapping["lawn"]), 4)
        self.assertEqual(len(mapping["trees"]), 4)
        self.assertNotIn("far_trees", mapping)
        self.assertEqual(sm.validate(sem, route), [])
        asphalt = [z for z in sem["zones"] if z["semantic_type"] == "open_space"]
        self.assertEqual([(z["from_s"],z["to_s"],z["lateral_offset_m"]) for z in asphalt], [(40,60,[8.0,30])])
        self.assertEqual([z["lateral_offset_m"] for z in sem["zones"]
                          if z["semantic_type"] == "vegetation_zone" and z["from_s"] == 40], [[4,8],[40,60]])

    def test_describe_reads_like_the_brief(self):
        self.assertIn("dense forest begins 4.0-60.0 m right of the centreline (1.0 m beyond the trail edge",
                      " ".join(sm.describe(self.sem, self.route, 1250)))
        self.assertIn("chalets building zone runs 12.0-25.0 m left", " ".join(sm.describe(self.sem, self.route, 1400)))
        self.assertIn("lake water begins 5.0-150.0 m left", " ".join(sm.describe(self.sem, self.route, 1520)))

    def test_queries_for_later_stages(self):
        self.assertEqual([z["id"] for z in sm.zones_at(self.sem, 1550, side="left")], ["bank", "lake"])
        self.assertEqual([z["id"] for z in sm.zones_in(self.sem, 1200, 1300, {"forest", "vegetation_zone"})], ["forest"])

    def test_nothing_but_route_surface_in_the_playable_band(self):
        self.sem["zones"][1]["lateral_offset_m"] = [-60, -2]
        self.assertTrue(self.errs("forest intrudes into the playable band"))

    def test_side_must_match_offsets(self):
        self.sem["zones"][2]["side"] = "right"
        self.assertTrue(self.errs("side right"))

    def test_both_only_for_route_surfaces(self):
        self.sem["zones"][5].update(side="both", lateral_offset_m=[-3.4, 3.4])
        self.assertTrue(self.errs("side both"))

    def test_route_surface_must_be_described_everywhere(self):
        self.sem["zones"][0]["to_s"] = 1500
        self.assertTrue(self.errs("route surface not described"))

    def test_one_ground_cover_per_spot(self):
        self.sem["zones"][3]["lateral_offset_m"] = [3, 8]  # grass reaching into the lake
        self.assertTrue(self.errs("overlaps lake (water)"))

    def test_no_forest_in_water(self):
        self.sem["zones"].append(zone("wet", "forest", "left", 1600, 1700, (20, 40)))
        self.assertTrue(self.errs("overlaps wet (forest)") or self.errs("wet (forest) overlaps"))

    def test_ranges_inside_route_and_extent(self):
        self.sem["zones"][4]["to_s"] = 2500
        self.sem["zones"][1]["lateral_offset_m"] = [-400, -4]
        self.assertTrue(self.errs("to_s <= total_length_m"))
        self.assertTrue(self.errs("beyond extent_m"))

    def test_confidence_and_route_id(self):
        self.sem["zones"][1]["confidence"] = 1.5
        self.sem["route_id"] = "other"
        self.assertTrue(self.errs("confidence"))
        self.assertTrue(self.errs("route_id"))

    def test_schema(self):
        self.sem["zones"][1]["semantic_type"] = "lava"
        self.assertTrue(self.errs("not in"))

    @unittest.skipUnless(os.path.isfile("export/packages/weissensee_rolling_hills/semantics/semantics.json"),
                         "generate with tools/export_semantics.gd")
    def test_generated_weissensee_example(self):
        route, sem = sm._load_pkg("export/packages/weissensee_rolling_hills")
        self.assertEqual(sm.validate(sem, route), [])


class BuildSemanticsTest(unittest.TestCase):
    """tools/build_semantics.py: tools/export_semantics.gd's zones without Godot."""
    def test_noise_matches_godot(self):  # FastNoiseLite.new(), seed 5, get_noise_2d (Godot 4.7)
        for (x, y), want in [((0.0, 1.4), -0.0212239064), ((37.0, 3.5), 0.1320121735), ((-250.3, 77.7), 0.2233056873),
                             ((4000.0, 1.4), -0.2036522627), ((1234.5, -987.6), 0.0625508800)]:
            self.assertAlmostEqual(bs.noise2(5, x, y), want, delta=1e-5)

    def test_weissensee_matches_godot_adapter(self):
        root = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "data")
        with open(os.path.join(root, "weissensee_sections.json")) as f:
            secs = json.load(f)
        with open(os.path.join(root, "programs.json")) as f:
            segs = json.load(f)["rolling_hills"]
        route = br.build(segs, secs, route_id="weissensee_rolling_hills", bend=0.6, start_height=0.0,
                         road_left=1.4, road_right=1.4)
        # MainScene_weissensee.tscn's Path3D / Foliage / Buildings exports
        sem = bs.build(secs, route, "data/weissensee_sections.json", sea_y=-12.0, inland_slope=1.0, bank_ratio=0.45,
                       bank_run=3.0, cliff_lip=0.4, max_dist=38.0, trees_per_chunk=70, buildings=True)
        self.assertEqual(sm.validate(sem, route), [])
        counts = {}
        for z in sem["zones"]:
            counts[z["semantic_type"]] = counts.get(z["semantic_type"], 0) + 1
        self.assertEqual(counts, {"bridge": 2, "building_zone": 12, "cliff": 2, "fence": 19, "forest": 127, "grass": 114,
                                  "guardrail": 6, "open_space": 2, "road": 4, "sidewalk": 4, "slope": 171, "trail": 82,
                                  "vegetation_zone": 169, "water": 90})
        # zones as tools/export_semantics.gd writes them (Godot 4.7); z0446's lake edge depends on the bank noise
        by_id = {z["id"]: z for z in sem["zones"]}
        for zid, t, a, lat, vert, edge in [
                ("z0165", "trail", 836.81, [-0.7, 0.7], [0.0, 0.0], None),
                ("z0169", "water", 836.81, [13.43, 150.0], [-15.0, -8.4], [13.4, 28.1]),
                ("z0319", "cliff", 1883.52, [-16.1, -2.1], [0.0, 26.0], None),
                ("z0446", "water", 2757.14, [40.82, 150.0], [-16.2, -8.3], [40.8, 56.4]),
                ("z0603", "grass", 3765.93, [1.25, 24.59], [-3.2, 0.0], None)]:
            z = by_id[zid]
            self.assertEqual((z["semantic_type"], z["from_s"], z["vertical_offset_m"], z["attributes"].get("edge_m")),
                             (t, a, vert, edge))
            for g, w in zip(z["lateral_offset_m"], lat):
                self.assertAlmostEqual(g, w, delta=0.02)


class VegetationTest(unittest.TestCase):
    """1000 m straight route, 3 m either side: forest right, grass + lake left, a house block, a guardrail, a tunnel."""

    def test_split_density_zone_records_remap_instances_without_transform_changes(self):
        zone = {"id":"v0001","kind":"sparse_trees","semantic_zone":"z0001","side":"left",
                "from_s":0,"to_s":100,"lateral_offset_m":[2,20],
                "mix":[{"prototype":"oak","density_per_ha":10,"free_area_ha":1.0,"count":8,"target_count":8}]}
        semantic_pieces = [
            {"id":"z0002","semantic_type":"vegetation_zone","from_s":0,"to_s":100,"lateral_offset_m":[2,8]},
            {"id":"z0003","semantic_type":"open_space","from_s":0,"to_s":100,"lateral_offset_m":[8,14]},
            {"id":"z0004","semantic_type":"vegetation_zone","from_s":0,"to_s":100,"lateral_offset_m":[14,20]},
        ]
        split = vg.split_zones_by_semantics([zone], {"z0001":semantic_pieces})
        self.assertEqual([z["lateral_offset_m"] for z in split], [[2,8],[14,20]])
        tile = {"zone_refs":["v0001","v_keep"],"groups":[{"proto":"oak","zone":[0,0],"s":[20,70],
                "lateral_offset_m":[4,17],"data":[1,2,3,0,0,0,1,1,1,1,4,5,6,0,0,0,1,1,1,1]}]}
        before = copy.deepcopy(tile["groups"][0]["data"])
        self.assertEqual(vg.remap_existing_zone_refs(tile,{"v0001":split}),2)
        self.assertEqual(tile["zone_refs"], ["v_keep",split[0]["id"],split[1]["id"]])
        self.assertEqual(tile["groups"][0]["zone"],[1,2])
        self.assertEqual(tile["groups"][0]["data"],before)

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.pkg = os.path.join(cls.tmp, "veg")
        os.makedirs(os.path.join(cls.pkg, "route"))
        with open(os.path.join(cls.pkg, "route", "route.json"), "w") as f:
            json.dump(rm.finalize(raw_route(length=1000, grade=3.0, width=(3.0, 3.0))), f)
        rt.build(cls.pkg, tile_m=500, terrain={"hill_amplitude_m": 5.0})
        cls.sem = {"version": "0.1", "route_id": "test", "extent_m": 150, "zones": [
            zone("road", "trail", "both", 0, 1000, (-3, 3)),
            zone("tunnel", "tunnel", "both", 800, 900, (-8, 8)),
            zone("forest", "forest", "right", 0, 600, (-60, -3), density="dense", stems_per_ha=300,
                 species={"beech": 0.5, "spruce": 0.5}),
            zone("houses", "building_zone", "right", 600, 700, (-40, -8)),
            zone("scatter", "vegetation_zone", "right", 600, 1000, (-60, -3), kind="scattered_trees", stems_per_ha=40),
            zone("rail", "guardrail", "right", 300, 400, (-3.4, -3.1)),
            zone("grass", "grass", "left", 0, 1000, (3, 12), cover=0.8),
            zone("lake", "water", "left", 0, 1000, (12, 150)),
            zone("wood_by_lake", "forest", "left", 0, 1000, (3, 12), density="medium"),
            zone("crag", "cliff", "right", 900, 1000, (-30, -10), height_m=20),
        ]}
        os.makedirs(os.path.join(cls.pkg, "semantics"))
        with open(os.path.join(cls.pkg, "semantics", "semantics.json"), "w") as f:
            json.dump(cls.sem, f)
        cls.zones, cls.n = vg.build(cls.pkg, seed=3)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def instances(self, pkg=None):
        out = []
        for t in ("00", "01"):
            with open(os.path.join(pkg or self.pkg, "tiles", t, "vegetation.json")) as f:
                d = json.load(f)
            for g in d["groups"]:
                out += [(g["category"], s, u) for s, u in zip(g["s"], g["lateral_offset_m"])]
        return out

    def _copy(self, name):
        dst = os.path.join(self.tmp, name)
        shutil.copytree(self.pkg, dst)
        return dst

    def _edit_tile(self, pkg, fn):
        path = os.path.join(pkg, "tiles", "00", "vegetation.json")
        with open(path) as f:
            d = json.load(f)
        fn(d)
        with open(path, "w") as f:
            json.dump(d, f)

    def test_valid_and_categories(self):
        self.assertEqual(vg.validate(self.pkg)[0], [])
        cats = {c for c, _, _ in self.instances()}
        self.assertTrue({"deciduous_tree", "conifer", "grass", "flowers", "rocks", "ground_cover"} <= cats)
        self.assertEqual({z["kind"] for z in self.zones} >= {"dense_forest", "sparse_trees", "grassland", "rocky_slope"}, True)

    def test_exclusions(self):
        for cat, s, u in self.instances():
            self.assertGreaterEqual(abs(u), 3.0 + vg.CLEARANCE_M[cat], "road clearance")
            self.assertFalse(800 <= s <= 900 and abs(u) <= 8, "inside the tunnel")
            self.assertFalse(600 <= s <= 700 and -40 <= u <= -8, "inside the building zone")
            self.assertFalse(u >= 12, "in the lake")
            if cat in vg.TALL:
                self.assertFalse(300 <= s <= 400 and -3.9 <= u <= -3.0, "between road and guardrail")

    def test_density_follows_zones(self):
        trees = [1 for c, s, u in self.instances() if c in ("deciduous_tree", "conifer") and s < 590 and u < 0]
        area = 590 * (60 - 3 - 1.5) / 10000.0  # minus the tree clearance strip, the guardrail strip is negligible
        self.assertAlmostEqual(len(trees) / area, 300, delta=40)

    def test_deterministic(self):
        pkg = self._copy("again")
        vg.build(pkg, seed=3)
        self.assertEqual(self.instances(pkg), self.instances())

    def test_needs_semantics_first(self):
        pkg = self._copy("no_sem")
        os.remove(os.path.join(pkg, "semantics", "semantics.json"))
        with self.assertRaises(ValueError):
            vg.build(pkg)

    def test_detects_instance_on_the_road(self):
        pkg = self._copy("on_road")

        self._edit_tile(pkg, lambda d: d["groups"][0]["lateral_offset_m"].__setitem__(0, 0.5))
        errs = vg.validate(pkg)[0]
        self.assertTrue([e for e in errs if "road clearance" in e])

    def test_detects_floating_instance(self):
        pkg = self._copy("floating")
        self._edit_tile(pkg, lambda d: d["groups"][0]["data"].__setitem__(1, d["groups"][0]["data"][1] + 1.0))
        self.assertTrue([e for e in vg.validate(pkg)[0] if "terrain mesh" in e])

    def test_detects_density_error(self):
        pkg = self._copy("thin")

        def thin(d):
            for g in d["groups"]:
                if g["category"] == "conifer":
                    keep = g["count"] // 2
                    g.update(count=keep, data=g["data"][:10 * keep], s=g["s"][:keep],
                             lateral_offset_m=g["lateral_offset_m"][:keep], zone=g["zone"][:keep])
        self._edit_tile(pkg, thin)
        self.assertTrue([e for e in vg.validate(pkg)[0] if "density target" in e])

    @unittest.skipUnless(os.path.isfile("export/packages/weissensee_rolling_hills/vegetation/zones.json"),
                         "generate with tools/vegetation.py build")
    def test_generated_weissensee_example(self):
        self.assertEqual(vg.validate("export/packages/weissensee_rolling_hills")[0], [])


class StructuresTest(unittest.TestCase):
    """1000 m route, 3 m either side: lake left, forest + houses right, a fence, a guardrail, a bridge, a tunnel."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.pkg = os.path.join(cls.tmp, "st")
        os.makedirs(os.path.join(cls.pkg, "route"))
        with open(os.path.join(cls.pkg, "route", "route.json"), "w") as f:
            json.dump(rm.finalize(raw_route(length=1000, grade=2.0, width=(3.0, 3.0))), f)
        rt.build(cls.pkg, tile_m=500, terrain={"hill_amplitude_m": 3.0})
        sem = {"version": "0.1", "route_id": "test", "extent_m": 150, "zones": [
            zone("road", "trail", "both", 0, 1000, (-3, 3)),
            zone("bridge", "bridge", "both", 100, 110, (-3.15, 3.15)),
            zone("tunnel", "tunnel", "both", 850, 950, (-8, 8)),
            zone("lake", "water", "left", 0, 1000, (20, 150)),
            zone("grass", "grass", "left", 0, 1000, (3, 20), cover=0.5),
            zone("forest", "forest", "right", 0, 400, (-60, -3), density="dense", stems_per_ha=250),
            zone("houses", "building_zone", "right", 500, 700, (-45, -8), kind="chalets"),
            zone("fence", "fence", "right", 200, 300, (-3.35, -3.05), kind="woodrail"),
            zone("rail", "guardrail", "left", 600, 650, (3.05, 3.35), kind="cable"),
        ]}
        os.makedirs(os.path.join(cls.pkg, "semantics"))
        with open(os.path.join(cls.pkg, "semantics", "semantics.json"), "w") as f:
            json.dump(sem, f)
        vg.build(cls.pkg, seed=2)
        cls.hints = [
            {"semantic_type": "church", "importance": "high", "name": "St. Test chapel", "s": 750, "side": "right",
             "edge_offset_m": 10, "dimensions_m": [12, 15, 20], "confidence": 0.8, "source": {"kind": "video", "ref": "t=1:00"}},
            {"semantic_type": "bench", "prototype": "bench_wood", "importance": "medium", "s": 300, "side": "left",
             "edge_offset_m": 1.0, "source": {"kind": "video", "ref": "t=0:30"}},
            {"semantic_type": "lamp", "prototype": "lamp_lantern", "importance": "low", "s": 520, "side": "right",
             "edge_offset_m": 0.6, "source": {"kind": "video", "ref": "t=0:50"}},
        ]
        cls.objs, cls.skipped = stc.build(cls.pkg, hints=cls.hints)
        cls.by_type = {}
        for o in cls.objs:
            cls.by_type.setdefault(o["semantic_type"], []).append(o)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def _copy(self, name):
        dst = os.path.join(self.tmp, name)
        shutil.copytree(self.pkg, dst)
        return dst

    def _edit(self, pkg, fn):
        path = os.path.join(pkg, "structures", "structures.json")
        with open(path) as f:
            d = json.load(f)
        fn({o["object_id"]: o for o in d["objects"]}, d)
        with open(path, "w") as f:
            json.dump(d, f)

    def _first(self, t):
        return self.by_type[t][0]["object_id"]

    def test_valid(self):
        self.assertEqual(stc.validate(self.pkg)[0], [])

    def test_point_building_validation_reports_all_rigid_world_base_samples(self):
        """Ground reporting must use the transformed mesh footprint, not route-frame proxy corners."""
        pkg = self._copy("rigid_support")
        church = self.by_type["church"][0]
        self._edit(pkg, lambda objs, data: objs[church["object_id"]].setdefault("attributes", {}).update(
            foundation_support={"kind": "flat_rigid_base", "max_gap_m": 0.08, "max_penetration_m": 0.02}))
        errs, report = stc.validate(pkg)
        support = report["ground_support"][church["object_id"]]
        self.assertEqual(support["sample_count"], 9)
        self.assertEqual(support["hit_count"] + support["missing_count"], 9)
        self.assertIn("missing_points", support)

    def test_mesh_support_grid_is_merged_before_quaternion_translation(self):
        obj = {"dimensions_m": {"width": 2.0, "height": 2.0, "depth": 2.0},
               "transform": {"position": [10.0, 5.0, 20.0], "rotation": [0.0, math.sin(math.pi / 4), 0.0, math.cos(math.pi / 4)],
                             "scale": [1.0, 1.0, 1.0]}}
        samples = stc.point_world_mesh_support_samples(obj, [(-1, 0, -1), (1, 0, -1), (1, 0, 1), (-1, 0, 1)])
        self.assertEqual(len(samples), 9)
        self.assertEqual({(round(p["x"], 3), round(p["z"], 3)) for p in samples},
                         {(9.0, 19.0), (10.0, 19.0), (11.0, 19.0), (9.0, 20.0), (10.0, 20.0),
                          (11.0, 20.0), (9.0, 21.0), (10.0, 21.0), (11.0, 21.0)})
        self.assertTrue(all(abs(p["y"] - 5.0) < 1e-9 for p in samples))

    def test_mesh_support_grid_uses_prototype_dimensions_and_instance_scale(self):
        obj = {"dimensions_m": {"width": 2.0, "height": 2.0, "depth": 2.0},
               "prototype_dimensions_m": [1.0, 1.0, 1.0],
               "transform": {"position": [0.0, 0.0, 0.0], "rotation": [0.0, 0.0, 0.0, 1.0],
                             "scale": [1.0, 1.0, 1.0]}}
        samples = stc.point_world_mesh_support_samples(obj, [(0.6, 0, 0.6), (0.6, 0, -0.6),
                                                              (-0.6, 0, 0.6), (-0.6, 0, -0.6)])
        self.assertIn((1.2, 1.2), {(round(p["x"], 3), round(p["z"], 3)) for p in samples})

    def test_float32_glb_mesh_bottom_uses_tile_prototype_scale(self):
        with tempfile.TemporaryDirectory() as tmp:
            path = os.path.join(tmp, "prototype.glb")
            rt.write_glb(path, {"name": "prototype", "translation": [0, 0, 0],
                                "attributes": {"POSITION": [(0.6, 0, 0.6), (0.6, 0, -0.6),
                                                               (-0.6, 0, 0.6), (-0.6, 0, -0.6)]},
                                "primitives": [{"material": {"name": "test", "color": [1, 1, 1], "roughness": 1},
                                                "indices": [0, 1, 2]}]})
            vertices, _ = gltf_mesh.read(path)
            obj = {"dimensions_m": {"width": 2.0, "height": 2.0, "depth": 2.0},
                   "prototype_dimensions_m": [1.0, 1.0, 1.0],
                   "transform": {"position": [0, 0, 0], "rotation": [0, 0, 0, 1],
                                 "scale": [1, 1, 1]}}
            samples = stc.point_world_mesh_support_samples(obj, vertices)
            self.assertIn((1.2, 1.2), {(round(p["x"], 3), round(p["z"], 3)) for p in samples})

    def test_gltf_external_buffer_reads_positions_indices_and_node_transform(self):
        with tempfile.TemporaryDirectory() as tmp:
            raw = __import__("struct").pack("<9f3H", 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2)
            Path(tmp, "mesh.bin").write_bytes(raw)
            doc = {"asset": {"version": "2.0"}, "buffers": [{"uri": "mesh.bin", "byteLength": len(raw)}],
                   "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36},
                                   {"buffer": 0, "byteOffset": 36, "byteLength": 6}],
                   "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                                 {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
                   "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
                   "nodes": [{"mesh": 0, "translation": [2, 3, 4],
                              "rotation": [0, math.sqrt(0.5), 0, math.sqrt(0.5)]}],
                   "scenes": [{"nodes": [0]}], "scene": 0}
            Path(tmp, "asset.gltf").write_text(json.dumps(doc))
            vertices, indices = gltf_mesh.read(str(Path(tmp, "asset.gltf")))
            for got, expected in zip(vertices, [(2, 3, 4), (2, 3, 3), (3, 3, 4)]):
                self.assertTrue(all(abs(a - b) < 1e-6 for a, b in zip(got, expected)))
            self.assertEqual(indices, [0, 1, 2])

    def test_structures_validation_reads_prototype_gltf_with_external_buffer(self):
        pkg = self._copy("gltf_prototype")
        asset_dir = Path(pkg, "assets", "prototypes"); asset_dir.mkdir(parents=True)
        raw = __import__("struct").pack("<9f3H", -0.5, 0, -0.5, 0.5, 0, -0.5, 0, 0, 0.5, 0, 1, 2)
        (asset_dir / "prototype.bin").write_bytes(raw)
        doc = {"asset": {"version": "2.0"}, "buffers": [{"uri": "prototype.bin", "byteLength": len(raw)}],
               "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36},
                               {"buffer": 0, "byteOffset": 36, "byteLength": 6}],
               "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                             {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
               "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
               "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
        (asset_dir / "prototype.gltf").write_text(json.dumps(doc))
        path = Path(pkg, "structures", "prototypes.json")
        prototypes = json.loads(path.read_text())
        proto = next(p for p in prototypes["prototypes"] if p["id"] == "house_chalet")
        proto["mesh_file"] = "assets/prototypes/prototype.gltf"
        path.write_text(json.dumps(prototypes))
        errors, report = stc.validate(pkg)
        hid = self._first("house")
        self.assertFalse(any("cannot be used" in error for error in errors))
        self.assertEqual(report["ground_support"][hid]["sample_kind"],
                         "prototype_lowest_vertices_and_footprint_grid")

    def test_low_unused_mesh_vertex_does_not_define_structure_support_base(self):
        pkg = self._copy("unused_low_vertex")
        asset_dir = Path(pkg, "assets", "prototypes")
        asset_dir.mkdir(parents=True, exist_ok=True)
        raw = __import__("struct").pack("<12f3H", 0, 0, 0, 1, 0, 0, 0, 0, 1,
                                         0, -100, 0, 0, 1, 2)
        (asset_dir / "prototype.bin").write_bytes(raw)
        doc = {"asset": {"version": "2.0"}, "buffers": [{"uri": "prototype.bin", "byteLength": len(raw)}],
               "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 48},
                               {"buffer": 0, "byteOffset": 48, "byteLength": 6}],
               "accessors": [{"bufferView": 0, "componentType": 5126, "count": 4, "type": "VEC3"},
                             {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
               "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
               "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
        (asset_dir / "prototype.gltf").write_text(json.dumps(doc))
        prototypes_path = Path(pkg, "structures", "prototypes.json")
        prototypes = json.loads(prototypes_path.read_text())
        next(p for p in prototypes["prototypes"] if p["id"] == "house_chalet")["mesh_file"] = \
            "assets/prototypes/prototype.gltf"
        prototypes_path.write_text(json.dumps(prototypes))
        hid = self._first("house")
        self._edit(pkg, lambda objs, data: objs[hid].update({"importance": "high"}))

        errors, report = stc.validate(pkg)
        self.assertFalse(any("cannot be used" in error for error in errors))
        self.assertEqual(report["ground_support"][hid]["sample_kind"],
                         "prototype_lowest_vertices_and_footprint_grid")
        self.assertEqual(report["ground_support"][hid]["sample_count"], 11)
        self.assertGreater(min(s["base_y_m"] for s in report["ground_support"][hid]["samples"]), -50)

    def test_glb_uint16_indices_and_node_transform_use_shared_reader(self):
        with tempfile.TemporaryDirectory() as tmp:
            import struct
            binary = struct.pack("<9f3H", 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 1, 2)
            gltf = {"asset": {"version": "2.0"}, "buffers": [{"byteLength": len(binary)}],
                    "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36},
                                    {"buffer": 0, "byteOffset": 36, "byteLength": 6}],
                    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                                  {"bufferView": 1, "componentType": 5123, "count": 3, "type": "SCALAR"}],
                    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 1}]}],
                    "nodes": [{"mesh": 0, "translation": [2, 3, 4],
                               "rotation": [0, math.sqrt(0.5), 0, math.sqrt(0.5)]}],
                    "scenes": [{"nodes": [0]}], "scene": 0}
            js = json.dumps(gltf, separators=(",", ":")).encode()
            js += b" " * (-len(js) % 4)
            binary += b"\0" * (-len(binary) % 4)
            total = 12 + 8 + len(js) + 8 + len(binary)
            path = Path(tmp, "uint16.glb")
            path.write_bytes(struct.pack("<III", 0x46546C67, 2, total)
                             + struct.pack("<II", len(js), 0x4E4F534A) + js
                             + struct.pack("<II", len(binary), 0x004E4942) + binary)
            vertices, indices = gltf_mesh.read(str(path))
            for got, expected in zip(vertices, [(2, 3, 4), (2, 3, 3), (3, 3, 4)]):
                self.assertTrue(all(abs(a - b) < 1e-6 for a, b in zip(got, expected)))
            self.assertEqual(indices, [0, 1, 2])
            malformed = bytearray(path.read_bytes())
            bin_start = 12 + 8 + len(js) + 8
            struct.pack_into("<H", malformed, bin_start + 40, 3)
            bad_path = Path(tmp, "bad-index.glb"); bad_path.write_bytes(malformed)
            with self.assertRaisesRegex(gltf_mesh.GltfMeshError, "primitive index"):
                gltf_mesh.read(str(bad_path))

    def test_glb_rejects_index_outside_its_primitive_even_if_next_primitive_has_that_vertex(self):
        with tempfile.TemporaryDirectory() as tmp:
            import struct
            binary = struct.pack("<18f6H", 0, 0, 0, 1, 0, 0, 0, 0, 1,
                                 2, 0, 0, 3, 0, 0, 2, 0, 1,
                                 3, 1, 2, 0, 1, 2)
            gltf = {"asset": {"version": "2.0"}, "buffers": [{"byteLength": len(binary)}],
                    "bufferViews": [{"buffer": 0, "byteOffset": 0, "byteLength": 36},
                                    {"buffer": 0, "byteOffset": 36, "byteLength": 36},
                                    {"buffer": 0, "byteOffset": 72, "byteLength": 6},
                                    {"buffer": 0, "byteOffset": 78, "byteLength": 6}],
                    "accessors": [{"bufferView": 0, "componentType": 5126, "count": 3, "type": "VEC3"},
                                  {"bufferView": 1, "componentType": 5126, "count": 3, "type": "VEC3"},
                                  {"bufferView": 2, "componentType": 5123, "count": 3, "type": "SCALAR"},
                                  {"bufferView": 3, "componentType": 5123, "count": 3, "type": "SCALAR"}],
                    "meshes": [{"primitives": [{"attributes": {"POSITION": 0}, "indices": 2},
                                                 {"attributes": {"POSITION": 1}, "indices": 3}]}],
                    "nodes": [{"mesh": 0}], "scenes": [{"nodes": [0]}], "scene": 0}
            js = json.dumps(gltf, separators=(",", ":")).encode(); js += b" " * (-len(js) % 4)
            binary += b"\0" * (-len(binary) % 4)
            total = 12 + 8 + len(js) + 8 + len(binary)
            path = Path(tmp, "cross-primitive-index.glb")
            path.write_bytes(struct.pack("<III", 0x46546C67, 2, total)
                             + struct.pack("<II", len(js), 0x4E4F534A) + js
                             + struct.pack("<II", len(binary), 0x004E4942) + binary)
            with self.assertRaisesRegex(gltf_mesh.GltfMeshError, "primitive index"):
                gltf_mesh.read(str(path))

    def test_non_osm_estimated_local_pad_with_matching_p1_evidence_is_allowed(self):
        obj = {
            "attributes": {
                "candidate_only": True,
                "foundation_support": {
                    "kind": "estimated_local_level_pad", "max_gap_m": 0.012,
                    "max_penetration_m": 0.002, "pad_top_y_m": 3.005, "p1_tile": "T1",
                },
            },
            "source": {"kind": "gps_video_estimate", "estimated": True, "ref": "survey and frame match"},
            "transform": {"position": [1.0, 3.005, 2.0]},
        }
        manifest = {
            "tiles": [{"id": "T1", "files": {"terrain": "tiles/T1/terrain.glb"}}],
            "p1_local_support_patches": [{
                "tile_id": "T1", "estimated": True, "top_y_m": 3.005,
                "method": "estimated local construction pad",
                "source": {"kind": "gps_video_local_pad", "estimated": True, "ref": "pad evidence"},
                "polygon_xz_m": [[0.0, 0.0], [3.0, 0.0], [3.0, 3.0], [0.0, 3.0]],
            }],
        }
        self.assertTrue(stc.valid_foundation_support_policy(obj, manifest))

    def test_unsupported_foundation_support_cannot_raise_ground_tolerance(self):
        pkg = self._copy("forged_support")
        hid = self._first("house")
        def forge(objs, _):
            obj = objs[hid]
            obj["transform"]["position"][1] += 100.0
            obj.setdefault("attributes", {})["foundation_support"] = {
                "kind": "estimated_local_level_pad", "max_gap_m": 1000.0,
                "max_penetration_m": 1000.0, "pad_top_y_m": obj["transform"]["position"][1],
                "p1_tile": "00"}
        self._edit(pkg, forge)
        errors, report = stc.validate(pkg)
        self.assertTrue(any(hid in e and ("support policy" in e or "off the terrain" in e) for e in errors))
        self.assertLessEqual(report["ground_support"][hid]["gap_limit_m"], 0.05)

    def test_managed_rebuild_finalizes_fresh_blocked_structures_validation(self):
        with tempfile.TemporaryDirectory(prefix="candidate-workflow-") as tmp:
            root = Path(tmp).resolve(); source = root / "source"; shutil.copytree(self.pkg, source)
            (source / "acceptance.json").write_text(json.dumps({"status": "accepted", "blockers": []}))
            destination = root / "candidate"
            hid = self._first("house")
            def build_into(stage):
                shutil.copytree(source, stage)
                self._edit(str(stage), lambda objs, _data:
                           objs[hid]["transform"]["position"].__setitem__(1,
                               objs[hid]["transform"]["position"][1] + 100.0))
                errors, validation = stc.validate(str(stage))
                return {"status": "blocked" if errors else "valid", "p4_errors": errors,
                        "validation": validation}

            report = cw.build_managed_candidate(destination, source, "test_r17_candidate", build_into)
            self.assertTrue(report["p4_errors"])
            self.assertEqual(json.loads((destination / "manifest.json").read_text())["package_id"],
                             "test_r17_candidate")
            self.assertEqual(json.loads((destination / "acceptance.json").read_text())["status"], "blocked")
            self.assertTrue(json.loads((destination / cw.REPORT_NAME).read_text())["validation"])
            rerun = cw.build_managed_candidate(destination, source, "test_r17_candidate", build_into)
            self.assertEqual(rerun["status"], "blocked")

    def test_partial_world_ground_hits_are_reported_even_when_other_samples_are_missing(self):
        pkg = self._copy("partial_ground")
        hid = self._first("church")
        # The world-space rigid footprint extends outside the terrain grid. Keep the object record and
        # let the validator report both sampled hits and misses rather than silently skipping ground error.
        self._edit(pkg, lambda objs, data: objs[hid]["transform"]["position"].__setitem__(0, 998.0))
        errs, report = stc.validate(pkg)
        support = report["ground_support"][hid]
        self.assertGreater(support["missing_count"], 0)
        self.assertGreater(support["hit_count"], 0)
        self.assertTrue(any(hid in e and "missing terrain samples" in e for e in errs))
        self.assertIsNotNone(support["max_abs_ground_error_m"])

    def test_legacy_building_still_rejects_a_large_base_to_ground_gap(self):
        pkg=self._copy("legacy_building_gap")
        hid=self._first("house")
        self._edit(pkg,lambda objs,data: objs[hid]["transform"]["position"].__setitem__(1,objs[hid]["transform"]["position"][1]+100.0))
        errors,report=stc.validate(pkg)
        self.assertTrue(any(hid in e and "off the terrain" in e for e in errors))

    def test_every_object_has_the_required_fields(self):
        for o in self.objs:
            for k in ("object_id", "semantic_type", "s", "lateral_offset_m", "transform", "dimensions_m", "prototype",
                      "confidence", "source", "importance"):
                self.assertIn(k, o)

    def test_structure_rebuild_preserves_existing_prototype_asset_lineage(self):
        generated = {"fence_rail": {"semantic_type": "fence", "placement": "linear"},
                     "new_type": {"semantic_type": "fence", "placement": "linear"}}
        previous = [{"id": "fence_rail", "semantic_type": "fence", "placement": "linear",
                     "mesh_file": "assets/prototypes/fence.glb", "source": {"kind": "procedural"}},
                    {"id": "legacy_unused", "semantic_type": "fence", "mesh_file": "assets/prototypes/old.glb"}]
        merged = stc.preserve_package_prototype_assets(generated, previous)
        self.assertEqual(merged["fence_rail"]["mesh_file"], "assets/prototypes/fence.glb")
        self.assertEqual(merged["fence_rail"]["source"], {"kind": "procedural"})
        self.assertEqual(merged["new_type"], generated["new_type"])
        self.assertEqual(merged["legacy_unused"]["mesh_file"], "assets/prototypes/old.glb")

    def test_append_hints_keeps_existing_objects_and_reindexes_tiles(self):
        pkg = self._copy("append_hint")
        path = os.path.join(pkg, "structures", "structures.json")
        with open(path) as f:
            before = json.load(f)
        old_objects = copy.deepcopy(before["objects"])
        hints = [{"semantic_type": "bench", "prototype": "bench_wood", "importance": "medium",
                  "name": "Added test bench", "s": 50, "side": "left", "lateral_offset_m": 10,
                  "dimensions_m": [1.8, 0.9, 0.6], "confidence": 0.5,
                  "source": {"kind": "video_estimate", "ref": "synthetic fixture", "estimated": True}}]
        objs, skipped = stc.append_hints(pkg, hints)
        self.assertEqual(skipped, [])
        with open(path) as f:
            after = json.load(f)
        self.assertEqual(after["objects"][:-1], old_objects)
        self.assertEqual(len(objs), len(old_objects) + 1)
        self.assertEqual(stc.validate(pkg)[0], [])

    def test_append_prototype_asset_is_scoped_to_named_mesh(self):
        pkg = self._copy("append_asset")
        hint = {"semantic_type": "house", "prototype": "coastal_house_gable", "importance": "medium",
                "name": "Gable fixture", "s": 50, "side": "left", "lateral_offset_m": 10,
                "dimensions_m": [18, 6, 8], "confidence": 0.5,
                "source": {"kind": "video_estimate", "ref": "synthetic fixture", "estimated": True}}
        _, skipped = stc.append_hints(pkg, [hint])
        self.assertEqual(skipped, [])
        veg_path = os.path.join(pkg, "vegetation", "prototypes.json")
        with open(veg_path, "rb") as f:
            vegetation_before = f.read()
        structure_path = os.path.join(pkg, "structures", "prototypes.json")
        with open(structure_path) as f:
            before = {p["id"]: p for p in json.load(f)["prototypes"]}
        bpa.build(Path(pkg), only="coastal_house_gable")
        with open(veg_path, "rb") as f:
            self.assertEqual(f.read(), vegetation_before)
        with open(structure_path) as f:
            after = {p["id"]: p for p in json.load(f)["prototypes"]}
        for prototype_id, prototype in before.items():
            if prototype_id != "coastal_house_gable":
                self.assertEqual(after[prototype_id], prototype)
        new_proto = after["coastal_house_gable"]
        self.assertTrue(os.path.isfile(os.path.join(pkg, new_proto["mesh_file"])))

    def test_gabled_house_mesh_has_continuous_ridge_and_end_gables(self):
        mesh = bpa.structure("coastal_house_gable", [18.0, 6.0, 8.0])
        vertices = {tuple(round(v, 5) for v in p) for p in mesh.pos}
        self.assertIn((-9.0, 6.0, 0.0), vertices)
        self.assertIn((9.0, 6.0, 0.0), vertices)
        triangles = {
            frozenset(tuple(round(v, 5) for v in p) for p in mesh.pos[i:i + 3])
            for i in range(0, len(mesh.pos), 3)
        }
        for x in (-9.0, 9.0):
            end_gable = frozenset({(x, 4.08, -4.0), (x, 6.0, 0.0), (x, 4.08, 4.0)})
            self.assertIn(end_gable, triangles)

    def test_corner_apartment_adds_side_facing_balconies_without_touching_base_mesh(self):
        base = bpa.structure("coastal_apartment_36", [18.0, 36.0, 15.0])
        corner = bpa.structure("coastal_apartment_corner_36", [18.0, 36.0, 15.0])
        self.assertGreater(len(corner.pos), len(base.pos))
        vertices = {tuple(round(v, 5) for v in p) for p in corner.pos}
        # The corner variant's body ends at |x|=7m; its side balcony and rail protrude visibly
        # beyond that wall while staying inside the declared 18m width (|x|<=9m).
        self.assertIn((7.0, 0.0, -7.5), vertices)
        self.assertIn((9.0, 0.6, -7.5), vertices)
        self.assertIn((8.71, 1.025, -7.5), vertices)
        for point in ((7.0, 0.0, -7.5), (9.0, 0.6, -7.5), (8.71, 1.025, -7.5)):
            self.assertLessEqual(abs(point[0]), 9.0)
        self.assertEqual(bpa.structure("coastal_apartment_36", [18.0, 36.0, 15.0]).pos, base.pos)

    def test_append_high_hint_keeps_fixed_anchor_for_validator(self):
        pkg = self._copy("append_high")
        hint = {"semantic_type": "house", "prototype": "coastal_house_gable", "importance": "high",
                "name": "Blocked high fixture", "s": 300, "side": "left", "lateral_offset_m": 30,
                "dimensions_m": [18, 6, 8], "confidence": 0.4,
                "source": {"kind": "video_estimate", "ref": "synthetic fixture", "estimated": True}}
        objs, skipped = stc.append_hints(pkg, [hint])
        self.assertEqual(skipped, [])
        obj = objs[-1]
        self.assertEqual(obj["s"], 300)
        self.assertEqual(obj["anchor"], {"s": 300, "lateral_offset_m": 30})
        self.assertTrue([e for e in stc.validate(pkg)[0] if obj["object_id"] in e and "in water" in e])

    def test_types_from_route_semantics_and_hints(self):
        self.assertEqual(len(self.by_type["race_landmark"]), 2)       # start + finish gates
        self.assertEqual(len(self.by_type["tunnel_portal"]), 2)       # both tunnel ends
        self.assertEqual(len(self.by_type["bridge"]), 1)
        self.assertEqual(len(self.by_type["sign"]), 1)                # the route's checkpoint
        self.assertEqual({o["prototype"] for o in self.by_type["fence"] + self.by_type["guardrail"]}, {"fence_rail", "guardrail_cable"})
        self.assertTrue(self.by_type["house"])

    def test_high_importance_landmark_keeps_identity(self):
        c = self.by_type["church"][0]
        self.assertEqual((c["s"], c["name"], c["prototype"]), (750, "St. Test chapel", "landmark_st_test_chapel"))
        self.assertEqual(c["lateral_offset_m"], c["anchor"]["lateral_offset_m"])

    def test_generic_houses_inside_their_zone(self):
        for h in self.by_type["house"]:
            fs = h["footprints_route"][0]
            self.assertTrue(500 <= fs[0] and fs[1] <= 700 and -45 <= fs[2] and fs[3] <= -8)
            self.assertEqual((h["importance"], h["prototype"]), ("low", "house_chalet"))

    def test_gate_legs_clear_of_road(self):
        for g in self.by_type["race_landmark"]:
            for b in g["footprints_route"]:
                self.assertTrue(b[2] >= 3.3 or b[3] <= -3.3)

    def test_detects_house_in_water(self):
        pkg = self._copy("wet")
        hid = self._first("house")
        self._edit(pkg, lambda o, d: o[hid].update(lateral_offset_m=30.0, footprints_route=[[550, 560, 25, 35]]))
        self.assertTrue([e for e in stc.validate(pkg)[0] if hid in e and "in water" in e])

    def test_detects_house_on_the_road(self):
        pkg = self._copy("road")
        hid = self._first("house")
        self._edit(pkg, lambda o, d: o[hid].update(footprints_route=[[550, 560, -5, 1]]))
        self.assertTrue([e for e in stc.validate(pkg)[0] if hid in e and "road boundary" in e])

    def test_detects_tree_inside_a_building(self):
        pkg = self._copy("tree")
        c = self.by_type["church"][0]
        path = os.path.join(pkg, "tiles", "01", "vegetation.json")
        with open(path) as f:
            d = json.load(f)
        d["groups"].append({"proto": "conifer_spruce", "category": "conifer", "count": 1, "data": [0] * 7 + [1, 1, 1],
                            "s": [c["s"]], "lateral_offset_m": [c["lateral_offset_m"]], "zone": [0]})
        with open(path, "w") as f:
            json.dump(d, f)
        self.assertTrue([e for e in stc.validate(pkg)[0] if c["object_id"] in e and "collides" in e])

    def test_detects_moved_landmark(self):
        pkg = self._copy("moved")
        cid = self._first("church")
        self._edit(pkg, lambda o, d: o[cid].update(s=o[cid]["s"] + 5))
        self.assertTrue([e for e in stc.validate(pkg)[0] if cid in e and "anchor" in e])

    def test_detects_bridge_mismatch(self):
        pkg = self._copy("bridge")
        bid = self._first("bridge")
        self._edit(pkg, lambda o, d: o[bid].update(footprints_route=[[100, 110, -1, 1]], from_s=120, to_s=130))
        errs = [e for e in stc.validate(pkg)[0] if bid in e]
        self.assertTrue([e for e in errs if "narrower" in e] and [e for e in errs if "semantic bridge" in e])

    def test_detects_floating_barrier(self):
        pkg = self._copy("float")
        fid = self._first("fence")
        self._edit(pkg, lambda o, d: o[fid]["polyline"]["points"][3].__setitem__(1, o[fid]["polyline"]["points"][3][1] + 1.0))
        self.assertTrue([e for e in stc.validate(pkg)[0] if fid in e and "off the terrain" in e])

    def test_impossible_high_landmark_is_reported_not_dropped(self):
        pkg = self._copy("impossible")
        bad = dict(self.hints[0], name="Lake chapel", s=300, side="left", edge_offset_m=30)
        objs, skipped = stc.build(pkg, hints=[bad])
        self.assertIn("Lake chapel", [o.get("name") for o in objs])
        self.assertTrue([e for e in stc.validate(pkg)[0] if "in water" in e])

    def test_needs_vegetation_first(self):
        pkg = self._copy("no_veg")
        shutil.rmtree(os.path.join(pkg, "vegetation"))
        with self.assertRaises(ValueError):
            stc.build(pkg)

    @unittest.skipUnless(os.path.isfile("export/packages/weissensee_rolling_hills/structures/structures.json"),
                         "generate with tools/structures.py build")
    def test_generated_weissensee_example(self):
        self.assertEqual(stc.validate("export/packages/weissensee_rolling_hills")[0], [])


class EnvironmentTest(unittest.TestCase):
    """Full chain on a 1000 m route, then a synthetic DEM backdrop (bowl of mountains), a fake HDRI and scene hints."""

    @classmethod
    def setUpClass(cls):
        cls.tmp = tempfile.mkdtemp()
        cls.pkg = os.path.join(cls.tmp, "env")
        os.makedirs(os.path.join(cls.pkg, "route"))
        with open(os.path.join(cls.pkg, "route", "route.json"), "w") as f:
            json.dump(rm.finalize(raw_route(length=1000, grade=2.0, radius=800, width=(3.0, 3.0))), f)
        rt.build(cls.pkg, tile_m=500, terrain={"hill_amplitude_m": 3.0})
        os.makedirs(os.path.join(cls.pkg, "semantics"))
        with open(os.path.join(cls.pkg, "semantics", "semantics.json"), "w") as f:
            json.dump({"version": "0.1", "route_id": "test", "extent_m": 150, "zones": [
                zone("road", "trail", "both", 0, 1000, (-3, 3)), zone("lake", "water", "left", 0, 1000, (12, 150)),
                zone("grass", "grass", "right", 0, 1000, (-60, -3), cover=0.5)]}, f)
        vg.build(cls.pkg)
        stc.build(cls.pkg)
        # a 33 x 33 DEM over 2 km: a bowl rising 0.0002 m/m^2 around its centre, with a fake orthophoto and HDRI
        cls.dem = os.path.join(cls.tmp, "terrain")
        os.makedirs(cls.dem)
        g, size = 33, 2000.0
        hs = [1000.0 + 0.0002 * (((c - 16) * size / 32) ** 2 + ((r - 16) * size / 32) ** 2) for r in range(g) for c in range(g)]
        import array as _a
        with open(os.path.join(cls.dem, "bowl_h.f32"), "wb") as f:
            f.write(_a.array("f", hs).tobytes())
        with open(os.path.join(cls.dem, "bowl.json"), "w") as f:
            json.dump({"name": "bowl", "lat": 46.7, "lon": 13.4, "size_m": size, "grid": g, "centre_m": 1000.0}, f)
        with open(os.path.join(cls.dem, "bowl_albedo.jpg"), "wb") as f:
            f.write(b"\xff\xd8\xff\xe0" + b"\0" * 64)
        cls.hdr = os.path.join(cls.tmp, "test_clear_sky.hdr")
        with open(cls.hdr, "wb") as f:
            f.write(b"#?RADIANCE\nFORMAT=32-bit_rle_rgbe\n\n-Y 1 +X 2\n" + b"\0" * 8)
        heading0 = rm.finalize(raw_route(length=1000, grade=2.0, radius=800))["samples"]["heading_deg"][0]
        az = math.radians(heading0 - 60.0)
        el = math.radians(35.0)
        cls.hints = {
            "scene": "test", "course": "test",
            "sun": {"direction_to_sun": [math.cos(el) * math.sin(az), math.sin(el), -math.cos(el) * math.cos(az)],
                    "color": [1.0, 0.95, 0.88], "energy": 1.5, "mode": "relative_to_route", "left_of_travel_deg": 60.0,
                    "elevation_from_hdri": True},
            "sky": {"hdri": cls.hdr, "sun_u": 0.6, "sun_elevation_deg": 35.0, "energy": 1.0},
            "ambient": {"source": "sky", "energy": 1.2},
            "fog": {"density": 0.0005, "color": [0.6, 0.7, 0.9], "aerial_perspective": 0.8, "sun_scatter": 0.1, "sky_affect": 0.1, "mist": None},
            "grading": {"tonemap": "agx", "exposure": 1.0, "saturation": 1.2, "contrast": 1.0, "glow": True},
            "time_of_day": {"phase": [0.3, 0.5]},
            "real_terrain": {"name": "bowl", "dir": cls.dem, "rotation_deg": 30.0, "height_offset": -50.0, "anchor": [300.0, 0.0],
                             "hole_radius": 1.0, "hole_depth": -600.0, "sink_west_of": None, "sink_axis_deg": 0.0},
            "water": [{"name": "LakeFar", "size_m": [40000, 40000], "base_y": -0.08, "follows_route_water": True,
                       "deep_color": [0.03, 0.34, 0.46], "roughness": 0.12}],
            "water_offset_m": [[s, -3.0] for s in range(0, 1001, 25)],
            "cloud_volumes": [],
        }
        cls.hints_path = os.path.join(cls.tmp, "hints.json")
        with open(cls.hints_path, "w") as f:
            json.dump(cls.hints, f)
        cls.env = en.build(cls.pkg, cls.hints_path, max_grid=17)

    @classmethod
    def tearDownClass(cls):
        shutil.rmtree(cls.tmp)

    def _copy(self, name):
        dst = os.path.join(self.tmp, name)
        shutil.copytree(self.pkg, dst)
        return dst

    def _edit(self, pkg, fn):
        path = os.path.join(pkg, "environment", "environment.json")
        with open(path) as f:
            d = json.load(f)
        fn(d)
        with open(path, "w") as f:
            json.dump(d, f)

    def errs(self, pkg, text):
        return [e for e in en.validate(pkg)[0] if text in e]

    def test_valid_and_referenced(self):
        self.assertEqual(en.validate(self.pkg)[0], [])
        a = self.env["atmosphere"]
        self.assertTrue(os.path.isfile(os.path.join(self.pkg, a["sky"]["file"])))
        self.assertTrue(os.path.isfile(os.path.join(self.pkg, self.env["distant"]["terrain"][0]["file"])))
        self.assertAlmostEqual(a["sun"]["elevation_deg"], 35.0, places=3)
        self.assertAlmostEqual(a["fog"]["visibility_m"], 3.912 / 0.0005, delta=1)
        self.assertEqual(a["weather"]["condition"], "clear")
        self.assertEqual(a["time_of_day"]["approx_local_time"], ["09:36", "12:00"])

    def test_data_not_shaders(self):
        with open(os.path.join(self.pkg, "environment", "environment.json")) as f:
            text = f.read()
        for bad in ("gdshader", "shader_parameter", "ShaderMaterial", "HDRP", "URP"):
            self.assertNotIn(bad, text)

    def test_follow_anchor_and_skyline(self):
        fol = self.env["distant"]["anchors"]["follow_runner"]
        self.assertEqual((fol["s"][0], fol["s"][-1]), (0, 1000))
        self.assertGreater(fol["yaw_deg"][-1], 30.0)  # an 800 m radius left bend turns the backdrop left (+)
        sky = self.env["distant"]["skyline"]["samples"]
        self.assertEqual(len(sky), 180)
        self.assertTrue(all(r[1] > 0 for r in sky))  # inside a bowl the horizon is above eye level all round

    def test_missing_sky_file(self):
        pkg = self._copy("nosky")
        os.remove(os.path.join(pkg, "environment", "sky.hdr"))
        self.assertTrue(self.errs(pkg, "sky.hdr missing"))

    def test_missing_attribution(self):
        pkg = self._copy("noatt")
        self._edit(pkg, lambda d: d.__setitem__("attribution", []))
        self.assertTrue(self.errs(pkg, "attribution polyhaven not listed"))

    def test_bad_sun_and_fog(self):
        pkg = self._copy("sunfog")

        def bad(d):
            d["atmosphere"]["sun"]["direction_to_sun"] = [0.0, 2.0, 0.0]
            d["atmosphere"]["fog"]["visibility_m"] = 100
        self._edit(pkg, bad)
        self.assertTrue(self.errs(pkg, "not a unit vector"))
        self.assertTrue(self.errs(pkg, "visibility_m inconsistent"))

    def test_sun_must_follow_its_route_rule(self):
        pkg = self._copy("sunrule")
        self._edit(pkg, lambda d: d["atmosphere"]["sun"].__setitem__("left_of_travel_deg", 10.0))
        self.assertTrue(self.errs(pkg, "left of the start heading"))

    def test_water_above_road(self):
        pkg = self._copy("flood")
        self._edit(pkg, lambda d: d["distant"]["anchors"]["follow_runner"]["pivot_y_offset_m"].__setitem__(5, 1.0))
        self.assertTrue(self.errs(pkg, "above the road"))

    def test_yaw_must_follow_route(self):
        pkg = self._copy("yaw")
        self._edit(pkg, lambda d: d["distant"]["anchors"]["follow_runner"]["yaw_deg"].__setitem__(10, 90.0))
        self.assertTrue(self.errs(pkg, "smoothed direction"))

    def test_distant_terrain_swallowing_the_runner(self):
        pkg = self._copy("swallow")
        h = dict(self.hints, real_terrain=dict(self.hints["real_terrain"], height_offset=20.0))
        path = os.path.join(self.tmp, "hints_high.json")
        with open(path, "w") as f:
            json.dump(h, f)
        en.build(pkg, path, max_grid=17)
        self.assertTrue(self.errs(pkg, "above the road under the runner"))

    def test_whole_package_valid(self):
        self.assertEqual({s for _, s, _ in vp.validate(self.pkg)}, {"VALID"})

    def test_missing_stage_reported_in_order(self):
        pkg = self._copy("partial")
        shutil.rmtree(os.path.join(pkg, "vegetation"))
        res = {n: s for n, s, _ in vp.validate(pkg)}
        self.assertEqual((res["semantics"], res["vegetation"], res["structures"], res["environment"]),
                         ("VALID", "MISSING", "MISSING", "MISSING"))
        self.assertEqual(res["package integrity"], "INVALID")  # the manifest still lists vegetation files

    def test_needs_structures_first(self):
        pkg = self._copy("nostruct")
        shutil.rmtree(os.path.join(pkg, "structures"))
        with self.assertRaises(ValueError):
            en.build(pkg, self.hints_path)

    @unittest.skipUnless(os.path.isfile("export/packages/weissensee_rolling_hills/environment/environment.json"),
                         "generate with tools/environment.py build")
    def test_generated_weissensee_example(self):
        self.assertEqual(en.validate("export/packages/weissensee_rolling_hills")[0], [])


class EstimatedLandInfillTest(unittest.TestCase):
    def test_nonserializable_clipped_polygon_collapses_without_losing_valid_triangle(self):
        # Reproduction from the S5640 intersection: four double-precision points
        # become two points in the GLB float32 coordinate frame.
        sliver=[(1504.024892414558,4947.33174887295),(1504.0248924145599,4947.331748872949),
                (1503.9953250774981,4947.3469787741915),(1503.9953250774645,4947.346978774209)]
        tris,collapsed=rt._triangulate_serializable_polygon(sliver,(0,0,0))
        self.assertTrue(collapsed);self.assertEqual(tris,[])
        triangle=[(1504.,4947.),(1504.1,4947.),(1504.,4947.1)]
        tris,collapsed=rt._triangulate_serializable_polygon(triangle,(0,0,0))
        self.assertFalse(collapsed);self.assertEqual(len(tris),1)


    def test_target_road_affine_chart_recovers_curved_edge_without_clamping_or_moving_mesh(self):
        # Adjacent road rows turn 45 degrees. Their outer edge chord projects to
        # U≈1.707 on the incoming route chord, although the road faces author U=2.
        origin=(400.0,0.0,2700.0)
        left0=(9.0,0.0,-2.0)
        right0=(9.0,0.0,2.0)
        left1=(10.0-2.0*math.sqrt(0.5),0.05,-2.0*math.sqrt(0.5))
        right1=(10.0+2.0*math.sqrt(0.5),0.05,2.0*math.sqrt(0.5))
        road_positions=[(p[0],p[1],p[2]) for p in (left0,right0,left1,right1)]
        road={"translation":list(origin),"attributes":{"POSITION":road_positions,
              "_ROUTE_S":[9.0,9.0,10.0,10.0],"_ROUTE_U":[2.0,-2.0,2.0,-2.0]},
              "primitives":[{"material":{"name":"road_asphalt"},"indices":[0,1,2,1,3,2]}]}
        edge_point=tuple((left0[i]+left1[i])*.5 for i in range(3))
        far_point=(30.0,1.0,30.0)
        terrain={"translation":list(origin),"attributes":{
            "POSITION":[edge_point,far_point],"NORMAL":[(0.0,1.0,0.0)]*2,
            "TEXCOORD_0":[(1.0,2.0),(3.0,4.0)],"_ROUTE_S":[9.0,30.0],"_ROUTE_U":[1.7,20.0]},
            "primitives":[{"material":{"name":"terrain_ground"},"indices":[0,1,0]}]}
        before=copy.deepcopy(terrain)
        route={"samples":{"s":[9.0,10.0,11.0],"x":[409.0,410.0,410.0],
                           "z":[2700.0,2700.0,2699.0]}}
        old_s,old_u,_=rt._land_infill_route_projection(origin[0]+edge_point[0],
            origin[2]+edge_point[2],route,{"from_s":9.0,"to_s":11.0})
        self.assertLess(abs(old_u),2.0-0.001)  # legacy validator would call this road-band overlap

        report=rt._apply_near_road_affine_chart(terrain,road,start_vertex=0,max_distance_m=0.02)

        self.assertEqual(report["changed_vertex_count"],1)
        self.assertAlmostEqual(terrain["attributes"]["_ROUTE_S"][0],9.5,places=6)
        self.assertAlmostEqual(terrain["attributes"]["_ROUTE_U"][0],2.0,places=6)
        self.assertGreaterEqual(abs(terrain["attributes"]["_ROUTE_U"][0]),2.0-0.001)
        self.assertEqual(terrain["attributes"]["_ROUTE_S"][1:],before["attributes"]["_ROUTE_S"][1:])
        self.assertEqual(terrain["attributes"]["_ROUTE_U"][1:],before["attributes"]["_ROUTE_U"][1:])
        for key in ("POSITION","NORMAL","TEXCOORD_0"):
            self.assertEqual(terrain["attributes"][key],before["attributes"][key])
        self.assertEqual(terrain["primitives"],before["primitives"])

    def test_edge_interpolated_support_resolves_sparse_vertices_without_changing_coverage(self):
        ground={"name":"terrain_ground","color":[0.3,0.42,0.2],"roughness":0.95}
        # The source rectangle only touches the ROI along z=0. Its four original
        # vertices are >4 m from the upper ROI corners, while interpolated samples
        # on the existing shared edge provide four distinct supports within 4 m.
        source=self._mesh("terrain",[0,0,0],self._rect(-5,-1,5,0,2.0),ground)
        with tempfile.TemporaryDirectory() as td:
            for folder in ("tiles/00","route"):os.makedirs(os.path.join(td,folder))
            rt.write_glb(os.path.join(td,"tiles/00/terrain.glb"),source)
            Path(os.path.join(td,"route/route.json")).write_text(json.dumps(
                {"samples":{"s":[0.0,10.0],"x":[0.0,10.0],"z":[0.0,0.0]}}))
            manifest={"package_id":"edge-support-fixture","tiles":[{"id":"00","from_s":0.0,"to_s":10.0,
                "origin":[0,0,0],"files":{"terrain":"tiles/00/terrain.glb"}}]}
            Path(os.path.join(td,"manifest.json")).write_text(json.dumps(manifest))
            base={"schema_version":1,"estimated":True,"target_tile_id":"00",
                "provenance":{"source":"fixture","status":"estimated","rationale":"derived edge sample support"},
                "height_rule":{"kind":"boundary_supported_idw","neighbors":4,
                    "max_boundary_mismatch_m":0.002,"max_estimated_support_distance_m":4.0,
                    "support_owner_policy":{"terrain":"terrain_coverage_owner_ids","road":"all_package_p0","foreign_terrain":"excluded"}},
                "material":ground,"regions":[{"id":"roi","terrain_coverage_owner_ids":["00"],
                    "polygon_xz":[[0,0],[1,0],[1,1],[0,1]]}]}
            with self.assertRaisesRegex(ValueError,"no supported height within 4.0m"):
                rt.apply_land_infill(td,base)
            halo_test_source=rt.read_glb(os.path.join(td,"tiles/00/terrain.glb"))
            self.assertEqual(halo_test_source["primitives"],source["primitives"])
            edge={**base,"height_rule":{**base["height_rule"],"support_edge_sample_spacing_m":1.0}}
            result=rt.apply_land_infill(td,edge)
            out=rt.read_glb(os.path.join(td,"tiles/00/terrain.glb"))
            self.assertEqual(out["attributes"]["POSITION"][:len(source["attributes"]["POSITION"])],source["attributes"]["POSITION"])
            self.assertEqual(out["primitives"][0]["indices"][:len(source["primitives"][0]["indices"])],source["primitives"][0]["indices"])
            region=result["regions"][0]
            self.assertAlmostEqual(region["selected_p1_all_p0_complement_area_m2"],1.0,places=8)
            self.assertAlmostEqual(region["added_area_m2"],1.0,places=8)
            self.assertEqual(region["all_p0_triangle_count"],0)
            report=result["mesh_report"]["support_edge_sampling"]
            self.assertEqual(report["spacing_m"],1.0)
            self.assertGreater(report["derived_sample_count"],0)
            self.assertEqual(report["minimum_estimated_neighbor_count_used"],4)
            self.assertLessEqual(report["max_sample_segment_m"],1.0+1e-9)
            self.assertLessEqual(result["mesh_report"]["max_estimated_support_distance_m"],4.0)

    def test_edge_support_deduplicates_reversed_shared_edges_and_rejects_same_chart_height_conflicts(self):
        def triangle(owner="49", layer="terrain", y_offset=0.0, s_offset=0.0):
            return {"owner":owner,"layer":layer,"xz":[(0.0,0.0),(2.0,0.0),(0.0,2.0)],
                "y":[1.0+y_offset,2.0+y_offset,3.0+y_offset],
                "attributes":{"_ROUTE_S":[10.0+s_offset,12.0+s_offset,10.0+s_offset],
                              "_ROUTE_U":[-2.0,-2.0,0.0]}}
        first=triangle()
        reversed_copy={**first,"xz":list(reversed(first["xz"])),"y":list(reversed(first["y"])),
            "attributes":{"_ROUTE_S":list(reversed(first["attributes"]["_ROUTE_S"])),
                          "_ROUTE_U":list(reversed(first["attributes"]["_ROUTE_U"]))}}
        samples,report=rt._land_infill_edge_support_samples([first,reversed_copy],1.0,0.002)
        self.assertEqual(report["derived_sample_count"],4)
        self.assertEqual(len(samples),4)
        with self.assertRaisesRegex(ValueError,"same-chart edge support height mismatch"):
            rt._land_infill_edge_support_samples([first,triangle(y_offset=0.01)],1.0,0.002)
        # A T-junction source vertex can coincide with an interpolated edge sample.
        # It must be checked before the derived sample is deduplicated away.
        tjunction={"owner":"49","layer":"terrain","xz":[(1.0,0.0),(1.0,-1.0),(2.0,-1.0)],
            "y":[9.0,9.0,9.0],"attributes":{"_ROUTE_S":[11.0,11.0,12.0],"_ROUTE_U":[-2.0,-2.0,-3.0]}}
        with self.assertRaisesRegex(ValueError,"same-chart edge support height mismatch"):
            rt._land_infill_edge_support_samples([first,tjunction],1.0,0.002)
        distinct_chart,distinct_report=rt._land_infill_edge_support_samples(
            [first,triangle(s_offset=20.0)],1.0,0.002)
        self.assertEqual(distinct_report["derived_sample_count"],8)
        self.assertEqual(len(distinct_chart),8)

    def test_edge_sample_spacing_validation_is_finite_and_bounded(self):
        valid={"schema_version":1,"estimated":True,"target_tile_id":"49",
            "provenance":{"source":"fixture","status":"estimated","rationale":"edge sample spacing bounds"},
            "height_rule":{"kind":"boundary_supported_idw","neighbors":4,
                "max_boundary_mismatch_m":0.002,"max_estimated_support_distance_m":4.0},
            "material":{"name":"terrain_ground","color":[0.2,0.3,0.4],"roughness":0.9},
            "regions":[{"id":"r","polygon_xz":[[0,0],[1,0],[1,1],[0,1]]}]}
        for spacing in (-0.1,4.0001,float("nan"),float("inf")):
            with self.subTest(spacing=spacing),self.assertRaisesRegex(ValueError,"support_edge_sample_spacing_m"):
                rt._validate_land_infill_authoring({**valid,"height_rule":{**valid["height_rule"],"support_edge_sample_spacing_m":spacing}})

    def _mesh(self, name, translation, triangles, material):
        positions=[]; indices=[]
        for tri in triangles:
            base=len(positions)
            positions.extend([(x,y,z) for x,z,y in tri])
            indices.extend((base,base+1,base+2))
        return {"name":name,"translation":translation,"attributes":{
            "POSITION":positions,"NORMAL":[(0.0,1.0,0.0)]*len(positions),
            "TEXCOORD_0":[(p[0],p[2]) for p in positions],
            "_ROUTE_S":[p[0] for p in positions],"_ROUTE_U":[-p[2] for p in positions]},
            "primitives":[{"material":material,"indices":indices}]}

    @staticmethod
    def _rect(x0,z0,x1,z1,y=2.0):
        a=(x0,z0,y);b=(x1,z0,y);c=(x1,z1,y);d=(x0,z1,y)
        # Clockwise in XZ is an upward-facing surface in this package convention.
        return [(a,d,c),(a,c,b)]

    def test_bounded_infill_preserves_original_faces_and_excludes_road(self):
        material={"name":"terrain_ground","color":[0.3,0.42,0.2],"roughness":0.95}
        sand={"name":"shore_sand","color":[0.68,0.59,0.39],"roughness":0.95}
        roadmat={"name":"road_asphalt","color":[0.18,0.18,0.18],"roughness":0.9}
        # A 10x10 P1 ring leaves a 2x2 hole; a 0.2m P0 stripe occupies part of it.
        ring=[]
        ring += self._rect(0,0,10,4) + self._rect(0,6,10,10)
        ring += self._rect(0,4,4,6) + self._rect(6,4,10,6)
        # A same-owner elevated duplicate and a higher foreign traversal touch the
        # lower shore of the gap. The fill must choose target-owner topmost support,
        # while retaining the cross-owner difference as a diagnostic.
        p1=self._mesh("terrain",[0,0,0],ring,material)
        p1["primitives"][0]["indices"].extend(p1["primitives"][0]["indices"][:3])
        elevated=self._rect(0,0,10,4,2.0005)[0]
        start=len(p1["attributes"]["POSITION"])
        p1["attributes"]["POSITION"].extend([(x,y,z) for x,z,y in elevated])
        p1["attributes"]["NORMAL"].extend([(0.0,1.0,0.0)]*3)
        p1["attributes"]["TEXCOORD_0"].extend([(x,z) for x,y,z in p1["attributes"]["POSITION"][start:]])
        p1["attributes"]["_ROUTE_S"].extend([p[0] for p in p1["attributes"]["POSITION"][start:]])
        p1["attributes"]["_ROUTE_U"].extend([-p[2] for p in p1["attributes"]["POSITION"][start:]])
        p1["primitives"][0]["indices"].extend([start,start+1,start+2])
        p0=self._mesh("road",[0,0,0],self._rect(4,4.9,6,5.1,2.0),roadmat)
        foreign=self._mesh("foreign_terrain",[0,0,0],self._rect(0,0,10,4,2.08),material)
        with tempfile.TemporaryDirectory() as td:
            os.makedirs(os.path.join(td,"tiles","00"));os.makedirs(os.path.join(td,"tiles","03"));os.makedirs(os.path.join(td,"route"))
            rt.write_glb(os.path.join(td,"tiles","00","terrain.glb"),p1)
            rt.write_glb(os.path.join(td,"tiles","00","road.glb"),p0)
            rt.write_glb(os.path.join(td,"tiles","03","terrain.glb"),foreign)
            original=rt.read_glb(os.path.join(td,"tiles","00","terrain.glb"))
            route={"samples":{"s":[0.0,10.0],"x":[0.0,10.0],"z":[5.0,5.0],
                               "heading_deg":[90.0,90.0]}}
            Path(os.path.join(td,"route","route.json")).write_text(json.dumps(route))
            manifest={"package_id":"fixture","tiles":[{"id":"00","from_s":0.0,"to_s":10.0,
                "origin":[0,0,0],"files":{"terrain":"tiles/00/terrain.glb","road":"tiles/00/road.glb"}},
                {"id":"03","from_s":30.0,"to_s":40.0,"origin":[0,0,0],
                 "files":{"terrain":"tiles/03/terrain.glb"}}]}
            Path(os.path.join(td,"manifest.json")).write_text(json.dumps(manifest))
            authoring={"schema_version":1,"estimated":True,"target_tile_id":"00",
                "provenance":{"source":"procedural_estimated_land","status":"estimated",
                              "rationale":"bounded local continuity fixture"},
                "height_rule":{"kind":"boundary_supported_idw","neighbors":4,
                               "max_boundary_mismatch_m":0.001,"max_estimated_support_distance_m":1.0},
                "material":material,"regions":[{"id":"hole","logical_owner_ids":["00"],
                    "polygon_xz":[[4,4],[6,4],[6,6],[4,6]]}]}
            updated=rt.apply_land_infill(td,authoring)
            out=rt.read_glb(os.path.join(td,"tiles","00","terrain.glb"))
            self.assertEqual(out["attributes"]["POSITION"][:len(original["attributes"]["POSITION"])],
                             original["attributes"]["POSITION"])
            self.assertEqual(out["primitives"][0]["indices"][:len(original["primitives"][0]["indices"])],
                             original["primitives"][0]["indices"])
            self.assertGreater(updated["regions"][0]["added_area_m2"],3.5)
            self.assertLess(updated["regions"][0]["added_area_m2"],3.7)
            self.assertLess(updated["mesh_report"]["serialized_overlap_max_single_face_pair_m2"],1e-10)
            self.assertEqual(updated["mesh_report"]["route_projection_station_bounds_m"],[4.0,6.0])
            self.assertAlmostEqual(updated["mesh_report"]["supported_height_range_y_m"][1],2.0005,places=5)
            self.assertEqual(updated["mesh_report"]["selected_support_owner_vertex_counts"],{"00":8})
            self.assertGreater(updated["mesh_report"]["max_cross_owner_input_height_difference_m"],0.07)

    def test_authoring_validation_rejects_nonfinite_and_unestimated_patch(self):
        with self.assertRaises(ValueError):
            rt._validate_land_infill_authoring({"estimated":False})

    def test_route_attribute_chart_rejects_unknown_policy_and_excessive_distance(self):
        valid={"schema_version":1,"estimated":True,"target_tile_id":"49",
            "provenance":{"source":"fixture","status":"estimated","rationale":"test"},
            "height_rule":{"kind":"boundary_supported_idw","neighbors":1,
                "max_boundary_mismatch_m":0.01,"max_estimated_support_distance_m":1.0},
            "material":{"name":"terrain_ground","color":[0.2,0.3,0.4],"roughness":0.9},
            "regions":[{"id":"r","polygon_xz":[[0,0],[1,0],[1,1],[0,1]]}]}
        for chart in ({"kind":"foreign_copy","max_distance_m":0.02},
                      {"kind":"target_road_affine","max_distance_m":0.0201},
                      {"kind":"target_road_affine","max_distance_m":float("nan")}):
            with self.subTest(chart=chart),self.assertRaises(ValueError):
                rt._validate_land_infill_authoring({**valid,"route_attribute_chart":chart})

    def test_route_coherent_support_selects_unique_visit_chart_and_rejects_ambiguity(self):
        def hit(owner, s0, s1, z, y):
            xz=[(0.0,z),(10.0,z),(5.0,z+2.0)]
            tri={"owner":owner,"layer":"terrain","triangle":0,"primitive":0,"xz":xz,
                 "y":[y,y,y],"attributes":{"_ROUTE_S":[s0,s1,(s0+s1)*.5],
                                                  "_ROUTE_U":[0.0,0.0,0.0]}}
            bary=rt._barycentric_xz(5.0,0.5,[(x,0.0,zz) for x,zz in xz])
            return {"height":sum(bary[i]*tri["y"][i] for i in range(3)),"bary":bary,"triangle":tri}
        route={"samples":{"s":[0.0,10.0,12.0,13.0,14.0,24.0],
                           "x":[0.0,10.0,20.0,-10.0,0.0,10.0],
                           "z":[0.0,0.0,20.0,20.0,0.5,0.5]}}
        target={"from_s":0.0,"to_s":24.0,"origin":[0.0,0.0,0.0]}
        config={"station_window_m":1.0,"lateral_window_m":0.05,
                "distinct_branch_station_separation_m":5.0,"branch_ambiguity_distance_m":0.02,
                "max_selected_owner_spread_m":0.002}
        branch_old=hit("49",0.0,10.0,0.0,2.0)
        branch_visit=hit("49",14.0,24.0,0.5,2.5)
        selected,diag=rt._land_infill_select_route_coherent_hits(
            (5.0,0.5),[branch_old,branch_visit],route,target,config)
        self.assertEqual(len(selected),1)
        self.assertEqual(selected[0]["triangle"]["attributes"]["_ROUTE_S"],[14.0,24.0,19.0])
        self.assertAlmostEqual(diag["selected_height_spread_m"],0.0,places=9)
        self.assertGreater(diag["nearest_distinct_branch_distance_delta_m"],0.02)
        with self.assertRaisesRegex(ValueError,"ambiguous distinct route branches"):
            rt._land_infill_select_route_coherent_hits(
                (5.0,0.25),[branch_old,branch_visit],route,target,config)
        with self.assertRaisesRegex(ValueError,"no terrain support face matches canonical route chart"):
            rt._land_infill_select_route_coherent_hits(
                (5.0,0.5),[branch_old],route,target,config)
        same_chart_high=hit("49",14.0,24.0,0.5,3.0)
        with self.assertRaisesRegex(ValueError,"selected-owner support spread"):
            rt._land_infill_select_route_coherent_hits(
                (5.0,0.5),[branch_visit,same_chart_high],route,target,config)

    def test_unambiguous_offchart_boundary_keeps_actual_face_height(self):
        ground={"name":"terrain_ground","color":[0.3,0.42,0.2],"roughness":0.95}
        ring=self._rect(0,0,10,4)+self._rect(0,6,10,10)+self._rect(0,4,4,6)+self._rect(6,4,10,6)
        target=self._mesh("terrain",[0,0,0],ring,ground)
        # This is an intentionally alternate S chart with the exact same physical
        # boundary faces. A sole/same-height hit must retain Y=2 rather than force IDW.
        target["attributes"]["_ROUTE_S"]=[s+14.0 for s in target["attributes"]["_ROUTE_S"]]
        with tempfile.TemporaryDirectory() as td:
            for folder in ("tiles/00","route"):os.makedirs(os.path.join(td,folder))
            rt.write_glb(os.path.join(td,"tiles/00/terrain.glb"),target)
            route={"samples":{"s":[0.0,10.0],"x":[0.0,10.0],"z":[5.0,5.0]}}
            Path(os.path.join(td,"route/route.json")).write_text(json.dumps(route))
            manifest={"package_id":"unambiguous-chart-fixture","tiles":[{"id":"00","from_s":0.0,"to_s":10.0,
                "origin":[0,0,0],"files":{"terrain":"tiles/00/terrain.glb"}}]}
            Path(os.path.join(td,"manifest.json")).write_text(json.dumps(manifest))
            authoring={"schema_version":1,"estimated":True,"target_tile_id":"00",
                "provenance":{"source":"fixture","status":"estimated","rationale":"preserve unique actual boundary support"},
                "height_rule":{"kind":"boundary_supported_idw","neighbors":4,"max_boundary_mismatch_m":0.002,
                    "max_estimated_support_distance_m":4.0,"support_owner_policy":{"terrain":"terrain_coverage_owner_ids",
                        "road":"all_package_p0","foreign_terrain":"excluded"},
                    "terrain_support_chart":{"kind":"canonical_route_local",
                        "station_window_m":1.0,"lateral_window_m":0.05,"distinct_branch_station_separation_m":5.0,
                        "branch_ambiguity_distance_m":0.02}},
                "material":ground,"regions":[{"id":"hole","terrain_coverage_owner_ids":["00"],
                    "polygon_xz":[[4,4],[6,4],[6,6],[4,6]]}]}
            result=rt.apply_land_infill(td,authoring)
            self.assertGreater(result["mesh_report"]["support_hit_vertices"],0)
            self.assertAlmostEqual(result["mesh_report"]["supported_height_range_y_m"][0],2.0,places=6)
            self.assertEqual(result["mesh_report"]["route_coherent_support"]["evaluated_chart_points"],0)
            self.assertGreater(result["mesh_report"]["route_coherent_support"]["unambiguous_support_max_abs_station_delta_m"],10.0)

    def test_selected_visit_terrain_coverage_still_excludes_every_foreign_road(self):
        ground={"name":"terrain_ground","color":[0.3,0.42,0.2],"roughness":0.95}
        asphalt={"name":"road_asphalt","color":[0.18,0.18,0.18],"roughness":0.9}
        ring=[]
        ring += self._rect(0,0,10,4) + self._rect(0,6,10,10)
        ring += self._rect(0,4,4,6) + self._rect(6,4,10,6)
        target=self._mesh("terrain",[0,0,0],ring,ground)
        foreign_p1=self._mesh("old_foreign_terrain",[0,0,0],self._rect(4,4,5,5),ground)
        target_p0=self._mesh("road",[0,0,0],self._rect(4.9,4,5.1,6,2.0),asphalt)
        foreign_p0=self._mesh("old_foreign_road",[0,0,0],self._rect(5.5,4,6.0,6,2.0),asphalt)
        with tempfile.TemporaryDirectory() as td:
            for folder in ("tiles/00","tiles/03","route"):
                os.makedirs(os.path.join(td,folder))
            rt.write_glb(os.path.join(td,"tiles/00/terrain.glb"),target)
            rt.write_glb(os.path.join(td,"tiles/00/road.glb"),target_p0)
            rt.write_glb(os.path.join(td,"tiles/03/terrain.glb"),foreign_p1)
            rt.write_glb(os.path.join(td,"tiles/03/road.glb"),foreign_p0)
            Path(os.path.join(td,"route/route.json")).write_text(json.dumps({"samples":{"s":[0,10],"x":[0,10],"z":[5,5]}}))
            manifest={"package_id":"selected-coverage-fixture","tiles":[
                {"id":"00","from_s":0,"to_s":10,"origin":[0,0,0],"files":{"terrain":"tiles/00/terrain.glb","road":"tiles/00/road.glb"}},
                {"id":"03","from_s":30,"to_s":40,"origin":[0,0,0],"files":{"terrain":"tiles/03/terrain.glb","road":"tiles/03/road.glb"}}]}
            Path(os.path.join(td,"manifest.json")).write_text(json.dumps(manifest))
            authoring={"schema_version":1,"estimated":True,"target_tile_id":"00",
                "provenance":{"source":"fixture","status":"estimated","rationale":"selected P1 with all-owner P0 exclusion"},
                "height_rule":{"kind":"boundary_supported_idw","neighbors":4,"max_boundary_mismatch_m":0.002,"max_estimated_support_distance_m":4.0,
                    "support_owner_policy":{"terrain":"terrain_coverage_owner_ids","road":"all_package_p0","foreign_terrain":"excluded"}},
                "material":ground,"regions":[{"id":"hole","logical_owner_ids":["00"],"terrain_coverage_owner_ids":["00"],
                    "polygon_xz":[[0,0],[10,0],[10,10],[0,10]]}]}
            result=rt.apply_land_infill(td,authoring)
            region=result["regions"][0]
            self.assertEqual(region["terrain_coverage_owner_ids"],["00"])
            self.assertEqual(region["selected_p1_triangle_count"],len(target["primitives"][0]["indices"])//3)
            self.assertEqual(region["all_p0_triangle_count"],len(target_p0["primitives"][0]["indices"])//3+
                             len(foreign_p0["primitives"][0]["indices"])//3)
            # The 1 m² old-terrain island is overlapped by 0.1 m² foreign P0,
            # which remains excluded regardless of the selected P1 owners.
            self.assertAlmostEqual(region["duplicated_unselected_p1_coverage_area_m2"],0.9,places=5)
            self.assertGreater(region["selected_p1_all_p0_complement_area_m2"],region["all_package_complement_area_m2"])
            self.assertEqual(result["mesh_report"]["serialized_overlap_by_layer"].get("road",{}).get("pair_area_sum_m2",0.0),0.0)


if __name__ == "__main__":
    unittest.main()
