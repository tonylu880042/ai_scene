using System;
using UnityEngine;

// Keeps the real-terrain backdrop (backdrop.glb) around the runner, as the Godot scene does: it moves with the camera
// in X/Z and sits at the lake level of the route point nearest the camera (route.json water_y). Exported at the route
// start; without this component the mountains stay there and the hole cut around the start shows up further along.
// Setup: add to the instantiated backdrop.glb object, assign route.json (TextAsset) and the runner camera.
public class VirtualRunBackdrop : MonoBehaviour
{
    public TextAsset routeJson;
    public Transform runner;   // the camera; Camera.main when empty
    [Tooltip("Same as VirtualRunScatter: glTFast negates X, UnityGLTF negates Z.")]
    public VirtualRunScatter.Handedness conversion = VirtualRunScatter.Handedness.NegateX;
    public int startIndex = 0;  // environment.json route_from_m

    [Serializable] class Route { public float[] x; public float[] y; public float[] z; public float[] water_y; }
    Route _r;
    int _i;
    Vector3 _home;

    Vector3 P(int i) => conversion == VirtualRunScatter.Handedness.NegateX
        ? new Vector3(-_r.x[i], _r.y[i], _r.z[i]) : new Vector3(_r.x[i], _r.y[i], -_r.z[i]);

    void Start()
    {
        _r = JsonUtility.FromJson<Route>(routeJson.text);
        _i = startIndex;
        _home = transform.position;
    }

    void LateUpdate()
    {
        var cam = runner != null ? runner : (Camera.main != null ? Camera.main.transform : null);
        if (cam == null || _r == null) return;
        var c = cam.position;
        // nearest route point: walk from the last one (the runner moves a few metres per frame at most)
        float D(int i) { var d = P(i) - c; d.y = 0f; return d.sqrMagnitude; }
        while (_i + 1 < _r.x.Length && D(_i + 1) < D(_i)) _i++;
        while (_i > 0 && D(_i - 1) < D(_i)) _i--;
        var s0 = P(startIndex);
        transform.position = _home + new Vector3(c.x - s0.x, _r.water_y[_i] - _r.water_y[startIndex], c.z - s0.z);
    }
}
