@preconcurrency import AVFoundation
import Photos
import CoreImage
import ImageIO
import Metal
import UIKit
import Combine

final class CameraManager: NSObject, ObservableObject, @unchecked Sendable {

    // MARK: - Published state

    @Published var permissionDenied = false
    @Published var permissionMessage: String?
    @Published var isSessionRunning = false
    @Published var captureError: String?

    @Published private(set) var activeFilmProfile: FilmProfile = .raw
    @Published private(set) var pendingFilmProfile: FilmProfile?
    @Published private(set) var isVGReady = false
    @Published private(set) var isEWReady = false
    @Published private(set) var isLGReady = false
    @Published private(set) var selectedFocalLength = 28
    @Published private(set) var selectedAspectFormat: AspectFormat = .threeToFour
    @Published private(set) var flashEnabled = false
    @Published private(set) var captureOutputKind: CaptureOutputKind = .jpg
    @Published private(set) var isAELocked = false
    @Published private(set) var meteringMode: MeteringMode = .matrix
    @Published private(set) var isWidescreenEnabled = false
    @Published private(set) var availableFocalLengths: [Int] = [15, 28, 43, 85]
    @Published private(set) var histogramSamples: [CGFloat] = CameraManager.defaultHistogramSamples
    @Published private(set) var cameraOrientation: CameraOrientationState = .portrait
    @Published private(set) var previewGeneration = 0
    @Published private(set) var isPreviewTransitioning = false
    @Published private(set) var previewTransitionReason = "startup"

    // MARK: - Session-owned objects

    nonisolated(unsafe) let session = AVCaptureSession()
    nonisolated(unsafe) let photoOutput = AVCapturePhotoOutput()
    nonisolated(unsafe) let previewOutput = AVCaptureVideoDataOutput()

    private(set) var currentDevice: AVCaptureDevice?

    // MARK: - Queues

    private let sessionQueue = DispatchQueue(label: "camera.session.queue")
    fileprivate let imageProcessingQueue = DispatchQueue(
        label: "camera.imageprocessing.queue",
        qos: .userInitiated
    )
    private let profilePreheatQueue = DispatchQueue(
        label: "camera.profile.preheat.queue",
        qos: .utility
    )

    // MARK: - Session-owned state

    nonisolated(unsafe) private var isSessionConfigured = false
    nonisolated(unsafe) private var sessionSelectedFocalLength = 28
    nonisolated(unsafe) private var sessionFlashEnabled = false
    nonisolated(unsafe) private var meteringState = MeteringRuntimeState()
    nonisolated(unsafe) private var sessionCaptureOutputKind = CaptureOutputKind.jpg
    nonisolated(unsafe) private var sessionOrientation = CameraOrientationState.portrait
    nonisolated(unsafe) private var lastAppliedOrientationState: CameraOrientationState?
    nonisolated(unsafe) private var lastAppliedVideoOutputAngle: CGFloat?
    nonisolated(unsafe) private var lastAppliedPhotoAngle: CGFloat?
    nonisolated(unsafe) private var captureCropFactor: CGFloat = 1.0
    nonisolated(unsafe) private var digitalZoomFactor: CGFloat = 1.0
    nonisolated(unsafe) private var sessionMaxPhotoDimensions: CMVideoDimensions?
    nonisolated(unsafe) private var cameraCapabilities = CameraCapabilities.empty
    nonisolated(unsafe) private var lastHistogramUpdateAt: TimeInterval = 0
    private var previousStandardAspectFormat: AspectFormat = .threeToFour

    // MARK: - Observers / delegates

    private var inProgressDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var sessionRunningObserver: AnyCancellable?
    private var runtimeErrorObserver: AnyCancellable?
    private var interruptionObserver: AnyCancellable?
    private var interruptionEndedObserver: AnyCancellable?

    // MARK: - Permissions / timings

    private var cameraPermissionGranted = false
    private var photoPermissionGranted = false
    nonisolated(unsafe) private var launchStartedAt = CameraManager.now()
    private var didReportFirstPreviewFrame = false
    private var didStartVGPreheat = false
    private var didStartEWPreheat = false
    private var didStartLGPreheat = false
    private var vgPreheatStartedAt: TimeInterval?
    private var ewPreheatStartedAt: TimeInterval?
    private var lgPreheatStartedAt: TimeInterval?
    private var profileRequestStartedAt: [FilmProfile: TimeInterval] = [:]
    private var didLogInitialOrientationState = false
    nonisolated(unsafe) private var pendingOrientationTransition: PendingOrientationTransition?
    nonisolated(unsafe) private var pendingFocalTransition: PendingFocalTransition?
    nonisolated(unsafe) private var startupStartRunningEndedAt: TimeInterval?
    private static let outputJPEGQuality: CGFloat = 0.95
    private static let outputHEIFQuality: CGFloat = 0.93
    private static let outputTargetPixels: CGFloat = 36_000_000
    private static let outputResizeTolerance: CGFloat = 0.01
    private static let fullFrame35mmWidth: CGFloat = 36
    private static let nominalUltraWideEquivalent: CGFloat = 15
    private static let nominalWideEquivalent: CGFloat = 28
    private static let nominalTeleShortEquivalent: CGFloat = 77
    private static let nominalTeleLongEquivalent: CGFloat = 120
    private static let outputColorSpace = CGColorSpace(name: CGColorSpace.sRGB)
        ?? CGColorSpaceCreateDeviceRGB()
    private let meteringTuning = MeteringTuning.default
    static let defaultHistogramSamples: [CGFloat] = [
        0.40, 0.46, 0.44, 0.52, 0.50, 0.58, 0.62, 0.56,
        0.48, 0.44, 0.50, 0.60, 0.72, 0.66, 0.54, 0.46,
        0.42, 0.36
    ]

    private struct PendingOrientationTransition {
        let from: CameraOrientationState
        let to: CameraOrientationState
        let generation: Int
        let startedAt: TimeInterval
    }

    private struct PendingFocalTransition {
        let from: Int
        let to: Int
        let generation: Int
        let startedAt: TimeInterval
        var sessionReconfiguredAt: TimeInterval?
    }

    private struct PhotoQualityMetrics {
        let iso: CGFloat
        let exposureSeconds: Double?
        let fNumber: Double?
        let brightnessValue: Double?
        let whiteBalance: Int?
    }

    private struct DetailProcessingPlan {
        let sharpenIntensity: Float
        let sharpenRadius: Float
        let noiseLevel: Float
        let shouldDenoise: Bool
        let reason: String
    }

    private struct CameraCapabilities {
        let hasUltraWide: Bool
        let hasWide: Bool
        let hasTelephoto: Bool
        let telephoto35mmEquivalent: CGFloat?
        let wide35mmEquivalent: CGFloat
        let ultraWide35mmEquivalent: CGFloat?
        let virtualSwitchFactors: [CGFloat]

        static let empty = CameraCapabilities(
            hasUltraWide: false,
            hasWide: false,
            hasTelephoto: false,
            telephoto35mmEquivalent: nil,
            wide35mmEquivalent: 24,
            ultraWide35mmEquivalent: nil,
            virtualSwitchFactors: []
        )

        var supportedFocalLengths: [Int] {
            if hasTelephoto {
                return [15, 28, 43, 77, 120]
            }
            return [15, 28, 43, 85]
        }
    }

    private struct MeteringTuning {
        let histogramInterval: TimeInterval
        let adaptiveInterval: TimeInterval
        let biasDeadband: Float
        let applyDeadband: Float
        let smoothingTau: Float
        let fastResponseThreshold: Float
        let shadowThreshold: CGFloat
        let highlightThreshold: CGFloat
        let hardHighlightThreshold: CGFloat

        static let `default` = MeteringTuning(
            histogramInterval: 0.14,
            adaptiveInterval: 0.55,
            biasDeadband: 0.07,
            applyDeadband: 0.035,
            smoothingTau: 1.15,
            fastResponseThreshold: 0.30,
            shadowThreshold: 0.18,
            highlightThreshold: 0.82,
            hardHighlightThreshold: 0.92
        )
    }

    private struct MeteringRuntimeState {
        var bias: Float = 0
        var smoothedBias: Float = 0
        var lastUpdateTime: TimeInterval = 0
        var lastSmoothingTime: TimeInterval = 0
        var lastDesiredBias: Float = 0
        var mode: MeteringMode = .matrix
        var aeLocked: Bool = false
        var adaptivePausedUntil: TimeInterval = 0
    }

    private struct MeteringZoneSummary: Sendable {
        let rows: Int
        let columns: Int
        let means: [CGFloat]
        let counts: [Int]
        let shadowShares: [CGFloat]
        let highlightShares: [CGFloat]
        let hardHighlightShares: [CGFloat]
        let globalMean: CGFloat
        let globalShadowShare: CGFloat
        let globalHighlightShare: CGFloat
        let globalHardHighlightShare: CGFloat
    }

    private struct MeteringWeightedStats {
        let mean: CGFloat
        let shadowShare: CGFloat
        let highlightShare: CGFloat
        let hardHighlightShare: CGFloat
    }

    private struct ExposureEnvironment {
        enum Kind: String {
            case balanced
            case overcast
            case lowLight
            case highKey
            case highContrast
            case hardHighlight
            case backlit
        }

        let kind: Kind
        let intensity: CGFloat
    }

    private struct MeteringBiasDecision {
        let desiredBias: Float
        let environment: ExposureEnvironment
    }

    private struct ExposureResponse {
        let smoothingTau: Float
        let maxAlpha: Float
        let fastResponseThreshold: Float
        let fastAlpha: Float
        let positiveStep: Float
        let negativeStep: Float
    }

    // MARK: - Rendering

