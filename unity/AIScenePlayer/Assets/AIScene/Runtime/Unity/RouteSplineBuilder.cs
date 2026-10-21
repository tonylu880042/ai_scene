// The route as a Unity Spline (SplineContainer), for Unity-side tools (rigs, effects, editors). Gameplay keeps using
// the canonical RouteData: the spline is a derived representation and RuntimeValidator measures its deviation.
using AIScene.Core;
using Unity.Mathematics;
using UnityEngine;
using UnityEngine.Splines;

namespace AIScene.Runtime
{
    public sealed class RouteSplineBuilder : MonoBehaviour
    {
        public float knotSpacingM = 10f;
        public SplineContainer Container { get; private set; }

        void Start()
        {
            var player = GetComponent<AIScenePlayer>();
            var route = player.Route;
            var go = new GameObject("Route Spline");
            Container = go.AddComponent<SplineContainer>();
            var spline = Container.Spline;
            spline.Clear();
            for (double s = 0; ; s += knotSpacingM)
            {
                s = System.Math.Min(s, route.Length);
                var p = UnitySpace.V(route.Position(s), player.handedness);
                spline.Add(new BezierKnot(new float3(p.x, p.y, p.z)), TangentMode.AutoSmooth);
                if (s >= route.Length) break;
            }
            spline.Closed = route.File.closed;
        }

        /// <summary>Horizontal distance from a Unity point to the spline.</summary>
        public float Deviation(Vector3 p)
        {
            if (Container == null) return 0;
            SplineUtility.GetNearestPoint(Container.Spline, new float3(p.x, p.y, p.z), out float3 nearest, out float _);
            return new Vector2(nearest.x - p.x, nearest.z - p.z).magnitude;
        }
    }
}
