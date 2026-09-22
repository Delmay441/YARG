Shader "Custom/MatrixRain"
{
    Properties
    {
        [Header(Glyph Atlas)]
        [NoScaleOffset] _FontAtlas ("Glyph Atlas (White on Black)", 2D) = "black" {}
        _AtlasGridSize ("Atlas Grid (Cols, Rows)", Vector) = (16, 16, 0, 0)

        [Header(Colors)]
        _HeadColor       ("Head Color (leading glyph)", Color) = (1, 1, 1, 1)
        _TrailColor      ("Trail Tint Color", Color) = (0.05, 0.85, 0.25, 1)
        _BackgroundColor ("Background Color", Color) = (0, 0, 0, 1)

        [Header(Grid And Scale)]
        _GlyphScale  ("Glyph Scale", Range(0.1, 4.0)) = 1.0
        _BaseColumns ("Reference Column Count @ Scale 1.0", Float) = 40
        _AspectRatio ("Grid Aspect Ratio (Width / Height)", Float) = 1.7778

        [Header(Rain Motion)]
        _RainSpeed       ("Rain Speed", Range(0.0, 1.0)) = 0.35
        _Density         ("Column Density (visual fullness)", Range(0.0, 1.0)) = 0.9
        _TrailLength     ("Trail Length", Range(0.05, 1.0)) = 0.35
        _LengthBias      ("Trail Length Variance Bias", Range(0.0, 1.0)) = 0.25
        _MutationRate    ("Glyph Mutation Rate", Range(0.0, 1.0)) = 0.10
        _ColumnGapChance ("Blank-Cell Chance", Range(0.0, 0.5)) = 0.05

        [Header(Cell Spacing)]
        // Real-time configurable spacing between cells. Positive values carve
        // a symmetric margin out of each cell (glyph shrinks toward the
        // center, blank border grows). Negative values invert this: the
        // step-based boundsMask below stops clipping anything the moment the
        // margin goes negative (its two step() thresholds both fall outside
        // the valid cellU/cellV range), and the innerUV rescale instead maps
        // each cell's full footprint across a NARROWER slice of the glyph's
        // own UV span -- so the glyph reads as magnified and its strokes
        // bleed past the cell boundary into its neighbors, i.e. cells pack
        // closer together / overlap. See EvaluateCell() below.
        _CellGapX ("Cell Gap X (negative = overlap/pack)", Range(-0.5, 0.45)) = 0.0
        _CellGapY ("Cell Gap Y (negative = overlap/pack)", Range(-0.5, 0.45)) = 0.0

        [Header(Glow)]
        // Embedded glow -- previously a separate ScriptableRendererFeature
        // (MatrixReflowBloomFeature.cs + Hidden/MatrixReflow/Bloom.shader), now
        // folded directly into this single pass since a .yarground AssetBundle
        // cannot load a custom C# URP renderer feature at runtime. See the
        // EvaluateCell()/glow-tap comments in the fragment shader below.
        _GlowIntensity ("Glow Intensity", Range(0.0, 2.0)) = 0.9
        _GlowRadius    ("Glow Radius (UV units)", Range(0.001, 0.05)) = 0.01
        _GlowThreshold ("Glow Luminance Threshold", Range(0.0, 1.0)) = 0.55

        [Header(YARG Audio Reactivity)]
        // YARG does NOT broadcast a BPM/tempo float to venue shaders -- the only
        // song-sync hook exposed to materials is _Yarg_SoundTex, a 512x2 R8
        // texture (row 0 = smoothed FFT magnitude, row 1 = waveform) that
        // TextureManager.ProcessMaterial() assigns automatically to any venue
        // material that declares a texture property with this exact name
        // (see YARG__venue_creation_wiki.txt and Assets/Art/Shaders/
        // LavaMetaballs.shader, which uses the same texture + tap-averaging
        // pattern this shader mirrors below).
        //
        // IMPORTANT: downward fall speed is 100% constant and audio-independent
        // by design -- baseFall/period/rawLoops/g/genFrac/speedVar in
        // EvaluateCell() never read audioNorm. Every OTHER effect below (glow,
        // mutation rate, trail length, gap relief, head color) still reacts to
        // the beat. A previous revision let an _AudioReactivity slider nudge
        // speedVar slightly; that slider and its logic have been removed
        // entirely per an explicit decouple request, not just zeroed out.
        [NoScaleOffset] _Yarg_SoundTex ("YARG Sound Texture (set automatically by the game)", 2D) = "black" {}
        _AudioFloor      ("Audio Energy Floor (below = no effect)", Range(0.0, 1.0)) = 0.05
        _AudioCeiling    ("Audio Energy Ceiling (at/above = max effect)", Range(0.0, 1.0)) = 0.5

        // "Power Spikes": bass peaks (global OR this lane's own live peak,
        // whichever is stronger) flare the leading glyph + its glow
        // brighter/whiter, then decay smoothly back down. The decay comes
        // for free from _Yarg_SoundTex's own source-side smoothing filter
        // (see SampleAudioEnergy() below) -- no extra per-pixel history is
        // kept here. CRITICAL: neither of these touches any _Time.y-based
        // translation math, only color/intensity, so fall speed never stutters.
        _AudioGlowBoost ("Audio Glow Boost (Power Spikes)", Range(0.0, 3.0)) = 1.2
        _AudioHeadBoost ("Audio Head Overdrive Boost", Range(0.0, 3.0)) = 1.0
        _OverdriveColor ("Head Overdrive Flare Color", Color) = (0.85, 1.0, 0.55, 1)

        // "Data Processing Load": scales the LOCAL mutation rate so active
        // glyphs scramble faster/more often across the currently lit streams.
        // Driven by whichever is stronger: overall RMS loudness
        // (SampleWaveformRMS() below) or this lane's own live FFT amplitude --
        // see the localMutRate comment in EvaluateCell() for why this is safe
        // to scale directly by elapsed time (unlike fall speed) without
        // causing a visible snap.
        _AudioMutationBoost ("Audio Mutation Boost (Data Processing Load)", Range(0.0, 4.0)) = 2.5

        // "Code Overflow": bass peaks temporarily extend how far each active
        // trail reaches and relax the blank-cell chance, so dormant columns
        // light up and the screen fills with code during heavy sections.
        _AudioTrailSwell ("Audio Trail Swell (Code Overflow)", Range(0.0, 1.0)) = 0.4
        _AudioGapRelief  ("Audio Gap Relief (light up dormant columns)", Range(0.0, 1.0)) = 0.6

        // Normalization range for SampleWaveformRMS() below, feeding
        // _AudioMutationBoost above. Kept separate from _AudioFloor/
        // _AudioCeiling since RMS of the raw waveform has a different natural
        // range than the dB-mapped FFT magnitude those two normalize.
        _RMSFloor   ("RMS Loudness Floor (below = no effect)", Range(0.0, 1.0)) = 0.04
        _RMSCeiling ("RMS Loudness Ceiling (at/above = max effect)", Range(0.0, 1.0)) = 0.4

        [Header(YARG Signal Corruption Burst)]
        // ---- Audio-Reactive "Signal Corruption" Burst ------------------------
        // Discrete, all-rows-at-once hard glyph reroll gated by a beat hit --
        // see the burst comment inside EvaluateCell() below. Distinct from
        // _AudioMutationBoost above: that continuously scrambles individual
        // cells at their own pace; this snaps an entire lane to a fresh,
        // correlated reroll all at once, all rows simultaneously, then holds
        // until the next window -- reads as a percussive "corrupted column"
        // flash rather than a smooth churn. Triggers on EITHER an audio-energy
        // threshold OR genuine tempo (measure downbeat proximity) below, so
        // it reads as tempo-locked rather than purely FFT-threshold-driven.
        _AudioBurstThreshold ("Audio Burst Threshold (glitch trigger)", Range(0.0, 1.0)) = 0.55
        _AudioBurstChance    ("Audio Burst Chance (lane participation)", Range(0.0, 1.0)) = 0.4
        _AudioBurstRate      ("Audio Burst Rate (windows / sec)", Range(1.0, 30.0)) = 10.0
        _MeasureBurstWindow  ("Measure Downbeat Burst Window (fraction of measure after downbeat)", Range(0.0, 0.5)) = 0.08

        [Header(YARG Beat Synced Head Flare)]
        // A guaranteed, tempo-locked flash on the leading glyph right after
        // each beat (from YargGameStateBeatPhase()), layered additively on
        // top of the existing audio-peak head overdrive -- see beatPulse in
        // frag() and its use in EvaluateCell()'s headOverdrive calc.
        _BeatPulseIntensity ("Beat Pulse Intensity (head flare)", Range(0.0, 2.0)) = 0.5
        _BeatPulseWindow     ("Beat Pulse Window (fraction of beat interval)", Range(0.01, 0.5)) = 0.15

        [Header(YARG Inverse Spectrum Analyzer)]
        // _SpectrumHoldTex is CRT_MatrixSpectrumHold.asset (a Custom Render
        // Texture, not a runtime script -- see MatrixRainSpectrumHold.shader
        // for why): a small per-lane ATTACK/RELEASE ENVELOPE (0..1), not a
        // one-shot snapshot -- it grows continuously while that lane's FFT
        // band stays above a noise floor (the "Extruder": a sustained chord
        // keeps pushing it up, a short staccato hit barely grows before
        // Release takes back over) and decays gradually once the band drops
        // back down, but NEVER below a constant, audio-independent baseline
        // floor (the "Drizzle" -- see MatrixRainSpectrumHold.shader's
        // _BaselineDrizzle). EvaluateCell() below ADDS this on top of the
        // existing hash-randomized trail-length variance via
        // _SpectrumInfluence -- deliberately additive, not a blend-toward:
        // blending toward the held value used to crush a lane's length
        // toward zero during quiet passages (most of a song, most of the
        // time), which is what made the rain read as sparse "waves" that
        // dropped all at once instead of a constant cascade. Adding on top
        // means audio can only ever EXTEND a lane's reach, never suppress
        // the baseline cascade -- and it's never applied against
        // col/cellU/finalPx, so lanes stay perfectly vertical and are never
        // offset or deformed by audio, only lengthened.
        [NoScaleOffset] _SpectrumHoldTex ("Spectrum Hold Buffer (per-lane length envelope)", 2D) = "black" {}
        _SpectrumInfluence ("Spectrum Influence (extra length added on top of the random baseline)", Range(0.0, 1.0)) = 0.7

        [Header(YARG Song Progress Growth)]
        // Slow macro-scale growth as the song advances (YargGameStateSongProgress()):
        // both are ADDED on top of the existing sliders above (same additive
        // discipline as the audio effects), so at songProgress == 0 the look is
        // exactly the previously-verified baseline and it only ever grows toward
        // the end of a song, never shrinks below the manual slider values.
        _ProgressTrailGrowth    ("Progress Trail Growth (added to Trail Length by song end)", Range(0.0, 1.0)) = 0.3
        _ProgressSpectrumGrowth ("Progress Spectrum Growth (added to Spectrum Influence by song end)", Range(0.0, 1.0)) = 0.3

        [Header(YARG Star Power Charge Pulse)]
        // A subtle heartbeat pulse on the overall glow once Star Power is
        // fully charged but not yet activated (YargGameStateStarPowerCharge()),
        // so the background visibly "wants" to be popped. Multiplicative on
        // top of the existing glow boost -- see effectiveGlowIntensity in frag().
        _ChargePulseIntensity ("Charge-Ready Pulse Intensity", Range(0.0, 2.0)) = 0.6
        _ChargePulseSpeed     ("Charge-Ready Pulse Speed", Range(0.5, 6.0)) = 2.5

        [Header(YARG Gold Milestone (6 Stars))]
        // Once the band reaches 6 (gold) stars, the whole background shifts
        // from its normal color to a radiant gold with a steady shimmer.
        // _GoldMilestoneTex is a 1x1 Custom Render Texture feedback buffer
        // (CRT_MatrixGoldMilestone.asset / MatrixRainGoldMilestone.shader,
        // same self-feedback pattern as _SpectrumHoldTex) holding a single
        // 0..1 envelope that rises toward 1 the moment 6 stars is reached and
        // falls back to 0 otherwise, via an exponential approach to target --
        // most of the shift happens almost immediately, with the last bit
        // easing in a little more gradually (logarithmic time-to-target).
        // Takes priority over the fail-state alarm tint (applied after it in
        // EvaluateCell()), since hitting 6 stars and being in the fail zone
        // are mutually exclusive in practice and this is the "hero" moment.
        [NoScaleOffset] _GoldMilestoneTex ("Gold Milestone Envelope (set automatically, 1x1 CRT feedback buffer)", 2D) = "black" {}
        _GoldColor ("Radiant Gold Color", Color) = (1.2, 0.92, 0.25, 1)
        _GoldShimmerIntensity ("Gold Shimmer Intensity (color breathing + glow radiance boost)", Range(0.0, 2.0)) = 0.5
        _GoldShimmerSpeed ("Gold Shimmer Speed", Range(0.1, 5.0)) = 1.5

        // ---- CRT emulation (ported from MatrixReflow's windows/shaders.hlsl:
        // BarrelDistort() + crt_filter()) -- applied directly to this quad's own
        // UVs rather than as a screen-space post effect, since a .yarground can't
        // carry a custom URP renderer feature. Scanline/slot-mask defaults are
        // intentionally NOT zero -- per an explicit "make the CRT grid heavy and
        // dramatic by default, not a subtle overlay" request, those two ship
        // pre-dialed-in. Every other CRT slider here still defaults to 0 (opt-in),
        // matching the rest of this section. ------------------------------------
        [Header(CRT Emulation)]
        _BarrelDistortion ("Barrel Distortion (static baseline)", Range(0.0, 0.5)) = 0.0
        _CRTChromaticAberration ("CRT Chromatic Aberration (radial)", Range(0.0, 0.1)) = 0.0
        _CRTConvergenceFringing ("CRT Convergence Fringing (edge-weighted)", Range(0.0, 0.05)) = 0.0
        _CRTPhosphorBleed ("CRT Phosphor Bleed", Range(0.0, 1.0)) = 0.0
        _CRTSlotMaskIntensity ("CRT Slot Mask Intensity", Range(0.0, 1.0)) = 0.55
        _CRTScanlineIntensity ("CRT Scanline Intensity", Range(0.0, 1.0)) = 0.65
        _CRTVignetteIntensity ("CRT Vignette Intensity", Range(0.0, 1.0)) = 0.0
        _BlackLevelLift ("CRT Black Level Lift", Range(0.0, 0.3)) = 0.0

        [Header(Glyph Rotation)]
        // ---- Locked 90-degree glyph rotation ---------------------------------------
        // Chance that a given glyph, on mutation, lands in a rotated (90/180/270-
        // degree) orientation instead of upright. 0 = never rotate (matches previous
        // behavior exactly). Additionally boosted as the fail meter drops -- see
        // _FailRotationBoost below.
        _RotationChance ("Glyph Rotation Chance (baseline)", Range(0.0, 1.0)) = 0.0

        [Header(YARG Gameplay State)]
        // Auto-assigned by TextureManager.ProcessMaterial() the same way
        // _Yarg_SoundTex is -- a small, fixed-size, append-only texture of raw
        // gameplay values (fail meter, song progress, beat/measure phase, star
        // power charge, etc). Sampled with Load() (exact texel, no filtering)
        // since it's a handful of discrete values, not an image. See
        // YargFailMeter()/YargSongProgress()/YargBeatPhase()/YargMeasurePhase()/
        // YargStarPowerCharge() below for the texel layout this shader reads.
        [NoScaleOffset] _Yarg_GameStateTex ("YARG Game State Texture (set automatically by the game)", 2D) = "black" {}

        [Header(Editor Preview Fail Meter Override)]
        // Authoring aid only. Outside an actual running song,
        // _Yarg_GameStateTex sits at its declared default (a black texture),
        // so YargFailMeter() reads as a flat 0 (worst case) with nothing to
        // preview against. Flip this toggle on to substitute a hand-set value
        // instead, so the fail-state ramp (desync, alarm palette, rotation/
        // mutation boost, barrel distortion) can be dialed through by hand in
        // the Inspector/preview window. MUST be left OFF on whatever material
        // actually ships in the venue -- with it off, this has zero effect and
        // the real gameplay fail meter is used exactly as before.
        [Toggle] _UseEditorPreviewFailMeter ("Use Editor Preview Fail Meter (author-time only)", Float) = 0
        _EditorPreviewFailMeter ("Editor Preview Fail Meter (0 = failed, 1 = full health)", Range(0.0, 1.0)) = 1.0

        [Header(YARG Fail State Desync)]
        // ---- Audio-INDEPENDENT signal desync, driven purely by the fail meter --
        // (YargGameStateFailMeter(), 1.0 = full health, 0.0 = failed). Desync
        // begins the moment the fail meter starts dropping below 1.0 and ramps
        // continuously and non-linearly (see _FailGlitchCurve) toward maximum
        // severity as it approaches 0 -- there is no dead zone/gate before it
        // starts, and it has NO dependency on _Yarg_SoundTex/audioNorm at all
        // (previously this system reused the same wave-wobble/tear-burst code
        // as the audio-reactive glitch; it has been fully detached and re-keyed
        // to failDriveShaped instead -- see ApplyAnalogGlitch() below).
        _FailGlitchThreshold ("Fail Glitch Onset - Rock Meter Red Zone (fail-meter fraction; matches the in-game meter's own red cutoff)", Range(0.0, 1.0)) = 0.333
        _FailGlitchCurve ("Fail Desync Ramp Curve (higher = more sudden near death)", Range(0.1, 4.0)) = 2.0
        _GlitchWaveAmount    ("Glitch Wave Amount (UV units, at full fail)", Range(0.0, 0.05)) = 0.004
        _GlitchWaveFrequency ("Glitch Wave Frequency", Range(1.0, 60.0)) = 18.0
        _GlitchWaveSpeed     ("Glitch Wave Speed", Range(0.0, 10.0)) = 1.2
        _GlitchFailBoost     ("Glitch Fail Boost (wave amount multiplier)", Range(0.0, 20.0)) = 6.0
        _GlitchTearThreshold ("Glitch Tear Onset (fail-drive fraction before tears begin)", Range(0.0, 1.0)) = 0.5
        _GlitchTearAmount    ("Glitch Tear Amount (UV units, at full fail)", Range(0.0, 0.2)) = 0.05
        _GlitchTearRate      ("Glitch Tear Rate (windows / sec)", Range(1.0, 30.0)) = 6.0
        _GlitchFlashColor    ("Glitch Flash Color (tear leading edge)", Color) = (0.8, 1.0, 0.95, 1)
        _GlitchFlashAmount   ("Glitch Flash Amount (leading-edge brightness)", Range(0.0, 3.0)) = 1.2
        _FailBarrelDistortion ("Fail Barrel Distortion (added on top of the static baseline, at full fail)", Range(0.0, 0.5)) = 0.15

        _FailAlarmColor      ("Fail Alarm Color (trail/head tint near death)", Color) = (1.0, 0.22, 0.05, 1)
        _FailPaletteThreshold ("Fail Palette Onset (fail-drive fraction before tinting begins)", Range(0.0, 1.0)) = 0.7
        _FailRotationBoost   ("Fail Rotation Boost (added to Rotation Chance at full fail)", Range(0.0, 1.0)) = 0.8
        _FailMutationBoost   ("Fail Mutation Boost (scramble multiplier at full fail)", Range(0.0, 8.0)) = 3.0

    }

    SubShader
    {
        Tags { "RenderType" = "Opaque" "RenderPipeline" = "UniversalPipeline" "Queue" = "Geometry" }
        Cull Off
        ZWrite On
        ZTest LEqual
        Blend Off

        Pass
        {
            Name "MatrixRainForward"
            Tags { "LightMode" = "UniversalForward" }

            HLSLPROGRAM
            #pragma vertex vert
            #pragma fragment frag
            #pragma target 3.0

            #include "Packages/com.unity.render-pipelines.universal/ShaderLibrary/Core.hlsl"

            struct Attributes
            {
                float4 positionOS : POSITION;
                float2 uv         : TEXCOORD0;
            };

            struct Varyings
            {
                float4 positionCS : SV_POSITION;
                float2 uv         : TEXCOORD0;
            };

            TEXTURE2D(_FontAtlas);
            SAMPLER(sampler_FontAtlas);

            // No SAMPLER(sampler_Yarg_SoundTex) declared -- sampler_LinearClamp
            // is URP's shared implicit sampler (already pulled in via Core.hlsl)
            // and is the exact sampler LavaMetaballs.shader uses for the same
            // texture, so this reuses it rather than declaring a duplicate.
            TEXTURE2D(_Yarg_SoundTex);

            // The per-lane spectrum-hold buffer (see the property comment
            // above). Gets its own sampler since it's a small, dedicated
            // Custom Render Texture rather than something we want implicitly
            // sharing sampler state with _Yarg_SoundTex.
            TEXTURE2D(_SpectrumHoldTex);
            SAMPLER(sampler_SpectrumHoldTex);

            // YARG's gameplay-state texture -- a handful of discrete texels,
            // read with an exact Load() (no filtering/sampler needed at all).
            TEXTURE2D(_Yarg_GameStateTex);

            // The 1x1 gold-milestone envelope buffer (see the property comment
            // above). Own dedicated sampler, same reasoning as _SpectrumHoldTex.
            TEXTURE2D(_GoldMilestoneTex);
            SAMPLER(sampler_GoldMilestoneTex);

            CBUFFER_START(UnityPerMaterial)
                float4 _AtlasGridSize;
                float4 _TrailColor;
                float4 _HeadColor;
                float4 _BackgroundColor;
                float  _GlyphScale;
                float  _BaseColumns;
                float  _AspectRatio;
                float  _RainSpeed;
                float  _Density;
                float  _TrailLength;
                float  _LengthBias;
                float  _MutationRate;
                float  _ColumnGapChance;
                float  _CellGapX;
                float  _CellGapY;
                float  _GlowIntensity;
                float  _GlowRadius;
                float  _GlowThreshold;
                float  _AudioFloor;
                float  _AudioCeiling;
                float  _AudioGlowBoost;
                float  _AudioHeadBoost;
                float4 _OverdriveColor;
                float  _AudioMutationBoost;
                float  _AudioTrailSwell;
                float  _AudioGapRelief;
                float  _SpectrumInfluence;
                float  _RMSFloor;
                float  _RMSCeiling;
                float  _BarrelDistortion;
                float  _CRTScanlineIntensity;
                float  _CRTVignetteIntensity;
                float  _CRTChromaticAberration;
                float  _CRTConvergenceFringing;
                float  _CRTPhosphorBleed;
                float  _CRTSlotMaskIntensity;
                float  _BlackLevelLift;
                float  _RotationChance;
                float  _AudioBurstThreshold;
                float  _AudioBurstChance;
                float  _AudioBurstRate;
                float  _MeasureBurstWindow;
                float  _BeatPulseIntensity;
                float  _BeatPulseWindow;
                float  _ProgressTrailGrowth;
                float  _ProgressSpectrumGrowth;
                float  _ChargePulseIntensity;
                float  _ChargePulseSpeed;
                float4 _GoldColor;
                float  _GoldShimmerIntensity;
                float  _GoldShimmerSpeed;
                float  _UseEditorPreviewFailMeter;
                float  _EditorPreviewFailMeter;
                float  _FailGlitchThreshold;
                float  _FailGlitchCurve;
                float  _GlitchWaveAmount;
                float  _GlitchWaveFrequency;
                float  _GlitchWaveSpeed;
                float  _GlitchFailBoost;
                float  _GlitchTearThreshold;
                float  _GlitchTearAmount;
                float  _GlitchTearRate;
                float4 _GlitchFlashColor;
                float  _GlitchFlashAmount;
                float  _FailBarrelDistortion;
                float4 _FailAlarmColor;
                float  _FailPaletteThreshold;
                float  _FailRotationBoost;
                float  _FailMutationBoost;
            CBUFFER_END

            // ---- tiny deterministic GPU hash ----
            float hash11(float p)
            {
                p = frac(p * 0.1031);
                p *= p + 33.33;
                p *= p + p;
                return frac(p);
            }

            // Ported from MatrixReflow's BarrelDistort() (windows/shaders.hlsl,
            // bloom_composite): warps uv around the screen/quad center. amount > 0
            // bows the image outward, strongest at the edges, ~0 at the center.
            float2 BarrelDistort(float2 uv, float amount)
            {
                float2 c = uv - 0.5;
                float r2 = dot(c, c);
                float2 warped = c * (1.0 + amount * r2);
                return warped + 0.5;
            }

            // Analytically-anti-aliased step(): a fwidth()-widened smoothstep that
            // replaces hard step() edges (cell-gap bounds masking, slot-mask triad
            // boundaries) with a transition sized to the screen-space derivative of
            // `value` at this pixel, so edges anti-alias correctly regardless of how
            // much screen space one UV/pixel unit covers (camera distance, mesh
            // scale, etc.) instead of shimmering/moire-ing under motion.
            float aastep(float threshold, float value)
            {
                float afwidth = max(fwidth(value) * 0.5, 1e-5);
                return smoothstep(threshold - afwidth, threshold + afwidth, value);
            }

            // ---- YARG gameplay-state accessors --------------------------------
            // _Yarg_GameStateTex is a small, fixed-layout, append-only texture
            // (see gamestate.hlsl's texel table); we only need a handful of the
            // sixteen texels for Stage 1, so only those get named accessors here
            // rather than pulling in the whole file's unused wrappers. Indices
            // match gamestate.hlsl exactly so this stays correct if that file is
            // later added to the project and these are swapped to #include it.
            float YargGameState(int index)
            {
                return _Yarg_GameStateTex.Load(int3(index, 0, 0)).x;
            }
            float YargFailMeter()
            {
                // Host's EngineManager.Happiness (texel 2), ranges -3.0..1.0, not 0..1.
                // Actual failure triggers below 0.0, well inside that range. Since this
                // venue ships as a standalone .yarground bundle, this shader is the only
                // place we can remap it -- the raw -3..1 value is what any host sends.
                const float HAPPINESS_MIN = -3.0;
                const float HAPPINESS_MAX = 1.0;
                float raw = YargGameState(2);
                return saturate((raw - HAPPINESS_MIN) / (HAPPINESS_MAX - HAPPINESS_MIN));
            }
            float YargSongProgress()    { return YargGameState(3); }
            float YargBeatPhase()       { return YargGameState(8); }
            float YargMeasurePhase()    { return YargGameState(9); }
            float YargStarPowerCharge() { return YargGameState(11); }
            float YargStars()           { return YargGameState(15); }

            // Per-pixel gameplay-state inputs, decoded ONCE in frag() (same
            // discipline as audioNorm/SampleAudioEnergy() below) and threaded
            // into EvaluateCell() as a single struct rather than growing its
            // parameter list one feature at a time.
            struct GameplayInputs
            {
                float failDrive;        // 0 = full health, 1 = about to fail (linear)
                float failDriveShaped;  // pow(failDrive, _FailGlitchCurve) -- eases in, ramps hard near failure
                float failPaletteBlend; // 0..1 blend of _TrailColor/_HeadColor toward _FailAlarmColor
                float songProgress;     // 0..1
                float measurePhase;     // 0..1, position within the current measure
                float beatPulse;        // 0..1, spikes right after each beat then decays out
                float goldBlend;        // 0..1, eased envelope toward the 6-star gold shift
            };

            // Audio-INDEPENDENT signal desync: a slow, always-agitated wave
            // wobble plus a discrete tear burst, both driven purely by
            // failDriveShaped (0 at full health, ramping toward 1 as the fail
            // meter empties -- see _FailGlitchCurve). Starts the instant the
            // fail meter begins dropping below 1.0 (no gate/dead-zone) and
            // grows continuously more dramatic from there; has NO dependency
            // on _Yarg_SoundTex or any audio signal whatsoever. Applied to the
            // SAME uvBase BarrelDistort() produces, and reused everywhere
            // uvBase already is (center cell, all CA/phosphor-bleed taps,
            // every glow tap) -- so the whole rain field warps/tears together
            // as one coherent signal.
            //
            // This only ever perturbs the SAMPLING uv -- the same category as
            // BarrelDistort's own warp -- never _Time.y/baseFall/rawLoops/g/
            // genFrac inside EvaluateCell(), so the rain's own fall-speed
            // timing stays exactly as fail-state-independent as everywhere
            // else in this shader; only WHICH pixel samples which cell moves.
            //
            // `flashOut` returns the leading-edge brightness kick (0 when no
            // tear is active at this pixel) for frag() to blend
            // _GlitchFlashColor in with.
            float2 ApplyAnalogGlitch(float2 uv, float failDriveShaped, out float flashOut)
            {
                // --- Layer 1: continuous fail-driven wave wobble --------------------
                // No gate: waveAmt is exactly 0 only at failDriveShaped == 0 (full
                // health) and grows smoothly from the very first point of damage,
                // per the "desync starts when the fail state starts" brief.
                float waveAmt = _GlitchWaveAmount * _GlitchFailBoost * failDriveShaped;
                float wobble  = sin(uv.y * _GlitchWaveFrequency + _Time.y * _GlitchWaveSpeed) * waveAmt;
                uv.x += wobble;

                // --- Layer 2: discrete fail-gated tear burst ---
                float tearWindow  = floor(_Time.y * max(_GlitchTearRate, 0.01));
                float bandY       = hash11(tearWindow * 7.91 + 1.7);
                float bandHeight  = lerp(0.02, 0.12, hash11(tearWindow * 3.13 + 4.9));
                float bandOffset  = (hash11(tearWindow * 5.47 + 2.3) * 2.0 - 1.0);

                bool  tearActive = failDriveShaped > saturate(_GlitchTearThreshold);
                float bandDist   = abs(uv.y - bandY);
                float bandMask   = tearActive ? (1.0 - aastep(bandHeight, bandDist)) : 0.0;

                // Tear displacement itself also scales with failDriveShaped (on top
                // of the threshold gate above), so tears keep getting more violent
                // the closer to failing you get, not just binary on/off.
                uv.x += bandOffset * _GlitchTearAmount * bandMask * failDriveShaped;

                // Bright leading edge right at the band's own boundary (mimics
                // a scanning highlight), only where the band itself is actually
                // active at this pixel.
                float edgeDist = abs(bandDist - bandHeight);
                flashOut = bandMask * (1.0 - aastep(0.01, edgeDist)) * _GlitchFlashAmount;

                return uv;
            }

            // Same pattern as LavaMetaballs.shader's SampleOverallEnergy(): average
            // a handful of taps across the low ~40% of the spectrum (the
            // bass/beat-carrying band) from _Yarg_SoundTex's FFT row (v=0). This
            // is already temporally smoothed at the source (TextureManager applies
            // an 0.8 exponential-decay filter before writing the texture each
            // frame), so the value read here changes gradually rather than
            // spiking per-sample -- important for the no-snap requirement below.
            //
            // NOTE: this has no dependency on uv/cell position, so it's sampled
            // ONCE per pixel in frag() and threaded into every EvaluateCell()
            // call (the center cell plus all 16 glow taps) as audioNorm, rather
            // than being re-sampled from scratch inside each of those calls.
            float SampleAudioEnergy()
            {
                const int taps = 8;
                float sum = 0.0;
                UNITY_UNROLL
                for (int i = 0; i < taps; i++)
                {
                    float u = (i + 0.5) / taps * 0.4;
                    sum += SAMPLE_TEXTURE2D_LOD(_Yarg_SoundTex, sampler_LinearClamp, float2(u, 0.0), 0).r;
                }
                return saturate(sum / taps);
            }

            // Root-mean-square estimate of the song's current overall loudness,
            // sampled from _Yarg_SoundTex's WAVEFORM row (row 1, v=1.0 -- see
            // TextureManager.cs: pixelData[FFT_TEXTURE_WIDTH+i] = 128*(wave+1),
            // i.e. texel value 0.5 == silence, decoded back to a -1..1 sample
            // below) rather than row 0's FFT magnitude. This is deliberately
            // distinct from SampleAudioEnergy()'s bass-band FFT average above:
            // RMS of the raw waveform is what "how loud is this song right now"
            // actually means, and is what drives _AudioMutationBoost -- the
            // FFT-based audioNorm continues to drive the glow/head-overdrive/
            // trail-swell/gap-relief effects exactly as before, untouched.
            float SampleWaveformRMS()
            {
                const int taps = 8;
                float sumSq = 0.0;
                UNITY_UNROLL
                for (int i = 0; i < taps; i++)
                {
                    float u = (i + 0.5) / taps;
                    float raw = SAMPLE_TEXTURE2D_LOD(_Yarg_SoundTex, sampler_LinearClamp, float2(u, 1.0), 0).r;
                    float sample = raw * 2.0 - 1.0;
                    sumSq += sample * sample;
                }
                return sqrt(sumSq / taps);
            }

            Varyings vert(Attributes IN)
            {
                Varyings OUT;
                OUT.positionCS = TransformObjectToHClip(IN.positionOS.xyz);
                OUT.uv = IN.uv;
                return OUT;
            }

            struct CellResult
            {
                float3 color;
                float  coverage;
                float  luminance; // color.rgb luminance * coverage, used by the glow taps below
            };

            // Every falling stream is reconstructed purely from (uv, _Time.y) -- no
            // per-glyph objects, no CPU column state. Factored into its own function
            // so the glow pass below can re-evaluate it at a handful of neighboring
            // UV offsets to build a cheap screen-space-style bloom with zero extra
            // render targets/passes. `audioNorm` (0..1, pre-normalized against
            // _AudioFloor/_AudioCeiling) and `gs` (gameplay-state inputs, see
            // GameplayInputs above) are both sampled/decoded once in frag() and
            // passed in here rather than re-sampled per call.
            CellResult EvaluateCell(float2 uv, float audioNorm, GameplayInputs gs)
            {
                CellResult result;

                // --- Grid & UV division driven by Glyph Scale ---
                float cols = max(4.0, round(_BaseColumns / max(_GlyphScale, 0.05)));
                float rows = max(4.0, round(cols / max(_AspectRatio, 0.01)));

                float colF  = uv.x * cols;
                float col   = floor(colF);
                float cellU = frac(colF);

                // Flip UV.y so rain falls top -> bottom
                float rowF  = (1.0 - uv.y) * rows;
                float row   = floor(rowF);
                float cellV = frac(rowF);

                float laneSeed = hash11(col * 12.9898 + 78.233);

                // --- Per-lane LIVE FFT amplitude ("Audio-Driven Intensity") ---
                // Distinct from _SpectrumHoldTex's slow attack/release envelope
                // used for length below: this is the RAW amplitude of THIS
                // lane's own assigned band, sampled fresh every frame. It drives
                // the head's brightness/color and the mutation rate for this
                // lane specifically (see the "Power Spikes" and "Data Processing
                // Load" sections further down), so a lane currently peaking
                // visibly burns hot while a neighboring quiet lane doesn't -- as
                // the amplitude falls back off, so does the effect, with no
                // extra smoothing applied here beyond what TextureManager
                // already bakes into the texture at the source. A few narrow
                // taps around the lane's own band center average out single-
                // bin noise without losing per-lane distinction. Uses the same
                // fixed-fraction-of-the-FFT-row mapping as
                // MatrixRainSpectrumHold.shader's _SpectrumBandRange (0.6
                // default), hardcoded here since this shader has no matching
                // property of its own to keep in sync.
                float laneBandCenter = saturate((col + 0.5) / cols * 0.6);
                float laneAmp = 0.0;
                {
                    const int laneTaps = 3;
                    UNITY_UNROLL
                    for (int li = 0; li < laneTaps; li++)
                    {
                        float offset = (li - 1) * (0.5 / max(cols, 1.0)) * 0.6;
                        laneAmp += SAMPLE_TEXTURE2D_LOD(_Yarg_SoundTex, sampler_LinearClamp, float2(saturate(laneBandCenter + offset), 0.0), 0).r;
                    }
                    laneAmp /= laneTaps;
                }
                float laneAmpNorm = saturate((laneAmp - _AudioFloor) / max(_AudioCeiling - _AudioFloor, 1e-4));

                // --- Fall Speed & Generation Math ---
                // baseFall/period/rawLoops/g/genFrac/speedVar are ALL driven purely
                // by _RainSpeed and the unbounded, ever-increasing _Time.y --
                // audioNorm and gameplay state (fail meter included) are NEVER
                // read here, by explicit design (fall speed is 100% constant
                // regardless of the song or the player's performance). Every
                // OTHER burst effect below (audio- or fail-driven) still only
                // scales already-bounded, non-positional terms (streamLen,
                // gapChance, color/intensity, rotation/mutation chance) -- never
                // baseFall/rawLoops/g/genFrac/speedVar.
                float baseFall = lerp(1.5, 34.0, saturate(_RainSpeed));

                // --- STATIC BASE LENGTH (For Physics/Translation) ---
                // Song-progress growth is folded into the _TrailLength input
                // here (additive, same discipline as every other modifier in
                // this shader) so baseMaxLen -- and everything downstream of it
                // (worstCaseStreamLen, period, reactiveMaxLen) -- automatically
                // picks it up without any extra touch points below.
                float effectiveTrailLength = saturate(_TrailLength + _ProgressTrailGrowth * gs.songProgress);
                float baseMaxLen = lerp(8.0, rows * 0.9, effectiveTrailLength);

                // --- Lane-overlap-safe generation period -------------------------
                // `period` must stay long enough that, even in the worst case (the
                // slowest possible speedVar and the longest possible trail under
                // full _AudioTrailSwell), one generation's tail has completely
                // fallen past the bottom row before the next generation (g+1)
                // begins. Otherwise the still-visible tail is abruptly replaced
                // mid-fall by the new generation's (as-yet-invisible) stream --
                // this reads as a column vanishing/"de-spawning" early, and is the
                // shader-architecture equivalent of two columns overlapping in the
                // same lane. Computed only from static material properties (never
                // from live audioNorm/gs/_Time.y), so it can't itself introduce any
                // stutter into baseFall/rawLoops/g/genFrac.
                float worstCaseStreamLen = baseMaxLen * (1.0 + saturate(_AudioTrailSwell));
                const float kMinSpeedVar = 0.90; // matches speedVar's lerp floor below
                const float kClearMargin = 6.0;  // extra rows so the logarithmic fade-to-black tail (below) also fully clears, not just the raw distToHead cutoff
                float minPeriodForClearance = (rows + worstCaseStreamLen * 2.0 + kClearMargin) / kMinSpeedVar;
                float period = max(rows * 2.2 + 8.0, minPeriodForClearance);

                float rawLoops     = (_Time.y * baseFall) / max(period, 1.0);
                float phaseOffset  = laneSeed * 4096.0;
                float g            = floor(rawLoops + phaseOffset);
                float genFrac      = frac(rawLoops + phaseOffset);
                float genSeed      = hash11(col * 97.13 + g * 13.71 + 4.7);

                float speedVar  = lerp(0.90, 1.10, hash11(genSeed * 3.71));

                float exponent  = pow(10.0, (0.5 - saturate(_LengthBias)) * 2.0);
                float lengthT   = pow(hash11(genSeed * 5.13), exponent);

                // --- Spectrum-Driven Column Sizing ("Inverse Spectrum Analyzer") ---
                // _SpectrumHoldTex holds a per-lane attack/release envelope (see
                // MatrixRainSpectrumHold.shader / the property comment above).
                // Song-progress growth is folded into _SpectrumInfluence here the
                // same additive way as effectiveTrailLength above.
                float lengthEnvelope = SAMPLE_TEXTURE2D_LOD(_SpectrumHoldTex, sampler_SpectrumHoldTex, float2((col + 0.5) / cols, 0.5), 0).r;
                float effectiveSpectrumInfluence = saturate(_SpectrumInfluence + _ProgressSpectrumGrowth * gs.songProgress);
                lengthT = saturate(lengthT + saturate(lengthEnvelope) * effectiveSpectrumInfluence);

                float baseStreamLen = lerp(6.0, baseMaxLen, lengthT);

                float hueBias = (hash11(genSeed * 9.31) * 2.0 - 1.0) * 0.15;

                // Continuous head position (used for smooth trail-body falloff) vs.
                // the single locked row the head glyph itself occupies. Snapping the
                // head overlay to floor(headRowContinuous) keeps the head locked to
                // exactly one cell at a time. We subtract baseStreamLen here so the
                // stream's physical downward speed is entirely decoupled from audio
                // and gameplay state alike.
                float headRowContinuous = genFrac * period * speedVar - baseStreamLen;
                float headRowSnapped    = floor(headRowContinuous);
                float distToHead        = headRowContinuous - row; // smooth, trail-only distance

                // --- DYNAMIC REACTIVE LENGTH (For Visual Rendering) ---
                // "Code Overflow": bass peaks stretch reactiveMaxLen so the visual
                // tails visibly elongate backward/upward with the beat.
                float reactiveMaxLen = baseMaxLen * lerp(1.0, 1.0 + _AudioTrailSwell, audioNorm);
                float reactiveStreamLen = lerp(6.0, reactiveMaxLen, lengthT);

                bool inStream = (distToHead >= 0.0) && (distToHead < reactiveStreamLen);

                // --- Brightness Falloff ---
                // Three segments: near-head plateau, exponential trail body, then a
                // logarithmic phosphor-decay fade to EXACTLY zero over the final
                // 10% of the stream (kTailFadeStart..1.0).
                float t = saturate(distToHead / max(reactiveStreamLen, 0.001));
                const float kTailFadeStart = 0.90;
                float bright;
                if (t <= 0.35)
                {
                    bright = 1.0 - 0.10 * (t / 0.35);
                }
                else if (t <= kTailFadeStart)
                {
                    float u = (t - 0.35) / (kTailFadeStart - 0.35);
                    bright = 0.90 * exp(-3.0 * u);
                }
                else
                {
                    float tailAnchorBright = 0.90 * exp(-3.0);
                    float fadeT = saturate((t - kTailFadeStart) / (1.0 - kTailFadeStart));
                    const float kLogK = 9.0; // log2(1+9) == log2(10)
                    float logFade = log2(1.0 + (1.0 - fadeT) * kLogK) / log2(1.0 + kLogK);
                    bright = tailAnchorBright * logFade;
                }

                // Head overlay: a hard, single-row test -- never spans two rows, so
                // there is exactly one white glyph per stream at any instant.
                float headGlow = (row == headRowSnapped) ? 1.0 : 0.0;
                bright = bright + headGlow * (1.0 - bright);
                bright *= 0.80;

                // --- Glyph Mutation ---
                float cellSeed = hash11(col * 31.7 + row * 57.13 + g * 11.0 + 1.3);
                const float kFreezeFloor = 0.084 * 0.80;
                float energyNorm = saturate((bright - kFreezeFloor) / (1.0 - kFreezeFloor));
                float mutWeight  = (energyNorm > 0.0) ? pow(energyNorm, 3.0) * 4.0 : 0.0;

                float mutRateBase  = lerp(1.5, 7.0, saturate(_RainSpeed)) * lerp(0.0, 2.0, saturate(_MutationRate));

                // "Data Processing Load" (audio) stacks multiplicatively with the
                // fail-state scramble boost below -- both only ever scale how fast
                // glyphBucket increments, never a position, so this is safe to
                // drive directly by elapsed time the same way the unboosted rate
                // already does.
                float rmsEnergy    = SampleWaveformRMS();
                float rmsNorm      = saturate((rmsEnergy - _RMSFloor) / max(_RMSCeiling - _RMSFloor, 1e-4));
                float audioMutMult = 1.0 + _AudioMutationBoost * max(rmsNorm, laneAmpNorm);

                // Fail-state "scramble wildly in danger states": a second,
                // independent multiplier driven purely by failDriveShaped, so a
                // full-health quiet song and a near-death quiet song read
                // completely differently regardless of what's playing.
                float failMutMult  = 1.0 + _FailMutationBoost * gs.failDriveShaped;
                float localMutRate = mutRateBase * mutWeight * audioMutMult * failMutMult;
                float glyphBucket  = floor(_Time.y * max(localMutRate, 0.0001) + cellSeed * 97.0);

                // --- "Signal Corruption" burst: discrete, all-rows-at-once hard
                // glyph reroll gated by either an audio-energy threshold OR
                // genuine tempo (proximity to a measure downbeat, from
                // gs.measurePhase) -- see the "YARG Signal Corruption Burst"
                // properties above. Time is sliced into fixed windows (no
                // persistent state needed -- every pixel this frame agrees on
                // which window it's in, purely from _Time.y) and each lane
                // independently rolls whether IT is "hot" for that window via a
                // hash keyed on (lane, window). While hot AND the trigger
                // condition holds, glyphBucket is force-overridden to a value
                // keyed only on (lane, window) -- shared across every row in
                // that column, so the whole lane rerolls simultaneously for the
                // window (cellSeed below still varies per-row, so rows land on
                // DIFFERENT fresh glyphs, not one repeated glyph). Like every
                // other effect in this shader, this only ever perturbs
                // glyphBucket/glyphHash -- never col/row/distToHead/baseFall --
                // so position and fall speed stay completely untouched.
                float burstWindow    = floor(_Time.y * max(_AudioBurstRate, 0.01));
                float burstLaneRoll  = hash11(col * 53.87 + burstWindow * 19.61 + 8.3);
                bool  burstArmed     = burstLaneRoll < saturate(_AudioBurstChance);
                bool  audioBurstTriggered    = max(audioNorm, laneAmpNorm) > saturate(_AudioBurstThreshold);
                bool  downbeatBurstTriggered = gs.measurePhase < saturate(_MeasureBurstWindow);
                bool  burstTriggered = audioBurstTriggered || downbeatBurstTriggered;
                if (burstArmed && burstTriggered)
                {
                    glyphBucket = burstWindow * 4096.0 + col * 3.0;
                }
                float glyphHash    = hash11(cellSeed + glyphBucket * 3.19);

                float atlasCols = max(1.0, _AtlasGridSize.x);
                float atlasRows = max(1.0, _AtlasGridSize.y);
                float cellCount = atlasCols * atlasRows;
                float glyphIndex = floor(glyphHash * cellCount);

                // Blank-cell gaps
                float gapHash       = hash11(cellSeed * 7.77);
                float lowDensityGap = lerp(0.35, 0.0, saturate(_Density));
                float gapChance     = saturate(_ColumnGapChance + lowDensityGap);

                // "Code Overflow" (part 2): bass peaks relax the blank-cell chance
                // so previously-dormant columns light up during heavy sections.
                gapChance *= (1.0 - _AudioGapRelief * audioNorm);

                bool  isGap         = gapHash < gapChance;

                // --- Locked 90-degree glyph rotation ---------------------------
                // Deterministic per-glyph rotation state, re-rolled each time the
                // glyph mutates (keyed off cellSeed + glyphBucket, same inputs that
                // pick the glyph itself). Rotation chance is the baseline slider
                // PLUS a fail-state boost -- glyphs rotate more and more wildly as
                // the fail meter empties, on top of whatever baseline the material
                // is set to. rotState (0..3) then picks WHICH of the four
                // 90-degree-locked orientations it lands in. Rotating cellU/cellV
                // (not the atlas UV) around the cell midpoint (0.5, 0.5) means the
                // gap-margin/bounds-mask math right below, which already operates on
                // cellU/cellV, applies identically regardless of rotation.
                float effectiveRotationChance = saturate(_RotationChance + _FailRotationBoost * gs.failDriveShaped);
                float rotateRoll = hash11(cellSeed * 53.91 + glyphBucket * 7.13 + 2.0);
                float rotHash     = hash11(cellSeed * 41.73 + glyphBucket * 5.53 + 3.1);
                float rotState     = (rotateRoll < effectiveRotationChance) ? min(floor(rotHash * 4.0), 3.0) : 0.0;

                float2 rotatedCellUV = float2(cellU, cellV);
                if (rotState > 0.5 && rotState < 1.5)      rotatedCellUV = float2(cellV, 1.0 - cellU);        // 90
                else if (rotState > 1.5 && rotState < 2.5) rotatedCellUV = float2(1.0 - cellU, 1.0 - cellV);   // 180
                else if (rotState > 2.5)                   rotatedCellUV = float2(1.0 - cellV, cellU);        // 270
                cellU = rotatedCellUV.x;
                cellV = rotatedCellUV.y;

                // --- Texture Sampling (with real-time configurable cell gaps) ---
                float gapX = clamp(_CellGapX, -1.0, 0.49);
                float gapY = clamp(_CellGapY, -1.0, 0.49);

                float boundsMask = aastep(gapX, cellU) * (1.0 - aastep(1.0 - gapX, cellU))
                                  * aastep(gapY, cellV) * (1.0 - aastep(1.0 - gapY, cellV));

                float2 innerUV = float2(
                    saturate((cellU - gapX) / max(1.0 - 2.0 * gapX, 0.0001)),
                    saturate((cellV - gapY) / max(1.0 - 2.0 * gapY, 0.0001)));

                float aCol = fmod(glyphIndex, atlasCols);
                float aRow = floor(glyphIndex / atlasCols);
                float2 atlasUV = (float2(aCol, aRow) + innerUV) / float2(atlasCols, atlasRows);

                // Sampling .r because the atlas is white-on-black, not alpha-transparent.
                float coverage = SAMPLE_TEXTURE2D(_FontAtlas, sampler_FontAtlas, atlasUV).r * boundsMask;

                if (!inStream || isGap) coverage = 0.0;

                // --- Color Blending ---
                // Fail-state palette shift: below _FailPaletteThreshold fail-drive,
                // both the trail and head base colors blend toward _FailAlarmColor.
                // Computed here (not as a static CBUFFER read) so it responds live
                // to gs.failPaletteBlend.
                float3 baseTrailColor = lerp(_TrailColor.rgb, _FailAlarmColor.rgb, gs.failPaletteBlend);
                float3 baseHeadColor  = lerp(_HeadColor.rgb, _FailAlarmColor.rgb, gs.failPaletteBlend);

                // Gold Milestone (6 stars): shifts both colors to _GoldColor on top of
                // (rendered after, so it wins over) the fail-tint above. A gentle,
                // per-lane-phase-offset brightness breathing (keyed on the same
                // laneSeed used elsewhere) reads as a steady shimmer rather than a
                // flat wash or a screen-wide synchronized pulse.
                baseTrailColor = lerp(baseTrailColor, _GoldColor.rgb, gs.goldBlend);
                baseHeadColor  = lerp(baseHeadColor, _GoldColor.rgb, gs.goldBlend);
                float goldShimmer = 1.0 + gs.goldBlend * _GoldShimmerIntensity * 0.5 *
                    (0.5 + 0.5 * sin(_Time.y * _GoldShimmerSpeed + laneSeed * 6.2831853));
                baseTrailColor *= goldShimmer;
                baseHeadColor  *= goldShimmer;

                float3 hueTint = (hueBias > 0.0)
                    ? float3(hueBias * 0.5 * bright, 0.0, 0.0)
                    : float3(0.0, 0.0, (-hueBias) * 0.5 * bright);
                float3 trailColor = saturate(baseTrailColor * bright + hueTint);

                // "Power Spikes" (audio) + beat-synced head flare (tempo) both
                // drive the same headOverdrive term, additively -- either a bass
                // peak or a fresh beat can flare the head, and they stack during
                // a peak that also happens to land on a beat.
                float headOverdrive  = _AudioHeadBoost * max(audioNorm, laneAmpNorm) + _BeatPulseIntensity * gs.beatPulse;
                float3 headColorHot  = baseHeadColor * (1.0 + headOverdrive * 0.6);
                headColorHot         = lerp(headColorHot, _OverdriveColor.rgb * (1.0 + headOverdrive), saturate(headOverdrive));

                float3 glyphColor = lerp(trailColor, headColorHot, headGlow);

                result.color = glyphColor;
                result.coverage = coverage;
                result.luminance = dot(glyphColor, float3(0.299, 0.587, 0.114)) * coverage;
                return result;
            }

            // Evaluates EvaluateCell() at the given uv and blends its coverage over
            // _BackgroundColor -- the same lerp every CA/phosphor-bleed tap needs, so
            // it's factored out here rather than repeated at each call site below.
            float3 EvalBlended(float2 uv, float audioNorm, GameplayInputs gs)
            {
                CellResult r = EvaluateCell(uv, audioNorm, gs);
                return lerp(_BackgroundColor.rgb, r.color, r.coverage);
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float2 uv = IN.uv;

                // Sampled once per pixel and reused everywhere below (center cell
                // + all 16 glow taps) -- see the SampleAudioEnergy()/EvaluateCell()
                // comments above for why this used to be redundantly re-sampled
                // per call and why that was unnecessary (the value has no uv
                // dependency at all).
                float audioEnergy = SampleAudioEnergy();
                float audioNorm   = saturate((audioEnergy - _AudioFloor) / max(_AudioCeiling - _AudioFloor, 1e-4));

                // --- YARG gameplay state, decoded once per pixel ---------------------
                // Editor-authoring aid: lets the material preview the full fail-
                // state ramp by hand while editing, without a live YARG session
                // feeding _Yarg_GameStateTex (which otherwise reads as a flat 0 --
                // see the property comment above). Uniform across every pixel, so
                // this branch costs nothing at runtime; MUST be left OFF (0) on
                // whatever material actually ships in the venue, or the real
                // fail meter from gameplay will be ignored entirely.
                float failMeter    = (_UseEditorPreviewFailMeter > 0.5)
                    ? saturate(_EditorPreviewFailMeter)
                    : saturate(YargFailMeter());
                // Floor the threshold itself (not just the divisor) at a small
                // epsilon -- at exactly 0 the numerator (threshold - failMeter) is
                // always <= 0 for any failMeter in 0..1, so failDrive saturates to 0
                // permanently (even at failMeter == 0, i.e. actual failure) and the
                // whole desync effect goes silently dead. A slider left at its Range
                // minimum should still produce a (very late, very sharp) glitch onset,
                // not none at all.
                float failThreshold = max(_FailGlitchThreshold, 0.02);
                float failDrive    = saturate((failThreshold - failMeter) / failThreshold);
                float failDriveShaped = pow(saturate(failDrive), max(_FailGlitchCurve, 0.01));
                float failPaletteBlend = smoothstep(saturate(_FailPaletteThreshold), 1.0, failDrive);
                float songProgress = saturate(YargSongProgress());
                float measurePhase = saturate(YargMeasurePhase());
                float beatPhase    = saturate(YargBeatPhase());
                float beatPulse    = 1.0 - smoothstep(0.0, saturate(_BeatPulseWindow), beatPhase);
                float starCharge   = saturate(YargStarPowerCharge());
                // Already the eased 0..1 shift amount -- see MatrixRainGoldMilestone.shader
                // for where the logarithmic-approach curve is actually computed.
                float goldBlend    = saturate(SAMPLE_TEXTURE2D_LOD(_GoldMilestoneTex, sampler_GoldMilestoneTex, float2(0.5, 0.5), 0).r);

                GameplayInputs gs;
                gs.failDrive = failDrive;
                gs.failDriveShaped = failDriveShaped;
                gs.failPaletteBlend = failPaletteBlend;
                gs.songProgress = songProgress;
                gs.measurePhase = measurePhase;
                gs.beatPulse = beatPulse;
                gs.goldBlend = goldBlend;

                // Barrel distortion warps the sampling UV before any grid/cell math
                // runs, mirroring MatrixReflow's BarrelDistort() usage in
                // bloom_composite (windows/shaders.hlsl). The static baseline slider
                // is added to a fail-driven extra warp (_FailBarrelDistortion,
                // scaled by failDriveShaped) so the screen itself visibly bows more
                // as the player nears failure, on top of whatever curvature look
                // the material was already set to. Computed once and reused for the
                // center cell AND every glow tap below, so the whole rain field
                // (streams + glow) warps together as one coherent curved surface.
                float effectiveBarrelDistortion = _BarrelDistortion + _FailBarrelDistortion * failDriveShaped;
                float2 uvBase = BarrelDistort(uv, effectiveBarrelDistortion);

                // --- Fail-State Analog Signal Desync (audio-independent) -------------
                // Applied to the SAME uvBase used for the center cell, every
                // CA/phosphor-bleed tap, and every glow tap below -- so the whole
                // rain field warps/tears together as one coherent signal, exactly
                // like BarrelDistort above (whose result this further distorts).
                // See ApplyAnalogGlitch() for the two-layer (continuous wobble +
                // fail-gated tear burst) breakdown. Driven purely by
                // failDriveShaped -- no audio input at all.
                float glitchFlash = 0.0;
                uvBase = ApplyAnalogGlitch(uvBase, failDriveShaped, glitchFlash);

                // --- Chromatic Aberration + Convergence Fringing -------------------
                // Two distinct MatrixReflow effects, combined into one pair of R/B
                // sample offsets (both push R and B in exactly opposite directions
                // along the same axis, so they algebraically combine into one offR/
                // offB pair):
                //   1) Radial CA (bloom_composite's offR/offB): direction is radially
                //      OUTWARD from center (caDir), magnitude grows with caEdge = r^2.
                //   2) Convergence fringing (crt_filter's beam-misalignment term): the
                //      source uses a FIXED small horizontal offset; here its magnitude
                //      is instead scaled by the same caEdge term so it scales outward
                //      from center to the edges, matching how convergence error is
                //      worst toward the corners on a real shadow-mask tube.
                // Each channel is sampled from a SEPARATE EvaluateCell() call via
                // EvalBlended(), so coverage -- not just color -- differs per tap near
                // cell/glyph edges, producing real fringing rather than a flat channel
                // shift. R/B taps are skipped entirely when both sliders are at their
                // default 0 so the previously-verified look is unchanged.
                float2 caCenter    = uvBase - 0.5;
                float  caEdge      = dot(caCenter, caCenter);
                float2 caDir       = normalize(caCenter + 1e-5);
                float2 radialOff   = caDir * _CRTChromaticAberration * caEdge;
                float2 convergeOff = float2(_CRTConvergenceFringing * caEdge, 0.0);
                float2 offR        = radialOff + convergeOff;
                float2 offB        = -offR;

                float3 blendedG = EvalBlended(uvBase, audioNorm, gs);
                float3 blendedR = blendedG;
                float3 blendedB = blendedG;
                if (_CRTChromaticAberration > 0.0001 || _CRTConvergenceFringing > 0.0001)
                {
                    blendedR = EvalBlended(uvBase + offR, audioNorm, gs);
                    blendedB = EvalBlended(uvBase + offB, audioNorm, gs);
                }
                float3 baseRGB = float3(blendedR.r, blendedG.g, blendedB.b);

                // --- Phosphor Bleed --------------------------------------------------
                // Adapted from MatrixReflow's crt_filter phosphor-glow-bleed term: a
                // 5-tap horizontal-biased blur with the source's exact weights
                // (0.06/0.18/0.52/0.18/0.06), standing in for electron-beam spot
                // spread / phosphor persistence -- distinct from the luminance-
                // THRESHOLDED glow pass below (this softens everything a little
                // regardless of brightness, the way real phosphor bleed does).
                // Applied to the pre-glow base color only (not re-run through all 16
                // glow taps below) to keep this affordable; fwidth(uvBase) derives the
                // UV size of one screen pixel dynamically so the blur stays correctly
                // scaled at any camera distance. Skipped entirely at its default 0.
                if (_CRTPhosphorBleed > 0.0001)
                {
                    float2 texelUV = max(fwidth(uvBase), 1e-5);
                    float2 stepUV  = float2(texelUV.x, 0.0);

                    float3 bm2 = EvalBlended(uvBase - stepUV * 2.0, audioNorm, gs);
                    float3 bm1 = EvalBlended(uvBase - stepUV,       audioNorm, gs);
                    float3 bp1 = EvalBlended(uvBase + stepUV,       audioNorm, gs);
                    float3 bp2 = EvalBlended(uvBase + stepUV * 2.0, audioNorm, gs);

                    float3 bled = bm2 * 0.06 + bm1 * 0.18 + baseRGB * 0.52 + bp1 * 0.18 + bp2 * 0.06;
                    baseRGB = lerp(baseRGB, bled, saturate(_CRTPhosphorBleed));
                }

                // ---------------------------------------------------------------
                // Embedded glow. There is no separate scene-color render target to
                // blur here (this is a single unlit pass on one background quad,
                // not a full-screen post effect), so instead of a real mip-chain
                // blur this re-evaluates EvaluateCell() at a small ring of nearby
                // UV offsets -- cheap because the whole rain function is a pure
                // function of (uv, time) with no texture-dependent recursion --
                // and additively blends in the luminance-thresholded result,
                // approximating the original DrawPost() bloom chain's
                // threshold -> downsample -> additive-upsample -> composite.
                //
                // "Power Spikes" (audio, _AudioGlowBoost) and the Star Power
                // "charge-ready" heartbeat (tempo-independent, keyed on
                // starCharge + _Time.y) both scale the overall glow intensity,
                // multiplicatively, on top of the base _GlowIntensity slider.
                // ---------------------------------------------------------------
                float chargeReady = smoothstep(0.985, 1.0, starCharge);
                float chargePulse = 0.5 + 0.5 * sin(_Time.y * _ChargePulseSpeed);
                float effectiveGlowIntensity = _GlowIntensity
                    * (1.0 + _AudioGlowBoost * audioNorm)
                    * (1.0 + chargeReady * chargePulse * _ChargePulseIntensity)
                    * (1.0 + gs.goldBlend * _GoldShimmerIntensity * 0.5);

                float3 glow = 0.0;
                if (effectiveGlowIntensity > 0.0001)
                {
                    const float2 kDirs[8] = {
                        float2( 1.0,  0.0), float2(-1.0,  0.0),
                        float2( 0.0,  1.0), float2( 0.0, -1.0),
                        float2( 0.7071,  0.7071), float2(-0.7071,  0.7071),
                        float2( 0.7071, -0.7071), float2(-0.7071, -0.7071)
                    };
                    float lo = _GlowThreshold - 0.3;
                    float hi = _GlowThreshold + 0.3;

                    [unroll]
                    for (int i = 0; i < 8; i++)
                    {
                        float2 dir = kDirs[i];

                        CellResult nearTap = EvaluateCell(uvBase + dir * _GlowRadius, audioNorm, gs);
                        float nearK = smoothstep(lo, hi, nearTap.luminance);
                        glow += nearTap.color * nearK;

                        CellResult farTap = EvaluateCell(uvBase + dir * _GlowRadius * 2.5, audioNorm, gs);
                        float farK = smoothstep(lo, hi, farTap.luminance);
                        glow += farTap.color * farK * 0.5;
                    }
                    glow *= effectiveGlowIntensity / 8.0;
                }

                float3 finalRGB = saturate(baseRGB + glow);

                // --- Slot Mask / Shadow Mask ----------------------------------------
                // Adapted from MatrixReflow's crt_filter vertical RGB phosphor triads,
                // DRAMATIZED per an explicit "heavy, not subtle" request: wider triad
                // pitch, much stronger per-channel separation (was 1.08/0.82, now
                // 1.5/0.35), and no longer luminance-gated (the source's maskStrength
                // only showed the grid over lit glyphs; here it's visible everywhere,
                // including the lifted-black background below, for a persistent,
                // always-on CRT grid). The hard triadPhase branch is replaced with an
                // aastep()-based crossfade between the three channel-dominant thirds
                // so the vertical stripes don't alias/moire as they move relative to
                // pixel centers (procedural AA, see aastep() above).
                const float kTriadPx = 3.0;
                float triadPhase = frac(IN.positionCS.x / kTriadPx);
                float wA = 1.0 - aastep(1.0 / 3.0, triadPhase);
                float wC = aastep(2.0 / 3.0, triadPhase);
                float wB = saturate(1.0 - wA - wC);
                float3 slotMask = wA * float3(1.5, 0.35, 0.35)
                                + wB * float3(0.35, 1.5, 0.35)
                                + wC * float3(0.35, 0.35, 1.5);

                float maskStrength = saturate(_CRTSlotMaskIntensity);
                finalRGB *= lerp(1.0, slotMask, maskStrength);

                // --- CRT scanlines ---------------------------------------------------
                // Adapted from MatrixReflow's crt_filter horizontal raster gaps,
                // DRAMATIZED the same way as the slot mask above: a deeper trough
                // (0.72..1.0 -> 0.30..1.0, a 70% swing instead of 28%) and a wider
                // kScanlinePx pitch so individual lines read as chunky and obvious
                // rather than a fine, subtle texture. scanY (the unwrapped pixel-
                // space coordinate, before frac()) drives an fwidth()-based adaptive
                // transition width instead of a fixed smoothstep edge, so the bands
                // stay clean under camera movement/perspective instead of shimmering
                // (procedural AA, same idea as aastep() above).
                const float kScanlinePx = 3.0;
                float scanY      = IN.positionCS.y / kScanlinePx;
                float scanPhase  = frac(scanY);
                float scanShape  = 1.0 - abs(scanPhase * 2.0 - 1.0);
                float scanAA     = max(fwidth(scanY), 1e-4);
                float scanline   = lerp(0.30, 1.0, smoothstep(0.5 - scanAA, 0.5 + scanAA, scanShape));
                float lineRipple = 0.94 + 0.06 * sin(IN.positionCS.y * 1.7 + _Time.y * 0.6);
                scanline *= lineRipple;
                float scanlineMask = lerp(1.0, scanline, saturate(_CRTScanlineIntensity));
                finalRGB *= scanlineMask;

                // --- Black-Level Lift -------------------------------------------------
                // Generalized from MatrixReflow's crt_filter: real CRTs never reach a
                // true 0 black (residual phosphor persistence / ambient tube glow). The
                // source uses a flat kBlackLift=0.02 grey; this tints toward phosphor
                // green instead of neutral grey so it reads as "glowing tube" rather
                // than "washed out," and exposes the amount live as _BlackLevelLift
                // (the source's fixed value corresponds to roughly 0.02 on this slider).
                float3 phosphorLiftColor = float3(0.035, 0.05, 0.04);
                finalRGB = finalRGB * (1.0 - _BlackLevelLift) + phosphorLiftColor * _BlackLevelLift;

                // --- Corner Vignette / Edge Roll-off ---------------------------------
                // Ported 1:1 from MatrixReflow's crt_filter mask-edge vignette: a
                // physically-domed-shadow-mask-style falloff from UV center (0.5, 0.5),
                // using squared distance (cornerDist = dot(c,c), matching the source
                // exactly) and its exact smoothstep range/strength (0.12..0.5, 0.22).
                float2 vignetteC     = uvBase - 0.5;
                float  cornerDist    = dot(vignetteC, vignetteC);
                float  vignetteCurve = 1.0 - 0.22 * smoothstep(0.12, 0.5, cornerDist);
                float  vignetteMask  = lerp(1.0, vignetteCurve, saturate(_CRTVignetteIntensity));
                finalRGB *= vignetteMask;

                // Blend the tear band's bright scanning leading edge in last,
                // on top of every CRT post pass above (slot mask/scanlines/
                // black-level/vignette) -- mimics a scanning flash riding
                // visibly ON TOP of its own screen static, rather than being
                // another texture the CRT passes would just dim back down.
                finalRGB = saturate(finalRGB + _GlitchFlashColor.rgb * glitchFlash);

                return half4(finalRGB, 1.0);
            }
            ENDHLSL
        }
    }
}