#if UNITY_EDITOR
using UnityEngine;
using UnityEditor;

// Editor-only preview driver for CRT_MatrixTempoClock (Hidden/MatrixRain/TempoClock).
//
// WHY THIS EXISTS: that shader integrates live song tempo into a monotonic clock by
// reading unity_DeltaTime.x every update -- but Unity reports unity_DeltaTime.x as
// exactly 0 for Custom Render Textures outside Play mode (see the shader's own
// "_DebugDeltaTime" property comment). With dt == 0 every update, the shader's
// `if (dt <= 1e-5) return prev;` guard holds its previous state forever, so in Scene
// view / material preview the integrated clock freezes almost immediately after its
// first tick. Since M_MatrixRain's _TempoInfluence defaults to 0.85, the rain's fall
// clock (gs.rainClock in MatrixRain.shader) ends up 85% weighted toward that frozen
// value and only 15% toward real time -- so in the editor the rain crawls forward at
// roughly 15% of its intended speed, while everything keyed directly off _Time.y (the
// glyph mutation bucket, most visibly) keeps ticking at full real-time rate. That
// mismatch is exactly the "mutations look fast, fall speed is nearly locked" symptom.
//
// This is purely an editor-authoring gap, not a bug in the live gameplay path: during
// a real song unity_DeltaTime.x is a normal nonzero per-frame delta and the clock
// integrates correctly on its own, completely untouched by this file.
//
// FIX: feed the shader's existing "_DebugDeltaTime" authoring hook with a real
// wall-clock delta while NOT in Play mode. This never calls SetDirty/Save on the
// material -- it only sets an in-memory value on the loaded Material instance for
// live preview, so the asset on disk (and therefore any .yarground export) is
// untouched and always ships with _DebugDeltaTime == 0, exactly as the shader's
// property comment requires.
[InitializeOnLoad]
internal static class MatrixRainTempoClockPreviewDriver
{
    const string kMaterialPath = "Assets/Authoring/Venue/Unique/MatrixRain/Materials/M_MatrixRainTempoClock.mat";
    const string kDebugDtProperty = "_DebugDeltaTime";

    static double s_lastTime;
    static bool s_haveLastTime;

    static MatrixRainTempoClockPreviewDriver()
    {
        EditorApplication.update += OnEditorUpdate;
        EditorApplication.playModeStateChanged += OnPlayModeStateChanged;
    }

    static void OnPlayModeStateChanged(PlayModeStateChange change)
    {
        // Hand control back to the real unity_DeltaTime path the instant Play mode
        // starts (or ends), and never carry a stale delta across the transition.
        s_haveLastTime = false;
        SetDebugDeltaTime(0f);
    }

    static void OnEditorUpdate()
    {
        if (Application.isPlaying)
        {
            s_haveLastTime = false;
            return; // real gameplay path: let unity_DeltaTime.x drive the clock as designed
        }

        double now = EditorApplication.timeSinceStartup;
        if (!s_haveLastTime)
        {
            s_lastTime = now;
            s_haveLastTime = true;
            return; // first tick after (re)load: no delta to report yet
        }

        float dt = (float)(now - s_lastTime);
        s_lastTime = now;
        if (dt <= 0f) return;

        SetDebugDeltaTime(dt);
    }

    static void SetDebugDeltaTime(float dt)
    {
        var mat = AssetDatabase.LoadAssetAtPath<Material>(kMaterialPath);
        if (mat == null || !mat.HasProperty(kDebugDtProperty)) return;
        mat.SetFloat(kDebugDtProperty, dt); // in-memory only -- never SetDirty/Save here
    }
}
#endif
