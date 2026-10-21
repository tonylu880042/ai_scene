// Runtime-side package checks, done in Unity space (after the glTF -> Unity conversion):
// position <-> route distance, elevation, grade, road mesh vs route, seamless tiles, streaming lead time,
// vegetation clear of the playable route. Engine-free, so the same checks run in Unity and under dotnet test.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;

namespace AIScene.Core
{
    public sealed class ValidationReport
    {
        public readonly List<string> Errors = new List<string>();
        public readonly SortedDictionary<string, double> Metrics = new SortedDictionary<string, double>();
        public bool Valid => Errors.Count == 0;

        public void Max(string key, double v) => Metrics[key] = Metrics.TryGetValue(key, out var o) ? Math.Max(o, v) : v;
        public void Min(string key, double v) => Metrics[key] = Metrics.TryGetValue(key, out var o) ? Math.Min(o, v) : v;
        public void Check(bool ok, string error) { if (!ok) Errors.Add(error); }
    }

    public static class PackageValidator
    {
        public const double PositionTol = 0.01, ElevationTol = 0.01, GradeTol = 0.05, MeshSlopeTol = 0.5, SeamTol = 0.001;

        public static ValidationReport Validate(string pkg, Handedness h = Handedness.NegateX, double streamAhead = 600,
            double streamBehind = 150, double streamLatency = 2.0, double testSpeed = 15.0)
        {
            var r = new ValidationReport();
            var man = Json.Load<Manifest>(Path.Combine(pkg, "manifest.json"));
            var route = RouteData.Load(Path.Combine(pkg, man.route ?? "route/route.json"));
            RouteInUnity(route, h, r);
            var roads = RoadTiles(pkg, man, route, h, r);
            Seams(man, roads, h, r);
            Streaming(man, route, r, streamAhead, streamBehind, streamLatency, testSpeed);
            Vegetation(pkg, man, route, h, r);
            return r;
        }

        /// <summary>Unity position <-> route distance, elevation, grade and left / right, for the route itself.</summary>
        public static void RouteInUnity(RouteData route, Handedness h, ValidationReport r)
        {
            var f = new RouteFollower(route);
            for (double s = 0; s <= route.Length; s += 10.0)
            {
                f.S = s;
                f.Lateral = 0.5 * f.Current.WidthLeft;
                var u = Frame.ToUnity(f.Position, h);
                var (ps, pu) = route.Project(Frame.FromUnity(u, h), s);
                r.Max("position_to_distance_error_m", Math.Abs(ps - s));
                r.Max("position_to_lateral_error_m", Math.Abs(pu - f.Lateral));
                var smp = route.Sample(s);
                r.Max("elevation_error_m", Math.Abs(u.Y - (smp.Elevation - route.File.coordinate_system.elevation_datum_m)));
                var fwd = Frame.ToUnity(RouteData.Forward(smp.Heading), h);
                var left = Frame.ToUnity(RouteData.Left(smp.Heading), h);
                r.Min("left_dot_unity_right", -left.Dot(Frame.UnityRight(fwd)));  // 1 = travel-left is Unity-left
            }
            var m = route.File.samples;
            for (int i = 1; i < route.Count - 1; i++)  // world slope in Unity space = route grade (central difference)
            {
                var a = Frame.ToUnity(new Vec3(m.x[i - 1], m.y[i - 1], m.z[i - 1]), h);
                var b = Frame.ToUnity(new Vec3(m.x[i + 1], m.y[i + 1], m.z[i + 1]), h);
                r.Max("unity_slope_vs_grade_pp", Math.Abs((b.Y - a.Y) / a.HorizontalDistance(b) * 100.0 - m.grade_percent[i]));
            }
            r.Check(r.Metrics["position_to_distance_error_m"] <= PositionTol, $"Unity position does not map back to route distance (max {r.Metrics["position_to_distance_error_m"]:0.####} m)");
            r.Check(r.Metrics["position_to_lateral_error_m"] <= PositionTol, "Unity position does not map back to its lateral offset");
            r.Check(r.Metrics["elevation_error_m"] <= ElevationTol, "Unity height differs from route.json elevation");
            r.Check(r.Metrics["unity_slope_vs_grade_pp"] <= GradeTol, $"Unity world slope differs from route.json grade_percent by {r.Metrics["unity_slope_vs_grade_pp"]:0.###} pp");
            r.Check(r.Metrics["left_dot_unity_right"] > 0.999, "travel-left is not Unity-left after the axis conversion");
        }

