// MatrixRainTempoClock.shader -- Custom Render Texture "update" shader.
//
// YARG does NOT publish a BPM / tempo float to venue shaders. What it DOES
// publish (TextureManager.UpdateGameState(), see gamestate.hlsl) is:
//   texel 0 = song length (s)         texel 1 = song position (s)
//   texel 5 = paused (0/1)            texel 7 = playback speed
//   texel 8 = beat phase, quarter-note (0..1, wraps every beat)
//   texel 9 = measure phase (0..1)
// so live tempo has to be RECOVERED from how fast texel 8 wraps.
//
// This 1x1 self-feedback texture does that and also integrates it into a
// monotonic "rain clock" (the same double-buffered CRT pattern as
// MatrixRainGoldMilestone.shader / MatrixRainSpectrumHold.shader -- a plain
// asset, so a .yarground can carry it; no runtime C# needed).
//
//   R = rainClock  seconds of "reference-tempo time". Advances at
//                  (bpm / _TempoReferenceBPM) x real time while a song is
//                  running, and at exactly 1x real time otherwise.
//   G = previous beat phase (used to measure the per-frame delta)
//   B = smoothed tempo scale (bpm / _TempoReferenceBPM); 0 == uninitialized
//   A = 0 when no live song, otherwise 1 + seconds the beat phase has been
//       stuck (used to detect charts with no beat data)
//
// WHY AN INTEGRATED CLOCK: the rain shader derives every stream position
// from an absolute clock. If tempo were simply multiplied into
// _Time.y * speed, every tempo change would rescale ALL of elapsed time and
// the entire rain field would snap/re-seed. Integrating the scale here means
// a tempo change only alters the *slope* of the clock, so motion stays
// perfectly continuous while speeding up or slowing down.
//
// Everything is smoothed and clamped, and when there is no live song
// (editor, menus, countdown, paused, no beat data) the scale relaxes to
// exactly 1.0, i.e. the shader's normal default fall rate.
Shader "Hidden/MatrixRain/TempoClock"
{
    Properties
    {
        // NOTE: _Yarg_GameStateTex is deliberately NOT a material property
        // (it is a GLOBAL set by TextureManager; a Properties entry would
        // shadow it with a black default). Declared in the CGPROGRAM below.

        _TempoReferenceBPM ("Reference BPM (rain runs at 1x speed at this tempo)", Range(40.0, 240.0)) = 120.0
        _TempoSmoothing    ("Tempo Smoothing Rate (1/sec, higher = snappier)", Range(0.5, 20.0)) = 3.0
        _MinTempoScale     ("Min Tempo Scale (slowest the rain may go)", Range(0.05, 1.0)) = 0.35
        _MaxTempoScale     ("Max Tempo Scale (fastest the rain may go)", Range(1.0, 6.0)) = 3.0
        // Authoring/test hook: when > 0, replaces unity_DeltaTime.x so the update can be
        // stepped deterministically from an editor script (unity_DeltaTime is 0 outside
        // play mode). MUST stay 0 on the shipped material.
        _DebugDeltaTime    ("Debug: fixed delta time override (0 = use real dt)", Float) = 0.0
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

            sampler2D _Yarg_GameStateTex;
            float _TempoReferenceBPM;
            float _TempoSmoothing;
            float _MinTempoScale;
            float _MaxTempoScale;
            float _DebugDeltaTime;

            // 16 texels wide, point filtered: texel i centre is at (i + 0.5) / 16.
            float ReadState(int i)
            {
                return tex2Dlod(_Yarg_GameStateTex, float4((i + 0.5) / 16.0, 0.5, 0.0, 0.0)).r;
            }

            float4 frag(v2f_customrendertexture IN) : COLOR
            {
                float4 prev = tex2D(_SelfTexture2D, IN.localTexcoord.xy);

                float dt = clamp((_DebugDeltaTime > 0.0) ? _DebugDeltaTime : unity_DeltaTime.x, 0.0, 0.1);
                if (dt <= 1e-5) return prev; // stalled / first update: hold state

                bool  initialized = prev.b > 0.0001;
                float scale       = initialized ? prev.b : 1.0;
                float clock       = prev.r;
                float prevPhase   = prev.g;
                bool  prevLive    = initialized && prev.a > 0.5;
                float stale       = prevLive ? max(prev.a - 1.0, 0.0) : 0.0;

                float songLength = ReadState(0);
                float songPos    = ReadState(1);
                float paused     = ReadState(5);
                float phase      = saturate(ReadState(8));

                // Real songs are far longer than 5 s, so an unbound texture
                // (black OR default-white) is never mistaken for a live song.
                bool live = (songLength > 5.0) && (songPos >= 0.0) && (paused < 0.5);

                float refBps = max(_TempoReferenceBPM, 1.0) / 60.0;
                float target = 1.0; // default: reference rate

                if (live && prevLive)
                {
                    // Beats advanced since last update, unwrapped against the
                    // beat count we EXPECT at the current tempo so a wrap
                    // (0.98 -> 0.03) reads as +0.05 rather than -0.95.
                    float expected = scale * refBps * dt;
                    float raw = phase - prevPhase;
                    float d = raw + round(expected - raw);
                    float tol = expected * 1.5 + 0.03;

                    stale = (abs(d) < 1e-4) ? (stale + dt) : 0.0;

                    if (stale > 0.5)
                    {
                        target = 1.0; // beat phase frozen on a live song: no usable beat data
                    }
                    else if (abs(d - expected) <= tol)
                    {
                        target = clamp(d / (refBps * dt), _MinTempoScale, _MaxTempoScale);
                    }
                    else
                    {
                        target = scale; // seek / discontinuity: keep the current tempo
                    }
                }
                else
                {
                    stale = 0.0;
                }

                float k = 1.0 - exp(-max(_TempoSmoothing, 0.01) * dt);
                scale = lerp(scale, target, k);
                clock += scale * dt;

                return float4(clock, phase, scale, live ? (1.0 + stale) : 0.0);
            }
            ENDCG
        }
    }
}
