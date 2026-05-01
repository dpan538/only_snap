import CoreImage
import Foundation
import Metal
import os

enum LGProcessor {

    nonisolated private static let analysisCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    nonisolated private static let sRGBColorSpace: CGColorSpace = {
        CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
    }()

    nonisolated private static let lgLUTDim = 33
    nonisolated private static let lutCacheLock = OSAllocatedUnfairLock(initialState: LGLUTCacheState())
    nonisolated private static let previewAnalysisInterval: TimeInterval = 0.46
    nonisolated private static let previewStateLock = OSAllocatedUnfairLock(initialState: LGPreviewAnalysisState())

    private struct LGLUTCacheState {
        var order: [String] = []
        var data: [String: Data] = [:]
    }

    private struct LGPreviewAnalysisState {
        var scene: LGSceneAnalysis?
        var params: LGMappingParams = .neutral
        var lastAnalysisTime: TimeInterval = 0
    }

    private struct LGSceneAnalysis {
        let kelvin: CGFloat
        let avgLuma: CGFloat
        let shadowRatio: CGFloat
        let highlightRatio: CGFloat
        let avgSaturation: CGFloat
        let contrast: CGFloat
        let whiteBalanceShift: (rg: CGFloat, bg: CGFloat)
        let avgR: CGFloat
        let avgG: CGFloat
        let avgB: CGFloat
        let centerLuma: CGFloat
        let topLuma: CGFloat

        nonisolated var isLowLight: Bool {
            avgLuma < 0.24 || shadowRatio > 0.58
        }

        nonisolated var isHighContrast: Bool {
            contrast > 0.48 || (shadowRatio > 0.34 && highlightRatio > 0.22)
        }

        nonisolated var lowLightStrength: CGFloat {
            max(
                LGProcessor.smoothstepCG(lo: 0.30, hi: 0.12, t: avgLuma),
                ((shadowRatio - 0.32) / 0.48).clamped(to: 0...1)
            )
        }

        nonisolated var warmProtectStrength: CGFloat {
            let tempFactor = LGProcessor.smoothstepCG(lo: 3200, hi: 6500, t: kelvin)
            let lowLightDamp = isLowLight ? 0.72 : 0.92
            let warmCastDamp = 1.0 - max(0, -whiteBalanceShift.bg) * 0.18
            return (tempFactor * lowLightDamp * warmCastDamp).clamped(to: 0.28...1.0)
        }

        nonisolated var whiteProtectStrength: CGFloat {
            let lowSat = (1.0 - LGProcessor.smoothstepCG(lo: 0.16, hi: 0.34, t: avgSaturation))
            let brightScene = LGProcessor.smoothstepCG(lo: 0.48, hi: 0.82, t: avgLuma)
            let highlightBoost = LGProcessor.smoothstepCG(lo: 0.18, hi: 0.52, t: highlightRatio)
            return (0.42 + lowSat * 0.34 + brightScene * 0.18 + highlightBoost * 0.22).clamped(to: 0.38...1.16)
        }

        nonisolated var neutralBiasStrength: CGFloat {
            let shadowMid = LGProcessor.smoothstepCG(lo: 0.10, hi: 0.38, t: avgLuma)
                * (1.0 - LGProcessor.smoothstepCG(lo: 0.66, hi: 0.90, t: avgLuma))
            let lowSat = 1.0 - LGProcessor.smoothstepCG(lo: 0.08, hi: 0.28, t: avgSaturation)
            return (shadowMid * lowSat * (1.0 - highlightRatio * 0.32)).clamped(to: 0...1)
        }
    }

    private struct LGMappingParams {
        let coolBoost: Float
        let warmProtection: Float
        let whiteProtection: Float
        let neutralBias: Float
        let saturationAdjust: Float
        let hueShift: Float
        let valueLift: Float
        let highlightRolloff: Float

        nonisolated static let neutral = LGMappingParams(
            coolBoost: 1.0,
            warmProtection: 0.78,
            whiteProtection: 0.82,
            neutralBias: 0.76,
            saturationAdjust: 1.0,
            hueShift: 0.0,
            valueLift: 0.0,
            highlightRolloff: 0.018
        )
    }

