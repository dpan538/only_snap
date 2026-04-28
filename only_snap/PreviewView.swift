import SwiftUI
import AVFoundation
import CoreImage
import Metal
import MetalKit

// MARK: - SwiftUI wrapper

struct PreviewView: UIViewRepresentable {

    let session: AVCaptureSession
    let format: AspectFormat
    let isSessionRunning: Bool
    let ryEnabled: Bool
    let isLandscape: Bool
    let cameraManager: CameraManager   // routes session mutations through sessionQueue

    func makeUIView(context: Context) -> RYPreviewUIView {
        let view = RYPreviewUIView()
        view.configure(session: session, cameraManager: cameraManager)
        return view
    }

    func updateUIView(_ uiView: RYPreviewUIView, context: Context) {
        uiView.setRY(enabled: ryEnabled)
        uiView.setLandscape(isLandscape)
        if !uiView.bounds.isEmpty {
            uiView.setFormat(format, animated: true)
        }
    }
}

// MARK: - UIView with dual-mode rendering

final class RYPreviewUIView: UIView {

    // MARK: - Properties
    private var session: AVCaptureSession?
    private weak var cameraManager: CameraManager?   // weak to avoid retain cycle
    private var ryEnabled = false

    // Normal mode: AVCaptureVideoPreviewLayer (zero overhead)
    private lazy var previewLayer: AVCaptureVideoPreviewLayer = {
        let l = AVCaptureVideoPreviewLayer()
        l.videoGravity = .resizeAspectFill
        return l
    }()

