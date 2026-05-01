import SwiftUI
@preconcurrency import AVFoundation
import CoreImage
import Metal

struct PreviewView: UIViewRepresentable {
    let format: AspectFormat
    let activeFilmProfile: FilmProfile
    let pendingFilmProfile: FilmProfile?
    let focalLength: Int
    let orientation: CameraOrientationState
    let previewGeneration: Int
    let isPreviewTransitioning: Bool
    let previewTransitionReason: String
    let cameraManager: CameraManager

    func makeUIView(context: Context) -> FilmPreviewUIView {
        let view = FilmPreviewUIView()
        view.configure(cameraManager: cameraManager)
        return view
    }

    func updateUIView(_ uiView: FilmPreviewUIView, context: Context) {
        uiView.update(
            format: format,
            activeFilmProfile: activeFilmProfile,
            pendingFilmProfile: pendingFilmProfile,
            focalLength: focalLength,
            orientation: orientation,
            previewGeneration: previewGeneration,
            isPreviewTransitioning: isPreviewTransitioning,
            previewTransitionReason: previewTransitionReason
        )
    }
}

final class FilmPreviewUIView: UIView {

    private struct RenderState: Sendable {
        var profile: FilmProfile = .raw
        var pendingProfile: FilmProfile?
        var focalLength = 28
        var orientation: CameraOrientationState = .portrait
        var format: AspectFormat = .threeToFour
        var generation = 0
        var isTransitioning = false
        var transitionReason = "startup"
        var drawableSize: CGSize = .zero
        var scale: CGFloat = 1.0
        var awaitingFirstRenderableFrame = false
        var minimumFramePTS: CMTime = .invalid
        var publishedAt: TimeInterval = 0
    }

    private struct ResolutionSnapshot: Equatable {
        let profile: FilmProfile
        let bufferWidth: Int
        let bufferHeight: Int
        let drawableWidth: Int
        let drawableHeight: Int
        let boundsWidth: Int
        let boundsHeight: Int
        let scale: CGFloat
        let orientation: CameraOrientationState
        let format: AspectFormat
        let generation: Int
    }

    private struct RenderSnapshot: Equatable {
        let generation: Int
        let orientation: CameraOrientationState
        let bufferWidth: Int
        let bufferHeight: Int
        let drawableWidth: Int
        let drawableHeight: Int
        let connectionAngle: Int
        let transformDescription: String
        let aspectFillScale: String
    }

    private struct RenderStateSignature: Equatable {
        let profile: FilmProfile
        let pendingProfile: FilmProfile?
        let focalLength: Int
        let orientation: CameraOrientationState
        let format: AspectFormat
        let generation: Int
        let isTransitioning: Bool
        let transitionReason: String
        let drawableSize: CGSize
        let scale: CGFloat
        let awaitingFirstRenderableFrame: Bool
    }

    private weak var cameraManager: CameraManager?
    nonisolated(unsafe) private weak var renderCameraManager: CameraManager?
    nonisolated private let renderQueue = DispatchQueue(
        label: "film.preview.render.queue",
        qos: .userInteractive
    )

    nonisolated private let ciContext: CIContext = {
        let options: [CIContextOption: Any] = [
            .workingColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .outputColorSpace: CGColorSpace(name: CGColorSpace.sRGB) as Any,
            .useSoftwareRenderer: false,
            .cacheIntermediates: false
        ]
        if let device = MTLCreateSystemDefaultDevice() {
            return CIContext(mtlDevice: device, options: options)
        }
        return CIContext(options: options)
    }()

    private var desiredProfile: FilmProfile = .raw
    private var desiredPendingProfile: FilmProfile?
    private var desiredFocalLength = 28
    private var desiredOrientation: CameraOrientationState = .portrait
    private var desiredFormat: AspectFormat = .threeToFour
    private var desiredPreviewGeneration = 0
    private var desiredPreviewTransitioning = false
    private var desiredPreviewTransitionReason = "startup"
    private var lastPublishedGeneration = -1
    private var lastPublishedTransitioning = false
    private var lastPublishedSignature: RenderStateSignature?
    private var awaitingFirstFrameGeneration: Int?
    private var committedDrawableSize: CGSize = .zero
    private var committedDrawableScale: CGFloat = 1.0
    private var pendingLayoutCommitWorkItem: DispatchWorkItem?
    private var lastLayoutOrientationApplied: CameraOrientationState?

