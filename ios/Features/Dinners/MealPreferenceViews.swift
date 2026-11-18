import SwiftUI
import CoreDomain

private struct PreferenceTermsField: View {
    let title: String
    let identifier: String?
    @Binding var terms: [String]
    @State private var text: String
    @FocusState.Binding var focus: String?
    init(_ title: String, terms: Binding<[String]>, focus: FocusState<String?>.Binding, identifier: String? = nil) {
        self.title = title
        self.identifier = identifier
        _terms = terms
        _focus = focus
        _text = State(initialValue: terms.wrappedValue.joined(separator: "\n"))
    }
    var body: some View {
        Group {
            if let identifier {
                VStack(alignment: .leading) {
                    Text(title).font(.caption)
                    TextEditor(text: $text)
                        .frame(minHeight: 58)
                        .focused($focus, equals: title)
                        .accessibilityLabel(title)
                        .accessibilityIdentifier(identifier)
                }
            } else {
                workingTextField(title, text: $text, axis: .vertical)
                    .focused($focus, equals: title)
            }
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
    private let focus: FocusState<String?>.Binding?
    private let identifier: String?
    @FocusState private var localFocus: String?
    init(title: String, field: String, value: Binding<[String]?>, focus: FocusState<String?>.Binding? = nil, identifier: String? = nil) {
        self.title = title
        self.field = field
        _value = value
        self.focus = focus
        self.identifier = identifier
    }
    var body: some View {
        Toggle(title, isOn: Binding(get: { value != nil }, set: { value = $0 ? [] : nil }))
        if value != nil {
            PreferenceTermsField(field, terms: Binding(get: { value ?? [] }, set: { value = $0 }),
                                 focus: focus ?? $localFocus, identifier: identifier)
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
    var packageLabel = false
    var focus: FocusState<String?>.Binding? = nil
    var body: some View {
        ReviewedTermsField(title: packageLabel ? tonightText("Package ingredients reviewed") : dinnerText("Ingredient details reviewed"),
            field: packageLabel ? tonightText("Ingredients printed on this package, one per line") : dinnerText("Additional ingredients, one per line"),
            value: $draft.reviewedIngredientDetails, focus: focus, identifier: packageLabel ? "householdTonight.label.ingredients" : nil)
        if !foodOnly { ReviewedTermsField(title: dinnerText("Required appliances reviewed"), field: dinnerText("Required appliances, one per line"), value: $draft.requiredAppliances, focus: focus) }
        ReviewedTermsField(title: packageLabel ? tonightText("Package brands reviewed") : dinnerText("Brands reviewed"),
            field: packageLabel ? tonightText("Brands printed on this package, one per line") : dinnerText("Brands used, one per line"),
            value: $draft.brands, focus: focus, identifier: packageLabel ? "householdTonight.label.brands" : nil)
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
        case .durationAboveLimit: dinnerText("Total preparation time exceeds your available time.")
        case .durationUnknown: dinnerText("Total elapsed preparation time is unknown.")
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
                MealPreferenceEditor(profile: profile, languageBasis: { revision in
                    MealLanguageBasis.current(ledger: ledger, access: access, household: household,
                        childPresented: child?.presented == true, source: nil, revision: revision)
                }) { settings, revision, assistedBasis in
                    let access = access, household = household, child = child, ledger = ledger
                    return await ledger.saveMealPreferences(settings, expectedRevision: revision, workspaceID: workspaceID) {
                        child?.presented != true && household.projection?.grantId == nil &&
                        UIApplication.shared.isProtectedDataAvailable && ledger.sourceWorkspaceID == workspaceID &&
                        CapturePrivateIdentity.current(access: access, household: household) == identity &&
                        (assistedBasis == nil || assistedBasis == MealLanguageBasis.current(ledger: ledger, access: access,
                            household: household, childPresented: child?.presented == true, source: nil, revision: revision, duringSave: true))
                    }
                }.id([identity.actorID.uuidString, identity.subject, identity.householdID, identity.memberID, identity.role, workspaceID.uuidString])
            } else { Text(dinnerText("Unlock your private workspace to review meal preferences.")) }
        }.navigationTitle(dinnerText("Private meal preferences"))
    }
}

struct MealPreferenceEditor: View {
    let save: (MealPreferenceSettings, UUID?, MealLanguageBasis?) async -> Bool
    @State private var assistedBasis: MealLanguageBasis?
    private let initial: MealPreferenceProfile?
    private let canSetTimeLimit: Bool
    private let languageBasis: ((UUID?) -> MealLanguageBasis?)?
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MealPreferenceSettings
    @State private var minutes: String
    @State private var reviewing = false
    @State private var busy = false
    @FocusState private var textFocus: String?
    @State private var failed = false
    init(profile: MealPreferenceProfile?, canSetTimeLimit: Bool = true, languageBasis: ((UUID?) -> MealLanguageBasis?)?,
         save: @escaping (MealPreferenceSettings, UUID?, MealLanguageBasis?) async -> Bool) {
        self.save = save
        self.canSetTimeLimit = canSetTimeLimit
        self.languageBasis = languageBasis
        initial = profile
        _draft = State(initialValue: profile?.settings ?? .init())
        _base = State(initialValue: profile?.revision)
        _minutes = State(initialValue: profile?.settings.timeLimit.map { String($0.maximumMinutes) } ?? "")
    }
    init(profile: MealPreferenceProfile?, canSetTimeLimit: Bool = true, save: @escaping (MealPreferenceSettings, UUID?) async -> Bool) {
        self.init(profile: profile, canSetTimeLimit: canSetTimeLimit, languageBasis: nil) { settings, revision, _ in
            await save(settings, revision)
        }
    }
    @State private var base: UUID?
    var body: some View {
        Form {
            Section(dinnerText("Hard constraints")) {
                PreferenceTermsField(dinnerText("Excluded ingredients, one per line"), terms: $draft.exclusions, focus: $textFocus)
                    .accessibilityIdentifier("preferences.exclusions")
                ReviewedTermsField(title: dinnerText("Limit recipes to available appliances"), field: dinnerText("Available appliances, one per line"), value: $draft.availableAppliances, focus: $textFocus)
            }.disabled(reviewing)
            Section(dinnerText("Preferences")) {
                PreferenceTermsField(dinnerText("Disliked ingredients, one per line"), terms: $draft.dislikes, focus: $textFocus)
                if !draft.dislikes.isEmpty { Toggle(dinnerText("Require meals without these dislikes"), isOn: $draft.strictDislikes) }
                PreferenceTermsField(dinnerText("Preferred brands, one per line"), terms: $draft.preferredBrands, focus: $textFocus)
                if !draft.preferredBrands.isEmpty { Toggle(dinnerText("Require preferred brands"), isOn: $draft.strictBrands) }
                if canSetTimeLimit {
                    TextField(dinnerText("Available cooking time in minutes, if limited"), text: $minutes)
                        .keyboardType(.numberPad).focused($textFocus, equals: "availableMinutes")
                        .accessibilityIdentifier("preferences.availableMinutes")
                    if !minutes.isEmpty {
                        Toggle(dinnerText("Require meals within this time"), isOn: Binding(
                            get: { draft.timeLimit?.strict == true },
                            set: { required in
                                if let value = Int(minutes) { draft.timeLimit = .init(maximumMinutes: value, strict: required) }
                            }
                        )).accessibilityIdentifier("preferences.requireMinutes")
                    }
                }
                MealEffortPicker(title: dinnerText("Preferred maximum effort"), effort: $draft.maximumEffort)
                if draft.maximumEffort != nil { Toggle(dinnerText("Require this effort limit"), isOn: $draft.strictEffort) }
            }.disabled(reviewing)
            if !reviewing, let languageBasis {
                MealLanguageDraftLink(basis: { languageBasis(base) }, draft: { .preferences(draft) }) { result, basis in
                    if case .preferences(let settings) = result { draft = settings; assistedBasis = basis }
                }
            }
            Section {
                if failed { Text(dinnerText("Preferences could not be saved. Check the entries or reopen the current version.")) }
                if reviewing {
                    Text(dinnerText("These choices apply to future meal proposals. Earlier meal records keep their original details."))
                    Button(dinnerText("Save reviewed preferences")) {
                        busy = true
                        Task {
                            let ok = await save(draft, base, assistedBasis)
                            busy = false
                            if ok { dismiss() } else { failed = true }
                        }
                    }.accessibilityIdentifier("preferences.save")
                    Button(dinnerText("Keep editing")) { reviewing = false }
                } else {
                    Button(dinnerText("Review preferences")) {
                        do {
                            if minutes.isEmpty { draft.timeLimit = nil }
                            else if let value = Int(minutes) { draft.timeLimit = .init(maximumMinutes: value, strict: draft.timeLimit?.strict ?? false) }
                            else { throw DinnerPlanningError.invalid("timeLimit") }
                            try draft.validate(); failed = false; reviewing = true
                        }
                        catch { failed = true }
                    }.accessibilityIdentifier("preferences.review")
                    if initial != nil, draft != MealPreferenceSettings() {
                        Button(dinnerText("Remove all preferences"), role: .destructive) { draft = .init(); minutes = ""; reviewing = true }
                    }
                }
            }
        }.disabled(busy)
        .keyboardDoneAction(visible: textFocus != nil, title: dinnerText("Done"),
                            identifier: "preferences.keyboardDone") { textFocus = nil }
        .onChange(of: minutes) { _, value in
            if value.isEmpty { draft.timeLimit = nil }
            else if let minutes = Int(value) { draft.timeLimit = .init(maximumMinutes: minutes, strict: draft.timeLimit?.strict ?? false) }
        }
        .onChange(of: draft.dislikes) { _, values in if values.isEmpty { draft.strictDislikes = false } }
        .onChange(of: draft.preferredBrands) { _, values in if values.isEmpty { draft.strictBrands = false } }
        .onChange(of: draft.maximumEffort) { _, value in if value == nil { draft.strictEffort = false } }
    }
}