    nonisolated static func preheatResources() {
        let sample = CIImage(color: CIColor(red: 0.42, green: 0.49, blue: 0.38))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        guard let lutData = lgAtmosphereLUT(params: .neutral),
              let cubeFilter = CIFilter(name: "CIColorCubeWithColorSpace") ?? CIFilter(name: "CIColorCube") else {
            renderWarmup(sample)
            return
        }

        cubeFilter.setValue(lgLUTDim, forKey: "inputCubeDimension")
        cubeFilter.setValue(lutData, forKey: "inputCubeData")
        cubeFilter.setValue(sample, forKey: kCIInputImageKey)
        if cubeFilter.inputKeys.contains("inputColorSpace") {
            cubeFilter.setValue(sRGBColorSpace, forKey: "inputColorSpace")
        }

        renderWarmup(cubeFilter.outputImage ?? sample)
    }

    nonisolated static func apply(
        to image: CIImage,
        focalLength: Int = 28,
        isPreview: Bool = false
    ) -> CIImage {
        _ = focalLength

        let (scene, params) = sceneAndParams(for: image, isPreview: isPreview)
        var output = applyWhiteBalance(to: image, scene: scene, isPreview: isPreview)
        output = applyAdaptiveToneCurve(to: output, scene: scene)

        guard let lutData = lgAtmosphereLUT(params: params),
              let cubeFilter = CIFilter(name: "CIColorCubeWithColorSpace") ?? CIFilter(name: "CIColorCube") else {
            return output
        }

        cubeFilter.setValue(lgLUTDim, forKey: "inputCubeDimension")
        cubeFilter.setValue(lutData, forKey: "inputCubeData")
        cubeFilter.setValue(output, forKey: kCIInputImageKey)
        if cubeFilter.inputKeys.contains("inputColorSpace") {
            cubeFilter.setValue(sRGBColorSpace, forKey: "inputColorSpace")
        }

        output = cubeFilter.outputImage ?? output
        return applyPostControls(to: output, scene: scene, params: params)
    }

    nonisolated private static func sceneAndParams(
        for image: CIImage,
        isPreview: Bool
    ) -> (LGSceneAnalysis, LGMappingParams) {
        guard isPreview else {
            let scene = analyzeImage(image, isPreview: false)
            return (scene, computeMappingParams(from: scene))
        }

        let now = ProcessInfo.processInfo.systemUptime
        let cached = previewStateLock.withLock { state in
            (
                scene: state.scene,
                params: state.params,
                shouldAnalyze: state.scene == nil || now - state.lastAnalysisTime >= previewAnalysisInterval
            )
        }

        guard cached.shouldAnalyze else {
            return (cached.scene ?? fallbackScene(), cached.params)
        }

        let scene = analyzeImage(image, isPreview: true)
        let params = computeMappingParams(from: scene)
        previewStateLock.withLock { state in
            state.scene = scene
            state.params = params
            state.lastAnalysisTime = now
        }
        return (scene, params)
    }

    // MARK: - Scene Analysis

    nonisolated private static func fallbackScene() -> LGSceneAnalysis {
        LGSceneAnalysis(
            kelvin: 5200,
            avgLuma: 0.46,
            shadowRatio: 0.18,
            highlightRatio: 0.12,
            avgSaturation: 0.22,
            contrast: 0.28,
            whiteBalanceShift: (rg: 0, bg: 0),
            avgR: 0.46,
            avgG: 0.46,
            avgB: 0.46,
            centerLuma: 0.46,
            topLuma: 0.46
        )
    }