    nonisolated private let renderStateLock = NSLock()
    nonisolated(unsafe) private var renderState = RenderState()
    nonisolated(unsafe) private var lastResolutionSnapshot: ResolutionSnapshot?
    nonisolated(unsafe) private var lastRenderSnapshot: RenderSnapshot?
    nonisolated(unsafe) private var didReportFirstFrame = false
    nonisolated(unsafe) private var droppedFrameCount = 0
    nonisolated(unsafe) private var slowFrameCount = 0
    nonisolated(unsafe) private var lastHeldGeneration = -1
    nonisolated(unsafe) private var lastStaleDropGeneration = -1
    nonisolated(unsafe) private var cachedMetalLayerRef: CAMetalLayer?

    override class var layerClass: AnyClass { CAMetalLayer.self }

    func configure(cameraManager: CameraManager) {
        self.cameraManager = cameraManager
        self.renderCameraManager = cameraManager

        backgroundColor = .black
        isOpaque = true
        clipsToBounds = true

        let metalLayer = layer as! CAMetalLayer
        updateCachedMetalLayer(metalLayer)
        metalLayer.pixelFormat = .bgra8Unorm
        metalLayer.framebufferOnly = false
        metalLayer.contentsGravity = .resizeAspectFill
        metalLayer.isOpaque = true

        RuntimeLog.info(
            "[Preview]",
            "metalLayerConfiguredOnMain drawable=\(Int(metalLayer.drawableSize.width))x\(Int(metalLayer.drawableSize.height))"
        )

        publishRenderState(reason: "configured")
        cameraManager.attachPreviewDelegate(self, queue: renderQueue)
    }

    deinit {
        pendingLayoutCommitWorkItem?.cancel()
        cameraManager?.detachPreviewDelegate(waitUntilDone: true)
    }

    func update(
        format: AspectFormat,
        activeFilmProfile: FilmProfile,
        pendingFilmProfile: FilmProfile?,
        focalLength: Int,
        orientation: CameraOrientationState,
        previewGeneration: Int,
        isPreviewTransitioning: Bool,
        previewTransitionReason: String
    ) {
        desiredProfile = activeFilmProfile
        desiredPendingProfile = pendingFilmProfile
        desiredFocalLength = focalLength
        desiredOrientation = orientation
        desiredFormat = format
        desiredPreviewGeneration = previewGeneration
        desiredPreviewTransitioning = isPreviewTransitioning
        desiredPreviewTransitionReason = previewTransitionReason
        publishRenderState(reason: previewTransitionReason)
    }

    override func layoutSubviews() {
        super.layoutSubviews()

        guard bounds.width > 0, bounds.height > 0,
              bounds.width.isFinite, bounds.height.isFinite else { return }

        let metalLayer = layer as! CAMetalLayer
        updateCachedMetalLayer(metalLayer)

        let scale = max(1.0, window?.screen.scale ?? UIScreen.main.scale)
        metalLayer.contentsScale = scale
        let targetDrawableSize = CGSize(
            width: max(1, bounds.width * scale),
            height: max(1, bounds.height * scale)
        )
        if committedDrawableSize == .zero {
            commitLayoutChange(
                to: targetDrawableSize,
                scale: scale,
                reason: "layoutChanged"
            )
        } else if desiredPreviewTransitionReason == "aspectFormatChanged" {
            scheduleDeferredLayoutCommit(
                drawableSize: targetDrawableSize,
                scale: scale
            )
        } else {
            pendingLayoutCommitWorkItem?.cancel()
            pendingLayoutCommitWorkItem = nil
            commitLayoutChange(
                to: targetDrawableSize,
                scale: scale,
                reason: "layoutChanged"
            )
        }
    }

