// Package frame (right-handed, X east, Y up, Z south = glTF axes) <-> Unity world (left-handed, Y up).
using System;

namespace AIScene.Core
{
    public readonly struct Vec3
    {
        public readonly double X, Y, Z;
        public Vec3(double x, double y, double z) { X = x; Y = y; Z = z; }
        public static Vec3 operator +(Vec3 a, Vec3 b) => new Vec3(a.X + b.X, a.Y + b.Y, a.Z + b.Z);
        public static Vec3 operator -(Vec3 a, Vec3 b) => new Vec3(a.X - b.X, a.Y - b.Y, a.Z - b.Z);
        public static Vec3 operator *(Vec3 a, double k) => new Vec3(a.X * k, a.Y * k, a.Z * k);
        public double Dot(Vec3 b) => X * b.X + Y * b.Y + Z * b.Z;
        public Vec3 Cross(Vec3 b) => new Vec3(Y * b.Z - Z * b.Y, Z * b.X - X * b.Z, X * b.Y - Y * b.X);
        public double Length => Math.Sqrt(X * X + Y * Y + Z * Z);
        public double HorizontalDistance(Vec3 b) => Math.Sqrt((X - b.X) * (X - b.X) + (Z - b.Z) * (Z - b.Z));
        public override string ToString() => $"({X:0.###}, {Y:0.###}, {Z:0.###})";
    }

    public readonly struct Quat
    {
        public readonly double X, Y, Z, W;
        public Quat(double x, double y, double z, double w) { X = x; Y = y; Z = z; W = w; }
        public static Quat AboutY(double radians) => new Quat(0, Math.Sin(radians / 2), 0, Math.Cos(radians / 2));

        /// <summary>q v q* (the same algebra Unity's Quaternion * Vector3 uses).</summary>
        public Vec3 Rotate(Vec3 v)
        {
            var u = new Vec3(X, Y, Z);
            var t = u.Cross(v) * 2.0;
            return v + t * W + u.Cross(t);
        }
    }

    /// <summary>How glTF's right-handed axes map to Unity's left-handed ones. glTFast negates X (default);
    /// UnityGLTF negates Z. The same rule must be used for every package object.</summary>
    public enum Handedness { NegateX, NegateZ }

    public static class Frame
    {
        public static Vec3 ToUnity(Vec3 p, Handedness h) => h == Handedness.NegateX ? new Vec3(-p.X, p.Y, p.Z) : new Vec3(p.X, p.Y, -p.Z);

        public static Vec3 FromUnity(Vec3 p, Handedness h) => ToUnity(p, h);  // the mirror is its own inverse

        public static Quat ToUnity(Quat q, Handedness h) =>
            h == Handedness.NegateX ? new Quat(q.X, -q.Y, -q.Z, q.W) : new Quat(-q.X, -q.Y, q.Z, q.W);

        /// <summary>Unity's right vector for a forward direction (left-handed: right = up x forward).</summary>
        public static Vec3 UnityRight(Vec3 forward) => new Vec3(0, 1, 0).Cross(forward);
    }
}
