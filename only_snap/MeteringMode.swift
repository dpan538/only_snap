import Foundation

enum MeteringMode: String, CaseIterable, Sendable {
    case matrix
    case centerWeighted
    case average
    case highlight

    var shortLabel: String {
        switch self {
        case .matrix: return "METER"
        case .centerWeighted: return "CENTER"
        case .average: return "AVG"
        case .highlight: return "HILITE"
        }
    }

    var systemImageName: String {
        switch self {
        case .matrix: return "square.grid.3x3"
        case .centerWeighted: return "circle.circle"
        case .average: return "circle"
        case .highlight: return "sun.max.fill"
        }
    }

    var logName: String {
        switch self {
        case .matrix: return "matrix"
        case .centerWeighted: return "centerWeighted"
        case .average: return "average"
        case .highlight: return "highlight"
        }
    }

    var next: MeteringMode {
        let all = Self.allCases
        return all[(all.firstIndex(of: self)! + 1) % all.count]
    }
}
