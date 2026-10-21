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
import sys
import tempfile
import unittest

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import build_route as br  # noqa: E402
import road_terrain as rt  # noqa: E402
import route_model as rm  # noqa: E402
import semantics as sm  # noqa: E402
import environment as en  # noqa: E402
import validate_package as vp  # noqa: E402
import structures as stc  # noqa: E402
import vegetation as vg  # noqa: E402


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

    def test_tight_bend_terrain_does_not_fold(self):
        pkg = self._package("hairpin", raw_route(length=400, grade=3.0, radius=40))
        rt.build(pkg, tile_m=250)
        self.assertEqual([e for e in rt.validate(pkg)[0] if "fold" in e], [])

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


class VegetationTest(unittest.TestCase):
    """1000 m straight route, 3 m either side: forest right, grass + lake left, a house block, a guardrail, a tunnel."""

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

    def test_every_object_has_the_required_fields(self):
        for o in self.objs:
            for k in ("object_id", "semantic_type", "s", "lateral_offset_m", "transform", "dimensions_m", "prototype",
                      "confidence", "source", "importance"):
                self.assertIn(k, o)

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


if __name__ == "__main__":
    unittest.main()
