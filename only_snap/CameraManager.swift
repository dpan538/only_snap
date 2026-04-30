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
    @Published private(set) var selectedFocalLength = 35
    @Published private(set) var selectedAspectFormat: AspectFormat = .threeToFour
    @Published private(set) var flashEnabled = false
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
    nonisolated(unsafe) private var sessionSelectedFocalLength = 35
    nonisolated(unsafe) private var sessionFlashEnabled = false
    nonisolated(unsafe) private var sessionOrientation = CameraOrientationState.portrait
    nonisolated(unsafe) private var lastAppliedOrientationState: CameraOrientationState?
    nonisolated(unsafe) private var lastAppliedVideoOutputAngle: CGFloat?
    nonisolated(unsafe) private var lastAppliedPhotoAngle: CGFloat?
    nonisolated(unsafe) private var captureCropFactor: CGFloat = 1.0
    nonisolated(unsafe) private var digitalZoomFactor: CGFloat = 1.0
    nonisolated(unsafe) private var sessionMaxPhotoDimensions: CMVideoDimensions?

    // MARK: - Observers / delegates

    private var inProgressDelegates: [Int64: PhotoCaptureDelegate] = [:]
    private var sessionRunningObserver: AnyCancellable?
    private var runtimeErrorObserver: AnyCancellable?
    private var interruptionObserver: AnyCancellable?
    private var interruptionEndedObserver: AnyCancellable?

    // MARK: - Permissions / timings

    private var cameraPermissionGranted = false
    private var photoPermissionGranted = false
    private var launchStartedAt = CameraManager.now()
    private var didReportFirstPreviewFrame = false
    private var didStartVGPreheat = false
    private var didStartEWPreheat = false
    private var vgPreheatStartedAt: TimeInterval?
    private var ewPreheatStartedAt: TimeInterval?
    private var profileRequestStartedAt: [FilmProfile: TimeInterval] = [:]
    private var didLogInitialOrientationState = false
    nonisolated(unsafe) private var pendingOrientationTransition: PendingOrientationTransition?
    nonisolated(unsafe) private var pendingFocalTransition: PendingFocalTransition?
    nonisolated(unsafe) private var startupStartRunningEndedAt: TimeInterval?
    private static let outputJPEGQuality: CGFloat = 0.95

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
        selectedAspectFormat = format
        bumpPreviewGeneration(reason: "aspectFormatChanged")
        RuntimeLog.info("[Preview]", "aspectFormat=\(format.label)")
    }

    func setFlashEnabled(_ enabled: Bool) {
        flashEnabled = enabled
        sessionFlashEnabled = enabled
        RuntimeLog.info("[Capture]", "flashEnabled=\(enabled)")
    }

    func requestFilmProfile(_ profile: FilmProfile) {
        switch profile {
        case .raw:
            guard activeFilmProfile != .raw || pendingFilmProfile != nil else { return }
        case .vg:
            guard activeFilmProfile != .vg, pendingFilmProfile != .vg else { return }
        case .ew:
            guard activeFilmProfile != .ew, pendingFilmProfile != .ew else { return }
        }

        profileRequestStartedAt[profile] = Self.now()

        switch profile {
        case .raw:
            pendingFilmProfile = nil
            activeFilmProfile = .raw
            RuntimeLog.info("[FilmProfile]", "requested=raw active=raw ready=true")
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
                RuntimeLog.info("[FilmProfile]", "requested=vg active=raw ready=false pending=true")
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

            let clampedZoom = min(
                max(selection.zoomFactor, selection.device.minAvailableVideoZoomFactor),
                selection.device.maxAvailableVideoZoomFactor
            )

            do {
                if selection.device.uniqueID == previousDeviceID {
                    try selection.device.lockForConfiguration()
                    if #available(iOS 16.0, *) {
                        self.configurePreferredPhotoFormatIfAvailableLocked(
                            for: selection.device,
                            reason: "focalChangedSameDevice"
                        )
                    }
                    selection.device.videoZoomFactor = clampedZoom
                    selection.device.unlockForConfiguration()
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
                    if #available(iOS 16.0, *) {
                        self.configurePreferredPhotoFormatIfAvailableLocked(
                            for: selection.device,
                            reason: "focalChanged"
                        )
                    }
                    selection.device.videoZoomFactor = clampedZoom
                    selection.device.unlockForConfiguration()

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
            self.digitalZoomFactor = clampedZoom
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
            RuntimeLog.info(
                "[Focal]",
                "requested=\(mm) resolvedDevice=\(self.deviceLogName(for: selection.device)) position=\(self.positionLogName(for: selection.device)) zoom=\(Self.format(clampedZoom)) fallback=\(selection.isFallback) reason=\(reason) elapsed=\(Self.formatDuration(Self.now() - requestStartedAt))"
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
        let deviceHasFlash = currentDevice?.hasFlash ?? false
        let captureStartedAt = Self.now()

        RuntimeLog.info(
            "[Capture]",
            "start profile=\(profile.logName) focal=\(focal) format=\(format.label) orientation=\(orientation.rawValue)"
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

                let settings = AVCapturePhotoSettings()
                settings.flashMode = (flashEnabled && deviceHasFlash) ? .on : .off
                settings.photoQualityPrioritization = .quality
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
                    cropFactor: cropFactor,
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
                        if #available(iOS 16.0, *) {
                            self.configurePreferredPhotoFormatIfAvailableLocked(
                                for: selection.device,
                                reason: "initialSetup"
                            )
                        }
                        selection.device.videoZoomFactor = selection.zoomFactor
                        selection.device.unlockForConfiguration()

                        self.captureCropFactor = 1.0
                        self.digitalZoomFactor = selection.zoomFactor
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

    // MARK: - Photo processing

    fileprivate func handleCapturedPhoto(
        _ photo: AVCapturePhoto,
        format: AspectFormat,
        filmProfile: FilmProfile,
        cropFactor: CGFloat,
        focalLength: Int,
        captureStartedAt: TimeInterval
    ) async {
        let processingStartedAt = Self.now()
        RuntimeLog.info(
            "[PhotoProcessing]",
            "start profile=\(filmProfile.logName) focal=\(focalLength) format=\(format.label)"
        )

        guard let cgImage = photo.cgImageRepresentation() else {
            await MainActor.run { captureError = "Failed to extract image data" }
            RuntimeLog.error("[Error]", "photoExtractionFailed")
            return
        }
        let sourceDimensions = "\(cgImage.width)x\(cgImage.height)"

        guard let cropped = CropManager.crop(image: cgImage, format: format, cropFactor: cropFactor) else {
            await MainActor.run { captureError = "Crop failed" }
            RuntimeLog.error("[Error]", "photoCropFailed format=\(format.label)")
            return
        }
        let cropDimensions = "\(cropped.width)x\(cropped.height)"
        let qualityMetrics = Self.photoQualityMetrics(from: photo)
        let isoValue = qualityMetrics.iso
        RuntimeLog.info(
            "[QualityAudit]",
            "profile=\(filmProfile.logName) focal=\(focalLength) format=\(format.label) iso=\(Self.format(isoValue)) exposure=\(Self.formatExposure(qualityMetrics.exposureSeconds)) fNumber=\(Self.formatOptional(qualityMetrics.fNumber)) brightness=\(Self.formatOptional(qualityMetrics.brightnessValue)) wb=\(Self.whiteBalanceLogName(qualityMetrics.whiteBalance)) source=\(sourceDimensions) crop=\(cropDimensions)"
        )

        let baseImage = CIImage(cgImage: cropped)
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

        let targetOutputMP: CGFloat = 36_000_000
        let inputWidth = CGFloat(normalizedProfiledImage.extent.width)
        let inputHeight = CGFloat(normalizedProfiledImage.extent.height)
        let inputMP = inputWidth * inputHeight

        let requestedScaleFactor: CGFloat
        if inputMP < targetOutputMP * 0.98 {
            requestedScaleFactor = min(2.0, sqrt(targetOutputMP / inputMP))
        } else if inputMP > targetOutputMP * 1.02 {
            requestedScaleFactor = max(0.5, sqrt(targetOutputMP / inputMP))
        } else {
            requestedScaleFactor = 1.0
        }
        let requestedOutputWidth = Int((inputWidth * requestedScaleFactor).rounded())
        let requestedOutputHeight = Int((inputHeight * requestedScaleFactor).rounded())

        let resampledImage: CIImage
        let resizeDisposition: String
        if requestedScaleFactor > 1.02 {
            if let scaleFilter = CIFilter(name: "CILanczosScaleTransform") {
                let outputExtent = Self.scaledExtent(
                    for: normalizedProfiledImage.extent,
                    scale: requestedScaleFactor
                )
                scaleFilter.setValue(normalizedProfiledImage, forKey: kCIInputImageKey)
                scaleFilter.setValue(requestedScaleFactor, forKey: kCIInputScaleKey)
                scaleFilter.setValue(1.0, forKey: "inputAspectRatio")
                resampledImage = (scaleFilter.outputImage ?? normalizedProfiledImage)
                    .cropped(to: outputExtent)
            } else {
                resampledImage = normalizedProfiledImage
            }
            resizeDisposition = "upscaled"
            RuntimeLog.info(
                "[PhotoProcessing]",
                "outputResize applied reason=upscale source=\(Int(inputWidth))x\(Int(inputHeight)) target=\(requestedOutputWidth)x\(requestedOutputHeight)"
            )
        } else if requestedScaleFactor < 0.98 {
            if let scaleFilter = CIFilter(name: "CILanczosScaleTransform") {
                let outputExtent = Self.scaledExtent(
                    for: normalizedProfiledImage.extent,
                    scale: requestedScaleFactor
                )
                scaleFilter.setValue(normalizedProfiledImage, forKey: kCIInputImageKey)
                scaleFilter.setValue(requestedScaleFactor, forKey: kCIInputScaleKey)
                scaleFilter.setValue(1.0, forKey: "inputAspectRatio")
                resampledImage = (scaleFilter.outputImage ?? normalizedProfiledImage)
                    .cropped(to: outputExtent)
            } else {
                resampledImage = normalizedProfiledImage
            }
            resizeDisposition = "downscaled"
            RuntimeLog.info(
                "[PhotoProcessing]",
                "outputResize applied reason=downscale source=\(Int(inputWidth))x\(Int(inputHeight)) target=\(requestedOutputWidth)x\(requestedOutputHeight)"
            )
        } else {
            resizeDisposition = "native"
            resampledImage = normalizedProfiledImage
        }

        let detailPlan = Self.detailProcessingPlan(
            profile: filmProfile,
            focalLength: focalLength,
            iso: isoValue
        )
        RuntimeLog.info(
            "[DetailPipeline]",
            "profile=\(filmProfile.logName) focal=\(focalLength) iso=\(Self.format(isoValue)) order=denoiseThenSharpen sharpen=\(Self.format(CGFloat(detailPlan.sharpenIntensity))) radius=\(Self.format(CGFloat(detailPlan.sharpenRadius))) denoise=\(detailPlan.shouldDenoise ? Self.format(CGFloat(detailPlan.noiseLevel)) : "off") reason=\(detailPlan.reason)"
        )

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

        let renderImage = finalImage.transformed(
            by: CGAffineTransform(
                translationX: -finalImage.extent.origin.x,
                y: -finalImage.extent.origin.y
            )
        )
        let renderExtent = CGRect(origin: .zero, size: finalImage.extent.size)
        guard let outputCGImage = photoCIContext.createCGImage(renderImage, from: renderExtent) else {
            await MainActor.run { captureError = "Failed to render final image" }
            RuntimeLog.error("[Error]", "finalImageRenderFailed")
            return
        }
        let outputDimensions = "\(outputCGImage.width)x\(outputCGImage.height)"
        RuntimeLog.info(
            "[PhotoProcessing]",
            "profile=\(filmProfile.logName) format=\(format.label) source=\(sourceDimensions) crop=\(cropDimensions) output=\(outputDimensions) resize=\(resizeDisposition) jpegQuality=\(Self.format(Self.outputJPEGQuality))"
        )
        RuntimeLog.info(
            "[PhotoProcessing]",
            "jpegQuality=\(Self.format(Self.outputJPEGQuality))"
        )

        let properties = buildEXIF(from: photo, focalLength: focalLength, filmProfile: filmProfile)

        do {
            RuntimeLog.info("[Capture]", "saveStarted")
            try await saveToLibrary(cgImage: outputCGImage, exif: properties)
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

    private func saveToLibrary(cgImage: CGImage, exif: [String: Any]) async throws {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data,
            "public.jpeg" as CFString,
            1,
            nil
        ) else {
            throw CameraError.saveFailed
        }

        var destinationProperties = exif
        destinationProperties[kCGImageDestinationLossyCompressionQuality as String] = Self.outputJPEGQuality
        CGImageDestinationAddImage(destination, cgImage, destinationProperties as CFDictionary)
        guard CGImageDestinationFinalize(destination) else {
            throw CameraError.saveFailed
        }

        let finalData = data as Data
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

        var errorDescription: String? { "Could not save photo to library" }
    }

    // MARK: - Device selection

    private struct FocalSelection {
        let device: AVCaptureDevice
        let zoomFactor: CGFloat
        let deviceLabel: String
        let isFallback: Bool
        let fallbackReason: String?
    }

    private func deviceSelection(for mm: Int) -> FocalSelection? {
        deviceSelection(for: mm, source: "deviceSelection")
    }

    private func deviceSelection(
        for mm: Int,
        source: String
    ) -> FocalSelection? {
        guard let selection = rawDeviceSelection(for: mm) else { return nil }
        return validatedRearSelection(selection, requested: mm, source: source)
    }

    private func rawDeviceSelection(for mm: Int) -> FocalSelection? {
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

        func equivalentFocalLength(_ camera: AVCaptureDevice) -> CGFloat {
            let radians = CGFloat(camera.activeFormat.videoFieldOfView) * .pi / 180.0
            let tangent = tan(radians / 2.0)
            return tangent > 0 ? 21.6 / tangent : 24.0
        }

        let wideEquivalent = equivalentFocalLength(wide)

        switch mm {
        case 21:
            if let ultraWide = find(.builtInUltraWideCamera) {
                let zoom = CGFloat(mm) / equivalentFocalLength(ultraWide)
                return FocalSelection(
                    device: ultraWide,
                    zoomFactor: min(max(zoom, ultraWide.minAvailableVideoZoomFactor), ultraWide.maxAvailableVideoZoomFactor),
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

        case 35:
            let zoom = max(35.0 / wideEquivalent, 1.0)
            return FocalSelection(
                device: wide,
                zoomFactor: min(zoom, wide.maxAvailableVideoZoomFactor),
                deviceLabel: label(for: wide),
                isFallback: false,
                fallbackReason: nil
            )

        case 50:
            let zoom = max(50.0 / wideEquivalent, 1.0)
            return FocalSelection(
                device: wide,
                zoomFactor: min(zoom, wide.maxAvailableVideoZoomFactor),
                deviceLabel: label(for: wide),
                isFallback: false,
                fallbackReason: nil
            )

        case 105:
            if let tele = find(.builtInTelephotoCamera) {
                let zoom = max(105.0 / equivalentFocalLength(tele), 1.0)
                return FocalSelection(
                    device: tele,
                    zoomFactor: min(zoom, tele.maxAvailableVideoZoomFactor),
                    deviceLabel: label(for: tele),
                    isFallback: false,
                    fallbackReason: nil
                )
            }
            let zoom = max(105.0 / wideEquivalent, 1.0)
            return FocalSelection(
                device: wide,
                zoomFactor: min(zoom, wide.maxAvailableVideoZoomFactor),
                deviceLabel: label(for: wide),
                isFallback: true,
                fallbackReason: "teleUnavailable"
            )

        default:
            return FocalSelection(
                device: wide,
                zoomFactor: 1.0,
                deviceLabel: label(for: wide),
                isFallback: true,
                fallbackReason: "unsupportedFocalRequested"
            )
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

            let clampedZoom = min(
                max(selection.zoomFactor, selection.device.minAvailableVideoZoomFactor),
                selection.device.maxAvailableVideoZoomFactor
            )
            try selection.device.lockForConfiguration()
            if #available(iOS 16.0, *) {
                configurePreferredPhotoFormatIfAvailableLocked(
                    for: selection.device,
                    reason: source
                )
            }
            selection.device.videoZoomFactor = clampedZoom
            selection.device.unlockForConfiguration()
            digitalZoomFactor = clampedZoom

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
        case 35:
            desiredZoom = max(35.0 / wideEquivalent, 1.0)
        case 50:
            desiredZoom = max(50.0 / wideEquivalent, 1.0)
        case 105:
            desiredZoom = max(105.0 / wideEquivalent, 1.0)
        default:
            desiredZoom = 1.0
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
        return tangent > 0 ? 21.6 / tangent : 24.0
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
        iso: CGFloat
    ) -> DetailProcessingPlan {
        let focalBase: Float
        switch focalLength {
        case 21:  focalBase = 0.11
        case 35:  focalBase = 0.14
        case 50:  focalBase = 0.17
        case 105: focalBase = 0.20
        default:  focalBase = 0.15
        }

        let profileMultiplier: Float
        let radius: Float
        switch profile {
        case .raw:
            profileMultiplier = 1.00
            radius = focalLength == 105 ? 1.00 : 1.30
        case .vg:
            profileMultiplier = focalLength == 105 ? 0.82 : 0.88
            radius = focalLength == 105 ? 0.82 : 1.15
        case .ew:
            profileMultiplier = focalLength == 105 ? 0.62 : 0.42
            radius = focalLength == 105 ? 0.72 : 0.65
        }

        let isoAttenuation = Float(max(0.35, 1.0 - max(0.0, Double(iso) - 160.0) / 1000.0))
        let sharpenIntensity = focalBase * profileMultiplier * isoAttenuation

        let denoiseThreshold: CGFloat
        switch profile {
        case .raw: denoiseThreshold = 280
        case .vg: denoiseThreshold = 220
        case .ew: denoiseThreshold = 1000
        }

        let shouldDenoise = iso > denoiseThreshold
        let noiseLevel: Float
        if shouldDenoise {
            let base: Float = {
                switch profile {
                case .ew: return 0.003
                case .raw, .vg: return 0.008
                }
            }()
            let extraLimit: Float = profile == .ew ? 0.016 : 0.030
            let extraDivisor: Float = profile == .ew ? 42_000.0 : 28_000.0
            let extra = min(extraLimit, max(0.0, Float(iso - denoiseThreshold) / extraDivisor))
            noiseLevel = base + extra
        } else {
            noiseLevel = 0
        }

        return DetailProcessingPlan(
            sharpenIntensity: sharpenIntensity,
            sharpenRadius: radius,
            noiseLevel: noiseLevel,
            shouldDenoise: shouldDenoise,
            reason: shouldDenoise ? "isoAdaptive" : "lowISO"
        )
    }

    private static func doubleValue(_ value: Any?) -> Double? {
        if let number = value as? NSNumber { return number.doubleValue }
        if let double = value as? Double { return double }
        if let string = value as? String { return Double(string) }
        return nil
    }

    private static func intValue(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let int = value as? Int { return int }
        if let string = value as? String { return Int(string) }
        return nil
    }

    private static func formatOptional(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.3f", value)
    }

    private static func formatExposure(_ value: Double?) -> String {
        guard let value else { return "unknown" }
        return String(format: "%.5fs", value)
    }

    private static func whiteBalanceLogName(_ value: Int?) -> String {
        switch value {
        case 0: return "auto"
        case 1: return "manual"
        case let value?: return "\(value)"
        case nil: return "unknown"
        }
    }

    private static func now() -> TimeInterval {
        ProcessInfo.processInfo.systemUptime
    }

    private static func format(_ value: CGFloat) -> String {
        String(format: "%.2f", value)
    }

    private static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", duration)
    }
}

private final class PhotoCaptureDelegate: NSObject, AVCapturePhotoCaptureDelegate, @unchecked Sendable {
    let format: AspectFormat
    let filmProfile: FilmProfile
    let cropFactor: CGFloat
    let focalLength: Int
    let captureStartedAt: TimeInterval

    nonisolated(unsafe) weak var cameraManager: CameraManager?
    nonisolated(unsafe) let completion: () -> Void

    init(
        format: AspectFormat,
        filmProfile: FilmProfile,
        cropFactor: CGFloat,
        focalLength: Int,
        captureStartedAt: TimeInterval,
        cameraManager: CameraManager,
        completion: @escaping () -> Void
    ) {
        self.format = format
        self.filmProfile = filmProfile
        self.cropFactor = cropFactor
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
                    cropFactor: self.cropFactor,
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
