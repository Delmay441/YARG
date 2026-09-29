// MatrixReflowAspectSyncEditor.cs
//
// Editor-only authoring utility for the MatrixRain shader/material.
//
// IMPORTANT — why this is an Editor menu command and NOT a runtime
// MonoBehaviour attached to the background quad:
//
// A YARG .yarground is an AssetBundle of plain Unity assets (Meshes,
// Materials, Textures, Lights, Cameras, AnimationClips/Controllers, Audio)
// plus the handful of component types YARG's own venue system recognizes at
// load time (BundleBackgroundManager, VenueCamera, VenueCharacter,
// VenueLight, VenueAnimator, Venue SFX). YARG does not load or execute
// arbitrary third-party script assemblies out of a venue bundle — any other
// MonoBehaviour left on a GameObject either does nothing at runtime or, worse,
// is a build-time liability. So instead of a script that has to survive
// on the quad forever, this bakes the correct _AspectRatio value directly
// into the *shared* Material asset once, at authoring time, in the Unity
// Editor — the exact same place you'd hand-type it into the Inspector.
// Nothing needs to run in-game for the shader to work correctly afterward.
//
// Place this file under an "Editor/" folder anywhere in Assets/ (e.g.
// Assets/Editor/MatrixReflowAspectSyncEditor.cs) so Unity automatically
// excludes it from player/AssetBundle builds.
#if UNITY_EDITOR
using UnityEditor;
using UnityEngine;

public static class MatrixReflowAspectSyncEditor
{
    private const string MenuPath = "Tools/Matrix Reflow/Sync Grid Aspect To Selected Quad";
    private const string AspectProperty = "_AspectRatio";

    [MenuItem(MenuPath)]
    private static void SyncSelected()
    {
        GameObject go = Selection.activeGameObject;
        if (go == null)
        {
            Debug.LogWarning("[MatrixReflow] Select the background quad in the Hierarchy first.");
            return;
        }

        Renderer renderer = go.GetComponent<Renderer>();
        if (renderer == null || renderer.sharedMaterial == null)
        {
            Debug.LogWarning("[MatrixReflow] Selected object has no Renderer or no assigned Material.");
            return;
        }

        Material mat = renderer.sharedMaterial;
        if (!mat.HasProperty(AspectProperty))
        {
            Debug.LogWarning("[MatrixReflow] '" + mat.name + "' has no " + AspectProperty +
                              " property — is it using the Custom/MatrixRain shader?");
            return;
        }

        Vector3 worldSize = go.transform.lossyScale;
        if (worldSize.y <= 0.0001f)
        {
            Debug.LogWarning("[MatrixReflow] Quad's world-space height is ~0; can't derive an aspect ratio.");
            return;
        }

        float aspect = worldSize.x / worldSize.y;

        Undo.RecordObject(mat, "Sync Matrix Reflow Grid Aspect");
        mat.SetFloat(AspectProperty, aspect);
        EditorUtility.SetDirty(mat);

        Debug.Log(string.Format("[MatrixReflow] '{0}'.{1} set to {2:F4} (from '{3}' world size {4:F2} x {5:F2}).",
            mat.name, AspectProperty, aspect, go.name, worldSize.x, worldSize.y));
    }

    [MenuItem(MenuPath, true)]
    private static bool ValidateSyncSelected()
    {
        return Selection.activeGameObject != null;
    }
}
#endif
