// MatrixRainGoldMilestone.shader — Custom Render Texture "update" shader.
//
// Tracks a single scalar: how "gold" the background should currently be.
// Reads texel 15 of _Yarg_GameStateTex (stars earned, 0.0-6.0 incl.
// fractional progress -- see gamestate.hlsl's texel table) and drives a
// self-feedback envelope toward 1.0 once the band reaches 6 (gold) stars,
// toward 0.0 otherwise.
//
// The envelope update is an exponential approach to the target
// (blend += (target - blend) * (1 - exp(-rate * dt))) rather than a linear
// ramp or an instant snap: this closes most of the remaining gap almost
// immediately (a high _GoldRiseRate), then eases the last stretch in more
// gradually -- the continuous-time curve whose closed form is logarithmic
// in time-to-reach-a-given-fraction, matching a "shift should be
// logarithmic but happen nearly immediately" brief.
//
// Same reasoning as MatrixRainSpectrumHold.shader for why this is a genuine
// Unity asset (a double-buffered Custom Render Texture) rather than a
// runtime MonoBehaviour: a .yarground AssetBundle can only load plain Unity
// assets, not arbitrary C# components. Written with the standard CGPROGRAM
// Custom Render Texture pattern for the same version-stability reason.
//
// NOTE: _SelfTexture2D (the previous update's own output) is already
// declared by UnityCustomRenderTexture.cginc below -- do NOT redeclare it.
// (MatrixRainSpectrumHold.shader has a pre-existing, unrelated bug where it
// does redeclare it; that has been left alone rather than silently touched
// here, per an earlier explicit "leave that alone for now".)
Shader "Hidden/MatrixRain/GoldMilestone"
{
    Properties
    {
        // Auto-populated at runtime by YARG's TextureManager.ProcessMaterial()
        // -- this Material must sit on a real Renderer somewhere under the
        // venue's Stage hierarchy to be found by that scan (see
        // _MatrixRainSpectrumHoldProxy for the established pattern; this
        // shares that same proxy object rather than needing a second one).
        _Yarg_GameStateTex ("YARG Game State Texture (set automatically by the game)", 2D) = "black" {}

        // How fast the envelope closes the gap toward its target once the
        // 6-star threshold is crossed (or un-crossed). Higher = more sudden.
        _GoldRiseRate ("Gold Rise Rate (higher = faster, more sudden onset)", Range(1.0, 50.0)) = 18.0
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
            float     _GoldRiseRate;

            float4 frag(v2f_customrendertexture IN) : COLOR
            {
                // Texel 15 (see gamestate.hlsl): stars earned, 0.0-6.0
                // including fractional progress into the next star.
                // 16 texels wide -> texel 15's center is at u = 15.5/16.
                float stars = tex2D(_Yarg_GameStateTex, float2(15.5 / 16.0, 0.0)).r;
                float target = (stars >= 5.999) ? 1.0 : 0.0;

                float prevBlend = tex2D(_SelfTexture2D, IN.localTexcoord.xy).r;

                // unity_DeltaTime.x is Unity's standard per-frame delta time,
                // globally bound regardless of render pipeline. Clamped to
                // guard against a stalled/zero first update and against huge
                // jumps on a lag spike.
                float dt = clamp(unity_DeltaTime.x, 0.0, 0.1);

                float k = 1.0 - exp(-max(_GoldRiseRate, 0.01) * dt);
                float blend = lerp(prevBlend, target, k);

                // G/B/A unused, kept at 0/1 for clarity.
                return float4(blend, 0.0, 0.0, 1.0);
            }
            ENDCG
        }
    }
}
