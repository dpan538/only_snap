import SwiftUI
import Combine
import CoreMotion

private typealias L = Theme.Layout

private enum HistogramDisplayMode: Equatable {
    case waveform
    case bars

    var next: HistogramDisplayMode {
        switch self {
        case .waveform: return .bars
        case .bars: return .waveform
        }
    }
}

private enum GridGuideMode: Equatable {
    case off
    case thirds
    case diagonal
    case center
    case frame

    var next: GridGuideMode {
        switch self {
        case .off: return .thirds
        case .thirds: return .diagonal
        case .diagonal: return .center
        case .center: return .frame
        case .frame: return .off
        }
    }

    var isActive: Bool {
        self != .off
    }

    var label: String {
        switch self {
        case .off, .thirds: return "GRID"
        case .diagonal: return "DIAG"
        case .center: return "CENTER"
        case .frame: return "FRAME"
        }
    }

    var capsuleWidth: CGFloat {
        switch self {
        case .center: return 84
        case .frame: return 78
        default: return 64
        }
    }
}

private struct PortraitLayoutMetrics {
    let centerX: CGFloat
    let contentWidth: CGFloat
    let viewfinderWidth: CGFloat
    let viewfinderHeight: CGFloat
    let topHUDCenterY: CGFloat
    let viewfinderCenterY: CGFloat
    let focalCenterY: CGFloat
    let controlsCenterY: CGFloat
    let controlsHeight: CGFloat
}

struct ContentView: View {

    @EnvironmentObject private var camera: CameraManager
    @State private var shutterProgress: CGFloat = 0
    @State private var histogramMode: HistogramDisplayMode = .waveform
    @State private var levelEnabled = false
    @State private var gridMode: GridGuideMode = .off
    @StateObject private var levelMotion = LevelMotionModel()

    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    private let orientationUIAnimation = Animation.linear(duration: 0.14)
    private let selectionAnimation = Animation.linear(duration: 0.12)
    private let aspectAnimation = Animation.linear(duration: 0.16)

    private var iconRotation: Angle {
        .degrees(camera.cameraOrientation.uiRotationAngle)
    }

    private var filmProfileButtonTitle: String {
        if let pendingFilmProfile = camera.pendingFilmProfile {
            return "\(pendingFilmProfile.label)…"
        }
        return camera.activeFilmProfile.label
    }

