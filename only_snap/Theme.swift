import SwiftUI

enum Theme {

    // MARK: - Colors
    enum Colors {
        static let background   = Color(red: 0.961, green: 0.941, blue: 0.910)
        static let bodyDark     = Color(red: 0.165, green: 0.145, blue: 0.125)
        static let buttonFill   = Color(red: 0.918, green: 0.894, blue: 0.847)
        static let buttonBorder = Color(red: 0.753, green: 0.722, blue: 0.659)
        static let rawFill      = Color(red: 0.604, green: 0.565, blue: 0.533)
        static let textMuted    = Color(red: 0.690, green: 0.635, blue: 0.597)
        static let textSubtle   = Color(red: 0.478, green: 0.447, blue: 0.408)
        static let viewfinderBg = Color(red: 0.118, green: 0.102, blue: 0.086)
        static let cream        = Color(red: 0.961, green: 0.941, blue: 0.910)
    }

    // MARK: - Typography
    enum Font {
        static func regular(_ size: CGFloat) -> SwiftUI.Font { .system(size: size, weight: .regular) }
        static func medium(_ size: CGFloat) -> SwiftUI.Font  { .system(size: size, weight: .medium)  }
    }

    // MARK: - Layout
    enum Layout {
        // Portrait
        static let vfHPad: CGFloat            = 30
        static let vfTopOffset: CGFloat       = 40
        static let btnSize: CGFloat           = 66
        static let shutterOuter: CGFloat      = 110
        static let shutterInner: CGFloat      = 90
        static let formatUpLift: CGFloat      = 70
        static let swipeThreshold: CGFloat    = 45
        static let focalToButtons: CGFloat    = 30
        static let controlsBottomPad: CGFloat = 48
        static let controlsExtraDown: CGFloat = 20

        // Reserved layout constants from the original camera UI exploration.
        static let lsStripWidth: CGFloat      = 108
        static let lsShutterOuter: CGFloat    = 76
        static let lsShutterInner: CGFloat    = 60
        static let lsBtnSize: CGFloat         = 46
        static let lsVPad: CGFloat            = 14
    }
}

// MARK: - Aspect Format
enum AspectFormat: CaseIterable, Sendable {

    case square       // 1:1
    case threeToFour  // 3:4
    case twoToThree   // 2:3

    nonisolated var label: String {
        switch self {
        case .square:      return "1:1"
        case .threeToFour: return "3:4"
        case .twoToThree:  return "2:3"
        }
    }

    nonisolated var heightRatio: CGFloat {
        switch self {
        case .square:      return 1.0
        case .threeToFour: return 4.0 / 3.0
        case .twoToThree:  return 3.0 / 2.0
        }
    }

    nonisolated func verticalOffset(forWidth w: CGFloat) -> CGFloat {
        let baseH    = w * (4.0 / 3.0)
        let currentH = w * heightRatio
        return (currentH - baseH) / 2.0 * -1.0
    }

    nonisolated func next() -> AspectFormat {
        let all = AspectFormat.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }

    nonisolated func previous() -> AspectFormat {
        let all = AspectFormat.allCases
        return all[(all.firstIndex(of: self)! - 1 + all.count) % all.count]
    }
}
