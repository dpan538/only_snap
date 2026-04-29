import CoreImage
import Metal

enum VGProcessor {

    // MARK: - Shared context (one GPU context for all analysis)

    nonisolated private static let analysisCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // VG atmosphere 3-D LUT — built once, reused for every photo
    nonisolated(unsafe) private static var vgLUTCache: Data?
    nonisolated private static let vgLUTDim = 33

    // MARK: - Scene Analysis Struct

    private struct SceneAnalysis {
        let kelvin: CGFloat
        let luminance: CGFloat
        let avgR: CGFloat
        let avgG: CGFloat
        let avgB: CGFloat
        let satScore: CGFloat
        let highlightRatio: CGFloat
        let hazeScore: CGFloat
        let isBacklit: Bool
        let topR: CGFloat
        let topG: CGFloat
        let topB: CGFloat

        nonisolated var gRatio: CGFloat {
            let midRB = (avgR + avgB) / 2.0
            return midRB > 0.01 ? avgG / midRB : 1.0
        }

        nonisolated var isSunset: Bool { kelvin < 3600 && highlightRatio > 0.30 && luminance > 0.25 }
        nonisolated var isNight: Bool { luminance < 0.15 }
        nonisolated var isFoggy: Bool { hazeScore > 0.38 && luminance > 0.32 }
        nonisolated var isRainSnow: Bool {
            kelvin > 6300 && satScore < 0.18 && luminance > 0.25 && luminance < 0.75
        }
        nonisolated var isWaterScene: Bool {
            let cbDiff = avgB - avgR
            return cbDiff > 0.08 && avgB > 0.28 && satScore > 0.18 && !isNight
        }
        nonisolated var isBlueSkyDominant: Bool {
            let topMax = max(topR, topG, topB)
            let topMin = min(topR, topG, topB)
            let topSat = topMax > 0.01 ? (topMax - topMin) / topMax : 0.0
            return topB > topR + 0.06
                && topB > topG + 0.02
                && topB > 0.24
                && topSat > 0.16
                && highlightRatio > 0.34
                && !isNight
        }
        nonisolated var isSunlit: Bool {
            highlightRatio > 0.48 && luminance > 0.28 && !isNight
        }
    }

    nonisolated static func preheatResources() {
        _ = vgAtmosphereLUT()
    }

    nonisolated static func apply(to image: CIImage, focalLength: Int) -> CIImage {
        let processed = applyVGTransform(to: image, skipPreSmooth: focalLength == 105)
        return focalLength == 105 ? apply105mmVGEnhancement(to: processed) : processed
    }

    // MARK: - Multi-zone Scene Analysis

