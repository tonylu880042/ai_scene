// Stand-in meshes per vegetation category (the package defines prototypes, not meshes). Two LODs each, sized from
// the prototype's height range; instancing-enabled materials. Swap in real assets per prototype id later.
using System.Collections.Generic;
using AIScene.Core;
using UnityEngine;

namespace AIScene.Runtime
{
    public static class PlaceholderPrototypes
    {
        public sealed class Visual
        {
            public Mesh[] Lods;          // LOD0 .. LODn (submesh k uses Materials[k])
            public Material[] Materials;
            public bool CastShadows;
        }

        static readonly Color Bark = new Color(0.33f, 0.25f, 0.18f), Broadleaf = new Color(0.25f, 0.42f, 0.16f),
            Needles = new Color(0.12f, 0.27f, 0.14f), Grass = new Color(0.36f, 0.52f, 0.2f), Rock = new Color(0.5f, 0.5f, 0.48f),
            Flower = new Color(0.9f, 0.82f, 0.3f), Fern = new Color(0.22f, 0.45f, 0.18f), Palm = new Color(0.3f, 0.5f, 0.2f);

        public static Visual Build(VegetationPrototype p)
        {
            float h = p.height_m != null && p.height_m.Length == 2 ? (float)(0.5 * (p.height_m[0] + p.height_m[1])) : 1f;
            var mat = new System.Func<string, Color, Material>((k, c) => Materials.Lit("veg_" + k, c, 0.1f, null, true));
            switch (p.category)
            {
                case "deciduous_tree":
                    return new Visual { Lods = new[] { Tree(h, false, 10, 8), Tree(h, false, 5, 3) }, Materials = new[] { mat("bark", Bark), mat("broadleaf", Broadleaf) }, CastShadows = true };
                case "conifer":
                    return new Visual { Lods = new[] { Tree(h, true, 10, 8), Tree(h, true, 5, 3) }, Materials = new[] { mat("bark", Bark), mat("needles", Needles) }, CastShadows = true };
                case "tropical_tree":
                    return new Visual { Lods = new[] { Palm_(h, 8), Palm_(h, 4) }, Materials = new[] { mat("bark", Bark), mat("palm", Palm) }, CastShadows = true };
                case "shrub":
                    return new Visual { Lods = new[] { Blob(h, 8, 5, Vector3.one), Blob(h, 5, 3, Vector3.one) }, Materials = new[] { mat("broadleaf", Broadleaf) }, CastShadows = true };
                case "rocks":
                    return new Visual { Lods = new[] { Blob(h, 7, 4, new Vector3(1.3f, 0.7f, 1f)), Blob(h, 4, 2, new Vector3(1.3f, 0.7f, 1f)) }, Materials = new[] { mat("rock", Rock) }, CastShadows = true };
                case "flowers":
                    return new Visual { Lods = new[] { Cross(h, 0.25f, 3) }, Materials = new[] { mat("flowers", Flower) } };
                case "ground_cover":
                    return new Visual { Lods = new[] { Cross(h, 0.8f, 3) }, Materials = new[] { mat("fern", Fern) } };
                default:  // grass
                    return new Visual { Lods = new[] { Cross(h, 0.35f, 3), Cross(h, 0.35f, 2) }, Materials = new[] { mat("grass", Grass) } };
            }
        }

        sealed class Builder
        {
            readonly List<Vector3> _v = new List<Vector3>();
            readonly List<List<int>> _t = new List<List<int>>();

            public Builder(int submeshes) { for (int i = 0; i < submeshes; i++) _t.Add(new List<int>()); }

            // Unity front faces are clockwise; orient each triangle away from `inside`, or add both sides
            public void Tri(int sub, Vector3 a, Vector3 b, Vector3 c, Vector3? inside)
            {
                if (inside.HasValue && Vector3.Dot(Vector3.Cross(b - a, c - a), (a + b + c) / 3f - inside.Value) < 0) { var x = b; b = c; c = x; }
                int i = _v.Count;
                _v.Add(a); _v.Add(b); _v.Add(c);
                _t[sub].Add(i); _t[sub].Add(i + 1); _t[sub].Add(i + 2);
                if (!inside.HasValue) { _v.Add(a); _v.Add(c); _v.Add(b); _t[sub].Add(i + 3); _t[sub].Add(i + 4); _t[sub].Add(i + 5); }
            }

