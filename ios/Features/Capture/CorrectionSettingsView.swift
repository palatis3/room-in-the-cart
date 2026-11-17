import SwiftUI

/// Settings uses the same optional, device-local spelling store as capture.
/// A runtime identity and live ledger are required; no account ID or recovered
/// document can select a correction profile through this screen.
@MainActor struct CorrectionSettingsView: View {
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var corrections = CaptureCorrectionsModel()

    private enum Selection: Hashable {
        case language(String)
        case previous(CaptureCorrectionScope)
    }
    @State private var selection = Selection.language(CaptureCorrectionScope.appLanguage())
    @State private var boundContext: Context?
    @State private var working = false
    @State private var confirmDisable = false
    @State private var requestedDisableContext: Context?
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
        let scope: CaptureCorrectionScope
    }

    private var context: Context? {
        guard scenePhase == .active, ledger.ready, !ledger.hasPendingLedgerDeletion,
              let workspaceID = ledger.sourceWorkspaceID,
              let identity = CapturePrivateIdentity.current(access: access, household: household) else { return nil }
        let profile = "local:" + workspaceID.uuidString
        let scope: CaptureCorrectionScope
        switch selection {
        case .previous(let previous) where previous.profileID == profile: scope = previous
        case .language(let language): scope = CaptureCorrectionScope(profileID: profile, localeIdentifier: language)
        default: scope = CaptureCorrectionScope(profileID: profile, localeIdentifier: CaptureCorrectionScope.appLanguage())
        }
        return Context(actorID: identity.actorID, subject: identity.subject, householdID: identity.householdID,
            memberID: identity.memberID, role: identity.role, workspaceID: workspaceID, scope: scope)
    }
    private var displayedSelection: Selection {
        guard let scope = context?.scope, scope.isPreviousRegion else {
            return .language(context?.scope.localeIdentifier ?? CaptureCorrectionScope.appLanguage())
        }
        return .previous(scope)
    }
    private var previousRegions: [CaptureCorrectionScope] {
        // Keep the selected row identifiable after its last file is deleted.
        if let scope = context?.scope, scope.isPreviousRegion, !corrections.previousRegions.contains(scope) {
            return corrections.previousRegions + [scope]
        }
        return corrections.previousRegions
    }
    private var authorized: Bool {
        context != nil && boundContext == context && corrections.scope == context?.scope
    }

    var body: some View {
        ScrollViewReader { scroll in
            Form {
                if authorized {
                    Section(captureText("Spelling language")) {
                        Picker(captureText("Spelling language"), selection: Binding(get: { displayedSelection }, set: { selection = $0 })) {
                            Text(captureText("English spellings")).tag(Selection.language("en-US"))
                            Text(captureText("Spanish spellings")).tag(Selection.language("es-US"))
                            ForEach(Array(previousRegions.enumerated()), id: \.element) { index, region in
                                Text(regionLabel(region, index: index)).tag(Selection.previous(region))
                            }
                        }.accessibilityIdentifier("corrections.language")
                        if !previousRegions.isEmpty {
                            Text(captureText("Earlier regions have their own saved spellings. Select a region to review or delete them. New captures use the app language."))
                        }
                        Text(captureText("These spellings belong to this private workspace and the selected language. They stay on this iPhone."))
                    }
                    if let outcome {
                        Section(captureText("Spelling result")) {
                            Text(outcome == .disabled && context?.scope.isPreviousRegion == true ? captureText("Saved spellings for this earlier region were deleted.") : outcome.text)
                                .id("corrections.result")
                                .accessibilityIdentifier("corrections.result")
                                .accessibilityFocused($outcomeFocused)
                                .task(id: outcomeRevision) { await focusOutcome(using: scroll) }
                        }
                    }
                    Section(captureText("Optional spelling memory")) {
                        if !corrections.failed && (context?.scope.isPreviousRegion != true || corrections.snapshot.enabled) {
                            Toggle(captureText("Remember product spellings on this device"), isOn: Binding(get: { corrections.snapshot.enabled }, set: { value in
                                if value { perform(.enable) }
                                else { requestDisable() }
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
                            Button(captureText("Turn off and delete these spellings"), role: .destructive) {
                                requestDisable()
                            }.disabled(working).accessibilityIdentifier("corrections.deleteUnreadable")
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
                    await corrections.bind(selected.scope, includePreviousRegions: true)
                    guard !Task.isCancelled, context == selected, corrections.scope == selected.scope else { return }
                    boundContext = selected
                }
                // The live context check hides old entries before a replacement task
                // loads its own scope. A cancelled task must not clear a newer load.
                .onDisappear { corrections.invalidate(); boundContext = nil; confirmDisable = false; outcome = nil; outcomeFocused = false }
                .confirmationDialog(captureText("Turn off spelling memory?"), isPresented: $confirmDisable, titleVisibility: .visible) {
                    Button(captureText("Turn off and delete these spellings"), role: .destructive) {
                        confirmDisable = false
                        guard let requestedDisableContext, requestedDisableContext == context else { return }
                        perform(.disable)
                    }
                    Button(captureText("Cancel")) { confirmDisable = false }
                        .accessibilityIdentifier("corrections.cancelDisable")
                } message: {
                    Text(captureText(context?.scope.isPreviousRegion == true
                        ? "This deletes only the saved spellings for this earlier region."
                        : "This deletes remembered spellings for this private workspace and selected language. Other languages and previously saved records stay as they are."))
                }
        }
    }

    private func regionLabel(_ region: CaptureCorrectionScope, index: Int) -> String {
        let language = Locale(identifier: CaptureCorrectionScope.appLanguage())
        let label = region.localeIdentifier == "und" ? String(index + 1)
            : language.localizedString(forIdentifier: region.localeIdentifier) ?? region.localeIdentifier
        return captureText("Earlier region") + " · " + label
    }

    private func requestDisable() {
        guard authorized, !working, let context else { return }
        requestedDisableContext = context
        confirmDisable = true
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
            await corrections.bind(selected.scope, includePreviousRegions: true)
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
