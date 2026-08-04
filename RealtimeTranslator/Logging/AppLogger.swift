import Foundation
import OSLog

enum AppLogger {
    private static let subsystem = Bundle.main.bundleIdentifier ?? "com.realtimetranslator.app"

    static let general = Logger(subsystem: subsystem, category: "general")
    static let audio = Logger(subsystem: subsystem, category: "audio")
    static let realtime = Logger(subsystem: subsystem, category: "realtime")
    static let subtitle = Logger(subsystem: subsystem, category: "subtitle")
    static let session = Logger(subsystem: subsystem, category: "session")
}