    private func publishRenderState(reason: String) {
        let metalLayer = layer as? CAMetalLayer
        let drawableSize = metalLayer?.drawableSize ?? .zero
        let scale = max(1.0, metalLayer?.contentsScale ?? UIScreen.main.scale)
        let generationChanged = desiredPreviewGeneration != lastPublishedGeneration
        let transitionJustEnded = lastPublishedTransitioning && !desiredPreviewTransitioning

        if generationChanged || transitionJustEnded {
            awaitingFirstFrameGeneration = desiredPreviewGeneration
        }

        let awaitingFirstFrame =
            awaitingFirstFrameGeneration == desiredPreviewGeneration && !desiredPreviewTransitioning
        let transitionReason = desiredPreviewTransitionReason.isEmpty ? reason : desiredPreviewTransitionReason

        let signature = RenderStateSignature(
            profile: desiredProfile,
            pendingProfile: desiredPendingProfile,
            focalLength: desiredFocalLength,
            orientation: desiredOrientation,
            format: desiredFormat,
            generation: desiredPreviewGeneration,
            isTransitioning: desiredPreviewTransitioning,
            transitionReason: transitionReason,
            drawableSize: drawableSize,
            scale: scale,
            awaitingFirstRenderableFrame: awaitingFirstFrame
        )

        guard signature != lastPublishedSignature else { return }
        lastPublishedSignature = signature

        let snapshot = RenderState(
            profile: desiredProfile,
            pendingProfile: desiredPendingProfile,
            focalLength: desiredFocalLength,
            orientation: desiredOrientation,
            format: desiredFormat,
            generation: desiredPreviewGeneration,
            isTransitioning: desiredPreviewTransitioning,
            transitionReason: transitionReason,
            drawableSize: drawableSize,
            scale: scale,
            awaitingFirstRenderableFrame: awaitingFirstFrame,
            minimumFramePTS: CMClockGetTime(CMClockGetHostTimeClock()),
            publishedAt: ProcessInfo.processInfo.systemUptime
        )

        lastPublishedGeneration = desiredPreviewGeneration
        lastPublishedTransitioning = desiredPreviewTransitioning

        storeRenderState(snapshot)
        RuntimeLog.info(
            "[PreviewRender]",
            "renderStateUpdated orientation=\(snapshot.orientation.rawValue) drawable=\(Int(snapshot.drawableSize.width))x\(Int(snapshot.drawableSize.height)) scale=\(String(format: "%.1f", snapshot.scale)) generation=\(snapshot.generation) transitioning=\(snapshot.isTransitioning) reason=\(transitionReason)"
        )
    }

    private func markGenerationRendered(_ generation: Int) {
        if awaitingFirstFrameGeneration == generation {
            awaitingFirstFrameGeneration = nil
        }
    }

    private func updateCachedMetalLayer(_ metalLayer: CAMetalLayer?) {
        renderStateLock.lock()
        cachedMetalLayerRef = metalLayer
        renderStateLock.unlock()
    }

    private func scheduleDeferredLayoutCommit(drawableSize: CGSize, scale: CGFloat) {
        pendingLayoutCommitWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            self?.commitLayoutChange(
                to: drawableSize,
                scale: scale,
                reason: "aspectLayoutSettled"
            )
        }
        pendingLayoutCommitWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08, execute: workItem)
    }

    private func commitLayoutChange(
        to drawableSize: CGSize,
        scale: CGFloat,
        reason: String
    ) {
        guard let metalLayer = layer as? CAMetalLayer else { return }

        let roundedSize = CGSize(
            width: max(1, drawableSize.width.rounded()),
            height: max(1, drawableSize.height.rounded())
        )
        let sizeChanged = abs(committedDrawableSize.width - roundedSize.width) >= 2
            || abs(committedDrawableSize.height - roundedSize.height) >= 2
            || abs(committedDrawableScale - scale) > 0.01

        if sizeChanged {
            metalLayer.contentsScale = scale
            metalLayer.drawableSize = roundedSize
            committedDrawableSize = roundedSize
            committedDrawableScale = scale
            publishRenderState(reason: reason)
        }

        if lastLayoutOrientationApplied != desiredOrientation {
            lastLayoutOrientationApplied = desiredOrientation
            cameraManager?.reapplyOrientation(reason: "previewLayoutChanged")
        }
    }

    nonisolated private func storeRenderState(_ state: RenderState) {
        renderStateLock.lock()
        renderState = state
        renderStateLock.unlock()
    }

    nonisolated private func readRenderInputs() -> (state: RenderState, metalLayer: CAMetalLayer?) {
        renderStateLock.lock()
        let state = renderState
        let metalLayer = cachedMetalLayerRef
        renderStateLock.unlock()
        return (state, metalLayer)
    }

    nonisolated private func markAwaitingFrameRendered() {
        renderStateLock.lock()
        renderState.awaitingFirstRenderableFrame = false
        renderStateLock.unlock()
    }
}