    var body: some View {
        GeometryReader { screen in
            let sw = screen.size.width
            let sh = screen.size.height
            let safe = screen.safeAreaInsets
            let metrics = portraitLayoutMetrics(
                screenWidth: sw,
                screenHeight: sh,
                safeTop: safe.top,
                safeBottom: safe.bottom,
                format: camera.selectedAspectFormat
            )

            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                viewfinderBlock(viewfinderWidth: metrics.viewfinderWidth)
                    .position(x: metrics.centerX, y: metrics.viewfinderCenterY)

                topHUD(width: metrics.viewfinderWidth)
                    .position(x: metrics.centerX, y: metrics.topHUDCenterY)

                focalRow
                    .frame(width: metrics.viewfinderWidth, height: L.focalRowHeight)
                    .position(
                        x: metrics.centerX + focalRowOffset.width,
                        y: metrics.focalCenterY + focalRowOffset.height
                    )

                controlsBlock(width: metrics.viewfinderWidth)
                    .frame(width: metrics.viewfinderWidth, height: metrics.controlsHeight)
                    .position(x: metrics.centerX, y: metrics.controlsCenterY)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            camera.updateCameraOrientation(UIDevice.current.orientation)
            levelMotion.start()
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
            levelMotion.stop()
            camera.stop()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIDevice.orientationDidChangeNotification)) { _ in
            camera.updateCameraOrientation(UIDevice.current.orientation)
        }
        .alert("Camera Error", isPresented: captureErrorBinding) {
            Button("OK") { camera.captureError = nil }
        } message: {
            Text(camera.captureError ?? "Unknown camera error")
        }
    }

    private var captureErrorBinding: Binding<Bool> {
        Binding(
            get: { camera.captureError != nil },
            set: { if !$0 { camera.captureError = nil } }
        )
    }

    private func portraitLayoutMetrics(
        screenWidth: CGFloat,
        screenHeight: CGFloat,
        safeTop: CGFloat,
        safeBottom: CGFloat,
        format: AspectFormat
    ) -> PortraitLayoutMetrics {
        let maxContentWidth = max(1, screenWidth - L.vfHPad * 2)
        let controlsHeight = max(L.shutterHitSize, L.btnSize * 2 + L.sideButtonSpacing)
        let controlsBottom = screenHeight - max(L.controlsBottomPad, safeBottom + L.controlsSafeBottomInset)
        let controlsCenterY = controlsBottom - controlsHeight / 2

        // Focal labels are not part of the lower control cluster; keep them
        // anchored to the previous control baseline while the buttons move.
        let focalReferenceHeight = max(L.shutterHitSize, L.focalReferenceButtonSize * 2 + L.sideButtonSpacing)
        let focalReferenceBottom = screenHeight - max(
            L.focalReferenceControlsBottomPad,
            safeBottom + L.focalReferenceControlsSafeBottomInset
        )
        let focalReferenceTop = focalReferenceBottom - focalReferenceHeight
        let focalCenterY = focalReferenceTop - L.focalToButtons - L.focalRowHeight / 2 + 12
            + (camera.cameraOrientation.isLandscape ? 16 : 0)
        let focalTop = focalCenterY - L.focalRowHeight / 2

        let minTopHUDTop: CGFloat = 10
        let topHUDTop = max(minTopHUDTop, safeTop - L.topHUDTopLift)
        let viewfinderMinTop = topHUDTop + L.topHUDHeight + L.topHUDToViewfinder
        let viewfinderMaxBottom = focalTop - L.viewfinderToFocal
        let availableViewfinderHeight = max(1, viewfinderMaxBottom - viewfinderMinTop)

        // Keep 3:3, 3:4, and 3:4.5 on one shared width. The tallest
        // portrait ratio decides the maximum width, so only height changes.
        let tallestPortraitRatio = AspectFormat.twoToThree.heightRatio
        let targetViewfinderWidth = min(maxContentWidth, L.viewfinderTargetWidth)
        let viewfinderWidth = min(targetViewfinderWidth, availableViewfinderHeight / tallestPortraitRatio)
        let viewfinderHeight = viewfinderWidth * format.heightRatio
        let viewfinderCenterY = viewfinderMinTop + availableViewfinderHeight / 2

        return PortraitLayoutMetrics(
            centerX: screenWidth / 2,
            contentWidth: viewfinderWidth,
            viewfinderWidth: viewfinderWidth,
            viewfinderHeight: viewfinderHeight,
            topHUDCenterY: topHUDTop + L.topHUDHeight / 2,
            viewfinderCenterY: viewfinderCenterY,
            focalCenterY: focalCenterY,
            controlsCenterY: controlsCenterY,
            controlsHeight: controlsHeight
        )
    }

    private func topHUD(width: CGFloat) -> some View {
        let isLandscape = camera.cameraOrientation.isLandscape
        let landscapeRailWidth = landscapeHUDRailWidth(for: width)
        let histogramWidth = isLandscape ? landscapeRailWidth : L.histogramWidth
        let histogramHeight = isLandscape ? landscapeRailWidth : L.topHUDHeight

        return Group {
            if isLandscape {
                HStack(alignment: .top, spacing: 0) {
                    Button {
                        haptic.impactOccurred()
                        histogramMode = histogramMode.next
                    } label: {
                        MiniHistogramView(
                            mode: histogramMode,
                            samples: camera.histogramSamples
                        )
                        .frame(width: histogramWidth, height: histogramHeight)
                        .rotationEffect(iconRotation)
                    }
                    .buttonStyle(.plain)

                    Color.clear
                        .frame(width: landscapeHUDGroupGap)

                    proControlStrip(isLandscape: true, railWidth: landscapeRailWidth)
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
                .frame(width: width, height: max(L.topHUDHeight, histogramHeight), alignment: .leading)
            } else {
                let stripWidth = max(0, width - L.histogramWidth - L.topHUDSpacing)
                HStack(alignment: .top, spacing: L.topHUDSpacing) {
                    Button {
                        haptic.impactOccurred()
                        histogramMode = histogramMode.next
                    } label: {
                        MiniHistogramView(
                            mode: histogramMode,
                            samples: camera.histogramSamples
                        )
                        .frame(width: L.histogramWidth, height: L.topHUDHeight)
                    }
                    .buttonStyle(.plain)

                    proControlStrip(isLandscape: false, railWidth: L.proCapsuleHitHeight)
                        .frame(width: stripWidth, alignment: .leading)
                }
                .frame(width: width, height: L.topHUDHeight, alignment: .leading)
                    .clipped()
            }
        }
            .animation(selectionAnimation, value: histogramMode)
            .animation(selectionAnimation, value: camera.captureOutputKind)
            .animation(selectionAnimation, value: camera.isAELocked)
            .animation(selectionAnimation, value: camera.meteringMode)
            .animation(selectionAnimation, value: gridMode)
    }

    @ViewBuilder
    private func proControlStrip(isLandscape: Bool, railWidth: CGFloat) -> some View {
        let controls = HStack(spacing: isLandscape ? landscapeCapsuleSpacing : 6) {
                proCapsule(title: camera.captureOutputKind.rawValue, width: isLandscape ? railWidth : 58, railWidth: railWidth) {
                    haptic.impactOccurred()
                    camera.cycleCaptureOutputKind()
                }

                proCapsule(
                    title: "AE",
                    systemName: camera.isAELocked ? "lock.fill" : "lock.open",
                    isActive: camera.isAELocked,
                    width: isLandscape ? railWidth : 60,
                    railWidth: railWidth
                ) {
                    haptic.impactOccurred()
                    camera.toggleAELock()
                }

                proCapsule(title: "LEVEL", isActive: levelEnabled, width: isLandscape ? railWidth : 74, railWidth: railWidth) {
                    haptic.impactOccurred()
                    levelEnabled.toggle()
                }

                proCapsule(title: gridMode.label, isActive: gridMode.isActive, width: isLandscape ? railWidth : gridCapsuleWidth, railWidth: railWidth) {
                    haptic.impactOccurred()
                    gridMode = gridMode.next
                }

                proCapsule(
                    title: isLandscape ? "" : camera.meteringMode.shortLabel,
                    systemName: camera.meteringMode.systemImageName,
                    isActive: camera.meteringMode != .matrix,
                    width: isLandscape
                        ? railWidth
                        : (camera.meteringMode == .matrix ? 88 : 92),
                    railWidth: railWidth
                ) {
                    haptic.impactOccurred()
                    camera.cycleMeteringMode()
                }
        }

        if isLandscape {
            controls.frame(height: railWidth, alignment: .leading)
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                controls
            }
            .frame(height: L.proCapsuleHitHeight)
        }
    }

    private func proCapsule(
        title: String,
        systemName: String? = nil,
        isActive: Bool = false,
        width: CGFloat,
        railWidth: CGFloat,
        action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            let isLandscape = camera.cameraOrientation.isLandscape
            let capsuleHeight = L.proCapsuleHeight
            let hitHeight = isLandscape ? landscapeProCapsuleHitHeight : L.proCapsuleHitHeight
            let visualWidth = isLandscape ? min(width, railWidth) : width
            ZStack {
                HStack(spacing: 5) {
                    if !title.isEmpty {
                        Text(title)
                            .font(.system(size: isLandscape ? 11 : 12, weight: .semibold))
                            .kerning(0.6)
                            .lineLimit(1)
                            .minimumScaleFactor(0.72)
                    }

                    if let systemName {
                        Image(systemName: systemName)
                            .font(.system(size: title.isEmpty ? (isLandscape ? 16 : 15) : (isLandscape ? 10.5 : 11), weight: .semibold))
                    }
                }
            }
            .foregroundColor(isActive ? Theme.Colors.cream : Theme.Colors.bodyDark)
            .frame(width: visualWidth, height: capsuleHeight)
            .background(proCapsuleShape.fill(isActive ? Theme.Colors.bodyDark : Theme.Colors.buttonFill.opacity(0.92)))
            .overlay(proCapsuleShape.strokeBorder(Theme.Colors.bodyDark.opacity(isActive ? 1.0 : 0.58), lineWidth: 1.2))
            .frame(
                width: isLandscape ? railWidth : width,
                height: isLandscape ? railWidth : hitHeight
            )
            .contentShape(proCapsuleShape)
            .rotationEffect(iconRotation)
        }
        .buttonStyle(.plain)
    }

    private func landscapeHUDRailWidth(for hudWidth: CGFloat) -> CGFloat {
        let capsuleCount: CGFloat = 5
        let histogramCount: CGFloat = 1
        let capsuleSpacing = landscapeCapsuleSpacing
        let requiredSpacing = capsuleSpacing * (capsuleCount - 1)
        let available = hudWidth - landscapeHUDGroupGap - requiredSpacing
        let fitted = available / (capsuleCount + histogramCount)
        return min(54, max(44, fitted))
    }

    private var landscapeHUDGroupGap: CGFloat { 50 }

    private var landscapeCapsuleSpacing: CGFloat { 4 }

    private var landscapeProCapsuleHitHeight: CGFloat { 54 }

    private var proCapsuleShape: RoundedRectangle {
        RoundedRectangle(cornerRadius: L.proCapsuleCornerRadius, style: .continuous)
    }

    private func viewfinderBlock(viewfinderWidth vfWidth: CGFloat) -> some View {
        let selectedFormat = camera.selectedAspectFormat
        let vfHeight = max(1, vfWidth * selectedFormat.heightRatio)

        return ZStack {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.Colors.bodyDark, lineWidth: 1.5)
                .frame(width: vfWidth, height: vfHeight)

            RoundedRectangle(cornerRadius: 10)
                .fill(Color.black)
                .frame(width: max(1, vfWidth - 12), height: max(1, vfHeight - 12))
                .overlay(
                    PreviewView(
                        format: selectedFormat,
                        activeFilmProfile: camera.activeFilmProfile,
                        pendingFilmProfile: camera.pendingFilmProfile,
                        focalLength: camera.selectedFocalLength,
                        orientation: camera.cameraOrientation,
                        previewGeneration: camera.previewGeneration,
                        isPreviewTransitioning: camera.isPreviewTransitioning,
                        previewTransitionReason: camera.previewTransitionReason,
                        cameraManager: camera
                    )
                    .transaction { transaction in
                        transaction.animation = nil
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                )
                .overlay(
                    ZStack {
                        if gridMode.isActive {
                            GridGuideView(mode: gridMode)
                        }

                        if levelEnabled {
                            LevelGuideView(
                                rollDegrees: levelMotion.rollDegrees,
                                orientation: camera.cameraOrientation
                            )
                        }

                        ViewfinderCorners()
                        CrosshairView()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
                )
                .overlay(
                    Group {
                        if let permissionMessage = camera.permissionMessage, camera.permissionDenied {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.black.opacity(0.75))
                                .overlay(
                                    Text(permissionMessage)
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                )
                        }
                    }
                )
                .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .animation(aspectAnimation, value: selectedFormat)
        .frame(width: vfWidth, height: vfHeight, alignment: .center)
    }

    private func controlsBlock(width: CGFloat) -> some View {
        return ZStack(alignment: .center) {
            shutterButton
            leftButtons
                .frame(width: width, alignment: .leading)
                .offset(x: -(L.btnHitSize - L.btnSize) / 2)
                .offset(y: 0)
            rightButtons
                .frame(width: width, alignment: .trailing)
                .offset(x: (L.btnHitSize - L.aspectButtonWidth) / 2)
        }
        .frame(width: width)
        .animation(orientationUIAnimation, value: camera.cameraOrientation)
    }

    private var focalRow: some View {
        let focals = camera.availableFocalLengths.isEmpty ? [15, 28, 43, 85] : camera.availableFocalLengths
        let isLandscape = camera.cameraOrientation.isLandscape

        return HStack(alignment: .lastTextBaseline, spacing: isLandscape ? 8 : 12) {
            ForEach(focals, id: \.self) { mm in
                Button { switchFocal(to: mm) } label: {
                    let isSelected = mm == camera.selectedFocalLength
                    let selectedSize: CGFloat = isLandscape ? 25.2 : 33.3
                    let inactiveSize: CGFloat = isLandscape ? 17.8 : 21
                    let unitSize: CGFloat = isLandscape ? 10.8 : 13.5
                    let unitWidth: CGFloat = isLandscape ? 18 : 29
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(mm)")
                            .font(.system(size: isSelected ? selectedSize : inactiveSize, weight: isSelected ? .medium : .regular))
                            .foregroundColor(isSelected ? Theme.Colors.bodyDark : Theme.Colors.textMuted)
                        Text("mm")
                            .font(.system(size: unitSize, weight: .regular))
                            .foregroundColor(Theme.Colors.textSubtle)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: isSelected ? unitWidth : 0, alignment: .leading)
                            .clipped()
                            .opacity(isSelected ? 1 : 0)
                    }
                    .scaleEffect(isSelected ? 1.0 : 0.985)
                    .opacity(isSelected ? 1.0 : 0.95)
                    .rotationEffect(iconRotation)
                }
                .buttonStyle(.plain)
            }
        }
        .animation(selectionAnimation, value: camera.selectedFocalLength)
        .gesture(focalSwipeGesture)
    }

    private var focalRowOffset: CGSize {
        switch camera.cameraOrientation {
        case .portrait:
            return .zero
        case .landscapeLeft, .landscapeRight:
            return CGSize(width: 25, height: 0)
        }
    }

    private var gridCapsuleWidth: CGFloat {
        guard camera.cameraOrientation.isLandscape else { return gridMode.capsuleWidth }
        switch gridMode {
        case .center: return 50
        default: return 48
        }
    }

    private var leftButtons: some View {
        VStack(spacing: L.sideButtonSpacing) {
            Button {
                let next = !camera.flashEnabled
                camera.setFlashEnabled(next)
            } label: {
                Circle()
                    .fill(Theme.Colors.buttonFill)
                    .frame(width: L.btnSize, height: L.btnSize)
                    .overlay(Circle().strokeBorder(Theme.Colors.buttonBorder, lineWidth: 1))
                    .overlay(
                        Image(systemName: camera.flashEnabled ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 27.5, weight: .medium))
                            .foregroundColor(camera.flashEnabled ? Theme.Colors.bodyDark : Theme.Colors.textMuted)
                            .rotationEffect(iconRotation)
                    )
                    .frame(width: L.btnHitSize, height: L.btnHitSize)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)

            Button {
                toggleFilmProfile()
            } label: {
                filmProfileButton
                    .offset(y: -4)
            }
            .buttonStyle(.plain)
        }
        .animation(selectionAnimation, value: camera.flashEnabled)
        .animation(selectionAnimation, value: camera.activeFilmProfile)
        .animation(selectionAnimation, value: camera.pendingFilmProfile)
    }

    private var filmProfileButton: some View {
        let displayedProfile = camera.pendingFilmProfile ?? camera.activeFilmProfile
        let showsProcessedProfile = displayedProfile != .raw
        let isPendingProcessedProfile = camera.pendingFilmProfile != nil && showsProcessedProfile

        return ZStack {
            Circle()
                .fill(Theme.Colors.rawFill)
                .frame(width: L.btnSize, height: L.btnSize)
                .overlay(
                    Text(FilmProfile.raw.label)
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(Theme.Colors.cream)
                        .kerning(1.0)
                        .rotationEffect(iconRotation)
                )
                .opacity(showsProcessedProfile ? 0 : 1)

            Circle()
                .fill(Theme.Colors.cream.opacity(isPendingProcessedProfile ? 0.65 : 1.0))
                .frame(width: L.btnSize, height: L.btnSize)
                .overlay(Circle().strokeBorder(Theme.Colors.bodyDark, lineWidth: 2))
                .overlay(
                    Text(filmProfileButtonTitle)
                        .font(.system(size: isPendingProcessedProfile ? 19 : 22, weight: .medium))
                        .foregroundColor(Theme.Colors.bodyDark)
                        .kerning(0.5)
                        .rotationEffect(iconRotation)
                )
                .opacity(showsProcessedProfile ? 1 : 0)
        }
        .frame(width: L.btnHitSize, height: L.btnHitSize)
        .contentShape(Circle())
        .animation(selectionAnimation, value: camera.activeFilmProfile)
        .animation(selectionAnimation, value: camera.pendingFilmProfile)
    }

    private var shutterButton: some View {
        let isLandscape = camera.cameraOrientation.isLandscape
        let shutterOuter = isLandscape ? L.shutterOuter * 0.90 : L.shutterOuter
        let shutterInner = isLandscape ? L.shutterInner * 0.90 : L.shutterInner

        return Button {
            guard camera.isSessionRunning else { return }
            shutterProgress = 0
            withAnimation(.linear(duration: 0.6)) {
                shutterProgress = 1
            }
            Task {
                await camera.capture()
            }
        } label: {
            ZStack {
                Circle()
                    .fill(Color.clear)
                    .frame(width: L.shutterHitSize, height: L.shutterHitSize)

                Circle()
                    .strokeBorder(Theme.Colors.bodyDark.opacity(0.25), lineWidth: 2.5)
                    .frame(width: shutterOuter, height: shutterOuter)

                Circle()
                    .trim(from: 0, to: shutterProgress)
                    .stroke(
                        Theme.Colors.bodyDark,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: shutterOuter, height: shutterOuter)
                    .rotationEffect(.degrees(-90))

                Circle()
                    .fill(Theme.Colors.bodyDark)
                    .frame(width: shutterInner, height: shutterInner)
            }
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
    }

    private var rightButtons: some View {
        Button {
            switchFormat(to: camera.selectedAspectFormat.next())
        } label: {
            Text(camera.selectedAspectFormat.label)
                .font(.system(size: 20, weight: .medium))
                .foregroundColor(Theme.Colors.bodyDark)
                .frame(width: L.aspectButtonWidth, height: L.aspectButtonHeight)
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .strokeBorder(Theme.Colors.bodyDark, lineWidth: 1.5)
                )
                .rotationEffect(iconRotation)
        }
        .buttonStyle(.plain)
        .frame(width: L.btnHitSize, height: L.btnHitSize)
        .contentShape(Rectangle())
        .gesture(formatSwipeGesture)
        .animation(aspectAnimation, value: camera.selectedAspectFormat)
    }

    private var focalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let focals = camera.availableFocalLengths.isEmpty ? [15, 28, 43, 85] : camera.availableFocalLengths
                let steps = Int((-value.translation.width) / L.swipeThreshold)
                guard steps != 0 else { return }
                let idx = focals.firstIndex(of: camera.selectedFocalLength) ?? 1
                let newIdx = (idx + steps).clamped(to: 0...(focals.count - 1))
                if focals[newIdx] != camera.selectedFocalLength {
                    switchFocal(to: focals[newIdx])
                }
            }
    }

    private var formatSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dx = value.translation.width
                let dy = value.translation.height
                let dominant = abs(dx) > abs(dy) ? dx : -dy
                let steps = Int(dominant / L.swipeThreshold)
                guard steps != 0 else { return }
                let all = AspectFormat.standardCases
                let idx = all.firstIndex(of: camera.selectedAspectFormat) ?? 0
                let newIdx = (idx + steps).clamped(to: 0...(all.count - 1))
                if all[newIdx] != camera.selectedAspectFormat {
                    switchFormat(to: all[newIdx])
                }
            }
    }

    private func switchFocal(to mm: Int) {
        haptic.impactOccurred()
        camera.setFocalLength(mm)
    }

    private func switchFormat(to format: AspectFormat) {
        guard format != camera.selectedAspectFormat else { return }
        haptic.impactOccurred()
        camera.setAspectFormat(format)
    }

    private func toggleFilmProfile() {
        haptic.impactOccurred()
        let displayedProfile = camera.pendingFilmProfile ?? camera.activeFilmProfile
        switch displayedProfile {
        case .raw:
            camera.requestFilmProfile(.vg)
        case .vg:
            camera.requestFilmProfile(.ew)
        case .ew:
            camera.requestFilmProfile(.lg)
        case .lg:
            camera.requestFilmProfile(.raw)
        }
    }
}

