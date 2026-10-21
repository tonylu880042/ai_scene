// Debug HUD (IMGUI, not production UI): route distance, speed, elevation, grade from route.json, current tile,
// streaming and vegetation counts, validation status, controls. F1 toggles.
using UnityEngine;

namespace AIScene.Runtime
{
    public sealed class DebugHud : MonoBehaviour
    {
        public bool show = true;
        AIScenePlayer _player;
        float _fps;
        GUIStyle _style;

        void Start() => _player = GetComponent<AIScenePlayer>();

        void Update()
        {
            if (RouteFollowerBehaviour.ToggleHud) show = !show;
            _fps = Mathf.Lerp(_fps, 1f / Mathf.Max(Time.unscaledDeltaTime, 1e-4f), 0.05f);
        }

        void OnGUI()
        {
            if (!show || _player == null || _player.Follower?.Model == null) return;
            _style ??= new GUIStyle(GUI.skin.box) { alignment = TextAnchor.UpperLeft, fontSize = 15, richText = true };
            var f = _player.Follower.Model;
            var p = f.Current;  // canonical route.json sample: gameplay facts never come from the mesh
            double kmh = f.Speed * 3.6;
            string pace = kmh > 0.5 ? $"{(int)(60 / kmh)}:{(int)(60 / kmh % 1 * 60):00} min/km" : "--";
            var v = _player.Validator;
            string text =
                $"<b>{_player.Manifest.package_id}</b>\n" +
                $"distance   {f.S,8:0.0} m / {_player.Route.Length:0} m   ({f.S / 1000:0.000} km)\n" +
                $"speed      {kmh,8:0.0} km/h   {pace}{(_player.Follower.Paused ? "   PAUSED" : "")}\n" +
                $"elevation  {p.Elevation,8:0.00} m\n" +
                $"grade      {p.Grade,8:0.00} %   (route.json)\n" +
                $"heading    {p.Heading,8:0.0} deg   surface {p.Surface}   width {p.WidthRight:0.0} + {p.WidthLeft:0.0} m   lateral {f.Lateral:+0.0;-0.0} m\n" +
                $"tile       {_player.Tiles.CurrentTile}   loaded {_player.Tiles.Loaded}   pending {_player.Tiles.Pending}\n" +
                $"vegetation drawn {_player.Vegetation.Drawn} / {_player.Vegetation.Total} loaded   {_fps:0} fps\n" +
                (v != null ? string.Join("\n", v.Summary()) + "\n" : "") +
                "W/S speed  A/D lateral  Space pause  PgUp/PgDn 250 m  Home restart  F1 HUD  F3 lines";
            GUI.Box(new Rect(10, 10, 760, 230), text, _style);
        }
    }
}