    // RY mode: Metal rendering path
    private var metalLayer: CAMetalLayer?
    private var videoDataOutput: AVCaptureVideoDataOutput?
    private let videoQueue = DispatchQueue(label: "ry.preview.queue", qos: .userInteractive)
    private let ciContext: CIContext = {
        // Process in extended-linear sRGB (float precision internally) before quantising
        // to the 8-bit Metal drawable.  This eliminates gradient banding ("mosaic") on
        // smooth areas such as sky because all CIFilter math runs at float resolution.
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .useSoftwareRenderer: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: opts)
        }
        return CIContext(options: opts)
    }()

    // Aspect-ratio mask layers
    private var maskLayers: [CALayer] = []
    private var currentFormat: AspectFormat = .threeToFour

    // Deferred-setup flag — prevents assigning previewLayer.session before valid bounds.
    // A zero-frame layer triggers AVFoundation "Invalid frame dimension" → mediaserverd
    // destabilisation → cascading err=-17281 on every subsequent capturePhoto.
    private var isPreviewLayerConfigured = false

    // Orientation flag — set via setLandscape() from updateUIView.
    // Controls pixel-buffer rotation in captureOutput and previewLayer angle in layoutSubviews.
    private var isLandscape: Bool = false

    // Cached RY CIFilter instances — pre-warmed eagerly in enableRYMode() on videoQueue,
    // then reused every frame (videoQueue is serial, so all access is data-race-free).
    // Reusing avoids ~60+ object allocations/sec at 30 fps.
    private var cachedMatrixFilter:  CIFilter?
    private var cachedToneFilter:    CIFilter?
    private var cachedSatFilter:     CIFilter?
    private var cachedLanczosFilter: CIFilter?

    // MARK: - Setup

    func configure(session: AVCaptureSession, cameraManager: CameraManager) {
        self.session       = session
        self.cameraManager = cameraManager
        // Deliberately do NOT assign previewLayer.session or call layer.addSublayer here.
        // makeUIView() is called before the first layoutSubviews(), so bounds are still
        // CGRect.zero at this point. Assigning .session to a zero-frame layer immediately
        // triggers AVFoundation's "Invalid frame dimension" path inside mediaserverd,
        // which corrupts the XPC connection and causes every subsequent capturePhoto
        // to fail with err=-17281 for the lifetime of the process.
        // layoutSubviews() handles first-time wiring once real bounds are available.
        // The CAMetalLayer is also pre-allocated in layoutSubviews (hidden) so that
        // enableRYMode() can reveal it instantly without a DispatchQueue.main.async delay.
    }

    // MARK: - Landscape

    /// Called from PreviewView.updateUIView whenever the orientation changes.
    func setLandscape(_ landscape: Bool) {
        guard landscape != isLandscape else { return }
        isLandscape = landscape
        // Update previewLayer rotation and recalculate format masks.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            let angle: CGFloat = landscape ? 0 : 90
            if let conn = self.previewLayer.connection,
               conn.isVideoRotationAngleSupported(angle) {
                conn.videoRotationAngle = angle
            }
            // Recalculate mask rects for the new orientation.
            self.setFormat(self.currentFormat, animated: false)
        }
    }

    // MARK: - RY toggle

    func setRY(enabled: Bool) {
        guard enabled != ryEnabled else { return }
        ryEnabled = enabled
        enabled ? enableRYMode() : disableRYMode()
    }

    /// Enables RY (warm-red Metal preview).
    ///
    /// The CAMetalLayer is already pre-allocated and hidden in layoutSubviews, so this
    /// method only needs to reveal it — no allocation on the hot path.
    /// Session mutation is routed through CameraManager.sessionQueue — never touches
    /// AVCaptureSession on the main thread directly.
    private func enableRYMode() {
        guard let cameraManager = cameraManager else { return }

        // Create output first (no delegate yet — set inside addVideoDataOutput on sessionQueue).
        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        videoDataOutput = output

        // Route session mutation through sessionQueue.
        cameraManager.addVideoDataOutput(output, delegate: self, queue: videoQueue)

        // Pre-warm all CIFilter instances on videoQueue so the first few frames don't
        // pay the lazy-init cost.  videoQueue is serial, so this is data-race-free.
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            if self.cachedMatrixFilter == nil {
                let f = CIFilter(name: "CIColorMatrix")
                f?.setValue(CIVector(x:  1.05, y: 0.00, z: -0.03, w: 0), forKey: "inputRVector")
                f?.setValue(CIVector(x:  0.00, y: 0.98, z: -0.03, w: 0), forKey: "inputGVector")
                f?.setValue(CIVector(x: -0.04, y: 0.00, z:  0.90, w: 0), forKey: "inputBVector")
                f?.setValue(CIVector(x:  0.00, y: 0.00, z:  0.00, w: 1), forKey: "inputAVector")
                f?.setValue(CIVector(x: 0.006, y: 0.003, z: 0.000, w: 0), forKey: "inputBiasVector")
                self.cachedMatrixFilter = f
            }
            if self.cachedSatFilter == nil {
                let f = CIFilter(name: "CIColorControls")
                f?.setValue(0.84, forKey: kCIInputSaturationKey)
                f?.setValue(0.0,  forKey: kCIInputBrightnessKey)
                f?.setValue(1.0,  forKey: kCIInputContrastKey)
                self.cachedSatFilter = f
            }
            if self.cachedLanczosFilter == nil {
                let f = CIFilter(name: "CILanczosScaleTransform")
                f?.setValue(1.0, forKey: "inputAspectRatio")
                self.cachedLanczosFilter = f
            }
        }

        // Reveal the pre-allocated Metal layer (created once in layoutSubviews).
        // No allocation here — this is instant, eliminating the toggle lag.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            if let ml = self.metalLayer {
                // Normal path: layer was pre-allocated in layoutSubviews.
                ml.isHidden = false
            } else {
                // Fallback: layoutSubviews hasn't fired with valid bounds yet (very rare).
                let ml = CAMetalLayer()
                ml.frame           = self.bounds.isEmpty ? UIScreen.main.bounds : self.bounds
                ml.pixelFormat     = .bgra8Unorm
                ml.framebufferOnly = false
                ml.contentsGravity = .resizeAspectFill
                self.layer.addSublayer(ml)
                self.metalLayer    = ml
            }
            self.previewLayer.isHidden = true
        }
    }

    /// Disables RY mode and restores the standard preview layer.
    private func disableRYMode() {
        // Remove the data output via sessionQueue (thread-safe).
        if let output = videoDataOutput {
            cameraManager?.removeVideoDataOutput(output)
            videoDataOutput = nil
        }

        // Release cached filters — they will be rebuilt fresh on the next enableRYMode().
        cachedMatrixFilter  = nil
        cachedToneFilter    = nil
        cachedSatFilter     = nil
        cachedLanczosFilter = nil

        // Hide (not remove) the Metal layer — keeps it alive for the next enableRYMode()
        // call, which simply un-hides it instead of allocating a new CAMetalLayer.
        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.metalLayer?.isHidden  = true
            self.previewLayer.isHidden = false
        }
    }

    // MARK: - Layout

    override func layoutSubviews() {
        super.layoutSubviews()
        // Also guard against +Infinity: `Inf > 0` is true, but AVFoundation treats a
        // non-finite frame as invalid → "Invalid frame dimension" × 3 → err=-17281.
        guard bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite else { return }

        // Frame MUST be set before .session is assigned.
        // AVFoundation reads the layer's current frame the moment .session is written;
        // a zero-frame triggers "Invalid frame dimension" inside mediaserverd which
        // corrupts the XPC link and makes every subsequent capturePhoto return -17281.
        previewLayer.frame = bounds
        metalLayer?.frame  = bounds

        // Pre-allocate the Metal layer once (hidden) so that enableRYMode() can reveal it
        // instantly without any allocation on the toggle path.
        // Added BEFORE previewLayer so it sits at a lower z-index; maskLayers (added in
        // setFormat below via addSublayer) end up on top of both.
        if metalLayer == nil {
            let ml = CAMetalLayer()
            ml.frame           = bounds
            ml.pixelFormat     = .bgra8Unorm
            ml.framebufferOnly = false
            ml.contentsGravity = .resizeAspectFill
            ml.isHidden        = true   // stays hidden until enableRYMode() reveals it
            layer.addSublayer(ml)
            metalLayer = ml
        }

        // First-time wiring: session assigned only after frame is already valid above.
        // previewLayer is added AFTER metalLayer so it sits on top in z-order.
        if !isPreviewLayerConfigured, let session = session {
            isPreviewLayerConfigured = true
            previewLayer.session = session   // frame is valid — safe to assign
            layer.addSublayer(previewLayer)
        }

        // AVCaptureVideoPreviewLayer does NOT auto-rotate — must be set explicitly.
        // Use 0° in landscape (sensor delivers landscape pixels natively) and 90° in portrait.
        let angle: CGFloat = isLandscape ? 0 : 90
        if let conn = previewLayer.connection,
           conn.isVideoRotationAngleSupported(angle) {
            conn.videoRotationAngle = angle
        }

        setFormat(currentFormat, animated: false)
    }

    // MARK: - Format mask

    func setFormat(_ format: AspectFormat, animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        currentFormat = format

        maskLayers.forEach { $0.removeFromSuperlayer() }
        maskLayers = []

        let w = bounds.width
        let h = bounds.height

        let isLandscapeBounds = w > h

        let visibleRect: CGRect
        switch format {
        case .square:
            // min-side crop works for both orientations:
            // portrait → crops top/bottom  |  landscape → crops left/right
            let side = min(w, h)
            visibleRect = CGRect(x: (w - side) / 2, y: (h - side) / 2,
                                 width: side, height: side)
        case .threeToFour:
            // Portrait 3:4 / landscape 4:3 — both are the sensor's native aspect, full frame.
            visibleRect = bounds
        case .twoToThree:
            if isLandscapeBounds {
                // Landscape: sensor 4:3, target 3:2 → crop top/bottom by factor (2/3)/(3/4) = 8/9
                let targetH = h * (8.0 / 9.0)
                visibleRect = CGRect(x: 0, y: (h - targetH) / 2, width: w, height: targetH)
            } else {
                // Portrait: 2:3 crop — narrower than 3:4, masks top/bottom
                let targetH = min(w * (3.0 / 2.0) * 0.95, h)
                visibleRect = CGRect(x: 0, y: (h - targetH) / 2, width: w, height: targetH)
            }
        }

        let maskColor = UIColor.black.withAlphaComponent(0.55).cgColor

        let addMasks = {
            for rect in self.rectsOutside(visibleRect, in: self.bounds) {
                guard rect.width > 0, rect.height > 0 else { continue }
                let ml = CALayer()
                ml.frame           = rect
                ml.backgroundColor = maskColor
                self.layer.addSublayer(ml)
                self.maskLayers.append(ml)
            }
        }

        if animated {
            CATransaction.begin()
            CATransaction.setAnimationDuration(0.3)
            addMasks()
            CATransaction.commit()
        } else {
            addMasks()
        }
    }

    private func rectsOutside(_ inner: CGRect, in outer: CGRect) -> [CGRect] {
        var rects: [CGRect] = []
        if inner.minY > outer.minY {
            rects.append(CGRect(x: outer.minX, y: outer.minY,
                                width: outer.width, height: inner.minY - outer.minY))
        }
        if inner.maxY < outer.maxY {
            rects.append(CGRect(x: outer.minX, y: inner.maxY,
                                width: outer.width, height: outer.maxY - inner.maxY))
        }
        if inner.minX > outer.minX {
            rects.append(CGRect(x: outer.minX, y: inner.minY,
                                width: inner.minX - outer.minX, height: inner.height))
        }
        if inner.maxX < outer.maxX {
            rects.append(CGRect(x: inner.maxX, y: inner.minY,
                                width: outer.maxX - inner.maxX, height: inner.height))
        }
        return rects
    }
}

