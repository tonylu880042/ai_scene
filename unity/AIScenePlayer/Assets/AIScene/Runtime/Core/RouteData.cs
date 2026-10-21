// The canonical route (route.json, docs/ROUTE_SCHEMA.md) at runtime: sampling, boundaries, projection.
// Gameplay facts (distance, elevation, grade, width, surface) always come from here, never from mesh orientation.
using System;

namespace AIScene.Core
{
    public struct RouteSample
    {
        public double S, X, Y, Z, Elevation, Grade, Heading, Curvature, WidthLeft, WidthRight;
        public string Surface;
        public Vec3 Position => new Vec3(X, Y, Z);
    }

    public sealed class RouteData
    {
        public readonly RouteFile File;
        public readonly double Length;
        readonly double[] _s;
        readonly RouteSamples _m;

        public RouteData(RouteFile file)
        {
            File = file;
            _m = file.samples;
            _s = _m.s;
            Length = file.total_length_m;
        }

        public static RouteData Load(string path) => new RouteData(Json.Load<RouteFile>(path));

        public int Count => _s.Length;
        public double SampleS(int i) => _s[i];

        int Segment(double s, out double t)
        {
            s = Math.Max(_s[0], Math.Min(s, _s[_s.Length - 1]));
            int i = Array.BinarySearch(_s, s);
            if (i < 0) i = ~i - 1;
            i = Math.Max(0, Math.Min(i, _s.Length - 2));
            t = (s - _s[i]) / (_s[i + 1] - _s[i]);
            return i;
        }

        static double Lerp(double a, double b, double t) => a + (b - a) * t;
        public static double Wrap180(double a) => ((a + 180.0) % 360.0 + 360.0) % 360.0 - 180.0;

        /// <summary>Every field linearly interpolated at s; heading by the shortest angle (as route_model.sample).</summary>
        public RouteSample Sample(double s)
        {
            int i = Segment(s, out double t);
            var m = _m;
            return new RouteSample
            {
                S = Math.Max(_s[0], Math.Min(s, _s[_s.Length - 1])),
                X = Lerp(m.x[i], m.x[i + 1], t), Y = Lerp(m.y[i], m.y[i + 1], t), Z = Lerp(m.z[i], m.z[i + 1], t),
                Elevation = Lerp(m.elevation_m[i], m.elevation_m[i + 1], t),
                Grade = Lerp(m.grade_percent[i], m.grade_percent[i + 1], t),
                Heading = ((m.heading_deg[i] + Wrap180(m.heading_deg[i + 1] - m.heading_deg[i]) * t) % 360.0 + 360.0) % 360.0,
                Curvature = Lerp(m.curvature[i], m.curvature[i + 1], t),
                WidthLeft = Lerp(m.width_left_m[i], m.width_left_m[i + 1], t),
                WidthRight = Lerp(m.width_right_m[i], m.width_right_m[i + 1], t),
                Surface = t < 0.5 ? m.surface_type[i] : m.surface_type[i + 1],
            };
        }

        public Vec3 Position(double s) => Sample(s).Position;

        /// <summary>Horizontal unit vector to the left of travel for a compass heading (package frame).</summary>
        public static Vec3 Left(double headingDeg)
        {
            double b = headingDeg * Math.PI / 180.0;
            return new Vec3(-Math.Cos(b), 0, -Math.Sin(b));
        }

        public static Vec3 Forward(double headingDeg)
        {
            double b = headingDeg * Math.PI / 180.0;
            return new Vec3(Math.Sin(b), 0, -Math.Cos(b));
        }

        /// <summary>Point on the route surface at distance s, lateral offset u (+ left); the road is flat across.</summary>
        public Vec3 PointAt(double s, double u)
        {
            var p = Sample(s);
            return p.Position + Left(p.Heading) * u;
        }

        /// <summary>World point -> (s, lateral offset) by the nearest horizontal centreline segment. With a hint,
        /// only segments within +-window metres of it are searched (a route may pass near itself).</summary>
        public (double s, double u) Project(Vec3 p, double sHint = double.NaN, double window = 60.0)
        {
            int i0 = 0, i1 = _s.Length - 2;
            if (!double.IsNaN(sHint))
            {
                i0 = Math.Max(0, Segment(sHint - window, out _));
                i1 = Math.Min(_s.Length - 2, Segment(sHint + window, out _) + 1);
            }
            double best = double.MaxValue, bs = 0, bu = 0;
            var m = _m;
            for (int i = i0; i <= i1; i++)
            {
                double ax = m.x[i], az = m.z[i], dx = m.x[i + 1] - ax, dz = m.z[i + 1] - az;
                double len2 = dx * dx + dz * dz;
                double t = len2 > 0 ? Math.Max(0, Math.Min(1, ((p.X - ax) * dx + (p.Z - az) * dz) / len2)) : 0;
                double cx = ax + dx * t, cz = az + dz * t;
                double d2 = (p.X - cx) * (p.X - cx) + (p.Z - cz) * (p.Z - cz);
                if (d2 < best)
                {
                    best = d2;
                    bs = _s[i] + (_s[i + 1] - _s[i]) * t;
                    var left = Left(Sample(bs).Heading);
                    bu = (p.X - cx) * left.X + (p.Z - cz) * left.Z;
                }
            }
            return (bs, bu);
        }

        public double WidthOnSide(double s, double u)
        {
            var p = Sample(s);
            return u >= 0 ? p.WidthLeft : p.WidthRight;
        }
    }
}
