import CoreImage
import Metal

enum EWProcessor {

    nonisolated(unsafe) private static var ewToneCubeCache: Data?
    nonisolated private static let ewCubeDimension = 33
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

        nonisolated var contrastIndex: CGFloat {
            max(abs(topLuma - centerLuma), abs(topLuma - averageLuma), abs(centerLuma - averageLuma))
        }

        nonisolated var isHighContrast: Bool {
            contrastIndex > 0.22 || (topLuma > 0.62 && centerLuma < 0.42)
        }

        nonisolated var isLowContrast: Bool {
            contrastIndex < 0.08 && averageLuma > 0.22 && averageLuma < 0.76
        }

        nonisolated var isDark: Bool {
            averageLuma < 0.24
        }
    }

    nonisolated private static let ewCurvePoints: [(input: CGFloat, output: CGFloat)] = [
        (0, 4),
        (24, 22),
        (64, 70),
        (128, 132),
        (176, 188),
        (220, 216),
        (255, 250)
    ]

    nonisolated static func preheatResources() {
        _ = ewToneCubeData()
    }

    nonisolated static func apply(to image: CIImage) -> CIImage {
        let scene = analyzeImage(image)
        let monochrome = applyToneMappedMonochrome(to: image)
        let adaptive = applyAdaptiveTone(to: monochrome, scene: scene)
        return applySoftWhitePolish(to: adaptive, scene: scene)
    }

    nonisolated private static let rec709Red: CGFloat = 0.2126
    nonisolated private static let rec709Green: CGFloat = 0.7152
    nonisolated private static let rec709Blue: CGFloat = 0.0722

    nonisolated private static func applyToneMappedMonochrome(to image: CIImage) -> CIImage {
        guard let cubeData = ewToneCubeData(),
              let cube = CIFilter(name: "CIColorCube") else {
            return fallbackMonochrome(to: image)
        }

        cube.setValue(ewCubeDimension, forKey: "inputCubeDimension")
        cube.setValue(cubeData, forKey: "inputCubeData")
        cube.setValue(image, forKey: kCIInputImageKey)
        return cube.outputImage ?? fallbackMonochrome(to: image)
    }

    nonisolated private static func fallbackMonochrome(to image: CIImage) -> CIImage {
        guard let matrix = CIFilter(name: "CIColorMatrix"),
              let toneCurve = CIFilter(name: "CIToneCurve") else {
            return image
        }

        matrix.setValue(image, forKey: kCIInputImageKey)
        let rVector = CIVector(x: rec709Red, y: rec709Green, z: rec709Blue, w: 0)
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

    nonisolated private static func analyzeImage(_ image: CIImage) -> EWSceneAnalysis {
        let ext = image.extent
        let fallback = EWSceneAnalysis(averageLuma: 0.5, centerLuma: 0.5, topLuma: 0.5)
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

        func luma(_ rect: CGRect) -> CGFloat? {
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
            return rec709Red * r + rec709Green * g + rec709Blue * b
        }

        guard let average = luma(ext) else { return fallback }
        return EWSceneAnalysis(
            averageLuma: average,
            centerLuma: luma(centerExt) ?? average,
            topLuma: luma(topExt) ?? average
        )
    }

    nonisolated private static func applyAdaptiveTone(to image: CIImage, scene: EWSceneAnalysis) -> CIImage {
        guard let toneCurve = CIFilter(name: "CIToneCurve") else { return image }
        toneCurve.setValue(image, forKey: kCIInputImageKey)

        let p0: CGFloat
        let p1: CGFloat
        let p2: CGFloat
        let p3: CGFloat
        let p4: CGFloat

        if scene.isHighContrast {
            p0 = 0.010
            p1 = 0.170
            p2 = 0.510
            p3 = 0.820
            p4 = 0.965
        } else if scene.isLowContrast {
            p0 = 0.020
            p1 = 0.235
            p2 = 0.535
            p3 = 0.805
            p4 = 0.965
        } else if scene.isDark {
            p0 = 0.018
            p1 = 0.220
            p2 = 0.520
            p3 = 0.800
            p4 = 0.955
        } else {
            p0 = 0.015
            p1 = 0.215
            p2 = 0.515
            p3 = 0.805
            p4 = 0.965
        }

        toneCurve.setValue(CIVector(x: 0.00, y: p0), forKey: "inputPoint0")
        toneCurve.setValue(CIVector(x: 0.24, y: p1), forKey: "inputPoint1")
        toneCurve.setValue(CIVector(x: 0.50, y: p2), forKey: "inputPoint2")
        toneCurve.setValue(CIVector(x: 0.78, y: p3), forKey: "inputPoint3")
        toneCurve.setValue(CIVector(x: 1.00, y: p4), forKey: "inputPoint4")
        return toneCurve.outputImage ?? image
    }

    nonisolated private static func applySoftWhitePolish(to image: CIImage, scene: EWSceneAnalysis) -> CIImage {
        guard let controls = CIFilter(name: "CIColorControls") else { return image }
        controls.setValue(image, forKey: kCIInputImageKey)
        controls.setValue(0.0, forKey: kCIInputSaturationKey)
        controls.setValue(scene.isLowContrast ? 0.008 : 0.004, forKey: kCIInputBrightnessKey)
        controls.setValue(scene.isHighContrast ? 0.99 : (scene.isLowContrast ? 0.91 : 0.95), forKey: kCIInputContrastKey)
        return controls.outputImage ?? image
    }

    nonisolated private static func ewToneCubeData() -> Data? {
        if let cache = ewToneCubeCache { return cache }

        let dim = ewCubeDimension
        let total = dim * dim * dim * 4
        var cube = [Float](repeating: 0, count: total)

        for blueIndex in 0..<dim {
            for greenIndex in 0..<dim {
                for redIndex in 0..<dim {
                    let r = CGFloat(redIndex) / CGFloat(dim - 1)
                    let g = CGFloat(greenIndex) / CGFloat(dim - 1)
                    let b = CGFloat(blueIndex) / CGFloat(dim - 1)
                    let luminance = rec709Red * r + rec709Green * g + rec709Blue * b
                    let curved = curveMappedValue(for: luminance)
                    let output = Float(curved)

                    let idx = (blueIndex * dim * dim + greenIndex * dim + redIndex) * 4
                    cube[idx] = output
                    cube[idx + 1] = output
                    cube[idx + 2] = output
                    cube[idx + 3] = 1.0
                }
            }
        }

        ewToneCubeCache = Data(bytes: cube, count: total * MemoryLayout<Float>.size)
        return ewToneCubeCache
    }

    nonisolated private static func curveMappedValue(for normalizedInput: CGFloat) -> CGFloat {
        let input = (normalizedInput.clamped(to: 0...1)) * 255.0

        guard let first = ewCurvePoints.first, let last = ewCurvePoints.last else {
            return normalizedInput
        }
        if input <= first.input { return first.output / 255.0 }
        if input >= last.input { return last.output / 255.0 }

        for index in 0..<(ewCurvePoints.count - 1) {
            let start = ewCurvePoints[index]
            let end = ewCurvePoints[index + 1]
            if input >= start.input && input <= end.input {
                let t = ((input - start.input) / (end.input - start.input)).clamped(to: 0...1)
                let smoothT = t * t * (3.0 - 2.0 * t)
                let output = start.output + (end.output - start.output) * smoothT
                return output / 255.0
            }
        }

        return normalizedInput
    }
}
