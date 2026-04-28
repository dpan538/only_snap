import CoreImage
import Accelerate
import Metal

/// Colour-processing modes.
enum ColorMode {
    case normal
    case experimental
}

/// Applies a colour transform to a `CIImage`.
enum ColorProcessor {

    // MARK: - Shared context (one GPU context for all analysis)

    private static let analysisCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // RY atmosphere 3-D LUT — built once, reused for every photo
    private static var ryLUTCache: Data?
    private static let ryLUTDim = 33     // 33³ = 35 937 entries; good balance of accuracy/speed

    // MARK: - Scene Analysis Struct

    /// Full scene metrics computed before any colour grading is applied.
    /// Derived once per photo from the raw sensor data and consumed throughout
    /// the pipeline — no repeated GPU dispatches.
    private struct SceneAnalysis {
        let kelvin:         CGFloat  // estimated CCT  2 500 – 9 000 K
        let luminance:      CGFloat  // weighted average perceptual brightness  0…1
        let avgR:           CGFloat  // weighted R (center×0.6 + full×0.4)
        let avgG:           CGFloat  // weighted G
        let avgB:           CGFloat  // weighted B
        let satScore:       CGFloat  // (max−min)/max  0…1  color richness
        let highlightRatio: CGFloat  // top-area average luminance — proxy for sky/sun intensity
        let hazeScore:      CGFloat  // min(R,G,B)/max(R,G,B)  higher = more haze or overexposure
        let isBacklit:      Bool     // center luminance < 55% of full-image luminance

        // ── Semantic convenience flags ───────────────────────────────────────
        /// Golden-hour / sunrise: very warm light with active highlights.
        var isSunset:    Bool { kelvin < 3600 && highlightRatio > 0.30 && luminance > 0.25 }
        /// Very low ambient light.
        var isNight:     Bool { luminance < 0.15 }
        /// Haze / mist / fog: all channels elevated relative to each other.
        var isFoggy:     Bool { hazeScore > 0.38 && luminance > 0.32 }
        /// Rain or snow: cool, desaturated, moderate brightness.
        var isRainSnow:  Bool {
            kelvin > 6300 && satScore < 0.18 && luminance > 0.25 && luminance < 0.75
        }
    }

    // MARK: - Public entry point

    static func process(image: CIImage, mode: ColorMode, focalLength: Int = 35) -> CIImage {
        let processed: CIImage
        switch mode {
        case .normal:
            processed = image
        case .experimental:
            // skipPreSmooth: 105mm has its own CINoiseReduction + the universal post-upscale
            // denoise in CameraManager. Running the 0.01 pre-smooth too would stack three
            // passes and visibly over-blur telephoto output.
            processed = applyExperimentalCurve(to: image, skipPreSmooth: focalLength == 105)
        }
        return focalLength == 105 ? apply105mmEnhancement(to: processed) : processed
    }

    // MARK: - Multi-zone Scene Analysis