// MARK: - AVCaptureVideoDataOutputSampleBufferDelegate

extension RYPreviewUIView: AVCaptureVideoDataOutputSampleBufferDelegate {

    func captureOutput(_ output: AVCaptureOutput,
                       didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        guard ryEnabled,
              let metalLayer  = metalLayer,
              let drawable    = metalLayer.nextDrawable(),
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Guard against zero-size drawable — this was the root cause of the
        // "Invalid frame dimension" Metal crash that killed mediaserverd and
        // triggered cascading err=-17281 on all subsequent capturePhoto calls.
        let texW = drawable.texture.width
        let texH = drawable.texture.height
        guard texW > 0, texH > 0 else { return }

        // The sensor always delivers landscape pixels (width > height).
        // In portrait mode we rotate to portrait; in landscape mode we keep the native
        // landscape orientation so the Metal layer fills the landscape viewfinder correctly.
        let raw = CIImage(cvPixelBuffer: pixelBuffer)
        let ciImage: CIImage
        if isLandscape {
            // Phone held landscape — keep native landscape pixels.
            ciImage = raw
        } else {
            // Phone held portrait — conn.videoRotationAngle = 90 may only tag metadata
            // on some devices/iOS builds without physically rotating the buffer; detect
            // and correct here to guarantee portrait output.
            ciImage = raw.extent.width > raw.extent.height
                ? raw.oriented(.right)  // rotate 90° CW: landscape → portrait
                : raw                   // connection already delivered portrait
        }
        let filtered  = applyRYCurve(to: ciImage)

        // Scale to aspect-fill the Metal drawable using CILanczosScaleTransform.
        // Previous approach: CGAffineTransform — bilinear nearest-pixel mapping that
        // produces visible mosaic / aliasing on high-frequency textures (foliage, fabrics,
        // reflections) because it upscales the ~1080p video frame to a 3× retina screen
        // without any anti-aliasing kernel.
        // CILanczosScaleTransform applies a proper Lanczos-3 sinc kernel that blends
        // neighbouring pixels, eliminating the blockiness.  The filter is cached across
        // frames — drawable size is fixed after layout settles, so `scale` is constant.
        let drawableSize = CGSize(width: texW, height: texH)
        let scaleX = drawableSize.width  / filtered.extent.width
        let scaleY = drawableSize.height / filtered.extent.height
        let scale  = max(scaleX, scaleY)

        guard scale.isFinite, scale > 0 else { return }

        // Lazy-initialise Lanczos filter (aspect ratio always 1.0 — we scale uniformly).
        if cachedLanczosFilter == nil {
            cachedLanczosFilter = CIFilter(name: "CILanczosScaleTransform")
            cachedLanczosFilter?.setValue(1.0, forKey: "inputAspectRatio")
        }
        let scaledRaw: CIImage
        if let lf = cachedLanczosFilter {
            lf.setValue(filtered, forKey: kCIInputImageKey)
            lf.setValue(scale,    forKey: kCIInputScaleKey)
            scaledRaw = lf.outputImage
                ?? filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaledRaw = filtered.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        }

        let tx = ((drawableSize.width  - scaledRaw.extent.width)  * 0.5) - scaledRaw.extent.minX
        let ty = ((drawableSize.height - scaledRaw.extent.height) * 0.5) - scaledRaw.extent.minY
        let scaled = scaledRaw.transformed(by: CGAffineTransform(translationX: tx, y: ty))

        ciContext.render(scaled,
                         to: drawable.texture,
                         commandBuffer: nil,
                         bounds: CGRect(origin: .zero, size: drawableSize),
                         colorSpace: CGColorSpaceCreateDeviceRGB())
        drawable.present()
    }