    nonisolated private static func analyzeImage(_ image: CIImage, isPreview: Bool) -> LGSceneAnalysis {
        let ext = image.extent
        let fallback = fallbackScene()
        guard ext.width > 4, ext.height > 4 else { return fallback }

        let fullExt = ext
        let centerExt = CGRect(
            x: ext.midX - ext.width * 0.22,
            y: ext.midY - ext.height * 0.22,
            width: ext.width * 0.44,
            height: ext.height * 0.44
        )
        let topExt = CGRect(
            x: ext.midX - ext.width * 0.32,
            y: ext.maxY - ext.height * 0.26,
            width: ext.width * 0.64,
            height: ext.height * 0.26
        )

        guard let full = sampleAverage(image, rect: fullExt),
              let center = sampleAverage(image, rect: centerExt) else {
            return fallback
        }
        let top = sampleAverage(image, rect: topExt) ?? full
        let grid = sampleGrid(image, extent: ext, divisions: isPreview ? 2 : 3)
        let lumaSamples = grid.isEmpty ? [luma(full)] : grid.map(\.luma)

        let shadowRatio = CGFloat(lumaSamples.filter { $0 < 0.20 }.count) / CGFloat(max(lumaSamples.count, 1))
        let highlightRatio = CGFloat(lumaSamples.filter { $0 > 0.82 }.count) / CGFloat(max(lumaSamples.count, 1))
        let contrast = ((lumaSamples.max() ?? luma(full)) - (lumaSamples.min() ?? luma(full))).clamped(to: 0...1)

        let avgR = (center.r * 0.58 + full.r * 0.42).clamped(to: 0...1)
        let avgG = (center.g * 0.58 + full.g * 0.42).clamped(to: 0...1)
        let avgB = (center.b * 0.58 + full.b * 0.42).clamped(to: 0...1)
        let avgLuma = luma((r: avgR, g: avgG, b: avgB))
        let avgSaturation = saturation((r: avgR, g: avgG, b: avgB))
        let rgShift = CGFloat(log2(Double(max(avgR, 0.001) / max(avgG, 0.001)))).clamped(to: -1.45...1.45)
        let bgShift = CGFloat(log2(Double(max(avgB, 0.001) / max(avgG, 0.001)))).clamped(to: -1.45...1.45)
        let kelvin = estimateKelvin(
            full: (r: avgR, g: avgG, b: avgB),
            top: top,
            saturation: avgSaturation,
            rgShift: rgShift,
            bgShift: bgShift
        )

        return LGSceneAnalysis(
            kelvin: kelvin,
            avgLuma: avgLuma,
            shadowRatio: shadowRatio,
            highlightRatio: highlightRatio,
            avgSaturation: avgSaturation,
            contrast: contrast,
            whiteBalanceShift: (rg: rgShift, bg: bgShift),
            avgR: avgR,
            avgG: avgG,
            avgB: avgB,
            centerLuma: luma(center),
            topLuma: luma(top)
        )
    }

