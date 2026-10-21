// Test player on the route: speed along the surface, distance s horizontal (ds = v dt / sqrt(1 + grade^2)).
using System;

namespace AIScene.Core
{
    public sealed class RouteFollower
    {
        public readonly RouteData Route;
        public double S;             // m, route distance (horizontal)
        public double Speed;         // m/s along the road surface
        public double Lateral;       // m, + left of the centreline, clamped to the playable band
        public double Travelled;     // m along the surface

        public RouteFollower(RouteData route, double startS = 0) { Route = route; S = startS; }

        public void Step(double dt)
        {
            double g = Route.Sample(S).Grade / 100.0;
            double ds = Speed * dt / Math.Sqrt(1 + g * g);
            double before = S;
            S = Math.Max(0, Math.Min(Route.Length, S + ds));
            Travelled += Math.Abs(S - before) * Math.Sqrt(1 + g * g);
            var p = Route.Sample(S);
            Lateral = Math.Max(-p.WidthRight, Math.Min(p.WidthLeft, Lateral));
        }

        public RouteSample Current => Route.Sample(S);
        public Vec3 Position => Route.PointAt(S, Lateral);
        public Vec3 Forward => RouteData.Forward(Current.Heading);
    }
}