    /// RY warm-film colour grade for the real-time Metal preview.
    ///
    /// Two-stage pipeline (CIToneCurve and CIBloom intentionally excluded):
    ///   1. CIColorMatrix   — calibrated cross-channel warm tilt (amber/golden quality)
    ///   2. CIColorControls — mild desaturation (0.84), no contrast boost
    ///
    /// CIBloom was removed from the preview path because at radius=8 it applies a
    /// full-frame Gaussian blur to every 30fps frame, making the Metal preview visibly
    /// softer than the hardware AVCaptureVideoPreviewLayer (text becomes unreadable).
    /// Bloom is still applied in ColorProcessor for saved stills, where the larger
    /// radius/intensity produces the intended film-frame border effect.
    ///
    /// CIToneCurve is applied in ColorProcessor for still photos but NOT here.
    /// On the Metal path a piecewise tone curve causes visible posterization / banding
    /// in smooth gradients — the extended-linear CIContext working space handles that.
    ///
    /// All CIFilter objects are pre-warmed in enableRYMode() and reused every frame.
    /// videoQueue is serial, so all access is data-race-free.
    ///
    /// Matrix — conservative warm baseline; scene fine-tuning is handled per-photo
    /// in ColorProcessor.applyAdaptiveCorrection (green / warm-scene / overcast paths).
    /// Kept in sync with ColorProcessor.applyExperimentalCurve():
    ///   R_out = 1.05·R − 0.03·B + 0.006   moderate warm boost
    ///   G_out = 0.98·G − 0.03·B + 0.003   near-neutral G; B cross-pull keeps sky blue
    ///   B_out = 0.90·B − 0.04·R            modest B reduction; greens stay green
    private func applyRYCurve(to image: CIImage) -> CIImage {

        // ── 1. Warming colour matrix ─────────────────────────────────────────
        if cachedMatrixFilter == nil {
            let f = CIFilter(name: "CIColorMatrix")
            f?.setValue(CIVector(x:  1.05, y: 0.00, z: -0.03, w: 0), forKey: "inputRVector")
            f?.setValue(CIVector(x:  0.00, y: 0.98, z: -0.03, w: 0), forKey: "inputGVector")
            f?.setValue(CIVector(x: -0.04, y: 0.00, z:  0.90, w: 0), forKey: "inputBVector")
            f?.setValue(CIVector(x:  0.00, y: 0.00, z:  0.00, w: 1), forKey: "inputAVector")
            f?.setValue(CIVector(x: 0.006, y: 0.003, z: 0.000, w: 0), forKey: "inputBiasVector")
            cachedMatrixFilter = f
        }

        // ── 2. Mild desaturation — no contrast boost ─────────────────────────
        // Saturation 0.84 tames oversaturated yellows without dulling the look.
        if cachedSatFilter == nil {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(0.84, forKey: kCIInputSaturationKey)
            f?.setValue(0.0,  forKey: kCIInputBrightnessKey)
            f?.setValue(1.0,  forKey: kCIInputContrastKey)
            cachedSatFilter = f
        }

        guard let mf = cachedMatrixFilter else { return image }
        mf.setValue(image, forKey: kCIInputImageKey)
        guard let matOut = mf.outputImage else { return image }

        guard let sf = cachedSatFilter else { return matOut }
        sf.setValue(matOut, forKey: kCIInputImageKey)
        return sf.outputImage ?? matOut
    }
}

// MARK: - MTLTexture helper

private extension MTLTexture {
    var size2D: CGSize { CGSize(width: width, height: height) }
}
