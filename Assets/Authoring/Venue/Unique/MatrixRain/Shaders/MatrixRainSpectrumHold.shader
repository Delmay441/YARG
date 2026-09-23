// MatrixRainSpectrumHold.shader — Custom Render Texture "update" shader.
//
// v2: attack/release ENVELOPE FOLLOWER per lane, replacing the earlier
// "commit once per cycle" design. The old design directly blended a lane's
// visual length TOWARD the held spectrum value, which crushed length
// toward zero during quiet passages -- most of a song is quiet most of the
// time, so the rain read as sparse "waves" that dropped all at once and
// left the screen bare between beats. That's fixed two ways here:
//
//   1. This buffer's output (R channel, 0..1) is clamped to never fall
//      below _BaselineDrizzle -- a constant, randomized-by-lane floor that
//      is completely independent of audio. Total silence still produces
//      this floor.
//   2. MatrixRain.shader now ADDS this value on top of its own existing
//      hash-randomized trail length instead of blending toward it -- see
//      the _SpectrumInfluence comment there. Audio can only ever EXTEND a
//      lane's reach, never suppress the baseline "drizzle" cascade.
//
// The envelope itself is a simple, per-lane attack/release integrator: it
// grows while that lane's FFT band is above _NoiseThreshold (the
// "extruder" pushing the tail further down the longer a sound sustains),
// and decays smoothly back toward the baseline floor once the band drops
// below threshold (the "detach" -- MatrixRain.shader's existing logarithmic
// phosphor-fade-to-zero handles the actual visual fade-out once a row falls
// outside the now-shorter reactive window; this shader only shapes how
// large that window currently is, and only ever changes it gradually,
// frame to frame, so that boundary never jumps abruptly).
//
// Same reasoning as v1 for why this is a genuine Unity asset (a
// double-buffered Custom Render Texture) rather than a runtime
// MonoBehaviour: a .yarground AssetBundle can only load plain Unity
// assets, not arbitrary C# components. Written with the standard CGPROGRAM
// Custom Render Texture pattern (Unity Manual: Custom Render Textures)
// rather than MatrixRain.shader's URP HLSLPROGRAM style -- Custom Render
// Texture updates are handled by Unity's engine-level CRT system
// independent of which SRP is active, and this CG-style include/entry-
// point pair is the documented, version-stable way to write one.
Shader "Hidden/MatrixRain/SpectrumHold"
{
    Properties
    {
        // Auto-populated at runtime by YARG's TextureManager.ProcessMaterial()
        // -- see the discovery-proxy renderer comment in the venue scene for
        // why this Material needs to sit on a real Renderer to be found by
        // that scan. Row 0 (v=0) is FFT magnitude, 512 texels wide, linear
        // frequency bins from DC up to roughly a quarter of Nyquist.
        _Yarg_SoundTex ("YARG Sound Texture (set automatically by the game)", 2D) = "black" {}

        // How much of the low end of _Yarg_SoundTex's 512-wide FFT row gets
        // spread across this buffer's lanes. 0.6 covers bass through mid,
        // matching the "spectrum analyzer" brief without reaching into the
        // near-silent top of the FFT row.
        _SpectrumBandRange ("Spectrum Band Range (fraction of FFT row)", Range(0.05, 1.0)) = 0.6

        // A lane's band must exceed this (0..1, same normalized scale as the
        // FFT texture) before it counts as "sound present" and starts
        // growing (the Attack). Below it, the lane releases back down.
        _NoiseThreshold ("Noise Threshold (extrude above this)", Range(0.0, 1.0)) = 0.12

        // Attack: how fast a triggered lane's envelope grows per second of
        // sustained sound, scaled further by that instant's own amplitude
        // (so a loud sustained note extrudes faster than a quiet one right
        // at the threshold). This is the "Extruder" -- a long guitar chord
        // keeps pushing the value up for as long as it holds; a short
        // staccato hit barely grows before Release takes back over.
        _ExtrudeRate ("Extrude Rate (growth / sec while triggered)", Range(0.05, 3.0)) = 0.6

        // Release: how fast an untriggered lane's envelope decays per
        // second, back down toward (never below) _BaselineDrizzle. Kept
        // deliberately gradual rather than snapping to the floor instantly
        // -- MatrixRain.shader's reactive window shrinks exactly as fast as
        // this value falls, and a large frame-to-frame jump there is what
        // used to read as an abrupt pop instead of a fade.
        _ReleaseRate ("Release Rate (decay / sec once below threshold)", Range(0.05, 3.0)) = 0.25

        // The constant, audio-independent floor every lane's envelope is
        // clamped to. This is Task 1's "Baseline Drizzle": even in total
        // silence, every lane still reports at least this much, so
        // MatrixRain.shader's existing hash-randomized trail length is
        // never crushed toward zero and the screen is never bare.
        _BaselineDrizzle ("Baseline Drizzle Floor (audio-independent)", Range(0.0, 1.0)) = 0.18
    }

    SubShader
    {
        Lighting Off
        Blend One Zero

        Pass
        {
            CGPROGRAM
            #include "UnityCustomRenderTexture.cginc"
            #pragma vertex CustomRenderTextureVertexShader
            #pragma fragment frag
            #pragma target 3.0

            sampler2D _Yarg_SoundTex;
            float     _SpectrumBandRange;
            float     _NoiseThreshold;
            float     _ExtrudeRate;
            float     _ReleaseRate;
            float     _BaselineDrizzle;
            sampler2D _SelfTexture2D; // previous update's own output (double-buffered)

            float4 frag(v2f_customrendertexture IN) : COLOR
            {
                float width = max(_CustomRenderTextureWidth, 1.0);
                float laneX = IN.localTexcoord.x * width;

                float bandU   = saturate(((laneX + 0.5) / width) * saturate(_SpectrumBandRange));
                float liveAmp = tex2D(_Yarg_SoundTex, float2(bandU, 0.0)).r;

                float prevEnvelope = tex2D(_SelfTexture2D, IN.localTexcoord.xy).r;

                // unity_DeltaTime.x is Unity's standard per-frame delta time,
                // globally bound regardless of render pipeline. Clamped to
                // guard against a stalled/zero first update and against huge
                // jumps on a lag spike (which would otherwise let one slow
                // frame snap the envelope instead of gliding it).
                float dt = clamp(unity_DeltaTime.x, 0.0, 0.1);

                bool triggered = liveAmp > saturate(_NoiseThreshold);

                float envelope = prevEnvelope;
                if (triggered)
                {
                    // Attack -- amplitude-scaled growth, this is the "extruder"
                    // pushing the tail further down for as long as the sound holds.
                    envelope += liveAmp * max(_ExtrudeRate, 0.0) * dt;
                }
                else
                {
                    // Release -- gradual decay, never below the baseline floor.
                    envelope -= max(_ReleaseRate, 0.0) * dt;
                }
                envelope = clamp(envelope, saturate(_BaselineDrizzle), 1.0);

                // G/B channels reserved/unused (kept around from the buffer's
                // previous single-shot design; harmless to leave at 0).
                return float4(envelope, 0.0, 0.0, 1.0);
            }
            ENDCG
        }
    }
}
