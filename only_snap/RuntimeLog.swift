import Foundation
import os.log

enum RuntimeLog {
    nonisolated private static let logger = Logger(subsystem: "only_snap", category: "Runtime")

    nonisolated static func info(_ tag: String, _ message: String) {
        logger.info("\(tag, privacy: .public) \(message, privacy: .public)")
    }

    nonisolated static func error(_ tag: String, _ message: String) {
        logger.error("\(tag, privacy: .public) \(message, privacy: .public)")
    }
}
