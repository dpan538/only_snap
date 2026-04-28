import SwiftUI

private typealias L = Theme.Layout

struct ContentView: View {

    // MARK: - Camera
    @EnvironmentObject private var camera: CameraManager

    // MARK: - UI State
    @State private var selectedFocal: Int           = 35
    @State private var flashOn: Bool                = false
    @State private var experimentalColor: Bool      = false
    @State private var selectedFormat: AspectFormat = .threeToFour
    @State private var shutterProgress: CGFloat      = 0

    private let focals = [21, 35, 50, 105]
    private let haptic = UIImpactFeedbackGenerator(style: .rigid)

    // MARK: - Body
    var body: some View {
        GeometryReader { screen in
            let sw   = screen.size.width
            let sh   = screen.size.height
            let safe = screen.safeAreaInsets
            let isLandscape = sw > sh

            ZStack {
                Theme.Colors.background.ignoresSafeArea()
                if isLandscape {
                    landscapeLayout(sw: sw, sh: sh, safe: safe)
                } else {
                    VStack(spacing: 0) {
                        viewfinderBlock(
                            screenWidth: sw,
                            screenHeight: sh,
                            safeTop: safe.top
                        )
                        Spacer(minLength: 0)
                        controlsBlock
                    }
                    .offset(y: -35)
                }
            }
        }
        .ignoresSafeArea(edges: .bottom)
        .onDisappear {
            camera.stop()
        }
    }

