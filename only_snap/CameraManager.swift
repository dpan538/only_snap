@preconcurrency import AVFoundation
import Photos
import CoreImage
import ImageIO
import Metal
import UIKit
import os.log
import Combine

final class CameraManager: NSObject, ObservableObject {

    // MARK: - Published properties
    @Published var permissionDenied = false
    @Published var isSessionRunning = false
    @Published var captureError: String? = nil

    // MARK: - Internal properties
    nonisolated(unsafe) let session     = AVCaptureSession()
    nonisolated(unsafe) let photoOutput = AVCapturePhotoOutput()
    private(set) var currentDevice: AVCaptureDevice?

    // MARK: - Private state
    private var flashOn = false
    nonisolated(unsafe) private var selectedFocalLength: Int = 35
    nonisolated(unsafe) private var cropFactor: CGFloat       = 1.0
    nonisolated(unsafe) private var digitalZoomFactor: CGFloat = 1.0

    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    fileprivate let imageProcessingQueue = DispatchQueue(
        label: "camera.imageprocessing.queue", qos: .userInitiated)
    private let logger = Logger(subsystem: "only_snap", category: "CameraManager")
    private var inProgressDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var sessionRunningObserver: AnyCancellable?

    private var cameraPermissionGranted = false
    private var photoPermissionGranted  = false

    /// Shared Metal-backed CIContext for rendering.
    let ciContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .outputColorSpace:  CGColorSpace(name: CGColorSpace.sRGB) as Any
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - Start / Stop

    func start() async {
        guard !session.isRunning else { return }

        if !cameraPermissionGranted {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:   cameraPermissionGranted = true
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted { await MainActor.run { permissionDenied = true }; return }
                cameraPermissionGranted = true
            default:
                await MainActor.run { permissionDenied = true }; return
            }
        }

