// Minimal glTF 2.0 binary reader for the package's own meshes (tools/road_terrain.py write_glb): one node, one mesh,
// primitives sharing float attributes, uint32 indices, PBR factor materials, optional one embedded image.
using System;
using System.Collections.Generic;
using System.IO;
using System.Text;
using Newtonsoft.Json.Linq;

namespace AIScene.Core
{
    public sealed class GlbPrimitive
    {
        public string Material;
        public double[] BaseColor = { 1, 1, 1, 1 };
        public double Roughness = 1;
        public bool Textured;
        public int[] Indices;
    }

    public sealed class GlbMesh
    {
        public string Name;
        public Vec3 Translation;
        public float[] Positions, Normals, Uv;                 // xyz / xyz / uv per vertex, node-local, glTF axes
        public readonly Dictionary<string, float[]> Extra = new Dictionary<string, float[]>();  // _ROUTE_S, _ROUTE_U
        public readonly List<GlbPrimitive> Primitives = new List<GlbPrimitive>();
        public byte[] Image;
        public string ImageMime;
        public int VertexCount => Positions.Length / 3;

        public Vec3 WorldVertex(int i) => new Vec3(Positions[3 * i] + Translation.X, Positions[3 * i + 1] + Translation.Y,
            Positions[3 * i + 2] + Translation.Z);

        public static GlbMesh Read(string path) => Parse(File.ReadAllBytes(path));

        public static GlbMesh Parse(byte[] b)
        {
            if (BitConverter.ToUInt32(b, 0) != 0x46546C67) throw new InvalidDataException("not a GLB");
            int jlen = (int)BitConverter.ToUInt32(b, 12);
            var gltf = JObject.Parse(Encoding.UTF8.GetString(b, 20, jlen));
            int bin = 20 + jlen + 8;
            var accessors = (JArray)gltf["accessors"];
            var views = (JArray)gltf["bufferViews"];

            float[] Floats(int a)
            {
                var acc = accessors[a];
                var v = views[(int)acc["bufferView"]];
                int comps = (string)acc["type"] == "VEC3" ? 3 : (string)acc["type"] == "VEC2" ? 2 : 1;
                int n = (int)acc["count"] * comps, off = bin + (int)v["byteOffset"] + ((int?)acc["byteOffset"] ?? 0);
                var f = new float[n];
                Buffer.BlockCopy(b, off, f, 0, n * 4);
                return f;
            }

            int[] Ints(int a)
            {
                var acc = accessors[a];
                var v = views[(int)acc["bufferView"]];
                int n = (int)acc["count"], off = bin + (int)v["byteOffset"] + ((int?)acc["byteOffset"] ?? 0);
                var r = new int[n];
                Buffer.BlockCopy(b, off, r, 0, n * 4);
                return r;
            }

            var node = gltf["nodes"][0];
            var t = node["translation"] as JArray;
            var mesh = new GlbMesh
            {
                Name = (string)node["name"],
                Translation = t == null ? new Vec3(0, 0, 0) : new Vec3((double)t[0], (double)t[1], (double)t[2]),
            };
            var prims = (JArray)gltf["meshes"][0]["primitives"];
            var attrs = (JObject)prims[0]["attributes"];
            foreach (var kv in attrs)
            {
                var f = Floats((int)kv.Value);
                if (kv.Key == "POSITION") mesh.Positions = f;
                else if (kv.Key == "NORMAL") mesh.Normals = f;
                else if (kv.Key == "TEXCOORD_0") mesh.Uv = f;
                else mesh.Extra[kv.Key] = f;
            }
            var mats = gltf["materials"] as JArray;
            foreach (var p in prims)
            {
                var gp = new GlbPrimitive { Indices = Ints((int)p["indices"]) };
                if (p["material"] != null && mats != null)
                {
                    var m = mats[(int)p["material"]];
                    gp.Material = (string)m["name"];
                    var pbr = m["pbrMetallicRoughness"];
                    if (pbr?["baseColorFactor"] is JArray c) gp.BaseColor = new[] { (double)c[0], (double)c[1], (double)c[2], (double)c[3] };
                    if (pbr?["roughnessFactor"] != null) gp.Roughness = (double)pbr["roughnessFactor"];
                    gp.Textured = pbr?["baseColorTexture"] != null;
                }
                mesh.Primitives.Add(gp);
            }
            if (gltf["images"] is JArray imgs && imgs.Count > 0)
            {
                var v = views[(int)imgs[0]["bufferView"]];
                mesh.Image = new byte[(int)v["byteLength"]];
                Buffer.BlockCopy(b, bin + (int)v["byteOffset"], mesh.Image, 0, mesh.Image.Length);
                mesh.ImageMime = (string)imgs[0]["mimeType"];
            }
            return mesh;
        }
    }
}
