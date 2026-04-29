import Foundation

enum FilmProfile: String, CaseIterable, Sendable {
    case raw
    case vg
    case ew

    nonisolated var label: String {
        switch self {
        case .raw: return "raw"
        case .vg:  return "VG"
        case .ew:  return "EW"
        }
    }

    nonisolated var logName: String { rawValue }
}
