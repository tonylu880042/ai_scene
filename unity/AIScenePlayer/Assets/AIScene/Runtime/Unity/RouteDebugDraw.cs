// Route debug lines: centreline (yellow), playable edges (white), tile boundaries (cyan), start / finish (green / red),
// checkpoints (magenta). F3 toggles.
using System.Collections.Generic;
using AIScene.Core;
using UnityEngine;

namespace AIScene.Runtime
{
    public sealed class RouteDebugDraw : MonoBehaviour
    {
        public bool show = true;
        public float stepM = 2f;
        public float lift = 0.05f;

        readonly List<GameObject> _lines = new List<GameObject>();

        void Start()
        {
            var player = GetComponent<AIScenePlayer>();
            var route = player.Route;
            var h = player.handedness;
            var root = new GameObject("Route Debug").transform;
            var centre = new List<Vector3>();
            var left = new List<Vector3>();
            var right = new List<Vector3>();
            for (double s = 0; ; s += stepM)
            {
                s = System.Math.Min(s, route.Length);
                var p = route.Sample(s);
                centre.Add(UnitySpace.V(route.PointAt(s, 0), h) + Vector3.up * lift);
                left.Add(UnitySpace.V(route.PointAt(s, p.WidthLeft), h) + Vector3.up * lift);
                right.Add(UnitySpace.V(route.PointAt(s, -p.WidthRight), h) + Vector3.up * lift);
                if (s >= route.Length) break;
            }
            Line(root, "centreline", centre, Color.yellow, 0.06f);
            Line(root, "left edge", left, Color.white, 0.04f);
            Line(root, "right edge", right, Color.white, 0.04f);
            foreach (var t in player.Manifest.tiles) Across(root, route, h, "tile " + t.id, t.from_s, Color.cyan, 0.3f);
            if (route.File.start != null) Across(root, route, h, "START", route.File.start.s, Color.green, 3f);
            if (route.File.finish != null) Across(root, route, h, "FINISH", route.File.finish.s, Color.red, 3f);
            foreach (var c in route.File.checkpoints ?? new List<Marker>()) Across(root, route, h, c.id, c.s, Color.magenta, 2f);
        }

        void Across(Transform root, RouteData route, Handedness h, string name, double s, Color c, float height)
        {
            var p = route.Sample(s);
            var a = UnitySpace.V(route.PointAt(s, p.WidthLeft + 0.5), h);
            var b = UnitySpace.V(route.PointAt(s, -p.WidthRight - 0.5), h);
            Line(root, name, new List<Vector3> { a + Vector3.up * lift, a + Vector3.up * height, b + Vector3.up * height, b + Vector3.up * lift }, c, 0.05f);
        }

        void Line(Transform root, string name, List<Vector3> pts, Color c, float width)
        {
            var go = new GameObject(name);
            go.transform.SetParent(root, false);
            var lr = go.AddComponent<LineRenderer>();
            lr.positionCount = pts.Count;
            lr.SetPositions(pts.ToArray());
            lr.widthMultiplier = width;
            lr.material = new Material(Shader.Find("Sprites/Default"));
            lr.startColor = lr.endColor = c;
            lr.shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            _lines.Add(go);
        }

        void Update()
        {
            if (RouteFollowerBehaviour.ToggleDebugLines) show = !show;
            foreach (var l in _lines) if (l.activeSelf != show) l.SetActive(show);
        }
    }
}