struct ViewfinderCorners: View {
    let size: CGFloat = 18
    let lineWidth: CGFloat = 1.5
    let color = Color.white.opacity(0.35)
    let inset: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            let w = geo.size.width
            let h = geo.size.height
            ZStack {
                Path { p in
                    p.move(to: CGPoint(x: inset, y: inset + size))
                    p.addLine(to: CGPoint(x: inset, y: inset))
                    p.addLine(to: CGPoint(x: inset + size, y: inset))
                }.stroke(color, lineWidth: lineWidth)
                Path { p in
                    p.move(to: CGPoint(x: w - inset - size, y: inset))
                    p.addLine(to: CGPoint(x: w - inset, y: inset))
                    p.addLine(to: CGPoint(x: w - inset, y: inset + size))
                }.stroke(color, lineWidth: lineWidth)
                Path { p in
                    p.move(to: CGPoint(x: inset, y: h - inset - size))
                    p.addLine(to: CGPoint(x: inset, y: h - inset))
                    p.addLine(to: CGPoint(x: inset + size, y: h - inset))
                }.stroke(color, lineWidth: lineWidth)
                Path { p in
                    p.move(to: CGPoint(x: w - inset - size, y: h - inset))
                    p.addLine(to: CGPoint(x: w - inset, y: h - inset))
                    p.addLine(to: CGPoint(x: w - inset, y: h - inset - size))
                }.stroke(color, lineWidth: lineWidth)
            }
        }
    }
}

