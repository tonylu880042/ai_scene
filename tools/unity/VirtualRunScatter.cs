using System;
using System.Collections.Generic;
using UnityEngine;
using UnityEngine.Rendering;

// Places the repeated objects (trees, grass clumps, flowers, rocks, fence parts) of a Virtual Run Unity export.
// Setup: import the export folder with glTFast (com.unity.cloud.gltfast), drop prototypes.glb into the scene
// (disable it - it is only a source of meshes), assign it to `prototypes`, and add every tile_XX_instances.json
// (as TextAsset) to `instanceFiles`. Small meshes are drawn with GPU instancing near the camera; heavy ones
// (scanned trees) become regular GameObjects so Unity can cull and batch them.
public class VirtualRunScatter : MonoBehaviour
{
    public enum Handedness { NegateX, NegateZ }

    public GameObject prototypes;
    public TextAsset[] instanceFiles;
    [Tooltip("glTF is right-handed. glTFast converts by negating X (default); UnityGLTF negates Z. Must match the importer used for the tiles.")]
    public Handedness conversion = Handedness.NegateX;
    public float gpuDrawDistance = 160f;
    public ShadowCastingMode gpuShadows = ShadowCastingMode.On;

    [Serializable] class Group { public string proto; public int count; public float[] data; }
    [Serializable] class InstanceFile { public string tile; public Group[] groups; }

    class Batch { public Mesh mesh; public Material[] mats; public Matrix4x4[] m; public Vector3 centre; }
    readonly List<Batch> _gpu = new List<Batch>();

    void Start()
    {
        var map = new Dictionary<string, (Mesh mesh, Material[] mats, GameObject go)>();
        foreach (var mf in prototypes.GetComponentsInChildren<MeshFilter>(true))
        {
            var mr = mf.GetComponent<MeshRenderer>();
            if (mr == null || mf.sharedMesh == null) continue;
            var entry = (mf.sharedMesh, mr.sharedMaterials, mf.gameObject);
            map[mf.gameObject.name] = entry;
            if (mf.transform.parent != null && !map.ContainsKey(mf.transform.parent.name))
                map[mf.transform.parent.name] = entry;   // glTFast may put the mesh on a child of the named node
        }
        var instMats = new Dictionary<Material, Material>();
        Material Inst(Material m)
        {
            if (m == null) return null;
            if (!instMats.TryGetValue(m, out var c)) { c = new Material(m) { enableInstancing = true }; instMats[m] = c; }
            return c;
        }

        foreach (var file in instanceFiles)
        {
            var data = JsonUtility.FromJson<InstanceFile>(file.text);
            foreach (var g in data.groups)
            {
                if (!map.TryGetValue(g.proto, out var p)) { Debug.LogWarning($"VirtualRunScatter: prototype '{g.proto}' not found"); continue; }
                bool heavy = p.mesh.vertexCount > 20000;
                var list = new List<Matrix4x4>(g.count);
                for (int i = 0; i < g.count; i++)
                {
                    int k = i * 10; var d = g.data;
                    Vector3 pos; Quaternion rot;
                    if (conversion == Handedness.NegateX) { pos = new Vector3(-d[k], d[k + 1], d[k + 2]); rot = new Quaternion(d[k + 3], -d[k + 4], -d[k + 5], d[k + 6]); }
                    else { pos = new Vector3(d[k], d[k + 1], -d[k + 2]); rot = new Quaternion(-d[k + 3], -d[k + 4], d[k + 5], d[k + 6]); }
                    var scale = new Vector3(d[k + 7], d[k + 8], d[k + 9]);
                    if (heavy)
                    {
                        var go = Instantiate(p.go, pos, rot, transform);
                        go.transform.localScale = scale;
                        go.SetActive(true);
                    }
                    else list.Add(Matrix4x4.TRS(pos, rot, scale));
                }
                if (heavy) continue;
                var mats = Array.ConvertAll(p.mats, Inst);
                for (int s = 0; s < list.Count; s += 1023)   // instances come in route order, so slices are spatially compact
                {
                    var slice = list.GetRange(s, Mathf.Min(1023, list.Count - s)).ToArray();
                    var c = Vector3.zero; foreach (var m in slice) c += (Vector3)m.GetColumn(3);
                    _gpu.Add(new Batch { mesh = p.mesh, mats = mats, m = slice, centre = c / slice.Length });
                }
            }
        }
    }

    void Update()
    {
        var cam = Camera.main;
        if (cam == null) return;
        var cp = cam.transform.position;
        foreach (var b in _gpu)
        {
            if ((b.centre - cp).sqrMagnitude > gpuDrawDistance * gpuDrawDistance) continue;
            for (int sm = 0; sm < b.mesh.subMeshCount && sm < b.mats.Length; sm++)
            {
                if (b.mats[sm] == null) continue;
                var rp = new RenderParams(b.mats[sm]) { shadowCastingMode = gpuShadows, receiveShadows = true };
                Graphics.RenderMeshInstanced(rp, b.mesh, sm, b.m);
            }
        }
    }
}