    let photoCIContext: CIContext = {
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: [
                .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
                .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any
            ])
        }
        return CIContext(options: [.useSoftwareRenderer: false])
    }()

    // MARK: - Lifecycle

    override init() {
        super.init()

        previewOutput.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
        ]
        previewOutput.alwaysDiscardsLateVideoFrames = true

        sessionRunningObserver = session.publisher(for: \.isRunning)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] running in
                self?.isSessionRunning = running
                RuntimeLog.info("[Session]", "isRunning=\(running)")
            }

        runtimeErrorObserver = NotificationCenter.default
            .publisher(for: AVCaptureSession.runtimeErrorNotification, object: session)
            .sink { notification in
                let error = (notification.userInfo?[AVCaptureSessionErrorKey] as? NSError)?
                    .localizedDescription ?? "unknown"
                RuntimeLog.error("[Error]", "sessionRuntimeError=\(error)")
            }

        interruptionObserver = NotificationCenter.default
            .publisher(for: AVCaptureSession.wasInterruptedNotification, object: session)
            .sink { notification in
                let raw = notification.userInfo?[AVCaptureSessionInterruptionReasonKey] as? NSNumber
                RuntimeLog.error("[Error]", "sessionInterrupted reason=\(raw?.intValue ?? -1)")
            }

        interruptionEndedObserver = NotificationCenter.default
            .publisher(for: AVCaptureSession.interruptionEndedNotification, object: session)
            .sink { _ in
                RuntimeLog.info("[Session]", "interruptionEnded")
            }

        logInitialOrientationStateIfNeeded()
    }

    deinit {
        sessionRunningObserver?.cancel()
        runtimeErrorObserver?.cancel()
        interruptionObserver?.cancel()
        interruptionEndedObserver?.cancel()
        sessionQueue.sync {
            self.previewOutput.setSampleBufferDelegate(nil, queue: nil)
        }
    }

    // MARK: - Start / Stop

    func start() async {
        let requestStartedAt = Self.now()
        launchStartedAt = requestStartedAt
        didReportFirstPreviewFrame = false
        startupStartRunningEndedAt = nil

        if !cameraPermissionGranted {
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            switch status {
            case .authorized:
                cameraPermissionGranted = true
                RuntimeLog.info(
                    "[Startup]",
                    "cameraPermission=granted elapsed=\(Self.formatDuration(Self.now() - requestStartedAt))"
                )
            case .notDetermined:
                let granted = await AVCaptureDevice.requestAccess(for: .video)
                if !granted {
                    await MainActor.run {
                        permissionDenied = true
                        permissionMessage = "Camera access required"
                    }
                    RuntimeLog.error(
                        "[Error]",
                        "cameraPermission=denied elapsed=\(Self.formatDuration(Self.now() - requestStartedAt))"
                    )
                    return
                }
                cameraPermissionGranted = true
                RuntimeLog.info(
                    "[Startup]",
                    "cameraPermission=granted elapsed=\(Self.formatDuration(Self.now() - requestStartedAt))"
                )
            default:
                await MainActor.run {
                    permissionDenied = true
                    permissionMessage = "Camera access required"
                }
                RuntimeLog.error("[Error]", "cameraPermission=denied status=\(status.rawValue)")
                return
            }
        }

        if !photoPermissionGranted {
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .authorized, .limited:
                photoPermissionGranted = true
            case .notDetermined:
                let result = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
                if result != .authorized && result != .limited {
                    await MainActor.run {
                        permissionDenied = true
                        permissionMessage = "Photo library access required"
                    }
                    RuntimeLog.error("[Error]", "photoPermission=denied status=\(result.rawValue)")
                    return
                }
                photoPermissionGranted = true
            default:
                await MainActor.run {
                    permissionDenied = true
                    permissionMessage = "Photo library access required"
                }
                RuntimeLog.error("[Error]", "photoPermission=denied status=\(status.rawValue)")
                return
            }
        }

        await MainActor.run {
            permissionDenied = false
            permissionMessage = nil
        }

        RuntimeLog.info(
            "[Startup]",
            "permissionElapsed=\(Self.formatDuration(Self.now() - launchStartedAt))"
        )

        await configureSessionIfNeeded()
    }

    func stop() {
        RuntimeLog.info("[Session]", "stopRequested")
        sessionQueue.async {
            guard self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    // MARK: - UI state mutation

    func setAspectFormat(_ format: AspectFormat) {
        guard format != selectedAspectFormat else { return }
        if format == .cinematicWide {
            isWidescreenEnabled = true
        } else {
            previousStandardAspectFormat = format
            isWidescreenEnabled = false
        }
        selectedAspectFormat = format
        bumpPreviewGeneration(reason: "aspectFormatChanged")
        RuntimeLog.info("[Preview]", "aspectFormat=\(format.label)")
    }

    func toggleWidescreenMode() {
        let next = !isWidescreenEnabled
        isWidescreenEnabled = next

        if next {
            if selectedAspectFormat != .cinematicWide {
                if selectedAspectFormat != .cinematicWide {
                    previousStandardAspectFormat = selectedAspectFormat
                }
                selectedAspectFormat = .cinematicWide
                bumpPreviewGeneration(reason: "widescreenChanged")
            }
            RuntimeLog.info("[Preview]", "widescreen=true aspect=2.39 focal=28")
            if selectedFocalLength != 28 {
                setFocalLength(28)
            }
        } else {
            let restoreFormat = previousStandardAspectFormat == .cinematicWide
                ? AspectFormat.threeToFour
                : previousStandardAspectFormat
            selectedAspectFormat = restoreFormat
            bumpPreviewGeneration(reason: "widescreenChanged")
            RuntimeLog.info("[Preview]", "widescreen=false aspect=\(restoreFormat.label)")
        }
    }

    func setFlashEnabled(_ enabled: Bool) {
        flashEnabled = enabled
        sessionFlashEnabled = enabled
        RuntimeLog.info("[Capture]", "flashEnabled=\(enabled)")
    }

    func cycleCaptureOutputKind() {
        let next = captureOutputKind.next
        captureOutputKind = next
        sessionCaptureOutputKind = next
        RuntimeLog.info("[Capture]", "outputKind=\(next.logName)")
    }

    func toggleAELock() {
        let target = !isAELocked
        sessionQueue.async {
            guard let device = self.currentDevice else {
                DispatchQueue.main.async {
                    self.captureError = "No active camera for AE lock"
                }
                RuntimeLog.error("[Error]", "aeLockFailed reason=noCurrentDevice")
                return
            }

            do {
                try device.lockForConfiguration()
                let applied: Bool
                let shouldRampBiasToZero: Bool
                do {
                    defer { device.unlockForConfiguration() }
                    if target {
                        applied = self.applyExposureLockLocked(to: device, locked: true)
                        shouldRampBiasToZero = false
                    } else {
                        _ = self.applyExposureLockLocked(to: device, locked: false)
                        self.applyMeteringModeLocked(to: device, mode: self.meteringState.mode)
                        applied = false
                        shouldRampBiasToZero = true
                    }
                }
                self.meteringState.aeLocked = applied
                if shouldRampBiasToZero {
                    self.scheduleBiasRampToZero()
                }
                DispatchQueue.main.async {
                    self.isAELocked = applied
                }
                RuntimeLog.info(
                    "[Exposure]",
                    "aeLockRequested=\(target) applied=\(applied) mode=\(device.exposureMode.rawValue)"
                )
            } catch {
                DispatchQueue.main.async {
                    self.captureError = error.localizedDescription
                }
                RuntimeLog.error("[Error]", "aeLockFailed error=\(error.localizedDescription)")
            }
        }
    }

    func cycleMeteringMode() {
        let next = meteringMode.next
        meteringMode = next
        RuntimeLog.info("[Exposure]", "meteringMode=\(next.logName)")

        sessionQueue.async {
            self.meteringState.mode = next
            guard let device = self.currentDevice else { return }
            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                self.resetMeteringBiasLocked(to: device)
                self.applyMeteringModeLocked(to: device, mode: next)
                if self.meteringState.aeLocked {
                    _ = self.applyExposureLockLocked(to: device, locked: true)
                }
            } catch {
                RuntimeLog.error("[Error]", "meteringModeApplyFailed error=\(error.localizedDescription)")
            }
        }
    }

    func requestFilmProfile(_ profile: FilmProfile) {
        switch profile {
        case .raw:
            guard activeFilmProfile != .raw || pendingFilmProfile != nil else { return }
        case .vg:
            guard activeFilmProfile != .vg, pendingFilmProfile != .vg else { return }
        case .ew:
            guard activeFilmProfile != .ew, pendingFilmProfile != .ew else { return }
        case .lg:
            guard activeFilmProfile != .lg, pendingFilmProfile != .lg else { return }
        }

        profileRequestStartedAt[profile] = Self.now()

        switch profile {
        case .raw:
            pendingFilmProfile = nil
            activeFilmProfile = .raw
            RuntimeLog.info("[FilmProfile]", "requested=sd active=sd ready=true")
        case .vg:
            if isVGReady {
                pendingFilmProfile = nil
                activeFilmProfile = .vg
                let elapsed = profileRequestStartedAt[.vg].map { Self.now() - $0 } ?? 0
                RuntimeLog.info(
                    "[FilmProfile]",
                    "requested=vg active=vg ready=true elapsed=\(Self.formatDuration(elapsed))"
                )
            } else {
                pendingFilmProfile = .vg
                preheatVGResourcesIfNeeded()
                RuntimeLog.info("[FilmProfile]", "requested=vg active=\(activeFilmProfile.logName) ready=false pending=true")
            }
        case .ew:
            if isEWReady {
                pendingFilmProfile = nil
                activeFilmProfile = .ew
                let elapsed = profileRequestStartedAt[.ew].map { Self.now() - $0 } ?? 0
                RuntimeLog.info(
                    "[FilmProfile]",
                    "requested=ew active=ew ready=true elapsed=\(Self.formatDuration(elapsed))"
                )
            } else {
                pendingFilmProfile = .ew
                preheatEWResourcesIfNeeded()
                RuntimeLog.info(
                    "[FilmProfile]",
                    "requested=ew active=\(activeFilmProfile.logName) ready=false pending=true"
                )
            }
        case .lg:
            if isLGReady {
                pendingFilmProfile = nil
                activeFilmProfile = .lg
                let elapsed = profileRequestStartedAt[.lg].map { Self.now() - $0 } ?? 0
                RuntimeLog.info(
                    "[FilmProfile]",
                    "requested=lg active=lg ready=true elapsed=\(Self.formatDuration(elapsed))"
                )
            } else {
                pendingFilmProfile = .lg
                preheatLGResourcesIfNeeded()
                RuntimeLog.info(
                    "[FilmProfile]",
                    "requested=lg active=\(activeFilmProfile.logName) ready=false pending=true"
                )
            }
        }

        bumpPreviewGeneration(reason: "filmProfileChanged")
        applyCameraOrientationAsync(reason: "filmProfileChanged")
    }

    func updateCameraOrientation(_ deviceOrientation: UIDeviceOrientation) {
        let rawName = CameraOrientationState.logName(for: deviceOrientation)

        guard let next = CameraOrientationState(deviceOrientation: deviceOrientation) else {
            RuntimeLog.info(
                "[Orientation]",
                "rawDeviceOrientation=\(rawName) ignored=\(cameraOrientation.rawValue)"
            )
            RuntimeLog.info(
                "[Orientation]",
                "ignoredUnsupportedOrientation raw=\(rawName) keeping=\(cameraOrientation.rawValue)"
            )
            return
        }

        RuntimeLog.info(
            "[Orientation]",
            "rawDeviceOrientation=\(rawName) accepted=\(next.rawValue)"
        )

        guard next != cameraOrientation else { return }

        let generation = beginPreviewTransition(reason: "orientationWillChange", state: next)
        pendingOrientationTransition = PendingOrientationTransition(
            from: cameraOrientation,
            to: next,
            generation: generation,
            startedAt: Self.now()
        )
        sessionOrientation = next
        applyCameraOrientationAsync(reason: "deviceOrientationChanged")
    }

    // MARK: - Preview delegate routing

    func attachPreviewDelegate(
        _ delegate: AVCaptureVideoDataOutputSampleBufferDelegate,
        queue: DispatchQueue
    ) {
        sessionQueue.async {
            self.previewOutput.setSampleBufferDelegate(delegate, queue: queue)
            RuntimeLog.info("[Preview]", "delegateAttached")
            self.applyCameraOrientation(reason: "previewOutputAttached")
        }
    }

    func detachPreviewDelegate(waitUntilDone: Bool = false) {
        if waitUntilDone {
            sessionQueue.sync {
                self.previewOutput.setSampleBufferDelegate(nil, queue: nil)
                RuntimeLog.info("[Preview]", "delegateDetached")
            }
        } else {
            sessionQueue.async {
                self.previewOutput.setSampleBufferDelegate(nil, queue: nil)
                RuntimeLog.info("[Preview]", "delegateDetached")
            }
        }
    }

    nonisolated func updatePreviewHistogram(from pixelBuffer: CVPixelBuffer) {
        let now = Self.now()
        let isStartupWarmup = now - launchStartedAt < 1.6
        let effectiveHistogramInterval = isStartupWarmup ? 0.28 : meteringTuning.histogramInterval
        guard now - lastHistogramUpdateAt >= effectiveHistogramInterval else { return }
        lastHistogramUpdateAt = now

        let pixelFormat = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard pixelFormat == kCVPixelFormatType_32BGRA else { return }

        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let buffer = baseAddress.assumingMemoryBound(to: UInt8.self)

        let bucketCount = 24
        var buckets = Array(repeating: 0, count: bucketCount)
        let shouldCollectMeteringZones = !isStartupWarmup
            && pendingFocalTransition == nil
            && pendingOrientationTransition == nil
        let zoneRows = 6
        let zoneColumns = 8
        let zoneCount = zoneRows * zoneColumns
        var zoneLumaSums = shouldCollectMeteringZones ? Array(repeating: CGFloat(0), count: zoneCount) : []
        var zoneCounts = shouldCollectMeteringZones ? Array(repeating: 0, count: zoneCount) : []
        var zoneShadowCounts = shouldCollectMeteringZones ? Array(repeating: 0, count: zoneCount) : []
        var zoneHighlightCounts = shouldCollectMeteringZones ? Array(repeating: 0, count: zoneCount) : []
        var zoneHardHighlightCounts = shouldCollectMeteringZones ? Array(repeating: 0, count: zoneCount) : []
        var globalLumaSum: CGFloat = 0
        var globalSampleCount = 0
        var globalShadowCount = 0
        var globalHighlightCount = 0
        var globalHardHighlightCount = 0
        let stepX = max(1, width / 48)
        let stepY = max(1, height / 32)

        var y = 0
        while y < height {
            var x = 0
            while x < width {
                let offset = y * bytesPerRow + x * 4
                let blue = CGFloat(buffer[offset]) / 255.0
                let green = CGFloat(buffer[offset + 1]) / 255.0
                let red = CGFloat(buffer[offset + 2]) / 255.0
                let luma = (0.2126 * red + 0.7152 * green + 0.0722 * blue).clamped(to: 0...1)
                let index = min(bucketCount - 1, Int(luma * CGFloat(bucketCount)))
                buckets[index] += 1

                if shouldCollectMeteringZones {
                    let zoneX = min(zoneColumns - 1, x * zoneColumns / max(1, width))
                    let zoneY = min(zoneRows - 1, y * zoneRows / max(1, height))
                    let zoneIndex = zoneY * zoneColumns + zoneX
                    zoneLumaSums[zoneIndex] += luma
                    zoneCounts[zoneIndex] += 1

                    globalLumaSum += luma
                    globalSampleCount += 1
                    if luma < meteringTuning.shadowThreshold {
                        zoneShadowCounts[zoneIndex] += 1
                        globalShadowCount += 1
                    }
                    if luma > meteringTuning.highlightThreshold {
                        zoneHighlightCounts[zoneIndex] += 1
                        globalHighlightCount += 1
                    }
                    if luma > meteringTuning.hardHighlightThreshold {
                        zoneHardHighlightCounts[zoneIndex] += 1
                        globalHardHighlightCount += 1
                    }
                }
                x += stepX
            }
            y += stepY
        }

        let maxCount = max(1, buckets.max() ?? 1)
        let normalized = buckets.map { CGFloat($0) / CGFloat(maxCount) }
        if shouldCollectMeteringZones {
            let zones = makeMeteringZoneSummary(
                rows: zoneRows,
                columns: zoneColumns,
                lumaSums: zoneLumaSums,
                counts: zoneCounts,
                shadowCounts: zoneShadowCounts,
                highlightCounts: zoneHighlightCounts,
                hardHighlightCounts: zoneHardHighlightCounts,
                globalLumaSum: globalLumaSum,
                globalSampleCount: globalSampleCount,
                globalShadowCount: globalShadowCount,
                globalHighlightCount: globalHighlightCount,
                globalHardHighlightCount: globalHardHighlightCount
            )
            updateAdaptiveMeteringBiasIfNeeded(buckets: buckets, zones: zones, now: now)
        }

        DispatchQueue.main.async { [weak self] in
            self?.histogramSamples = normalized
        }
    }

    nonisolated private func makeMeteringZoneSummary(
        rows: Int,
        columns: Int,
        lumaSums: [CGFloat],
        counts: [Int],
        shadowCounts: [Int],
        highlightCounts: [Int],
        hardHighlightCounts: [Int],
        globalLumaSum: CGFloat,
        globalSampleCount: Int,
        globalShadowCount: Int,
        globalHighlightCount: Int,
        globalHardHighlightCount: Int
    ) -> MeteringZoneSummary {
        let means = lumaSums.enumerated().map { index, sum in
            let count = max(1, counts[index])
            return sum / CGFloat(count)
        }
        let shadowShares = shadowCounts.enumerated().map { index, count in
            CGFloat(count) / CGFloat(max(1, counts[index]))
        }
        let highlightShares = highlightCounts.enumerated().map { index, count in
            CGFloat(count) / CGFloat(max(1, counts[index]))
        }
        let hardHighlightShares = hardHighlightCounts.enumerated().map { index, count in
            CGFloat(count) / CGFloat(max(1, counts[index]))
        }
        let total = max(1, globalSampleCount)

        return MeteringZoneSummary(
            rows: rows,
            columns: columns,
            means: means,
            counts: counts,
            shadowShares: shadowShares,
            highlightShares: highlightShares,
            hardHighlightShares: hardHighlightShares,
            globalMean: globalLumaSum / CGFloat(total),
            globalShadowShare: CGFloat(globalShadowCount) / CGFloat(total),
            globalHighlightShare: CGFloat(globalHighlightCount) / CGFloat(total),
            globalHardHighlightShare: CGFloat(globalHardHighlightCount) / CGFloat(total)
        )
    }

    func notifyFirstPreviewFrame() {
        guard !didReportFirstPreviewFrame else { return }
        didReportFirstPreviewFrame = true

        RuntimeLog.info(
            "[Startup]",
            "firstPreviewFrameElapsed=\(Self.formatDuration(Self.now() - launchStartedAt))"
        )
        if let startupStartRunningEndedAt {
            RuntimeLog.info(
                "[Startup]",
                "firstPreviewFrameFromStartRunningElapsed=\(Self.formatDuration(Self.now() - startupStartRunningEndedAt))"
            )
        }
        preheatVGResourcesIfNeeded()
        preheatEWResourcesIfNeeded()
        preheatLGResourcesIfNeeded()
    }

    func notifyPreviewFrameRendered(
        generation: Int,
        focalLength: Int,
        orientation: CameraOrientationState,
        reason: String
    ) {
        guard generation == previewGeneration else { return }

        if let pendingOrientationTransition, pendingOrientationTransition.generation == generation {
            let duration = Self.now() - pendingOrientationTransition.startedAt
            RuntimeLog.info(
                "[Performance]",
                "orientationSwitch duration=\(Self.formatDuration(duration)) generation=\(generation) state=\(orientation.rawValue)"
            )
            self.pendingOrientationTransition = nil
        }

        if let pendingFocalTransition, pendingFocalTransition.generation == generation {
            let total = Self.now() - pendingFocalTransition.startedAt
            let sessionConfig = pendingFocalTransition.sessionReconfiguredAt.map {
                Self.formatDuration($0 - pendingFocalTransition.startedAt)
            } ?? "n/a"
            let firstFrame = pendingFocalTransition.sessionReconfiguredAt.map {
                Self.formatDuration(Self.now() - $0)
            } ?? "n/a"

            RuntimeLog.info(
                "[FocalTransition]",
                "complete to=\(pendingFocalTransition.to) duration=\(Self.formatDuration(total))"
            )
            RuntimeLog.info(
                "[Performance]",
                "focalSwitch requested=\(pendingFocalTransition.from)->\(pendingFocalTransition.to) sessionConfig=\(sessionConfig) firstFrame=\(firstFrame) total=\(Self.formatDuration(total))"
            )
            self.pendingFocalTransition = nil
        }
    }

    func reapplyOrientation(reason: String) {
        applyCameraOrientationAsync(reason: reason)
    }

    // MARK: - Focal length

    func setFocalLength(_ mm: Int) {
        guard mm != selectedFocalLength else { return }
        let requestStartedAt = Self.now()
        let previousFocal = selectedFocalLength
        let previousDeviceID = currentDevice?.uniqueID
        let generation = beginPreviewTransition(reason: "focalWillChange")
        pendingFocalTransition = PendingFocalTransition(
            from: previousFocal,
            to: mm,
            generation: generation,
            startedAt: requestStartedAt,
            sessionReconfiguredAt: nil
        )
        RuntimeLog.info(
            "[FocalTransition]",
            "begin from=\(previousFocal) to=\(mm) generation=\(generation)"
        )

        sessionQueue.async {
            guard let selection = self.deviceSelection(for: mm, source: "focalChanged") else {
                DispatchQueue.main.async {
                    self.captureError = "No compatible camera device available"
                }
                self.cancelPreviewTransition(reason: "focalSelectionFailed")
                self.pendingFocalTransition = nil
                RuntimeLog.error("[Error]", "focalSelectionFailed requested=\(mm)")
                return
            }

            if selection.isFallback {
                let reason = selection.fallbackReason ?? "none"
                RuntimeLog.info(
                    "[Device]",
                    "fallback requested=\(mm) resolved=\(self.deviceLogName(for: selection.device)) position=\(self.positionLogName(for: selection.device)) reason=\(reason)"
                )
            }

            var zoomCalibration: ZoomCalibration?

            do {
                if selection.device.uniqueID == previousDeviceID {
                    try selection.device.lockForConfiguration()
                    let calibration: ZoomCalibration
                    do {
                        defer { selection.device.unlockForConfiguration() }
                        calibration = self.applyPreferredFormatAndZoomLocked(
                            for: selection.device,
                            targetFocalLength: mm,
                            reason: "focalChangedSameDevice"
                        )
                    }
                    zoomCalibration = calibration
                    self.configurePreferredPhotoDimensions(
                        for: selection.device,
                        reason: "focalChangedSameDevice"
                    )
                } else {
                    RuntimeLog.info("[Session]", "beginConfiguration reason=focalChanged")
                    self.session.beginConfiguration()
                    if let input = self.session.inputs.first {
                        self.session.removeInput(input)
                        RuntimeLog.info("[Session]", "inputRemoved reason=focalChanged")
                    }

                    let input = try AVCaptureDeviceInput(device: selection.device)
                    guard self.session.canAddInput(input) else {
                        self.session.commitConfiguration()
                        self.cancelPreviewTransition(reason: "focalInputAddFailed")
                        self.pendingFocalTransition = nil
                        RuntimeLog.error("[Error]", "inputAddFailed requested=\(mm)")
                        return
                    }
                    self.session.addInput(input)
                    RuntimeLog.info("[Session]", "inputAdded device=\(selection.deviceLabel)")

                    try selection.device.lockForConfiguration()
                    let calibration: ZoomCalibration
                    do {
                        defer { selection.device.unlockForConfiguration() }
                        calibration = self.applyPreferredFormatAndZoomLocked(
                            for: selection.device,
                            targetFocalLength: mm,
                            reason: "focalChanged"
                        )
                    }
                    zoomCalibration = calibration

                    self.configurePreferredPhotoDimensions(
                        for: selection.device,
                        reason: "focalChanged"
                    )
                    self.session.commitConfiguration()
                    RuntimeLog.info("[Session]", "commitConfiguration reason=focalChanged")
                }
            } catch {
                DispatchQueue.main.async {
                    self.captureError = error.localizedDescription
                }
                self.cancelPreviewTransition(reason: "focalSwitchFailed")
                self.pendingFocalTransition = nil
                RuntimeLog.error("[Error]", "focalSwitchFailed requested=\(mm) error=\(error.localizedDescription)")
                return
            }

            self.captureCropFactor = 1.0
            let appliedZoom = zoomCalibration?.zoomFactor ?? selection.zoomFactor
            self.digitalZoomFactor = appliedZoom
            self.sessionSelectedFocalLength = mm
            self.applyCameraOrientation(reason: "focalChanged")

            let sessionReconfiguredAt = Self.now()
            if var pendingFocalTransition = self.pendingFocalTransition,
               pendingFocalTransition.to == mm {
                pendingFocalTransition.sessionReconfiguredAt = sessionReconfiguredAt
                self.pendingFocalTransition = pendingFocalTransition
            }
            RuntimeLog.info(
                "[FocalTransition]",
                "sessionReconfigured to=\(mm) duration=\(Self.formatDuration(sessionReconfiguredAt - requestStartedAt))"
            )

            DispatchQueue.main.async {
                self.selectedFocalLength = mm
                self.currentDevice = selection.device
                self.completePreviewTransition(reason: "focalChanged")
            }

            let reason = selection.fallbackReason ?? "none"
            let focalCalibration = zoomCalibration.map {
                " base=\(Self.format($0.baseEquivalentFocalLength)) actual=\(Self.format($0.actualEquivalentFocalLength)) error=\(Self.format($0.errorRatio * 100))%"
            } ?? ""
            RuntimeLog.info(
                "[Focal]",
                "requested=\(mm) resolvedDevice=\(self.deviceLogName(for: selection.device)) position=\(self.positionLogName(for: selection.device)) zoom=\(Self.format(appliedZoom))\(focalCalibration) fallback=\(selection.isFallback) reason=\(reason) elapsed=\(Self.formatDuration(Self.now() - requestStartedAt))"
            )
        }
    }

    // MARK: - Capture

    func capture() async {
        let flashEnabled = self.flashEnabled
        let cropFactor = self.captureCropFactor
        let focal = selectedFocalLength
        let profile = activeFilmProfile
        let format = selectedAspectFormat
        let orientation = cameraOrientation
        let outputKind = captureOutputKind
        let deviceHasFlash = currentDevice?.hasFlash ?? false
        let captureStartedAt = Self.now()

        RuntimeLog.info(
            "[Capture]",
            "start profile=\(profile.logName) focal=\(focal) format=\(format.label) output=\(outputKind.logName) orientation=\(orientation.rawValue)"
        )
        await MainActor.run {
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
        }
        RuntimeLog.info("[Capture]", "feedbackIssued stage=shutter")

        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            sessionQueue.async {
                self.applyCameraOrientation(reason: "capturePrepared")

                guard self.session.isRunning else {
                    DispatchQueue.main.async {
                        self.captureError = "Session not running"
                    }
                    RuntimeLog.error("[Error]", "captureFailed reason=sessionNotRunning")
                    cont.resume()
                    return
                }

                guard !self.photoOutput.connections.isEmpty else {
                    DispatchQueue.main.async {
                        self.captureError = "No photo connection"
                    }
                    RuntimeLog.error("[Error]", "captureFailed reason=noPhotoConnection")
                    cont.resume()
                    return
                }

                let settings: AVCapturePhotoSettings
                do {
                    settings = try self.photoSettings(for: outputKind)
                } catch {
                    DispatchQueue.main.async {
                        self.captureError = error.localizedDescription
                    }
                    RuntimeLog.error("[Error]", "captureFailed error=\(error.localizedDescription)")
                    cont.resume()
                    return
                }
                settings.flashMode = (flashEnabled && deviceHasFlash) ? .on : .off
                settings.photoQualityPrioritization = .quality
                if self.photoOutput.isCameraCalibrationDataDeliverySupported {
                    settings.isCameraCalibrationDataDeliveryEnabled = true
                }
                if #available(iOS 16.0, *), let maxDimensions = self.sessionMaxPhotoDimensions {
                    settings.maxPhotoDimensions = maxDimensions
                    RuntimeLog.info(
                        "[PhotoOutput]",
                        "captureMaxPhotoDimensions=\(Self.photoDimensionsLogName(maxDimensions))"
                    )
                }

                if let connection = self.photoOutput.connection(with: .video),
                   connection.isVideoRotationAngleSupported(self.sessionOrientation.photoRotationAngle) {
                    connection.videoRotationAngle = self.sessionOrientation.photoRotationAngle
                }

                let uniqueID = settings.uniqueID
                let delegate = PhotoCaptureDelegate(
                    format: format,
                    filmProfile: profile,
                    outputKind: outputKind,
                    cropFactor: cropFactor,
                    digitalZoomFactor: self.digitalZoomFactor,
                    focalLength: focal,
                    captureStartedAt: captureStartedAt,
                    cameraManager: self,
                    completion: { [weak self] in
                        self?.inProgressDelegates.removeValue(forKey: uniqueID)
                        cont.resume()
                    }
                )

                self.inProgressDelegates[uniqueID] = delegate
                self.photoOutput.capturePhoto(with: settings, delegate: delegate)
            }
        }
    }

    // MARK: - Session configuration

    private func photoSettings(for outputKind: CaptureOutputKind) throws -> AVCapturePhotoSettings {
        switch outputKind {
        case .jpg, .heif:
            return AVCapturePhotoSettings()

        case .dng:
            guard let rawPixelFormat = photoOutput.availableRawPhotoPixelFormatTypes.first else {
                throw CameraError.dngUnsupported
            }
            return AVCapturePhotoSettings(rawPixelFormatType: rawPixelFormat)
        }
    }

    private func configureSessionIfNeeded() async {
        await withCheckedContinuation { cont in
            sessionQueue.async {
                if self.isSessionConfigured {
                    RuntimeLog.info("[Session]", "restartRequested configured=true")
                    self.ensureRearCameraInputIfNeeded(source: "sessionRestart")
                    if !self.session.isRunning {
                        self.session.startRunning()
                    }
                    self.applyCameraOrientation(reason: "sessionRestarted")
                    cont.resume()
                    return
                }

                let deviceDiscoveryStartedAt = Self.now()
                RuntimeLog.info("[Session]", "beginConfiguration reason=initialSetup preset=photo")
                let sessionConfigurationStartedAt = Self.now()
                self.session.beginConfiguration()
                self.session.sessionPreset = .photo
                var configuredCaptureDevice: AVCaptureDevice?

                if let selection = self.deviceSelection(
                    for: self.sessionSelectedFocalLength,
                    source: "initialConfigure"
                ) {
                    RuntimeLog.info(
                        "[Startup]",
                        "deviceDiscoveryElapsed=\(Self.formatDuration(Self.now() - deviceDiscoveryStartedAt))"
                    )
                    RuntimeLog.info(
                        "[Device]",
                        "initialSelection requested=\(self.sessionSelectedFocalLength) resolved=\(self.deviceLogName(for: selection.device)) position=\(self.positionLogName(for: selection.device))"
                    )
                    if selection.isFallback {
                        let reason = selection.fallbackReason ?? "none"
                        RuntimeLog.info(
                            "[Device]",
                            "fallback requested=\(self.sessionSelectedFocalLength) resolved=\(self.deviceLogName(for: selection.device)) position=\(self.positionLogName(for: selection.device)) reason=\(reason)"
                        )
                    }
                    do {
                        let input = try AVCaptureDeviceInput(device: selection.device)
                        if self.session.canAddInput(input) {
                            self.session.addInput(input)
                            RuntimeLog.info("[Session]", "inputAdded device=\(selection.deviceLabel)")
                        }

                        try selection.device.lockForConfiguration()
                        let calibration: ZoomCalibration
                        do {
                            defer { selection.device.unlockForConfiguration() }
                            calibration = self.applyPreferredFormatAndZoomLocked(
                                for: selection.device,
                                targetFocalLength: self.sessionSelectedFocalLength,
                                reason: "initialSetup"
                            )
                        }

                        self.captureCropFactor = 1.0
                        self.digitalZoomFactor = calibration.zoomFactor
                        configuredCaptureDevice = selection.device

                        DispatchQueue.main.async {
                            self.currentDevice = selection.device
                        }
                    } catch {
                        DispatchQueue.main.async {
                            self.captureError = error.localizedDescription
                        }
                        RuntimeLog.error("[Error]", "initialInputConfigurationFailed error=\(error.localizedDescription)")
                    }
                }

                if self.session.outputs.contains(where: { $0 === self.previewOutput }) == false,
                   self.session.canAddOutput(self.previewOutput) {
                    self.session.addOutput(self.previewOutput)
                    RuntimeLog.info("[Session]", "outputAdded type=previewVideoData")
                }

                if self.session.outputs.contains(where: { $0 === self.photoOutput }) == false,
                   self.session.canAddOutput(self.photoOutput) {
                    self.session.addOutput(self.photoOutput)
                    self.photoOutput.maxPhotoQualityPrioritization = .quality
                    RuntimeLog.info("[Session]", "outputAdded type=photo")
                }
                if let configuredCaptureDevice {
                    self.configurePreferredPhotoDimensions(
                        for: configuredCaptureDevice,
                        reason: "initialSetup"
                    )
                }

                self.session.commitConfiguration()
                RuntimeLog.info("[Session]", "commitConfiguration reason=initialSetup")
                RuntimeLog.info(
                    "[Startup]",
                    "sessionConfigurationElapsed=\(Self.formatDuration(Self.now() - sessionConfigurationStartedAt))"
                )

                self.isSessionConfigured = true
                self.applyCameraOrientation(reason: "sessionConfigured")
                let startRunningStartedAt = Self.now()
                self.session.startRunning()
                let startRunningEndedAt = Self.now()
                self.startupStartRunningEndedAt = startRunningEndedAt
                RuntimeLog.info(
                    "[Startup]",
                    "startRunningElapsed=\(Self.formatDuration(startRunningEndedAt - startRunningStartedAt))"
                )

                RuntimeLog.info(
                    "[Startup]",
                    "sessionConfigured elapsed=\(Self.formatDuration(Self.now() - self.launchStartedAt)) preset=\(self.session.sessionPreset.rawValue)"
                )
                cont.resume()
            }
        }
    }

    // MARK: - Orientation

    private func applyCameraOrientationAsync(reason: String) {
        sessionQueue.async {
            self.applyCameraOrientation(reason: reason)
        }
    }

    private func applyCameraOrientation(reason: String) {
        let orientation = sessionOrientation
        let previewAngle = orientation.previewRotationAngle
        let videoOutputAngle = orientation.videoOutputRotationAngle
        let photoAngle = orientation.photoRotationAngle

        let isRedundantApply = lastAppliedOrientationState == orientation
            && lastAppliedVideoOutputAngle == videoOutputAngle
            && lastAppliedPhotoAngle == photoAngle
            && (reason == "previewLayoutChanged" || reason == "filmProfileChanged")
        if isRedundantApply {
            return
        }

        if let previewConnection = previewOutput.connection(with: .video),
           previewConnection.isVideoRotationAngleSupported(videoOutputAngle) {
            previewConnection.videoRotationAngle = videoOutputAngle
        }

        if let photoConnection = photoOutput.connection(with: .video),
           photoConnection.isVideoRotationAngleSupported(photoAngle) {
            photoConnection.videoRotationAngle = photoAngle
        }

        lastAppliedOrientationState = orientation
        lastAppliedVideoOutputAngle = videoOutputAngle
        lastAppliedPhotoAngle = photoAngle

        RuntimeLog.info(
            "[Orientation]",
            "reason=\(reason) state=\(orientation.rawValue) angle=\(Int(videoOutputAngle)) preview=\(Int(previewAngle)) videoOutput=\(Int(videoOutputAngle)) photo=\(Int(photoAngle)) profile=\(activeFilmProfile.logName) focal=\(sessionSelectedFocalLength)"
        )

        if reason == "deviceOrientationChanged" {
            finishOrientationTransitionIfNeeded(
                appliedOrientation: orientation,
                angle: Int(videoOutputAngle)
            )
        }
    }

    // MARK: - VG preheating

    private func preheatVGResourcesIfNeeded() {
        guard !didStartVGPreheat else { return }
        didStartVGPreheat = true
        vgPreheatStartedAt = Self.now()

        RuntimeLog.info("[FilmProfile]", "vgPreheatStarted vgPreheatStartedAfterFirstFrame=true")
        profilePreheatQueue.async {
            FilmProfileProcessor.preheatResources(for: .vg)
            let elapsed = Self.now() - (self.vgPreheatStartedAt ?? Self.now())

            DispatchQueue.main.async {
                self.isVGReady = true
                RuntimeLog.info(
                    "[FilmProfile]",
                    "vgPreheatCompleted elapsed=\(Self.formatDuration(elapsed))"
                )

                if self.pendingFilmProfile == .vg {
                    self.pendingFilmProfile = nil
                    self.activeFilmProfile = .vg
                    let switchElapsed = self.profileRequestStartedAt[.vg].map { Self.now() - $0 } ?? 0
                    RuntimeLog.info(
                        "[FilmProfile]",
                        "requested=vg active=vg source=preheatCompletion elapsed=\(Self.formatDuration(switchElapsed))"
                    )
                    self.applyCameraOrientationAsync(reason: "filmProfileChanged")
                }
            }
        }
    }

    private func preheatEWResourcesIfNeeded() {
        guard !didStartEWPreheat else { return }
        didStartEWPreheat = true
        ewPreheatStartedAt = Self.now()

        RuntimeLog.info("[FilmProfile]", "ewPreheatStarted ewPreheatStartedAfterFirstFrame=true")
        profilePreheatQueue.async {
            FilmProfileProcessor.preheatResources(for: .ew)
            let elapsed = Self.now() - (self.ewPreheatStartedAt ?? Self.now())

            DispatchQueue.main.async {
                self.isEWReady = true
                RuntimeLog.info(
                    "[FilmProfile]",
                    "ewPreheatCompleted elapsed=\(Self.formatDuration(elapsed))"
                )

                if self.pendingFilmProfile == .ew {
                    self.pendingFilmProfile = nil
                    self.activeFilmProfile = .ew
                    let switchElapsed = self.profileRequestStartedAt[.ew].map { Self.now() - $0 } ?? 0
                    RuntimeLog.info(
                        "[FilmProfile]",
                        "requested=ew active=ew source=preheatCompletion elapsed=\(Self.formatDuration(switchElapsed))"
                    )
                    self.applyCameraOrientationAsync(reason: "filmProfileChanged")
                }
            }
        }
    }

    private func preheatLGResourcesIfNeeded() {
        guard !didStartLGPreheat else { return }
        didStartLGPreheat = true
        lgPreheatStartedAt = Self.now()

        RuntimeLog.info("[FilmProfile]", "lgPreheatStarted lgPreheatStartedAfterFirstFrame=true")
        profilePreheatQueue.async {
            FilmProfileProcessor.preheatResources(for: .lg)
            let elapsed = Self.now() - (self.lgPreheatStartedAt ?? Self.now())

            DispatchQueue.main.async {
                self.isLGReady = true
                RuntimeLog.info(
                    "[FilmProfile]",
                    "lgPreheatCompleted elapsed=\(Self.formatDuration(elapsed))"
                )

                if self.pendingFilmProfile == .lg {
                    self.pendingFilmProfile = nil
                    self.activeFilmProfile = .lg
                    let switchElapsed = self.profileRequestStartedAt[.lg].map { Self.now() - $0 } ?? 0
                    RuntimeLog.info(
                        "[FilmProfile]",
                        "requested=lg active=lg source=preheatCompletion elapsed=\(Self.formatDuration(switchElapsed))"
                    )
                    self.applyCameraOrientationAsync(reason: "filmProfileChanged")
                }
            }
        }
    }

    // MARK: - Photo processing

    fileprivate func handleCapturedPhoto(
        _ photo: AVCapturePhoto,
        format: AspectFormat,
        filmProfile: FilmProfile,
        outputKind: CaptureOutputKind,
        cropFactor: CGFloat,
        digitalZoomFactor: CGFloat,
        focalLength: Int,
        captureStartedAt: TimeInterval
    ) async {
        let processingStartedAt = Self.now()
        RuntimeLog.info(
            "[PhotoProcessing]",
            "start profile=\(filmProfile.logName) focal=\(focalLength) format=\(format.label) output=\(outputKind.logName)"
        )

        if outputKind == .dng {
            let extractionStartedAt = Self.now()
            guard let dngData = photo.fileDataRepresentation() else {
                await MainActor.run { captureError = "Failed to extract DNG data" }
                RuntimeLog.error("[Error]", "dngExtractionFailed")
                return
            }
            RuntimeLog.info(
                "[PhotoProcessing]",
                "dngExtractionElapsed=\(Self.formatDuration(Self.now() - extractionStartedAt)) bytes=\(dngData.count)"
            )

            do {
                RuntimeLog.info("[Capture]", "saveStarted output=dng")
                try await savePhotoDataToLibrary(dngData)
                await MainActor.run {
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                }
                RuntimeLog.info(
                    "[PhotoProcessing]",
                    "completed output=dng bytes=\(dngData.count) elapsed=\(Self.formatDuration(Self.now() - processingStartedAt))"
                )
                RuntimeLog.info(
                    "[Capture]",
                    "saveCompleted totalElapsed=\(Self.formatDuration(Self.now() - captureStartedAt))"
                )
            } catch {
                await MainActor.run { captureError = error.localizedDescription }
                RuntimeLog.error("[Error]", "dngSaveFailed error=\(error.localizedDescription)")
            }
            return
        }

        let extractionStartedAt = Self.now()
        guard let cgImage = photo.cgImageRepresentation() else {
            await MainActor.run { captureError = "Failed to extract image data" }
            RuntimeLog.error("[Error]", "photoExtractionFailed")
            return
        }
        let sourceDimensions = "\(cgImage.width)x\(cgImage.height)"
        RuntimeLog.info(
            "[PhotoProcessing]",
            "extractStage elapsed=\(Self.formatDuration(Self.now() - extractionStartedAt)) source=\(sourceDimensions)"
        )

        let cropStartedAt = Self.now()
        guard let cropped = CropManager.crop(image: cgImage, format: format, cropFactor: cropFactor) else {
            await MainActor.run { captureError = "Crop failed" }
            RuntimeLog.error("[Error]", "photoCropFailed format=\(format.label)")
            return
        }
        let cropDimensions = "\(cropped.width)x\(cropped.height)"
        RuntimeLog.info(
            "[PhotoProcessing]",
            "cropStage elapsed=\(Self.formatDuration(Self.now() - cropStartedAt)) crop=\(cropDimensions)"
        )
        let qualityMetrics = Self.photoQualityMetrics(from: photo)
        let isoValue = qualityMetrics.iso
        RuntimeLog.info(
            "[QualityAudit]",
            "profile=\(filmProfile.logName) focal=\(focalLength) format=\(format.label) iso=\(Self.format(isoValue)) exposure=\(Self.formatExposure(qualityMetrics.exposureSeconds)) fNumber=\(Self.formatOptional(qualityMetrics.fNumber)) brightness=\(Self.formatOptional(qualityMetrics.brightnessValue)) wb=\(Self.whiteBalanceLogName(qualityMetrics.whiteBalance)) source=\(sourceDimensions) crop=\(cropDimensions)"
        )

        let prepareStartedAt = Self.now()
        let baseImage = correctDistortionIfNeeded(
            CIImage(cgImage: cropped),
            photo: photo,
            focalLength: focalLength
        )
        RuntimeLog.info(
            "[PhotoProcessing]",
            "prepareStage elapsed=\(Self.formatDuration(Self.now() - prepareStartedAt))"
        )
        let profileStartedAt = Self.now()
        let profiledImage = FilmProfileProcessor.apply(
            profile: filmProfile,
            to: baseImage,
            focalLength: focalLength
        )
        let normalizedProfiledImage = Self.normalizedImageExtent(profiledImage)
        RuntimeLog.info(
            "[QualityAudit]",
            "profileStage=\(filmProfile.logName) elapsed=\(Self.formatDuration(Self.now() - profileStartedAt)) input=\(cropDimensions)"
        )

        let resizeStartedAt = Self.now()
        let inputWidth = CGFloat(normalizedProfiledImage.extent.width)
        let inputHeight = CGFloat(normalizedProfiledImage.extent.height)
        let inputMP = inputWidth * inputHeight

        let requestedScaleFactor: CGFloat
        if inputMP < Self.outputTargetPixels * (1 - Self.outputResizeTolerance)
            || inputMP > Self.outputTargetPixels * (1 + Self.outputResizeTolerance) {
            requestedScaleFactor = sqrt(Self.outputTargetPixels / max(inputMP, 1))
        } else {
            requestedScaleFactor = 1.0
        }
        let requestedOutputWidth = Int((inputWidth * requestedScaleFactor).rounded())
        let requestedOutputHeight = Int((inputHeight * requestedScaleFactor).rounded())

        let resampledImage: CIImage
        let resizeDisposition: String
        if requestedScaleFactor > 1 + Self.outputResizeTolerance {
            resampledImage = Self.highQualityResampledImage(
                normalizedProfiledImage,
                scale: requestedScaleFactor
            )
            resizeDisposition = "upscaled"
            RuntimeLog.info(
                "[PhotoProcessing]",
                "outputResize applied reason=upscale source=\(Int(inputWidth))x\(Int(inputHeight)) target=\(requestedOutputWidth)x\(requestedOutputHeight) scale=\(Self.format(requestedScaleFactor)) targetMP=\(Self.format(Self.outputTargetPixels / 1_000_000.0))"
            )
        } else if requestedScaleFactor < 1 - Self.outputResizeTolerance {
            resampledImage = Self.highQualityResampledImage(
                normalizedProfiledImage,
                scale: requestedScaleFactor
            )
            resizeDisposition = "downscaled"
            RuntimeLog.info(
                "[PhotoProcessing]",
                "outputResize applied reason=downscale source=\(Int(inputWidth))x\(Int(inputHeight)) target=\(requestedOutputWidth)x\(requestedOutputHeight) scale=\(Self.format(requestedScaleFactor)) targetMP=\(Self.format(Self.outputTargetPixels / 1_000_000.0))"
            )
        } else {
            resizeDisposition = "native"
            resampledImage = normalizedProfiledImage
        }
        RuntimeLog.info(
            "[PhotoProcessing]",
            "resizeStage elapsed=\(Self.formatDuration(Self.now() - resizeStartedAt)) disposition=\(resizeDisposition) target=\(requestedOutputWidth)x\(requestedOutputHeight) targetMP=\(Self.format(Self.outputTargetPixels / 1_000_000.0))"
        )

        let detailPlan = Self.detailProcessingPlan(
            profile: filmProfile,
            focalLength: focalLength,
            digitalZoomFactor: digitalZoomFactor,
            iso: isoValue,
            resampleScale: requestedScaleFactor
        )
        RuntimeLog.info(
            "[DetailPipeline]",
            "profile=\(filmProfile.logName) focal=\(focalLength) zoom=\(Self.format(digitalZoomFactor)) resizeScale=\(Self.format(requestedScaleFactor)) iso=\(Self.format(isoValue)) order=denoiseThenSharpen sharpen=\(Self.format(CGFloat(detailPlan.sharpenIntensity))) radius=\(Self.format(CGFloat(detailPlan.sharpenRadius))) denoise=\(detailPlan.shouldDenoise ? Self.format(CGFloat(detailPlan.noiseLevel)) : "off") reason=\(detailPlan.reason)"
        )

        let detailStartedAt = Self.now()
        let denoisedImage: CIImage
        if detailPlan.shouldDenoise, let noiseFilter = CIFilter(name: "CINoiseReduction") {
            noiseFilter.setValue(resampledImage.clampedToExtent(), forKey: kCIInputImageKey)
            noiseFilter.setValue(detailPlan.noiseLevel, forKey: "inputNoiseLevel")
            noiseFilter.setValue(0.0, forKey: "inputSharpness")
            denoisedImage = (noiseFilter.outputImage ?? resampledImage)
                .cropped(to: resampledImage.extent)
        } else {
            denoisedImage = resampledImage
        }

        let finalImage: CIImage
        if let unsharpMask = CIFilter(name: "CIUnsharpMask") {
            unsharpMask.setValue(denoisedImage.clampedToExtent(), forKey: kCIInputImageKey)
            unsharpMask.setValue(detailPlan.sharpenRadius, forKey: "inputRadius")
            unsharpMask.setValue(detailPlan.sharpenIntensity, forKey: "inputIntensity")
            finalImage = (unsharpMask.outputImage ?? denoisedImage)
                .cropped(to: denoisedImage.extent)
        } else if let sharpenFilter = CIFilter(name: "CISharpenLuminance") {
            sharpenFilter.setValue(denoisedImage.clampedToExtent(), forKey: kCIInputImageKey)
            sharpenFilter.setValue(detailPlan.sharpenIntensity, forKey: kCIInputSharpnessKey)
            finalImage = (sharpenFilter.outputImage ?? denoisedImage)
                .cropped(to: denoisedImage.extent)
        } else {
            finalImage = denoisedImage
        }
        RuntimeLog.info(
            "[PhotoProcessing]",
            "detailStage elapsed=\(Self.formatDuration(Self.now() - detailStartedAt)) denoise=\(detailPlan.shouldDenoise)"
        )

        let renderImage = finalImage.transformed(
            by: CGAffineTransform(
                translationX: -finalImage.extent.origin.x,
                y: -finalImage.extent.origin.y
            )
        )
        let renderExtent = CGRect(origin: .zero, size: finalImage.extent.size)
        let renderStartedAt = Self.now()
        guard let outputCGImage = photoCIContext.createCGImage(
            renderImage,
            from: renderExtent,
            format: .RGBA8,
            colorSpace: Self.outputColorSpace
        ) else {
            await MainActor.run { captureError = "Failed to render final image" }
            RuntimeLog.error("[Error]", "finalImageRenderFailed")
            return
        }
        let outputDimensions = "\(outputCGImage.width)x\(outputCGImage.height)"
        RuntimeLog.info(
            "[PhotoProcessing]",
            "renderStage elapsed=\(Self.formatDuration(Self.now() - renderStartedAt)) output=\(outputDimensions)"
        )
        RuntimeLog.info(
            "[PhotoProcessing]",
            "profile=\(filmProfile.logName) format=\(format.label) output=\(outputKind.logName) source=\(sourceDimensions) crop=\(cropDimensions) outputDimensions=\(outputDimensions) resize=\(resizeDisposition)"
        )

        let properties = buildEXIF(from: photo, focalLength: focalLength, filmProfile: filmProfile)

        do {
            RuntimeLog.info("[Capture]", "saveStarted")
            try await saveToLibrary(
                cgImage: outputCGImage,
                exif: properties,
                outputKind: outputKind
            )
            await MainActor.run {
                UINotificationFeedbackGenerator().notificationOccurred(.success)
            }
            RuntimeLog.info(
                "[PhotoProcessing]",
                "completed elapsed=\(Self.formatDuration(Self.now() - processingStartedAt))"
            )
            RuntimeLog.info(
                "[Capture]",
                "saveCompleted totalElapsed=\(Self.formatDuration(Self.now() - captureStartedAt))"
            )
        } catch {
            await MainActor.run { captureError = error.localizedDescription }
            RuntimeLog.error("[Error]", "photoSaveFailed error=\(error.localizedDescription)")
        }
    }

    // MARK: - Metadata / saving

    private func buildEXIF(
        from photo: AVCapturePhoto,
        focalLength: Int,
        filmProfile: FilmProfile
    ) -> [String: Any] {
        var fullProps = photo.metadata as [String: Any]
        var exif = (fullProps[kCGImagePropertyExifDictionary as String] as? [String: Any]) ?? [:]

        exif[kCGImagePropertyExifFocalLenIn35mmFilm as String] = focalLength
        exif[kCGImagePropertyExifLensMake as String] = "only_snap"
        exif[kCGImagePropertyExifUserComment as String] =
            "only_snap | \(focalLength)mm | \(filmProfile.logName)"

        fullProps[kCGImagePropertyExifDictionary as String] = exif
        return fullProps
    }

    private func correctDistortionIfNeeded(
        _ image: CIImage,
        photo: AVCapturePhoto,
        focalLength: Int
    ) -> CIImage {
        guard focalLength == 15,
              let calibrationData = photo.cameraCalibrationData,
              let filter = CIFilter(name: "CICameraCalibrationLensCorrection"),
              filter.inputKeys.contains(kCIInputImageKey) else {
            return image
        }

        filter.setValue(image, forKey: kCIInputImageKey)
        if filter.inputKeys.contains("inputAVCameraCalibrationData") {
            filter.setValue(calibrationData, forKey: "inputAVCameraCalibrationData")
        }

        guard let corrected = filter.outputImage else { return image }
        RuntimeLog.info("[PhotoProcessing]", "lensCorrectionApplied focal=15")
        return corrected
    }

    private func saveToLibrary(
        cgImage: CGImage,
        exif: [String: Any],
        outputKind: CaptureOutputKind
    ) async throws {
        let encodeStartedAt = Self.now()
        guard let imageUTI = outputKind.imageUTI else {
            throw CameraError.saveFailed
        }

        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            imageUTI as CFString,
            1,
            nil
        ) else {
            throw outputKind == .heif ? CameraError.heifUnsupported : CameraError.saveFailed
        }

        var destinationProperties = exif
        destinationProperties[kCGImageDestinationLossyCompressionQuality as String] =
            outputKind == .heif ? Self.outputHEIFQuality : Self.outputJPEGQuality
        CGImageDestinationAddImage(destination, cgImage, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CameraError.saveFailed
        }

        let finalData = data as Data
        let encodeElapsed = Self.now() - encodeStartedAt
        let libraryStartedAt = Self.now()
        try await savePhotoDataToLibrary(finalData)
        let libraryElapsed = Self.now() - libraryStartedAt
        RuntimeLog.info(
            "[PhotoProcessing]",
            "encoded output=\(outputKind.logName) bytes=\(finalData.count) quality=\(Self.format(outputKind == .heif ? Self.outputHEIFQuality : Self.outputJPEGQuality)) encodeElapsed=\(Self.formatDuration(encodeElapsed)) libraryElapsed=\(Self.formatDuration(libraryElapsed))"
        )
    }

    private func savePhotoDataToLibrary(_ finalData: Data) async throws {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<Void, Error>) in
            PHPhotoLibrary.shared().performChanges {
                let request = PHAssetCreationRequest.forAsset()
                request.addResource(with: .photo, data: finalData, options: nil)
            } completionHandler: { ok, error in
                if ok {
                    cont.resume()
                } else {
                    cont.resume(throwing: error ?? CameraError.saveFailed)
                }
            }
        }
    }

    private enum CameraError: LocalizedError {
        case saveFailed
        case dngUnsupported
        case heifUnsupported

        var errorDescription: String? {
            switch self {
            case .saveFailed:
                return "Could not save photo to library"
            case .dngUnsupported:
                return "DNG capture is not supported on this device"
            case .heifUnsupported:
                return "HEIF encoding is not available on this device"
            }
        }
    }

    // MARK: - Device selection

    private struct FocalSelection {
        let device: AVCaptureDevice
        let zoomFactor: CGFloat
        let deviceLabel: String
        let isFallback: Bool
        let fallbackReason: String?
    }

    private struct ZoomCalibration {
        let zoomFactor: CGFloat
        let baseEquivalentFocalLength: CGFloat
        let actualEquivalentFocalLength: CGFloat
        let errorRatio: CGFloat
        let wasClamped: Bool
    }

    private func deviceSelection(for mm: Int) -> FocalSelection? {
        deviceSelection(for: mm, source: "deviceSelection")
    }

    private func deviceSelection(
        for mm: Int,
        source: String
    ) -> FocalSelection? {
        let capabilities = refreshedCameraCapabilities(source: source)
        guard let selection = rawDeviceSelection(for: mm, capabilities: capabilities) else { return nil }
        return validatedRearSelection(selection, requested: mm, source: source)
    }

    private func refreshedCameraCapabilities(source: String) -> CameraCapabilities {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        )
        let devices = discovery.devices

        let ultraWide = devices.first { $0.deviceType == .builtInUltraWideCamera }
        let wide = devices.first { $0.deviceType == .builtInWideAngleCamera }
        let tele = devices.first { $0.deviceType == .builtInTelephotoCamera }

        let capabilities = CameraCapabilities(
            hasUltraWide: ultraWide != nil,
            hasWide: wide != nil,
            hasTelephoto: tele != nil,
            telephoto35mmEquivalent: tele.map { equivalentFocalLength(for: $0) },
            wide35mmEquivalent: wide.map { equivalentFocalLength(for: $0) } ?? 24,
            ultraWide35mmEquivalent: ultraWide.map { equivalentFocalLength(for: $0) },
            virtualSwitchFactors: wide?.virtualDeviceSwitchOverVideoZoomFactors.map {
                CGFloat(truncating: $0)
            } ?? []
        )

        cameraCapabilities = capabilities
        publishSupportedFocalsIfNeeded(capabilities.supportedFocalLengths)
        RuntimeLog.info(
            "[Device]",
            "capabilities source=\(source) uw=\(capabilities.hasUltraWide) wide=\(capabilities.hasWide) tele=\(capabilities.hasTelephoto) uwEq=\(Self.formatOptional(capabilities.ultraWide35mmEquivalent)) wideEq=\(Self.format(capabilities.wide35mmEquivalent)) teleEq=\(Self.formatOptional(capabilities.telephoto35mmEquivalent)) virtual=\(capabilities.virtualSwitchFactors.map(Self.format).joined(separator: ",")) focals=\(capabilities.supportedFocalLengths.map(String.init).joined(separator: ","))"
        )
        return capabilities
    }

    private func publishSupportedFocalsIfNeeded(_ focals: [Int]) {
        let normalized = focals.isEmpty ? [15, 28, 43, 85] : focals
        DispatchQueue.main.async {
            if self.availableFocalLengths != normalized {
                self.availableFocalLengths = normalized
            }

            if !normalized.contains(self.selectedFocalLength),
               let fallback = normalized.first {
                self.selectedFocalLength = fallback
                self.sessionSelectedFocalLength = fallback
            }
        }
    }

    private func rawDeviceSelection(
        for mm: Int,
        capabilities: CameraCapabilities
    ) -> FocalSelection? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInUltraWideCamera, .builtInWideAngleCamera, .builtInTelephotoCamera],
            mediaType: .video,
            position: .back
        )
        let devices = discovery.devices

        func find(_ type: AVCaptureDevice.DeviceType) -> AVCaptureDevice? {
            devices.first { $0.deviceType == type }
        }

        func label(for device: AVCaptureDevice) -> String {
            switch device.deviceType {
            case .builtInUltraWideCamera: return "ultraWide"
            case .builtInWideAngleCamera: return "wide"
            case .builtInTelephotoCamera: return "tele"
            default: return "unknown"
            }
        }

        guard let wide = find(.builtInWideAngleCamera) else { return nil }

        func clampedZoom(
            targetMM: Int,
            baseEquivalent: CGFloat,
            device: AVCaptureDevice
        ) -> CGFloat {
            let desired = Self.zoomFactor(
                targetFocalLength: CGFloat(targetMM),
                baseEquivalentFocalLength: baseEquivalent
            )
            return min(
                max(desired, device.minAvailableVideoZoomFactor),
                device.maxAvailableVideoZoomFactor
            )
        }

        func virtualZoom(targetMM: Int, baseEquivalent: CGFloat) -> CGFloat? {
            let targetZoom = Self.zoomFactor(
                targetFocalLength: CGFloat(targetMM),
                baseEquivalentFocalLength: baseEquivalent
            )
            return capabilities.virtualSwitchFactors.first {
                abs($0 - targetZoom) / max(targetZoom, 0.001) < 0.015
            }
        }

        func wideSelection(targetMM: Int, fallbackReason: String?) -> FocalSelection {
            let baseEquivalent = capabilities.wide35mmEquivalent
            if let zoom = virtualZoom(targetMM: targetMM, baseEquivalent: baseEquivalent) {
                return FocalSelection(
                    device: wide,
                    zoomFactor: zoom,
                    deviceLabel: "wideVirtual",
                    isFallback: false,
                    fallbackReason: nil
                )
            }

            return FocalSelection(
                device: wide,
                zoomFactor: clampedZoom(targetMM: targetMM, baseEquivalent: baseEquivalent, device: wide),
                deviceLabel: label(for: wide),
                isFallback: fallbackReason != nil,
                fallbackReason: fallbackReason
            )
        }

        func teleBaseEquivalent() -> CGFloat {
            guard let teleEquivalent = capabilities.telephoto35mmEquivalent else {
                return Self.nominalTeleShortEquivalent
            }
            return teleEquivalent
        }

        switch mm {
        case 15:
            if let ultraWide = find(.builtInUltraWideCamera) {
                let zoom = clampedZoom(
                    targetMM: mm,
                    baseEquivalent: capabilities.ultraWide35mmEquivalent ?? Self.nominalUltraWideEquivalent,
                    device: ultraWide
                )
                return FocalSelection(
                    device: ultraWide,
                    zoomFactor: zoom,
                    deviceLabel: label(for: ultraWide),
                    isFallback: false,
                    fallbackReason: nil
                )
            }
            return FocalSelection(
                device: wide,
                zoomFactor: 1.0,
                deviceLabel: label(for: wide),
                isFallback: true,
                fallbackReason: "ultraWideUnavailable"
            )

        case 28:
            return wideSelection(targetMM: mm, fallbackReason: nil)

        case 43:
            return wideSelection(targetMM: mm, fallbackReason: nil)

        case 77:
            if let tele = find(.builtInTelephotoCamera),
               teleBaseEquivalent() < 100 {
                return FocalSelection(
                    device: tele,
                    zoomFactor: clampedZoom(targetMM: mm, baseEquivalent: teleBaseEquivalent(), device: tele),
                    deviceLabel: label(for: tele),
                    isFallback: false,
                    fallbackReason: nil
                )
            }
            return wideSelection(targetMM: mm, fallbackReason: "77mmWideCrop")

        case 85:
            if let tele = find(.builtInTelephotoCamera),
               teleBaseEquivalent() < 100 {
                return FocalSelection(
                    device: tele,
                    zoomFactor: clampedZoom(targetMM: mm, baseEquivalent: teleBaseEquivalent(), device: tele),
                    deviceLabel: label(for: tele),
                    isFallback: false,
                    fallbackReason: nil
                )
            }
            return wideSelection(targetMM: mm, fallbackReason: "85mmWideCrop")

        case 120:
            if let tele = find(.builtInTelephotoCamera) {
                return FocalSelection(
                    device: tele,
                    zoomFactor: clampedZoom(targetMM: mm, baseEquivalent: teleBaseEquivalent(), device: tele),
                    deviceLabel: label(for: tele),
                    isFallback: false,
                    fallbackReason: nil
                )
            }
            return nil

        default:
            return nil
        }
    }

    // MARK: - Helpers

    private func logInitialOrientationStateIfNeeded() {
        guard !didLogInitialOrientationState else { return }
        didLogInitialOrientationState = true
        RuntimeLog.info("[Orientation]", "initialState=\(cameraOrientation.rawValue)")
    }

    @discardableResult
    private func beginPreviewTransition(
        reason: String,
        state: CameraOrientationState? = nil
    ) -> Int {
        assert(Thread.isMainThread)
        previewGeneration += 1
        isPreviewTransitioning = true
        previewTransitionReason = reason
        RuntimeLog.info(
            "[PreviewState]",
            "generation=\(previewGeneration) reason=\(reason) state=\((state ?? cameraOrientation).rawValue)"
        )
        return previewGeneration
    }

    private func completePreviewTransition(
        reason: String,
        state: CameraOrientationState? = nil,
        angle: Int? = nil
    ) {
        let apply = { [self] in
            self.isPreviewTransitioning = false
            self.previewTransitionReason = reason
            var message = "generation=\(self.previewGeneration) reason=\(reason) state=\((state ?? self.cameraOrientation).rawValue)"
            if let angle {
                message += " angle=\(angle)"
            }
            RuntimeLog.info("[PreviewState]", message)
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPreviewTransitioning = false
                self.previewTransitionReason = reason
                var message = "generation=\(self.previewGeneration) reason=\(reason) state=\((state ?? self.cameraOrientation).rawValue)"
                if let angle {
                    message += " angle=\(angle)"
                }
                RuntimeLog.info("[PreviewState]", message)
            }
        }
    }

    private func cancelPreviewTransition(reason: String) {
        let apply = { [self] in
            self.isPreviewTransitioning = false
            self.previewTransitionReason = reason
            RuntimeLog.info(
                "[PreviewState]",
                "generation=\(self.previewGeneration) reason=\(reason) state=\(self.cameraOrientation.rawValue)"
            )
        }

        if Thread.isMainThread {
            apply()
        } else {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.isPreviewTransitioning = false
                self.previewTransitionReason = reason
                RuntimeLog.info(
                    "[PreviewState]",
                    "generation=\(self.previewGeneration) reason=\(reason) state=\(self.cameraOrientation.rawValue)"
                )
            }
        }
    }

    private func bumpPreviewGeneration(reason: String) {
        assert(Thread.isMainThread)
        previewGeneration += 1
        isPreviewTransitioning = false
        previewTransitionReason = reason
        RuntimeLog.info(
            "[PreviewState]",
            "generation=\(previewGeneration) reason=\(reason) state=\(cameraOrientation.rawValue)"
        )
    }

    private func finishOrientationTransitionIfNeeded(
        appliedOrientation: CameraOrientationState,
        angle: Int
    ) {
        guard let pendingOrientationTransition,
              pendingOrientationTransition.to == appliedOrientation else {
            return
        }

        let duration = Self.now() - pendingOrientationTransition.startedAt
        self.pendingOrientationTransition = nil

        DispatchQueue.main.async {
            self.cameraOrientation = appliedOrientation
            self.completePreviewTransition(
                reason: "orientationApplied",
                state: appliedOrientation,
                angle: angle
            )
            RuntimeLog.info(
                "[Performance]",
                "orientationSwitch duration=\(Self.formatDuration(duration)) generation=\(pendingOrientationTransition.generation) state=\(appliedOrientation.rawValue)"
            )
        }
    }

    private func validatedRearSelection(
        _ selection: FocalSelection,
        requested mm: Int,
        source: String
    ) -> FocalSelection {
        guard selection.device.position == .front else { return selection }

        RuntimeLog.error(
            "[Error]",
            "frontCameraSelectedUnexpectedly source=\(source) requested=\(mm) replacingWith=backWide"
        )

        return rearWideSelection(for: mm, fallbackReason: "frontCameraRejected") ?? selection
    }

    private func ensureRearCameraInputIfNeeded(source: String) {
        guard let currentInput = session.inputs.compactMap({ $0 as? AVCaptureDeviceInput }).first,
              currentInput.device.position == .front else {
            return
        }

        RuntimeLog.error(
            "[Error]",
            "frontCameraSelectedUnexpectedly source=\(source) replacingWith=backWide"
        )

        guard let selection = rearWideSelection(
            for: sessionSelectedFocalLength,
            fallbackReason: "frontCameraRejected"
        ) else {
            RuntimeLog.error("[Error]", "rearCameraRecoveryFailed source=\(source)")
            return
        }

        do {
            RuntimeLog.info("[Session]", "beginConfiguration reason=\(source)")
            session.beginConfiguration()
            session.removeInput(currentInput)
            RuntimeLog.info("[Session]", "inputRemoved reason=\(source)")

            let input = try AVCaptureDeviceInput(device: selection.device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                RuntimeLog.error("[Error]", "rearCameraRecoveryAddInputFailed source=\(source)")
                return
            }

            session.addInput(input)
            RuntimeLog.info("[Session]", "inputAdded device=\(selection.deviceLabel)")

            try selection.device.lockForConfiguration()
            let calibration: ZoomCalibration
            do {
                defer { selection.device.unlockForConfiguration() }
                calibration = applyPreferredFormatAndZoomLocked(
                    for: selection.device,
                    targetFocalLength: sessionSelectedFocalLength,
                    reason: source
                )
            }
            digitalZoomFactor = calibration.zoomFactor

            configurePreferredPhotoDimensions(for: selection.device, reason: source)
            session.commitConfiguration()
            RuntimeLog.info("[Session]", "commitConfiguration reason=\(source)")

            DispatchQueue.main.async {
                self.currentDevice = selection.device
            }
        } catch {
            session.commitConfiguration()
            RuntimeLog.error(
                "[Error]",
                "rearCameraRecoveryFailed source=\(source) error=\(error.localizedDescription)"
            )
        }
    }

    private func rearWideSelection(
        for mm: Int,
        fallbackReason: String
    ) -> FocalSelection? {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.builtInWideAngleCamera],
            mediaType: .video,
            position: .back
        )

        guard let wide = discovery.devices.first else { return nil }

        let wideEquivalent = equivalentFocalLength(for: wide)
        let desiredZoom: CGFloat

        switch mm {
        case 15, 28, 43, 77, 85, 120:
            desiredZoom = Self.zoomFactor(
                targetFocalLength: CGFloat(mm),
                baseEquivalentFocalLength: wideEquivalent
            )
        default:
            desiredZoom = Self.zoomFactor(
                targetFocalLength: Self.nominalWideEquivalent,
                baseEquivalentFocalLength: wideEquivalent
            )
        }

        let zoom = min(max(desiredZoom, wide.minAvailableVideoZoomFactor), wide.maxAvailableVideoZoomFactor)
        return FocalSelection(
            device: wide,
            zoomFactor: zoom,
            deviceLabel: "wide",
            isFallback: true,
            fallbackReason: fallbackReason
        )
    }

    private func equivalentFocalLength(for camera: AVCaptureDevice) -> CGFloat {
        let radians = CGFloat(camera.activeFormat.videoFieldOfView) * .pi / 180.0
        let tangent = tan(radians / 2.0)
        guard tangent > 0 else { return 24.0 }

        // videoFieldOfView is the horizontal FOV. For a 35mm-equivalent
        // horizontal frame width of 36mm, equivalent focal length is:
        // f = (36 / 2) / tan(horizontalFOV / 2).
        return (Self.fullFrame35mmWidth * 0.5) / tangent
    }

    private static func zoomFactor(
        targetFocalLength: CGFloat,
        baseEquivalentFocalLength: CGFloat
    ) -> CGFloat {
        max(targetFocalLength / max(baseEquivalentFocalLength, 0.001), 1.0)
    }

    @discardableResult
    private func applyPreferredFormatAndZoomLocked(
        for device: AVCaptureDevice,
        targetFocalLength mm: Int,
        reason: String
    ) -> ZoomCalibration {
        if #available(iOS 16.0, *) {
            configurePreferredPhotoFormatIfAvailableLocked(
                for: device,
                reason: reason
            )
        }

        let calibration = calibratedZoom(
            for: device,
            targetFocalLength: mm
        )
        device.videoZoomFactor = calibration.zoomFactor
        applyMeteringModeLocked(to: device, mode: meteringState.mode)
        let effectiveAELock = applyExposureLockLocked(
            to: device,
            locked: meteringState.aeLocked
        )
        if effectiveAELock != meteringState.aeLocked {
            meteringState.aeLocked = effectiveAELock
            DispatchQueue.main.async {
                self.isAELocked = effectiveAELock
            }
        }
        logFocalCalibration(
            calibration,
            device: device,
            reason: reason
        )
        return calibration
    }

    @discardableResult
    private func applyExposureLockLocked(
        to device: AVCaptureDevice,
        locked: Bool
    ) -> Bool {
        if locked, device.isExposureModeSupported(.locked) {
            device.exposureMode = .locked
            return true
        }

        if device.isExposureModeSupported(.continuousAutoExposure) {
            device.exposureMode = .continuousAutoExposure
        } else if device.isExposureModeSupported(.autoExpose) {
            device.exposureMode = .autoExpose
        }
        return false
    }

    private func applyMeteringModeLocked(
        to device: AVCaptureDevice,
        mode: MeteringMode
    ) {
        let point: CGPoint?
        switch mode {
        case .matrix:
            point = nil
        case .average:
            point = nil
        case .highlight:
            point = nil
        case .centerWeighted:
            point = CGPoint(x: 0.5, y: 0.5)
        }

        if let point, device.isExposurePointOfInterestSupported {
            device.exposurePointOfInterest = point
        }

        if !meteringState.aeLocked {
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            } else if device.isExposureModeSupported(.autoExpose) {
                device.exposureMode = .autoExpose
            }
        }

        RuntimeLog.info(
            "[Exposure]",
            "meteringApplied mode=\(mode.logName) point=\(point.map { "\(Self.format($0.x)),\(Self.format($0.y))" } ?? "auto") aeLocked=\(meteringState.aeLocked)"
        )
    }

    nonisolated private func updateAdaptiveMeteringBiasIfNeeded(
        buckets: [Int],
        zones: MeteringZoneSummary,
        now: TimeInterval
    ) {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            let mode = self.meteringState.mode
            let profile = self.activeFilmProfile
            guard !self.meteringState.aeLocked else { return }
            guard now >= self.meteringState.adaptivePausedUntil else { return }
            guard now - self.meteringState.lastUpdateTime >= self.meteringTuning.adaptiveInterval else { return }
            guard self.pendingFocalTransition == nil,
                  self.pendingOrientationTransition == nil else {
                return
            }

            self.meteringState.lastUpdateTime = now
            let decision = self.computeDesiredMeteringBias(
                buckets: buckets,
                zones: zones,
                mode: mode,
                profile: profile
            )
            let smoothedBias = self.smoothMeteringBiasLocked(
                desired: decision.desiredBias,
                now: now,
                response: self.exposureResponse(
                    profile: profile,
                    environment: decision.environment
                )
            )
            guard abs(smoothedBias - self.meteringState.bias) > self.meteringTuning.biasDeadband else {
                return
            }
            guard let device = self.currentDevice else { return }

            do {
                try device.lockForConfiguration()
                defer { device.unlockForConfiguration() }
                guard !self.meteringState.aeLocked,
                      self.meteringState.mode == mode,
                      self.activeFilmProfile == profile,
                      self.pendingFocalTransition == nil,
                      self.pendingOrientationTransition == nil else {
                    return
                }
                self.applyExposureBiasLocked(smoothedBias, to: device, force: false)
                RuntimeLog.info(
                    "[Exposure]",
                    "policy profile=\(profile.logName) env=\(decision.environment.kind.rawValue) desired=\(Self.format(CGFloat(decision.desiredBias))) applied=\(Self.format(CGFloat(smoothedBias)))"
                )
            } catch {
                RuntimeLog.error("[Error]", "adaptiveMeteringBiasFailed error=\(error.localizedDescription)")
            }
        }
    }

    private func computeDesiredMeteringBias(
        buckets: [Int],
        zones: MeteringZoneSummary,
        mode: MeteringMode,
        profile: FilmProfile
    ) -> MeteringBiasDecision {
        let globalStats = globalMeteringStats(from: buckets)
        let stats = weightedZoneStats(zones: zones, mode: mode)
        let environment = exposureEnvironment(
            globalStats: globalStats,
            stats: stats,
            zones: zones
        )
        let baseBias = baseMeteringBias(
            globalStats: globalStats,
            stats: stats,
            zones: zones,
            mode: mode
        )
        let profileBias = applyFilmProfileExposurePolicy(
            baseBias: baseBias,
            profile: profile,
            environment: environment,
            globalStats: globalStats,
            stats: stats,
            zones: zones,
            mode: mode
        )

        return MeteringBiasDecision(
            desiredBias: profileBias,
            environment: environment
        )
    }

    private func baseMeteringBias(
        globalStats: MeteringWeightedStats,
        stats: MeteringWeightedStats,
        zones: MeteringZoneSummary,
        mode: MeteringMode
    ) -> Float {
        switch mode {
        case .average:
            let base = (0.46 - zones.globalMean) * 1.05
            let highlightProtection = max(0, zones.globalHighlightShare - 0.22) * 0.42
            return Float(base - highlightProtection).clamped(to: -0.60...0.60)

        case .matrix:
            let base = (0.48 - stats.mean) * 0.92
            let highlightProtection = max(0, stats.highlightShare - 0.13) * 0.82
                + max(0, stats.hardHighlightShare - 0.035) * 1.15
            let shadowRecovery = max(0, stats.shadowShare - 0.28) * 0.26
            return Float(base - highlightProtection + shadowRecovery).clamped(to: -0.85...0.70)

        case .centerWeighted:
            let base = (0.50 - stats.mean) * 1.20
            let highlightProtection = max(0, stats.highlightShare - 0.18) * 0.52
                + max(0, stats.hardHighlightShare - 0.05) * 0.92
            let shadowRecovery = max(0, stats.shadowShare - 0.30) * 0.22
            return Float(base - highlightProtection + shadowRecovery).clamped(to: -0.85...0.80)

        case .highlight:
            let brightMeanControl = max(0, stats.mean - 0.45) * 0.72
            let highlightProtection = max(0, stats.highlightShare - 0.04) * 1.55
                + max(0, stats.hardHighlightShare - 0.01) * 2.25
            let globalProtection = max(0, globalStats.hardHighlightShare - 0.015) * 0.85
            let shadowRecovery = max(0, zones.globalShadowShare - 0.58) * 0.07
            return Float(
                -brightMeanControl
                - highlightProtection
                - globalProtection
                + shadowRecovery
            ).clamped(to: -1.35...0.05)
        }
    }

    private func exposureEnvironment(
        globalStats: MeteringWeightedStats,
        stats: MeteringWeightedStats,
        zones: MeteringZoneSummary
    ) -> ExposureEnvironment {
        let mean = stats.mean
        let globalMean = zones.globalMean
        let shadowShare = max(stats.shadowShare, globalStats.shadowShare)
        let highlightShare = max(stats.highlightShare, globalStats.highlightShare)
        let hardHighlightShare = max(stats.hardHighlightShare, globalStats.hardHighlightShare)

        if hardHighlightShare > 0.035 || highlightShare > 0.34 {
            return ExposureEnvironment(
                kind: .hardHighlight,
                intensity: max(
                    ((hardHighlightShare - 0.018) / 0.10).clamped(to: 0...1),
                    ((highlightShare - 0.24) / 0.36).clamped(to: 0...1)
                )
            )
        }

        if shadowShare > 0.40 && highlightShare > 0.14 {
            return ExposureEnvironment(
                kind: .highContrast,
                intensity: min(1, shadowShare * 0.80 + highlightShare * 1.20)
            )
        }

        if globalMean > mean + 0.10 && shadowShare > 0.28 {
            return ExposureEnvironment(
                kind: .backlit,
                intensity: min(1, (globalMean - mean) * 4.0 + shadowShare * 0.42)
            )
        }

        if globalMean < 0.30 || shadowShare > 0.56 {
            return ExposureEnvironment(
                kind: .lowLight,
                intensity: max(
                    ((0.34 - globalMean) / 0.22).clamped(to: 0...1),
                    ((shadowShare - 0.42) / 0.38).clamped(to: 0...1)
                )
            )
        }

        if globalMean > 0.62 && shadowShare < 0.12 {
            return ExposureEnvironment(
                kind: .highKey,
                intensity: ((globalMean - 0.58) / 0.24).clamped(to: 0...1)
            )
        }

        if highlightShare < 0.09,
           shadowShare < 0.22,
           abs(globalMean - 0.50) < 0.18 {
            return ExposureEnvironment(
                kind: .overcast,
                intensity: (1.0 - abs(globalMean - 0.50) / 0.18).clamped(to: 0...1)
            )
        }

        return ExposureEnvironment(kind: .balanced, intensity: 0)
    }

    private func applyFilmProfileExposurePolicy(
        baseBias: Float,
        profile: FilmProfile,
        environment: ExposureEnvironment,
        globalStats: MeteringWeightedStats,
        stats: MeteringWeightedStats,
        zones: MeteringZoneSummary,
        mode: MeteringMode
    ) -> Float {
        var bias = baseBias
        let intensity = Float(environment.intensity)
        let highlightExcess = Float(max(0, max(stats.highlightShare, globalStats.highlightShare) - 0.16))
        let hardHighlightExcess = Float(max(0, max(stats.hardHighlightShare, globalStats.hardHighlightShare) - 0.018))
        let shadowExcess = Float(max(0, max(stats.shadowShare, zones.globalShadowShare) - 0.42))

        switch profile {
        case .raw:
            return Self.clamp(baseBias, to: -1.35...0.80)

        case .vg:
            bias -= highlightExcess * 0.18
            bias -= hardHighlightExcess * 0.36
            if environment.kind == .highContrast || environment.kind == .backlit {
                bias -= 0.07 * intensity
            } else if environment.kind == .lowLight {
                bias += min(0.08, shadowExcess * 0.20)
            } else if environment.kind == .overcast {
                bias += 0.035 * intensity
            }
            return Self.clamp(bias, to: mode == .highlight ? -1.35...0.05 : -1.05...0.48)

        case .ew:
            if environment.kind == .overcast {
                bias += 0.10 * intensity
            } else if environment.kind == .highKey {
                bias += 0.045 * intensity
            } else if environment.kind == .lowLight {
                bias += 0.06 * intensity
            }
            bias -= highlightExcess * 0.09
            bias -= hardHighlightExcess * 0.32
            return Self.clamp(bias, to: mode == .highlight ? -1.35...0.08 : -1.05...0.72)

        case .lg:
            bias -= highlightExcess * 0.16
            bias -= hardHighlightExcess * 0.34
            if environment.kind == .highContrast || environment.kind == .backlit {
                bias -= 0.08 * intensity
            } else if environment.kind == .lowLight {
                bias += 0.035 * intensity
            } else if environment.kind == .overcast {
                bias += 0.04 * intensity
            }
            return Self.clamp(bias, to: mode == .highlight ? -1.35...0.05 : -1.05...0.38)
        }
    }

    private func globalMeteringStats(from buckets: [Int]) -> MeteringWeightedStats {
        let total = max(1, buckets.reduce(0, +))
        let bucketCount = max(1, buckets.count)
        var weightedSum: CGFloat = 0
        var shadowCount = 0
        var highlightCount = 0
        var hardHighlightCount = 0

        for (index, count) in buckets.enumerated() {
            let center = (CGFloat(index) + 0.5) / CGFloat(bucketCount)
            weightedSum += center * CGFloat(count)
            if center < meteringTuning.shadowThreshold { shadowCount += count }
            if center > meteringTuning.highlightThreshold { highlightCount += count }
            if center > meteringTuning.hardHighlightThreshold { hardHighlightCount += count }
        }

        return MeteringWeightedStats(
            mean: weightedSum / CGFloat(total),
            shadowShare: CGFloat(shadowCount) / CGFloat(total),
            highlightShare: CGFloat(highlightCount) / CGFloat(total),
            hardHighlightShare: CGFloat(hardHighlightCount) / CGFloat(total)
        )
    }

    private func weightedZoneStats(
        zones: MeteringZoneSummary,
        mode: MeteringMode
    ) -> MeteringWeightedStats {
        guard !zones.means.isEmpty else {
            return MeteringWeightedStats(
                mean: zones.globalMean,
                shadowShare: zones.globalShadowShare,
                highlightShare: zones.globalHighlightShare,
                hardHighlightShare: zones.globalHardHighlightShare
            )
        }

        let centerColumn = CGFloat(zones.columns - 1) / 2
        let centerRow = CGFloat(zones.rows - 1) / 2
        let maxDistance = max(0.001, sqrt(centerColumn * centerColumn + centerRow * centerRow))
        var weightedMean: CGFloat = 0
        var weightedShadowShare: CGFloat = 0
        var weightedHighlightShare: CGFloat = 0
        var weightedHardHighlightShare: CGFloat = 0
        var totalWeight: CGFloat = 0

        for index in zones.means.indices {
            let row = index / zones.columns
            let column = index % zones.columns
            let dx = CGFloat(column) - centerColumn
            let dy = CGFloat(row) - centerRow
            let normalizedDistance = min(1, sqrt(dx * dx + dy * dy) / maxDistance)
            let countScale = CGFloat(max(1, zones.counts[index]))
            let weight: CGFloat

            switch mode {
            case .average:
                weight = 1
            case .matrix:
                let centerWeight = pow(1 - normalizedDistance, 1.35)
                let highlightAttention = zones.highlightShares[index] * 0.35
                    + zones.hardHighlightShares[index] * 0.75
                weight = 0.26 + 0.74 * centerWeight + highlightAttention
            case .centerWeighted:
                let centerWeight = pow(1 - normalizedDistance, 2.6)
                weight = 0.12 + 1.28 * centerWeight
            case .highlight:
                let brightLift = max(0, zones.means[index] - 0.68) * 1.20
                weight = 0.10
                    + brightLift
                    + zones.highlightShares[index] * 2.10
                    + zones.hardHighlightShares[index] * 3.20
            }

            let sampleWeight = weight * countScale
            weightedMean += zones.means[index] * sampleWeight
            weightedShadowShare += zones.shadowShares[index] * sampleWeight
            weightedHighlightShare += zones.highlightShares[index] * sampleWeight
            weightedHardHighlightShare += zones.hardHighlightShares[index] * sampleWeight
            totalWeight += sampleWeight
        }

        let divisor = max(0.001, totalWeight)
        return MeteringWeightedStats(
            mean: weightedMean / divisor,
            shadowShare: weightedShadowShare / divisor,
            highlightShare: weightedHighlightShare / divisor,
            hardHighlightShare: weightedHardHighlightShare / divisor
        )
    }

    private func smoothMeteringBiasLocked(
        desired: Float,
        now: TimeInterval,
        response: ExposureResponse
    ) -> Float {
        let previousTime = meteringState.lastSmoothingTime
        let dt = previousTime > 0
            ? max(0.001, now - previousTime)
            : meteringTuning.adaptiveInterval
        meteringState.lastSmoothingTime = now

        let desiredDelta = abs(desired - meteringState.lastDesiredBias)
        meteringState.lastDesiredBias = desired

        var alpha = min(Float(dt) / response.smoothingTau, response.maxAlpha)
        if desiredDelta > response.fastResponseThreshold {
            alpha = response.fastAlpha
        }

        let previousBias = meteringState.smoothedBias
        let candidate = alpha * desired + (1 - alpha) * previousBias
        let delta = candidate - previousBias
        let limitedDelta: Float
        if delta >= 0 {
            limitedDelta = min(delta, response.positiveStep)
        } else {
            limitedDelta = max(delta, -response.negativeStep)
        }

        meteringState.smoothedBias = previousBias + limitedDelta
        return meteringState.smoothedBias
    }

    private func exposureResponse(
        profile: FilmProfile,
        environment: ExposureEnvironment
    ) -> ExposureResponse {
        var tau = meteringTuning.smoothingTau
        var maxAlpha: Float = 0.30
        var fastThreshold = meteringTuning.fastResponseThreshold
        var fastAlpha: Float = 0.54
        var positiveStep: Float = 0.16
        var negativeStep: Float = 0.22

        switch profile {
        case .raw:
            tau = 1.05
            fastAlpha = 0.58
            positiveStep = 0.18
            negativeStep = 0.24
        case .vg:
            tau = 1.28
            maxAlpha = 0.28
            fastThreshold = 0.28
            fastAlpha = 0.56
            positiveStep = 0.13
            negativeStep = 0.25
        case .ew:
            tau = 1.00
            maxAlpha = 0.34
            fastThreshold = 0.32
            fastAlpha = 0.60
            positiveStep = 0.18
            negativeStep = 0.20
        case .lg:
            tau = 1.36
            maxAlpha = 0.26
            fastThreshold = 0.25
            fastAlpha = 0.52
            positiveStep = 0.11
            negativeStep = 0.24
        }

        switch environment.kind {
        case .hardHighlight:
            negativeStep += 0.08
            positiveStep *= 0.78
            fastThreshold *= 0.82
        case .highContrast, .backlit:
            tau *= 1.10
            positiveStep *= 0.82
            negativeStep += 0.04
        case .lowLight:
            tau *= 1.16
            positiveStep *= 0.72
            negativeStep *= 0.82
            maxAlpha = min(maxAlpha, 0.24)
        case .overcast, .highKey:
            tau *= 0.94
        case .balanced:
            break
        }

        return ExposureResponse(
            smoothingTau: tau,
            maxAlpha: maxAlpha,
            fastResponseThreshold: fastThreshold,
            fastAlpha: fastAlpha,
            positiveStep: positiveStep,
            negativeStep: negativeStep
        )
    }

    private static func clamp(_ value: Float, to range: ClosedRange<Float>) -> Float {
        min(max(value, range.lowerBound), range.upperBound)
    }

    private func resetMeteringBiasLocked(to device: AVCaptureDevice) {
        meteringState.smoothedBias = 0
        meteringState.lastDesiredBias = 0
        meteringState.lastSmoothingTime = Self.now()
        meteringState.adaptivePausedUntil = Self.now() + 0.20
        applyExposureBiasLocked(0, to: device, force: true)
    }

    private func scheduleBiasRampToZero(duration: TimeInterval = 0.40) {
        let now = Self.now()
        let startBias = meteringState.bias
        meteringState.adaptivePausedUntil = now + duration + 0.25
        guard abs(startBias) > 0.03 else {
            meteringState.smoothedBias = 0
            meteringState.lastDesiredBias = 0
            return
        }

        let steps = 5
        for step in 1...steps {
            let delay = duration * Double(step) / Double(steps)
            sessionQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self,
                      !self.meteringState.aeLocked,
                      let device = self.currentDevice else {
                    return
                }

                let progress = Float(step) / Float(steps)
                let bias = startBias + (0 - startBias) * progress
                do {
                    try device.lockForConfiguration()
                    defer { device.unlockForConfiguration() }
                    self.applyExposureBiasLocked(bias, to: device, force: true)
                    if step == steps {
                        self.meteringState.smoothedBias = 0
                        self.meteringState.lastDesiredBias = 0
                        self.meteringState.lastSmoothingTime = Self.now()
                    }
                } catch {
                    RuntimeLog.error("[Error]", "aeUnlockBiasRampFailed error=\(error.localizedDescription)")
                }
            }
        }
    }

    private func applyExposureBiasLocked(
        _ bias: Float,
        to device: AVCaptureDevice,
        force: Bool
    ) {
        let clampedBias = bias.clamped(
            to: device.minExposureTargetBias...device.maxExposureTargetBias
        )
        guard force || abs(clampedBias - meteringState.bias) > meteringTuning.applyDeadband else { return }
        device.setExposureTargetBias(clampedBias)
        meteringState.bias = clampedBias
        if force {
            meteringState.smoothedBias = clampedBias
            meteringState.lastDesiredBias = clampedBias
        }
        RuntimeLog.info("[Exposure]", "targetBias=\(Self.format(CGFloat(clampedBias)))")
    }

    private func calibratedZoom(
        for device: AVCaptureDevice,
        targetFocalLength mm: Int
    ) -> ZoomCalibration {
        let baseEquivalent = max(nominalEquivalentFocalLength(for: device), 0.001)
        let requested = max(CGFloat(mm), 1.0)
        let desiredZoom = Self.zoomFactor(
            targetFocalLength: requested,
            baseEquivalentFocalLength: baseEquivalent
        )
        let zoom = min(
            max(desiredZoom, device.minAvailableVideoZoomFactor),
            device.maxAvailableVideoZoomFactor
        )
        let actualEquivalent = baseEquivalent * zoom
        let errorRatio = abs(actualEquivalent - requested) / requested

        return ZoomCalibration(
            zoomFactor: zoom,
            baseEquivalentFocalLength: baseEquivalent,
            actualEquivalentFocalLength: actualEquivalent,
            errorRatio: errorRatio,
            wasClamped: abs(zoom - desiredZoom) > 0.001
        )
    }

    private func nominalEquivalentFocalLength(for device: AVCaptureDevice) -> CGFloat {
        switch device.deviceType {
        case .builtInUltraWideCamera:
            return (cameraCapabilities.ultraWide35mmEquivalent ?? equivalentFocalLength(for: device))
                .clamped(to: 10...22)
        case .builtInWideAngleCamera:
            return cameraCapabilities.wide35mmEquivalent
                .clamped(to: 20...32)
        case .builtInTelephotoCamera:
            let measured = cameraCapabilities.telephoto35mmEquivalent ?? equivalentFocalLength(for: device)
            return measured.clamped(to: 60...135)
        default:
            return Self.nominalWideEquivalent
        }
    }

    private func logFocalCalibration(
        _ calibration: ZoomCalibration,
        device: AVCaptureDevice,
        reason: String
    ) {
        let message = "reason=\(reason) device=\(deviceLogName(for: device)) fov=\(Self.format(CGFloat(device.activeFormat.videoFieldOfView))) base=\(Self.format(calibration.baseEquivalentFocalLength)) actual=\(Self.format(calibration.actualEquivalentFocalLength)) zoom=\(Self.format(calibration.zoomFactor)) error=\(Self.format(calibration.errorRatio * 100))% clamped=\(calibration.wasClamped)"

        if calibration.errorRatio > 0.05 {
            RuntimeLog.error("[FocalCalibration]", "targetMismatch \(message)")
        } else {
            RuntimeLog.info("[FocalCalibration]", message)
        }
    }

    private func deviceLogName(for device: AVCaptureDevice) -> String {
        let position = positionLogName(for: device)
        let suffix: String

        switch device.deviceType {
        case .builtInUltraWideCamera:
            suffix = "UltraWide"
        case .builtInWideAngleCamera:
            suffix = "Wide"
        case .builtInTelephotoCamera:
            suffix = "Tele"
        default:
            suffix = "Unknown"
        }

        return position + suffix
    }

    private func positionLogName(for device: AVCaptureDevice) -> String {
        switch device.position {
        case .back: return "back"
        case .front: return "front"
        case .unspecified: return "unspecified"
        @unknown default: return "unknown"
        }
    }

    @available(iOS 16.0, *)
    private func configurePreferredPhotoFormatIfAvailableLocked(
        for device: AVCaptureDevice,
        reason: String
    ) {
        let currentDimensions = Self.preferredPhotoDimensions(for: device.activeFormat)
        let currentPixels = currentDimensions.map(Self.photoDimensionPixels) ?? 0

        guard let candidate = Self.preferredPhotoFormat(for: device),
              let candidateDimensions = Self.preferredPhotoDimensions(for: candidate) else {
            RuntimeLog.info(
                "[PhotoOutput]",
                "activeFormatHighResUnavailable reason=\(reason) device=\(deviceLogName(for: device))"
            )
            return
        }

        let candidatePixels = Self.photoDimensionPixels(candidateDimensions)
        guard candidatePixels > currentPixels else {
            RuntimeLog.info(
                "[PhotoOutput]",
                "activeFormatKept reason=\(reason) device=\(deviceLogName(for: device)) selected=\(Self.photoDimensionsLogName(candidateDimensions)) mp=\(Self.format(CGFloat(candidatePixels) / 1_000_000.0))"
            )
            return
        }
        
        let previous = currentDimensions.map(Self.photoDimensionsLogName) ?? "unknown"
        device.activeFormat = candidate
        RuntimeLog.info(
            "[PhotoOutput]",
            "activeFormatChanged reason=\(reason) device=\(deviceLogName(for: device)) previous=\(previous) selected=\(Self.photoDimensionsLogName(candidateDimensions)) mp=\(Self.format(CGFloat(candidatePixels) / 1_000_000.0))"
        )
    }

    private func configurePreferredPhotoDimensions(
        for device: AVCaptureDevice,
        reason: String
    ) {
        guard #available(iOS 16.0, *) else { return }
        guard let dimensions = Self.preferredPhotoDimensions(for: device) else {
            RuntimeLog.info(
                "[PhotoOutput]",
                "maxPhotoDimensions unavailable reason=\(reason) device=\(deviceLogName(for: device))"
            )
            return
        }

        photoOutput.maxPhotoDimensions = dimensions
        sessionMaxPhotoDimensions = dimensions
        let megapixels = CGFloat(Self.photoDimensionPixels(dimensions)) / 1_000_000.0
        RuntimeLog.info(
            "[PhotoOutput]",
            "maxPhotoDimensions reason=\(reason) device=\(deviceLogName(for: device)) selected=\(Self.photoDimensionsLogName(dimensions)) mp=\(Self.format(megapixels))"
        )
    }

    @available(iOS 16.0, *)
    private static func preferredPhotoDimensions(for device: AVCaptureDevice) -> CMVideoDimensions? {
        preferredPhotoDimensions(for: device.activeFormat)
    }

    @available(iOS 16.0, *)
    private static func preferredPhotoDimensions(for format: AVCaptureDevice.Format) -> CMVideoDimensions? {
        let supported = format.supportedMaxPhotoDimensions
        guard !supported.isEmpty else { return nil }

        let sorted = supported.sorted {
            photoDimensionPixels($0) < photoDimensionPixels($1)
        }
        let nativeExperimentLimit = Int64(50_000_000)
        let preferredMinimum = Int64(12_000_000)

        if let highRes = sorted.last(where: {
            let pixels = photoDimensionPixels($0)
            return pixels >= preferredMinimum && pixels <= nativeExperimentLimit
        }) {
            return highRes
        }

        return sorted.last
    }

    @available(iOS 16.0, *)
    private static func preferredPhotoFormat(for device: AVCaptureDevice) -> AVCaptureDevice.Format? {
        let nativeExperimentLimit = Int64(50_000_000)
        let preferredMinimum = Int64(12_000_000)

        return device.formats.compactMap { format -> (format: AVCaptureDevice.Format, dimensions: CMVideoDimensions, pixels: Int64)? in
            guard let dimensions = preferredPhotoDimensions(for: format) else { return nil }
            let pixels = photoDimensionPixels(dimensions)
            guard pixels >= preferredMinimum && pixels <= nativeExperimentLimit else { return nil }
            return (format, dimensions, pixels)
        }
        .max { lhs, rhs in
            if lhs.pixels != rhs.pixels {
                return lhs.pixels < rhs.pixels
            }
            return lhs.format.videoFieldOfView < rhs.format.videoFieldOfView
        }?
        .format
    }

    nonisolated private static func photoDimensionPixels(_ dimensions: CMVideoDimensions) -> Int64 {
        Int64(dimensions.width) * Int64(dimensions.height)
    }

    nonisolated private static func normalizedImageExtent(_ image: CIImage) -> CIImage {
        let extent = image.extent
        guard extent.origin != .zero else { return image }

        return image.transformed(
            by: CGAffineTransform(
                translationX: -extent.origin.x,
                y: -extent.origin.y
            )
        )
    }

    nonisolated private static func scaledExtent(for extent: CGRect, scale: CGFloat) -> CGRect {
        CGRect(
            x: (extent.origin.x * scale).rounded(.down),
            y: (extent.origin.y * scale).rounded(.down),
            width: max(1, (extent.width * scale).rounded()),
            height: max(1, (extent.height * scale).rounded())
        )
    }

    nonisolated private static func highQualityResampledImage(
        _ image: CIImage,
        scale: CGFloat
    ) -> CIImage {
        guard abs(scale - 1.0) > 0.001 else { return image }

        // Large upscales look cleaner when split into two Lanczos passes.
        // 12MP -> 36MP stays one pass; narrow crops can benefit from two.
        if scale > 2.05 {
            let firstScale = sqrt(scale)
            let firstPass = lanczosResampledImage(image, scale: firstScale)
            return lanczosResampledImage(firstPass, scale: scale / firstScale)
        }

        return lanczosResampledImage(image, scale: scale)
    }

    nonisolated private static func lanczosResampledImage(
        _ image: CIImage,
        scale: CGFloat
    ) -> CIImage {
        guard let scaleFilter = CIFilter(name: "CILanczosScaleTransform") else {
            return image
        }

        let normalized = normalizedImageExtent(image)
        let outputExtent = scaledExtent(for: normalized.extent, scale: scale)
        scaleFilter.setValue(normalized, forKey: kCIInputImageKey)
        scaleFilter.setValue(scale, forKey: kCIInputScaleKey)
        scaleFilter.setValue(1.0, forKey: "inputAspectRatio")
        return (scaleFilter.outputImage ?? normalized)
            .cropped(to: outputExtent)
    }

    nonisolated private static func photoDimensionsLogName(_ dimensions: CMVideoDimensions) -> String {
        "\(dimensions.width)x\(dimensions.height)"
    }

    private static func photoQualityMetrics(from photo: AVCapturePhoto) -> PhotoQualityMetrics {
        let exif = photo.metadata[kCGImagePropertyExifDictionary as String] as? [String: Any]
        let isoRatings = exif?[kCGImagePropertyExifISOSpeedRatings as String] as? [NSNumber]
        let iso = CGFloat(isoRatings?.first?.doubleValue ?? 100.0)

        return PhotoQualityMetrics(
            iso: iso,
            exposureSeconds: doubleValue(exif?[kCGImagePropertyExifExposureTime as String]),
            fNumber: doubleValue(exif?[kCGImagePropertyExifFNumber as String]),
            brightnessValue: doubleValue(exif?[kCGImagePropertyExifBrightnessValue as String]),
            whiteBalance: intValue(exif?[kCGImagePropertyExifWhiteBalance as String])
        )
    }

    private static func detailProcessingPlan(
        profile: FilmProfile,
        focalLength: Int,
        digitalZoomFactor: CGFloat,
        iso: CGFloat,
        resampleScale: CGFloat
    ) -> DetailProcessingPlan {
        let focalBase: Float
        switch focalLength {
        case 15:  focalBase = 0.10
        case 28:  focalBase = 0.12
        case 43:  focalBase = 0.15
        case 77:  focalBase = 0.17
        case 85:  focalBase = 0.17
        case 120: focalBase = 0.19
        default:  focalBase = 0.14
        }

        let isLongFocal = focalLength >= 77
        let profileMultiplier: Float
        let baseRadius: Float
        switch profile {
        case .raw:
            profileMultiplier = 1.00
            baseRadius = isLongFocal ? 0.96 : 1.26
        case .vg:
            profileMultiplier = isLongFocal ? 0.50 : 0.62
            baseRadius = isLongFocal ? 0.54 : 0.82
        case .ew:
            profileMultiplier = isLongFocal ? 0.30 : 0.30
            baseRadius = isLongFocal ? 0.48 : 0.52
        case .lg:
            profileMultiplier = isLongFocal ? 0.50 : 0.62
            baseRadius = isLongFocal ? 0.54 : 0.82
        }

        let zoomDenoiseBoost: Float
        let radiusScale: Float
        let sharpenScale: Float
        if digitalZoomFactor > 2.0 {
            zoomDenoiseBoost = 0.020
            radiusScale = 0.70
            sharpenScale = 0.82
        } else if digitalZoomFactor > 1.5 {
            zoomDenoiseBoost = 0.010
            radiusScale = 0.85
            sharpenScale = 0.90
        } else {
            zoomDenoiseBoost = 0
            radiusScale = 1.0
            sharpenScale = 1.0
        }

        let isoAttenuation = Float(max(0.35, 1.0 - max(0.0, Double(iso) - 160.0) / 1000.0))
        let upscaleSharpnessCompensation = Float(
            min(1.16, 1.0 + max(0, resampleScale - 1.0) * 0.13)
        )
        let upscaleRadiusDamp = Float(
            max(0.86, 1.0 - max(0, resampleScale - 1.0) * 0.06)
        )
        let sharpenIntensity = focalBase
            * profileMultiplier
            * isoAttenuation
            * sharpenScale
            * upscaleSharpnessCompensation
        let radius = baseRadius * radiusScale * upscaleRadiusDamp

        let denoiseThreshold: CGFloat
        switch profile {
        case .raw: denoiseThreshold = 280
        case .vg: denoiseThreshold = 320
        case .ew: denoiseThreshold = 560
        case .lg: denoiseThreshold = 320
        }

        let upscaleDenoiseBoost: Float
        if resampleScale > 1.75, iso > 160 {
            upscaleDenoiseBoost = 0.003
        } else if resampleScale > 1.45, iso > 240 {
            upscaleDenoiseBoost = 0.002
        } else {
            upscaleDenoiseBoost = 0
        }

        let shouldDenoise = iso > denoiseThreshold
            || zoomDenoiseBoost > 0
            || upscaleDenoiseBoost > 0
        let noiseLevel: Float
        if shouldDenoise {
            let base: Float = {
                switch profile {
                case .ew: return 0.004
                case .vg: return 0.006
                case .lg: return 0.006
                case .raw: return 0.008
                }
            }()
            let extraLimit: Float
            let extraDivisor: Float
            switch profile {
            case .ew:
                extraLimit = 0.018
                extraDivisor = 36_000.0
            case .vg, .lg:
                extraLimit = 0.024
                extraDivisor = 34_000.0
            case .raw:
                extraLimit = 0.030
                extraDivisor = 28_000.0
            }
            let extra = min(extraLimit, max(0.0, Float(iso - denoiseThreshold) / extraDivisor))
            noiseLevel = base + extra + zoomDenoiseBoost + upscaleDenoiseBoost
        } else {
            noiseLevel = 0
        }

        let reason: String
        if iso > denoiseThreshold && zoomDenoiseBoost > 0 && upscaleDenoiseBoost > 0 {
            reason = "isoZoomAndUpscaleAdaptive"
        } else if iso > denoiseThreshold && upscaleDenoiseBoost > 0 {
            reason = "isoAndUpscaleAdaptive"
        } else if zoomDenoiseBoost > 0 && upscaleDenoiseBoost > 0 {
            reason = "zoomAndUpscaleAdaptive"
        } else if upscaleDenoiseBoost > 0 {
            reason = "upscaleAdaptive"
        } else if iso > denoiseThreshold && zoomDenoiseBoost > 0 {
            reason = "isoAndZoomAdaptive"
        } else if zoomDenoiseBoost > 0 {
            reason = "zoomAdaptive"
        } else if shouldDenoise {
            reason = "isoAdaptive"
        } else {
            reason = "lowISO"
        }

        return DetailProcessingPlan(
            sharpenIntensity: sharpenIntensity,
            sharpenRadius: radius,
            noiseLevel: noiseLevel,
            shouldDenoise: shouldDenoise,
            reason: reason
        )
    }

    nonisolated private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let string = value as? String { return Double(string) }
        return nil
    }

    nonisolated private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    nonisolated private static func formatOptional(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.3f", value)
    }

    nonisolated private static func formatOptional(_ value: CGFloat?) -> String {
        guard let value else { return "unknown" }
        return format(value)
    }

    nonisolated private static func formatExposure(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.5fs", value)
    }

    nonisolated private static func whiteBalanceLogName(_ value: Int?) -> String {
        switch value {
        case 0: return "auto"
        case 1: return "manual"
        case let value?: return "\(value)"
        case nil: return "unknown"
        }
    }

    nonisolated private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    nonisolated private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    nonisolated private static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", duration)
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let format: AspectFormat
    let filmProfile: FilmProfile
    let outputKind: CaptureOutputKind
    let cropFactor: CGFloat
    let digitalZoomFactor: CGFloat
    let focalLength: Int
    let captureStartedAt: TimeInterval

    nonisolated(unsafe) weak var cameraManager: CameraManager?
    nonisolated(unsafe) let completion: () -> Void

    init(
        format: AspectFormat,
        filmProfile: FilmProfile,
        outputKind: CaptureOutputKind,
        cropFactor: CGFloat,
        digitalZoomFactor: CGFloat,
        focalLength: Int,
        captureStartedAt: TimeInterval,
        cameraManager: CameraManager,
        completion: @escaping () -> Void
    ) {
        self.format = format
        self.filmProfile = filmProfile
        self.outputKind = outputKind
        self.cropFactor = cropFactor
        self.digitalZoomFactor = digitalZoomFactor
        self.focalLength = focalLength
        self.captureStartedAt = captureStartedAt
        self.cameraManager = cameraManager
        self.completion = completion
    }

    nonisolated func photoOutput(
        _ output: AVCapturePhotoOutput,
        didFinishProcessingPhoto photo: AVCapturePhoto,
        error: Error?
    ) {
        guard let cameraManager else {
            completion()
            return
        }

        if let error {
            Task { @MainActor in
                cameraManager.captureError = error.localizedDescription
            }
            RuntimeLog.error("[Error]", "captureProcessingFailed error=\(error.localizedDescription)")
            Task { @MainActor in self.completion() }
            return
        }

        cameraManager.imageProcessingQueue.async {
            Task {
                await cameraManager.handleCapturedPhoto(
                    photo,
                    format: self.format,
                    filmProfile: self.filmProfile,
                    outputKind: self.outputKind,
                    cropFactor: self.cropFactor,
                    digitalZoomFactor: self.digitalZoomFactor,
                    focalLength: self.focalLength,
                    captureStartedAt: self.captureStartedAt
                )
                await MainActor.run {
                    self.completion()
                }
            }
        }
    }
}