        if !photoPermissionGranted {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited: photoPermissionGranted = true
            case .notDetermined:
                let s = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                if s != .authorized { await MainActor.run { permissionDenied = true }; return }
                photoPermissionGranted = true
            default:
                await MainActor.run { permissionDenied = true }; return
            }
        }

        if sessionRunningObserver == nil {
            sessionRunningObserver = session.publisher(for: \.isRunning)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] running in self?.isSessionRunning = running }
        }

        await configureSession()
    }

    func stop() {
        sessionQueue.async { self.session.stopRunning() }
        sessionRunningObserver = nil
    }

    // MARK: - Focal Length

    func setFocalLength(_ mm: Int) {
        guard mm != selectedFocalLength else { return }
        selectedFocalLength = mm
        // Capture the current physical device ID on the calling (main) thread before
        // dispatching — avoids reading currentDevice on two threads simultaneously.
        let prevDeviceID = currentDevice?.uniqueID

        sessionQueue.async {
            // Resolve target device on sessionQueue (device(for:) creates a DiscoverySession).
            guard let (dev, zoom) = self.device(for: mm) else { return }

            let clamped = Swift.min(Swift.max(zoom, dev.minAvailableVideoZoomFactor),
                                    dev.maxAvailableVideoZoomFactor)

            // ── Fast path: same physical camera (e.g. 35 mm ↔ 50 mm on wide lens) ──────
            // Skips the expensive begin/remove/add/commit cycle and just updates zoom.
            // Switching between these two focal lengths is now essentially instant.
            if dev.uniqueID == prevDeviceID {
                do {
                    try dev.lockForConfiguration()
                    dev.videoZoomFactor = clamped
                    dev.unlockForConfiguration()
                    self.digitalZoomFactor = clamped
                } catch {
                    Task { @MainActor in self.captureError = error.localizedDescription }
                }
                Task { @MainActor in self.currentDevice = dev }
                return
            }

            // ── Full camera switch (ultra-wide ↔ wide ↔ telephoto) ───────────────────
            self.session.beginConfiguration()
            if let input = self.session.inputs.first { self.session.removeInput(input) }
            do {
                let input = try AVCaptureDeviceInput(device: dev)
                guard self.session.canAddInput(input) else {
                    self.session.commitConfiguration(); return
                }
                self.session.addInput(input)

                try dev.lockForConfiguration()
                dev.videoZoomFactor = clamped
                dev.unlockForConfiguration()

                Task { @MainActor in self.currentDevice = dev }
                self.cropFactor        = 1.0
                self.digitalZoomFactor = clamped
            } catch {
                Task { @MainActor in self.captureError = error.localizedDescription }
            }
            self.session.commitConfiguration()

            // Reapply portrait orientation on the rebuilt photo output connection.
            if let conn = self.photoOutput.connection(with: .video),
               conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
        }
    }

    // MARK: - Flash

    func setFlash(_ on: Bool) { flashOn = on }

    // MARK: - Video Data Output routing (always via sessionQueue)
    //
    // PreviewView MUST use these methods instead of touching session directly on the
    // main thread, which races with sessionQueue and causes err=-17281 / session corruption.

    /// Adds `output` to the session, wires `delegate` / `queue`, and sets portrait
    /// orientation — all serialised on sessionQueue.
    func addVideoDataOutput(_ output: AVCaptureVideoDataOutput,
                             delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
                             queue: DispatchQueue) {
        sessionQueue.async {
            self.session.beginConfiguration()
            if self.session.canAddOutput(output) {
                self.session.addOutput(output)
                output.setSampleBufferDelegate(delegate, queue: queue)
            }
            self.session.commitConfiguration()

            // IMPORTANT: set videoRotationAngle AFTER commitConfiguration.
            // The connection graph is only fully finalised after commit;
            // querying connection(with:) inside begin/commit can return nil
            // (connection not yet created) or have the angle silently reset
            // by the commit itself — both of which leave the Metal preview in
            // landscape (raw sensor orientation).
            if let conn = output.connection(with: .video),
               conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
            // commitConfiguration also resets the photoOutput connection's angle.
            // Re-apply portrait rotation so RY-mode captures remain portrait.
            if let conn = self.photoOutput.connection(with: .video),
               conn.isVideoRotationAngleSupported(90) {
                conn.videoRotationAngle = 90
            }
        }
    }

    /// Removes `output` from the session, serialised on sessionQueue.
    func removeVideoDataOutput(_ output: AVCaptureVideoDataOutput) {
        sessionQueue.async {
            self.session.beginConfiguration()
            self.session.removeOutput(output)
            self.session.commitConfiguration()
        }
    }

    // MARK: - Capture

    func capture(format: AspectFormat, experimentalColor: Bool) async {
        let flashOn       = self.flashOn
        let cropFactor    = self.cropFactor
        let focal         = selectedFocalLength
        let deviceHasFlash = currentDevice?.hasFlash ?? false

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                guard self.session.isRunning else {
                    Task { @MainActor in self.captureError = "Session not running" }
                    cont.resume(); return
                }
                guard !self.photoOutput.connections.isEmpty else {
                    Task { @MainActor in self.captureError = "No photo connection" }
                    cont.resume(); return
                }

                let settings = AVCapturePhotoSettings()
                settings.flashMode = (flashOn && deviceHasFlash) ? .on : .off
                settings.photoQualityPrioritization = .quality

                let uid = settings.uniqueID
                let delegate = PhotoCaptureDelegate(
                    format: format,
                    experimentalColor: experimentalColor,
                    cropFactor: cropFactor,
                    focalLength: focal,
                    cameraManager: self,
                    completion: { [weak self] in
                        self?.inProgressDelegates.removeValue(forKey: uid)
                        cont.resume()
                    }
                )
                self.inProgressDelegates[uid] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: - Private: configureSession

    private func configureSession() async {
        let focal = selectedFocalLength

        await withCheckedContinuation { cont in
            sessionQueue.async {
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo

                guard self.session.canAddOutput(self.photoOutput) else {
                    self.session.commitConfiguration(); cont.resume(); return
                }
                self.session.addOutput(self.photoOutput)
                self.photoOutput.maxPhotoQualityPrioritization = .quality

                if let (dev, zoom) = self.device(for: focal) {
                    do {
                        let input = try AVCaptureDeviceInput(device: dev)
                        if self.session.canAddInput(input) { self.session.addInput(input) }

                        try dev.lockForConfiguration()
                        let clamped = Swift.min(Swift.max(zoom, dev.minAvailableVideoZoomFactor),
                                                dev.maxAvailableVideoZoomFactor)
                        dev.videoZoomFactor = clamped
                        dev.unlockForConfiguration()

                        Task { @MainActor in self.currentDevice = dev }
                        self.cropFactor        = 1.0
                        self.digitalZoomFactor = clamped
                    } catch {
                        Task { @MainActor in self.captureError = error.localizedDescription }
                    }
                }

                self.session.commitConfiguration()
                self.session.startRunning()

                // Single short pause — replaces the old 10-attempt sleep loop (up to 1 s).
                Thread.sleep(forTimeInterval: 0.05)

                // Set portrait orientation on the initial photo output connection.
                if let conn = self.photoOutput.connection(with: .video),
                   conn.isVideoRotationAngleSupported(90) {
                    conn.videoRotationAngle = 90
                }

                cont.resume()
            }
        }
    }

    // MARK: - Private: device selection (accurate FOV-based)

    /// Accurate 35mm-equivalent focal length formula:
    ///   equivFL = 21.6 / tan(horizontalFOV_rad / 2)
    /// (21.6 mm ≈ half-diagonal of 35 mm film frame)
    private nonisolated func device(for mm: Int) -> (AVCaptureDevice, CGFloat)? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video, position: .back)
        let devices = discovery.devices

        func find(_ t: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
            devices.first { $0.deviceType == t }
        }
        guard let wide = find(.builtInWideAngleCamera) else { return nil }

        func equivFL(_ cam: AVCaptureDevice) -> CGFloat {
            let rad = CGFloat(cam.activeFormat.videoFieldOfView) * .pi / 180.0
            let t   = tan(rad / 2.0)
            return t > 0 ? 21.6 / t : 24.0
        }

        let wFL = equivFL(wide)

        switch mm {
        case 21:
            if let uw = find(.builtInUltraWideCamera) {
                let uwFL   = equivFL(uw)
                let zoom   = CGFloat(mm) / uwFL
                let clamped = Swift.min(Swift.max(zoom, uw.minAvailableVideoZoomFactor),
                                        uw.maxAvailableVideoZoomFactor)
                return (uw, clamped)
            }
            return (wide, 1.0)

        case 35:
            let z = Swift.max(35.0 / wFL, 1.0)
            return (wide, Swift.min(z, wide.maxAvailableVideoZoomFactor))

        case 50:
            let z = Swift.max(50.0 / wFL, 1.0)
            return (wide, Swift.min(z, wide.maxAvailableVideoZoomFactor))

        case 105:
            if let tel = find(.builtInTelephotoCamera) {
                let tFL = equivFL(tel)
                let z   = Swift.max(105.0 / tFL, 1.0)
                return (tel, Swift.min(z, tel.maxAvailableVideoZoomFactor))
            }
            let z = Swift.max(105.0 / wFL, 1.0)
            return (wide, Swift.min(z, wide.maxAvailableVideoZoomFactor))

        default:
            return (wide, 1.0)
        }
    }

    // MARK: - fileprivate: handleCapturedPhoto

    fileprivate func handleCapturedPhoto(
        _ photo: AVCapturePhoto,
        format: AspectFormat,
        experimentalColor: Bool,
        cropFactor: CGFloat,
        focalLength: Int
    ) async {
        guard let cgImage = photo.cgImageRepresentation() else {
            await MainActor.run { captureError = "Failed to extract image data" }; return
        }

        // Raw sensor data is always landscape; CropManager expects that orientation.
        guard let cropped = CropManager.crop(image: cgImage, format: format, cropFactor: cropFactor) else {
            await MainActor.run { captureError = "Crop failed" }; return
        }

        let ciImage   = CIImage(cgImage: cropped)
        let mode: ColorMode = experimentalColor ? .experimental : .normal

        // ── ISO extraction ────────────────────────────────────────────────────────
        // Read sensor ISO from EXIF — drives adaptive sharpening and denoise below.
        // Falls back to 100 (base ISO) if metadata is unavailable.
        let isoValue: CGFloat = {
            guard let exif = photo.metadata[kCGImagePropertyExifDictionary as String]
                             as? [String: Any],
                  let isoRatings = exif[kCGImagePropertyExifISOSpeedRatings as String]
                             as? [NSNumber],
                  let first = isoRatings.first else { return 100 }
            return CGFloat(first.doubleValue)
        }()

        // ── Stage 1: Colour grading ──────────────────────────────────────────────
        // PROCESSING ORDER: colour grade → upsample → sharpen → conditional denoise.
        // Sharpening MUST happen after upscaling; inverting this order amplifies
        // upscaling artefacts and produces the "digital over-sharpened" look.
        let colourGraded = ColorProcessor.process(image: ciImage, mode: mode, focalLength: focalLength)

        // ── Stage 2: Dynamic supersampling (12 – 36 MP window) ──────────────────
        //
        // Old behaviour: always upscale to a fixed 32 MP, even when the sensor already
        // delivers ~12 MP (adds unnecessary bicubic softness and wastes GPU time).
        //
        // New behaviour — three cases based on input pixel count:
        //   < 12 MP  → upscale to 12 MP floor  (preserves baseline print quality)
        //   12–36 MP → no scaling               (keep every native sensor pixel)
        //   > 36 MP  → downscale to 36 MP cap   (trim filesize, no visible quality loss)
        //
        // Upscaling uses CIBicubicScaleTransform (Mitchell-Netravali B=0.75, C=0.25).
        // Downscaling uses CILanczosScaleTransform (sharper kernel better suited for shrink).
        let targetMinMP: CGFloat = 12_000_000
        let targetMaxMP: CGFloat = 36_000_000
        let inputW  = CGFloat(colourGraded.extent.width)
        let inputH  = CGFloat(colourGraded.extent.height)
        let inputMP = inputW * inputH

        let scaleFactor: CGFloat
        if inputMP < targetMinMP * 0.95 {
            scaleFactor = min(2.0, sqrt(targetMinMP / inputMP))   // upscale to 12 MP floor
        } else if inputMP > targetMaxMP * 1.05 {
            scaleFactor = max(0.5, sqrt(targetMaxMP / inputMP))   // downscale to 36 MP cap
        } else {
            scaleFactor = 1.0                                       // in range — skip scaling
        }

        let upscaled: CIImage
        if abs(scaleFactor - 1.0) > 0.02 {
            let filterName = scaleFactor > 1.0 ? "CIBicubicScaleTransform"
                                               : "CILanczosScaleTransform"
            if let scaleF = CIFilter(name: filterName) {
                scaleF.setValue(colourGraded, forKey: kCIInputImageKey)
                scaleF.setValue(scaleFactor,  forKey: kCIInputScaleKey)
                scaleF.setValue(1.0,          forKey: "inputAspectRatio")
                if scaleFactor > 1.0 {
                    scaleF.setValue(0.75, forKey: "inputB")   // Mitchell-Netravali B
                    scaleF.setValue(0.25, forKey: "inputC")   // Mitchell-Netravali C
                }
                upscaled = scaleF.outputImage ?? colourGraded
            } else {
                upscaled = colourGraded
            }
        } else {
            upscaled = colourGraded
        }

        // ── Stage 3: Adaptive sharpening (BEFORE denoise) ───────────────────────
        //
        // CIUnsharpMask replaces the old CISharpenLuminance because:
        //   • inputThreshold skips flat/noisy areas (where pixel difference < threshold)
        //     → dramatically reduces white-fringe and noise-amplification artefacts.
        //   • inputRadius lets us control the spatial reach of the sharpening halo.
        //
        // Strength baseline by 35mm-equivalent focal length (at ISO 100):
        //   21 mm  0.12 — ultra-wide native optics are already very sharp
        //   35 mm  0.16 — standard wide
        //   50 mm  0.20 — normal
        //   105mm  0.28 — telephoto compression needs the most recovery
        //
        // ISO attenuation — high-ISO shots carry real noise that sharpening amplifies:
        //   ISO ≤ 200  → ×1.00  (full strength)
        //   ISO 800    → ×0.65
        //   ISO 3200   → ×0.30  (floor)
        let baseSharpen: Float
        switch focalLength {
        case 21:  baseSharpen = 0.12
        case 35:  baseSharpen = 0.16
        case 50:  baseSharpen = 0.20
        case 105: baseSharpen = 0.28
        default:  baseSharpen = 0.18
        }
        let isoAtten = Float(max(0.30, 1.0 - max(0.0, Double(isoValue) - 200.0) / 1200.0))
        let sharpenStrength = baseSharpen * isoAtten

        let sharpened: CIImage
        if let usmF = CIFilter(name: "CIUnsharpMask") {
            usmF.setValue(upscaled,        forKey: kCIInputImageKey)
            usmF.setValue(1.5,             forKey: "inputRadius")      // spatial halo size
            usmF.setValue(sharpenStrength, forKey: "inputIntensity")
            usmF.setValue(0.012,           forKey: "inputThreshold")   // skip flat/noisy areas
            sharpened = usmF.outputImage ?? upscaled
        } else if let legacyF = CIFilter(name: "CISharpenLuminance") {
            // Fallback for any OS version that lacks CIUnsharpMask
            legacyF.setValue(upscaled,        forKey: kCIInputImageKey)
            legacyF.setValue(sharpenStrength, forKey: kCIInputSharpnessKey)
            legacyF.setValue(0.0,             forKey: "inputRadius")
            sharpened = legacyF.outputImage ?? upscaled
        } else {
            sharpened = upscaled
        }

        // ── Stage 4: ISO-conditional denoise (AFTER sharpening) ─────────────────
        //
        // Key insight: sharpening FIRST then denoising is intentional.
        // Light sharpening restores bicubic-upscale softness; the denoise then removes
        // noise that sharpening amplified in flat regions.  At low ISO the bicubic
        // kernel's own smoothness is sufficient — skipping denoise preserves the
        // natural micro-texture that gives images their "optical" feel.
        //
        //   ISO < 200   → no denoise       (keep film grain / micro-texture)
        //   ISO 200–800 → very light 0.010 (trim interpolation artefacts only)
        //   ISO > 800   → scales with ISO  (0.020 → 0.040 hard cap)
        let finalImage: CIImage
        if isoValue > 200, let noiseF = CIFilter(name: "CINoiseReduction") {
            let noiseLevel: Float = isoValue > 800
                ? Float(min(0.040, 0.020 + (Double(isoValue) - 800.0) / 30_000.0))
                : 0.010
            noiseF.setValue(sharpened,  forKey: kCIInputImageKey)
            noiseF.setValue(noiseLevel, forKey: "inputNoiseLevel")
            noiseF.setValue(0.0,        forKey: "inputSharpness")
            finalImage = noiseF.outputImage ?? sharpened
        } else {
            finalImage = sharpened
        }

        guard let outputCG = ciContext.createCGImage(finalImage, from: finalImage.extent) else {
            await MainActor.run { captureError = "Failed to render final image" }; return
        }

        // Build full EXIF + metadata properties (orientation preserved from photo.metadata).
        let properties = buildEXIF(from: photo, focalLength: focalLength,
                                    experimentalColor: experimentalColor)
        do {
            try await saveToLibrary(cgImage: outputCG, exif: properties)
            UINotificationFeedbackGenerator().notificationOccurred(.success)
        } catch {
            await MainActor.run { captureError = error.localizedDescription }
            logger.error("Photo save failed: \(error.localizedDescription)")
        }
    }

    // MARK: - Private: EXIF builder

    /// Returns a full CGImageDestination properties dict built from photo.metadata,
    /// with custom only_snap fields merged into the EXIF sub-dictionary.
    /// The top-level kCGImagePropertyOrientation is preserved so the saved photo
    /// displays correctly without needing a UIImage orientation wrapper.
    private func buildEXIF(from photo: AVCapturePhoto,
                            focalLength: Int,
                            experimentalColor: Bool) -> [String: Any] {
        // Use photo.metadata as the base — it contains orientation, GPS, TIFF, etc.
        var fullProps = photo.metadata as [String: Any]
        var exif = (fullProps[kCGImagePropertyExifDictionary as String]
                        as? [String: Any]) ?? [:]

        // Focal length (35mm equivalent)
        exif[kCGImagePropertyExifFocalLength          as String] = Double(focalLength)
        exif[kCGImagePropertyExifFocalLenIn35mmFilm   as String] = focalLength
        // Software / lens identification
        exif[kCGImagePropertyExifLensMake             as String] = "only_snap"
        exif[kCGImagePropertyExifUserComment          as String] =
            "only_snap | \(focalLength)mm | \(experimentalColor ? "RY" : "raw")"

        // Original ISO / shutter / aperture / EV are already present in exif from
        // photo.metadata — we only override our custom fields above.

        fullProps[kCGImagePropertyExifDictionary as String] = exif
        return fullProps
    }

    // MARK: - Private: saveToLibrary

    private func saveToLibrary(cgImage: CGImage, exif: [String: Any]) async throws {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
                  data, "public.jpeg" as CFString, 1, nil)
        else { throw CameraError.saveFailed }

        // `exif` is actually the full properties dict (session + EXIF sub-dict).
        // CGImageDestinationAddImage writes the pixel data and embeds all metadata.
        CGImageDestinationAddImage(dest, cgImage, exif as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw CameraError.saveFailed }

        let finalData = data as Data
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let req = PHAssetCreationRequest.forAsset()
                req.addResource(with: .photo, data: finalData, options: nil)
            } completionHandler: { ok, err in
                if ok { cont.resume() }
                else  { cont.resume(throwing: err ?? CameraError.saveFailed) }
            }
        }
    }

    private enum CameraError: LocalizedError {
        case saveFailed
        var errorDescription: String? { "Could not save photo to library" }
    }
}

