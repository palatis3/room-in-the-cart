import SwiftUI

/// Settings uses the same optional, device-local spelling store as capture.
/// A runtime identity and live ledger are required; no account ID or recovered
/// document can select a correction profile through this screen.
@MainActor struct CorrectionSettingsView: View {
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.locale) private var locale
    @StateObject private var corrections = CaptureCorrectionsModel()
    @State private var selectedLanguage: String?
    @State private var boundContext: Context?
    @State private var working = false
    @State private var confirmDisable = false
    @State private var outcome: CorrectionSettingsOutcome?
    @State private var outcomeRevision = 0
    @AccessibilityFocusState private var outcomeFocused: Bool

    private struct Context: Equatable, Hashable {
        let actorID: UUID
        let subject: String?
        let householdID: String?
        let memberID: String?
        let role: String?
        let workspaceID: UUID
        let language: String
        var scope: CaptureCorrectionScope {
            CaptureCorrectionScope(profileID: "local:" + workspaceID.uuidString, localeIdentifier: language)
        }
    }

    private var language: String { selectedLanguage ?? (locale.language.languageCode?.identifier == "es" ? "es-US" : "en-US") }
    private var context: Context? {
        guard scenePhase == .active, ledger.ready, !ledger.hasPendingLedgerDeletion,
              let workspaceID = ledger.sourceWorkspaceID,
              let identity = CapturePrivateIdentity.current(access: access, household: household) else { return nil }
        return Context(actorID: identity.actorID, subject: identity.subject, householdID: identity.householdID,
            memberID: identity.memberID, role: identity.role, workspaceID: workspaceID, language: language)
    }
    private var authorized: Bool {
        context != nil && boundContext == context && corrections.scope == context?.scope
    }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                if context != nil {
                    Section(captureText("Spelling language")) {
                        Picker(captureText("Spelling language"), selection: Binding(get: { language }, set: { selectedLanguage = $0 })) {
                            Text(captureText("English spellings")).tag("en-US")
                            Text(captureText("Spanish spellings")).tag("es-US")
                        }.accessibilityIdentifier("corrections.language")
                        Text(captureText("These spellings belong to this private workspace and the selected language. They stay on this iPhone."))
                    }
                }
                if authorized {
                    if let outcome {
                        Section(captureText("Spelling result")) {
                            Text(outcome.text)
                                .id("corrections.result")
                                .accessibilityIdentifier("corrections.result")
                                .accessibilityFocused($outcomeFocused)
                                .task(id: outcomeRevision) { await focusOutcome(using: scroll) }
                        }
                    }
                    Section(captureText("Optional spelling memory")) {
                        if !corrections.failed {
                            Toggle(captureText("Remember product spellings on this device"), isOn: Binding(get: { corrections.snapshot.enabled }, set: { value in
                                if value { perform(.enable) }
                                else { confirmDisable = true }
                            })).disabled(working).accessibilityIdentifier("corrections.enabled")
                        }
                        Text(captureText("Only spellings you explicitly remember are saved for this profile and language. Turning this off deletes them. Previous records never change."))
                        Text(captureText("Manage saved spellings here. New spellings are remembered only when you explicitly choose that action during a capture review."))
                    }
                    if !corrections.failed {
                        Section(captureText("Saved spellings")) {
                            if corrections.snapshot.entries.isEmpty { Text(captureText("No saved spellings for this language.")) }
                            ForEach(corrections.snapshot.entries) { entry in
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(entry.original + " → " + entry.replacement).textSelection(.enabled)
                                    Button(captureText("Forget spelling"), role: .destructive) {
                                        perform(.forget(entry))
                                    }.frame(minHeight: 44).disabled(working)
                                        .accessibilityLabel(CorrectionSettingsOutcome.forgetLabel(entry))
                                        .accessibilityIdentifier("corrections.forget." + entry.id.uuidString)
                                }
                            }
                        }
                    }
                    if corrections.failed {
                        Section {
                            Text(captureText("Spelling settings could not be updated. Reload them before trying again."))
                            Button(captureText("Reload spelling memory")) { reload() }.disabled(working)
                        }
                    }
                } else if context != nil {
                    ProgressView(captureText("Opening spelling memory…"))
                } else {
                    Text(captureText("Open your current private workspace to manage spelling memory. It is unavailable while access is locked or local deletion is pending."))
                }
            }.workingSurface().navigationTitle(captureText("Spelling corrections"))
                .task(id: context) {
                    corrections.invalidate(); boundContext = nil; working = false; confirmDisable = false
                    outcome = nil; outcomeFocused = false
                    guard let selected = context else { return }
                    await corrections.bind(selected.scope)
                    guard !Task.isCancelled, context == selected, corrections.scope == selected.scope else { return }
                    boundContext = selected
                }
                // The live context check hides old entries before a replacement task
                // loads its own scope. A cancelled task must not clear a newer load.
                .onDisappear { corrections.invalidate(); boundContext = nil; confirmDisable = false; outcome = nil; outcomeFocused = false }
                .confirmationDialog(captureText("Turn off spelling memory?"), isPresented: $confirmDisable, titleVisibility: .visible) {
                    Button(captureText("Turn off and delete these spellings"), role: .destructive) {
                        confirmDisable = false
                        perform(.disable)
                    }
                    Button(captureText("Cancel")) { confirmDisable = false }
                        .accessibilityIdentifier("corrections.cancelDisable")
                } message: {
                    Text(captureText("This deletes remembered spellings for this private workspace and selected language. Other languages and previously saved records stay as they are."))
                }
        }
    }

    private func perform(_ action: CorrectionSettingsAction) {
        guard authorized, !working, let selected = context else { return }
        working = true; outcome = nil; outcomeFocused = false
        Task {
            guard authorized, context == selected else { return }
            switch action {
            case .enable: await corrections.setEnabled(true)
            case .disable: await corrections.setEnabled(false)
            case .forget(let entry): await corrections.forget(entry.id)
            }
            guard context == selected, boundContext == selected else { return }
            working = false
            outcome = .resolve(action, snapshot: corrections.snapshot, failed: corrections.failed)
            outcomeRevision += 1
        }
    }
    private func reload() {
        guard authorized, !working, let selected = context else { return }
        working = true; outcome = nil; outcomeFocused = false
        Task {
            guard context == selected else { return }
            await corrections.bind(selected.scope)
            guard context == selected, boundContext == selected else { return }
            working = false
            outcome = corrections.failed ? .unconfirmed : .reloaded
            outcomeRevision += 1
        }
    }

    private func focusOutcome(using scroll: ScrollViewProxy) async {
        guard authorized, let selected = context, outcome != nil else { return }
        // Wait for the durable result row and any confirmation dismissal to
        // enter the view tree. Scrolling is immediate, including Reduce Motion.
        await Task.yield()
        guard !Task.isCancelled, authorized, context == selected, outcome != nil else { return }
        scroll.scrollTo("corrections.result", anchor: .center)
        await Task.yield()
        guard !Task.isCancelled, authorized, context == selected, outcome != nil else { return }
        outcomeFocused = true
    }
}

struct CorrectionSettingsLink: View {
    var body: some View {
        NavigationLink(captureText("Spelling corrections")) { CorrectionSettingsView() }
            .accessibilityIdentifier("settings.corrections")
    }
}