struct CrosshairView: View {
    let size: CGFloat = 26
    let lineWidth: CGFloat = 1.5
    let color = Color.white.opacity(0.38)

    var body: some View {
        ZStack {
            Rectangle().fill(color).frame(width: size, height: lineWidth)
            Rectangle().fill(color).frame(width: lineWidth, height: size)
        }
    }
}

@MainActor
private final class LevelMotionModel: ObservableObject {
    @Published var rollDegrees: Double = 0

    private let motionManager = CMMotionManager()
    private let motionQueue = OperationQueue()

    func start() {
        guard motionManager.isDeviceMotionAvailable else { return }
        motionManager.deviceMotionUpdateInterval = 1.0 / 30.0
        motionManager.startDeviceMotionUpdates(to: motionQueue) { [weak self] motion, _ in
            guard let motion else { return }
            let roll = Self.rollDegrees(from: motion.gravity)
            Task { @MainActor in
                self?.rollDegrees = roll
            }
        }
    }

    func stop() {
        motionManager.stopDeviceMotionUpdates()
    }

    private static func rollDegrees(from gravity: CMAcceleration) -> Double {
        let raw = atan2(gravity.x, -gravity.y) * 180.0 / Double.pi
        let nearestRightAngle = (raw / 90.0).rounded() * 90.0
        var normalized = raw - nearestRightAngle

        if normalized > 45 {
            normalized -= 90
        } else if normalized < -45 {
            normalized += 90
        }

        return normalized
    }
}

