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

        [Header(Async Column Speed By Length)]
        // Fall speed is now INVERSELY tied to the length of each stream. Each
        // speed is scaled by lerp(_ShortColumnSpeed, _LongColumnSpeed, lengthFraction),
        // where lengthFraction is the STATIC hash-derived length (never the live
        // audio-extended length), so audio can never change the speed of a stream
        // mid-fall. Short streams read as fast foreground streaks; long streams
        // as slow, heavy background streams. 0 influence = old uniform speed.
        _LengthSpeedInfluence ("Length-Based Speed Influence (0 = uniform, 1 = full)", Range(0.0, 1.0)) = 1.0
        _ShortColumnSpeed ("Short Column Speed Multiplier (fast streaks)", Range(0.25, 3.0)) = 1.4
        _LongColumnSpeed  ("Long Column Speed Multiplier (slow heavy streams)", Range(0.1, 2.0)) = 0.5

        [Header(Column Spawn Density)]
        // Each lane now runs a CHAIN of back-to-back streams (a new one spawns as
        // soon as the previous one has fully cleared, after only a short random
        // idle gap) instead of one stream followed by a long dead period. The idle
        // gap shrinks as _Density rises. _SecondaryLayerChance adds an independent
        // second timeline per lane (the two timelines may cross inside a lane, but every
        // cell is single-occupancy: the brighter stream owns it outright and the other
        // is discarded there) -- 0 disables it entirely (also skips its cost).
        _StreamGapMax ("Idle Gap Between Streams @ Density 0 (rows)", Range(0.0, 80.0)) = 30.0
        _StreamGapMin ("Idle Gap Between Streams @ Density 1 (rows)", Range(0.0, 40.0)) = 2.0
        _SecondaryLayerChance ("Secondary Stream Layer Chance (extra density)", Range(0.0, 1.0)) = 0.6

        [Header(YARG Tempo Sync)]
        // YARG publishes no BPM float -- only beat phase (texel 8). The 1x1
        // feedback texture CRT_MatrixTempoClock (MatrixRainTempoClock.shader)
        // recovers tempo from how fast that phase wraps and integrates it into a
        // monotonic clock: the rain runs at (bpm / reference bpm) x its normal
        // speed during a song and exactly 1x otherwise. Integrating (instead of
        // multiplying _Time.y) keeps motion continuous through tempo changes.
        [NoScaleOffset] _TempoClockTex ("Tempo Clock (CRT_MatrixTempoClock, set on the material)", 2D) = "black" {}
        _TempoInfluence ("Tempo Sync Influence (0 = fixed speed, 1 = fully tempo-scaled)", Range(0.0, 1.0)) = 0.85

        [Header(Cell Spacing)]
        // Margin carved symmetrically out of each cell: the glyph shrinks toward the
        // cell center and the border stays blank. Positive values only ever shrink a
        // glyph inside its own cell (never overlaps a neighbor -- consistent with the
        // hard no-overlap rule everywhere else in this shader).
        //
        // EXPLICIT, REQUESTED EXCEPTION: negative values are allowed here on purpose.
        // They magnify the glyph beyond its cell's footprint (via the innerUV crop in
        // GlyphCoverage() below) so adjacent glyphs visually pack/overlap for a denser
        // look -- the one deliberate override of the single-occupancy rule, kept because
        // it never breaks per-pixel cell ownership: a pixel still ever samples exactly
        // ONE glyph (its own home cell's), the cell just no longer clips that glyph's
        // rendered shape at the cell boundary. Rotation/atlas-edge safety (kAtlasCellInset
        // in GlyphCoverage()) is unaffected by gap sign, so this cannot reintroduce the
        // atlas-bleed bug that motivated the no-overlap fix.
        _CellGapX ("Cell Gap X (negative = intentional overlap/pack)", Range(-0.5, 0.45)) = 0.0
        _CellGapY ("Cell Gap Y (negative = intentional overlap/pack)", Range(-0.5, 0.45)) = 0.0

        [Header(Glow)]
        // Embedded glow -- previously a separate ScriptableRendererFeature
        // (MatrixReflowBloomFeature.cs + Hidden/MatrixReflow/Bloom.shader), now
        // folded directly into this single pass since a .yarground AssetBundle
        // cannot load a custom C# URP renderer feature at runtime. See the
        // ResolveCellState()/glow-tap comments in the fragment shader below.
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
        // (AMENDED: fall speed now follows song TEMPO -- via the integrated clock in
        // _TempoClockTex, see YARG Tempo Sync above -- but still never the FFT/RMS
        // audio signal read by this section.)
        // IMPORTANT: downward fall speed is 100% constant and audio-independent
        // by design -- baseFall/period/rawLoops/g/genFrac/speedVar in
        // ResolveCellState() never read audioNorm. Every OTHER effect below (glow,
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
        // see the localMutRate comment in ResolveCellState() for why this is safe
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

        [Header(YARG Song Intro Reveal)]
        // During the song countdown, the rain is completely blank.
        // Once the song begins, a top-down wavefront reveals the rain.
        _IntroRevealSpeedMult ("Intro Reveal Speed Multiplier", Range(0.1, 4.0)) = 1.0
        _IntroRevealSoftness ("Intro Reveal Edge Softness (rows)", Range(0.01, 4.0)) = 0.75

        [Header(Editor Preview Intro)]
        // Authoring-only preview controls. A negative preview time simulates
        // the countdown; zero and above simulate elapsed song time.
        [Toggle] _UseEditorPreviewIntro ("Use Editor Preview Intro", Float) = 0
        _EditorPreviewIntroTime ("Editor Preview Intro Time (seconds)", Float) = 0.0

        [Header(YARG Beat Synced Head Flare)]
        // A guaranteed, tempo-locked flash on the leading glyph right after
        // each beat (from YargGameStateBeatPhase()), layered additively on
        // top of the existing audio-peak head overdrive -- see beatPulse in
        // frag() and its use in ResolveCellState()'s headOverdrive calc.
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
        // _BaselineDrizzle). ResolveCellState() below ADDS this on top of the
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
        // ResolveCellState()), since hitting 6 stars and being in the fail zone
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
        // Beam-pulse refresh sweep -- the scanning-highlight-then-decay look of an
        // old green terminal (Fallout 3/New Vegas Pip-Boy style). _CRTBeamBloom widens
        // the scanline gaps under bright glyph strokes; _CRTPhosphorDecay/_CRTRefreshRate
        // add a slow top-to-bottom sweep where phosphor is brightest just after the beam
        // passes and decays exponentially until it returns.
        _CRTBeamBloom ("CRT Beam Bloom (spot growth with brightness)", Range(0.0, 1.0)) = 0.5
        _CRTPhosphorDecay ("CRT Phosphor Decay Sweep Depth (beam-pulse look)", Range(0.0, 1.0)) = 0.12
        _CRTRefreshRate ("CRT Decay Sweep Rate (Hz)", Range(0.02, 2.0)) = 0.35
        _CRTVignetteIntensity ("CRT Vignette Intensity", Range(0.0, 1.0)) = 0.0
        _BlackLevelLift ("CRT Black Level Lift", Range(0.0, 0.3)) = 0.0

        [Header(Glyph Rotation)]
        // ---- Locked 90-degree glyph rotation ---------------------------------------
        // Chance that a given glyph, on mutation, lands in a rotated (90/180/270-
        // degree) orientation instead of upright. 0 = never rotate (matches previous
        // behavior exactly). Additionally boosted as the fail meter drops -- see
        // _FailRotationBoost below.
        _RotationChance ("Glyph Rotation Chance (baseline)", Range(0.0, 1.0)) = 0.0

        // NOTE: _Yarg_GameStateTex is deliberately NOT a material property.
        // YARG publishes it as a GLOBAL (Shader.SetGlobalTexture in
        // TextureManager) and never assigns it per-material; a Properties
        // entry of the same name would shadow the global with the material's
        // own black default, and every gameplay-state feature below would
        // silently read zeros in a real song. It is declared in the HLSL body
        // instead (see TEXTURE2D(_Yarg_GameStateTex)).

        [Header(Editor Preview Fail Meter Override)]
        // Authoring aid only. Outside an actual running song,
        // _Yarg_GameStateTex is a global written only during a real song, so
        // it is unbound/all-zero here (YargFailMeter() treats that as full
        // health) and there is nothing to preview against. Flip this toggle on to substitute a hand-set value
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
        // Slow hash-driven drift on top of the plain sine above (see
        // ApplyAnalogGlitch()) so the wave's phase and frequency wander
        // continuously instead of reading as one metronomic, obviously-looping
        // sine. 0 = old behavior exactly (pure sine, no drift).
        _GlitchWaveJitter    ("Glitch Wave Organic Jitter (phase/frequency drift)", Range(0.0, 1.0)) = 0.5
        _GlitchFailBoost     ("Glitch Fail Boost (wave amount multiplier)", Range(0.0, 20.0)) = 6.0
        _GlitchTearThreshold ("Glitch Tear Onset (fail-drive fraction before tears begin)", Range(0.0, 1.0)) = 0.5
        _GlitchTearAmount    ("Glitch Tear Amount (UV units, at full fail)", Range(0.0, 0.2)) = 0.05
        _GlitchTearRate      ("Glitch Tear Rate (windows / sec)", Range(1.0, 30.0)) = 6.0
        _GlitchFlashColor    ("Glitch Flash Color (tear leading edge)", Color) = (0.8, 1.0, 0.95, 1)
        _GlitchFlashAmount   ("Glitch Flash Amount (leading-edge brightness)", Range(0.0, 3.0)) = 1.2

        // Analog signal static: a screen-locked (not warped by barrel/tear UV
        // distortion above -- real signal noise sits on top of the picture,
        // it doesn't bend with it) per-pixel grain, re-rolled every frame off
        // IN.positionCS + _Time.y (see StaticNoise() -- single hash11() call,
        // no texture fetch, no loop). Directly and only driven by
        // failDriveShaped, same as every other Fail State Desync term on this
        // page: exactly 0 at full health, scaling up proportionately as the
        // fail meter empties. NOT gated by _GlitchTearThreshold -- this is the
        // constant grain-noise floor, independent of the discrete tear bursts.
        _StaticNoiseIntensity ("Signal Static Amount (grain, scales with desync)", Range(0.0, 2.0)) = 0.5
        _StaticNoiseScale     ("Signal Static Scale (grain size, screen pixels per cell)", Range(1.0, 8.0)) = 2.0
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

            // Tempo clock (1x1 RGBA32F feedback CRT, see MatrixRainTempoClock.shader):
            // R = integrated rain clock, B = smoothed tempo scale (0 = not running).
            TEXTURE2D(_TempoClockTex);
            SAMPLER(sampler_TempoClockTex);

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
                float  _CRTBeamBloom;
                float  _CRTPhosphorDecay;
                float  _CRTRefreshRate;
                float  _CRTVignetteIntensity;
                float  _CRTChromaticAberration;
                float  _CRTConvergenceFringing;
                float  _CRTPhosphorBleed;
                float  _CRTSlotMaskIntensity;
                float  _BlackLevelLift;
                float  _RotationChance;

                float  _IntroRevealSpeedMult;
                float  _IntroRevealSoftness;
                float  _UseEditorPreviewIntro;
                float  _EditorPreviewIntroTime;

                float  _BeatPulseIntensity;
                float  _BeatPulseWindow;
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
                float  _GlitchWaveJitter;
                float  _GlitchFailBoost;
                float  _GlitchTearThreshold;
                float  _GlitchTearAmount;
                float  _GlitchTearRate;
                float4 _GlitchFlashColor;
                float  _GlitchFlashAmount;
                float  _StaticNoiseIntensity;
                float  _StaticNoiseScale;
                float  _FailBarrelDistortion;
                float4 _FailAlarmColor;
                float  _FailPaletteThreshold;
                float  _FailRotationBoost;
                float  _FailMutationBoost;
                float  _LengthSpeedInfluence;
                float  _ShortColumnSpeed;
                float  _LongColumnSpeed;
                float  _StreamGapMax;
                float  _StreamGapMin;
                float  _SecondaryLayerChance;
                float  _TempoInfluence;
            CBUFFER_END

            // ---- tiny deterministic GPU hash ----
            float hash11(float p)
            {
                p = frac(p * 0.1031);
                p *= p + 33.33;
                p *= p + p;
                return frac(p);
            }

            // Lightweight, procedural analog-static grain. One hash11() call,
            // no texture fetch, no loop -- as cheap as the sine wobble it sits
            // alongside. Keyed off SCREEN pixel coordinates (not uvBase), so the
            // grain is screen-locked like real signal noise rather than warping
            // with the barrel-distortion/tear UV offsets applied elsewhere.
            // Re-hashed off raw _Time.y (not floor()'d into discrete steps), so
            // it re-rolls completely every frame -- an authentic non-deterministic
            // flicker rather than a slow, potentially loop-visible animation.
            float StaticNoise(float2 screenPx, float cellPx, float t)
            {
                float2 cell = floor(screenPx / max(cellPx, 1.0));
                float n = hash11(dot(cell, float2(12.9898, 78.233)) + t * 91.7);
                return n * 2.0 - 1.0; // -1..1
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
                // Texel 2 is EngineManager.Happiness already clamped to 0..1 by
                // TextureManager.UpdateGameState() (see gamestate.hlsl), so it is
                // used as-is: 1 = full health, 0 = failed. No remap.
                //
                // Texel 0 is the song length in seconds. It is 0 whenever the
                // texture is unbound or all-zero (editor, no running song), in
                // which case there is no real fail meter to read -- report full
                // health instead of a false 'failed'.
                if (YargGameState(0) <= 0.0) return 1.0;
                // Practice mode (texel 6, GameManager.IsPractice): the game skips the
                // fail routine entirely there, so Happiness is free to sink to 0 and
                // would pin every fail-driven effect (desync warp, tears, barrel, alarm
                // palette, rotation/mutation boost) at 100%. The meter is meaningless in
                // practice, so report full health and leave those effects off.
                if (YargGameState(6) > 0.5) return 1.0;

                return saturate(YargGameState(2));
            }
            float YargBeatPhase()       { return YargGameState(8); }
            float YargStarPowerCharge() { return YargGameState(11); }
            float YargStars()           { return YargGameState(15); }

            // Per-pixel gameplay-state inputs, decoded ONCE in frag() (same
            // discipline as audioNorm/SampleAudioEnergy() below) and threaded
            // into ResolveCellState() as a single struct rather than growing its
            // parameter list one feature at a time.
            struct GameplayInputs
            {
                float failDrive;        // 0 = full health, 1 = about to fail (linear)
                float failDriveShaped;  // pow(failDrive, _FailGlitchCurve) -- eases in, ramps hard near failure
                float failPaletteBlend; // 0..1 blend of _TrailColor/_HeadColor toward _FailAlarmColor
                float beatPulse;        // 0..1, spikes right after each beat then decays out
                float goldBlend;        // 0..1, eased envelope toward the 6-star gold shift
                float rainClock;        // seconds, tempo-integrated (falls back to _Time.y); the ONLY clock stream positions read
                float rmsNorm;          // 0..1 normalized waveform RMS, hoisted out of ResolveCellState (uv-independent)
                float introClock;       // seconds since the drop (0 at/before it); meaningless when introBlank > 0.5
                float introBlank;       // 1 = force every cell fully unlit (still in countdown), 0 = normal
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
            // genFrac inside ResolveCellState(), so the rain's own fall-speed
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
                //
                // Organic jitter: a plain sin(uv.y * freq + time * speed) is
                // perfectly periodic and reads as an obvious, repeating wave within
                // a few seconds. Two independent slow hash-noise ramps (~2-3s
                // period each, smoothstep-interpolated so they drift continuously
                // rather than stepping) perturb the frequency and phase instead --
                // four hash11() calls total, no texture fetch, no loop, so this
                // stays exactly as cheap as the sine itself. _GlitchWaveJitter == 0
                // reproduces the old pure-sine behavior exactly.
                float jitterAmt = saturate(_GlitchWaveJitter);
                float freqT      = _Time.y * 0.35;
                float freqDriftA = hash11(floor(freqT) * 3.7 + 1.0);
                float freqDriftB = hash11(floor(freqT) * 3.7 + 1.0 + 3.7);
                float freqDrift  = lerp(freqDriftA, freqDriftB, smoothstep(0.0, 1.0, frac(freqT))) * 2.0 - 1.0;

                float phaseT      = _Time.y * 0.22;
                float phaseDriftA = hash11(floor(phaseT) * 5.1 + 2.0);
                float phaseDriftB = hash11(floor(phaseT) * 5.1 + 2.0 + 5.1);
                float phaseDrift  = lerp(phaseDriftA, phaseDriftB, smoothstep(0.0, 1.0, frac(phaseT))) * 6.2831853;

                float effFrequency = _GlitchWaveFrequency * lerp(1.0, 1.0 + freqDrift * 0.5, jitterAmt);
                float effPhase     = _Time.y * _GlitchWaveSpeed + phaseDrift * jitterAmt;

                float waveAmt = _GlitchWaveAmount * _GlitchFailBoost * failDriveShaped;
                float wobble  = sin(uv.y * effFrequency + effPhase) * waveAmt;
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
            // ONCE per pixel in frag() and threaded into every ResolveCellState()
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

            // ---- Chained per-lane stream timeline ---------------------------------------
            // Time inside a lane is measured in BASE-RATE ROWS of clock (clock x
            // baseFall). One 'generation' spans `period` of those rows and holds a
            // chain of up to 4 back-to-back streams. A stream is only placed if it
            // (plus its idle gap) fits entirely inside the generation, so a stream
            // can never be cut off mid-fall at a generation boundary, and streams
            // in one timeline can never overlap. All timing inputs are STATIC
            // (material properties only) -- never live audio or gameplay
            // state -- so nothing here can make a stream jump.
            static const float kSpectrumHeadroom = 0.45; // how much audio may lengthen a stream beyond its hash length
            static const float kClearMargin      = 2.0;  // extra rows so the fading tail fully clears
            static const float kHeadStart        = 1.0;  // head begins one row above the top edge

            struct StreamTiming
            {
                float seed;      // per-stream hash seed
                float lenHash;   // static length fraction 0..1 (before spectrum growth)
                float speedRel;  // head speed relative to the base fall rate
                float budgetLen; // static upper bound on this stream visual length (rows)
                float dur;       // clock rows this stream occupies from spawn to fully cleared
                float gap;       // idle clock rows before the next chained stream
            };

            StreamTiming GetStreamTiming(float colKey, float sid, float rows, float worstMaxLen, float lenExponent, float period)
            {
                StreamTiming st;
                st.seed = hash11(colKey * 97.13 + sid * 13.71 + 4.7);
                float speedJitter = lerp(0.90, 1.10, hash11(st.seed * 3.71));
                st.lenHash = pow(hash11(st.seed * 5.13), lenExponent);

                // Inverse speed/length relationship: short = fast, long = slow.
                float lenSpeed = lerp(_ShortColumnSpeed, _LongColumnSpeed, st.lenHash);
                float speedRel = speedJitter * lerp(1.0, lenSpeed, saturate(_LengthSpeedInfluence));

                st.budgetLen = lerp(6.0, worstMaxLen, saturate(st.lenHash + kSpectrumHeadroom));
                float travel = rows + st.budgetLen + kClearMargin + kHeadStart;

                // Never slower than what still fits one generation.
                st.speedRel = max(max(speedRel, 0.05), travel / period);
                st.dur = travel / st.speedRel;

                float gapBase = lerp(_StreamGapMax, _StreamGapMin, saturate(_Density));
                st.gap = gapBase * (0.3 + 0.7 * hash11(st.seed * 11.3 + 0.7));
                return st;
            }

            struct LaneStream
            {
                float sid;      // unique stream id (drives per-cell glyph hashing)
                float bright;   // final brightness for this row (0 when not covered)
                float headGlow; // 1 on the head row
                float hueBias;
                bool  active;   // this stream covers this row
            };

            // Result of walking one lane's chain of back-to-back streams up to a given
            // instant: whichever stream (if any) covers it, and where in the generation
            // it started. A pure function of the static per-stream hashes and `rainClock`,
            // so calling it again for a different instant (as the lane-collision guard
            // below does) always gives the same answer for that instant.
            struct ChainHit
            {
                bool  found;
                float sid;
                float seed;
                StreamTiming timing;
                float actStart;
                float localD;
                float g;
            };

            ChainHit WalkChain(float colKey, float laneSeedT, float rainClock, float baseFall,
                               float period, float rows, float worstMaxLen, float lenExponent)
            {
                ChainHit hit = (ChainHit)0;

                // Small phase offset (64 generations) keeps float precision tight.
                float genPos = rainClock * baseFall / period + laneSeedT * 64.0;
                float g      = floor(genPos);
                float localD = frac(genPos) * period;
                hit.g = g;
                hit.localD = localD;

                float chainT = 0.0;
                [loop]
                for (int k = 0; k < 4; ++k)
                {
                    if (localD < chainT) break; // inside an idle gap
                    float sid = g * 4.0 + (float)k;
                    StreamTiming cand = GetStreamTiming(colKey, sid, rows, worstMaxLen, lenExponent, period);
                    float endT = chainT + cand.dur;
                    if (endT > period) break; // would not fit this generation
                    if (localD < endT)
                    {
                        hit.found    = true;
                        hit.sid      = sid;
                        hit.seed     = cand.seed;
                        hit.timing   = cand;
                        hit.actStart = chainT;
                        break;
                    }
                    chainT = endT + cand.gap;
                }
                return hit;
            }

            // Resolves which stream of this lane's timeline (if any) is on `row` and
            // its brightness. trackSalt 0 = primary timeline, 1 = independent
            // secondary timeline.
            LaneStream EvalLaneStream(float col, float row, float rows, float trackSalt,
                                      float rainClock, float baseFall, float period,
                                      float worstMaxLen, float lenExponent, float baseMaxLen,
                                      float lengthEnvelope, float effSpectrumInfl, float audioNorm)
            {
                LaneStream ls;
                ls.sid = 0.0; ls.bright = 0.0; ls.headGlow = 0.0; ls.hueBias = 0.0; ls.active = false;

                float colKey    = col + trackSalt * 211.0;
                float laneSeedT = hash11(colKey * 12.9898 + 78.233); // == laneSeed for the primary track

                ChainHit hit = WalkChain(colKey, laneSeedT, rainClock, baseFall, period, rows, worstMaxLen, lenExponent);
                if (!hit.found) return ls;

                // Secondary timeline: only a fraction of its streams exist.
                if (trackSalt > 0.5 && hash11(hit.seed * 17.9 + 3.3) >= saturate(_SecondaryLayerChance)) return ls;

                // Lane-collision guard: a secondary stream may only start once whichever
                // stream is on the PRIMARY timeline at that instant has already fallen past
                // the screen's midline, so a fast stream can never visually fall into a slow
                // one sharing its lane. Evaluated at the candidate's own spawn instant (not
                // the current query time), so a stream's presence never flickers as the
                // query time moves across its lifetime -- it either exists from spawn or not
                // at all.
                if (trackSalt > 0.5)
                {
                    float genPosAtStart    = hit.g + hit.actStart / period;
                    float rainClockAtSpawn = (genPosAtStart - laneSeedT * 64.0) * period / max(baseFall, 0.001);

                    float primaryLaneSeedT  = hash11(col * 12.9898 + 78.233);
                    ChainHit primaryAtSpawn = WalkChain(col, primaryLaneSeedT, rainClockAtSpawn, baseFall,
                                                        period, rows, worstMaxLen, lenExponent);
                    if (primaryAtSpawn.found)
                    {
                        float primaryHeadRowAtSpawn = (primaryAtSpawn.localD - primaryAtSpawn.actStart)
                                                     * primaryAtSpawn.timing.speedRel - kHeadStart;
                        if (primaryHeadRowAtSpawn < rows * 0.5) return ls;
                    }
                }

                StreamTiming st = hit.timing;
                float actStart  = hit.actStart;
                float localD    = hit.localD;
                ls.sid = hit.sid + trackSalt * 0.5;

                // Spectrum may lengthen the VISUAL trail, never the timing/speed.
                float lengthT = saturate(st.lenHash + saturate(lengthEnvelope) * effSpectrumInfl);
                ls.hueBias = (hash11(st.seed * 9.31) * 2.0 - 1.0) * 0.15;

                // Continuous head position (smooth trail falloff) vs the single locked
                // row the head glyph occupies.
                float headRowContinuous = (localD - actStart) * st.speedRel - kHeadStart;
                float headRowSnapped    = floor(headRowContinuous);
                float distToHead        = headRowContinuous - row;

                // Code Overflow: bass peaks stretch the visual tail, capped at the
                // stream's timing budget so it can never be cut off by the next stream.
                float reactiveMaxLen    = baseMaxLen * lerp(1.0, 1.0 + _AudioTrailSwell, audioNorm);
                float reactiveStreamLen = min(lerp(6.0, reactiveMaxLen, lengthT), st.budgetLen);
                if (!(distToHead >= 0.0 && distToHead < reactiveStreamLen)) return ls;

                // Brightness falloff: near-head plateau, exponential body, then a
                // logarithmic phosphor fade to exactly zero over the last 10%.
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
                    const float kLogK = 9.0;
                    float logFade = log2(1.0 + (1.0 - fadeT) * kLogK) / log2(1.0 + kLogK);
                    bright = tailAnchorBright * logFade;
                }

                // Head overlay: a hard single-row test, exactly one white glyph per stream.
                ls.headGlow = (row == headRowSnapped) ? 1.0 : 0.0;
                bright = bright + ls.headGlow * (1.0 - bright);
                bright *= 0.80;

                ls.bright = bright;
                ls.active = true;
                return ls;
            }
            // ---- Single-occupancy cell model ----------------------------------------
            // The rain field is a rigid (cols x rows) grid and every screen pixel belongs
            // to exactly ONE grid cell. ResolveCellState() decides everything that is a
            // property of the CELL (which stream owns it, blank gap, its one glyph index,
            // rotation, color) exactly once per pixel. GlyphCoverage() then samples ONLY
            // that glyph's own atlas cell. Every secondary tap (CRT convergence, phosphor
            // bleed, glow) re-uses the home cell's state and is clamped inside the home
            // cell (ClampToHomeCell), so no pixel can ever show a second glyph.
            struct CellState
            {
                float3 color;      // glyph color for this cell (trail/head blend)
                float  lit;        // 1 = a stream owns this cell and it is not a blank gap
                float  glyphIndex; // the ONE atlas cell this grid cell may ever sample
                float  rotState;   // 0..3 locked 90-degree rotation of that glyph
                float2 grid;       // (cols, rows)
            };

            // Every falling stream is reconstructed purely from (uv, _Time.y) -- no
            // per-glyph objects, no CPU column state. `audioNorm` (0..1, pre-normalized
            // against _AudioFloor/_AudioCeiling) and `gs` (gameplay-state inputs, see
            // GameplayInputs above) are both sampled/decoded once in frag() and passed
            // in here rather than re-sampled per call.
            CellState ResolveCellState(float2 uv, float audioNorm, GameplayInputs gs)
            {
                CellState cs;

                // --- Grid & UV division driven by Glyph Scale ---
                float cols = max(4.0, round(_BaseColumns / max(_GlyphScale, 0.05)));
                float rows = max(4.0, round(cols / max(_AspectRatio, 0.01)));

                float colF  = uv.x * cols;
                float col   = floor(colF);

                // Flip UV.y so rain falls top -> bottom
                float rowF  = (1.0 - uv.y) * rows;
                float row   = floor(rowF);

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

                // --- Fall speed, chained stream timelines, tempo clock -----------------
                // Stream positions are a pure function of (uv, gs.rainClock). rainClock is
                // the tempo-integrated clock from frag() (falls back to _Time.y with no
                // song), so tempo changes only change the SLOPE of time and never snap the
                // field. FFT/RMS audio and the fail meter are still never read here.
                float baseFall = lerp(1.5, 34.0, saturate(_RainSpeed));

                // --- YARG Song Intro Reveal: blank during countdown, top-down cascade
                // reveal wavefront from the drop onward -- see the property comment and
                // GameplayInputs.introClock/introBlank above. Uses the continuous rowF
                // (not the floored row) so the wavefront's own edge is smoothly
                // anti-aliased via _IntroRevealSoftness rather than snapping cell-to-cell.
                float introMask;
                if (gs.introBlank > 0.5)
                {
                    introMask = 0.0;
                }
                else
                {
                    float wavefront   = gs.introClock * baseFall * max(_IntroRevealSpeedMult, 0.01);
                    float introEdge   = max(_IntroRevealSoftness, 0.001);
                    introMask = 1.0 - smoothstep(wavefront - introEdge, wavefront + introEdge, rowF);
                }

                // Visual length ceiling (static -- only the audio swell ever stretches it)...
                float baseMaxLen = lerp(8.0, rows * 0.9, saturate(_TrailLength));

                // ...vs the STATIC worst case used for timing (full audio swell).
                float worstMaxLen    = baseMaxLen * (1.0 + saturate(_AudioTrailSwell));
                float exponent       = pow(10.0, (0.5 - saturate(_LengthBias)) * 2.0);

                // Generation length: long enough for the slowest / longest possible stream.
                float lenInfl       = saturate(_LengthSpeedInfluence);
                float slowestFactor = min(lerp(1.0, _ShortColumnSpeed, lenInfl), lerp(1.0, _LongColumnSpeed, lenInfl));
                float longestTravel = rows + worstMaxLen + kClearMargin + kHeadStart;
                float period        = max(longestTravel / max(slowestFactor, 0.05), rows * 2.0);

                // Inverse Spectrum Analyzer: per-lane length envelope, ADDED on top of the
                // hash length (visual only -- never affects timing or speed).
                float lengthEnvelope = SAMPLE_TEXTURE2D_LOD(_SpectrumHoldTex, sampler_SpectrumHoldTex, float2((col + 0.5) / cols, 0.5), 0).r;
                float effectiveSpectrumInfluence = saturate(_SpectrumInfluence);

                // Single-occupancy resolve: the primary and (optional) secondary timelines
                // are two CANDIDATES for this one cell. Exactly one candidate survives (the
                // brighter; ties go to the primary) and the loser is discarded outright --
                // its glyph, color and brightness are never blended in. Everything below
                // (glyph index, gap, rotation, color) is derived from the survivor only.
                LaneStream S = EvalLaneStream(col, row, rows, 0.0, gs.rainClock, baseFall, period,
                                              worstMaxLen, exponent, baseMaxLen,
                                              lengthEnvelope, effectiveSpectrumInfluence, audioNorm);
                if (_SecondaryLayerChance > 0.001)
                {
                    LaneStream S2 = EvalLaneStream(col, row, rows, 1.0, gs.rainClock, baseFall, period,
                                                   worstMaxLen, exponent, baseMaxLen,
                                                   lengthEnvelope, effectiveSpectrumInfluence, audioNorm);
                    if (S2.active && (!S.active || S2.bright > S.bright)) S = S2;
                }

                bool  inStream  = S.active;
                float bright    = S.bright;
                float headGlow  = S.headGlow;
                float hueBias   = S.hueBias;
                float sidActive = S.sid;

                // --- Glyph Mutation ---
                float cellSeed = hash11(col * 31.7 + row * 57.13 + sidActive * 11.0 + 1.3);
                const float kFreezeFloor = 0.084 * 0.80;
                float energyNorm = saturate((bright - kFreezeFloor) / (1.0 - kFreezeFloor));
                float mutWeight  = (energyNorm > 0.0) ? pow(energyNorm, 3.0) * 4.0 : 0.0;

                float mutRateBase  = lerp(1.5, 7.0, saturate(_RainSpeed)) * lerp(0.0, 2.0, saturate(_MutationRate));

                // "Data Processing Load" (audio) stacks multiplicatively with the
                // fail-state scramble boost below -- both only ever scale how fast
                // glyphBucket increments, never a position, so this is safe to
                // drive directly by elapsed time the same way the unboosted rate
                // already does.
                float rmsNorm      = gs.rmsNorm; // hoisted to frag(): uv-independent, was re-sampled 17x per pixel
                float audioMutMult = 1.0 + _AudioMutationBoost * max(rmsNorm, laneAmpNorm);

                // Fail-state "scramble wildly in danger states": a second,
                // independent multiplier driven purely by failDriveShaped, so a
                // full-health quiet song and a near-death quiet song read
                // completely differently regardless of what's playing.
                float failMutMult  = 1.0 + _FailMutationBoost * gs.failDriveShaped;
                float localMutRate = mutRateBase * mutWeight * audioMutMult * failMutMult;
                float glyphBucket  = floor(_Time.y * max(localMutRate, 0.0001) + cellSeed * 97.0);

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


                cs.lit        = (inStream && !isGap) ? introMask : 0.0;
                cs.glyphIndex = glyphIndex;
                cs.rotState   = rotState;
                cs.grid       = float2(cols, rows);

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

                cs.color = glyphColor;
                return cs;
            }

            // Coverage of THE cell's one glyph at `uv`. `uv` must lie inside the home cell
            // (true for the center sample by construction, and for every tap via
            // ClampToHomeCell). Everything is expressed in this cell's own local
            // (cellU, cellV) space, so no sample can reach another cell:
            //   * a positive gap only ever shrinks the glyph inside its own cell,
            //   * a negative gap (the one explicit, requested exception to single-occupancy
            //     footprint-clipping -- see the Cell Spacing property comment above) instead
            //     magnifies it, which can visually overlap neighbors on purpose,
            //   * atlas UV is clamped strictly inside this glyph's OWN atlas cell and read
            //     at LOD 0, so no neighboring atlas glyph can bleed in at the edges
            //     (rotated glyphs used to hit innerUV == 1.0 exactly, i.e. the border
            //     texel of the NEXT atlas cell).
            float GlyphCoverage(CellState cs, float2 uv)
            {
                const float kAtlasCellInset = 0.002; // fraction of one atlas cell

                float cellU = frac(uv.x * cs.grid.x);
                float cellV = frac((1.0 - uv.y) * cs.grid.y);

                // Locked 90-degree rotation about the cell midpoint (maps [0,1]^2 onto itself).
                float2 r = float2(cellU, cellV);
                if (cs.rotState > 0.5 && cs.rotState < 1.5)      r = float2(cellV, 1.0 - cellU);        // 90
                else if (cs.rotState > 1.5 && cs.rotState < 2.5) r = float2(1.0 - cellU, 1.0 - cellV);   // 180
                else if (cs.rotState > 2.5)                      r = float2(1.0 - cellV, cellU);        // 270
                cellU = r.x;
                cellV = r.y;

                // Clamp floor matches the property's Range minimum -- kept as a defensive
                // clamp (not just the Range slider) so a value driven in from a script can't
                // push the denominator below in the innerUV divide two lines down.
                float gapX = clamp(_CellGapX, -1.0, 0.49);
                float gapY = clamp(_CellGapY, -1.0, 0.49);

                float boundsMask = aastep(gapX, cellU) * (1.0 - aastep(1.0 - gapX, cellU))
                                 * aastep(gapY, cellV) * (1.0 - aastep(1.0 - gapY, cellV));

                float2 innerUV = float2(
                    (cellU - gapX) / max(1.0 - 2.0 * gapX, 0.0001),
                    (cellV - gapY) / max(1.0 - 2.0 * gapY, 0.0001));
                innerUV = clamp(innerUV, kAtlasCellInset, 1.0 - kAtlasCellInset);

                float atlasCols = max(1.0, _AtlasGridSize.x);
                float atlasRows = max(1.0, _AtlasGridSize.y);
                float aCol = fmod(cs.glyphIndex, atlasCols);
                float aRow = floor(cs.glyphIndex / atlasCols);
                float2 atlasUV = (float2(aCol, aRow) + innerUV) / float2(atlasCols, atlasRows);

                // Sampling .r because the atlas is white-on-black, not alpha-transparent.
                float cov = SAMPLE_TEXTURE2D_LOD(_FontAtlas, sampler_FontAtlas, atlasUV, 0).r;
                return cov * boundsMask * cs.lit;
            }

            // Clamps a tap position into the INTERIOR of the cell that `homeUV` lies in
            // (kEdge keeps it strictly off the shared border). Used for every secondary
            // tap so CRT fringing / phosphor bleed / glow can only ever re-sample the home
            // cell's own glyph -- never a neighbor's.
            float2 ClampToHomeCell(CellState cs, float2 tapUV, float2 homeUV)
            {
                const float kEdge = 0.002; // fraction of one grid cell
                float homeCol = floor(homeUV.x * cs.grid.x);
                float homeRow = floor((1.0 - homeUV.y) * cs.grid.y);
                float tx = clamp(tapUV.x * cs.grid.x,          homeCol + kEdge, homeCol + 1.0 - kEdge);
                float ty = clamp((1.0 - tapUV.y) * cs.grid.y,  homeRow + kEdge, homeRow + 1.0 - kEdge);
                return float2(tx / cs.grid.x, 1.0 - ty / cs.grid.y);
            }

            // Home-cell glyph at a (clamped) tap position, blended over _BackgroundColor --
            // the lerp every CRT tap needs.
            float3 HomeBlended(CellState cs, float2 tapUV, float2 homeUV)
            {
                float cov = GlyphCoverage(cs, ClampToHomeCell(cs, tapUV, homeUV));
                return lerp(_BackgroundColor.rgb, cs.color, cov);
            }

            half4 frag(Varyings IN) : SV_Target
            {
                float2 uv = IN.uv;

                // Sampled once per pixel and reused everywhere below (center cell
                // + all 16 glow taps) -- see the SampleAudioEnergy()/ResolveCellState()
                // comments above for why this used to be redundantly re-sampled
                // per call and why that was unnecessary (the value has no uv
                // dependency at all).
                float audioEnergy = SampleAudioEnergy();
                float audioNorm   = saturate((audioEnergy - _AudioFloor) / max(_AudioCeiling - _AudioFloor, 1e-4));

                // --- YARG gameplay state, decoded once per pixel ---------------------
                // Editor-authoring aid: lets the material preview the full fail-
                // state ramp by hand while editing, without a live YARG session
                // feeding _Yarg_GameStateTex (which is unbound/all-zero outside a real song --
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
                gs.beatPulse = beatPulse;
                gs.goldBlend = goldBlend;

                // Loudness (uv-independent) and the tempo-synced rain clock, decoded once.
                float rmsEnergy = SampleWaveformRMS();
                gs.rmsNorm = saturate((rmsEnergy - _RMSFloor) / max(_RMSCeiling - _RMSFloor, 1e-4));

                // --- YARG Song Intro Reveal: decoded once, see the property comment above ---
                if (_UseEditorPreviewIntro > 0.5)
                {
                    gs.introClock = max(_EditorPreviewIntroTime, 0.0);
                    gs.introBlank = (_EditorPreviewIntroTime < 0.0) ? 1.0 : 0.0;
                }
                else
                {
                    float songLenTx  = YargGameState(0);
                    float songTimeTx = YargGameState(1);
                    bool  hasSongTx  = songLenTx > 0.0; // same "unbound texture" gate YargFailMeter() uses
                    if (hasSongTx)
                    {
                        gs.introClock = max(songTimeTx, 0.0);
                        gs.introBlank = (songTimeTx < 0.0) ? 1.0 : 0.0;
                    }
                    else
                    {
                        gs.introClock = 1e6; // no real song -- effectively "long since the drop", never blank
                        gs.introBlank = 0.0;
                    }
                }

                // No CRT bound / not running yet (B == 0) -> plain _Time.y, i.e. the
                // normal default fall rate. _TempoInfluence blends between the fixed
                // clock and the tempo-integrated one (the mix is itself a continuous
                // clock, so changing it never snaps).
                float4 tempoState = SAMPLE_TEXTURE2D_LOD(_TempoClockTex, sampler_TempoClockTex, float2(0.5, 0.5), 0);
                float tempoClock  = (tempoState.b > 0.0001) ? tempoState.r : _Time.y;
                gs.rainClock = lerp(_Time.y, tempoClock, saturate(_TempoInfluence));

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
                // Each channel is sampled via HomeBlended(), i.e. a SEPARATE glyph-coverage
                // sample of the SAME home cell, with the tap position clamped inside that
                // cell. Coverage -- not just color -- therefore differs per channel near
                // stroke edges (real fringing rather than a flat channel shift), but a
                // channel can never pick up a NEIGHBORING cell's glyph. R/B taps are
                // skipped entirely when both sliders are at their default 0.
                float2 caCenter    = uvBase - 0.5;
                float  caEdge      = dot(caCenter, caCenter);
                float2 caDir       = normalize(caCenter + 1e-5);
                float2 radialOff   = caDir * _CRTChromaticAberration * caEdge;
                float2 convergeOff = float2(_CRTConvergenceFringing * caEdge, 0.0);
                float2 offR        = radialOff + convergeOff;
                float2 offB        = -offR;

                // The ONE cell (and glyph) this pixel belongs to. All taps below reuse it.
                CellState home = ResolveCellState(uvBase, audioNorm, gs);
                float3 blendedG = lerp(_BackgroundColor.rgb, home.color, GlyphCoverage(home, uvBase));
                float3 blendedR = blendedG;
                float3 blendedB = blendedG;
                if (_CRTChromaticAberration > 0.0001 || _CRTConvergenceFringing > 0.0001)
                {
                    blendedR = HomeBlended(home, uvBase + offR, uvBase);
                    blendedB = HomeBlended(home, uvBase + offB, uvBase);
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

                    float3 bm2 = HomeBlended(home, uvBase - stepUV * 2.0, uvBase);
                    float3 bm1 = HomeBlended(home, uvBase - stepUV,       uvBase);
                    float3 bp1 = HomeBlended(home, uvBase + stepUV,       uvBase);
                    float3 bp2 = HomeBlended(home, uvBase + stepUV * 2.0, uvBase);

                    float3 bled = bm2 * 0.06 + bm1 * 0.18 + baseRGB * 0.52 + bp1 * 0.18 + bp2 * 0.06;
                    baseRGB = lerp(baseRGB, bled, saturate(_CRTPhosphorBleed));
                }

                // ---------------------------------------------------------------
                // Embedded glow. There is no separate scene-color render target to
                // blur here (this is a single unlit pass on one background quad,
                // not a full-screen post effect), so instead of a real mip-chain
                // blur this re-samples the home cell's glyph at a small ring of nearby
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
                    // Perf: 4 cardinal directions instead of 8 (dropped the diagonals)
                    // halves this ring's font-atlas taps (16 -> 8: 4 dirs x near+far)
                    // for a small-radius halo approximation where the diagonals added
                    // the least distinguishable shape information per sample.
                    const float2 kDirs[4] = {
                        float2( 1.0,  0.0), float2(-1.0,  0.0),
                        float2( 0.0,  1.0), float2( 0.0, -1.0)
                    };
                    float lo = _GlowThreshold - 0.3;
                    float hi = _GlowThreshold + 0.3;
                    float homeLum = dot(home.color, float3(0.299, 0.587, 0.114));

                    [unroll]
                    for (int i = 0; i < 4; i++)
                    {
                        float2 dir = kDirs[i];

                        // Every ring tap is clamped inside the home cell: the halo is this
                        // glyph's own glow and can never paint a neighbor's shape over
                        // another cell's glyph.
                        float nearCov = GlyphCoverage(home, ClampToHomeCell(home, uvBase + dir * _GlowRadius, uvBase));
                        glow += home.color * smoothstep(lo, hi, homeLum * nearCov);

                        float farCov = GlyphCoverage(home, ClampToHomeCell(home, uvBase + dir * _GlowRadius * 2.5, uvBase));
                        glow += home.color * smoothstep(lo, hi, homeLum * farCov) * 0.5;
                    }
                    glow *= effectiveGlowIntensity / 4.0;
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

                // --- CRT scanlines + beam-pulse refresh sweep -------------------------
                // Adapted from MatrixReflow's crt_filter horizontal raster gaps,
                // DRAMATIZED the same way as the slot mask above: a deeper trough
                // (0.72..1.0 -> 0.30..1.0, a 70% swing instead of 28%) and a wider
                // kScanlinePx pitch so individual lines read as chunky and obvious
                // rather than a fine, subtle texture. scanY (the unwrapped pixel-
                // space coordinate, before frac()) drives an fwidth()-based adaptive
                // transition width instead of a fixed smoothstep edge, so the bands
                // stay clean under camera movement/perspective instead of shimmering
                // (procedural AA, same idea as aastep() above). The beam spot widens
                // under bright glyph strokes (phosphor blooming into the raster gaps),
                // so the trough shallows out with local luminance instead of a flat
                // scanline depth everywhere.
                float sharpLum   = dot(finalRGB, float3(0.299, 0.587, 0.114));
                const float kScanlinePx = 3.0;
                float scanY      = IN.positionCS.y / kScanlinePx;
                float scanPhase  = frac(scanY);
                float scanShape  = 1.0 - abs(scanPhase * 2.0 - 1.0);
                float scanAA     = max(fwidth(scanY), 1e-4);
                float scanTrough = lerp(0.30, 0.85, saturate(_CRTBeamBloom * sharpLum * 1.25));
                float scanline   = lerp(scanTrough, 1.0, smoothstep(0.5 - scanAA, 0.5 + scanAA, scanShape));
                float lineRipple = 0.94 + 0.06 * sin(IN.positionCS.y * 1.7 + _Time.y * 0.6);
                scanline *= lineRipple;
                float scanlineMask = lerp(1.0, scanline, saturate(_CRTScanlineIntensity));
                finalRGB *= scanlineMask;

                // Slow top-to-bottom refresh sweep -- the classic "beam pulse" look of an
                // old green terminal (Fallout 3/New Vegas Pip-Boy style): just after the
                // scanning beam passes, phosphor is at full brightness and decays
                // exponentially until the beam returns; the leading edge is softened over
                // 6% of the sweep cycle. Normalized by the mean of the decay curve so
                // average brightness is unchanged as the sweep passes over. No extra
                // texture fetches -- a handful of scalar ops, skipped entirely at 0.
                if (_CRTPhosphorDecay > 0.0001)
                {
                    const float kPersistRate  = 3.0;
                    const float kPersistFloor = 0.049787068; // exp(-3)
                    const float kPersistMean  = 0.316737;    // (1 - exp(-3)) / 3
                    float sweepAge = frac(frac(_Time.y * _CRTRefreshRate) - (1.0 - uvBase.y));
                    float persist  = lerp(kPersistFloor, exp(-kPersistRate * sweepAge), smoothstep(0.0, 0.06, sweepAge));
                    float decayAmt = saturate(_CRTPhosphorDecay);
                    finalRGB *= (1.0 - decayAmt * (1.0 - persist)) / (1.0 - decayAmt * (1.0 - kPersistMean));
                }

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

                // --- Analog Signal Static (audio-independent, desync-linked) --------
                // Same failDriveShaped driver as every other term on this page:
                // exactly 0 grain at full health, scaling up proportionately as
                // the meter empties. Screen-locked (IN.positionCS, not uvBase) so
                // it reads as noise riding on top of the picture rather than
                // being warped along with the barrel/tear UV distortion.
                float staticAmt = _StaticNoiseIntensity * failDriveShaped;
                if (staticAmt > 0.0001)
                {
                    float grain = StaticNoise(IN.positionCS.xy, _StaticNoiseScale, _Time.y);
                    finalRGB = saturate(finalRGB + grain * staticAmt);
                }

                // Blend the tear band's bright scanning leading edge in last,
                // on top of every CRT post pass above (slot mask/scanlines/
                // black-level/vignette/static) -- mimics a scanning flash riding
                // visibly ON TOP of its own screen static, rather than being
                // another texture the CRT passes would just dim back down.
                finalRGB = saturate(finalRGB + _GlitchFlashColor.rgb * glitchFlash);

                return half4(finalRGB, 1.0);
            }
            ENDHLSL
        }
    }
}