        /// <summary>Triangle order for Unity: the axis mirror flips winding, so each triangle is reversed.</summary>
        public static int[] UnityTriangles(int[] gltf)
        {
            var t = new int[gltf.Length];
            for (int i = 0; i < gltf.Length; i += 3) { t[i] = gltf[i]; t[i + 1] = gltf[i + 2]; t[i + 2] = gltf[i + 1]; }
            return t;
        }

        static Dictionary<string, (GlbMesh road, GlbMesh terrain)> RoadTiles(string pkg, Manifest man, RouteData route, Handedness h, ValidationReport r)
        {
            var tiles = new Dictionary<string, (GlbMesh, GlbMesh)>();
            foreach (var t in man.tiles)
            {
                var road = GlbMesh.Read(Path.Combine(pkg, t.files["road"]));
                var terr = GlbMesh.Read(Path.Combine(pkg, t.files["terrain"]));
                tiles[t.id] = (road, terr);
                var rs = road.Extra["_ROUTE_S"];
                var ru = road.Extra["_ROUTE_U"];
                var centre = new List<(double s, Vec3 p)>();
                for (int i = 0; i < road.VertexCount; i++)
                {
                    var u = Frame.ToUnity(road.WorldVertex(i), h);
                    var want = Frame.ToUnity(route.PointAt(rs[i], ru[i]), h);
                    r.Max("road_vertex_position_error_m", u.HorizontalDistance(want));
                    r.Max("road_vertex_elevation_error_m", Math.Abs(u.Y - want.Y));
                    if (Math.Abs(ru[i]) < 1e-3) centre.Add((rs[i], u));
                }
                centre.Sort((a, b) => a.s.CompareTo(b.s));
                for (int k = 1; k < centre.Count; k++)
                {
                    var (s0, a) = centre[k - 1];
                    var (s1, b) = centre[k];
                    double slope = (b.Y - a.Y) / a.HorizontalDistance(b) * 100.0;
                    double g = 0.5 * (route.Sample(s0).Grade + route.Sample(s1).Grade);
                    r.Max("road_mesh_slope_vs_grade_pp", Math.Abs(slope - g));
                }
                foreach (var prim in road.Primitives)  // faces up in Unity after the winding flip
                {
                    var tri = UnityTriangles(prim.Indices);
                    for (int k = 0; k < tri.Length; k += 3)
                    {
                        var a = Frame.ToUnity(road.WorldVertex(tri[k]), h);
                        var n = (Frame.ToUnity(road.WorldVertex(tri[k + 1]), h) - a).Cross(Frame.ToUnity(road.WorldVertex(tri[k + 2]), h) - a);
                        if (n.Y <= 0) { r.Errors.Add($"tile {t.id}: road triangle faces down in Unity"); break; }
                    }
                }
            }
            r.Check(r.Metrics["road_vertex_position_error_m"] <= PositionTol, "road mesh not on the route in Unity space");
            r.Check(r.Metrics["road_vertex_elevation_error_m"] <= ElevationTol, "road mesh height differs from route.json elevation");
            r.Check(r.Metrics["road_mesh_slope_vs_grade_pp"] <= MeshSlopeTol, "road mesh slope differs from route.json grade");
            return tiles;
        }

        static List<(double u, Vec3 p)> Row(GlbMesh m, double s, Handedness h)
        {
            var rs = m.Extra["_ROUTE_S"];
            var ru = m.Extra["_ROUTE_U"];
            var row = new List<(double, Vec3)>();
            for (int i = 0; i < m.VertexCount; i++)
                if (Math.Abs(rs[i] - s) < 1e-3) row.Add((ru[i], Frame.ToUnity(m.WorldVertex(i), h)));
            row.Sort((a, b) => a.Item1.CompareTo(b.Item1));
            return row;
        }

