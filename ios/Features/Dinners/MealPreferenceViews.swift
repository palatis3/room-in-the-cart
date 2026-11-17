import SwiftUI
import CoreDomain

private struct MealPreferenceFocusKey: EnvironmentKey {
    static let defaultValue: FocusState<String?>.Binding? = nil
}
private extension EnvironmentValues {
    var mealPreferenceFocus: FocusState<String?>.Binding? {
        get { self[MealPreferenceFocusKey.self] }
        set { self[MealPreferenceFocusKey.self] = newValue }
    }
}

private struct PreferenceTermsField: View {
    let title: String
    @Binding var terms: [String]
    @State private var text: String
    @Environment(\.mealPreferenceFocus) private var focus
    init(_ title: String, terms: Binding<[String]>) {
        self.title = title
        _terms = terms
        _text = State(initialValue: terms.wrappedValue.joined(separator: "\n"))
    }
    var body: some View {
        let field = workingTextField(title, text: $text, axis: .vertical)
        Group {
            if let focus { field.focused(focus, equals: title) }
            else { field }
        }
            .onChange(of: text) { _, next in terms = DinnerEntry.list(next) }
            .onChange(of: terms) { _, next in
                if DinnerEntry.list(text) != next { text = next.joined(separator: "\n") }
            }
    }
}

private struct ReviewedTermsField: View {
    let title: String
    let field: String
    @Binding var value: [String]?
    var body: some View {
        Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? [] : nil }))
        if value != nil {
            PreferenceTermsField(field, terms: Binding(get: { value ?? [] }, set: { value = $0 }))
        }
    }
}

private struct MealEffortPicker: View {
    let title: String
    @Binding var effort: MealEffort?
    var body: some View {
        Picker(title, selection: $effort) {
            Text(dinnerText("Unspecified")).tag(nil as MealEffort?)
            Text(dinnerText("Low effort")).tag(Optional(MealEffort.low))
            Text(dinnerText("Medium effort")).tag(Optional(MealEffort.medium))
            Text(dinnerText("High effort")).tag(Optional(MealEffort.high))
        }
    }
}

struct MealEvidenceFields: View {
    @Binding var draft: MealEligibilityEvidence
    var foodOnly = false
    var body: some View {
        ReviewedTermsField(title: dinnerText("Ingredient details reviewed"), field: dinnerText("Additional ingredients, one per line"), value: $draft.reviewedIngredientDetails)
        if !foodOnly { ReviewedTermsField(title: dinnerText("Required appliances reviewed"), field: dinnerText("Required appliances, one per line"), value: $draft.requiredAppliances) }
        ReviewedTermsField(title: dinnerText("Brands reviewed"), field: dinnerText("Brands used, one per line"), value: $draft.brands)
        if !foodOnly { MealEffortPicker(title: dinnerText("Recipe effort"), effort: $draft.effort) }
    }
}

struct MealPreferenceIssues: View {
    let result: MealEligibilityPolicy.Result
    var body: some View {
        ForEach(Array((result.blocked + result.unresolved + result.softDifferences).enumerated()), id: \.offset) { issue in
            Text(message(issue.element))
        }
    }
    private func message(_ issue: MealEligibilityPolicy.Issue) -> String {
        switch issue {
        case .excluded(let term): dinnerFormat("Excluded ingredient: %@", term)
        case .disliked(let term): dinnerFormat("Disliked ingredient: %@", term)
        case .appliancesUnavailable(let values): dinnerFormat("Unavailable appliances: %@", values.joined(separator: ", "))
        case .brandMismatch: dinnerText("A brand differs from your preferences.")
        case .effortAboveLimit: dinnerText("This meal exceeds your preferred effort.")
        case .ingredientsUnknown: dinnerText("Ingredient details still need review.")
        case .appliancesUnknown: dinnerText("Required appliances are unknown.")
        case .brandsUnknown: dinnerText("Brand details are unknown.")
        case .effortUnknown: dinnerText("Recipe effort is unknown.")
        }
    }
}