extension FilmPreviewUIView: AVCaptureVideoDataOutputSampleBufferDelegate {

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        autoreleasepool {
            let inputs = readRenderInputs()
            let state = inputs.state

            guard state.drawableSize.width > 0, state.drawableSize.height > 0 else { return }

            if state.isTransitioning {
                if lastHeldGeneration != state.generation {
                    lastHeldGeneration = state.generation
                    RuntimeLog.info(
                        "[PreviewRender]",
                        "holdingLastFrame reason=\(state.transitionReason) generation=\(state.generation)"
                    )
                }
                return
            }

            guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
            guard let metalLayer = inputs.metalLayer else { return }

            if shouldDropStaleFrame(sampleBuffer: sampleBuffer, connection: connection, state: state) {
                return
            }

            renderCameraManager?.updatePreviewHistogram(from: pixelBuffer)

            guard let drawable = metalLayer.nextDrawable() else { return }
            let drawableWidth = drawable.texture.width
            let drawableHeight = drawable.texture.height

            let frameStartedAt = ProcessInfo.processInfo.systemUptime
            let inputImage = CIImage(cvPixelBuffer: pixelBuffer)
            let processedImage = FilmProfileProcessor.apply(
                profile: state.profile,
                to: inputImage,
                focalLength: state.focalLength,
                isPreview: true
            )
            let (filteredImage, transformDescription) = orientedPreviewImage(
                processedImage,
                for: state.orientation
            )

            let drawableSize = CGSize(
                width: drawableWidth,
                height: drawableHeight
            )
            let scaleX = drawableSize.width / filteredImage.extent.width
            let scaleY = drawableSize.height / filteredImage.extent.height
            let scale = max(scaleX, scaleY)

            guard scale.isFinite, scale > 0 else { return }

            let scaled = filteredImage
                .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                .transformed(
                    by: CGAffineTransform(
                        translationX: ((drawableSize.width - filteredImage.extent.width * scale) * 0.5)
                            - filteredImage.extent.minX * scale,
                        y: ((drawableSize.height - filteredImage.extent.height * scale) * 0.5)
                            - filteredImage.extent.minY * scale
                    )
                )

            ciContext.render(
                scaled,
                to: drawable.texture,
                commandBuffer: nil,
                bounds: CGRect(origin: .zero, size: drawableSize),
                colorSpace: CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()
            )
            drawable.present()

            if !didReportFirstFrame {
                didReportFirstFrame = true
                DispatchQueue.main.async { [weak self] in
                    self?.renderCameraManager?.notifyFirstPreviewFrame()
                }
            }

            let bufferWidth = CVPixelBufferGetWidth(pixelBuffer)
            let bufferHeight = CVPixelBufferGetHeight(pixelBuffer)

            logResolutionIfNeeded(
                profile: state.profile,
                bufferWidth: bufferWidth,
                bufferHeight: bufferHeight,
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight,
                scale: state.scale,
                orientation: state.orientation,
                format: state.format,
                generation: state.generation
            )
            logRenderIfNeeded(
                generation: state.generation,
                orientation: state.orientation,
                bufferWidth: bufferWidth,
                bufferHeight: bufferHeight,
                drawableWidth: drawableWidth,
                drawableHeight: drawableHeight,
                connectionAngle: Int(connection.videoRotationAngle.rounded()),
                transformDescription: transformDescription,
                aspectFillScale: scale
            )

            if state.awaitingFirstRenderableFrame {
                markAwaitingFrameRendered()
                RuntimeLog.info(
                    "[PreviewRender]",
                    "rendered generation=\(state.generation) orientation=\(state.orientation.rawValue) transform=\(transformDescription)"
                )
                RuntimeLog.info(
                    "[Performance]",
                    "renderQueueBacklog=\(Self.formatDuration(max(0, frameStartedAt - state.publishedAt))) generation=\(state.generation)"
                )
                if state.transitionReason == "focalChanged" {
                    RuntimeLog.info(
                        "[PreviewRender]",
                        "firstFrameAfterFocalSwitch focal=\(state.focalLength) generation=\(state.generation)"
                    )
                }
                DispatchQueue.main.async { [weak self] in
                    self?.markGenerationRendered(state.generation)
                    self?.renderCameraManager?.notifyPreviewFrameRendered(
                        generation: state.generation,
                        focalLength: state.focalLength,
                        orientation: state.orientation,
                        reason: state.transitionReason
                    )
                }
            }

            let frameElapsed = ProcessInfo.processInfo.systemUptime - frameStartedAt
            if frameElapsed > 0.040 {
                slowFrameCount += 1
                if slowFrameCount % 30 == 0 {
                    RuntimeLog.info(
                        "[Performance]",
                        "slowPreviewFrame count=\(slowFrameCount) profile=\(state.profile.logName) elapsed=\(String(format: "%.3fs", frameElapsed))"
                    )
                }
            }
        }
    }

    nonisolated func captureOutput(
        _ output: AVCaptureOutput,
        didDrop sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        droppedFrameCount += 1
        if droppedFrameCount % 60 == 0 {
            RuntimeLog.info("[Preview]", "droppedFrames=\(droppedFrameCount)")
        }
    }

    nonisolated private func shouldDropStaleFrame(
        sampleBuffer: CMSampleBuffer,
        connection: AVCaptureConnection,
        state: RenderState
    ) -> Bool {
        guard state.awaitingFirstRenderableFrame else { return false }

        let samplePTS = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if samplePTS.isValid,
           state.minimumFramePTS.isValid,
           CMTimeCompare(samplePTS, state.minimumFramePTS) < 0 {
            if lastStaleDropGeneration != state.generation {
                lastStaleDropGeneration = state.generation
                RuntimeLog.info(
                    "[PreviewRender]",
                    "droppedStaleFrame frameGeneration=\(max(0, state.generation - 1)) currentGeneration=\(state.generation) reason=olderThanPublishedState"
                )
            }
            return true
        }

        let actualAngle = Int(connection.videoRotationAngle.rounded())
        let expectedAngle = Int(state.orientation.videoOutputRotationAngle.rounded())
        if actualAngle != expectedAngle {
            if lastStaleDropGeneration != state.generation {
                lastStaleDropGeneration = state.generation
                RuntimeLog.info(
                    "[PreviewRender]",
                    "droppedStaleFrame frameGeneration=\(max(0, state.generation - 1)) currentGeneration=\(state.generation) reason=angleMismatch actual=\(actualAngle) expected=\(expectedAngle)"
                )
            }
            return true
        }

        return false
    }

    nonisolated private func logResolutionIfNeeded(
        profile: FilmProfile,
        bufferWidth: Int,
        bufferHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int,
        scale: CGFloat,
        orientation: CameraOrientationState,
        format: AspectFormat,
        generation: Int
    ) {
        let boundsWidth = scale > 0 ? Int((CGFloat(drawableWidth) / scale).rounded()) : 0
        let boundsHeight = scale > 0 ? Int((CGFloat(drawableHeight) / scale).rounded()) : 0
        let snapshot = ResolutionSnapshot(
            profile: profile,
            bufferWidth: bufferWidth,
            bufferHeight: bufferHeight,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight,
            boundsWidth: boundsWidth,
            boundsHeight: boundsHeight,
            scale: scale,
            orientation: orientation,
            format: format,
            generation: generation
        )

        guard snapshot != lastResolutionSnapshot else { return }
        lastResolutionSnapshot = snapshot

        RuntimeLog.info(
            "[PreviewResolution]",
            "profile=\(profile.logName) buffer=\(bufferWidth)x\(bufferHeight) drawable=\(drawableWidth)x\(drawableHeight) bounds=\(boundsWidth)x\(boundsHeight) scale=\(String(format: "%.1f", scale)) orientation=\(orientation.rawValue) format=\(format.label)"
        )
    }

    nonisolated private func orientedPreviewImage(
        _ image: CIImage,
        for orientation: CameraOrientationState
    ) -> (image: CIImage, transformDescription: String) {
        switch orientation {
        case .portrait:
            return (image, "identity")
        case .landscapeLeft:
            return (image.oriented(.right), "rotate90CW")
        case .landscapeRight:
            return (image.oriented(.left), "rotate90CCW")
        }
    }

    nonisolated private func logRenderIfNeeded(
        generation: Int,
        orientation: CameraOrientationState,
        bufferWidth: Int,
        bufferHeight: Int,
        drawableWidth: Int,
        drawableHeight: Int,
        connectionAngle: Int,
        transformDescription: String,
        aspectFillScale: CGFloat
    ) {
        let snapshot = RenderSnapshot(
            generation: generation,
            orientation: orientation,
            bufferWidth: bufferWidth,
            bufferHeight: bufferHeight,
            drawableWidth: drawableWidth,
            drawableHeight: drawableHeight,
            connectionAngle: connectionAngle,
            transformDescription: transformDescription,
            aspectFillScale: String(format: "%.3f", aspectFillScale)
        )

        guard snapshot != lastRenderSnapshot else { return }
        lastRenderSnapshot = snapshot

        RuntimeLog.info(
            "[PreviewRender]",
            "generation=\(generation) orientation=\(orientation.rawValue) drawable=\(drawableWidth)x\(drawableHeight) buffer=\(bufferWidth)x\(bufferHeight) connectionAngle=\(connectionAngle) transform=\(transformDescription) aspectFill=\(snapshot.aspectFillScale)"
        )
    }

    nonisolated private static func formatDuration(_ duration: TimeInterval) -> String {
        String(format: "%.3fs", duration)
    }
}
