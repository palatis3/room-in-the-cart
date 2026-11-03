import OSLog

/// Only enumerated structural events may enter logs. No payload, food, money or error text.
enum DiagnosticEvent: String {
    case localStoreUnavailable
    case localReadFailed
    case localSaveFailed
}
enum Diagnostics {
    private static let logger = Logger(subsystem: "dev.roominthecart", category: "local-storage")
    static func record(_ event: DiagnosticEvent) {
        logger.error("Local operation: \(event.rawValue, privacy: .public)")
    }
}
