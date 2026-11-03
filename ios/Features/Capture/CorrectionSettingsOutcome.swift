import Foundation

enum CorrectionSettingsAction: Equatable {
    case enable, disable
    case forget(CaptureCorrection)
}

/// Presentation outcomes come from the model's post-operation reload, never
/// from a tap or a disappeared row. The view keeps them within its live scope.
enum CorrectionSettingsOutcome: Equatable {
    case enabled, disabled, reloaded, unconfirmed
    case forgotten(CaptureCorrection)

    static func resolve(_ action: CorrectionSettingsAction, snapshot: CaptureCorrectionSnapshot, failed: Bool) -> Self {
        guard !failed else { return .unconfirmed }
        switch action {
        case .enable: return snapshot.enabled ? .enabled : .unconfirmed
        case .disable: return !snapshot.enabled && snapshot.entries.isEmpty ? .disabled : .unconfirmed
        case .forget(let entry):
            return snapshot.entries.contains(where: { $0.id == entry.id }) ? .unconfirmed : .forgotten(entry)
        }
    }

    static func forgetLabel(_ entry: CaptureCorrection) -> String {
        String(format: captureText("Forget spelling from %@ to %@"), entry.original, entry.replacement)
    }

    var text: String {
        switch self {
        case .enabled: return captureText("Spelling memory is on for this workspace and language.")
        case .disabled: return captureText("Spelling memory is off. Saved spellings for this workspace and language were deleted.")
        case .forgotten(let entry): return String(format: captureText("Forgot the spelling from %@ to %@."), entry.original, entry.replacement)
        case .reloaded: return captureText("Spelling memory reloaded. Review its current setting and saved spellings.")
        case .unconfirmed: return captureText("Spelling settings could not be confirmed. Reload them before trying again.")
        }
    }
}
