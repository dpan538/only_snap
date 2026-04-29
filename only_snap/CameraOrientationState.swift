import CoreGraphics
import UIKit

enum CameraOrientationState: String, Sendable {
    case portrait
    case landscapeLeft

    nonisolated init?(deviceOrientation: UIDeviceOrientation) {
        switch deviceOrientation {
        case .portrait:
            self = .portrait
        case .landscapeLeft:
            self = .landscapeLeft
        default:
            return nil
        }
    }

    nonisolated var isLandscape: Bool { self == .landscapeLeft }

    nonisolated var previewRotationAngle: CGFloat {
        switch self {
        case .portrait:      return 90
        case .landscapeLeft: return 0
        }
    }

    nonisolated var videoOutputRotationAngle: CGFloat {
        switch self {
        case .portrait:      return 90
        case .landscapeLeft: return 0
        }
    }

    nonisolated var photoRotationAngle: CGFloat {
        switch self {
        case .portrait:      return 90
        case .landscapeLeft: return 0
        }
    }

    nonisolated static func logName(for deviceOrientation: UIDeviceOrientation) -> String {
        switch deviceOrientation {
        case .unknown:              return "unknown"
        case .portrait:             return "portrait"
        case .portraitUpsideDown:   return "portraitUpsideDown"
        case .landscapeLeft:        return "landscapeLeft"
        case .landscapeRight:       return "landscapeRight"
        case .faceUp:               return "faceUp"
        case .faceDown:             return "faceDown"
        @unknown default:           return "unknownFuture"
        }
    }
}
