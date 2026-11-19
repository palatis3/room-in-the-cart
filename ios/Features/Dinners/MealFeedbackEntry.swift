import CryptoKit
import SwiftUI
import CoreDomain

extension CapturePrivateIdentity {
    var mealFeedbackOwner: String {
        // Length framing distinguishes anonymous, household and member changes without exporting raw identifiers.
        let fields = [subject == nil ? actorID.uuidString : nil, subject, householdID, memberID]
        var data = Data()
        for value in fields {
            if let value { data.append(contentsOf: "\(value.utf8.count):\(value)".utf8) }
            else { data.append(contentsOf: "-:".utf8) }
        }
        return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }
}

struct MealFeedbackEntry: View {
    @ObservedObject var ledger: LedgerModel
    let source: MealFeedbackSource
    let title: String
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.scenePhase) private var scene

    private var identity: CapturePrivateIdentity? {
        guard scene == .active, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable, child?.presented != true,
              household.projection?.grantId == nil, ledger.ready, !ledger.hasPendingLedgerDeletion,
              ledger.workspace.feedbackSourceExists(source) else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }

    private struct EditorIdentity: Hashable { let owner: String; let origin: UUID; let source: MealFeedbackSource }

    var body: some View {
        Group {
            if let identity, let origin = ledger.sourceWorkspaceID {
                let owner = identity.mealFeedbackOwner
                MealFeedbackEditor(title: title, existing: ledger.workspace.feedback(for: source, owner: owner),
                    languageBasis: { revision in
                        MealLanguageBasis.current(ledger: ledger, access: access, household: household,
                            childPresented: child?.presented == true, source: source, revision: revision)
                    }) { draft, revision, assistedBasis in
                    await ledger.change(key: "private-meal-feedback", reviewedPantryBasis: nil,
                        authorize: {
                            self.identity == identity && ledger.sourceWorkspaceID == origin &&
                                (assistedBasis == nil || assistedBasis == MealLanguageBasis.current(ledger: ledger, access: access,
                                    household: household, childPresented: child?.presented == true, source: source, revision: revision, duringSave: true))
                        }) { workspace in
                        try workspace.updateMealFeedback(for: source, owner: owner, expectedRevision: revision, reactions: draft, at: Date())
                    }
                }.id(EditorIdentity(owner: owner, origin: origin, source: source))
            } else { Text(dinnerText("Unlock the same private workspace to review this meal.")) }
        }.navigationTitle(dinnerText("Private meal feedback")).privacySensitive()
    }
}

private struct MealFeedbackEditor: View {
    let title: String
    let languageBasis: (UUID?) -> MealLanguageBasis?
    let save: (Set<MealReaction>, UUID?, MealLanguageBasis?) async -> Bool
    @State private var assistedBasis: MealLanguageBasis?
    @Environment(\.dismiss) private var dismiss
    @State private var original: PrivateMealFeedback?
    @State private var reactions: Set<MealReaction>
    @State private var busy = false
    @State private var failed = false

    init(title: String, existing: PrivateMealFeedback?, languageBasis: @escaping (UUID?) -> MealLanguageBasis?,
         save: @escaping (Set<MealReaction>, UUID?, MealLanguageBasis?) async -> Bool) {
        self.languageBasis = languageBasis
        self.title = title
        self.save = save
        _original = State(initialValue: existing)
        _reactions = State(initialValue: Set(existing?.reactions ?? []))
    }

    var body: some View {
        WorkingForm {
            Section {
                Text(title).font(.headline)
                Text(dinnerText("Choose any reactions you want to keep for future meal suggestions."))
                ForEach(MealReaction.allCases, id: \.self) { reaction in
                    Toggle(name(reaction), isOn: Binding(get: { reactions.contains(reaction) }, set: { selected in
                        if selected { reactions.insert(reaction) } else { reactions.remove(reaction) }
                    })).accessibilityIdentifier("mealFeedback." + reaction.rawValue)
                }
            }
            MealLanguageDraftLink(basis: { languageBasis(original?.revision) }, draft: { .feedback(reactions) }) { result, basis in
                if case .feedback(let edited) = result { reactions = edited; assistedBasis = basis }
            }
            Section {
                if failed { Text(dinnerText("Feedback changed or could not be saved. Reopen this meal to review it.")) }
                Button(dinnerText("Save private feedback")) { submit(reactions) }
                    .disabled(reactions == Set(original?.reactions ?? [])).accessibilityIdentifier("mealFeedback.save")
                if original != nil {
                    Button(dinnerText("Remove my feedback"), role: .destructive) { submit([]) }
                        .accessibilityIdentifier("mealFeedback.remove")
                }
                Button(dinnerText("Cancel")) { dismiss() }
            }
        }.disabled(busy)
    }

    private func submit(_ selected: Set<MealReaction>) {
        guard !busy else { return }
        busy = true
        Task {
            let saved = await save(selected, original?.revision, assistedBasis)
            busy = false
            if saved { dismiss() } else { failed = true }
        }
    }

    private func name(_ reaction: MealReaction) -> String {
        switch reaction {
        case .makeAgain: dinnerText("Make again")
        case .tooMuchEffort: dinnerText("Too much effort")
        case .childrenLikedIt: dinnerText("Children liked it")
        case .tooManyLeftovers: dinnerText("Too many leftovers")
        }
    }
}