private struct MiniHistogramView: View {
    let mode: HistogramDisplayMode
    let samples: [CGFloat]

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let inset: CGFloat = 6
            let drawWidth = max(1, width - inset * 2)
            let drawHeight = max(1, height - inset * 2)

            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Theme.Colors.buttonFill.opacity(0.92))
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Theme.Colors.bodyDark.opacity(0.58), lineWidth: 1.2)

                Path { path in
                    path.move(to: CGPoint(x: inset, y: height * 0.33))
                    path.addLine(to: CGPoint(x: width - inset, y: height * 0.33))
                    path.move(to: CGPoint(x: inset, y: height * 0.66))
                    path.addLine(to: CGPoint(x: width - inset, y: height * 0.66))
                }
                .stroke(Theme.Colors.bodyDark.opacity(0.12), lineWidth: 1)

                if mode == .waveform {
                    Path { path in
                        for index in displayedSamples.indices {
                            let progress = CGFloat(index) / CGFloat(max(1, displayedSamples.count - 1))
                            let point = CGPoint(
                                x: inset + drawWidth * progress,
                                y: inset + drawHeight * (1.0 - displayedSamples[index])
                            )
                            if index == samples.startIndex {
                                path.move(to: point)
                            } else {
                                path.addLine(to: point)
                            }
                        }
                    }
                    .stroke(
                        Theme.Colors.bodyDark,
                        style: StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
                    )
                } else {
                    HStack(alignment: .bottom, spacing: 2) {
                        ForEach(displayedSamples.indices, id: \.self) { index in
                            Capsule()
                                .fill(Theme.Colors.bodyDark.opacity(0.86))
                                .frame(height: max(4, drawHeight * displayedSamples[index]))
                        }
                    }
                    .padding(.horizontal, inset)
                    .padding(.vertical, inset)
                }
            }
        }
    }

    private var displayedSamples: [CGFloat] {
        samples.isEmpty ? CameraManager.defaultHistogramSamples : samples
    }
}

