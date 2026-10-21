// Play mode: load the package, drive the test player through the first kilometres in fixed steps, and check what
// Unity built against route.json (road collider heights, seams, resident tiles, HUD values, vegetation clearance).
using System.Collections;
using AIScene.Runtime;
using NUnit.Framework;
using UnityEngine;
using UnityEngine.TestTools;

namespace AIScene.Tests
{
    public class PlayModeTests
    {
        GameObject _go;

        [UnityTearDown]
        public IEnumerator TearDown()
        {
            Object.Destroy(_go);
            foreach (var n in new[] { "Tiles", "Distant", "Route Debug", "Route Spline", "Test Player", "Sun" })
            {
                var o = GameObject.Find(n);
                if (o != null) Object.Destroy(o);
            }
            yield return null;
        }

        [UnityTest]
        public IEnumerator DrivesTheRouteOnTheCanonicalData()
        {
            _go = new GameObject("AI Scene Player");
            var player = _go.AddComponent<AIScenePlayer>();
            yield return null;
            Assume.That(player.LoadError, Is.Null, player.LoadError);
            var follower = player.Follower;
            follower.Paused = true;
            for (int i = 0; i < 300 && player.Tiles.Loaded < 2; i++) yield return null;
            Assert.GreaterOrEqual(player.Tiles.Loaded, 2, "tiles did not stream in");

            follower.Model.Speed = 15;  // 54 km/h
            double end = System.Math.Min(player.Route.Length, follower.Model.S + 1500);
            while (follower.Model.S < end)
            {
                follower.StepFixed(1.0 / 30.0);
                yield return null;
                var here = follower.Model.Current;
                Assert.AreEqual(player.Route.Sample(follower.Model.S).Grade, here.Grade, 1e-9, "grade must come from route.json");
            }
            for (int i = 0; i < 600 && player.Validator.Package == null; i++) yield return null;

            var v = player.Validator;
            foreach (var line in v.Summary()) Debug.Log(line);
            Assert.IsNotNull(v.Package, "package validation did not finish");
            Assert.IsTrue(v.Package.Valid, string.Join("\n", v.Package.Errors));
            Assert.IsTrue(v.Live.Valid, string.Join("\n", v.Live.Errors));
            Assert.AreEqual(0, v.MissingTileFrames, "the player stood on a tile that was not loaded");
            Assert.Greater(v.Live.Metrics["checks"], 10);
            Assert.Greater(player.Vegetation.Total, 0, "no vegetation loaded");
        }
    }
}
