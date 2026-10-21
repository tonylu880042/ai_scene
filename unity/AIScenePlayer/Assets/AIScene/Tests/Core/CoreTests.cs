// Engine-free tests of AIScene.Core against a real package. Run by Unity (EditMode) and by `dotnet test unity/CoreTests`.
// Package: AISCENE_PACKAGE, else export/packages/weissensee_rolling_hills found by walking up from the test directory.
using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using AIScene.Core;
using Newtonsoft.Json;
using Newtonsoft.Json.Linq;
using NUnit.Framework;

namespace AIScene.Tests
{
    public class CoreTests
    {
        static string _pkg;

        static string Pkg
        {
            get
            {
                if (_pkg != null) return _pkg;
                var env = Environment.GetEnvironmentVariable("AISCENE_PACKAGE");
                if (!string.IsNullOrEmpty(env)) return _pkg = env;
                foreach (var start in new[] { TestContext.CurrentContext.TestDirectory, Directory.GetCurrentDirectory() })
                    for (var d = new DirectoryInfo(start); d != null; d = d.Parent)
                    {
                        var p = Path.Combine(d.FullName, "export", "packages", "weissensee_rolling_hills");
                        if (File.Exists(Path.Combine(p, "manifest.json"))) return _pkg = p;
                    }
                Assert.Ignore("no AI Scene Package found (set AISCENE_PACKAGE)");
                return null;
            }
        }

        static Manifest Man => Json.Load<Manifest>(Path.Combine(Pkg, "manifest.json"));
        static RouteData Route => RouteData.Load(Path.Combine(Pkg, "route", "route.json"));

        [Test]
        public void SampleReturnsRouteJsonValuesAndInterpolates()
        {
            var r = Route;
            var m = r.File.samples;
            for (int i = 0; i < r.Count - 1; i += 97)
            {
                var a = r.Sample(m.s[i]);
                Assert.AreEqual(m.elevation_m[i], a.Elevation, 1e-9);
                Assert.AreEqual(m.grade_percent[i], a.Grade, 1e-9);
                Assert.AreEqual(m.surface_type[i], a.Surface);
                var mid = r.Sample(0.5 * (m.s[i] + m.s[i + 1]));
                Assert.AreEqual(0.5 * (m.elevation_m[i] + m.elevation_m[i + 1]), mid.Elevation, 1e-9);
            }
        }

        [Test]
        public void ProjectionRoundTrip()
        {
            var r = Route;
            foreach (var s in new[] { 0.0, 123.4, 2500.0, 4999.0 })
                foreach (var u in new[] { -0.4, 0.0, 0.4 })
                {
                    var (ps, pu) = r.Project(r.PointAt(s, u), s);
                    Assert.AreEqual(s, ps, 0.01, $"s at {s}");
                    Assert.AreEqual(u, pu, 0.01, $"u at {s}");
                }
        }

        [Test]
        public void AxisConversionKeepsRotationsAndSides()
        {
            foreach (var h in new[] { Handedness.NegateX, Handedness.NegateZ })
            {
                var q = Quat.AboutY(0.7);
                var v = new Vec3(3, 1, -2);
                var a = Frame.ToUnity(q, h).Rotate(Frame.ToUnity(v, h));
                var b = Frame.ToUnity(q.Rotate(v), h);
                Assert.AreEqual(0, (a - b).Length, 1e-9);
                var fwd = Frame.ToUnity(RouteData.Forward(37), h);
                var left = Frame.ToUnity(RouteData.Left(37), h);
                Assert.AreEqual(-1, left.Dot(Frame.UnityRight(fwd)), 1e-9);  // travel-left is Unity-left
            }
        }

        [Test]
        public void FollowerMovesAlongTheSurfaceAndReportsRouteGrade()
        {
            var r = Route;
            int i = Array.FindIndex(r.File.samples.grade_percent, g => g > 4.5);
            var f = new RouteFollower(r, r.SampleS(i)) { Speed = 10 };
            double g0 = f.Current.Grade, s0 = f.S;
            f.Step(1.0);
            Assert.AreEqual(10 / Math.Sqrt(1 + g0 * g0 / 1e4), f.S - s0, 1e-3);
            Assert.AreEqual(r.Sample(f.S).Grade, f.Current.Grade, 1e-12);
            f.Lateral = 99;
            f.Step(0);
            Assert.AreEqual(f.Current.WidthLeft, f.Lateral, 1e-12);  // clamped to the playable band
        }

        [Test]
        public void StreamingPlanAndTileLookup()
        {
            var tiles = Man.tiles;
            Assert.AreEqual(tiles[0].id, TileStreaming.At(tiles, 0).id);
            Assert.AreEqual(tiles[1].id, TileStreaming.At(tiles, tiles[1].from_s).id);
            Assert.AreEqual(tiles[tiles.Count - 1].id, TileStreaming.At(tiles, tiles[tiles.Count - 1].to_s).id);
            var w = TileStreaming.Wanted(tiles, 2500, 600, 150);
            Assert.IsTrue(w.Contains(TileStreaming.At(tiles, 2500).id) && w.Contains(TileStreaming.At(tiles, 3050).id));
            Assert.IsFalse(w.Contains(TileStreaming.At(tiles, 1000).id));
        }

