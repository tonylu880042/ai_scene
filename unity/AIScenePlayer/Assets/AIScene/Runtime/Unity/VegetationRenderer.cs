// Draws vegetation instances of the loaded tiles with GPU instancing (Graphics.RenderMeshInstanced), culled per
// 64 m cell (frustum + distance) and per instance (prototype cull distance), LOD per prototype (core Lod.Level).
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using AIScene.Core;
using UnityEngine;
using UnityEngine.Rendering;

namespace AIScene.Runtime
{
    public sealed class VegetationRenderer : MonoBehaviour
    {
        public float cellSize = 64f;
        public float lodBias = 1f;   // > 1 keeps detail farther

        public int Total { get; private set; }
        public int Drawn { get; private set; }

        sealed class Group
        {
            public int Proto;
            public Matrix4x4[] Matrices;
            public Vector3[] Positions;
            public List<(Bounds bounds, List<int> items)> Cells;
        }

        AIScenePlayer _player;
        VegetationPrototypes _protos;
        readonly Dictionary<string, int> _protoIndex = new Dictionary<string, int>();
        PlaceholderPrototypes.Visual[] _visuals;
        readonly Dictionary<string, List<Group>> _tiles = new Dictionary<string, List<Group>>();
        readonly Dictionary<string, Task<VegetationTile>> _pending = new Dictionary<string, Task<VegetationTile>>();
        List<Matrix4x4>[][] _batches;  // [proto][lod]
        readonly Plane[] _planes = new Plane[6];
        const int Chunk = 1023;

        void Start()
        {
            _player = GetComponent<AIScenePlayer>();
            var path = Path.Combine(_player.PackageDir, "vegetation", "prototypes.json");
            if (!File.Exists(path)) { enabled = false; return; }
            _protos = Json.Load<VegetationPrototypes>(path);
            _visuals = new PlaceholderPrototypes.Visual[_protos.prototypes.Count];
            _batches = new List<Matrix4x4>[_protos.prototypes.Count][];
            for (int i = 0; i < _protos.prototypes.Count; i++)
            {
                _protoIndex[_protos.prototypes[i].id] = i;
                _visuals[i] = PlaceholderPrototypes.Build(_protos.prototypes[i]);
                _batches[i] = new List<Matrix4x4>[_visuals[i].Lods.Length];
                for (int l = 0; l < _batches[i].Length; l++) _batches[i][l] = new List<Matrix4x4>();
            }
            _player.Tiles.TileLoaded += OnTileLoaded;
            _player.Tiles.TileUnloaded += t => { if (t != null) { _tiles.Remove(t.id); _pending.Remove(t.id); Recount(); } };
        }

        void OnTileLoaded(TileRecord t)
        {
            if (t.files == null || !t.files.TryGetValue("vegetation", out var f)) return;
            var path = Path.Combine(_player.PackageDir, f);
            _pending[t.id] = Task.Run(() => Json.Load<VegetationTile>(path));
        }

        void Recount()
        {
            int n = 0;
            foreach (var gs in _tiles.Values) foreach (var g in gs) n += g.Matrices.Length;
            Total = n;
        }

        void Build(string id, VegetationTile vt)
        {
            var h = _player.handedness;
            var groups = new List<Group>();
            foreach (var g in vt.groups)
            {
                if (!_protoIndex.TryGetValue(g.proto, out int pi)) continue;
                var gr = new Group { Proto = pi, Matrices = new Matrix4x4[g.count], Positions = new Vector3[g.count] };
                var pts = new List<Vec3>(g.count);
                for (int k = 0; k < g.count; k++)
                {
                    int o = 10 * k;
                    var pos = UnitySpace.V(new Vec3(g.data[o], g.data[o + 1], g.data[o + 2]), h);
                    var rot = UnitySpace.Q(new Quat(g.data[o + 3], g.data[o + 4], g.data[o + 5], g.data[o + 6]), h);
                    gr.Matrices[k] = Matrix4x4.TRS(pos, rot, new Vector3(g.data[o + 7], g.data[o + 8], g.data[o + 9]));
                    gr.Positions[k] = pos;
                    pts.Add(new Vec3(pos.x, pos.y, pos.z));
                }
                float height = (float)(_protos.prototypes[pi].height_m?[1] ?? 2.0) * 1.2f;
                gr.Cells = new List<(Bounds, List<int>)>();
                foreach (var cell in new InstanceGrid(pts, cellSize).Cells.Values)
                {
                    var b = new Bounds(gr.Positions[cell[0]], Vector3.zero);
                    foreach (int i in cell) b.Encapsulate(gr.Positions[i]);
                    b.max += Vector3.up * height;
                    b.Expand(2f);
                    gr.Cells.Add((b, cell));
                }
                groups.Add(gr);
            }
            _tiles[id] = groups;
            Recount();
        }

        void LateUpdate()
        {
            foreach (var id in new List<string>(_pending.Keys))
            {
                var t = _pending[id];
                if (!t.IsCompleted) continue;
                _pending.Remove(id);
                if (t.IsFaulted) Debug.LogError($"vegetation {id}: {t.Exception?.GetBaseException().Message}");
                else if (_player.Tiles.IsLoaded(id)) Build(id, t.Result);
            }
            var cam = _player.Follower.Camera;
            if (cam == null) return;
            GeometryUtility.CalculateFrustumPlanes(cam, _planes);
            var eye = cam.transform.position;
            foreach (var per in _batches) foreach (var l in per) l.Clear();
            foreach (var groups in _tiles.Values)
                foreach (var g in groups)
                {
                    var proto = _protos.prototypes[g.Proto];
                    double cull = (proto.lod?.cull_distance_m ?? 300) * lodBias;
                    var lods = _batches[g.Proto];
                    foreach (var (bounds, items) in g.Cells)
                    {
                        if (Mathf.Sqrt(bounds.SqrDistance(eye)) > cull || !GeometryUtility.TestPlanesAABB(_planes, bounds)) continue;
                        foreach (int i in items)
                        {
                            int level = Lod.Level(proto, Vector3.Distance(eye, g.Positions[i]) / lodBias);
                            if (level < 0) continue;
                            lods[Mathf.Min(level, lods.Length - 1)].Add(g.Matrices[i]);
                        }
                    }
                }
            int drawn = 0;
            for (int p = 0; p < _batches.Length; p++)
            {
                var vis = _visuals[p];
                for (int l = 0; l < _batches[p].Length; l++)
                {
                    var list = _batches[p][l];
                    if (list.Count == 0) continue;
                    var mesh = vis.Lods[l];
                    for (int sub = 0; sub < mesh.subMeshCount; sub++)
                    {
                        var rp = new RenderParams(vis.Materials[sub]) { shadowCastingMode = vis.CastShadows ? ShadowCastingMode.On : ShadowCastingMode.Off, receiveShadows = true };
                        for (int start = 0; start < list.Count; start += Chunk)
                            Graphics.RenderMeshInstanced(rp, mesh, sub, list, Mathf.Min(Chunk, list.Count - start), start);
                    }
                    drawn += list.Count;
                }
            }
            Drawn = drawn;
        }

        /// <summary>Unity-space positions of every loaded instance with its category (runtime clearance checks).</summary>
        public IEnumerable<(Vector3 pos, string category)> LoadedInstances()
        {
            foreach (var groups in _tiles.Values)
                foreach (var g in groups)
                    foreach (var p in g.Positions) yield return (p, _protos.prototypes[g.Proto].category);
        }

        public double Clearance(string category) => _protos?.clearance_m != null && _protos.clearance_m.TryGetValue(category, out var c) ? c : 0.3;
    }
}
