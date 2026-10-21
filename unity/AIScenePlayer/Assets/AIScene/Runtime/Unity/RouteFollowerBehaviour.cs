// Test player / camera moving along the canonical route. Keys: W / S or Up / Down speed, Space pause,
// A / D lateral, PageUp / PageDown jump 250 m, Home restart. Distance, elevation and grade come from route.json.
using AIScene.Core;
using UnityEngine;
#if ENABLE_INPUT_SYSTEM && AISCENE_INPUT_SYSTEM
using UnityEngine.InputSystem;
#endif

namespace AIScene.Runtime
{
    public sealed class RouteFollowerBehaviour : MonoBehaviour
    {
        public float eyeHeight = 1.65f;
        public float accelerationKmhPerSecond = 10f;
        public float maxSpeedKmh = 80f;
        public float lateralSpeed = 1.5f;
        public float lookAheadM = 15f;
        public float fovY = 75f;

        public RouteFollower Model { get; private set; }
        public Camera Camera { get; private set; }
        public bool Paused { get; set; }
        public double SpeedKmh => Model == null ? 0 : Model.Speed * 3.6;

        AIScenePlayer _player;
        Transform _rig;

        void Start()
        {
            _player = GetComponent<AIScenePlayer>();
            Model = new RouteFollower(_player.Route, _player.Route.File.start?.s ?? 0) { Speed = _player.startSpeedKmh / 3.6 };
            _rig = new GameObject("Test Player").transform;
            Camera = Camera.main;
            if (Camera == null) Camera = new GameObject("Camera", typeof(Camera), typeof(AudioListener)) { tag = "MainCamera" }.GetComponent<Camera>();
            Camera.transform.SetParent(_rig, false);
            Camera.fieldOfView = fovY;
            Camera.nearClipPlane = 0.05f;
            Camera.farClipPlane = 30000f;  // real backdrop mountains are ~10 km out
            Place(true);
        }

        static bool Held(int k)
        {
#if ENABLE_INPUT_SYSTEM && AISCENE_INPUT_SYSTEM
            var kb = Keyboard.current;
            if (kb == null) return false;
            switch (k)
            {
                case 0: return kb.wKey.isPressed || kb.upArrowKey.isPressed;
                case 1: return kb.sKey.isPressed || kb.downArrowKey.isPressed;
                case 2: return kb.aKey.isPressed || kb.leftArrowKey.isPressed;
                case 3: return kb.dKey.isPressed || kb.rightArrowKey.isPressed;
            }
            return false;
#elif ENABLE_LEGACY_INPUT_MANAGER
            switch (k)
            {
                case 0: return Input.GetKey(KeyCode.W) || Input.GetKey(KeyCode.UpArrow);
                case 1: return Input.GetKey(KeyCode.S) || Input.GetKey(KeyCode.DownArrow);
                case 2: return Input.GetKey(KeyCode.A) || Input.GetKey(KeyCode.LeftArrow);
                case 3: return Input.GetKey(KeyCode.D) || Input.GetKey(KeyCode.RightArrow);
            }
            return false;
#else
            return false;
#endif
        }

        static bool Pressed(int k)
        {
#if ENABLE_INPUT_SYSTEM && AISCENE_INPUT_SYSTEM
            var kb = Keyboard.current;
            if (kb == null) return false;
            switch (k)
            {
                case 0: return kb.spaceKey.wasPressedThisFrame;
                case 1: return kb.pageUpKey.wasPressedThisFrame;
                case 2: return kb.pageDownKey.wasPressedThisFrame;
                case 3: return kb.homeKey.wasPressedThisFrame;
                case 4: return kb.f1Key.wasPressedThisFrame;
                case 5: return kb.f3Key.wasPressedThisFrame;
            }
            return false;
#elif ENABLE_LEGACY_INPUT_MANAGER
            switch (k)
            {
                case 0: return Input.GetKeyDown(KeyCode.Space);
                case 1: return Input.GetKeyDown(KeyCode.PageUp);
                case 2: return Input.GetKeyDown(KeyCode.PageDown);
                case 3: return Input.GetKeyDown(KeyCode.Home);
                case 4: return Input.GetKeyDown(KeyCode.F1);
                case 5: return Input.GetKeyDown(KeyCode.F3);
            }
            return false;
#else
            return false;
#endif
        }

        public static bool ToggleHud => Pressed(4);
        public static bool ToggleDebugLines => Pressed(5);

        void Update()
        {
            if (Model == null) return;
            float dt = Time.deltaTime;
            double kmh = Model.Speed * 3.6;
            if (Held(0)) kmh += accelerationKmhPerSecond * dt;
            if (Held(1)) kmh -= accelerationKmhPerSecond * dt;
            Model.Speed = Mathf.Clamp((float)kmh, 0f, maxSpeedKmh) / 3.6;
            if (Held(2)) Model.Lateral += lateralSpeed * dt;
            if (Held(3)) Model.Lateral -= lateralSpeed * dt;
            if (Pressed(0)) Paused = !Paused;
            if (Pressed(1)) Model.S = System.Math.Min(Model.Route.Length, Model.S + 250);
            if (Pressed(2)) Model.S = System.Math.Max(0, Model.S - 250);
            if (Pressed(3)) { Model.S = Model.Route.File.start?.s ?? 0; Model.Lateral = 0; }
            Model.Step(Paused ? 0 : dt);
            Place(false);
        }

        /// <summary>Advance the model by a fixed step (tests / scripted drives) and move the rig.</summary>
        public void StepFixed(double dt)
        {
            Model.Step(dt);
            Place(true);
        }

        void Place(bool snap)
        {
            var h = _player.handedness;
            _rig.position = UnitySpace.V(Model.Position, h);
            var eye = _rig.position + Vector3.up * eyeHeight;
            var ahead = UnitySpace.V(Model.Route.PointAt(Model.S + lookAheadM, Model.Lateral), h) + Vector3.up * eyeHeight;
            var look = Quaternion.LookRotation((ahead - eye).normalized, Vector3.up);  // view pitch is visual only
            Camera.transform.position = eye;
            Camera.transform.rotation = snap ? look : Quaternion.Slerp(Camera.transform.rotation, look, 1f - Mathf.Exp(-6f * Time.deltaTime));
        }

        public Vector3 RigPosition => _rig != null ? _rig.position : Vector3.zero;
    }
}