        [Test]
        public void LodLevels()
        {
            var p = new VegetationPrototype { lod = new LodHints { lod_distances_m = new[] { 40.0, 120.0 }, cull_distance_m = 250 } };
            Assert.AreEqual(new[] { 0, 1, 2, -1 }, new[] { 10.0, 100.0, 200.0, 300.0 }.Select(d => Lod.Level(p, d)).ToArray());
        }

        [Test]
        public void ReadsPackageGlb()
        {
            var t = Man.tiles[0];
            var road = GlbMesh.Read(Path.Combine(Pkg, t.files["road"]));
            Assert.AreEqual(t.origin[0], road.Translation.X, 1e-9);
            Assert.IsTrue(road.Extra.ContainsKey("_ROUTE_S") && road.Extra.ContainsKey("_ROUTE_U"));
            Assert.AreEqual(3 * (int)Math.Round(t.to_s - t.from_s + 1), road.VertexCount);
            Assert.IsTrue(road.Primitives.All(p => p.Material.StartsWith("road_")));
            var distant = GlbMesh.Read(Path.Combine(Pkg, "environment", "distant_terrain.glb"));
            Assert.AreEqual("image/jpeg", distant.ImageMime);
            Assert.AreEqual(0xFF, distant.Image[0]);
        }

        [Test]
        public void DecodesSkyAndItsSunIsWhereTheEnvironmentSays()
        {
            var env = Json.Load<EnvironmentFile>(Path.Combine(Pkg, "environment", "environment.json"));
            var img = HdrImage.Read(Path.Combine(Pkg, env.atmosphere.sky.file));
            Assert.AreEqual(2 * img.Height, img.Width);
            int best = 0;
            for (int i = 0; i < img.Width * img.Height; i++)
            {
                Assert.IsTrue(img.Rgb[3 * i] >= 0 && !float.IsNaN(img.Rgb[3 * i]));
                if (img.Rgb[3 * i + 1] > img.Rgb[3 * best + 1]) best = i;
            }
            double u = (best % img.Width + 0.5) / img.Width, elev = 90.0 - (best / img.Width + 0.5) / img.Height * 180.0;
            Assert.AreEqual(env.atmosphere.sky.sun_in_image.u, u, 0.01);
            Assert.AreEqual(env.atmosphere.sky.sun_in_image.elevation_deg, elev, 2.0);
        }

        [Test]
        public void WholePackageIsValidInUnitySpace()
        {
            var r = PackageValidator.Validate(Pkg);
            foreach (var kv in r.Metrics) TestContext.WriteLine($"{kv.Key} = {kv.Value:0.######}");
            Assert.IsTrue(r.Valid, string.Join("\n", r.Errors.Take(10)));
        }

        [Test]
        public void StreamingTooShortAheadIsReported()
        {
            var r = new ValidationReport();
            PackageValidator.Streaming(Man, Route, r, ahead: 20, behind: 0, latency: 2.0, speed: 15);
            Assert.IsFalse(r.Valid);
        }

        [Test]
        public void VegetationOnTheRoadIsReported()
        {
            var tmp = Path.Combine(Path.GetTempPath(), "aiscene_veg_" + Guid.NewGuid().ToString("N"));
            try
            {
                var man = Man;
                Directory.CreateDirectory(Path.Combine(tmp, "vegetation"));
                File.Copy(Path.Combine(Pkg, "vegetation", "prototypes.json"), Path.Combine(tmp, "vegetation", "prototypes.json"));
                foreach (var t in man.tiles)
                {
                    var src = JObject.Parse(File.ReadAllText(Path.Combine(Pkg, t.files["vegetation"])));
                    if (t.id == man.tiles[0].id)  // move the first tree onto the centreline
                    {
                        var g = src["groups"].First(x => (string)x["category"] == "conifer" || (string)x["category"] == "deciduous_tree");
                        double s = (double)g["s"][0];
                        var p = Route.Position(s);
                        g["data"][0] = p.X; g["data"][1] = p.Y; g["data"][2] = p.Z;
                        g["lateral_offset_m"][0] = 0.0;
                    }
                    Directory.CreateDirectory(Path.Combine(tmp, Path.GetDirectoryName(t.files["vegetation"])));
                    File.WriteAllText(Path.Combine(tmp, t.files["vegetation"]), src.ToString(Formatting.None));
                }
                var r = new ValidationReport();
                PackageValidator.Vegetation(tmp, man, Route, Handedness.NegateX, r);
                Assert.IsTrue(r.Errors.Any(e => e.Contains("from the road edge")), string.Join("\n", r.Errors));
            }
            finally { Directory.Delete(tmp, true); }
        }
    }
}
