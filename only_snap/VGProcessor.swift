import CoreImage
import Foundation
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
    nonisolated private static let kelvinLUT = KelvinLookupTable.build()

    private struct KelvinLookupTable {
        let size: Int
        let rgRange: ClosedRange<CGFloat>
        let bgRange: ClosedRange<CGFloat>
        let values: [CGFloat]

        nonisolated func sample(rg: CGFloat, bg: CGFloat) -> CGFloat {
            let rgNorm = ((rg.clamped(to: rgRange) - rgRange.lowerBound) / (rgRange.upperBound - rgRange.lowerBound))
                .clamped(to: 0...1)
            let bgNorm = ((bg.clamped(to: bgRange) - bgRange.lowerBound) / (bgRange.upperBound - bgRange.lowerBound))
                .clamped(to: 0...1)
            let x = rgNorm * CGFloat(size - 1)
            let y = bgNorm * CGFloat(size - 1)
            let x0 = Int(floor(x))
            let y0 = Int(floor(y))
            let x1 = min(size - 1, x0 + 1)
            let y1 = min(size - 1, y0 + 1)
            let tx = x - CGFloat(x0)
            let ty = y - CGFloat(y0)

            let a = values[y0 * size + x0]
            let b = values[y0 * size + x1]
            let c = values[y1 * size + x0]
            let d = values[y1 * size + x1]
            return Self.mix(Self.mix(a, b, t: tx), Self.mix(c, d, t: tx), t: ty)
        }

        nonisolated static func build() -> KelvinLookupTable {
            let size = 128
            let rgRange: ClosedRange<CGFloat> = -1.80...1.60
            let bgRange: ClosedRange<CGFloat> = -2.00...1.60
            let samples = stride(from: 2500, through: 9000, by: 250).map { kelvin -> (k: CGFloat, rg: CGFloat, bg: CGFloat) in
                let rgb = rgbApproximation(forKelvin: CGFloat(kelvin))
                let rg = CGFloat(log2(Double(max(rgb.r, 0.001) / max(rgb.g, 0.001))))
                let bg = CGFloat(log2(Double(max(rgb.b, 0.001) / max(rgb.g, 0.001))))
                return (CGFloat(kelvin), rg, bg)
            }

            var values = [CGFloat](repeating: 4593, count: size * size)
            for y in 0..<size {
                let bg = mix(bgRange.lowerBound, bgRange.upperBound, t: CGFloat(y) / CGFloat(size - 1))
                for x in 0..<size {
                    let rg = mix(rgRange.lowerBound, rgRange.upperBound, t: CGFloat(x) / CGFloat(size - 1))
                    var weightedKelvin: CGFloat = 0
                    var totalWeight: CGFloat = 0
                    for sample in samples {
                        let dist2 = pow(rg - sample.rg, 2) + pow(bg - sample.bg, 2)
                        let weight = 1.0 / max(dist2, 0.0008)
                        weightedKelvin += sample.k * weight
                        totalWeight += weight
                    }
                    values[y * size + x] = (weightedKelvin / max(totalWeight, 0.001)).clamped(to: 2500...9000)
                }
            }

            return KelvinLookupTable(size: size, rgRange: rgRange, bgRange: bgRange, values: values)
        }

        nonisolated private static func rgbApproximation(forKelvin kelvin: CGFloat) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
            let temp = (kelvin / 100.0).clamped(to: 10...400)
            let red: CGFloat
            let green: CGFloat
            let blue: CGFloat

            if temp <= 66 {
                red = 1.0
                green = CGFloat(((99.4708025861 * log(Double(temp)) - 161.1195681661) / 255.0).clamped(to: 0...1))
                blue = temp <= 19
                    ? 0.0
                    : CGFloat(((138.5177312231 * log(Double(temp - 10)) - 305.0447927307) / 255.0).clamped(to: 0...1))
            } else {
                red = CGFloat((329.698727446 * pow(Double(temp - 60), -0.1332047592) / 255.0).clamped(to: 0...1))
                green = CGFloat((288.1221695283 * pow(Double(temp - 60), -0.0755148492) / 255.0).clamped(to: 0...1))
                blue = 1.0
            }

            return (red, green, blue)
        }

        nonisolated private static func mix(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
            a + (b - a) * t.clamped(to: 0...1)
        }
    }

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
        let centerR: CGFloat
        let centerG: CGFloat
        let centerB: CGFloat
        let topR: CGFloat
        let topG: CGFloat
        let topB: CGFloat

        nonisolated var gRatio: CGFloat {
            let midRB = (avgR + avgB) / 2.0
            return midRB > 0.01 ? avgG / midRB : 1.0
        }

        nonisolated var sunsetScore: CGFloat {
            let base = ((3600 - kelvin) / 900).clamped(to: 0...1)
                * ((highlightRatio - 0.24) / 0.22).clamped(to: 0...1)
                * ((luminance - 0.16) / 0.34).clamped(to: 0...1)
            return base
                * (0.20 + 0.80 * warmSkyScore)
                * (1.0 - whiteBalanceProtection * 0.65)
        }
        nonisolated var nightScore: CGFloat {
            ((0.22 - luminance) / 0.18).clamped(to: 0...1)
        }
        nonisolated var fogScore: CGFloat {
            ((hazeScore - 0.32) / 0.28).clamped(to: 0...1)
                * ((luminance - 0.24) / 0.32).clamped(to: 0...1)
        }
        nonisolated var rainScore: CGFloat {
            ((0.24 - satScore) / 0.20).clamped(to: 0...1)
                * ((luminance - 0.20) / 0.42).clamped(to: 0...1)
                * ((0.78 - highlightRatio) / 0.34).clamped(to: 0...1)
        }
        nonisolated var overcastScore: CGFloat {
            max(rainScore, fogScore * 0.72)
        }
        nonisolated var vegetationScore: CGFloat {
            let greenLead = avgG - max(avgR, avgB) * 1.03
            return (greenLead / 0.20).clamped(to: 0...1) * (satScore / 0.32).clamped(to: 0...1)
        }
        nonisolated var waterScore: CGFloat {
            let cbDiff = avgB - avgR
            return (cbDiff / 0.18).clamped(to: 0...1)
                * ((avgB - 0.22) / 0.28).clamped(to: 0...1)
                * (satScore / 0.30).clamped(to: 0...1)
                * (1.0 - nightScore)
        }
        nonisolated var blueSkyScore: CGFloat {
            return ((topB - max(topR, topG)) / 0.16).clamped(to: 0...1)
                * ((topB - 0.18) / 0.24).clamped(to: 0...1)
                * (topSaturation / 0.28).clamped(to: 0...1)
                * ((highlightRatio - 0.28) / 0.30).clamped(to: 0...1)
                * (1.0 - nightScore)
        }
        nonisolated var neutralWhiteScore: CGFloat {
            return ((0.18 - satScore) / 0.18).clamped(to: 0...1)
                * ((0.18 - topSaturation) / 0.18).clamped(to: 0...1)
                * ((luminance - 0.46) / 0.28).clamped(to: 0...1)
                * ((highlightRatio - 0.48) / 0.28).clamped(to: 0...1)
                * (1.0 - nightScore)
        }
        nonisolated var topLuma: CGFloat {
            0.2126 * topR + 0.7152 * topG + 0.0722 * topB
        }
        nonisolated var topSaturation: CGFloat {
            let topMax = max(topR, topG, topB)
            let topMin = min(topR, topG, topB)
            return topMax > 0.01 ? (topMax - topMin) / topMax : 0.0
        }
        nonisolated var topNeutralScore: CGFloat {
            ((0.22 - topSaturation) / 0.22).clamped(to: 0...1)
                * ((topLuma - 0.36) / 0.34).clamped(to: 0...1)
                * (1.0 - nightScore)
        }
        nonisolated var whiteBalanceProtection: CGFloat {
            max(neutralWhiteScore, topNeutralScore * 0.92, blueSkyScore * 0.78)
                .clamped(to: 0...1)
        }
        nonisolated var warmSkyScore: CGFloat {
            let redLead = ((topR - topB) / 0.18).clamped(to: 0...1)
            let amberLead = ((((topR + topG) * 0.5) - topB) / 0.16).clamped(to: 0...1)
            return max(redLead, amberLead)
                * (topSaturation / 0.24).clamped(to: 0...1)
                * ((topLuma - 0.18) / 0.36).clamped(to: 0...1)
                * (1.0 - nightScore)
        }
        nonisolated var warmHighlightProtection: CGFloat {
            let warmCast = ((avgR - avgB) / 0.18).clamped(to: 0...1)
            let warmGreen = ((avgG - avgB) / 0.18).clamped(to: 0...1)
            return max(warmCast, warmGreen * 0.70)
                * ((highlightRatio - 0.52) / 0.32).clamped(to: 0...1)
                * (1.0 - blueSkyScore * 0.55)
                * (1.0 - nightScore)
        }
        nonisolated var sunlitScore: CGFloat {
            ((highlightRatio - 0.40) / 0.30).clamped(to: 0...1)
                * ((luminance - 0.24) / 0.34).clamped(to: 0...1)
                * (1.0 - nightScore)
                * (1.0 - whiteBalanceProtection * 0.88)
        }
        nonisolated var skinPresenceScore: CGFloat {
            let hsv = VGProcessor.hsvFromRGBf(
                r: Float(centerR),
                g: Float(centerG),
                b: Float(centerB)
            )
            let hueFit = hsv.h >= 12 && hsv.h <= 48 ? 1.0 : max(0.0, 1.0 - min(abs(hsv.h - 30), abs(hsv.h - 360 - 30)) / 24.0)
            let satFit = (1.0 - abs(CGFloat(hsv.s) - 0.35) / 0.35).clamped(to: 0...1)
            let valueFit = ((CGFloat(hsv.v) - 0.26) / 0.42).clamped(to: 0...1)
            return CGFloat(hueFit) * satFit * valueFit
        }

        nonisolated var isNight: Bool { nightScore > 0.65 }
        nonisolated var isBlueSkyDominant: Bool { blueSkyScore > 0.35 }
        nonisolated var isNeutralWhiteDominant: Bool { neutralWhiteScore > 0.45 }
    }

    nonisolated static func preheatResources() {
        _ = vgAtmosphereLUT()
        let sample = CIImage(color: CIColor(red: 0.66, green: 0.62, blue: 0.52))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        renderWarmup(apply(to: sample, focalLength: 28))
    }

    nonisolated static func apply(to image: CIImage, focalLength: Int) -> CIImage {
        let processed = applyVGTransform(to: image, skipPreSmooth: false)
        return focalLength >= 77 ? applyLongFocalVGEnhancement(to: processed) : processed
    }

    // MARK: - Multi-zone Scene Analysis

    nonisolated private static func analyzeImage(_ image: CIImage) -> SceneAnalysis {
        let ext = image.extent
        let fallback = SceneAnalysis(kelvin: 4593, luminance: 0.5,
                                     avgR: 0.5, avgG: 0.5, avgB: 0.5,
                                     satScore: 0.2, highlightRatio: 0.4,
                                     hazeScore: 0.1, isBacklit: false,
                                     centerR: 0.5, centerG: 0.5, centerB: 0.5,
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
        let kelvin = estimateKelvin(full: fs, top: topSample, saturation: satScore)

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
            centerR: cs.r,
            centerG: cs.g,
            centerB: cs.b,
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
            let rise = smoothstep(lo: 3200, hi: 5000, t: scene.kelvin)
            let fall = 1.0 - smoothstep(lo: 6000, hi: 8000, t: scene.kelvin)
            let daylightBell = rise * fall
            let goldSignal = max(daylightBell, scene.sunlitScore * 0.60)
                * (1.0 - scene.whiteBalanceProtection * 0.52)
                * (1.0 - scene.warmHighlightProtection * 0.42)
            return (0.20
                + goldSignal * 0.42
                + scene.sunsetScore * 0.24
                + scene.overcastScore * 0.14
                - scene.nightScore * 0.22
                - scene.whiteBalanceProtection * 0.20
                - scene.skinPresenceScore * 0.18)
                .clamped(to: 0.16...0.86)
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

        let targetSat = (0.84
            + (1.0 - scene.satScore) * 0.05
            + scene.overcastScore * 0.04
            + scene.vegetationScore * 0.04
            + scene.sunsetScore * 0.02
            - scene.blueSkyScore * 0.04
            - scene.whiteBalanceProtection * 0.08
            - scene.warmHighlightProtection * 0.04
            - scene.skinPresenceScore * 0.06)
            .clamped(to: 0.74...1.02)
        let finalSat = scene.isNight ? min(targetSat, 0.84) : targetSat

        guard let satFilter = CIFilter(name: "CIColorControls") else { return lutOut }
        satFilter.setValue(lutOut, forKey: kCIInputImageKey)
        satFilter.setValue(finalSat, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.0, forKey: kCIInputContrastKey)
        let satOut = satFilter.outputImage ?? lutOut

        let bloomOut: CIImage
        if !scene.isNight, let bloomFilter = CIFilter(name: "CIBloom") {
            let highlightDamp: CGFloat = scene.highlightRatio > 0.58
                ? (1.0 - ((scene.highlightRatio - 0.58) / 0.30)).clamped(to: 0.0...1.0)
                : 1.0
            let flatBoost: CGFloat = 1.0 + scene.overcastScore * 0.08 + scene.rainScore * 0.04
            let protection = (1.0 - scene.warmHighlightProtection * 0.70)
                * (1.0 - scene.whiteBalanceProtection * 0.35)
            let bloomIntensity = (0.075 * highlightDamp * flatBoost * protection).clamped(to: 0.0...0.12)

            if bloomIntensity > 0.008 {
                bloomFilter.setValue(satOut, forKey: kCIInputImageKey)
                bloomFilter.setValue(9.0, forKey: kCIInputRadiusKey)
                bloomFilter.setValue(bloomIntensity, forKey: kCIInputIntensityKey)
                bloomOut = (bloomFilter.outputImage ?? satOut).cropped(to: satOut.extent)
            } else {
                bloomOut = satOut
            }
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

        let sR: CGFloat = 0.0015 * s
        let sG: CGFloat = 0.000 * s
        let sB: CGFloat = -0.0025 * s

        let hR: CGFloat = 0.008 * s
        let hG: CGFloat = 0.002 * s
        let hB: CGFloat = -0.006 * s

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

        var output = image
        if let controls = CIFilter(name: "CIColorControls") {
            let saturation = (1.0
                + scene.sunsetScore * 0.025
                + scene.overcastScore * 0.040
                + scene.rainScore * 0.030
                + scene.vegetationScore * 0.045
                - scene.blueSkyScore * 0.03
                - scene.whiteBalanceProtection * 0.055
                - scene.warmHighlightProtection * 0.035
                - scene.skinPresenceScore * 0.04)
                .clamped(to: 0.94...1.06)
            let contrast = (1.0
                + scene.fogScore * 0.020
                + scene.rainScore * 0.016
                - scene.nightScore * 0.040
                - scene.neutralWhiteScore * 0.018)
                .clamped(to: 0.94...1.05)
            let brightness = (-0.004 * scene.fogScore
                + 0.006 * scene.rainScore
                + 0.008 * scene.nightScore)
                .clamped(to: -0.010...0.014)
            controls.setValue(output, forKey: kCIInputImageKey)
            controls.setValue(saturation, forKey: kCIInputSaturationKey)
            controls.setValue(brightness, forKey: kCIInputBrightnessKey)
            controls.setValue(contrast, forKey: kCIInputContrastKey)
            output = controls.outputImage ?? output
        }

        let centerL = 0.2126 * avgR + 0.7152 * avgG + 0.0722 * avgB
        let backlitLift = scene.isBacklit
            ? min(0.045, max(0, (0.55 - centerL / 0.55)) * 0.045)
            : 0
        let whiteProtection = scene.whiteBalanceProtection
        let warmProtection = max(whiteProtection, scene.blueSkyScore, scene.warmHighlightProtection * 0.80)
        let greenStrength = (scene.vegetationScore * 0.28 + scene.rainScore * 0.16)
            * correctionScale
            * (1.0 - whiteProtection * 0.42)
        let warmScene = ((4000 - kelvin) / 3000).clamped(to: 0...1)
            * correctionScale
            * (1.0 - warmProtection * 0.82)
        let kelvinDelta = kelvin - 5200.0
        let rawBlueAdjust = (-kelvinDelta / 5600.0 * 0.020).clamped(to: -0.020...0.020)
        let blueAdjust = (rawBlueAdjust < 0
            ? rawBlueAdjust * (1.0 - warmProtection * 0.90)
            : rawBlueAdjust * (1.0 - scene.warmHighlightProtection * 0.35))
            * correctionScale
        let goldLift = (scene.sunlitScore * 0.12 + scene.sunsetScore * 0.16 + scene.overcastScore * 0.055)
            * (1.0 - whiteProtection * 0.82)
            * (1.0 - scene.skinPresenceScore * 0.55)
            * (1.0 - scene.warmHighlightProtection * 0.62)

        guard let mat = CIFilter(name: "CIColorMatrix") else { return output }
        mat.setValue(output, forKey: kCIInputImageKey)
        mat.setValue(CIVector(x: 1.0 + 0.004 * goldLift - 0.006 * warmScene, y: 0, z: 0, w: 0), forKey: "inputRVector")
        mat.setValue(CIVector(x: 0, y: 1.0 + 0.010 * greenStrength + 0.0015 * goldLift, z: 0, w: 0), forKey: "inputGVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 1.0 - 0.006 * goldLift + 0.010 * scene.waterScore, w: 0), forKey: "inputBVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        mat.setValue(
            CIVector(
                x: backlitLift + 0.0010 * goldLift - blueAdjust * 0.10,
                y: backlitLift + 0.0012 * greenStrength - blueAdjust * 0.04,
                z: backlitLift + blueAdjust + 0.0025 * scene.waterScore - 0.0008 * goldLift,
                w: 0
            ),
            forKey: "inputBiasVector"
        )
        return mat.outputImage ?? output
    }

    // MARK: - Gold 200 Final Balance

    nonisolated private static func applyGold200FinalBalance(to image: CIImage, scene: SceneAnalysis) -> CIImage {
        guard scene.nightScore < 0.85, let mat = CIFilter(name: "CIColorMatrix") else { return image }

        let blueContainment = max(scene.blueSkyScore, ((scene.avgB - scene.avgR - 0.04) / 0.18).clamped(to: 0...1))
        let neutralWhiteProtection = 1.0 - scene.whiteBalanceProtection * 0.86
        let skinProtection = 1.0 - scene.skinPresenceScore * 0.60
        let highlightProtection = 1.0 - scene.warmHighlightProtection * 0.72
        let goldStrength = (0.18
            + scene.sunlitScore * 0.58
            + scene.sunsetScore * 0.42
            + scene.overcastScore * 0.30
            + scene.vegetationScore * 0.16
            - blueContainment * 0.14)
            .clamped(to: 0.0...0.82)
            * 0.46
            * neutralWhiteProtection
            * skinProtection
            * highlightProtection
        let rainGreenLift = (scene.overcastScore * 0.006 + scene.vegetationScore * 0.007)
            * (1.0 - scene.whiteBalanceProtection * 0.58)
        let whiteBiasProtection = 1.0 - scene.whiteBalanceProtection

        mat.setValue(image, forKey: kCIInputImageKey)
        mat.setValue(CIVector(x: 1.0 + 0.006 * goldStrength, y: 0, z: 0, w: 0), forKey: "inputRVector")
        mat.setValue(CIVector(x: 0, y: 1.0 + 0.003 * goldStrength + rainGreenLift, z: 0, w: 0), forKey: "inputGVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 1.0 - 0.010 * goldStrength - 0.004 * blueContainment, w: 0), forKey: "inputBVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        mat.setValue(
            CIVector(
                x: 0.0012 * goldStrength * whiteBiasProtection,
                y: 0.0006 * goldStrength * whiteBiasProtection + rainGreenLift * 0.18,
                z: -0.0010 * goldStrength - 0.0008 * blueContainment,
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
        satFilter.setValue(1.02, forKey: kCIInputSaturationKey)
        satFilter.setValue(0.0, forKey: kCIInputBrightnessKey)
        satFilter.setValue(1.015, forKey: kCIInputContrastKey)
        guard let satOut = satFilter.outputImage else { return image }

        guard let depthFilter = CIFilter(name: "CIColorMatrix") else { return satOut }
        depthFilter.setValue(satOut, forKey: kCIInputImageKey)
        depthFilter.setValue(CIVector(x: 1.006, y: 0.00, z: 0.00, w: 0), forKey: "inputRVector")
        depthFilter.setValue(CIVector(x: 0.00, y: 0.998, z: 0.00, w: 0), forKey: "inputGVector")
        depthFilter.setValue(CIVector(x: 0.00, y: 0.00, z: 0.990, w: 0), forKey: "inputBVector")
        depthFilter.setValue(CIVector(x: 0.00, y: 0.00, z: 0.00, w: 1), forKey: "inputAVector")
        depthFilter.setValue(CIVector(x: 0.001, y: 0.000, z: -0.001, w: 0), forKey: "inputBiasVector")
        return depthFilter.outputImage ?? satOut
    }

    // MARK: - Long-Focal Enhancement

    nonisolated private static func applyLongFocalVGEnhancement(to image: CIImage) -> CIImage {
        guard let noiseFilter = CIFilter(name: "CINoiseReduction") else { return image }
        noiseFilter.setValue(image, forKey: kCIInputImageKey)
        noiseFilter.setValue(0.02, forKey: "inputNoiseLevel")
        noiseFilter.setValue(0.0, forKey: "inputSharpness")
        guard let denoised = noiseFilter.outputImage else { return image }

        guard let satFilter = CIFilter(name: "CIColorControls") else { return denoised }
        satFilter.setValue(denoised, forKey: kCIInputImageKey)
        satFilter.setValue(1.00, forKey: kCIInputSaturationKey)
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

                    let (mappedH, sMult, vMult) = vgHueMap(hue: h)
                    let isSkin = h >= 15 && h < 42 && s < 0.58 && v > 0.48
                    let newH = isSkin ? h + (mappedH - h) * 0.18 : mappedH
                    let effSM = isSkin ? min(sMult, 1.00) : sMult

                    let lowBoost: Float = s < 0.20 ? 1.0 + (0.20 - s) / 0.20 * 0.10 : 1.0
                    let hiClamp: Float = (v > 0.85 && s > 0.70) ? 0.95 : 1.0
                    let blueShadowClamp: Float = (h >= 198 && h < 258)
                        ? (v < 0.55 ? 0.62 : 0.78)
                        : 1.0
                    let cyanClamp: Float = (h >= 165 && h < 198) ? 0.86 : 1.0
                    let yellowLift: Float = (h >= 42 && h < 68 && s > 0.35 && v < 0.78) ? 1.01 : 1.0

                    let newS = min(s * effSM * lowBoost * hiClamp * blueShadowClamp * cyanClamp, 1.0)
                    let newV = softValueGain(v, gain: vMult * yellowLift)

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
        if h < 20 { return (h + 0.5, 1.00, 1.00) }
        if h < 50 { return (h + 1.0, 1.01, 1.00) }
        if h < 75 { return (h + 1.5, 1.02, 1.00) }
        if h < 120 { return (h + 0.0, 1.015, 1.00) }
        if h < 165 { return (h + 1.0, 1.02, 0.99) }
        if h < 200 { return (h + 2.0, 0.88, 1.00) }
        if h < 255 { return (h + 0.0, 0.76, 0.98) }
        if h < 310 { return (h - 3.0, 0.96, 0.99) }
        return (h + 0.0, 0.95, 1.00)
    }

    nonisolated private static func estimateKelvin(
        full: (r: CGFloat, g: CGFloat, b: CGFloat),
        top: (r: CGFloat, g: CGFloat, b: CGFloat),
        saturation: CGFloat
    ) -> CGFloat {
        let rg = CGFloat(log2(Double(max(full.r, 0.001) / max(full.g, 0.001))))
        let bg = CGFloat(log2(Double(max(full.b, 0.001) / max(full.g, 0.001))))
        let greenDominant = full.g > full.r * 1.05 && full.g > full.b
        let greenSuppression: CGFloat = greenDominant && saturation < 0.30 ? 0.68 : 1.0
        let baseKelvin = kelvinLUT.sample(rg: rg * greenSuppression, bg: bg)

        let topMax = max(top.r, top.g, top.b)
        let topMin = min(top.r, top.g, top.b)
        let topSat = topMax > 0.01 ? (topMax - topMin) / topMax : 0.0
        let topLuma = 0.2126 * top.r + 0.7152 * top.g + 0.0722 * top.b
        let topNeutralWeight = ((0.22 - topSat) / 0.22).clamped(to: 0...1)
            * ((topLuma - 0.36) / 0.34).clamped(to: 0...1)
        let neutralKelvin = baseKelvin < 5200 ? 5600 : baseKelvin
        let neutralAwareKelvin = lerp(baseKelvin, neutralKelvin, t: topNeutralWeight * 0.55)

        let skyLead = top.b - max(top.r, top.g)
        let skyWeight = (skyLead / 0.15).clamped(to: 0...1)
            * ((top.b - 0.18) / 0.22).clamped(to: 0...1)
        let skyKelvin = max(7000, neutralAwareKelvin)
        return lerp(neutralAwareKelvin, skyKelvin, t: skyWeight).clamped(to: 2500...9000)
    }

    nonisolated private static func renderWarmup(_ image: CIImage) {
        var px = [UInt8](repeating: 0, count: 4)
        analysisCIContext.render(
            image,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: CGColorSpaceCreateDeviceRGB()
        )
    }

    nonisolated private static func hsvFromRGBf(r: Float, g: Float, b: Float) -> (h: Float, s: Float, v: Float) {
        let maxC = max(r, max(g, b))
        let minC = min(r, min(g, b))
        let delta = maxC - minC
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

        return (h, s, maxC)
    }

    nonisolated private static func softValueGain(_ value: Float, gain: Float) -> Float {
        let boosted = min(value * gain, 1.0)
        guard gain > 1.0, value > 0.88 else { return boosted }
        return min(value + (boosted - value) * 0.28, 0.985)
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
