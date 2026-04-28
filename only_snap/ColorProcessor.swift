import CoreImage
import Accelerate
import Metal

/// Colour-processing modes.
enum ColorMode {
    case normal
    case vintageGold
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

    // VG atmosphere 3-D LUT — built once, reused for every photo
    private static var vgLUTCache: Data?
    private static let vgLUTDim = 33     // 33³ = 35 937 entries; good balance of accuracy/speed

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

        // ── Computed scene metrics ────────────────────────────────────────────

        /// Green-to-midRB ratio — used to detect foliage / park / garden scenes.
        var gRatio: CGFloat {
            let midRB = (avgR + avgB) / 2.0
            return midRB > 0.01 ? avgG / midRB : 1.0
        }

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
        /// Water / lake / ocean / pool: cool-blue dominant, moderately saturated, not night.
        /// Detected by blue channel significantly exceeding red, with meaningful saturation.
        var isWaterScene: Bool {
            let cbDiff = avgB - avgR
            return cbDiff > 0.08 && avgB > 0.28 && satScore > 0.18 && !isNight
        }
    }

    // MARK: - Public entry point

    static func process(image: CIImage, mode: ColorMode, focalLength: Int = 35) -> CIImage {
        let processed: CIImage
        switch mode {
        case .normal:
            processed = image
        case .vintageGold:
            // skipPreSmooth: 105mm has its own CINoiseReduction + the universal post-upscale
            // denoise in CameraManager. Running the 0.01 pre-smooth too would stack three
            // passes and visibly over-blur telephoto output.
            processed = applyVGCurve(to: image, skipPreSmooth: focalLength == 105)
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
        let maxC     = max(r, g, b)
        let minC     = min(r, g, b)
        let satScore = maxC > 0.01 ? (maxC - minC) / maxC : 0.0

        // ── Highlight proxy (top-area luminance) ─────────────────────────────
        let highlightRatio: CGFloat = ts.map {
            0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b
        } ?? lum

        // ── Haze / fog proxy ─────────────────────────────────────────────────
        let hazeScore = maxC > 0.01 ? minC / maxC : 0.0

        // ── Backlight detection ───────────────────────────────────────────────
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

    // MARK: - VG Vintage Gold pipeline

    /// Full VG (Vintage Gold) warm-film pipeline for saved stills.
    ///
    /// Positioning: Pentax Gold (luminance-driven shadow-blue → highlight-gold) +
    /// Kodak Gold 200 (warm, saturated, beautiful skin tones, golden-hour excellence).
    ///
    /// Stages:
    ///   0. Optional pre-smooth (skipped for 105mm)
    ///   1. VG Tone Curve — CIColorPolynomial luminance-separated toning
    ///      (shadows: cool-blue; highlights: warm-gold)
    ///   2. CIToneCurve — film S-curve contrast
    ///   3. VG Atmosphere LUT — per-hue remap with green protection + water guard
    ///   4. Adaptive saturation — dull scenes lifted, vivid scenes preserved
    ///   5. Dynamic bloom — attenuated for hot highlights, boosted for flat scenes
    ///   6. Scene-adaptive correction — per-scene fine-tuning
    ///
    /// Key VG improvements over old RY approach:
    ///   • Tone curve replaces global warm matrix → shadows stay cool, highlights go gold
    ///   • Green protection in LUT → foliage stays green (not yellow-khaki)
    ///   • Reduced cyan shift (-3° vs -10°) → water reflections preserved
    ///   • Lighter global saturation touch → more natural colour fidelity
    private static func applyVGCurve(to image: CIImage,
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

        // ── 1. VG Tone Curve ──────────────────────────────────────────────────
        //
        // Strength bell-curves with colour temperature:
        //   kelvin ~ 5000 K → full strength 1.0 (neutral daylight)
        //   kelvin < 3200 K → floor 0.40 (very warm scene: don't double-gold warm light)
        //   kelvin > 8000 K → floor 0.40 (cold overcast: let adaptive correction handle it)
        //   sunset           → 1.20 boost (golden hour deserves stronger gold toning)
        //   night            → 0.40 (minimal — reduce colour noise risk in shadows)
        let toneStrength: CGFloat = {
            if scene.isNight  { return 0.40 }
            if scene.isSunset { return 1.20 }
            let rise = smoothstep(lo: 3200, hi: 5000, t: scene.kelvin)
            let fall = 1.0 - smoothstep(lo: 6000, hi: 8000, t: scene.kelvin)
            return (rise * fall).clamped(to: 0.40...1.20)
        }()
        let vgToneOut = applyVGToneCurve(to: baseImage, strength: toneStrength)

        // ── 2. Film tone curve ───────────────────────────────────────────────
        guard let toneFilter = CIFilter(name: "CIToneCurve") else { return vgToneOut }
        toneFilter.setValue(vgToneOut, forKey: kCIInputImageKey)
        toneFilter.setValue(CIVector(x: 0.00, y: 0.000), forKey: "inputPoint0")
        toneFilter.setValue(CIVector(x: 0.25, y: 0.210), forKey: "inputPoint1")
        toneFilter.setValue(CIVector(x: 0.50, y: 0.500), forKey: "inputPoint2")
        toneFilter.setValue(CIVector(x: 0.75, y: 0.780), forKey: "inputPoint3")
        toneFilter.setValue(CIVector(x: 1.00, y: 0.940), forKey: "inputPoint4")
        guard let toneOut = toneFilter.outputImage else { return vgToneOut }

        // ── 3. VG Atmosphere LUT ─────────────────────────────────────────────
        //
        // A 33³ CIColorCube built once in vgAtmosphereLUT() and applied post
        // tone-curve.  Key differences from old RY LUT:
        //   green (120–165°): 0° hue shift + ×1.10 sat  ← protection, stays green
        //   cyan  (165–200°): −3° shift (was −10°)       ← water reflection guard
        //   warm hues: lighter saturation push for more natural skin tones
        //
        // Night scenes skip the LUT to avoid amplifying colour noise.
        let lutOut: CIImage
        if !scene.isNight,
           let lutData = vgAtmosphereLUT(),
           let cube = CIFilter(name: "CIColorCube") {
            cube.setValue(vgLUTDim, forKey: "inputCubeDimension")
            cube.setValue(lutData,  forKey: "inputCubeData")
            cube.setValue(toneOut,  forKey: kCIInputImageKey)
            lutOut = cube.outputImage ?? toneOut
        } else {
            lutOut = toneOut
        }

        // ── 4. Adaptive saturation ────────────────────────────────────────────
        //
        // Slightly higher floor (0.86 vs 0.84) and narrower boost range than old RY —
        // VG's tone curve already contributes colour richness via the highlight-gold push,
        // so we need less saturation boost to avoid over-saturating skies and foliage.
        let targetSat = (0.86 + (1.0 - scene.satScore) * 0.18)
            .clamped(to: 0.78...1.10)
        let finalSat: CGFloat
        if scene.isNight {
            finalSat = min(targetSat, 0.86)
        } else if scene.isSunset {
            finalSat = min(targetSat + 0.04, 1.10)
        } else {
            finalSat = targetSat
        }

        guard let satFilter = CIFilter(name: "CIColorControls") else { return lutOut }
        satFilter.setValue(lutOut, forKey: kCIInputImageKey)
        satFilter.setValue(finalSat, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0,      forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.0,      forKey: kCIInputContrastKey)
        let satOut = satFilter.outputImage ?? lutOut

        // ── 5. Dynamic bloom ─────────────────────────────────────────────────
        //
        // Slightly reduced intensity floor vs old RY (0.12 base vs 0.14) — the VG
        // tone curve's highlight push is more refined than bloom-as-glow, so we let
        // the curve do the heavy lifting and keep bloom as a subtle air/halation effect.
        let bloomOut: CIImage
        if !scene.isNight, let bloomFilter = CIFilter(name: "CIBloom") {
            let highlightDamp: CGFloat = scene.highlightRatio > 0.65
                ? (1.0 - ((scene.highlightRatio - 0.65) / 0.35)).clamped(to: 0.25...1.0)
                : 1.0
            let flatBoost: CGFloat = (scene.satScore < 0.15 && !scene.isFoggy) ? 1.20 : 1.0
            let bloomIntensity = (0.12 * highlightDamp * flatBoost).clamped(to: 0.04...0.20)

            bloomFilter.setValue(satOut,         forKey: kCIInputImageKey)
            bloomFilter.setValue(10.0,           forKey: kCIInputRadiusKey)
            bloomFilter.setValue(bloomIntensity, forKey: kCIInputIntensityKey)
            // IMPORTANT: CIBloom expands the output extent by `radius` on every side.
            // Crop back to source extent to remove the overflow edge; the black frame
            // composite in CameraManager.handleCapturedPhoto adds the intentional dark border.
            bloomOut = (bloomFilter.outputImage ?? satOut).cropped(to: satOut.extent)
        } else {
            bloomOut = satOut
        }

        // ── 6. Scene-adaptive correction ─────────────────────────────────────
        return applyAdaptiveCorrection(to: bloomOut, scene: scene)
    }

    // MARK: - VG Tone Curve (CIColorPolynomial)

    /// Luminance-separated gold toning — the defining VG aesthetic stage.
    ///
    /// Pentax Gold / Kodak Gold 200 signature:
    ///   • Shadows lean cool-blue  (film depth, dark separation from midtones)
    ///   • Midtones pass through naturally (faithful subject rendering, accurate skin)
    ///   • Highlights lean warm-gold (the "gold" in Kodak Gold 200, Pentax Gold)
    ///
    /// Unlike the old RY global warm matrix (which equally warmed all tones and produced
    /// flat muddy shadows), CIColorPolynomial applies different tints at different
    /// luminance levels — giving the graduated warm-gold characteristic that made
    /// Kodak Gold 200 a beloved portrait / street / travel film.
    ///
    /// CIColorPolynomial: out = a + b·in + c·in² + d·in³
    ///   a = constant offset — shadow bias (output at in=0)
    ///   b = linear slope   — identity = 1.0
    ///   c = quadratic term — set to 0 for smooth cubic response
    ///   d = cubic term     — set to (highlight_net_delta − a)
    ///       ensures at in=1: a + 1.0 + 0 + (h−a) = 1.0 + h ✓
    private static func applyVGToneCurve(to image: CIImage, strength: CGFloat) -> CIImage {
        guard let poly = CIFilter(name: "CIColorPolynomial") else { return image }
        let s = strength

        // Shadow push at in ≈ 0 (dark pixels):
        let sR: CGFloat = -0.012 * s    // R−: cooler, less red in shadows
        let sG: CGFloat = -0.005 * s    // G−: subtle green pull (reinforces cool cast)
        let sB: CGFloat =  0.014 * s    // B+: blue depth in shadows

        // Highlight net delta above identity at in = 1 (bright pixels):
        let hR: CGFloat =  0.018 * s    // R+: golden warmth in highlights
        let hG: CGFloat =  0.008 * s    // G+: slight green lift (gold, not just orange)
        let hB: CGFloat = -0.018 * s    // B−: removes cyan from highlights → pure gold

        poly.setValue(image, forKey: kCIInputImageKey)
        poly.setValue(CIVector(x: sR, y: 1.0, z: 0.0, w: hR - sR),
                      forKey: "inputRedCoefficients")
        poly.setValue(CIVector(x: sG, y: 1.0, z: 0.0, w: hG - sG),
                      forKey: "inputGreenCoefficients")
        poly.setValue(CIVector(x: sB, y: 1.0, z: 0.0, w: hB - sB),
                      forKey: "inputBlueCoefficients")
        poly.setValue(CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0.0),
                      forKey: "inputAlphaCoefficients")
        return poly.outputImage ?? image
    }

    // MARK: - Adaptive Correction (VG-updated scene coverage)

    /// Per-scene fine-tuning applied AFTER the main VG grade.
    ///
    /// Priority order (first match wins — scenes are mutually exclusive at thresholds):
    ///   0. Degenerate / single-colour fallback
    ///   1. Night / very low light
    ///   2. Sunset / sunrise (warm, DO NOT counter-correct)
    ///   3. Fog / haze
    ///   4. Rain / snow
    ///   5. Water / lake / ocean (new in VG — protect blue-cool reflections)
    ///   6. Backlit subject (shadow lift only)
    ///   7. Overcast / cold
    ///   8. Green-dominant (lighter than RY — VG LUT already protects foliage)
    ///   9. Warm indoor / tungsten
    ///  10. Standard neutral — fine-tune toward reference 4593 K
    private static func applyAdaptiveCorrection(to image: CIImage,
                                                 scene: SceneAnalysis) -> CIImage {

        let kelvin    = scene.kelvin
        let luminance = scene.luminance
        let avgR      = scene.avgR
        let avgG      = scene.avgG
        let avgB      = scene.avgB

        // Shared scale that damps ALL corrections near extreme brightness values.
        let correctionScale: CGFloat = {
            if luminance < 0.18 { return (luminance / 0.18).clamped(to: 0...1) }
            if luminance > 0.70 { return (1.0 - (luminance - 0.70) / 0.30).clamped(to: 0...1) }
            return 1.0
        }()

        // ── 0. Degenerate / monochrome fallback ──────────────────────────────
        let maxC = max(avgR, avgG, avgB)
        let minC = min(avgR, avgG, avgB)
        if maxC < 0.03 || (maxC - minC) < 0.015 {
            return image
        }

        // ── 1. Night / very low light ─────────────────────────────────────────
        // Slightly lift the black point so pure-black noise doesn't crush to digital black.
        // VG bias: warm-neutral (matches the golden-blue split in the tone curve at low lum).
        if scene.isNight {
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 1.0, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 0,   w: 1), forKey: "inputAVector")
            mat.setValue(CIVector(x: 0.010, y: 0.008, z: 0.008, w: 0),
                         forKey: "inputBiasVector")
            return mat.outputImage ?? image
        }

        // ── 2. Sunset / sunrise ───────────────────────────────────────────────
        // The VG tone curve already captured the golden light.  This pass enriches
        // saturation slightly — reduced vs old RY (1.10→1.06) since the tone curve
        // already adds rich gold colour without needing a separate saturation spike.
        if scene.isSunset {
            guard let sat = CIFilter(name: "CIColorControls") else { return image }
            sat.setValue(image, forKey: kCIInputImageKey)
            sat.setValue(1.06, forKey: kCIInputSaturationKey)
            sat.setValue(0.0,  forKey: kCIInputBrightnessKey)
            sat.setValue(1.0,  forKey: kCIInputContrastKey)
            return sat.outputImage ?? image
        }

        // ── 3. Fog / haze ─────────────────────────────────────────────────────
        if scene.isFoggy {
            guard let cc = CIFilter(name: "CIColorControls") else { return image }
            cc.setValue(image, forKey: kCIInputImageKey)
            cc.setValue(1.06,  forKey: kCIInputSaturationKey)
            cc.setValue(-0.02, forKey: kCIInputBrightnessKey)
            cc.setValue(1.10,  forKey: kCIInputContrastKey)
            return cc.outputImage ?? image
        }

        // ── 4. Rain / snow ────────────────────────────────────────────────────
        if scene.isRainSnow {
            guard let cc = CIFilter(name: "CIColorControls") else { return image }
            cc.setValue(image, forKey: kCIInputImageKey)
            cc.setValue(1.20, forKey: kCIInputSaturationKey)
            cc.setValue(0.02, forKey: kCIInputBrightnessKey)
            cc.setValue(1.04, forKey: kCIInputContrastKey)
            return cc.outputImage ?? image
        }

        // ── 5. Water / lake / ocean (new in VG) ──────────────────────────────
        // Water scenes are cool and blue-dominant.  The VG tone curve pushes highlights
        // gold, which is beautiful on light-sparkled water surfaces; however the green
        // channel's slight shadow pull can occasionally shift deep water toward blue-grey.
        // This pass subtly reinforces the blue depth and restores G channel neutrality
        // so water stays properly blue-cool rather than teal-shifted.
        if scene.isWaterScene {
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.00, y: 0.0, z: 0.0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0.0, y: 0.98, z: 0.0, w: 0), forKey: "inputGVector")  // slight G pull
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 1.02, w: 0), forKey: "inputBVector")  // slight B boost
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0,  w: 1), forKey: "inputAVector")
            // Cool shadow bias: reinforce water depth without pushing cyan
            mat.setValue(CIVector(x: -0.004, y: -0.002, z: 0.006, w: 0),
                         forKey: "inputBiasVector")
            return mat.outputImage ?? image
        }

        // ── 6. Backlit subject ────────────────────────────────────────────────
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

        // ── 7. Overcast / cold ────────────────────────────────────────────────
        if kelvin > 6800 && luminance >= 0.18 && luminance <= 0.70 {
            return applyOvercastEnhancement(to: image, luminance: luminance)
        }

        // ── 8. Green-dominant (foliage, parks, gardens) ───────────────────────
        // VG's vgAtmosphereLUT already protects green (0° hue shift, ×1.10 sat),
        // so only a lighter corrective touch is needed here vs old RY.
        // Specifically: smaller R pull-back (0.02 vs 0.04) and smaller B lift (0.04 vs 0.07)
        // to avoid over-correcting what the LUT already handled.
        if scene.gRatio > 1.25 && avgG > 0.18 {
            let strength = min(1.0, (scene.gRatio - 1.25) / 0.75) * correctionScale
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0 - 0.02 * strength, y: 0.0, z: 0.0, w: 0),
                         forKey: "inputRVector")
            mat.setValue(CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 1.0 + 0.04 * strength, w: 0),
                         forKey: "inputBVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1), forKey: "inputAVector")
            return mat.outputImage ?? image
        }

        // ── 9. Warm indoor / tungsten / golden-hour interior ─────────────────
        // VG's tone curve has a reduced strength at kelvin < 3200 (bell curve floor),
        // but residual warmth may remain.  Smooth counter-correction as before.
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

        // ── 10. Standard neutral scene ────────────────────────────────────────
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

    // MARK: - VG Atmosphere LUT

    /// Builds (on first call) and caches a 33³ CIColorCube that encodes the full
    /// VG per-hue atmosphere remap.  All transforms happen in HSV space.
    ///
    /// Key VG design differences vs old RY LUT:
    ///   • Green (120–165°): 0° hue shift + ×1.10 saturation
    ///     → foliage / grass / leaves stay genuinely green (RY pushed them warm/khaki)
    ///   • Cyan (165–200°): only −3° shift (RY was −10°)
    ///     → water reflections, pool surfaces, humid sky preserved; not over-shifted blue
    ///   • Red / orange / yellow: slightly lighter saturation push (×1.04–1.08 vs ×1.05–1.10)
    ///     → more natural skin tones; the VG tone curve already enriches warm highlights
    ///   • Skin-tone dual protection: hue 15–42°, S<0.58, V>0.48 → satMult capped at 1.02
    ///   • Dull-colour lift + vivid-highlight clamp (same as RY, unchanged)
    static func vgAtmosphereLUT() -> Data? {
        if let d = vgLUTCache { return d }

        let dim   = vgLUTDim
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

                    // Per-hue VG atmosphere mapping
                    let (newH, sMult, vMult) = vgHueMap(hue: h)

                    // Skin-tone dual protection: orange-range, moderate sat, bright value
                    // Prevents over-warming portrait skin (VG's warm highlights already
                    // enhance skin in the tone curve — the LUT should preserve, not stack)
                    let isSkin  = h >= 15 && h < 42 && s < 0.58 && v > 0.48
                    let effSM   = isSkin ? min(sMult, 1.02) : sMult

                    // Dull-colour lift: push grey/overcast tones toward richness
                    let lowBoost: Float = s < 0.20 ? 1.0 + (0.20 - s) / 0.20 * 0.10 : 1.0

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

        vgLUTCache = Data(bytes: cube, count: total * MemoryLayout<Float>.size)
        return vgLUTCache
    }

    /// Per-hue mapping for the VG atmosphere LUT.
    /// Returns (new hue °, saturation multiplier, value multiplier).
    ///
    /// VG design rationale vs old RY:
    ///   • Warm hues (red/orange/yellow): lighter sat push — VG tone curve handles warmth;
    ///     LUT adds refining amber shift without stacking on top of the tone curve gold.
    ///   • Green (120–165°): 0° shift + ×1.10 sat — THE key VG green protection.
    ///     Old RY pushed green +2° (slightly warm/khaki); VG keeps foliage green and lush.
    ///   • Cyan (165–200°): −3° (OLD: −10°) — water reflection guard.
    ///     The large −10° shift turned pool water and humid sky unrealistically blue.
    ///     −3° gently removes cyan channel overflow without destroying water colour.
    ///   • Blue: similar cobalt push (same as RY — cobalt blue is a VG signature too)
    ///   • Magenta: ×0.95 sat suppress — prevent colour overflow bleeding
    private static func vgHueMap(hue: Float) -> (Float, Float, Float) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
                 .truncatingRemainder(dividingBy: 360)
        if      h <  20 { return (h + 4.0, 1.04, 1.00) }   // red       → warm orange-red
        else if h <  50 { return (h + 3.0, 1.06, 1.01) }   // orange    → rich amber-orange
        else if h <  75 { return (h + 3.5, 1.08, 1.01) }   // yellow    → golden amber
        else if h < 120 { return (h + 0.0, 1.05, 1.00) }   // yel-grn   → GREEN PROTECT (0° shift)
        else if h < 165 { return (h + 1.0, 1.10, 0.99) }   // green     → lush, vibrant green
        else if h < 200 { return (h - 3.0, 1.08, 1.02) }   // cyan      → slight blue shift (water guard)
        else if h < 255 { return (h + 3.0, 1.08, 1.03) }   // blue      → rich cobalt
        else if h < 310 { return (h - 3.0, 1.02, 0.99) }   // purple    → deeper violet
        else            { return (h + 0.0, 0.95, 1.00) }   // magenta   → suppress overflow
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