private struct GridGuideView: View {
    let mode: GridGuideMode

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            ZStack {
                if mode == .thirds {
                    guidePath(width: width, height: height, ratios: [1.0 / 3.0, 2.0 / 3.0])
                        .stroke(
                            Color.white.opacity(0.52),
                            style: StrokeStyle(lineWidth: 1.9, lineCap: .round)
                        )
                } else if mode == .diagonal {
                    diagonalGuidePath(width: width, height: height)
                        .stroke(
                            Color.white.opacity(0.50),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round)
                        )
                } else if mode == .center {
                    centerGuidePath(width: width, height: height)
                        .stroke(
                            Color.white.opacity(0.56),
                            style: StrokeStyle(lineWidth: 1.9, lineCap: .round)
                        )
                } else if mode == .frame {
                    frameGuidePath(width: width, height: height)
                        .stroke(
                            Color.white.opacity(0.54),
                            style: StrokeStyle(lineWidth: 1.8, lineCap: .round, lineJoin: .round)
                        )
                }
            }
            .shadow(color: .black.opacity(0.26), radius: 1.5, x: 0, y: 0.5)
        }
        .allowsHitTesting(false)
    }

    private func guidePath(width: CGFloat, height: CGFloat, ratios: [CGFloat]) -> Path {
        Path { path in
            for ratio in ratios {
                let x = width * ratio
                path.move(to: CGPoint(x: x, y: 0))
                path.addLine(to: CGPoint(x: x, y: height))

                let y = height * ratio
                path.move(to: CGPoint(x: 0, y: y))
                path.addLine(to: CGPoint(x: width, y: y))
            }
        }
    }

    private func diagonalGuidePath(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: width, y: height))
            path.move(to: CGPoint(x: width, y: 0))
            path.addLine(to: CGPoint(x: 0, y: height))

            path.move(to: CGPoint(x: width * 0.5, y: 0))
            path.addLine(to: CGPoint(x: width, y: height * 0.5))
            path.move(to: CGPoint(x: width * 0.5, y: height))
            path.addLine(to: CGPoint(x: 0, y: height * 0.5))
        }
    }

    private func centerGuidePath(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            let center = CGPoint(x: width / 2, y: height / 2)
            let longTick = min(width, height) * 0.16
            let shortTick = min(width, height) * 0.045
            path.move(to: CGPoint(x: center.x - longTick, y: center.y))
            path.addLine(to: CGPoint(x: center.x - shortTick, y: center.y))
            path.move(to: CGPoint(x: center.x + shortTick, y: center.y))
            path.addLine(to: CGPoint(x: center.x + longTick, y: center.y))
            path.move(to: CGPoint(x: center.x, y: center.y - longTick))
            path.addLine(to: CGPoint(x: center.x, y: center.y - shortTick))
            path.move(to: CGPoint(x: center.x, y: center.y + shortTick))
            path.addLine(to: CGPoint(x: center.x, y: center.y + longTick))

            let inner = CGRect(
                x: width * 0.22,
                y: height * 0.22,
                width: width * 0.56,
                height: height * 0.56
            )
            path.addRoundedRect(in: inner, cornerSize: CGSize(width: 10, height: 10))
        }
    }

    private func frameGuidePath(width: CGFloat, height: CGFloat) -> Path {
        Path { path in
            let safe = CGRect(
                x: width * 0.08,
                y: height * 0.08,
                width: width * 0.84,
                height: height * 0.84
            )
            let inner = CGRect(
                x: width * 0.16,
                y: height * 0.16,
                width: width * 0.68,
                height: height * 0.68
            )
            path.addRoundedRect(in: safe, cornerSize: CGSize(width: 12, height: 12))
            path.addRoundedRect(in: inner, cornerSize: CGSize(width: 9, height: 9))
        }
    }
}