// MARK: - PhotoCaptureDelegate

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate {
    let format: AspectFormat
    let experimentalColor: Bool
    let cropFactor: CGFloat
    let focalLength: Int
    nonisolated(unsafe) weak var cameraManager: CameraManager?
    nonisolated(unsafe) let completion: () -> Void

    init(format: AspectFormat, experimentalColor: Bool, cropFactor: CGFloat,
         focalLength: Int, cameraManager: CameraManager, completion: @escaping () -> Void) {
        self.format            = format
        self.experimentalColor = experimentalColor
        self.cropFactor        = cropFactor
        self.focalLength       = focalLength
        self.cameraManager     = cameraManager
        self.completion        = completion
    }

    nonisolated func photoOutput(_ output: AVCapturePhotoOutput,
                                  didFinishProcessingPhoto photo: AVCapturePhoto,
                                  error: Error?) {
        guard let cm = cameraManager else { completion(); return }
        if let error = error {
            Task { @MainActor in cm.captureError = error.localizedDescription }
            Task { @MainActor in self.completion() }
            return
        }
        cm.imageProcessingQueue.async {
            Task {
                await cm.handleCapturedPhoto(
                    photo,
                    format: self.format,
                    experimentalColor: self.experimentalColor,
                    cropFactor: self.cropFactor,
                    focalLength: self.focalLength
                )
                await MainActor.run { self.completion() }
            }
        }
    }
}