    /// Samples three image zones, computes weighted averages, and returns a full
    /// `SceneAnalysis` for use throughout the grading pipeline.
    ///
    /// Zones (all rendered via GPU CIAreaAverage):
    ///   • Center  40%×40%  weight 0.60 — subject / main element
    ///   • Full image       weight 0.40 — ambient / background
    ///   • Top    60%×25%               — sky / highlights proxy (separate metric)
    ///
    /// Weighting prevents large sky areas from "hijacking" the scene classification
    /// (the old 1×1 single-average problem that caused over-warming on sunset shots
    ///  and under-correction on portraits against bright windows).
    private static func analyzeImage(_ image: CIImage) -> SceneAnalysis {
        let ext = image.extent
        // Safe fallback for degenerate extents
        let fallback = SceneAnalysis(kelvin: 4593, luminance: 0.5,
                                     avgR: 0.5, avgG: 0.5, avgB: 0.5,
                                     satScore: 0.2, highlightRatio: 0.4,
                                     hazeScore: 0.1, isBacklit: false)
        guard ext.width > 4, ext.height > 4 else { return fallback }

        // ── Zone extents ──────────────────────────────────────────────────────
        let cw = ext.width  * 0.40
        let ch = ext.height * 0.40
        let centerExt = CGRect(x: ext.midX - cw * 0.5, y: ext.midY - ch * 0.5,
                               width: cw, height: ch)
        let fullExt   = ext
        let topExt    = CGRect(x: ext.midX - ext.width * 0.30,
                               y: ext.maxY - ext.height * 0.25,
                               width: ext.width * 0.60,
                               height: ext.height * 0.25)

        // ── Fast GPU sample ───────────────────────────────────────────────────
        func sample(_ rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
            guard let f = CIFilter(name: "CIAreaAverage",
                                   parameters: [kCIInputImageKey:  image,
                                                kCIInputExtentKey: CIVector(cgRect: rect)]),
                  let out = f.outputImage else { return nil }
            var px = [UInt8](repeating: 0, count: 4)
            analysisCIContext.render(out, toBitmap: &px, rowBytes: 4,
                                     bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                                     format: .RGBA8,
                                     colorSpace: CGColorSpaceCreateDeviceRGB())
            return (CGFloat(px[0]) / 255.0,
                    CGFloat(px[1]) / 255.0,
                    CGFloat(px[2]) / 255.0)
        }

        guard let cs = sample(centerExt), let fs = sample(fullExt) else { return fallback }
        let ts = sample(topExt)  // optional; graceful fallback if nil

        // ── Weighted primary RGB ──────────────────────────────────────────────
        let r = cs.r * 0.60 + fs.r * 0.40
        let g = cs.g * 0.60 + fs.g * 0.40
        let b = cs.b * 0.60 + fs.b * 0.40

        // ── Colour temperature — piecewise R/B → CCT ─────────────────────────
        // More accurate than the old linear interpolation: accounts for the
        // non-linear relationship between raw R/B ratio and correlated CCT.
        let rb = r / max(b, 0.001)
        let kelvin: CGFloat = {
            switch rb {
            case ..<0.55:        return 9000
            case 0.55 ..< 0.80: return lerp(9000, 7000, t: (rb - 0.55) / 0.25)
            case 0.80 ..< 1.05: return lerp(7000, 6000, t: (rb - 0.80) / 0.25)
            case 1.05 ..< 1.35: return lerp(6000, 5000, t: (rb - 1.05) / 0.30)
            case 1.35 ..< 1.75: return lerp(5000, 4000, t: (rb - 1.35) / 0.40)
            case 1.75 ..< 2.30: return lerp(4000, 3000, t: (rb - 1.75) / 0.55)
            default:             return 2500
            }
        }()

        // ── Luminance ─────────────────────────────────────────────────────────
        let lum      = 0.2126 * r      + 0.7152 * g      + 0.0722 * b
        let centerL  = 0.2126 * cs.r   + 0.7152 * cs.g   + 0.0722 * cs.b
        let fullL    = 0.2126 * fs.r   + 0.7152 * fs.g   + 0.0722 * fs.b

        // ── Saturation score ─────────────────────────────────────────────────
        // (max − min) / max: measures colour richness independent of brightness.
        let maxC     = max(r, g, b)
        let minC     = min(r, g, b)
        let satScore = maxC > 0.01 ? (maxC - minC) / maxC : 0.0

        // ── Highlight proxy (top-area luminance) ─────────────────────────────
        let highlightRatio: CGFloat = ts.map {
            0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b
        } ?? lum

        // ── Haze / fog proxy ─────────────────────────────────────────────────
        // If the minimum channel is elevated relative to maximum, the whole
        // scene is "lifted" uniformly — the hallmark of haze, mist, or fog.
        let hazeScore = maxC > 0.01 ? minC / maxC : 0.0

        // ── Backlight detection ───────────────────────────────────────────────
        // Subject (center) is significantly darker than the overall scene.
        let isBacklit = fullL > 0.06 && centerL < fullL * 0.55

        return SceneAnalysis(kelvin:        kelvin,
                             luminance:     lum,
                             avgR:          r,
                             avgG:          g,
                             avgB:          b,
                             satScore:      satScore,
                             highlightRatio: highlightRatio,
                             hazeScore:     hazeScore,
                             isBacklit:     isBacklit)
    }

    // MARK: - Experimental tone curve (calibrated, adaptive)