    nonisolated private static func analyzeImage(_ image: CIImage) -> SceneAnalysis {
        let ext = image.extent
        let fallback = SceneAnalysis(kelvin: 4593, luminance: 0.5,
                                     avgR: 0.5, avgG: 0.5, avgB: 0.5,
                                     satScore: 0.2, highlightRatio: 0.4,
                                     hazeScore: 0.1, isBacklit: false,
                                     topR: 0.5, topG: 0.5, topB: 0.5)
        guard ext.width > 4, ext.height > 4 else { return fallback }

        let cw = ext.width * 0.40
        let ch = ext.height * 0.40
        let centerExt = CGRect(
            x: ext.midX - cw * 0.5,
            y: ext.midY - ch * 0.5,
            width: cw,
            height: ch
        )
        let fullExt = ext
        let topExt = CGRect(
            x: ext.midX - ext.width * 0.30,
            y: ext.maxY - ext.height * 0.25,
            width: ext.width * 0.60,
            height: ext.height * 0.25
        )

        func sample(_ rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
            guard let filter = CIFilter(
                name: "CIAreaAverage",
                parameters: [
                    kCIInputImageKey: image,
                    kCIInputExtentKey: CIVector(cgRect: rect)
                ]
            ),
            let out = filter.outputImage else {
                return nil
            }
            var px = [UInt8](repeating: 0, count: 4)
            analysisCIContext.render(
                out,
                toBitmap: &px,
                rowBytes: 4,
                bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
                format: .RGBA8,
                colorSpace: CGColorSpaceCreateDeviceRGB()
            )
            return (
                CGFloat(px[0]) / 255.0,
                CGFloat(px[1]) / 255.0,
                CGFloat(px[2]) / 255.0
            )
        }

        guard let cs = sample(centerExt), let fs = sample(fullExt) else { return fallback }
        let ts = sample(topExt)

        let r = cs.r * 0.60 + fs.r * 0.40
        let g = cs.g * 0.60 + fs.g * 0.40
        let b = cs.b * 0.60 + fs.b * 0.40

        let rb = r / max(b, 0.001)
        let kelvin: CGFloat = {
            switch rb {
            case ..<0.55:
                return 9000
            case 0.55..<0.80:
                return lerp(9000, 7000, t: (rb - 0.55) / 0.25)
            case 0.80..<1.05:
                return lerp(7000, 6000, t: (rb - 0.80) / 0.25)
            case 1.05..<1.35:
                return lerp(6000, 5000, t: (rb - 1.05) / 0.30)
            case 1.35..<1.75:
                return lerp(5000, 4000, t: (rb - 1.35) / 0.40)
            case 1.75..<2.30:
                return lerp(4000, 3000, t: (rb - 1.75) / 0.55)
            default:
                return 2500
            }
        }()

        let lum = 0.2126 * r + 0.7152 * g + 0.0722 * b
        let centerL = 0.2126 * cs.r + 0.7152 * cs.g + 0.0722 * cs.b
        let fullL = 0.2126 * fs.r + 0.7152 * fs.g + 0.0722 * fs.b

        let maxC = max(r, g, b)
        let minC = min(r, g, b)
        let satScore = maxC > 0.01 ? (maxC - minC) / maxC : 0.0

        let topSample = ts ?? fs
        let highlightRatio: CGFloat = ts.map {
            0.2126 * $0.r + 0.7152 * $0.g + 0.0722 * $0.b
        } ?? lum

        let hazeScore = maxC > 0.01 ? minC / maxC : 0.0
        let isBacklit = fullL > 0.06 && centerL < fullL * 0.55

        return SceneAnalysis(
            kelvin: kelvin,
            luminance: lum,
            avgR: r,
            avgG: g,
            avgB: b,
            satScore: satScore,
            highlightRatio: highlightRatio,
            hazeScore: hazeScore,
            isBacklit: isBacklit,
            topR: topSample.r,
            topG: topSample.g,
            topB: topSample.b
        )
    }

    // MARK: - VG Vintage Gold pipeline

