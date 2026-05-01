import Foundation

enum FilmProfile: String, CaseIterable, Sendable {
    case raw
    case vg
    case ew
    case lg

    nonisolated var label: String {
        switch self {
        case .raw: return "SD"
        case .vg:  return "VG"
        case .ew:  return "EW"
        case .lg:  return "LG"
        }
    }

    nonisolated var logName: String {
        switch self {
        case .raw: return "sd"
        case .vg, .ew, .lg: return rawValue
        }
    }
}