    // MARK: - Viewfinder
    private func viewfinderBlock(
        screenWidth sw: CGFloat,
        screenHeight sh: CGFloat,
        safeTop: CGFloat
    ) -> some View {
        // Clamp to 1 pt minimum — GeometryReader can deliver zero on its very first
        // layout pass (before the window has real dimensions).  A negative or zero vfWidth
        // produces negative frame values that trigger SwiftUI's "Invalid frame dimension"
        // runtime warning and propagate a non-positive bounds to PreviewView's UIView.
        let vfWidth    = max(1, sw - L.vfHPad * 2)
        let maxH       = vfWidth * AspectFormat.twoToThree.heightRatio
        let containerH = maxH + L.vfTopOffset + 20
        let vfHeight   = max(1, vfWidth * selectedFormat.heightRatio)

        let twoRowsH: CGFloat  = L.btnSize * 2 + 18
        let focalRowH: CGFloat = 44
        let controlsH: CGFloat = (L.controlsBottomPad + L.controlsExtraDown)
                                  + twoRowsH + L.focalToButtons + focalRowH
        let focalRowTop        = sh - controlsH + 35
        let islandBottom       = safeTop
        let availableH         = focalRowTop - islandBottom
        let squareCentreY      = islandBottom + availableH / 2
        let containerTopInScreen = islandBottom - 35
        let squareOffsetY      = squareCentreY - (containerTopInScreen + containerH / 2)

        let vOffset: CGFloat = {
            switch selectedFormat {
            case .square: return squareOffsetY
            default:      return selectedFormat.verticalOffset(forWidth: vfWidth)
            }
        }()

        return ZStack {
            // Outer border
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Theme.Colors.bodyDark, lineWidth: 1.5)
                .frame(width: vfWidth, height: vfHeight)

            // Live preview + fallback background
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.viewfinderBg)
                .frame(width: max(1, vfWidth - 12), height: max(1, vfHeight - 12))
                .overlay(
                    PreviewView(session: camera.session,
                                format: selectedFormat,
                                isSessionRunning: camera.isSessionRunning,
                                ryEnabled: experimentalColor,
                                isLandscape: false,
                                cameraManager: camera)
                        .clipShape(RoundedRectangle(cornerRadius: 10))
                )
                .overlay(
                    // Corner guides and crosshair sit above the preview, non-interactive
                    ZStack {
                        ViewfinderCorners()
                        CrosshairView()
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .allowsHitTesting(false)
                )
                // Permission denied overlay
                .overlay(
                    Group {
                        if camera.permissionDenied {
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color.black.opacity(0.75))
                                .overlay(
                                    Text("Camera access required")
                                        .font(.system(size: 14, weight: .medium))
                                        .foregroundColor(.white)
                                )
                        }
                    }
                )
        }
        .offset(y: vOffset)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: selectedFormat)
        .frame(width: sw, height: containerH)
        .padding(.top, L.vfTopOffset)
    }

    // MARK: - Controls
    private var controlsBlock: some View {
        VStack(spacing: 0) {
            focalRow
                .padding(.bottom, L.focalToButtons + 10)

            ZStack(alignment: .center) {
                shutterButton
                HStack(alignment: .bottom, spacing: 0) {
                    leftButtons
                    Spacer()
                    rightButtons
                }
            }
            .padding(.horizontal, L.vfHPad)
        }
        .padding(.bottom, L.controlsBottomPad + L.controlsExtraDown)
    }

    // MARK: - Focal Row
    private var focalRow: some View {
        HStack(alignment: .lastTextBaseline, spacing: 22) {
            ForEach(focals, id: \.self) { mm in
                Button { switchFocal(to: mm) } label: {
                    if mm == selectedFocal {
                        HStack(alignment: .lastTextBaseline, spacing: 2) {
                            Text("\(mm)")
                                .font(.system(size: 36, weight: .medium))
                                .foregroundColor(Theme.Colors.bodyDark)
                            Text("mm")
                                .font(.system(size: 15, weight: .regular))
                                .foregroundColor(Theme.Colors.textSubtle)
                        }
                    } else {
                        Text("\(mm)")
                            .font(.system(size: 20, weight: .regular))
                            .foregroundColor(Theme.Colors.textMuted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .gesture(focalSwipeGesture)
    }

    // MARK: - Left Buttons
    private var leftButtons: some View {
        VStack(spacing: 18) {

            // Flash
            Button {
                flashOn.toggle()
                camera.setFlash(flashOn)
            } label: {
                Circle()
                    .fill(Theme.Colors.buttonFill)
                    .frame(width: L.btnSize, height: L.btnSize)
                    .overlay(Circle().strokeBorder(Theme.Colors.buttonBorder, lineWidth: 1))
                    .overlay(
                        Image(systemName: flashOn ? "bolt.fill" : "bolt.slash.fill")
                            .font(.system(size: 26, weight: .medium))
                            .foregroundColor(flashOn ? Theme.Colors.bodyDark : Theme.Colors.textMuted)
                    )
            }
            .buttonStyle(.plain)

            // Experimental color
            Button {
                withAnimation(.easeInOut(duration: 0.18)) { experimentalColor.toggle() }
            } label: {
                expColorButton
            }
            .buttonStyle(.plain)
        }
        .offset(y: -15)
    }

    @ViewBuilder
    private var expColorButton: some View {
        if experimentalColor {
            Circle()
                .fill(Theme.Colors.cream)
                .frame(width: L.btnSize, height: L.btnSize)
                .overlay(Circle().strokeBorder(Theme.Colors.bodyDark, lineWidth: 2))
                .overlay(
                    Text("RY")
                        .font(.system(size: 21, weight: .medium))
                        .foregroundColor(Theme.Colors.bodyDark)
                        .kerning(0.5)
                )
        } else {
            Circle()
                .fill(Theme.Colors.rawFill)
                .frame(width: L.btnSize, height: L.btnSize)
                .overlay(
                    Text("raw")
                        .font(.system(size: 19, weight: .medium))
                        .foregroundColor(Theme.Colors.cream)
                        .kerning(1.0)
                )
        }
    }

    // MARK: - Shutter
    private var shutterButton: some View {
        Button {
            guard camera.isSessionRunning else { return }
            // Reset and trigger arc animation
            shutterProgress = 0
            withAnimation(.linear(duration: 0.6)) {
                shutterProgress = 1
            }
            Task {
                await camera.capture(
                    format: selectedFormat,
                    experimentalColor: experimentalColor
                )
            }
        } label: {
            ZStack {
                // Invisible tap-target — preserves original hit area
                Circle()
                    .fill(Color.clear)
                    .frame(width: L.shutterOuter, height: L.shutterOuter)

                // Static outer ring (−10% visual)
                Circle()
                    .strokeBorder(Theme.Colors.bodyDark.opacity(0.25), lineWidth: 2.5)
                    .frame(width: L.shutterOuter * 0.9, height: L.shutterOuter * 0.9)

                // Animated arc (−10% visual)
                Circle()
                    .trim(from: 0, to: shutterProgress)
                    .stroke(Theme.Colors.bodyDark, style: StrokeStyle(lineWidth: 2.5, lineCap: .round))
                    .frame(width: L.shutterOuter * 0.9, height: L.shutterOuter * 0.9)
                    .rotationEffect(.degrees(-90))

                // Inner filled circle (−10% visual)
                Circle()
                    .fill(Theme.Colors.bodyDark)
                    .frame(width: L.shutterInner * 0.9, height: L.shutterInner * 0.9)
            }
        }
        .buttonStyle(.plain)
        .offset(y: -15)
    }

    // MARK: - Right Buttons
    private var rightButtons: some View {
        VStack(spacing: 18) {
            Color.clear.frame(width: L.btnSize, height: L.btnSize)

            Button { switchFormat(to: selectedFormat.next()) } label: {
                Text(selectedFormat.label)
                    .font(.system(size: 20, weight: .medium))
                    .foregroundColor(Theme.Colors.bodyDark)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 10)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Theme.Colors.bodyDark, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .offset(y: -L.formatUpLift)
            .gesture(formatSwipeGesture)
        }
    }

    // MARK: - Gestures (Portrait)
    private var focalSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let steps = Int((-value.translation.width) / L.swipeThreshold)
                guard steps != 0 else { return }
                let idx    = focals.firstIndex(of: selectedFocal) ?? 1
                let newIdx = (idx + steps).clamped(to: 0...(focals.count - 1))
                if focals[newIdx] != selectedFocal { switchFocal(to: focals[newIdx]) }
            }
    }

    private var formatSwipeGesture: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let dx       = value.translation.width
                let dy       = value.translation.height
                let dominant = abs(dx) > abs(dy) ? dx : -dy
                let steps    = Int(dominant / L.swipeThreshold)
                guard steps != 0 else { return }
                let all    = AspectFormat.allCases
                let idx    = all.firstIndex(of: selectedFormat)!
                let newIdx = (idx + steps).clamped(to: 0...(all.count - 1))
                if all[newIdx] != selectedFormat { switchFormat(to: all[newIdx]) }
            }
    }

    // MARK: - Gestures (Landscape)

    /// Vertical drag on the focal column: swipe up → higher focal (105); swipe down → lower (21).
    private var focalSwipeGestureVertical: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let steps = Int((-value.translation.height) / L.swipeThreshold)
                guard steps != 0 else { return }
                let idx    = focals.firstIndex(of: selectedFocal) ?? 1
                let newIdx = (idx + steps).clamped(to: 0...(focals.count - 1))
                if focals[newIdx] != selectedFocal { switchFocal(to: focals[newIdx]) }
            }
    }

    /// Vertical drag on the format button: swipe up → next format; swipe down → previous.
    private var formatSwipeGestureLandscape: some Gesture {
        DragGesture(minimumDistance: 10)
            .onChanged { value in
                let steps = Int((-value.translation.height) / L.swipeThreshold)
                guard steps != 0 else { return }
                let all    = AspectFormat.allCases
                let idx    = all.firstIndex(of: selectedFormat)!
                let newIdx = (idx + steps).clamped(to: 0...(all.count - 1))
                if all[newIdx] != selectedFormat { switchFormat(to: all[newIdx]) }
            }
    }

    // MARK: - Landscape Layout

    @ViewBuilder
    private func landscapeLayout(sw: CGFloat, sh: CGFloat, safe: EdgeInsets) -> some View {
        let leadPad  = max(safe.leading, 6)
        let trailPad = max(safe.trailing, 6)
        let stripW   = L.lsStripWidth
        let vfW      = sw - leadPad - trailPad - stripW

        HStack(spacing: 0) {
            // Leading safe-area gap (notch / Dynamic Island side)
            Spacer().frame(width: leadPad, height: sh)

            // Viewfinder — explicit pixel dimensions
            lsViewfinderBlock(w: vfW, h: sh)

            // Controls strip — explicit size + cream background so it's never transparent
            landscapeControlsStrip(safeBottom: safe.bottom)
                .frame(width: stripW, height: sh)
                .background(Theme.Colors.background)

            // Trailing safe-area gap (home-indicator side)
            Spacer().frame(width: trailPad, height: sh)
        }
        .frame(width: sw, height: sh)
    }

    private func lsViewfinderBlock(w: CGFloat, h: CGFloat) -> some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10)
                .fill(Theme.Colors.viewfinderBg)
            PreviewView(session: camera.session,
                        format: selectedFormat,
                        isSessionRunning: camera.isSessionRunning,
                        ryEnabled: experimentalColor,
                        isLandscape: true,
                        cameraManager: camera)
                .clipShape(RoundedRectangle(cornerRadius: 10))
            ZStack {
                ViewfinderCorners()
                CrosshairView()
            }
            .clipShape(RoundedRectangle(cornerRadius: 10))
            .allowsHitTesting(false)
            if camera.permissionDenied {
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.black.opacity(0.75))
                    .overlay(
                        Text("Camera access required")
                            .font(.system(size: 14, weight: .medium))
                            .foregroundColor(.white)
                    )
            }
        }
        // Inner content with 6 pt inset; outer frame provides layout size
        .frame(width: w - 12, height: h - 12)
        .frame(width: w, height: h)
    }

    @ViewBuilder
    private func landscapeControlsStrip(safeBottom: CGFloat) -> some View {
        VStack(spacing: 0) {

            // ── Format (top) ─────────────────────────────────────────────────
            Button { switchFormat(to: selectedFormat.next()) } label: {
                Text(selectedFormat.label)
                    .font(.system(size: 15, weight: .medium))
                    .foregroundColor(Theme.Colors.bodyDark)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 5)
                    .overlay(
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.Colors.bodyDark, lineWidth: 1.5)
                    )
            }
            .buttonStyle(.plain)
            .gesture(formatSwipeGestureLandscape)
            .padding(.top, L.lsVPad)

            Spacer()

            // ── Focal column: 105 at top → 21 at bottom ──────────────────────
            VStack(alignment: .center, spacing: 9) {
                ForEach(focals.reversed(), id: \.self) { mm in
                    Button { switchFocal(to: mm) } label: {
                        if mm == selectedFocal {
                            HStack(alignment: .lastTextBaseline, spacing: 2) {
                                Text("\(mm)")
                                    .font(.system(size: 22, weight: .medium))
                                    .foregroundColor(Theme.Colors.bodyDark)
                                Text("mm")
                                    .font(.system(size: 9, weight: .regular))
                                    .foregroundColor(Theme.Colors.textSubtle)
                            }
                        } else {
                            Text("\(mm)")
                                .font(.system(size: 16, weight: .regular))
                                .foregroundColor(Theme.Colors.textMuted)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
            .gesture(focalSwipeGestureVertical)

            Spacer()

            // ── Shutter ───────────────────────────────────────────────────────
            Button {
                guard camera.isSessionRunning else { return }
                shutterProgress = 0
                withAnimation(.linear(duration: 0.6)) { shutterProgress = 1 }
                Task {
                    await camera.capture(format: selectedFormat,
                                         experimentalColor: experimentalColor)
                }
            } label: {
                ZStack {
                    // Invisible tap-target — preserves original hit area
                    Circle()
                        .fill(Color.clear)
                        .frame(width: L.lsShutterOuter, height: L.lsShutterOuter)
                    // Visual outer ring (−10%)
                    Circle()
                        .strokeBorder(Theme.Colors.bodyDark.opacity(0.25), lineWidth: 2)
                        .frame(width: L.lsShutterOuter * 0.9, height: L.lsShutterOuter * 0.9)
                    // Animated arc (−10%)
                    Circle()
                        .trim(from: 0, to: shutterProgress)
                        .stroke(Theme.Colors.bodyDark,
                                style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: L.lsShutterOuter * 0.9, height: L.lsShutterOuter * 0.9)
                        .rotationEffect(.degrees(-90))
                    // Inner fill (−10%)
                    Circle()
                        .fill(Theme.Colors.bodyDark)
                        .frame(width: L.lsShutterInner * 0.9, height: L.lsShutterInner * 0.9)
                }
            }
            .buttonStyle(.plain)

            Spacer()

            // ── RY + Flash (bottom) ───────────────────────────────────────────
            VStack(spacing: 8) {
                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { experimentalColor.toggle() }
                } label: {
                    lsExpColorButton
                }
                .buttonStyle(.plain)

                Button {
                    flashOn.toggle()
                    camera.setFlash(flashOn)
                } label: {
                    Circle()
                        .fill(Theme.Colors.buttonFill)
                        .frame(width: L.lsBtnSize, height: L.lsBtnSize)
                        .overlay(Circle().strokeBorder(Theme.Colors.buttonBorder, lineWidth: 1))
                        .overlay(
                            Image(systemName: flashOn ? "bolt.fill" : "bolt.slash.fill")
                                .font(.system(size: 20, weight: .medium))
                                .foregroundColor(
                                    flashOn ? Theme.Colors.bodyDark : Theme.Colors.textMuted)
                        )
                }
                .buttonStyle(.plain)
            }
            .padding(.bottom, L.lsVPad + safeBottom)
        }
    }

    @ViewBuilder
    private var lsExpColorButton: some View {
        if experimentalColor {
            Circle()
                .fill(Theme.Colors.cream)
                .frame(width: L.lsBtnSize, height: L.lsBtnSize)
                .overlay(Circle().strokeBorder(Theme.Colors.bodyDark, lineWidth: 1.5))
                .overlay(
                    Text("RY")
                        .font(.system(size: 15, weight: .medium))
                        .foregroundColor(Theme.Colors.bodyDark)
                        .kerning(0.5)
                )
        } else {
            Circle()
                .fill(Theme.Colors.rawFill)
                .frame(width: L.lsBtnSize, height: L.lsBtnSize)
                .overlay(
                    Text("raw")
                        .font(.system(size: 13, weight: .medium))
                        .foregroundColor(Theme.Colors.cream)
                        .kerning(1.0)
                )
        }
    }

    // MARK: - Helpers
    private func switchFocal(to mm: Int) {
        guard mm != selectedFocal else { return }
        haptic.impactOccurred()
        withAnimation(.easeInOut(duration: 0.12)) { selectedFocal = mm }
        camera.setFocalLength(mm)
    }

    private func switchFormat(to format: AspectFormat) {
        guard format != selectedFormat else { return }
        haptic.impactOccurred()
        selectedFormat = format
    }
}

// MARK: - Viewfinder Corners
struct ViewfinderCorners: View {
    let size: CGFloat      = 18
    let lineWidth: CGFloat = 1.5
    let color              = Color.white.opacity(0.35)
    let inset: CGFloat     = 12

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

// MARK: - Crosshair
struct CrosshairView: View {
    let size: CGFloat      = 26
    let lineWidth: CGFloat = 1.5
    let color              = Color.white.opacity(0.38)
    var body: some View {
        ZStack {
            Rectangle().fill(color).frame(width: size, height: lineWidth)
            Rectangle().fill(color).frame(width: lineWidth, height: size)
        }
    }
}

// MARK: - Clamping
extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}

#Preview {
    ContentView()
        .environmentObject(CameraManager())
        .preferredColorScheme(.light)
}