    nonisolated private static func applyVGTransform(to image: CIImage, skipPreSmooth: Bool = false) -> CIImage {
        let baseImage: CIImage
        if !skipPreSmooth, let filter = CIFilter(name: "CINoiseReduction") {
            filter.setValue(image, forKey: kCIInputImageKey)
            filter.setValue(0.01, forKey: "inputNoiseLevel")
            filter.setValue(0.0, forKey: "inputSharpness")
            baseImage = filter.outputImage ?? image
        } else {
            baseImage = image
        }

        let scene = analyzeImage(image)

        let toneStrength: CGFloat = {
            if scene.isNight { return 0.30 }
            if scene.isSunset { return 1.20 }
            let rise = smoothstep(lo: 3200, hi: 5000, t: scene.kelvin)
            let fall = 1.0 - smoothstep(lo: 6000, hi: 8000, t: scene.kelvin)
            let sunlightFloor: CGFloat = scene.isSunlit ? 0.76 : 0.0
            return max(rise * fall, sunlightFloor).clamped(to: 0.34...1.18)
        }()
        let vgToneOut = applyVGToneCurve(to: baseImage, strength: toneStrength)

        guard let toneFilter = CIFilter(name: "CIToneCurve") else { return vgToneOut }
        toneFilter.setValue(vgToneOut, forKey: kCIInputImageKey)
        toneFilter.setValue(CIVector(x: 0.00, y: 0.000), forKey: "inputPoint0")
        toneFilter.setValue(CIVector(x: 0.25, y: 0.225), forKey: "inputPoint1")
        toneFilter.setValue(CIVector(x: 0.50, y: 0.500), forKey: "inputPoint2")
        toneFilter.setValue(CIVector(x: 0.75, y: 0.800), forKey: "inputPoint3")
        toneFilter.setValue(CIVector(x: 1.00, y: 0.965), forKey: "inputPoint4")
        guard let toneOut = toneFilter.outputImage else { return vgToneOut }

        let lutOut: CIImage
        if !scene.isNight,
           let lutData = vgAtmosphereLUT(),
           let cube = CIFilter(name: "CIColorCube") {
            cube.setValue(vgLUTDim, forKey: "inputCubeDimension")
            cube.setValue(lutData, forKey: "inputCubeData")
            cube.setValue(toneOut, forKey: kCIInputImageKey)
            lutOut = cube.outputImage ?? toneOut
        } else {
            lutOut = toneOut
        }

        let targetSat = (0.86 + (1.0 - scene.satScore) * 0.14)
            .clamped(to: 0.78...1.08)
        let finalSat: CGFloat
        if scene.isNight {
            finalSat = min(targetSat, 0.86)
        } else if scene.isSunset {
            finalSat = min(targetSat + 0.03, 1.09)
        } else {
            finalSat = targetSat
        }

        guard let satFilter = CIFilter(name: "CIColorControls") else { return lutOut }
        satFilter.setValue(lutOut, forKey: kCIInputImageKey)
        satFilter.setValue(finalSat, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.0, forKey: kCIInputContrastKey)
        let satOut = satFilter.outputImage ?? lutOut

        let bloomOut: CIImage
        if !scene.isNight, let bloomFilter = CIFilter(name: "CIBloom") {
            let highlightDamp: CGFloat = scene.highlightRatio > 0.65
                ? (1.0 - ((scene.highlightRatio - 0.65) / 0.35)).clamped(to: 0.25...1.0)
                : 1.0
            let flatBoost: CGFloat = (scene.satScore < 0.15 && !scene.isFoggy) ? 1.20 : 1.0
            let bloomIntensity = (0.12 * highlightDamp * flatBoost).clamped(to: 0.04...0.20)

            bloomFilter.setValue(satOut, forKey: kCIInputImageKey)
            bloomFilter.setValue(10.0, forKey: kCIInputRadiusKey)
            bloomFilter.setValue(bloomIntensity, forKey: kCIInputIntensityKey)
            bloomOut = (bloomFilter.outputImage ?? satOut).cropped(to: satOut.extent)
        } else {
            bloomOut = satOut
        }

        let corrected = applyAdaptiveCorrection(to: bloomOut, scene: scene)
        return applyGold200FinalBalance(to: corrected, scene: scene)
    }

    // MARK: - VG Tone Curve

