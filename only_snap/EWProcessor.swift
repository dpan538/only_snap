import CoreImage
import Metal

enum EWProcessor {

    nonisolated private static let analysisCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device)
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    private struct EWSceneAnalysis {
        let averageLuma: CGFloat
        let centerLuma: CGFloat
        let topLuma: CGFloat
        let avgR: CGFloat
        let avgG: CGFloat
        let avgB: CGFloat
        let p10: CGFloat
        let p50: CGFloat
        let p90: CGFloat
        let p95: CGFloat

        nonisolated var contrastIndex: CGFloat {
            max(abs(topLuma - centerLuma), abs(topLuma - averageLuma), abs(centerLuma - averageLuma))
        }

        nonisolated var dynamicRange: CGFloat {
            (p95 - p10).clamped(to: 0...1)
        }

        nonisolated var midDensity: CGFloat {
            (1.0 - abs(0.5 - p50) / 0.5).clamped(to: 0...1)
        }

        nonisolated var highlightCompressNeed: CGFloat {
            ((p95 - 0.74) / 0.26).clamped(to: 0...1)
        }

        nonisolated var shadowLiftNeed: CGFloat {
            (1.0 - p10 / 0.14).clamped(to: 0...1)
        }

        nonisolated var lowContrastNeed: CGFloat {
            ((0.32 - dynamicRange) / 0.32).clamped(to: 0...1) * midDensity
        }

        nonisolated var darkNeed: CGFloat {
            ((0.34 - averageLuma) / 0.24).clamped(to: 0...1)
        }

        nonisolated var highContrastNeed: CGFloat {
            max(
                ((contrastIndex - 0.10) / 0.22).clamped(to: 0...1),
                highlightCompressNeed * dynamicRange
            )
        }

        nonisolated var overcastSoftNeed: CGFloat {
            let flatSky = ((0.76 - topLuma) / 0.30).clamped(to: 0...1)
            return (lowContrastNeed * flatSky * (1.0 - darkNeed * 0.5)).clamped(to: 0...1)
        }

        nonisolated var warmScore: CGFloat {
            ((avgR / max(avgB, 0.001) - 1.0) / 0.8).clamped(to: 0...1)
        }
    }

    private struct ToneCurve {
        let p0: CGFloat
        let p1: CGFloat
        let p2: CGFloat
        let p3: CGFloat
        let p4: CGFloat
    }

    nonisolated static func preheatResources() {
        let sample = CIImage(color: CIColor(red: 0.62, green: 0.62, blue: 0.60))
            .cropped(to: CGRect(x: 0, y: 0, width: 32, height: 32))
        renderWarmup(apply(to: sample, useFastAnalysis: true))
    }

    nonisolated static func apply(
        to image: CIImage,
        focalLength: Int = 28,
        useFastAnalysis: Bool = false
    ) -> CIImage {
        let scene = analyzeImage(image, includeHistogram: !useFastAnalysis)
        let monochrome = applyToneMappedMonochrome(to: image, scene: scene)
        let adaptive = applyAdaptiveTone(to: monochrome, scene: scene, focalLength: focalLength)
        return applySoftWhitePolish(to: adaptive, scene: scene, focalLength: focalLength)
    }

    nonisolated private static let rec709Red: CGFloat = 0.2126
    nonisolated private static let rec709Green: CGFloat = 0.7152
    nonisolated private static let rec709Blue: CGFloat = 0.0722

    nonisolated private static func applyToneMappedMonochrome(to image: CIImage, scene: EWSceneAnalysis) -> CIImage {
        guard let matrix = CIFilter(name: "CIColorMatrix"),
              let toneCurve = CIFilter(name: "CIToneCurve") else {
            return image
        }

        matrix.setValue(image, forKey: kCIInputImageKey)
        let weights = monochromeWeights(for: scene)
        let rVector = CIVector(x: weights.r, y: weights.g, z: weights.b, w: 0)
        matrix.setValue(rVector, forKey: "inputRVector")
        matrix.setValue(rVector, forKey: "inputGVector")
        matrix.setValue(rVector, forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 0), forKey: "inputBiasVector")
        let grayscale = matrix.outputImage ?? image

        toneCurve.setValue(grayscale, forKey: kCIInputImageKey)
        toneCurve.setValue(CIVector(x: 0.0, y: 4.0 / 255.0), forKey: "inputPoint0")
        toneCurve.setValue(CIVector(x: 64.0 / 255.0, y: 70.0 / 255.0), forKey: "inputPoint1")
        toneCurve.setValue(CIVector(x: 128.0 / 255.0, y: 132.0 / 255.0), forKey: "inputPoint2")
        toneCurve.setValue(CIVector(x: 220.0 / 255.0, y: 216.0 / 255.0), forKey: "inputPoint3")
        toneCurve.setValue(CIVector(x: 1.0, y: 250.0 / 255.0), forKey: "inputPoint4")
        return toneCurve.outputImage ?? grayscale
    }

    nonisolated private static func analyzeImage(_ image: CIImage, includeHistogram: Bool) -> EWSceneAnalysis {
        let ext = image.extent
        let fallback = EWSceneAnalysis(
            averageLuma: 0.5,
            centerLuma: 0.5,
            topLuma: 0.5,
            avgR: 0.5,
            avgG: 0.5,
            avgB: 0.5,
            p10: 0.18,
            p50: 0.5,
            p90: 0.82,
            p95: 0.88
        )
        guard ext.width > 4, ext.height > 4 else { return fallback }

        let centerExt = CGRect(
            x: ext.midX - ext.width * 0.20,
            y: ext.midY - ext.height * 0.20,
            width: ext.width * 0.40,
            height: ext.height * 0.40
        )
        let topExt = CGRect(
            x: ext.midX - ext.width * 0.30,
            y: ext.maxY - ext.height * 0.25,
            width: ext.width * 0.60,
            height: ext.height * 0.25
        )

        func sample(_ rect: CGRect) -> (r: CGFloat, g: CGFloat, b: CGFloat, luma: CGFloat)? {
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

            let r = CGFloat(px[0]) / 255.0
            let g = CGFloat(px[1]) / 255.0
            let b = CGFloat(px[2]) / 255.0
            return (r, g, b, rec709Red * r + rec709Green * g + rec709Blue * b)
        }

        guard let average = sample(ext) else { return fallback }
        let center = sample(centerExt)
        let top = sample(topExt)
        let histogram = includeHistogram ? lumaPercentiles(for: image, extent: ext) : nil
        let sampledLow = min(average.luma, center?.luma ?? average.luma, top?.luma ?? average.luma)
        let sampledHigh = max(average.luma, center?.luma ?? average.luma, top?.luma ?? average.luma)
        return EWSceneAnalysis(
            averageLuma: average.luma,
            centerLuma: center?.luma ?? average.luma,
            topLuma: top?.luma ?? average.luma,
            avgR: average.r,
            avgG: average.g,
            avgB: average.b,
            p10: histogram?.p10 ?? (sampledLow * 0.88).clamped(to: 0...1),
            p50: histogram?.p50 ?? average.luma,
            p90: histogram?.p90 ?? sampledHigh,
            p95: histogram?.p95 ?? min(1.0, sampledHigh * 1.04 + 0.02)
        )
    }

    nonisolated private static func applyAdaptiveTone(
        to image: CIImage,
        scene: EWSceneAnalysis,
        focalLength: Int
    ) -> CIImage {
        guard let toneCurve = CIFilter(name: "CIToneCurve") else { return image }
        toneCurve.setValue(image, forKey: kCIInputImageKey)

        let teleDamping: CGFloat = focalLength >= 77 ? 0.72 : 1.0
        let brightWeight = scene.highlightCompressNeed * (0.45 + scene.dynamicRange * 0.55)
        let highWeight = scene.highContrastNeed * teleDamping
        let lowWeight = scene.lowContrastNeed * (0.65 + scene.overcastSoftNeed * 0.35)
        let darkWeight = scene.darkNeed * teleDamping
        let normalWeight: CGFloat = 0.70

        let curve = blendCurves(
            [
                ToneCurve(p0: 0.016, p1: 0.188, p2: 0.508, p3: 0.785, p4: 0.938),
                ToneCurve(p0: 0.018, p1: 0.202, p2: 0.512, p3: 0.792, p4: 0.948),
                ToneCurve(p0: 0.017, p1: 0.224, p2: 0.528, p3: 0.822, p4: 0.968),
                ToneCurve(p0: 0.022, p1: 0.216, p2: 0.514, p3: 0.788, p4: 0.940),
                ToneCurve(p0: 0.014, p1: 0.210, p2: 0.514, p3: 0.812, p4: 0.962)
            ],
            weights: [
                brightWeight,
                highWeight,
                lowWeight,
                darkWeight,
                normalWeight
            ]
        )

        toneCurve.setValue(CIVector(x: 0.00, y: curve.p0), forKey: "inputPoint0")
        toneCurve.setValue(CIVector(x: 0.24, y: curve.p1), forKey: "inputPoint1")
        toneCurve.setValue(CIVector(x: 0.50, y: curve.p2), forKey: "inputPoint2")
        toneCurve.setValue(CIVector(x: 0.78, y: curve.p3), forKey: "inputPoint3")
        toneCurve.setValue(CIVector(x: 1.00, y: curve.p4), forKey: "inputPoint4")
        return toneCurve.outputImage ?? image
    }

    nonisolated private static func applySoftWhitePolish(
        to image: CIImage,
        scene: EWSceneAnalysis,
        focalLength: Int
    ) -> CIImage {
        guard let controls = CIFilter(name: "CIColorControls") else { return image }
        let teleDamping: CGFloat = focalLength >= 77 ? 0.70 : 1.0
        let contrast = (0.995
            - 0.060 * scene.highlightCompressNeed
            - 0.035 * scene.darkNeed * teleDamping
            - 0.025 * scene.overcastSoftNeed
            + 0.018 * scene.lowContrastNeed * (1.0 - scene.highlightCompressNeed))
            .clamped(to: 0.90...1.01)
        let brightness = (0.002
            + 0.010 * scene.shadowLiftNeed * teleDamping
            - 0.010 * scene.highlightCompressNeed)
            .clamped(to: -0.010...0.016)

        controls.setValue(image, forKey: kCIInputImageKey)
        controls.setValue(0.0, forKey: kCIInputSaturationKey)
        controls.setValue(brightness, forKey: kCIInputBrightnessKey)
        controls.setValue(contrast, forKey: kCIInputContrastKey)
        return controls.outputImage ?? image
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

    nonisolated private static func monochromeWeights(for scene: EWSceneAnalysis) -> (r: CGFloat, g: CGFloat, b: CGFloat) {
        let warm = scene.warmScore * (1.0 - scene.highlightCompressNeed * 0.35)
        let red = lerp(rec709Red, 0.2626, t: warm)
        let green = lerp(rec709Green, 0.6744, t: warm)
        let blue = lerp(rec709Blue, 0.0630, t: warm)
        let total = max(red + green + blue, 0.001)
        return (red / total, green / total, blue / total)
    }

    nonisolated private static func lumaPercentiles(
        for image: CIImage,
        extent: CGRect
    ) -> (p10: CGFloat, p50: CGFloat, p90: CGFloat, p95: CGFloat)? {
        guard let matrix = CIFilter(name: "CIColorMatrix") else { return nil }
        let lumaVector = CIVector(x: rec709Red, y: rec709Green, z: rec709Blue, w: 0)
        matrix.setValue(image, forKey: kCIInputImageKey)
        matrix.setValue(lumaVector, forKey: "inputRVector")
        matrix.setValue(lumaVector, forKey: "inputGVector")
        matrix.setValue(lumaVector, forKey: "inputBVector")
        matrix.setValue(CIVector(x: 0, y: 0, z: 0, w: 1), forKey: "inputAVector")
        guard let lumaImage = matrix.outputImage,
              let histogram = CIFilter(
                name: "CIAreaHistogram",
                parameters: [
                    kCIInputImageKey: lumaImage,
                    kCIInputExtentKey: CIVector(cgRect: extent),
                    "inputCount": 256,
                    "inputScale": 1.0
                ]
              )?.outputImage else {
            return nil
        }

        var bins = [Float](repeating: 0, count: 256 * 4)
        analysisCIContext.render(
            histogram,
            toBitmap: &bins,
            rowBytes: 256 * 4 * MemoryLayout<Float>.size,
            bounds: CGRect(x: 0, y: 0, width: 256, height: 1),
            format: .RGBAf,
            colorSpace: nil
        )

        let counts = stride(from: 0, to: bins.count, by: 4).map { max(0, CGFloat(bins[$0])) }
        let total = counts.reduce(0, +)
        guard total > 0 else { return nil }

        func percentile(_ target: CGFloat) -> CGFloat {
            let threshold = total * target
            var cumulative: CGFloat = 0
            for (index, value) in counts.enumerated() {
                cumulative += value
                if cumulative >= threshold {
                    return CGFloat(index) / 255.0
                }
            }
            return 1.0
        }

        return (
            percentile(0.10),
            percentile(0.50),
            percentile(0.90),
            percentile(0.95)
        )
    }

    nonisolated private static func blendCurves(_ curves: [ToneCurve], weights: [CGFloat]) -> ToneCurve {
        let total = max(weights.reduce(0, +), 0.001)
        var mixed = ToneCurve(p0: 0, p1: 0, p2: 0, p3: 0, p4: 0)
        for (curve, weight) in zip(curves, weights) {
            let w = weight / total
            mixed = ToneCurve(
                p0: mixed.p0 + curve.p0 * w,
                p1: mixed.p1 + curve.p1 * w,
                p2: mixed.p2 + curve.p2 * w,
                p3: mixed.p3 + curve.p3 * w,
                p4: mixed.p4 + curve.p4 * w
            )
        }
        return mixed
    }

    nonisolated private static func lerp(_ a: CGFloat, _ b: CGFloat, t: CGFloat) -> CGFloat {
        a + (b - a) * t.clamped(to: 0...1)
    }
}
