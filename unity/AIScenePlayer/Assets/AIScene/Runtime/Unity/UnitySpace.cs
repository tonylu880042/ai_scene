// Package frame -> Unity types, meshes and materials. All axis handling goes through AIScene.Core.Frame.
using System.Collections.Generic;
using AIScene.Core;
using UnityEngine;
using UnityEngine.Rendering;

namespace AIScene.Runtime
{
    public static class UnitySpace
    {
        public static Vector3 V(Vec3 p, Handedness h)
        {
            var u = Frame.ToUnity(p, h);
            return new Vector3((float)u.X, (float)u.Y, (float)u.Z);
        }

        public static Quaternion Q(Quat q, Handedness h)
        {
            var u = Frame.ToUnity(q, h);
            return new Quaternion((float)u.X, (float)u.Y, (float)u.Z, (float)u.W);
        }

        public static Vec3 Back(Vector3 p, Handedness h) => Frame.FromUnity(new Vec3(p.x, p.y, p.z), h);

        /// <summary>Unity mesh from a package GLB: vertices node-local (the GameObject carries the node translation),
        /// axes converted, triangles reversed for the mirror, glTF v flipped for Unity textures.</summary>
        public static Mesh BuildMesh(GlbMesh g, Handedness h)
        {
            int n = g.VertexCount;
            var v = new Vector3[n];
            var nr = g.Normals != null ? new Vector3[n] : null;
            var uv = g.Uv != null ? new Vector2[n] : null;
            for (int i = 0; i < n; i++)
            {
                v[i] = V(new Vec3(g.Positions[3 * i], g.Positions[3 * i + 1], g.Positions[3 * i + 2]), h);
                if (nr != null) nr[i] = V(new Vec3(g.Normals[3 * i], g.Normals[3 * i + 1], g.Normals[3 * i + 2]), h);
                if (uv != null) uv[i] = new Vector2(g.Uv[2 * i], 1f - g.Uv[2 * i + 1]);
            }
            var m = new Mesh { name = g.Name, indexFormat = IndexFormat.UInt32 };
            m.vertices = v;
            if (nr != null) m.normals = nr;
            if (uv != null) m.uv = uv;
            m.subMeshCount = g.Primitives.Count;
            for (int k = 0; k < g.Primitives.Count; k++)
                m.SetTriangles(PackageValidator.UnityTriangles(g.Primitives[k].Indices), k);
            if (nr == null) m.RecalculateNormals();
            m.RecalculateBounds();
            return m;
        }

        public static Material[] BuildMaterials(GlbMesh g)
        {
            Texture2D tex = null;
            if (g.Image != null)
            {
                tex = new Texture2D(2, 2, TextureFormat.RGBA32, true);
                tex.LoadImage(g.Image);
                tex.wrapMode = TextureWrapMode.Clamp;
            }
            var mats = new Material[g.Primitives.Count];
            for (int k = 0; k < mats.Length; k++)
            {
                var p = g.Primitives[k];
                var c = new Color((float)p.BaseColor[0], (float)p.BaseColor[1], (float)p.BaseColor[2], 1f);
                mats[k] = Materials.Lit(p.Material, c, 1f - (float)p.Roughness, p.Textured ? tex : null, false);
            }
            return mats;
        }

        public static GameObject Spawn(string name, Transform parent, GlbMesh g, Handedness h, bool collider)
        {
            var go = new GameObject(name);
            go.transform.SetParent(parent, false);
            go.transform.localPosition = V(g.Translation, h);
            var mesh = BuildMesh(g, h);
            go.AddComponent<MeshFilter>().sharedMesh = mesh;
            go.AddComponent<MeshRenderer>().sharedMaterials = BuildMaterials(g);
            if (collider) go.AddComponent<MeshCollider>().sharedMesh = mesh;
            return go;
        }
    }

    /// <summary>Lit materials for the active pipeline (URP Lit or built-in Standard), cached by name.</summary>
    public static class Materials
    {
        static readonly Dictionary<string, Material> Cache = new Dictionary<string, Material>();

        static bool Urp => GraphicsSettings.currentRenderPipeline != null;

        public static Material Lit(string key, Color color, float smoothness, Texture tex, bool instancing)
        {
            string id = key + (tex != null ? "#" + tex.GetInstanceID() : "") + (instancing ? "#i" : "");
            if (Cache.TryGetValue(id, out var m) && m != null) return m;
            var shader = Shader.Find(Urp ? "Universal Render Pipeline/Lit" : "Standard");
            m = new Material(shader) { name = key, enableInstancing = instancing };
            m.SetColor(Urp ? "_BaseColor" : "_Color", color);
            m.SetFloat(Urp ? "_Smoothness" : "_Glossiness", Mathf.Clamp01(smoothness));
            if (tex != null) m.SetTexture(Urp ? "_BaseMap" : "_MainTex", tex);
            Cache[id] = m;
            return m;
        }
    }
}
