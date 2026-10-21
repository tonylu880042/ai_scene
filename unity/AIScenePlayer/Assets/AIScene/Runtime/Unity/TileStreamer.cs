// Streams road + terrain tiles by route distance (core TileStreaming plan). GLBs are parsed off the main thread with
// the core reader, meshes built on the main thread. The road gets a MeshCollider (collision / player placement).
using System.Collections.Generic;
using System.IO;
using System.Threading.Tasks;
using AIScene.Core;
using UnityEngine;

namespace AIScene.Runtime
{
    public sealed class TileStreamer : MonoBehaviour
    {
        public float aheadM = 600f;
        public float behindM = 150f;
        public int maxBuildsPerFrame = 1;

        public string CurrentTile { get; private set; }
        public int Loaded => _loaded.Count;
        public int Pending => _pending.Count;
        public event System.Action<TileRecord> TileLoaded, TileUnloaded;

        sealed class Pending_ { public TileRecord Tile; public Task<(GlbMesh road, GlbMesh terrain)> Task; }

        readonly Dictionary<string, GameObject> _loaded = new Dictionary<string, GameObject>();
        readonly Dictionary<string, Pending_> _pending = new Dictionary<string, Pending_>();
        AIScenePlayer _player;
        Transform _root;

        public bool IsLoaded(string id) => _loaded.ContainsKey(id);
        public IEnumerable<string> LoadedIds => _loaded.Keys;

        void Start()
        {
            _player = GetComponent<AIScenePlayer>();
            _root = new GameObject("Tiles").transform;
        }

        void Update()
        {
            var tiles = _player.Manifest.tiles;
            double s = _player.Follower.Model?.S ?? 0;
            CurrentTile = TileStreaming.At(tiles, s)?.id;
            var wanted = TileStreaming.Wanted(tiles, s, aheadM, behindM);
            foreach (var t in tiles)
                if (wanted.Contains(t.id) && !_loaded.ContainsKey(t.id) && !_pending.ContainsKey(t.id))
                {
                    string dir = _player.PackageDir;
                    var rec = t;
                    _pending[t.id] = new Pending_
                    {
                        Tile = rec,
                        Task = Task.Run(() => (GlbMesh.Read(Path.Combine(dir, rec.files["road"])), GlbMesh.Read(Path.Combine(dir, rec.files["terrain"])))),
                    };
                }
            int built = 0;
            foreach (var id in new List<string>(_pending.Keys))
            {
                var p = _pending[id];
                if (!p.Task.IsCompleted || built >= maxBuildsPerFrame) continue;
                _pending.Remove(id);
                if (p.Task.IsFaulted) { Debug.LogError($"tile {id}: {p.Task.Exception?.GetBaseException().Message}"); continue; }
                if (!wanted.Contains(id)) continue;  // passed it while loading
                var go = new GameObject("tile_" + id);
                go.transform.SetParent(_root, false);
                UnitySpace.Spawn("road", go.transform, p.Task.Result.road, _player.handedness, true);
                UnitySpace.Spawn("terrain", go.transform, p.Task.Result.terrain, _player.handedness, true);
                _loaded[id] = go;
                built++;
                TileLoaded?.Invoke(p.Tile);
            }
            foreach (var id in new List<string>(_loaded.Keys))
                if (!wanted.Contains(id))
                {
                    foreach (var mf in _loaded[id].GetComponentsInChildren<MeshFilter>()) Destroy(mf.sharedMesh);
                    Destroy(_loaded[id]);
                    _loaded.Remove(id);
                    TileUnloaded?.Invoke(tiles.Find(t => t.id == id));
                }
        }
    }
}