        /// <summary>Neighbouring tiles share their boundary row: the same vertices in Unity space (road and terrain).</summary>
        static void Seams(Manifest man, Dictionary<string, (GlbMesh road, GlbMesh terrain)> tiles, Handedness h, ValidationReport r)
        {
            r.Metrics["tile_seam_gap_m"] = 0;
            for (int k = 1; k < man.tiles.Count; k++)
            {
                var a = man.tiles[k - 1];
                var b = man.tiles[k];
                r.Check(Math.Abs(a.to_s - b.from_s) < 1e-6, $"tiles {a.id}/{b.id} leave a gap in s");
                foreach (var pick in new Func<(GlbMesh road, GlbMesh terrain), GlbMesh>[] { x => x.road, x => x.terrain })
                {
                    var ra = Row(pick(tiles[a.id]), a.to_s, h);
                    var rb = Row(pick(tiles[b.id]), b.from_s, h);
                    if (ra.Count != rb.Count || ra.Count == 0) { r.Errors.Add($"seam {a.id}|{b.id}: boundary rows differ"); continue; }
                    for (int i = 0; i < ra.Count; i++)
                    {
                        var d = ra[i].p - rb[i].p;
                        r.Max("tile_seam_gap_m", Math.Max(Math.Abs(d.X), Math.Max(Math.Abs(d.Y), Math.Abs(d.Z))));
                    }
                }
            }
            r.Check(r.Metrics["tile_seam_gap_m"] <= SeamTol, $"tile seams open by {r.Metrics["tile_seam_gap_m"]:0.####} m");
        }

        /// <summary>Drive the route at testSpeed: every tile must have been requested at least `latency` seconds before
        /// the player enters it, and the tile under the player is never unloaded.</summary>
        public static void Streaming(Manifest man, RouteData route, ValidationReport r, double ahead, double behind, double latency, double speed)
        {
            var f = new RouteFollower(route) { Speed = speed };
            var since = new Dictionary<string, double>();
            double t = 0, dt = 1.0 / 30.0, minLead = double.MaxValue;
            string current = null;
            while (f.S < route.Length - 1e-6)
            {
                var wanted = TileStreaming.Wanted(man.tiles, f.S, ahead, behind);
                foreach (var id in wanted) if (!since.ContainsKey(id)) since[id] = t;
                foreach (var id in since.Keys.ToList()) if (!wanted.Contains(id)) since.Remove(id);
                var here = TileStreaming.At(man.tiles, f.S).id;
                if (!since.ContainsKey(here)) { r.Errors.Add($"tile {here} under the player is not requested at s={f.S:0}"); break; }
                if (here != current)
                {
                    if (current != null) minLead = Math.Min(minLead, t - since[here]);
                    current = here;
                }
                f.Step(dt);
                t += dt;
            }
            r.Metrics["stream_min_lead_s"] = minLead == double.MaxValue ? 0 : minLead;
            r.Check(man.tiles.Count < 2 || minLead >= latency, $"a tile is requested only {minLead:0.0} s before the player reaches it (needs {latency} s)");
        }

        /// <summary>Vegetation transforms in Unity space map back to the route clear of the playable band.</summary>
        public static void Vegetation(string pkg, Manifest man, RouteData route, Handedness h, ValidationReport r)
        {
            var protoPath = Path.Combine(pkg, "vegetation", "prototypes.json");
            if (!File.Exists(protoPath)) return;
            var protos = Json.Load<VegetationPrototypes>(protoPath);
            int n = 0;
            foreach (var t in man.tiles)
            {
                if (t.files == null || !t.files.TryGetValue("vegetation", out var vf)) continue;
                var vt = Json.Load<VegetationTile>(Path.Combine(pkg, vf));
                foreach (var g in vt.groups)
                {
                    double need = protos.clearance_m.TryGetValue(g.category, out var c) ? c : 0.3;
                    for (int k = 0; k < g.count; k++)
                    {
                        var u = Frame.ToUnity(new Vec3(g.data[10 * k], g.data[10 * k + 1], g.data[10 * k + 2]), h);
                        var (s, lat) = route.Project(Frame.FromUnity(u, h), g.s[k]);
                        double clear = Math.Abs(lat) - route.WidthOnSide(s, lat);
                        r.Min("vegetation_min_clearance_" + g.category + "_m", clear);
                        // placement rule: centre(s) + left(s) * lateral, compared in Unity space
                        var want = Frame.ToUnity(route.PointAt(g.s[k], g.lateral_offset_m[k]), h);
                        r.Max("vegetation_position_error_m", u.HorizontalDistance(want));
                        if (clear < need - 0.01) r.Errors.Add($"tile {t.id}: {g.proto} at s={s:0.0} is {clear:0.00} m from the road edge (needs {need})");
                        n++;
                    }
                }
            }
            r.Metrics["vegetation_instances"] = n;
            if (n > 0) r.Check(r.Metrics["vegetation_position_error_m"] <= 0.02, "vegetation transforms disagree with their s / lateral offset");
        }
    }
}
