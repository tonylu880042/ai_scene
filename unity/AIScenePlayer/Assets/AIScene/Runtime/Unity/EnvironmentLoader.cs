// environment/environment.json -> Unity: sun light, ambient, fog, HDR sky (decoded by the core), distant terrain and
// water following the runner (pivot height and yaw from the package's follow_runner samples).
using System;
using System.IO;
using System.Threading.Tasks;
using AIScene.Core;
using UnityEngine;

namespace AIScene.Runtime
{
    public sealed class EnvironmentLoader : MonoBehaviour
    {
        [Tooltip("Unity light intensity for intensity_relative = 1 (a standard clear day).")]
        public float sunIntensityScale = 0.8f;
        public float ambientIntensityScale = 0.8f;
        [Tooltip("Extra sky yaw if the HDRI's sun does not sit behind the light (degrees).")]
        public float skyRotationOffsetDeg = 0f;

        public EnvironmentFile Data { get; private set; }
        public Light Sun { get; private set; }

        AIScenePlayer _player;
        Transform _distant;
        Task<HdrImage> _sky;
        FollowRunner _follow;

        void Start()
        {
            _player = GetComponent<AIScenePlayer>();
            var path = Path.Combine(_player.PackageDir, _player.Manifest.environment ?? "environment/environment.json");
            if (!File.Exists(path)) { enabled = false; return; }
            Data = Json.Load<EnvironmentFile>(path);
            var h = _player.handedness;
            var atm = Data.atmosphere;
            // sun: the light shines along -direction_to_sun
            Sun = FindFirstObjectByType<Light>();
            if (Sun == null || Sun.type != LightType.Directional) Sun = new GameObject("Sun").AddComponent<Light>();
            Sun.type = LightType.Directional;
            Sun.shadows = LightShadows.Soft;
            var toSun = UnitySpace.V(new Vec3(atm.sun.direction_to_sun[0], atm.sun.direction_to_sun[1], atm.sun.direction_to_sun[2]), h);
            Sun.transform.rotation = Quaternion.LookRotation(-toSun.normalized, Vector3.up);
            Sun.color = Gamma(atm.sun.color_linear);
            Sun.intensity = (float)atm.sun.intensity_relative * sunIntensityScale;
            RenderSettings.sun = Sun;
            // fog: exponential extinction per metre
            if (atm.fog != null)
            {
                RenderSettings.fog = atm.fog.density_per_m > 0;
                RenderSettings.fogMode = FogMode.Exponential;
                RenderSettings.fogDensity = (float)atm.fog.density_per_m;
                RenderSettings.fogColor = Gamma(atm.fog.color_linear);
            }
            RenderSettings.ambientIntensity = (float)(atm.ambient?.intensity_relative ?? 1.0) * ambientIntensityScale;
            if (atm.sky?.file != null)
            {
                var sky = Path.Combine(_player.PackageDir, atm.sky.file);
                _sky = Task.Run(() => HdrImage.Read(sky));
            }
            // distant terrain + water
            _follow = Data.distant?.anchors?.follow_runner;
            _distant = new GameObject("Distant").transform;
            foreach (var t in Data.distant?.terrain ?? new System.Collections.Generic.List<DistantTerrain>())
            {
                var g = GlbMesh.Read(Path.Combine(_player.PackageDir, t.file));
                var go = UnitySpace.Spawn(t.id, _distant, g, h, false);
                go.GetComponent<MeshRenderer>().shadowCastingMode = UnityEngine.Rendering.ShadowCastingMode.Off;
            }
            foreach (var w in Data.distant?.water ?? new System.Collections.Generic.List<WaterBody>())
                Water(w);
        }

        static Color Gamma(double[] lin) => lin == null ? Color.white :
            new Color(Mathf.LinearToGammaSpace((float)lin[0]), Mathf.LinearToGammaSpace((float)lin[1]), Mathf.LinearToGammaSpace((float)lin[2]));