    nonisolated private static func sampleAverage(
        _ image: CIImage,
        rect: CGRect
    ) -> (r: CGFloat, g: CGFloat, b: CGFloat)? {
        let safeRect = rect.intersection(image.extent)
        guard !safeRect.isNull, safeRect.width > 0, safeRect.height > 0 else { return nil }
        guard let filter = CIFilter(
            name: "CIAreaAverage",
            parameters: [
                kCIInputImageKey: image,
                kCIInputExtentKey: CIVector(cgRect: safeRect)
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
            colorSpace: sRGBColorSpace
        )
        return (
            CGFloat(px[0]) / 255.0,
            CGFloat(px[1]) / 255.0,
            CGFloat(px[2]) / 255.0
        )
    }

    nonisolated private static func sampleGrid(
        _ image: CIImage,
        extent: CGRect,
        divisions: Int
    ) -> [(r: CGFloat, g: CGFloat, b: CGFloat, luma: CGFloat)] {
        guard divisions > 0 else { return [] }
        let stepW = extent.width / CGFloat(divisions)
        let stepH = extent.height / CGFloat(divisions)
        var samples: [(r: CGFloat, g: CGFloat, b: CGFloat, luma: CGFloat)] = []
        samples.reserveCapacity(divisions * divisions)

        for y in 0..<divisions {
            for x in 0..<divisions {
                let rect = CGRect(
                    x: extent.minX + CGFloat(x) * stepW,
                    y: extent.minY + CGFloat(y) * stepH,
                    width: stepW,
                    height: stepH
                ).insetBy(dx: stepW * 0.10, dy: stepH * 0.10)
                guard let sample = sampleAverage(image, rect: rect) else { continue }
                samples.append((sample.r, sample.g, sample.b, luma(sample)))
            }
        }
        return samples
    }

    nonisolated private static func estimateKelvin(
        full: (r: CGFloat, g: CGFloat, b: CGFloat),
        top: (r: CGFloat, g: CGFloat, b: CGFloat),
        saturation: CGFloat,
        rgShift: CGFloat,
        bgShift: CGFloat
    ) -> CGFloat {
        let base = 5200 + bgShift * 1750 - rgShift * 1050
        let topSat = Self.saturation(top)
        let topBlueLead = top.b - max(top.r, top.g)
        let skyWeight = (topBlueLead / 0.16).clamped(to: 0...1)
            * ((top.b - 0.18) / 0.24).clamped(to: 0...1)
            * (topSat / 0.26).clamped(to: 0...1)
        let warmGreenDamp = full.g > full.r * 1.05 && saturation < 0.26 ? 280 : 0
        return (base + skyWeight * 900 + CGFloat(warmGreenDamp)).clamped(to: 2800...8600)
    }

    // MARK: - Adaptive Pipeline

    nonisolated private static func applyWhiteBalance(
        to image: CIImage,
        scene: LGSceneAnalysis,
        isPreview: Bool
    ) -> CIImage {
        let shiftMagnitude = abs(scene.whiteBalanceShift.rg) + abs(scene.whiteBalanceShift.bg)
        guard shiftMagnitude > 0.035,
              let mat = CIFilter(name: "CIColorMatrix") else {
            return image
        }

        let baseStrength: CGFloat = isPreview ? 0.42 : 0.56
        let lowLightDamp = 1.0 - scene.lowLightStrength * 0.22
        let highContrastDamp = scene.isHighContrast ? 0.88 : 1.0
        let strength = baseStrength * lowLightDamp * highContrastDamp
        let rGain = CGFloat(pow(2.0, Double(-scene.whiteBalanceShift.rg * strength))).clamped(to: 0.86...1.14)
        let bGain = CGFloat(pow(2.0, Double(-scene.whiteBalanceShift.bg * strength))).clamped(to: 0.84...1.18)
        let gGain = (1.0 + (scene.avgG - ((scene.avgR + scene.avgB) * 0.5)) * 0.04).clamped(to: 0.985...1.018)

        mat.setValue(image, forKey: kCIInputImageKey)
        mat.setValue(CIVector(x: rGain, y: 0, z: 0, w: 0), forKey: "inputRVector")
        mat.setValue(CIVector(x: 0, y: gGain, z: 0, w: 0), forKey: "inputGVector")
        mat.setValue(CIVector(x: 0, y: 0, z: bGain, w: 0), forKey: "inputBVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        mat.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        return mat.outputImage ?? image
    }

    nonisolated private static func applyAdaptiveToneCurve(to image: CIImage, scene: LGSceneAnalysis) -> CIImage {
        guard let toneFilter = CIFilter(name: "CIToneCurve") else { return image }
        let shadowLift = (scene.shadowRatio * 0.052 + scene.lowLightStrength * 0.018).clamped(to: 0.0...0.066)
        let highlightCompress = (scene.highlightRatio * 0.044 + (scene.isHighContrast ? 0.012 : 0.0))
            .clamped(to: 0.0...0.060)
        let midLift = scene.isLowLight ? 0.008 : 0.0

        toneFilter.setValue(image, forKey: kCIInputImageKey)
        toneFilter.setValue(CIVector(x: 0.00, y: shadowLift * 0.52), forKey: "inputPoint0")
        toneFilter.setValue(CIVector(x: 0.25, y: 0.245 + shadowLift * 0.48), forKey: "inputPoint1")
        toneFilter.setValue(CIVector(x: 0.50, y: 0.500 + midLift), forKey: "inputPoint2")
        toneFilter.setValue(CIVector(x: 0.75, y: 0.755 - highlightCompress * 0.24), forKey: "inputPoint3")
        toneFilter.setValue(CIVector(x: 1.00, y: 1.000 - highlightCompress), forKey: "inputPoint4")
        return toneFilter.outputImage ?? image
    }

    nonisolated private static func applyPostControls(
        to image: CIImage,
        scene: LGSceneAnalysis,
        params: LGMappingParams
    ) -> CIImage {
        guard let controls = CIFilter(name: "CIColorControls") else { return image }
        let contrastLift: CGFloat = scene.avgLuma < 0.30 ? 0.026 : 0.0
        let contrastDamp: CGFloat = scene.isHighContrast ? 0.014 : 0.0

        controls.setValue(image, forKey: kCIInputImageKey)
        controls.setValue(CGFloat(params.saturationAdjust).clamped(to: 0.88...1.10), forKey: kCIInputSaturationKey)
        controls.setValue(0.0, forKey: kCIInputBrightnessKey)
        controls.setValue((1.0 + contrastLift - contrastDamp).clamped(to: 0.97...1.04), forKey: kCIInputContrastKey)
        return controls.outputImage ?? image
    }

    // MARK: - Mapping Params

    nonisolated private static func computeMappingParams(from scene: LGSceneAnalysis) -> LGMappingParams {
        let coolBase: CGFloat
        if scene.kelvin > 6200 {
            coolBase = 1.10 + ((scene.kelvin - 6200) / 2400).clamped(to: 0...1) * 0.16
        } else if scene.kelvin < 4300 {
            coolBase = 0.58 + ((scene.kelvin - 2800) / 1500).clamped(to: 0...1) * 0.24
        } else {
            coolBase = 0.86 + ((scene.kelvin - 4300) / 1900).clamped(to: 0...1) * 0.20
        }

        let lowLightScale = 1.0 - scene.lowLightStrength * 0.26
        let protectScale = scene.isHighContrast ? 0.76 : 1.0
        let satAdjust = (1.02
            + (0.30 - scene.avgSaturation).clamped(to: -0.18...0.22) * 0.22
            - scene.highlightRatio * 0.045
            - scene.lowLightStrength * 0.035)
            .clamped(to: 0.91...1.08)
        let hueShift = ((5200 - scene.kelvin) / 2200 * 0.45).clamped(to: -0.72...0.72)
        let valueLift = (max(0, scene.shadowRatio - 0.28) * 0.048 + scene.lowLightStrength * 0.012)
            .clamped(to: 0.0...0.052)
        let highlightRolloff = (0.012 + scene.highlightRatio * 0.082 + (scene.isHighContrast ? 0.016 : 0.0))
            .clamped(to: 0.012...0.104)

        return LGMappingParams(
            coolBoost: Float((coolBase * lowLightScale).clamped(to: 0.50...1.26)),
            warmProtection: Float((scene.warmProtectStrength * protectScale).clamped(to: 0.24...1.0)),
            whiteProtection: Float((scene.whiteProtectStrength * protectScale).clamped(to: 0.34...1.16)),
            neutralBias: Float((0.48 + scene.neutralBiasStrength * 0.58).clamped(to: 0.42...1.06)),
            saturationAdjust: Float(satAdjust),
            hueShift: Float(hueShift),
            valueLift: Float(valueLift),
            highlightRolloff: Float(highlightRolloff)
        )
    }

    // MARK: - LG Atmosphere LUT

    nonisolated private static func lgAtmosphereLUT(params: LGMappingParams) -> Data? {
        let key = cacheKey(for: params)
        if let cached = lutCacheLock.withLock({ $0.data[key] }) {
            return cached
        }

        let dim = lgLUTDim
        let total = dim * dim * dim * 4
        var cube = [Float](repeating: 0, count: total)

        for bi in 0..<dim {
            for gi in 0..<dim {
                for ri in 0..<dim {
                    let r = Float(ri) / Float(dim - 1)
                    let g = Float(gi) / Float(dim - 1)
                    let b = Float(bi) / Float(dim - 1)
                    let (or, og, ob) = lgMappedRGB(r: r, g: g, b: b, params: params)
                    let idx = (bi * dim * dim + gi * dim + ri) * 4
                    cube[idx] = or
                    cube[idx + 1] = og
                    cube[idx + 2] = ob
                    cube[idx + 3] = 1.0
                }
            }
        }

        let data = Data(bytes: cube, count: total * MemoryLayout<Float>.size)
        lutCacheLock.withLock { cache in
            if cache.data[key] == nil {
                cache.order.append(key)
            }
            cache.data[key] = data
            while cache.order.count > 6 {
                let evicted = cache.order.removeFirst()
                cache.data.removeValue(forKey: evicted)
            }
        }
        return data
    }

    nonisolated private static func lgMappedRGB(
        r: Float,
        g: Float,
        b: Float,
        params: LGMappingParams
    ) -> (Float, Float, Float) {
        let hsv = hsvFromRGBf(r: r, g: g, b: b)
        let y = rec709Luma(r: r, g: g, b: b)
        let warmProtection = warmProtection(hue: hsv.h, saturation: hsv.s, luma: y) * params.warmProtection
        let whiteProtection = whiteProtection(saturation: hsv.s, luma: y) * params.whiteProtection
        let coolStrength = clamp((1.0 - warmProtection * 0.82 - whiteProtection * 0.72) * params.coolBoost, 0.0, 1.24)
        let adjustment = lgAdjustment(hue: hsv.h)

        let hueShift = (adjustment.hueShift + params.hueShift) * coolStrength
        let satStrength = 1.0 - whiteProtection * 0.68
        let satTarget = adjustment.saturationMultiplier * params.saturationAdjust
        let satMult = mix(1.0, satTarget, t: satStrength)
        let valueOffset = (adjustment.valueOffset + params.valueLift) * (1.0 - whiteProtection * 0.55)

        var mappedH = hsv.h + hueShift
        var mappedS = clamp(hsv.s * satMult, 0.0, 1.0)
        var mappedV = clamp(softValueGain(hsv.v + valueOffset, highlight: y, rolloff: params.highlightRolloff), 0.0, 1.0)

        let neutralBias = neutralCoolBias(saturation: hsv.s, luma: y) * coolStrength * params.neutralBias
        if neutralBias > 0 {
            mappedH = mix(mappedH, 184.0, t: neutralBias * 0.18)
            mappedS = clamp(mappedS + neutralBias * 0.030, 0.0, 1.0)
            mappedV = clamp(mappedV + neutralBias * 0.012, 0.0, 1.0)
        }

        let highlightGate = smoothstep(lo: 0.84, hi: 1.0, t: y)
        if highlightGate > 0 {
            mappedV = mix(mappedV, min(mappedV, 0.985), t: highlightGate * params.highlightRolloff)
        }

        var (or, og, ob) = hsvToRGBf(h: mappedH, s: mappedS, v: mappedV)
        let whiteKeep = clamp(whiteProtection * 0.32, 0.0, 0.42)
        if whiteKeep > 0 {
            let neutral = rec709Luma(r: or, g: og, b: ob)
            or = mix(or, neutral, t: whiteKeep)
            og = mix(og, neutral, t: whiteKeep)
            ob = mix(ob, neutral, t: whiteKeep)
        }

        if neutralBias > 0 {
            or = clamp(or - neutralBias * 0.010, 0.0, 1.0)
            og = clamp(og + neutralBias * 0.004, 0.0, 1.0)
            ob = clamp(ob + neutralBias * 0.012, 0.0, 1.0)
        }

        return (clamp(or, 0.0, 1.0), clamp(og, 0.0, 1.0), clamp(ob, 0.0, 1.0))
    }

    nonisolated private static func lgAdjustment(hue: Float) -> (hueShift: Float, saturationMultiplier: Float, valueOffset: Float) {
        let h = normalizedHue(hue)
        if h < 15 || h >= 345 { return (-1.0, 0.970, 0.004) }
        if h < 45 { return (0.0, 0.985, 0.006) }
        if h < 70 { return (4.2, 0.855, -0.010) }
        if h < 105 { return (5.8, 0.905, -0.015) }
        if h < 155 { return (2.0, 0.965, 0.002) }
        if h < 180 { return (0.0, 1.020, 0.008) }
        if h < 205 { return (1.0, 1.030, 0.014) }
        if h < 255 { return (-4.8, 0.922, 0.006) }
        if h < 345 { return (-2.0, 0.900, -0.002) }
        return (0.0, 1.0, 0.0)
    }

    // MARK: - Utility

    nonisolated private static func warmProtection(hue: Float, saturation: Float, luma: Float) -> Float {
        let h = normalizedHue(hue)
        let coreHue: Float
        if h >= 12 && h <= 48 {
            coreHue = 1.0
        } else if h >= 5 && h < 12 {
            coreHue = smoothstep(lo: 5, hi: 12, t: h)
        } else if h > 48 && h <= 58 {
            coreHue = 1.0 - smoothstep(lo: 48, hi: 58, t: h)
        } else {
            coreHue = 0.0
        }

        let satIn = smoothstep(lo: 0.08, hi: 0.18, t: saturation)
        let satOut = 1.0 - smoothstep(lo: 0.62, hi: 0.82, t: saturation)
        let lumaIn = smoothstep(lo: 0.14, hi: 0.28, t: luma)
        let lumaOut = 1.0 - smoothstep(lo: 0.88, hi: 0.98, t: luma)
        return clamp(coreHue * satIn * satOut * lumaIn * lumaOut, 0.0, 1.0)
    }

    nonisolated private static func whiteProtection(saturation: Float, luma: Float) -> Float {
        let lowSat = 1.0 - smoothstep(lo: 0.08, hi: 0.20, t: saturation)
        let highLuma = smoothstep(lo: 0.74, hi: 0.98, t: luma)
        return clamp(lowSat * highLuma, 0.0, 1.0)
    }

    nonisolated private static func neutralCoolBias(saturation: Float, luma: Float) -> Float {
        let lowSat = 1.0 - smoothstep(lo: 0.07, hi: 0.19, t: saturation)
        let shadowMid = smoothstep(lo: 0.06, hi: 0.20, t: luma) * (1.0 - smoothstep(lo: 0.56, hi: 0.84, t: luma))
        return clamp(lowSat * shadowMid, 0.0, 1.0)
    }

    nonisolated private static func cacheKey(for params: LGMappingParams) -> String {
        func q(_ value: Float, scale: Float = 96) -> Int {
            Int((value * scale).rounded())
        }

        return "\(q(params.coolBoost))|\(q(params.warmProtection))|\(q(params.whiteProtection))|\(q(params.neutralBias))|\(q(params.saturationAdjust))|\(q(params.hueShift, scale: 160))|\(q(params.valueLift, scale: 640))|\(q(params.highlightRolloff, scale: 640))"
    }

    nonisolated private static func renderWarmup(_ image: CIImage) {
        var px = [UInt8](repeating: 0, count: 4)
        analysisCIContext.render(
            image,
            toBitmap: &px,
            rowBytes: 4,
            bounds: CGRect(x: 0, y: 0, width: 1, height: 1),
            format: .RGBA8,
            colorSpace: sRGBColorSpace
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

    nonisolated private static func hsvToRGBf(h: Float, s: Float, v: Float) -> (Float, Float, Float) {
        guard s > 0.001 else { return (v, v, v) }
        let hNorm = normalizedHue(h) / 60.0
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

    nonisolated private static func softValueGain(_ value: Float, highlight: Float, rolloff: Float) -> Float {
        let lifted = clamp(value, 0.0, 1.0)
        let rolloffGate = smoothstep(lo: 0.76, hi: 1.0, t: highlight)
        guard rolloffGate > 0 else { return lifted }
        let ceiling = max(0.955, 0.982 - rolloff * 0.16)
        return mix(lifted, min(lifted, ceiling), t: rolloffGate * (0.34 + rolloff * 1.6))
    }

    nonisolated private static func luma(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        0.2126 * rgb.r + 0.7152 * rgb.g + 0.0722 * rgb.b
    }

    nonisolated private static func saturation(_ rgb: (r: CGFloat, g: CGFloat, b: CGFloat)) -> CGFloat {
        let maxC = max(rgb.r, max(rgb.g, rgb.b))
        let minC = min(rgb.r, min(rgb.g, rgb.b))
        return maxC > 0.001 ? (maxC - minC) / maxC : 0.0
    }

    nonisolated private static func rec709Luma(r: Float, g: Float, b: Float) -> Float {
        0.2126 * r + 0.7152 * g + 0.0722 * b
    }

    nonisolated private static func normalizedHue(_ hue: Float) -> Float {
        (hue.truncatingRemainder(dividingBy: 360) + 360).truncatingRemainder(dividingBy: 360)
    }

    nonisolated private static func mix(_ a: Float, _ b: Float, t: Float) -> Float {
        a + (b - a) * clamp(t, 0.0, 1.0)
    }

    nonisolated private static func smoothstep(lo: Float, hi: Float, t: Float) -> Float {
        let x = clamp((t - lo) / (hi - lo), 0.0, 1.0)
        return x * x * (3.0 - 2.0 * x)
    }

    nonisolated private static func smoothstepCG(lo: CGFloat, hi: CGFloat, t: CGFloat) -> CGFloat {
        let x = ((t - lo) / (hi - lo)).clamped(to: 0...1)
        return x * x * (3.0 - 2.0 * x)
    }

    nonisolated private static func clamp(_ value: Float, _ lower: Float, _ upper: Float) -> Float {
        min(max(value, lower), upper)
    }
}