    nonisolated private static func applyVGToneCurve(to image: CIImage, strength: CGFloat) -> CIImage {
        guard let poly = CIFilter(name: "CIColorPolynomial") else { return image }
        let s = strength

        let sR: CGFloat = 0.004 * s
        let sG: CGFloat = 0.000 * s
        let sB: CGFloat = -0.010 * s

        let hR: CGFloat = 0.028 * s
        let hG: CGFloat = 0.014 * s
        let hB: CGFloat = -0.026 * s

        poly.setValue(image, forKey: kCIInputImageKey)
        poly.setValue(CIVector(x: sR, y: 1.0, z: 0.0, w: hR - sR), forKey: "inputRedCoefficients")
        poly.setValue(CIVector(x: sG, y: 1.0, z: 0.0, w: hG - sG), forKey: "inputGreenCoefficients")
        poly.setValue(CIVector(x: sB, y: 1.0, z: 0.0, w: hB - sB), forKey: "inputBlueCoefficients")
        poly.setValue(CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0.0), forKey: "inputAlphaCoefficients")
        return poly.outputImage ?? image
    }

    // MARK: - Adaptive Correction

    nonisolated private static func applyAdaptiveCorrection(to image: CIImage, scene: SceneAnalysis) -> CIImage {
        let kelvin = scene.kelvin
        let luminance = scene.luminance
        let avgR = scene.avgR
        let avgG = scene.avgG
        let avgB = scene.avgB

        let correctionScale: CGFloat = {
            if luminance < 0.18 { return (luminance / 0.18).clamped(to: 0...1) }
            if luminance > 0.70 { return (1.0 - (luminance - 0.70) / 0.30).clamped(to: 0...1) }
            return 1.0
        }()

        let maxC = max(avgR, avgG, avgB)
        let minC = min(avgR, avgG, avgB)
        if maxC < 0.03 || (maxC - minC) < 0.015 {
            return image
        }

        if scene.isNight {
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 1.0, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            mat.setValue(CIVector(x: 0.010, y: 0.008, z: 0.008, w: 0), forKey: "inputBiasVector")
            return mat.outputImage ?? image
        }

        if scene.isSunset {
            guard let sat = CIFilter(name: "CIColorControls") else { return image }
            sat.setValue(image, forKey: kCIInputImageKey)
            sat.setValue(1.06, forKey: kCIInputSaturationKey)
            sat.setValue(0.0, forKey: kCIInputBrightnessKey)
            sat.setValue(1.0, forKey: kCIInputContrastKey)
            return sat.outputImage ?? image
        }

        if scene.isFoggy {
            guard let cc = CIFilter(name: "CIColorControls") else { return image }
            cc.setValue(image, forKey: kCIInputImageKey)
            cc.setValue(1.06, forKey: kCIInputSaturationKey)
            cc.setValue(-0.02, forKey: kCIInputBrightnessKey)
            cc.setValue(1.08, forKey: kCIInputContrastKey)
            return cc.outputImage ?? image
        }

        if scene.isRainSnow {
            guard let cc = CIFilter(name: "CIColorControls") else { return image }
            cc.setValue(image, forKey: kCIInputImageKey)
            cc.setValue(1.12, forKey: kCIInputSaturationKey)
            cc.setValue(0.02, forKey: kCIInputBrightnessKey)
            cc.setValue(1.04, forKey: kCIInputContrastKey)
            return cc.outputImage ?? image
        }

        if scene.isWaterScene {
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.00, y: 0.0, z: 0.0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0.0, y: 0.98, z: 0.0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 1.02, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1), forKey: "inputAVector")
            mat.setValue(CIVector(x: -0.004, y: -0.002, z: 0.006, w: 0), forKey: "inputBiasVector")
            return mat.outputImage ?? image
        }

        if scene.isBacklit {
            let centerL = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
            let lift = min(0.05, max(0, (0.55 - centerL / 0.55)) * 0.05)
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 1.0, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            mat.setValue(CIVector(x: lift, y: lift, z: lift, w: 0), forKey: "inputBiasVector")
            return mat.outputImage ?? image
        }

        if kelvin > 6800 && luminance >= 0.18 && luminance <= 0.70 {
            return applyOvercastEnhancement(to: image, luminance: luminance)
        }

        if scene.gRatio > 1.25 && avgG > 0.18 {
            let strength = min(1.0, (scene.gRatio - 1.25) / 0.75) * correctionScale
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0 - 0.02 * strength, y: 0.0, z: 0.0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0.0, y: 1.0, z: 0.0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 1.0 + 0.04 * strength, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0.0, y: 0.0, z: 0.0, w: 1), forKey: "inputAVector")
            return mat.outputImage ?? image
        }

        if kelvin < 4000 {
            let w = min(0.40, (4000 - kelvin) / 3333.0) * correctionScale
            guard let mat = CIFilter(name: "CIColorMatrix") else { return image }
            mat.setValue(image, forKey: kCIInputImageKey)
            mat.setValue(CIVector(x: 1.0 - 0.05 * w, y: 0, z: 0, w: 0), forKey: "inputRVector")
            mat.setValue(CIVector(x: 0, y: 1.0, z: 0, w: 0), forKey: "inputGVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 1.0 + 0.04 * w, w: 0), forKey: "inputBVector")
            mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
            return mat.outputImage ?? image
        }

        let referenceKelvin: CGFloat = 4593.0
        let kelvinDelta = kelvin - referenceKelvin
        let blueAdjust = (-kelvinDelta / 5000.0 * 0.04).clamped(to: -0.04...0.04)
        let brightnessAdjust = (luminance - 0.5) * 0.03

        let rBias = (-blueAdjust * 0.3 + brightnessAdjust) * correctionScale
        let gBias = (-blueAdjust * 0.1 + brightnessAdjust) * correctionScale
        let bBias = (blueAdjust + brightnessAdjust) * correctionScale

        guard let finalMat = CIFilter(name: "CIColorMatrix") else { return image }
        finalMat.setValue(image, forKey: kCIInputImageKey)
        finalMat.setValue(CIVector(x: rBias, y: gBias, z: bBias, w: 0), forKey: "inputBiasVector")
        return finalMat.outputImage ?? image
    }

    // MARK: - Gold 200 Final Balance

    nonisolated private static func applyGold200FinalBalance(to image: CIImage, scene: SceneAnalysis) -> CIImage {
        guard !scene.isNight, let mat = CIFilter(name: "CIColorMatrix") else { return image }

        let sunlight = scene.isSunlit ? 1.0 : 0.45
        let blueContainment = scene.isBlueSkyDominant ? 1.0 : max(0.0, min(1.0, (scene.avgB - scene.avgR - 0.04) / 0.18))
        let goldStrength = (sunlight * (1.0 - blueContainment * 0.20)).clamped(to: 0.0...1.0)

        mat.setValue(image, forKey: kCIInputImageKey)
        mat.setValue(CIVector(x: 1.0 + 0.010 * goldStrength, y: 0, z: 0, w: 0), forKey: "inputRVector")
        mat.setValue(CIVector(x: 0, y: 1.0 + 0.004 * goldStrength, z: 0, w: 0), forKey: "inputGVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 1.0 - 0.018 * goldStrength - 0.035 * blueContainment, w: 0), forKey: "inputBVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        mat.setValue(
            CIVector(
                x: 0.004 * goldStrength,
                y: 0.002 * goldStrength,
                z: -0.004 * goldStrength - 0.005 * blueContainment,
                w: 0
            ),
            forKey: "inputBiasVector"
        )
        return mat.outputImage ?? image
    }

    // MARK: - Overcast Enhancement

    nonisolated private static func applyOvercastEnhancement(to image: CIImage, luminance: CGFloat) -> CIImage {
        guard let satFilter = CIFilter(name: "CIColorControls") else { return image }
        satFilter.setValue(image, forKey: kCIInputImageKey)
        satFilter.setValue(1.12, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.04, forKey: kCIInputContrastKey)
        guard let satOut = satFilter.outputImage else { return image }

        guard let depthFilter = CIFilter(name: "CIColorMatrix") else { return satOut }
        depthFilter.setValue(satOut, forKey: kCIInputImageKey)
        depthFilter.setValue(CIVector(x: 1.03, y: 0.00, z: 0.00, w: 0), forKey: "inputRVector")
        depthFilter.setValue(CIVector(x: 0.00, y: 0.92, z: 0.00, w: 0), forKey: "inputGVector")
        depthFilter.setValue(CIVector(x: 0.00, y: -0.02, z: 0.88, w: 0), forKey: "inputBVector")
        depthFilter.setValue(CIVector(x: 0.00, y: 0.00, z: 0.00, w: 1), forKey: "inputAVector")
        depthFilter.setValue(CIVector(x: 0.010, y: -0.005, z: -0.008, w: 0), forKey: "inputBiasVector")
        return depthFilter.outputImage ?? satOut
    }

    // MARK: - 105mm Enhancement

    nonisolated private static func apply105mmVGEnhancement(to image: CIImage) -> CIImage {
        guard let noiseFilter = CIFilter(name: "CINoiseReduction") else { return image }
        noiseFilter.setValue(image, forKey: kCIInputImageKey)
        noiseFilter.setValue(0.02, forKey: "inputNoiseLevel")
        noiseFilter.setValue(0.0, forKey: "inputSharpness")
        guard let denoised = noiseFilter.outputImage else { return image }

        guard let satFilter = CIFilter(name: "CIColorControls") else { return denoised }
        satFilter.setValue(denoised, forKey: kCIInputImageKey)
        satFilter.setValue(1.02, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.0, forKey: kCIInputContrastKey)
        return satFilter.outputImage ?? denoised
    }

    // MARK: - VG Atmosphere LUT

    nonisolated private static func vgAtmosphereLUT() -> Data? {
        if let data = vgLUTCache { return data }

        let dim = vgLUTDim
        let total = dim * dim * dim * 4
        var cube = [Float](repeating: 0, count: total)

        for bi in 0..<dim {
            for gi in 0..<dim {
                for ri in 0..<dim {
                    let r = Float(ri) / Float(dim - 1)
                    let g = Float(gi) / Float(dim - 1)
                    let b = Float(bi) / Float(dim - 1)

                    let maxC = max(r, max(g, b))
                    let minC = min(r, min(g, b))
                    let delta = maxC - minC
                    let v = maxC
                    let s = maxC > 0.001 ? delta / maxC : 0.0

                    var h: Float = 0.0
                    if delta > 0.001 {
                        if maxC == r {
                            h = (g - b) / delta
                            if h < 0 { h += 6 }
                        } else if maxC == g {
                            h = (b - r) / delta + 2.0
                        } else {
                            h = (r - g) / delta + 4.0
                        }
                        h *= 60.0
                    }

                    let (newH, sMult, vMult) = vgHueMap(hue: h)
                    let isSkin = h >= 15 && h < 42 && s < 0.58 && v > 0.48
                    let effSM = isSkin ? min(sMult, 1.02) : sMult

                    let lowBoost: Float = s < 0.20 ? 1.0 + (0.20 - s) / 0.20 * 0.10 : 1.0
                    let hiClamp: Float = (v > 0.85 && s > 0.70) ? 0.95 : 1.0
                    let blueShadowClamp: Float = (h >= 198 && h < 258)
                        ? (v < 0.55 ? 0.62 : 0.78)
                        : 1.0
                    let cyanClamp: Float = (h >= 165 && h < 198) ? 0.86 : 1.0
                    let yellowLift: Float = (h >= 35 && h < 72 && v > 0.45) ? 1.02 : 1.0

                    let newS = min(s * effSM * lowBoost * hiClamp * blueShadowClamp * cyanClamp, 1.0)
                    let newV = min(v * vMult * yellowLift, 1.0)

                    let (or, og, ob) = hsvToRGBf(h: newH, s: newS, v: newV)

                    let idx = (bi * dim * dim + gi * dim + ri) * 4
                    cube[idx] = or
                    cube[idx + 1] = og
                    cube[idx + 2] = ob
                    cube[idx + 3] = 1.0
                }
            }
        }

        vgLUTCache = Data(bytes: cube, count: total * MemoryLayout<Float>.size)
        return vgLUTCache
    }

    nonisolated private static func vgHueMap(hue: Float) -> (Float, Float, Float) {
        let h = (hue.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360)
        if h < 20 { return (h + 4.0, 1.02, 1.00) }
        if h < 50 { return (h + 4.0, 1.08, 1.02) }
        if h < 75 { return (h + 5.0, 1.12, 1.03) }
        if h < 120 { return (h + 0.0, 1.02, 1.00) }
        if h < 165 { return (h + 1.0, 1.02, 0.99) }
        if h < 200 { return (h - 4.0, 0.92, 1.00) }
        if h < 255 { return (h + 1.0, 0.80, 0.96) }
        if h < 310 { return (h - 3.0, 0.96, 0.99) }
        return (h + 0.0, 0.95, 1.00)
    }

    nonisolated private static func hsvToRGBf(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
        guard s > 0.001 else { return (v, v, v) }
        let hNorm = (h.truncatingRemainder(dividingBy: 360) + 360)
            .truncatingRemainder(dividingBy: 360) / 60.0
        let i = Int(hNorm)
        let f = hNorm - Float(i)
        let p = v * (1 - s)
        let q = v * (1 - s * f)
        let t = v * (1 - s * (1 - f))
        switch i {
        case 0: return (v, t, p)
        case 1: return (q, v, p)
        case 2: return (p, v, t)
        case 3: return (p, q, v)
        case 4: return (t, p, v)
        default: return (v, p, q)
        }
    }

    // MARK: - Math helpers

    nonisolated private static func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        a + (b - a) * t.clamped(to: 0...1)
    }

    nonisolated private static func smoothstep(lo: CGFloat, hi: CGFloat, t: CGFloat) -> CGFloat {
        let x = ((t - lo) / (hi - lo)).clamped(to: 0...1)
        return x * x * (3.0 - 2.0 * x)
    }
}
