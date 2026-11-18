import OSLog

/// Only enumerated structural events may enter logs. No payload, food, money or error text.
enum DiagnosticEvent: String {
    case localStoreUnavailable
    case localReadFailed
    case localSaveFailed
    case pantryRouteReady, pantryRouteUnavailable, pantryBindingUnavailable, pantryScopeEntered, pantryLedgerOpeningFailed
}
enum Diagnostics {
    private static let logger = Logger(subsystem: "dev.roominthecart", category: "local-storage")
    static func record(_ event: DiagnosticEvent) {
        switch event {
        case .pantryRouteReady, .pantryScopeEntered:
            logger.notice("Local operation: \(event.rawValue, privacy: .public)")
        default:
            logger.error("Local operation: \(event.rawValue, privacy: .public)")
        }
    }
}
