// Editor entry points: build a player scene, run the package validator (also from the command line).
//   Unity -batchmode -projectPath unity/AIScenePlayer -executeMethod AIScene.EditorTools.AISceneMenu.ValidateBatch -aiscene-package <dir> -quit
using System;
using AIScene.Core;
using AIScene.Runtime;
using UnityEditor;
using UnityEngine;

namespace AIScene.EditorTools
{
    public static class AISceneMenu
    {
        [MenuItem("AI Scene/Create Player In Scene")]
        public static void CreatePlayer()
        {
            var go = new GameObject("AI Scene Player");
            go.AddComponent<AIScenePlayer>();
            Undo.RegisterCreatedObjectUndo(go, "Create AI Scene Player");
            Selection.activeGameObject = go;
        }

        [MenuItem("AI Scene/Validate Package (Unity space)")]
        public static void Validate()
        {
            var r = PackageValidator.Validate(Package());
            foreach (var kv in r.Metrics) Debug.Log($"{kv.Key} = {kv.Value:0.######}");
            foreach (var e in r.Errors) Debug.LogError(e);
            Debug.Log(r.Valid ? "AI Scene Package VALID in Unity space" : $"AI Scene Package INVALID ({r.Errors.Count})");
        }

        public static void ValidateBatch()
        {
            var r = PackageValidator.Validate(Package());
            foreach (var e in r.Errors) Debug.LogError(e);
            EditorApplication.Exit(r.Valid ? 0 : 1);
        }

        static string Package()
        {
            var args = Environment.GetCommandLineArgs();
            for (int i = 0; i < args.Length - 1; i++)
                if (args[i] == "-aiscene-package") return args[i + 1];
            var env = Environment.GetEnvironmentVariable("AISCENE_PACKAGE");
            return string.IsNullOrEmpty(env) ? AIScenePlayer.DefaultPackage : env;
        }
    }
}
