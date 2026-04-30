import SwiftUI

private typealias L = Theme.Layout

struct ContentView: View {

    @EnvironmentObject private var camera: CameraManager
    @State private var shutterProgress: CGFloat = 0

    private let focals = [21, 35, 50, 105]
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)
    private let orientationUIAnimation = Animation.linear(duration: 0.14)
    private let selectionAnimation = Animation.linear(duration: 0.12)
    private let aspectAnimation = Animation.linear(duration: 0.16)

    private var iconRotation: Angle {
        camera.cameraOrientation.isLandscape ? .degrees(90) : .degrees(0)
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

            ZStack {
                Theme.Colors.background.ignoresSafeArea()

                VStack(spacing: 0) {
                    viewfinderBlock(screenWidth: sw, screenHeight: sh, safeTop: safe.top)
                    Spacer(minLength: 0)
                    controlsBlock
                }
                .offset(y: -35)
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onAppear {
            UIDevice.current.beginGeneratingDeviceOrientationNotifications()
            camera.updateCameraOrientation(UIDevice.current.orientation)
        }
        .onDisappear {
            UIDevice.current.endGeneratingDeviceOrientationNotifications()
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

    private func viewfinderBlock(
        screenWidth sw: CGFloat,
        screenHeight sh: CGFloat,
        safeTop: CGFloat
    ) -> some View {
        let selectedFormat = camera.selectedAspectFormat
        let vfWidth = max(1, sw - L.vfHPad * 2)
        let maxH = vfWidth * AspectFormat.twoToThree.heightRatio
        let containerH = maxH + L.vfTopOffset + 20
        let vfHeight = max(1, vfWidth * selectedFormat.heightRatio)

        let twoRowsH: CGFloat = L.btnSize * 2 + 18
        let focalRowH: CGFloat = 44
        let controlsH: CGFloat = (L.controlsBottomPad + L.controlsExtraDown)
            + twoRowsH + L.focalToButtons + focalRowH
        let focalRowTop = sh - controlsH + 35
        let islandBottom = safeTop
        let availableH = focalRowTop - islandBottom
        let squareCentreY = islandBottom + availableH / 2
        let containerTopInScreen = islandBottom - 35
        let squareOffsetY = squareCentreY - (containerTopInScreen + containerH / 2)

        let vOffset: CGFloat = {
            switch selectedFormat {
            case .square: return squareOffsetY
            default:      return selectedFormat.verticalOffset(forWidth: vfWidth)
            }
        }()

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
        }
        .offset(y: vOffset)
        .animation(aspectAnimation, value: selectedFormat)
        .frame(width: sw, height: containerH)
        .padding(.top, L.vfTopOffset)
    }

    private var controlsBlock: some View {
        VStack(spacing: 0) {
            focalRow
                .padding(.bottom, L.focalToButtons + 10)
                .offset(y: -10)

            ZStack(alignment: .center) {
                shutterButton
                HStack(alignment: .bottom, spacing: 0) {
                    leftButtons
                    Spacer()
                    rightButtons
                }
            }
            .offset(y: -20)
            .padding(.horizontal, L.vfHPad)
        }
        .padding(.bottom, L.controlsBottomPad + L.controlsExtraDown)
        .animation(orientationUIAnimation, value: camera.cameraOrientation)
    }

    private var focalRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 14) {
            ForEach(focals, id: \.self) { mm in
                Button { switchFocal(to: mm) } label: {
                    let isSelected = mm == camera.selectedFocalLength
                    HStack(alignment: .lastTextBaseline, spacing: 2) {
                        Text("\(mm)")
                            .font(.system(size: isSelected ? 36 : 20, weight: isSelected ? .medium : .regular))
                            .foregroundColor(isSelected ? Theme.Colors.bodyDark : Theme.Colors.textMuted)
                        Text("mm")
                            .font(.system(size: 15, weight: .regular))
                            .foregroundColor(Theme.Colors.textSubtle)
                            .lineLimit(1)
                            .fixedSize(horizontal: true, vertical: false)
                            .frame(width: isSelected ? 30 : 0, alignment: .leading)
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

    private var leftButtons: some View {
        VStack(spacing: 18) {
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
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(camera.flashEnabled ? Theme.Colors.bodyDark : Theme.Colors.textMuted)
                            .rotationEffect(iconRotation)
                    )
            }
            .buttonStyle(.plain)

            Button {
                toggleFilmProfile()
            } label: {
                filmProfileButton
            }
            .buttonStyle(.plain)
        }
        .offset(y: -15)
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
                    Text("raw")
                        .font(.system(size: 19, weight: .medium))
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
                        .font(.system(size: isPendingProcessedProfile ? 18 : 21, weight: .medium))
                        .foregroundColor(Theme.Colors.bodyDark)
                        .kerning(0.5)
                        .rotationEffect(iconRotation)
                )
                .opacity(showsProcessedProfile ? 1 : 0)
        }
        .animation(selectionAnimation, value: camera.activeFilmProfile)
        .animation(selectionAnimation, value: camera.pendingFilmProfile)
    }

    private var shutterButton: some View {
        Button {
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
                    .frame(width: L.shutterOuter, height: L.shutterOuter)

                Circle()
                    .strokeBorder(Theme.Colors.bodyDark.opacity(0.25), lineWidth: 2.5)
                    .frame(width: L.shutterOuter * 0.9, height: L.shutterOuter * 0.9)

                Circle()
                    .trim(from: 0, to: shutterProgress)
                    .stroke(
                        Theme.Colors.bodyDark,
                        style: StrokeStyle(lineWidth: 2.5, lineCap: .round)
                    )
                    .frame(width: L.shutterOuter * 0.9, height: L.shutterOuter * 0.9)
                    .rotationEffect(.degrees(-90))

                Circle()
                    .fill(Theme.Colors.bodyDark)
                    .frame(width: L.shutterInner * 0.9, height: L.shutterInner * 0.9)
            }
        }
        .buttonStyle(.plain)
        .offset(y: -15)
    }

    private var rightButtons: some View {
        VStack(spacing: 18) {
            Color.clear.frame(width: L.btnSize, height: L.btnSize)

            Button {
                switchFormat(to: camera.selectedAspectFormat.next())
            } label: {
                Text(camera.selectedAspectFormat.label)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Theme.Colors.bodyDark)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.bodyDark, lineWidth: 1.5)
                    )
                    .rotationEffect(iconRotation)
            }
            .buttonStyle(.plain)
            .offset(y: -L.formatUpLift)
            .gesture(formatSwipeGesture)
        }
        .animation(aspectAnimation, value: camera.selectedAspectFormat)
    }

    private var focalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
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
                let all = AspectFormat.allCases
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

extension Comparable {
    nonisolated func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
