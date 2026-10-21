// Checks while playing: the package validator (core, Unity space) once at load, then live checks against the
// objects Unity actually built - road collider height under the player, seams at tile boundaries, the tile under
// the player resident, spline deviation, vegetation clear of the playable band.
using System.Collections.Generic;
using System.Threading.Tasks;
using AIScene.Core;
using UnityEngine;

namespace AIScene.Runtime
{
    public sealed class RuntimeValidator : MonoBehaviour
    {
        public float checkEveryM = 20f;
        public float roadHeightTol = 0.02f, seamTol = 0.01f, splineTol = 0.1f;

        public ValidationReport Package { get; private set; }
        public readonly ValidationReport Live = new ValidationReport();
        public int MissingTileFrames { get; private set; }

        AIScenePlayer _player;
        Task<ValidationReport> _task;
        double _nextCheck;
        string _lastTile;

        void Start()
        {
            _player = GetComponent<AIScenePlayer>();
            string dir = _player.PackageDir;
            var h = _player.handedness;
            var t = _player.Tiles;
            _task = Task.Run(() => PackageValidator.Validate(dir, h, t.aheadM, t.behindM));
            Live.Metrics["road_height_error_m"] = 0;
            Live.Metrics["tile_seam_step_m"] = 0;
            Live.Metrics["spline_deviation_m"] = 0;
            Live.Metrics["checks"] = 0;
        }

        void Update()
        {
            if (_task != null && _task.IsCompleted)
            {
                Package = _task.IsFaulted ? Fail(_task.Exception?.GetBaseException().Message) : _task.Result;
                foreach (var e in Package.Errors) Debug.LogError("package: " + e);
                Debug.Log($"package validation (Unity space): {(Package.Valid ? "VALID" : "INVALID")}");
                _task = null;
            }
            var f = _player.Follower.Model;
            if (f == null) return;
            var tile = _player.Tiles.CurrentTile;
            if (tile != null && !_player.Tiles.IsLoaded(tile)) MissingTileFrames++;  // standing on a tile not built yet
            if (f.S >= _nextCheck && tile != null && _player.Tiles.IsLoaded(tile)) { CheckHere(f); _nextCheck = f.S + checkEveryM; }
            if (_lastTile != null && tile != _lastTile) CheckSeam(f);
            _lastTile = tile;
        }

        static ValidationReport Fail(string msg) { var r = new ValidationReport(); r.Errors.Add(msg); return r; }

        float? RoadY(Vector3 at)
        {
            var origin = at + Vector3.up * 50f;
            return Physics.Raycast(origin, Vector3.down, out var hit, 200f) ? hit.point.y : (float?)null;
        }

        void CheckHere(RouteFollower f)
        {
            var h = _player.handedness;
            var want = UnitySpace.V(f.Position, h);
            var y = RoadY(want);
            Live.Metrics["checks"]++;
            if (y == null) { Live.Errors.Add($"no road collider under the player at s={f.S:0}"); return; }
            Live.Max("road_height_error_m", Mathf.Abs(y.Value - want.y));  // collider (rendered mesh) vs route.json
            if (Mathf.Abs(y.Value - want.y) > roadHeightTol) Live.Errors.Add($"road mesh {y.Value - want.y:0.000} m off route.json at s={f.S:0}");
            var back = _player.Route.Project(UnitySpace.Back(_player.Follower.RigPosition, h), f.S);
            Live.Max("position_to_distance_error_m", System.Math.Abs(back.s - f.S));
            var spline = GetComponent<RouteSplineBuilder>();
            if (spline != null) Live.Max("spline_deviation_m", spline.Deviation(UnitySpace.V(f.Route.Position(f.S), h)));
            foreach (var (pos, cat) in _player.Vegetation.LoadedInstances())  // nothing on the playable band nearby
            {
                if ((pos - want).sqrMagnitude > 60f * 60f) continue;
                var pr = _player.Route.Project(UnitySpace.Back(pos, h), f.S);
                double clear = System.Math.Abs(pr.u) - _player.Route.WidthOnSide(pr.s, pr.u);
                Live.Min("vegetation_min_clearance_m", clear);
                if (clear < _player.Vegetation.Clearance(cat) - 0.01) Live.Errors.Add($"{cat} {clear:0.00} m from the road edge at s={pr.s:0}");
            }
        }

        void CheckSeam(RouteFollower f)
        {
            var tiles = _player.Manifest.tiles;
            var t = TileStreaming.At(tiles, f.S);
            var h = _player.handedness;
            var a = RoadY(UnitySpace.V(f.Route.PointAt(t.from_s - 0.25, 0), h));
            var b = RoadY(UnitySpace.V(f.Route.PointAt(t.from_s + 0.25, 0), h));
            if (a == null || b == null) { Live.Errors.Add($"seam at s={t.from_s:0}: road missing on one side"); return; }
            float step = Mathf.Abs(a.Value - b.Value) - Mathf.Abs((float)(f.Route.Sample(t.from_s + 0.25).Y - f.Route.Sample(t.from_s - 0.25).Y));
            Live.Max("tile_seam_step_m", Mathf.Abs(step));
            if (Mathf.Abs(step) > seamTol) Live.Errors.Add($"seam at s={t.from_s:0}: {step:0.000} m step");
        }

        public bool AllValid => Package != null && Package.Valid && Live.Valid && MissingTileFrames == 0
            && Live.Metrics["spline_deviation_m"] <= splineTol;

        public IEnumerable<string> Summary()
        {
            yield return Package == null ? "package check: running" : $"package check: {(Package.Valid ? "VALID" : Package.Errors.Count + " errors")}";
            yield return $"live: {(Live.Valid ? "OK" : Live.Errors.Count + " errors")}  road dy {Live.Metrics["road_height_error_m"]:0.000} m  seam {Live.Metrics["tile_seam_step_m"]:0.000} m  spline {Live.Metrics["spline_deviation_m"]:0.00} m  missing-tile frames {MissingTileFrames}";
        }
    }
}
