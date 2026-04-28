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
    /// The `videoRotationAngle` to use when `isLandscape` is true.
    /// - landscapeLeft  → 0°   (sensor native)
    /// - landscapeRight → 180° (sensor flipped 180°)
    /// - portrait       → ignored (always 90°)
    let landscapeRotationAngle: CGFloat
    let cameraManager: CameraManager   // routes session mutations through sessionQueue

    init(session: AVCaptureSession,
         format: AspectFormat,
         isSessionRunning: Bool,
         ryEnabled: Bool,
         isLandscape: Bool,
         landscapeRotationAngle: CGFloat = 0,
         cameraManager: CameraManager) {
        self.session               = session
        self.format                = format
        self.isSessionRunning      = isSessionRunning
        self.ryEnabled             = ryEnabled
        self.isLandscape           = isLandscape
        self.landscapeRotationAngle = landscapeRotationAngle
        self.cameraManager         = cameraManager
    }

    func makeUIView(context: Context) -> RYPreviewUIView {
        let view = RYPreviewUIView()
        view.configure(session: session, cameraManager: cameraManager)
        return view
    }

    func updateUIView(_ uiView: RYPreviewUIView, context: Context) {
        uiView.setRY(enabled: ryEnabled)
        uiView.setLandscape(isLandscape, rotationAngle: landscapeRotationAngle)
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
        //
        // cacheIntermediates: false — at 30 fps the intermediate CIImage textures are
        // consumed immediately and never reused.  Without this flag CoreImage caches every
        // intermediate GPU texture, growing the Metal heap unboundedly until iOS kills the
        // process or XPC fails (malloc: xzm: failed to initialize deferred reclamation
        // buffer → err=-17281).  Disabling caching trades a tiny amount of per-frame GPU
        // recompute for a stable, bounded memory footprint.
        let opts: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.extendedLinearSRGB) as Any,
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
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

    // Tracks the last angle applied to the preview layer connection so setLandscape()
    // can guard against redundant work.  updateUIView fires on every SwiftUI state
    // change (including 60fps shutterProgress animation) — without this guard we'd
    // set videoRotationAngle + run CATransaction on every animation frame.
    private var lastLandscapeAngle: CGFloat = 90

    // Guards setFormat() against the same 60fps updateUIView thrash.
    private var lastMaskFormat: AspectFormat?
    private var lastMaskBoundsSize: CGSize = .zero

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

    // MARK: - Deallocation

    /// Guarantees that `videoDataOutput` is removed from the session before the view dies.
    ///
    /// Without this, orientation transitions (which destroy and recreate the SwiftUI
    /// UIViewRepresentable host) leave an orphaned AVCaptureVideoDataOutput attached to
    /// the session with a delegate pointing at freed memory.  On the next frame delivery
    /// AVFoundation attempts to call the dangling delegate, which corrupts the XPC link
    /// to mediaserverd and produces cascading err=-17281 on all subsequent capturePhoto
    /// calls for the lifetime of the process.
    deinit {
        if let output = videoDataOutput {
            cameraManager?.removeVideoDataOutput(output)
        }
    }

    // MARK: - Landscape

    /// Called from PreviewView.updateUIView whenever the orientation changes.
    ///
    /// `landscape` is true when the device is held landscape.
    /// `rotationAngle` is the `videoRotationAngle` for the preview layer connection:
    ///   portrait        → 90°
    ///   landscapeLeft   →  0°  (sensor delivers landscape-left natively)
    ///   landscapeRight  → 180° (flip 180°)
    ///
    /// updateUIView is called on the main thread on every SwiftUI state change
    /// (including 60fps shutterProgress animation).  The guard on `lastLandscapeAngle`
    /// ensures we only do real work when the orientation actually changes.
    func setLandscape(_ landscape: Bool, rotationAngle: CGFloat = 90) {
        let previewAngle: CGFloat = landscape ? rotationAngle : 90
        // Guard: skip if the effective angle hasn't changed.
        guard abs(previewAngle - lastLandscapeAngle) > 0.1 else { return }
        lastLandscapeAngle = previewAngle
        isLandscape = landscape

        // Update preview layer connection (90° portrait, 0/180° landscape).
        if let conn = previewLayer.connection,
           conn.isVideoRotationAngleSupported(previewAngle) {
            conn.videoRotationAngle = previewAngle
        }

        // Update video data output connection so the Metal RY path receives
        // correctly oriented pixel buffers:
        //   portrait  → 90° → portrait pixels   → fills portrait Metal layer directly
        //   landscape →  0° → landscape pixels  → aspect-fill crops sides,
        //                                          showing the landscape scene perspective
        // Both landscapeLeft and landscapeRight use 0° for the data output because
        // the Metal path only needs landscape vs portrait, not the handedness.
        let dataAngle: CGFloat = landscape ? 0 : 90
        if let output = videoDataOutput,
           let conn = output.connection(with: .video),
           conn.isVideoRotationAngleSupported(dataAngle) {
            conn.videoRotationAngle = dataAngle
        }

        // Recalculate format masks for the new orientation.
        // Bounds haven't changed (portrait-locked UI), but isLandscapeBounds inside
        // setFormat reads bounds.width > bounds.height — still false in portrait layout.
        // We reset lastMaskBoundsSize so setFormat re-runs its layout pass.
        lastMaskBoundsSize = .zero
        setFormat(currentFormat, animated: false)
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
        // Only set pixel format — do NOT add kCVPixelBufferWidthKey / HeightKey here.
        // With .photo session preset the session controls the output resolution internally;
        // specifying explicit dimensions in videoSettings for a photo-preset session either
        // silently prevents canAddOutput() from succeeding (so no frames are ever delivered)
        // or conflicts with the session and breaks the RY/RAW toggle.
        // The .photo preset already delivers ~1920×1440 frames to the video data output,
        // which is sufficient for 30 fps Metal rendering at 3× retina screen sizes.
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        output.alwaysDiscardsLateVideoFrames = true
        videoDataOutput = output

        // Route session mutation through sessionQueue.
        // Pass the current landscape state so the output connection is initialised
        // with the correct videoRotationAngle right away — not always portrait-90°.
        // (addVideoDataOutput runs on sessionQueue asynchronously; if we waited for
        //  setLandscape to correct it afterwards, the connection wouldn't exist yet.)
        let initialDataAngle: CGFloat = isLandscape ? 0 : 90
        let previewAngle = lastLandscapeAngle   // capture before the async commit
        cameraManager.addVideoDataOutput(output, delegate: self, queue: videoQueue,
                                          initialDataAngle: initialDataAngle) { [weak self] in
            // session.commitConfiguration() resets previewLayer.connection.videoRotationAngle
            // back to 0° (sensor default).  Re-apply the correct angle here so the
            // viewfinder doesn't rotate when RY mode is toggled.
            guard let self = self,
                  let conn = self.previewLayer.connection,
                  conn.isVideoRotationAngleSupported(previewAngle) else { return }
            conn.videoRotationAngle = previewAngle
        }

        // Pre-warm all CIFilter instances AND the RY atmosphere LUT on videoQueue so the
        // first photo capture doesn't pay a memory-allocation spike mid-pipeline.
        // videoQueue is serial, so all access is data-race-free.
        videoQueue.async { [weak self] in
            guard let self = self else { return }
            // Pre-build the 33³ VG LUT cache (~560 KB, one-time cost) so the first capturePhoto
            // call finds it already resident instead of allocating it during the photo pipeline.
            _ = ColorProcessor.vgAtmosphereLUT()
            if self.cachedMatrixFilter == nil {
                let f = CIFilter(name: "CIColorMatrix")
                f?.setValue(CIVector(x:  1.02, y: 0.00, z: -0.010, w: 0), forKey: "inputRVector")
                f?.setValue(CIVector(x:  0.00, y: 0.99, z: -0.005, w: 0), forKey: "inputGVector")
                f?.setValue(CIVector(x: -0.02, y: 0.00, z:  0.950, w: 0), forKey: "inputBVector")
                f?.setValue(CIVector(x:  0.00, y: 0.00, z:  0.000, w: 1), forKey: "inputAVector")
                f?.setValue(CIVector(x: 0.004, y: 0.002, z: 0.000, w: 0), forKey: "inputBiasVector")
                self.cachedMatrixFilter = f
            }
            if self.cachedSatFilter == nil {
                let f = CIFilter(name: "CIColorControls")
                f?.setValue(0.88, forKey: kCIInputSaturationKey)
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
            let previewAngle = lastLandscapeAngle   // capture before the async commit
            cameraManager?.removeVideoDataOutput(output) { [weak self] in
                // session.commitConfiguration() resets previewLayer.connection.videoRotationAngle.
                // Re-apply the correct angle so the viewfinder doesn't rotate when
                // switching back from RY to RAW mode.
                guard let self = self,
                      let conn = self.previewLayer.connection,
                      conn.isVideoRotationAngleSupported(previewAngle) else { return }
                conn.videoRotationAngle = previewAngle
            }
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
        // Use lastLandscapeAngle (the angle last applied by setLandscape) so that
        // layoutSubviews re-applies the correct angle rather than reading a potentially
        // stale value from the connection (which commitConfiguration can reset to 0°).
        let angle = lastLandscapeAngle
        if let conn = previewLayer.connection,
           conn.isVideoRotationAngleSupported(angle) {
            conn.videoRotationAngle = angle
        }

        setFormat(currentFormat, animated: false)
    }

    // MARK: - Format mask

    func setFormat(_ format: AspectFormat, animated: Bool) {
        guard bounds.width > 0, bounds.height > 0 else { return }
        // Guard: skip if format AND bounds size are unchanged AND masks already exist.
        // Without this, updateUIView's direct setFormat call fires 60+ times during
        // the 0.6 s shutter animation, thrashing Core Animation with begin/commit cycles
        // and contributing to memory pressure that triggers err=-17281.
        let sz = bounds.size
        if format == lastMaskFormat, sz == lastMaskBoundsSize, !maskLayers.isEmpty {
            currentFormat = format
            return
        }
        lastMaskFormat = format
        lastMaskBoundsSize = sz
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
            if isLandscapeBounds {
                // Landscape 4:3: sensor native aspect is 4:3 but the viewfinder is typically
                // wider (e.g. 1.54:1).  Mask left/right so only the 4:3 sensor window is
                // visible — consistent with how other camera apps show the native crop.
                let targetW = min(w, h * (4.0 / 3.0))
                visibleRect = CGRect(x: (w - targetW) / 2, y: 0,
                                     width: targetW, height: h)
            } else {
                // Portrait 3:4 is the sensor native — no masking needed.
                visibleRect = bounds
            }
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

        // The videoDataOutput connection's videoRotationAngle is managed by setLandscape():
        //   portrait  → 90° → connection delivers portrait pixels  (width ≤ height)
        //   landscape →  0° → connection delivers landscape pixels (width > height)
        //
        // Using the pixel-buffer dimensions (not the main-thread `isLandscape` flag)
        // eliminates the data-race between this videoQueue callback and the main thread.
        //
        // For portrait buffers: CIImage fills the portrait Metal layer directly.
        // For landscape buffers: the aspect-fill scale step (max(scaleX, scaleY)) crops
        //   the sides to fill the portrait Metal layer, showing the landscape scene perspective.
        let raw = CIImage(cvPixelBuffer: pixelBuffer)
        let ciImage: CIImage
        if raw.extent.width > raw.extent.height {
            // Landscape pixel buffer (device landscape, connection angle=0°).
            // Keep as-is; the aspect-fill render step handles the portrait crop.
            ciImage = raw
        } else {
            // Portrait pixel buffer (device portrait OR connection already rotated to 90°).
            ciImage = raw
        }
        let filtered  = applyVGCurve(to: ciImage)

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

    /// VG (Vintage Gold) colour grade for the real-time Metal preview.
    ///
    /// Two-stage pipeline (CIToneCurve, CIColorPolynomial, and CIBloom intentionally excluded):
    ///   1. CIColorMatrix   — lightweight VG warm hint (lighter than old RY matrix)
    ///   2. CIColorControls — moderate saturation (0.88), no contrast boost
    ///
    /// Why a matrix and not CIColorPolynomial here:
    ///   The full VG pipeline uses CIColorPolynomial for luminance-separated toning (shadows
    ///   cool, highlights gold).  On the 30fps Metal preview path, CIColorPolynomial is fast
    ///   enough per-frame, BUT the extended-linear working space of this CIContext already
    ///   provides smoother gradients and the global warm hint is sufficient for a live preview
    ///   — the subtle shadow-blue / highlight-gold distinction is a still-photo refinement
    ///   that doesn't read clearly on a small moving viewfinder at 30fps.
    ///
    /// Matrix values — tuned for VG preview aesthetic:
    ///   R_out = 1.02·R − 0.01·B + 0.004   subtle warm nudge (old RY: 1.05, -0.03)
    ///   G_out = 0.99·G − 0.005·B + 0.002  near-neutral (old RY: 0.98, -0.03)
    ///   B_out = 0.95·B − 0.02·R            light B reduction (old RY: 0.90, -0.04)
    ///
    /// The lighter matrix preserves green and maintains natural skin tones in the live
    /// preview — matching the VG philosophy of "colour protection over global warming".
    ///
    /// All CIFilter objects are pre-warmed in enableRYMode() and reused every frame.
    /// videoQueue is serial, so all access is data-race-free.
    private func applyVGCurve(to image: CIImage) -> CIImage {

        // ── 1. VG warm hint matrix ───────────────────────────────────────────
        if cachedMatrixFilter == nil {
            let f = CIFilter(name: "CIColorMatrix")
            f?.setValue(CIVector(x:  1.02, y: 0.00, z: -0.010, w: 0), forKey: "inputRVector")
            f?.setValue(CIVector(x:  0.00, y: 0.99, z: -0.005, w: 0), forKey: "inputGVector")
            f?.setValue(CIVector(x: -0.02, y: 0.00, z:  0.950, w: 0), forKey: "inputBVector")
            f?.setValue(CIVector(x:  0.00, y: 0.00, z:  0.000, w: 1), forKey: "inputAVector")
            f?.setValue(CIVector(x: 0.004, y: 0.002, z: 0.000, w: 0), forKey: "inputBiasVector")
            cachedMatrixFilter = f
        }

        // ── 2. Moderate saturation — no contrast boost ───────────────────────
        // 0.88 (vs old RY 0.84): slightly higher because VG's lighter matrix means
        // colours haven't been over-shifted, so less desaturation is needed to
        // tame oversaturation — the result reads more natural in the live viewfinder.
        if cachedSatFilter == nil {
            let f = CIFilter(name: "CIColorControls")
            f?.setValue(0.88, forKey: kCIInputSaturationKey)
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
