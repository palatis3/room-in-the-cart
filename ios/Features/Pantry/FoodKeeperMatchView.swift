import CoreDomain
import HouseholdClient
import SwiftUI

struct FoodKeeperMatchLot {
    let id: UUID
    let revision: Int64
    let scope: PantryDigestScope
    let current: @MainActor () -> Bool
    let verify: @MainActor () async throws -> Void
}

@MainActor struct FoodKeeperMatchView: View {
    let lot: FoodKeeperMatchLot
    let reference: FoodKeeperReference
    let context: FoodKeeperLookupContext
    let language: FoodKeeperLanguage
    let choices: [FoodKeeperMatchChoice]
    @State private var selected: String
    @State private var ready = false
    @State private var consent: FoodKeeperMatchConsent?
    @State private var reply: FoodKeeperMatchReply?
    @State private var message: String?
    @State private var operation: Task<Void, Never>?
    @State private var sending = false
    @FocusState private var editing: Bool
    @Environment(\.scenePhase) private var scene
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel

    init(lot: FoodKeeperMatchLot, reference: FoodKeeperReference, context: FoodKeeperLookupContext,
         language: FoodKeeperLanguage, choices: [FoodKeeperMatchChoice], initialText: String) {
        self.lot = lot
        self.reference = reference
        self.context = context
        self.language = language
        self.choices = choices
        _selected = State(initialValue: initialText)
    }

    private var basis: FoodKeeperMatchBasis? {
        guard scene == .active, lot.current(), !household.guardianChildOnly, household.projection?.grantId == nil,
              let actor = CapturePrivateIdentity.current(access: access, household: household),
              let subject = actor.subject, let householdID = actor.householdID, let memberID = actor.memberID,
              PantryDigestScope(origin: lot.scope.origin, identity: actor) == lot.scope else { return nil }
        return .init(actor: actor, scope: .init(subject: subject, householdID: householdID, memberID: memberID,
                                               shopID: household.projection?.shopId),
                     pantry: lot.scope, lotID: lot.id, lotRevision: lot.revision, catalogVersion: reference.version,
                     locale: language == .spanish ? "es" : "en", candidates: choices)
    }
    private var wording: String { selected.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        Form {
            if !lot.current() || scene != .active {
                Text(pantryText("Unlock the authorized private workspace to view pantry food."))
            } else if basis == nil {
                Text(pantryText("An adult household sign-in is needed for optional label matching. You can search the guide on this device."))
                    .accessibilityIdentifier("foodKeeper.assistance.signedOut")
            } else if choices.isEmpty {
                Text(pantryText("Search the guide for a food or category to choose possible entries."))
            } else {
                Section(pantryText("Selected wording")) {
                    TextField(pantryText("Wording to send"), text: $selected, axis: .vertical)
                        .focused($editing).accessibilityIdentifier("foodKeeper.assistance.wording")
                    Text(pantryText("Only the wording shown here and these public USDA entry names and IDs will be sent to OpenAI through the app’s service."))
                }
                Section(pantryText("USDA FoodKeeper entries to consider")) {
                    ForEach(choices) { choice in
                        Text(verbatim: "#" + String(choice.id) + " · " + choice.label)
                    }
                }
                if ready {
                    Button(pantryText("Send selected wording for a match")) { send() }
                        .disabled(sending || !ReceiptLineAssistanceRequest.accepts(wording))
                        .accessibilityIdentifier("foodKeeper.assistance.send")
                } else {
                    Text(pantryText("Remote matching is unavailable. You can still search the guide on this device."))
                }
                if sending { ProgressView() }
                if let message { Text(message).accessibilityIdentifier("foodKeeper.assistance.status") }
                if let consent, let reply, let id = try? reply.match(for: consent, current: basis, wording: wording),
                   let product = reference.products.first(where: { $0.id == id }) {
                    Section(pantryText("Suggested USDA entry")) {
                        Text(verbatim: product.name(language))
                        NavigationLink(pantryText("Confirm this entry and review storage")) {
                            ConfirmedFoodKeeperMatch(reference: reference, product: product, language: language, context: context,
                                validate: {
                                    try await lot.verify()
                                    guard try reply.match(for: consent, current: basis, wording: wording) == id else {
                                        throw ClientError.accessEnded
                                    }
                                }, current: { basis == consent.basis && lot.current() })
                        }.accessibilityIdentifier("foodKeeper.assistance.confirm")
                    }
                }
            }
        }
        .navigationTitle(pantryText("Match a food label"))
        .privacySensitive().scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: editing, title: pantryText("Done"), identifier: "foodKeeper.assistance.done") { editing = false }
        .task(id: basis) {
            ready = false
            clear()
            guard let original = basis, let service = household.service else { return }
            let enabled = try? await service.languageAssistanceAvailable(purpose: "foodkeeper-match", scope: original.scope)
            if !Task.isCancelled && basis == original { ready = enabled == true }
        }
        .onChange(of: selected) { _, _ in clear() }
        .onDisappear { operation?.cancel() }
    }

    private func clear() {
        operation?.cancel()
        operation = nil
        consent = nil
        reply = nil
        message = nil
        sending = false
    }

    private func send() {
        guard !sending, ready, let original = basis, let service = household.service,
              ReceiptLineAssistanceRequest.accepts(wording) else { return }
        let selectedText = wording
        editing = false
        do {
            let ticket = try consent ?? FoodKeeperMatchConsent(basis: original, wording: selectedText)
            try ticket.requireCurrent(original, wording: selectedText)
            consent = ticket
            reply = nil
            message = nil
            sending = true
            operation = Task {
                defer { if consent?.request.requestID == ticket.request.requestID { sending = false } }
                do {
                    try await lot.verify()
                    try Task.checkCancellation()
                    try ticket.requireCurrent(basis, wording: wording)
                    let result: FoodKeeperMatchReply = try await service.languageSuggestion(purpose: "foodkeeper-match",
                        body: ticket.wireData(), scope: original.scope)
                    try await lot.verify()
                    try Task.checkCancellation()
                    let id = try result.match(for: ticket, current: basis, wording: wording)
                    reply = result
                    if id == nil { message = pantryText("No matching entry was proposed. Search the guide or keep your own check date.") }
                } catch {
                    if !Task.isCancelled && basis == original { message = pantryText("Remote matching is unavailable. You can still search the guide on this device.") }
                }
            }
        } catch { clear(); message = pantryText("Review the selected wording again before sending it.") }
    }
}

private struct ConfirmedFoodKeeperMatch: View {
    let reference: FoodKeeperReference
    let product: FoodKeeperProduct
    let language: FoodKeeperLanguage
    let context: FoodKeeperLookupContext
    let validate: @MainActor () async throws -> Void
    let current: @MainActor () -> Bool
    @State private var verified = false
    @State private var changed = false

    var body: some View {
        Group {
            if verified && current() { FoodKeeperDetail(reference: reference, product: product, language: language, context: context) }
            else if changed || !current() { Text(pantryText("The batch changed. Return to the guide and review it again.")) }
            else { ProgressView() }
        }.task {
            do { try await validate(); try Task.checkCancellation(); verified = true }
            catch { changed = true }
        }
    }
}