            public void Cone(int sub, float y0, float y1, float r0, float r1, int seg)
            {
                var axis = new Vector3(0, 0.5f * (y0 + y1), 0);
                for (int k = 0; k < seg; k++)
                {
                    float a0 = k * Mathf.PI * 2 / seg, a1 = (k + 1) * Mathf.PI * 2 / seg;
                    var p0 = new Vector3(Mathf.Cos(a0) * r0, y0, Mathf.Sin(a0) * r0);
                    var p1 = new Vector3(Mathf.Cos(a1) * r0, y0, Mathf.Sin(a1) * r0);
                    var q0 = new Vector3(Mathf.Cos(a0) * r1, y1, Mathf.Sin(a0) * r1);
                    var q1 = new Vector3(Mathf.Cos(a1) * r1, y1, Mathf.Sin(a1) * r1);
                    Tri(sub, p0, p1, q1, axis);
                    if (r1 > 0) Tri(sub, p0, q1, q0, axis);
                    Tri(sub, p0, p1, new Vector3(0, y0, 0), new Vector3(0, y0 + 1, 0));  // base cap faces down
                }
            }

            public void Sphere(int sub, Vector3 c, Vector3 r, int seg, int rings, int seed)
            {
                var rng = new System.Random(seed);
                var pts = new Vector3[rings + 1, seg];
                for (int i = 0; i <= rings; i++)
                    for (int k = 0; k < seg; k++)
                    {
                        float th = Mathf.PI * i / rings, ph = Mathf.PI * 2 * k / seg, j = 1f + 0.12f * (float)(rng.NextDouble() - 0.5);
                        pts[i, k] = c + Vector3.Scale(r, new Vector3(Mathf.Sin(th) * Mathf.Cos(ph), Mathf.Cos(th), Mathf.Sin(th) * Mathf.Sin(ph))) * j;
                    }
                for (int i = 0; i < rings; i++)
                    for (int k = 0; k < seg; k++)
                    {
                        int k1 = (k + 1) % seg;
                        Tri(sub, pts[i, k], pts[i + 1, k], pts[i + 1, k1], c);
                        Tri(sub, pts[i, k], pts[i + 1, k1], pts[i, k1], c);
                    }
            }

            public Mesh Done(string name)
            {
                var m = new Mesh { name = name };
                m.SetVertices(_v);
                m.subMeshCount = _t.Count;
                for (int i = 0; i < _t.Count; i++) m.SetTriangles(_t[i], i);
                m.RecalculateNormals();
                m.RecalculateBounds();
                return m;
            }
        }

        static Mesh Tree(float h, bool conifer, int seg, int rings)
        {
            var b = new Builder(2);
            b.Cone(0, 0, conifer ? h * 0.3f : h * 0.55f, h * 0.018f + 0.08f, h * 0.012f + 0.05f, Mathf.Max(4, seg / 2));
            if (conifer) b.Cone(1, h * 0.15f, h, h * 0.2f, 0f, seg);
            else b.Sphere(1, new Vector3(0, h * 0.65f, 0), new Vector3(h * 0.27f, h * 0.33f, h * 0.27f), seg, rings, 7);
            return b.Done(conifer ? "conifer" : "deciduous");
        }

        static Mesh Palm_(float h, int seg)
        {
            var b = new Builder(2);
            b.Cone(0, 0, h, 0.2f, 0.12f, Mathf.Max(4, seg / 2));
            b.Sphere(1, new Vector3(0, h, 0), new Vector3(h * 0.3f, h * 0.08f, h * 0.3f), seg, 3, 3);
            return b.Done("palm");
        }

        static Mesh Blob(float h, int seg, int rings, Vector3 shape)
        {
            var b = new Builder(1);
            b.Sphere(0, new Vector3(0, h * 0.45f * shape.y, 0), new Vector3(h * 0.5f * shape.x, h * 0.5f * shape.y, h * 0.5f * shape.z), seg, rings, 11);
            return b.Done("blob");
        }

        static Mesh Cross(float h, float width, int planes)
        {
            var b = new Builder(1);
            for (int k = 0; k < planes; k++)
            {
                float a = Mathf.PI * k / planes;
                var d = new Vector3(Mathf.Cos(a), 0, Mathf.Sin(a)) * (width * 0.5f);
                b.Tri(0, -d, d, d + Vector3.up * h, null);
                b.Tri(0, -d, d + Vector3.up * h, -d + Vector3.up * h, null);
            }
            return b.Done("cross");
        }
    }
}