struct PrivateMealPreferencesEntry: View {
    @ObservedObject var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    private var identity: CapturePrivateIdentity? {
        guard child?.presented != true, household.projection?.grantId == nil, !ledger.hasPendingLedgerDeletion,
              UIApplication.shared.isProtectedDataAvailable else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    var body: some View {
        Group {
            if let identity, let workspaceID = ledger.sourceWorkspaceID, ledger.ready {
                let profile = ledger.workspace.dinnerPlanning.privateMealPreferences
                MealPreferenceEditor(profile: profile) { settings, revision in
                    let access = access, household = household, child = child, ledger = ledger
                    return await ledger.saveMealPreferences(settings, expectedRevision: revision, workspaceID: workspaceID) {
                        child?.presented != true && household.projection?.grantId == nil &&
                        UIApplication.shared.isProtectedDataAvailable && ledger.sourceWorkspaceID == workspaceID &&
                        CapturePrivateIdentity.current(access: access, household: household) == identity
                    }
                }.id([identity.actorID.uuidString, identity.subject, identity.householdID, identity.memberID, identity.role, workspaceID.uuidString])
            } else { Text(dinnerText("Unlock your private workspace to review meal preferences.")) }
        }.navigationTitle(dinnerText("Private meal preferences"))
    }
}

struct MealPreferenceEditor: View {
    let save: (MealPreferenceSettings, UUID?) async -> Bool
    private let initial: MealPreferenceProfile?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MealPreferenceSettings
    @State private var reviewing = false
    @State private var busy = false
    @FocusState private var textFocus: String?
    @State private var failed = false
    init(profile: MealPreferenceProfile?, save: @escaping (MealPreferenceSettings, UUID?) async -> Bool) {
        self.save = save
        initial = profile
        _draft = State(initialValue: profile?.settings ?? .init())
        _base = State(initialValue: profile?.revision)
    }
    @State private var base: UUID?
    var body: some View {
        Form {
            Section(dinnerText("Hard constraints")) {
                PreferenceTermsField(dinnerText("Excluded ingredients, one per line"), terms: $draft.exclusions)
                    .accessibilityIdentifier("preferences.exclusions")
                ReviewedTermsField(title: dinnerText("Limit recipes to available appliances"), field: dinnerText("Available appliances, one per line"), value: $draft.availableAppliances)
            }.disabled(reviewing)
            Section(dinnerText("Preferences")) {
                PreferenceTermsField(dinnerText("Disliked ingredients, one per line"), terms: $draft.dislikes)
                if !draft.dislikes.isEmpty { Toggle(dinnerText("Require meals without these dislikes"), isOn: $draft.strictDislikes) }
                PreferenceTermsField(dinnerText("Preferred brands, one per line"), terms: $draft.preferredBrands)
                if !draft.preferredBrands.isEmpty { Toggle(dinnerText("Require preferred brands"), isOn: $draft.strictBrands) }
                MealEffortPicker(title: dinnerText("Preferred maximum effort"), effort: $draft.maximumEffort)
                if draft.maximumEffort != nil { Toggle(dinnerText("Require this effort limit"), isOn: $draft.strictEffort) }
            }.disabled(reviewing)
            Section {
                if failed { Text(dinnerText("Preferences could not be saved. Check the entries or reopen the current version.")) }
                if reviewing {
                    Text(dinnerText("These choices apply to future meal proposals. Earlier meal records keep their original details."))
                    Button(dinnerText("Save reviewed preferences")) {
                        busy = true
                        Task {
                            let ok = await save(draft, base)
                            busy = false
                            if ok { dismiss() } else { failed = true }
                        }
                    }.accessibilityIdentifier("preferences.save")
                    Button(dinnerText("Keep editing")) { reviewing = false }
                } else {
                    Button(dinnerText("Review preferences")) {
                        do { try draft.validate(); failed = false; reviewing = true }
                        catch { failed = true }
                    }.accessibilityIdentifier("preferences.review")
                    if initial != nil, draft != MealPreferenceSettings() {
                        Button(dinnerText("Remove all preferences"), role: .destructive) { draft = .init(); reviewing = true }
                    }
                }
            }
        }.disabled(busy)
        .environment(\.mealPreferenceFocus, $textFocus)
        .keyboardDoneAction(visible: textFocus != nil, title: dinnerText("Done"),
                            identifier: "preferences.keyboardDone") { textFocus = nil }
        .onChange(of: draft.dislikes) { _, values in if values.isEmpty { draft.strictDislikes = false } }
        .onChange(of: draft.preferredBrands) { _, values in if values.isEmpty { draft.strictBrands = false } }
        .onChange(of: draft.maximumEffort) { _, value in if value == nil { draft.strictEffort = false } }
    }
}