        void Water(WaterBody w)
        {
            float hx = (float)w.geometry.size_m[0] / 2, hz = (float)w.geometry.size_m[1] / 2, y = (float)w.level_offset_m;
            var m = new Mesh { name = w.id };
            m.vertices = new[] { new Vector3(-hx, y, -hz), new Vector3(-hx, y, hz), new Vector3(hx, y, hz), new Vector3(hx, y, -hz) };
            m.triangles = new[] { 0, 1, 2, 0, 2, 3 };  // clockwise seen from above
            m.RecalculateNormals();
            var go = new GameObject("water_" + w.id);
            go.transform.SetParent(_distant, false);
            go.AddComponent<MeshFilter>().sharedMesh = m;
            var c = new Color(0.02f, 0.2f, 0.3f);
            if (w.appearance != null && w.appearance.TryGetValue("deep_color_linear", out var dc) && dc is Newtonsoft.Json.Linq.JArray a)
                c = Gamma(new[] { (double)a[0], (double)a[1], (double)a[2] });
            go.AddComponent<MeshRenderer>().sharedMaterial = Materials.Lit("water_" + w.id, c, 0.9f, null, false);
        }

        void LateUpdate()
        {
            if (_sky != null && _sky.IsCompleted)
            {
                if (_sky.IsFaulted) Debug.LogError("sky: " + _sky.Exception?.GetBaseException().Message);
                else ApplySky(_sky.Result);
                _sky = null;
            }
            var f = _player.Follower.Model;
            if (f == null || _follow == null || _distant == null) return;
            // pivot under the runner at the water level below the road, turned with the route (follow_runner rule)
            int i = Array.BinarySearch(_follow.s, f.S);
            if (i < 0) i = ~i - 1;
            i = Mathf.Clamp(i, 0, _follow.s.Length - 2);
            double t = (f.S - _follow.s[i]) / (_follow.s[i + 1] - _follow.s[i]);
            double off = _follow.pivot_y_offset_m[i] + (_follow.pivot_y_offset_m[i + 1] - _follow.pivot_y_offset_m[i]) * t;
            double yaw = _follow.yaw_deg[i] + (_follow.yaw_deg[i + 1] - _follow.yaw_deg[i]) * t;
            var c = f.Current;
            var h = _player.handedness;
            _distant.position = UnitySpace.V(new Vec3(c.X, c.Y + off, c.Z), h);
            _distant.rotation = UnitySpace.Q(Quat.AboutY(yaw * Math.PI / 180.0), h);
        }

        void ApplySky(HdrImage img)
        {
            var tex = new Texture2D(img.Width, img.Height, TextureFormat.RGBAHalf, false, true) { wrapModeU = TextureWrapMode.Repeat, wrapModeV = TextureWrapMode.Clamp };
            var px = new ushort[img.Width * img.Height * 4];
            for (int y = 0; y < img.Height; y++)
            {
                int src = y * img.Width * 3, dst = (img.Height - 1 - y) * img.Width * 4;  // HDR row 0 is the top
                for (int x = 0; x < img.Width; x++)
                {
                    px[dst + 4 * x] = Mathf.FloatToHalf(img.Rgb[src + 3 * x]);
                    px[dst + 4 * x + 1] = Mathf.FloatToHalf(img.Rgb[src + 3 * x + 1]);
                    px[dst + 4 * x + 2] = Mathf.FloatToHalf(img.Rgb[src + 3 * x + 2]);
                    px[dst + 4 * x + 3] = Mathf.FloatToHalf(1f);
                }
            }
            tex.SetPixelData(px, 0);
            tex.Apply(false, true);
            var mat = new Material(Shader.Find("Skybox/Panoramic"));
            mat.SetTexture("_MainTex", tex);
            mat.SetFloat("_Mapping", 1);    // latitude-longitude
            mat.SetFloat("_ImageType", 0);  // 360 degrees
            mat.SetFloat("_Exposure", (float)(Data.atmosphere.sky.intensity_relative <= 0 ? 1 : Data.atmosphere.sky.intensity_relative));
            // ponytail: assumes Skybox/Panoramic looks up u = 0.5 - atan2(z, x) / 2pi of the un-rotated direction while
            // drawing the dome rotated by _Rotation; verify once that the sun disc sits behind the light, else set skyRotationOffsetDeg
            var d = Sun.transform.forward * -1f;
            float phi = Mathf.Atan2(d.z, d.x) * Mathf.Rad2Deg;
            mat.SetFloat("_Rotation", Mathf.Repeat(phi - 360f * (0.5f - (float)Data.atmosphere.sky.sun_in_image.u) + skyRotationOffsetDeg, 360f));
            RenderSettings.skybox = mat;
            RenderSettings.ambientMode = UnityEngine.Rendering.AmbientMode.Skybox;
            DynamicGI.UpdateEnvironment();
        }
    }
}