private struct LevelGuideView: View {
    let rollDegrees: Double
    let orientation: CameraOrientationState

    var body: some View {
        GeometryReader { geo in
            let width = geo.size.width
            let height = geo.size.height
            let centerY = height / 2.0
            let isLevel = abs(rollDegrees) < 1.0
            let guideColor = isLevel ? Color.green.opacity(0.92) : Color.white.opacity(0.72)
            let referenceColor = Color.white.opacity(0.22)
            let baseRotation = Double(orientation.uiRotationAngle)

            ZStack {
                Path { path in
                    path.move(to: CGPoint(x: width * 0.18, y: centerY))
                    path.addLine(to: CGPoint(x: width * 0.82, y: centerY))
                }
                .stroke(referenceColor, style: StrokeStyle(lineWidth: 1.4, lineCap: .round, dash: [6, 8]))
                .rotationEffect(.degrees(baseRotation), anchor: .center)

                Path { path in
                    path.move(to: CGPoint(x: width * 0.17, y: centerY))
                    path.addLine(to: CGPoint(x: width * 0.44, y: centerY))
                    path.move(to: CGPoint(x: width * 0.56, y: centerY))
                    path.addLine(to: CGPoint(x: width * 0.83, y: centerY))
                }
                .stroke(
                    guideColor,
                    style: StrokeStyle(lineWidth: isLevel ? 4.2 : 3.2, lineCap: .round)
                )
                .rotationEffect(.degrees(baseRotation + rollDegrees), anchor: .center)
                .shadow(color: .black.opacity(0.35), radius: 3, x: 0, y: 1)

                RoundedRectangle(cornerRadius: 2.5)
                    .fill(guideColor)
                    .frame(width: isLevel ? 18 : 14, height: isLevel ? 5 : 4)
                    .position(x: width / 2.0, y: centerY)
                    .rotationEffect(.degrees(baseRotation), anchor: .center)
                    .shadow(color: .black.opacity(0.30), radius: 2, x: 0, y: 1)
            }
        }
        .allowsHitTesting(false)
    }
}

extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
