// AI Scene Package -> playable Unity world. Add to an empty GameObject (or use AI Scene > Create Player In Scene).
// The package is the source of truth; this component only loads and consumes it.
using System;
using System.IO;
using AIScene.Core;
using UnityEngine;

namespace AIScene.Runtime
{
    [DefaultExecutionOrder(-100)]
    public sealed class AIScenePlayer : MonoBehaviour
    {
        [Tooltip("Package folder (contains manifest.json). Overridden by -aiscene-package <dir> or AISCENE_PACKAGE.")]
        public string packagePath = "";
        [Tooltip("glTF -> Unity axis rule; keep NegateX unless the package says otherwise.")]
        public Handedness handedness = Handedness.NegateX;
        public float startSpeedKmh = 18f;

        public Manifest Manifest { get; private set; }
        public RouteData Route { get; private set; }
        public string PackageDir { get; private set; }
        public string LoadError { get; private set; }

        public RouteFollowerBehaviour Follower { get; private set; }
        public TileStreamer Tiles { get; private set; }
        public VegetationRenderer Vegetation { get; private set; }
        public EnvironmentLoader Environment { get; private set; }
        public RuntimeValidator Validator { get; private set; }

        public static string DefaultPackage =>
            Path.GetFullPath(Path.Combine(Application.dataPath, "..", "..", "..", "export", "packages", "weissensee_rolling_hills"));

        string ResolvePackage()
        {
            var args = System.Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == "-aiscene-package") return args[i + 1];
            var env = System.Environment.GetEnvironmentVariable("AISCENE_PACKAGE");
            if (!string.IsNullOrEmpty(env)) return env;
            return string.IsNullOrEmpty(packagePath) ? DefaultPackage : packagePath;
        }

        void Awake()
        {
            PackageDir = ResolvePackage();
            try
            {
                Manifest = Json.Load<Manifest>(Path.Combine(PackageDir, "manifest.json"));
                Route = RouteData.Load(Path.Combine(PackageDir, Manifest.route ?? "route/route.json"));
            }
            catch (Exception e)
            {
                LoadError = $"cannot load package at {PackageDir}: {e.Message}";
                Debug.LogError(LoadError);
                enabled = false;
                return;
            }
            Follower = Add<RouteFollowerBehaviour>();
            Tiles = Add<TileStreamer>();
            Vegetation = Add<VegetationRenderer>();
            Environment = Add<EnvironmentLoader>();
            Validator = Add<RuntimeValidator>();
            Add<RouteSplineBuilder>();
            Add<RouteDebugDraw>();
            Add<DebugHud>();
            Debug.Log($"AI Scene Package {Manifest.package_id}: {Route.Length:0} m, {Manifest.tiles.Count} tiles, from {PackageDir}");
        }

        T Add<T>() where T : Component => TryGetComponent<T>(out var c) ? c : gameObject.AddComponent<T>();  // not ??: Unity fake-null
    }
}