    /// Full RY warm-film pipeline for saved stills.
    ///
    /// Stages:
    ///   0. Optional pre-smooth (skipped for 105mm)
    ///   1. Dynamic warm matrix — strength bell-curves with colour temperature
    ///   2. CIToneCurve — film S-curve
    ///   3. Adaptive saturation — dull scenes boosted, vivid scenes left alone
    ///   4. Subtle split toning — cool shadows / warm highlights (CIColorPolynomial)
    ///   5. Dynamic bloom — attenuated when highlights are intense; boosted when flat
    ///   6. Scene-adaptive correction — per-scene fine-tuning (sunset, night, fog, etc.)
    ///
    /// All scene metrics are computed ONCE on the raw image (before grading) so that
    /// the classification reflects true ambient light, not our colour additions.
    private static func applyExperimentalCurve(to image: CIImage,
                                                skipPreSmooth: Bool = false) -> CIImage {

        // ── 0. Pre-smooth ────────────────────────────────────────────────────
        let baseImage: CIImage
        if !skipPreSmooth, let f = CIFilter(name: "CINoiseReduction") {
            f.setValue(image, forKey: kCIInputImageKey)
            f.setValue(0.01, forKey: "inputNoiseLevel")
            f.setValue(0.0,  forKey: "inputSharpness")
            baseImage = f.outputImage ?? image
        } else {
            baseImage = image
        }

        // ── Scene analysis (pre-grading) ─────────────────────────────────────
        let scene = analyzeImage(image)

        // ── 1. Dynamic warm matrix ────────────────────────────────────────────
        //
        // Warmth strength is a bell curve:
        //   kelvin ≤ 3000 K → warmStrength = 0.0  (very warm scene: avoid double-heating)
        //   kelvin ~ 5000 K → warmStrength = 1.0  (neutral daylight: apply full warm look)
        //   kelvin ≥ 7500 K → warmStrength = 0.0  (overcast: handled by separate path)
        //
        // Rising edge: smoothstep 3000→5000 K
        // Falling edge: 1 − smoothstep 5000→7500 K
        // Sunset boost: isSunset scenes keep warmth (don't attenuate the golden hour)
        // Night damp:   very dark scenes get reduced warmth (amplifies noise)
        let rise    = smoothstep(lo: 3000, hi: 5000, t: scene.kelvin)
        let fall    = 1.0 - smoothstep(lo: 5000, hi: 7500, t: scene.kelvin)
        let rawWarm = rise * fall
        let warmStrength = (rawWarm
            * (scene.isNight   ? 0.35 : 1.0)   // night: damp to 35%
            * (scene.isSunset  ? 1.3  : 1.0)   // sunset: boost warm (clamp to 1 below)
        ).clamped(to: 0...1)

        let rScale = 1.0 + 0.05 * warmStrength   // R: modest warm boost
        let bScale = 1.0 - 0.10 * warmStrength   // B: modest reduction (keeps foliage green)

        guard let matFilter = CIFilter(name: "CIColorMatrix") else { return baseImage }
        matFilter.setValue(baseImage, forKey: kCIInputImageKey)
        // R: warm boost; cross-channel −0.03·B preserves sky purity
        matFilter.setValue(CIVector(x: rScale, y: 0.00, z: -0.03 * warmStrength, w: 0),
                           forKey: "inputRVector")
        // G: near-neutral; cross-channel reduced to −0.01·B (was −0.03) to prevent
        // over-pulling green from blue pixels which caused cyan sky artefacts.
        matFilter.setValue(CIVector(x: 0.00, y: 0.98, z: -0.01 * warmStrength, w: 0),
                           forKey: "inputGVector")
        // B: modest reduction; −0.04·R bleed warms deep shadows
        matFilter.setValue(CIVector(x: -0.04 * warmStrength, y: 0.00, z: bScale, w: 0),
                           forKey: "inputBVector")
        matFilter.setValue(CIVector(x: 0.00, y: 0.00, z: 0.00, w: 1), forKey: "inputAVector")
        // Warm bias in blacks (barely perceptible — prevents pure cold shadows)
        matFilter.setValue(CIVector(x: 0.006 * warmStrength, y: 0.003 * warmStrength,
                                    z: 0.000, w: 0),
                           forKey: "inputBiasVector")
        guard let matOut = matFilter.outputImage else { return baseImage }

        // ── 2. Film tone curve ───────────────────────────────────────────────
        guard let toneFilter = CIFilter(name: "CIToneCurve") else { return matOut }
        toneFilter.setValue(matOut, forKey: kCIInputImageKey)
        toneFilter.setValue(CIVector(x: 0.00, y: 0.000), forKey: "inputPoint0")
        toneFilter.setValue(CIVector(x: 0.25, y: 0.210), forKey: "inputPoint1")
        toneFilter.setValue(CIVector(x: 0.50, y: 0.500), forKey: "inputPoint2")
        toneFilter.setValue(CIVector(x: 0.75, y: 0.780), forKey: "inputPoint3")
        toneFilter.setValue(CIVector(x: 1.00, y: 0.940), forKey: "inputPoint4")
        guard let toneOut = toneFilter.outputImage else { return matOut }

        // ── 2b. RY Atmosphere LUT — per-hue colour remap ─────────────────────
        //
        // A 33³ CIColorCube built once in ryAtmosphereLUT() and applied post
        // tone-curve (perceptually balanced values).  Each hue band gets its
        // own shift + saturation/value multiplier:
        //
        //   red/orange/yellow → warmer, more saturated (film amber)
        //   green             → warmer, more vibrant
        //   cyan  (165–200°)  → shifted −10° toward pure blue  ← sky/water fix
        //   blue              → richer cobalt (+3°, sat ×1.10)
        //   magenta           → suppressed (sat ×0.96)         ← overflow fix
        //
        // Night scenes skip the LUT to avoid amplifying colour noise.
        let lutOut: CIImage
        if !scene.isNight,
           let lutData = ryAtmosphereLUT(),
           let cube = CIFilter(name: "CIColorCube") {
            cube.setValue(ryLUTDim, forKey: "inputCubeDimension")
            cube.setValue(lutData,  forKey: "inputCubeData")
            cube.setValue(toneOut,  forKey: kCIInputImageKey)
            lutOut = cube.outputImage ?? toneOut
        } else {
            lutOut = toneOut
        }

        // ── 3. Adaptive saturation ────────────────────────────────────────────
        //
        // Scene satScore drives the output saturation:
        //   Gray/dull (satScore ~ 0.0) → targetSat up to 1.06 (lift colour)
        //   Already vivid (satScore ~ 1.0) → targetSat ~ 0.84 (leave alone)
        //
        // Night cap: capped at 0.86 to avoid amplifying noise as coloured grain.
        // Sunset boost: + 0.05 to enrich golden colours.
        let targetSat = (0.84 + (1.0 - scene.satScore) * 0.22)
            .clamped(to: 0.76...1.10)
        let finalSat: CGFloat
        if scene.isNight {
            finalSat = min(targetSat, 0.86)
        } else if scene.isSunset {
            finalSat = min(targetSat + 0.05, 1.12)
        } else {
            finalSat = targetSat
        }

        guard let satFilter = CIFilter(name: "CIColorControls") else { return lutOut }
        satFilter.setValue(lutOut, forKey: kCIInputImageKey)
        satFilter.setValue(finalSat, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0,      forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.0,      forKey: kCIInputContrastKey)
        let satOut = satFilter.outputImage ?? toneOut

        // ── 4. Split toning (CIColorPolynomial) ──────────────────────────────
        //
        // Shadows: slight cool/blue lean (0, -0.01, +0.008) — film-like cool depth
        // Highlights: slight warm/orange lean (+0.010, -0.003, -0.010) — golden air
        //
        // CIColorPolynomial: out = a + b·in + c·in² + d·in³
        //   At in=0 (black):   out ≈ a      → shadow tint
        //   At in=1 (white):   out = a+b+c+d → shadow tint + linear + highlight delta
        //   For identity: a=0, b=1, c=0, d=0
        //   For shadow-only shift a: a + b=1, c=0, d=0 → dark pixels shift by a ✓
        //   For highlight-only shift h: a=0, b=1, c=0, d=h (cubic: near 0 for darks, ~h for whites) ✓
        //
        // Strength is gated — night/fog skip split toning (noise risk).
        let splitOut: CIImage
        if !scene.isNight, !scene.isFoggy,
           let poly = CIFilter(name: "CIColorPolynomial") {
            let strength: CGFloat = scene.isSunset ? 1.4 : 1.0
            // Shadow R: slightly cool (small negative shadow push)
            let sR: CGFloat = -0.010 * strength
            // Shadow B: slightly cool (small positive → bluer shadows)
            let sB: CGFloat =  0.008 * strength
            // Highlight R delta above identity
            let hR: CGFloat =  0.012 * strength
            // Highlight B delta above identity
            let hB: CGFloat = -0.010 * strength

            poly.setValue(satOut, forKey: kCIInputImageKey)
            poly.setValue(CIVector(x: sR,  y: 1.0, z: 0.0, w: hR - sR),
                          forKey: "inputRedCoefficients")
            poly.setValue(CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0.0),
                          forKey: "inputGreenCoefficients")
            poly.setValue(CIVector(x: sB,  y: 1.0, z: 0.0, w: hB - sB),
                          forKey: "inputBlueCoefficients")
            poly.setValue(CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0.0),
                          forKey: "inputAlphaCoefficients")
            splitOut = poly.outputImage ?? satOut
        } else {
            splitOut = satOut
        }

        // ── 5. Dynamic bloom ─────────────────────────────────────────────────
        //
        // Bloom intensity is not fixed — it responds to the scene:
        //   Hot highlights (sky/sun > 0.65 lum proxy) → attenuate (avoid blown halos)
        //   Flat/dull scene (low satScore, not foggy)  → boost (add depth and air)
        //   Night                                      → skip (glare noise amplification)
        let bloomOut: CIImage
        if !scene.isNight, let bloomFilter = CIFilter(name: "CIBloom") {
            let highlightDamp: CGFloat = scene.highlightRatio > 0.65
                ? (1.0 - ((scene.highlightRatio - 0.65) / 0.35)).clamped(to: 0.25...1.0)
                : 1.0
            let flatBoost: CGFloat = (scene.satScore < 0.15 && !scene.isFoggy) ? 1.25 : 1.0
            let bloomIntensity = (0.14 * highlightDamp * flatBoost).clamped(to: 0.04...0.22)

            bloomFilter.setValue(splitOut,       forKey: kCIInputImageKey)
            bloomFilter.setValue(10.0,           forKey: kCIInputRadiusKey)
            bloomFilter.setValue(bloomIntensity, forKey: kCIInputIntensityKey)
            bloomOut = bloomFilter.outputImage ?? splitOut
        } else {
            bloomOut = splitOut
        }

        // ── 6. Scene-adaptive correction ─────────────────────────────────────
        return applyAdaptiveCorrection(to: bloomOut, scene: scene)
    }

    // MARK: - Adaptive Correction (expanded scene coverage)

    /// Per-scene fine-tuning applied AFTER the main colour grade.
    ///
    /// Priority order (first match wins — scenes are mutually exclusive at thresholds):
    ///   0. Degenerate / single-colour fallback
    ///   1. Night / very low light
    ///   2. Sunset / sunrise (warm, DO NOT counter-correct)
    ///   3. Fog / haze
    ///   4. Rain / snow
    ///   5. Backlit subject (shadow lift only)
    ///   6. Overcast / cold
    ///   7. Green-dominant (foliage, parks)
    ///   8. Warm indoor / tungsten
    ///   9. Standard neutral — fine-tune toward reference 4593 K
    private static func applyAdaptiveCorrection(to image: CIImage,
                                                 scene: SceneAnalysis) -> CIImage {

        let kelvin    = scene.kelvin
        let luminance = scene.luminance
        let avgR      = scene.avgR
        let avgG      = scene.avgG
        let avgB      = scene.avgB

        // Shared scale that damps ALL corrections near extreme brightness values,
        // where the pipeline already operates at its limits.
        let correctionScale: CGFloat = {
            if luminance < 0.18 { return (luminance / 0.18).clamped(to: 0...1) }
            if luminance > 0.70 { return (1.0 - (luminance - 0.70) / 0.30).clamped(to: 0...1) }
            return 1.0
        }()

        // ── 0. Degenerate / monochrome fallback ──────────────────────────────
        let maxC = max(avgR, avgG, avgB)
        let minC = min(avgR, avgG, avgB)
        if maxC < 0.03 || (maxC - minC) < 0.015 {
            // Near-black or near-monochrome — skip colour corrections to avoid
            // introducing visible tints into what is effectively a grey image.
            return image
        }

        // ── 1. Night / very low light ─────────────────────────────────────────
        // Slightly lift the black point in all three channels so pure-black noise
        // doesn't crush to digital black.  Warmth is already attenuated upstream.
        if scene.isNight {
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 1.0, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 0,   w: 1), forKey: "inputAVector")
            // Warm-neutral black-point lift: prevents total crush in deep shadows
            mat.setValue(CIVector(x: 0.012, y: 0.009, z: 0.007, w: 0),
                         forKey: "inputBiasVector")
            return mat.outputImage ?? image
        }

        // ── 2. Sunset / sunrise ───────────────────────────────────────────────
        // The dynamic warm matrix already captured the golden light.  This pass
        // enriches saturation slightly rather than counter-correcting warmth —
        // the classic mistake that turns golden hour into a grey soup.
        if scene.isSunset {
            guard let sat = CIFilter(name: "CIColorControls") else { return image }
            sat.setValue(image, forKey: kCIInputImageKey)
            sat.setValue(1.10, forKey: kCIInputSaturationKey)
            sat.setValue(0.0,  forKey: kCIInputBrightnessKey)
            sat.setValue(1.0,  forKey: kCIInputContrastKey)
            return sat.outputImage ?? image
        }

        // ── 3. Fog / haze ─────────────────────────────────────────────────────
        // All channels are elevated uniformly.  Boost contrast and gently lower
        // mid-tone brightness to simulate a simple dehaze pass.
        if scene.isFoggy {
            guard let cc = CIFilter(name: "CIColorControls") else { return image }
            cc.setValue(image, forKey: kCIInputImageKey)
            cc.setValue(1.06,  forKey: kCIInputSaturationKey)
            cc.setValue(-0.02, forKey: kCIInputBrightnessKey)
            cc.setValue(1.10,  forKey: kCIInputContrastKey)
            return cc.outputImage ?? image
        }

        // ── 4. Rain / snow ────────────────────────────────────────────────────
        // Cold, desaturated, moderate luminance.  A saturation + micro-contrast
        // boost adds the "wet richness" that rainy-day shots benefit from without
        // pushing the palette toward the warm side.
        if scene.isRainSnow {
            guard let cc = CIFilter(name: "CIColorControls") else { return image }
            cc.setValue(image, forKey: kCIInputImageKey)
            cc.setValue(1.20, forKey: kCIInputSaturationKey)
            cc.setValue(0.02, forKey: kCIInputBrightnessKey)
            cc.setValue(1.04, forKey: kCIInputContrastKey)
            return cc.outputImage ?? image
        }

        // ── 5. Backlit subject ────────────────────────────────────────────────
        // Centre luminance is significantly below the full-image average — the
        // subject is in silhouette against a bright background.  Lift shadows
        // to recover subject detail; leave highlights intact.
        if scene.isBacklit {
            let centerL = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
            let lift = min(0.05, max(0, (0.55 - centerL / 0.55)) * 0.05)
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 1.0, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 0,   w: 1), forKey: "inputAVector")
            mat.setValue(CIVector(x: lift, y: lift, z: lift, w: 0), forKey: "inputBiasVector")
            return mat.outputImage ?? image
        }

        // ── 6. Overcast / cold ────────────────────────────────────────────────
        if kelvin > 6800 && luminance >= 0.18 && luminance <= 0.70 {
            return applyOvercastEnhancement(to: image, luminance: luminance)
        }

        // ── 7. Green-dominant (foliage, parks, gardens) ───────────────────────
        // The base warm matrix's B-reduction can push green leaves toward
        // yellow-khaki.  Restore B and gently pull R back.
        let midRB  = (avgR + avgB) / 2.0
        let gRatio = midRB > 0.01 ? avgG / midRB : 1.0
        if gRatio > 1.25 && avgG > 0.18 {
            let strength = min(1.0, (gRatio - 1.25) / 0.75) * correctionScale
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0 - 0.04 * strength, y: 0.0, z: 0.0, w: 0),
                         forKey: "inputRVector")
            mat.setValue(CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 1.0 + 0.07 * strength, w: 0),
                         forKey: "inputBVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1), forKey: "inputAVector")
            return mat.outputImage ?? image
        }

        // ── 8. Warm indoor / tungsten / golden-hour interior ─────────────────
        // The base matrix applied R×(1+0.05·warmStrength) unconditionally.  On
        // scenes already warm (kelvin < 4000) the matrix already backed off via
        // the bell curve, but some residual warm push may remain.  This provides
        // a further smooth counter-correction proportional to remaining warmth.
        if kelvin < 4000 {
            let w = min(0.40, (4000 - kelvin) / 3333.0) * correctionScale
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0 - 0.05 * w, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0, y: 1.0,       z: 0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 1.0 + 0.04 * w, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1),              forKey: "inputAVector")
            return mat.outputImage ?? image
        }

        // ── 9. Standard neutral scene ─────────────────────────────────────────
        // Fine-tune toward the 4593 K calibration reference.
        let referenceKelvin: CGFloat = 4593.0
        let kelvinDelta      = kelvin - referenceKelvin
        let blueAdjust       = (-kelvinDelta / 5000.0 * 0.04).clamped(to: -0.04...0.04)
        let brightnessAdjust = (luminance - 0.5) * 0.03

        let rBias = (-blueAdjust * 0.3 + brightnessAdjust) * correctionScale
        let gBias = (-blueAdjust * 0.1 + brightnessAdjust) * correctionScale
        let bBias = ( blueAdjust       + brightnessAdjust) * correctionScale

        guard let finalMat = CIFilter(name: "CIColorMatrix") else { return image }
        finalMat.setValue(image, forKey: kCIInputImageKey)
        finalMat.setValue(CIVector(x: rBias, y: gBias, z: bBias, w: 0),
                          forKey: "inputBiasVector")
        return finalMat.outputImage ?? image
    }

    // MARK: - Overcast Enhancement

    /// Deep, oil-paint treatment for flat overcast / cloudy scenes.
    ///
    ///   • Saturation +34% — lifts the muted palette into vivid richness
    ///   • G/B depth matrix — cobalt blues, bottle-green foliage, amber accents
    ///   • B-from-G cross-pull (−0.02·G) — removes residual cyan from blues
    private static func applyOvercastEnhancement(to image: CIImage,
                                                  luminance: CGFloat) -> CIImage {
        guard let satFilter = CIFilter(name: "CIColorControls") else { return image }
        satFilter.setValue(image, forKey: kCIInputImageKey)
        satFilter.setValue(1.18, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0,  forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.04, forKey: kCIInputContrastKey)
        guard let satOut = satFilter.outputImage else { return image }

        guard let depthFilter = CIFilter(name: "CIColorMatrix") else { return satOut }
        depthFilter.setValue(satOut, forKey: kCIInputImageKey)
        depthFilter.setValue(CIVector(x: 1.03, y:  0.00, z:  0.00, w: 0), forKey: "inputRVector")
        depthFilter.setValue(CIVector(x: 0.00, y:  0.92, z:  0.00, w: 0), forKey: "inputGVector")
        depthFilter.setValue(CIVector(x: 0.00, y: -0.02, z:  0.88, w: 0), forKey: "inputBVector")
        depthFilter.setValue(CIVector(x: 0.00, y:  0.00, z:  0.00, w: 1), forKey: "inputAVector")
        depthFilter.setValue(CIVector(x: 0.010, y: -0.005, z: -0.008, w: 0),
                             forKey: "inputBiasVector")
        return depthFilter.outputImage ?? satOut
    }

    // MARK: - 105mm Enhancement

    /// Telephoto-specific noise reduction + saturation lift.
    ///
    /// Telephoto lenses optically compress contrast and render colour flatter;
    /// the saturation lift compensates without affecting luminance.
    /// Sharpening is deferred to the universal post-upscale pipeline in
    /// CameraManager (CISharpenLuminance at 0.30 after CIBicubicScaleTransform)
    /// to guarantee correct colour-then-sharpen ordering.
    private static func apply105mmEnhancement(to image: CIImage) -> CIImage {
        guard let noiseFilter = CIFilter(name: "CINoiseReduction") else { return image }
        noiseFilter.setValue(image, forKey: kCIInputImageKey)
        noiseFilter.setValue(0.02, forKey: "inputNoiseLevel")
        noiseFilter.setValue(0.0,  forKey: "inputSharpness")
        guard let denoised = noiseFilter.outputImage else { return image }

        guard let satFilter = CIFilter(name: "CIColorControls") else { return denoised }
        satFilter.setValue(denoised, forKey: kCIInputImageKey)
        satFilter.setValue(1.08, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0,  forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.0,  forKey: kCIInputContrastKey)
        return satFilter.outputImage ?? denoised
    }

    // MARK: - RY Atmosphere LUT

    /// Builds (on first call) and caches a 33³ CIColorCube that encodes the full
    /// RY per-hue atmosphere remap.  All transforms happen in HSV space so every
    /// hue band receives an independent shift, saturation multiplier, and optional
    /// value compensation — enabling a coherent "film atmosphere" rather than a
    /// simple channel matrix.
    ///
    /// Call this from the filter pipeline; it returns `nil` only on OOM failure
    /// (in practice, 35 937 × 4 × Float = ~560 KB — always succeeds).
    static func ryAtmosphereLUT() -> Data? {
        if let d = ryLUTCache { return d }

        let dim   = ryLUTDim
        let total = dim * dim * dim * 4
        var cube  = [Float](repeating: 0, count: total)

        for bi in 0..<dim {
            for gi in 0..<dim {
                for ri in 0..<dim {
                    let r = Float(ri) / Float(dim - 1)
                    let g = Float(gi) / Float(dim - 1)
                    let b = Float(bi) / Float(dim - 1)

                    // RGB → HSV
                    let maxC  = max(r, max(g, b))
                    let minC  = min(r, min(g, b))
                    let delta = maxC - minC
                    let v     = maxC
                    let s     = maxC > 0.001 ? delta / maxC : 0.0

                    var h: Float = 0.0
                    if delta > 0.001 {
                        if      maxC == r { h = (g - b) / delta; if h < 0 { h += 6 } }
                        else if maxC == g { h = (b - r) / delta + 2.0 }
                        else              { h = (r - g) / delta + 4.0 }
                        h *= 60.0
                    }

                    // Per-hue atmosphere mapping
                    let (newH, sMult, vMult) = ryHueMap(hue: h)

                    // Skin-tone protection: orange range, moderate sat, bright value
                    // Prevent over-warming portrait skin (hue 15–42°, S < 0.58, V > 0.48)
                    let isSkin  = h >= 15 && h < 42 && s < 0.58 && v > 0.48
                    let effSM   = isSkin ? min(sMult, 1.02) : sMult

                    // Dull-colour lift: push grey/overcast tones toward richness
                    let lowBoost: Float = s < 0.20 ? 1.0 + (0.20 - s) / 0.20 * 0.12 : 1.0

                    // Vivid-highlight clamp: don't blow already-saturated highlights
                    let hiClamp: Float  = (v > 0.85 && s > 0.70) ? 0.97 : 1.0

                    let newS = min(s * effSM * lowBoost * hiClamp, 1.0)
                    let newV = min(v * vMult, 1.0)

                    let (or, og, ob) = hsvToRGBf(h: newH, s: newS, v: newV)

                    let idx = (bi * dim * dim + gi * dim + ri) * 4
                    cube[idx]     = or
                    cube[idx + 1] = og
                    cube[idx + 2] = ob
                    cube[idx + 3] = 1.0
                }
            }
        }

        ryLUTCache = Data(bytes: cube, count: total * MemoryLayout<Float>.size)
        return ryLUTCache
    }

    /// Per-hue mapping for the RY atmosphere LUT.
    /// Returns (new hue °, saturation multiplier, value multiplier).
    ///
    /// Design rationale:
    ///   • Warm hues (red/orange/yellow): modest hue push toward richer gold/amber +
    ///     saturation lift → produces the classic "RY warm film" look.
    ///   • Greens: slight warm push + saturation lift → lush foliage without
    ///     going yellow-khaki (the B-reduction problem in the warm matrix).
    ///   • Cyan (165–200°): large hue shift −10° toward pure blue, plus saturation
    ///     boost and value recovery → fixes sky turning cyan and water turning green.
    ///   • Blue: slight purple-ward push + brightness lift → rich cobalt/sapphire.
    ///   • Magenta: no hue shift, sat ×0.96 → suppresses overflow bleeding.
    private static func ryHueMap(hue: Float) -> (Float, Float, Float) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
                 .truncatingRemainder(dividingBy: 360)
        if      h <  20 { return (h +  5.0, 1.05, 1.00) }   // red      → warm orange-red
        else if h <  50 { return (h +  3.5, 1.08, 1.02) }   // orange   → rich amber-orange
        else if h <  75 { return (h +  4.5, 1.10, 1.02) }   // yellow   → golden amber
        else if h < 120 { return (h -  2.5, 1.05, 1.00) }   // yel-grn  → kept vibrant green
        else if h < 165 { return (h +  2.0, 1.06, 0.99) }   // green    → warm lush green
        else if h < 200 { return (h - 10.0, 1.14, 1.03) }   // cyan     → pure blue (sky fix)
        else if h < 255 { return (h +  3.0, 1.10, 1.04) }   // blue     → rich cobalt
        else if h < 310 { return (h -  4.0, 1.03, 0.99) }   // purple   → deeper violet
        else            { return (h +  0.0, 0.96, 1.00) }   // magenta  → suppress overflow
    }

    /// Float-precision HSV → RGB.  h in degrees [0, 360), s/v in [0, 1].
    private static func hsvToRGBf(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
        guard s > 0.001 else { return (v, v, v) }
        let hNorm = (h.truncatingRemainder(dividingBy: 360) + 360)
                     .truncatingRemainder(dividingBy: 360) / 60.0
        let i = Int(hNorm)
        let f = hNorm - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0:  return (v, t, p)
        case 1:  return (q, v, p)
        case 2:  return (p, v, t)
        case 3:  return (p, q, v)
        case 4:  return (t, p, v)
        default: return (v, p, q)
        }
    }

    // MARK: - Math helpers

    private static func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        a + (b - a) * t.clamped(to: 0...1)
    }

    /// Smooth Hermite interpolation from 0 at `lo` to 1 at `hi`.
    /// Returns 0 below `lo`, 1 above `hi`, smooth S-curve in between.
    private static func smoothstep(lo: CGFloat, hi: CGFloat, t: CGFloat) -> CGFloat {
        let x = ((t - lo) / (hi - lo)).clamped(to: 0...1)
        return x * x * (3.0 - 2.0 * x)
    }
}

// MARK: - CGFloat helper

private extension CGFloat {
    func clamped(to range: ClosedRange<CGFloat>) -> CGFloat {
        Swift.min(Swift.max(self, range.lowerBound), range.upperBound)
    }
}
