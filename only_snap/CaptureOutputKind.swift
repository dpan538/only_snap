import Foundation

enum CaptureOutputKind: String, CaseIterable, Sendable {
    case jpg = "JPG"
    case heif = "HEIF"
    case dng = "DNG"

    nonisolated var next: CaptureOutputKind {
        switch self {
        case .jpg: return .heif
        case .heif: return .dng
        case .dng: return .jpg
        }
    }

    nonisolated var imageUTI: String? {
        switch self {
        case .jpg: return "public.jpeg"
        case .heif: return "public.heic"
        case .dng: return nil
        }
    }

    nonisolated var logName: String {
        rawValue.lowercased()
    }
}
