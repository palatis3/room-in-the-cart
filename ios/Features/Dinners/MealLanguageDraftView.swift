import SwiftUI
import CoreDomain
import HouseholdClient

struct MealLanguageDraftLink: View {
    let basis: () -> MealLanguageBasis?
    let draft: () -> MealLanguageDraft
    var verifyBasis: ((MealLanguageBasis) async throws -> Void)? = nil
    let use: (MealLanguageDraft, MealLanguageBasis) -> Void
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @State private var opened: Session?

    private struct Session: Identifiable {
        let id = UUID()
        let basis: MealLanguageBasis
        let draft: MealLanguageDraft
    }
    private var current: MealLanguageBasis? {
        guard scene == .active, UIApplication.shared.applicationState == .active,
              UIApplication.shared.isProtectedDataAvailable else { return nil }
        return basis()
    }
    var body: some View {
        if current != nil, household.service != nil {
            Button(dinnerText("Suggest a draft from my words")) {
                guard let current else { return }
                opened = .init(basis: current, draft: draft())
            }.accessibilityIdentifier("mealLanguage.open")
            .sheet(item: $opened) { session in
                MealLanguageDraftReview(basis: session.basis, original: session.draft,
                    current: { self.current }, draft: draft, verifyBasis: verifyBasis, use: use)
            }
            .onChange(of: current) { _, next in if opened?.basis != next { opened = nil } }
        }
    }
}

private struct MealLanguageDraftReview: View {
    let basis: MealLanguageBasis
    let original: MealLanguageDraft
    let current: () -> MealLanguageBasis?
    let draft: () -> MealLanguageDraft
    var verifyBasis: ((MealLanguageBasis) async throws -> Void)? = nil
    let use: (MealLanguageDraft, MealLanguageBasis) -> Void
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.scenePhase) private var scene
    @State private var wording = ""
    @State private var available = false
    @State private var loading = true
    @State private var pending: UUID?
    @State private var sending: Task<Void, Never>?
    @State private var review: MealLanguageReview?
    @State private var message: String?
    @State private var attempts = 0

    private var active: Bool { scene == .active && current() == basis && draft() == original }
    private var text: String { wording.trimmingCharacters(in: .whitespacesAndNewlines) }
    var body: some View {
        NavigationStack {
            WorkingForm {
                if active {
                    if loading { ProgressView() }
                    else if available {
                        Section(dinnerText("Words to share with OpenAI")) {
                            if case .householdPreferences = basis.destination {
                                Text(dinnerText("Type only the words you want OpenAI to read. Leave out names and personal details. Review the suggestion before saving it to household preferences."))
                            } else {
                                Text(dinnerText("Type only the words you want to send. Leave out names and personal details. Your saved meal, preferences and feedback stay on this device."))
                            }
                            TextField(dinnerText("My words"), text: $wording).submitLabel(.done)
                                .accessibilityIdentifier("mealLanguage.note")
                            Button(dinnerText("Send these words for a suggestion")) { send() }
                                .disabled(pending != nil || review != nil || attempts >= 2 || !ReceiptLineAssistanceRequest.accepts(text))
                                .accessibilityIdentifier("mealLanguage.send")
                        }
                        if pending != nil { ProgressView() }
                        if let review {
                            Section(dinnerText("Review the proposed addition")) {
                                Text(verbatim: review.quote)
                                Text(review.choice.label)
                                Button(dinnerText("Add to my editable draft")) {
                                    do {
                                        let edited = try review.applying(current: current(), draft: draft(), text: text)
                                        guard active else { return }
                                        use(edited, basis)
                                        dismiss()
                                    } catch { clear(); message = dinnerText("The meal or draft changed. Open the suggestion again.") }
                                }.accessibilityIdentifier("mealLanguage.use")
                            }
                        }
                        if let message { Text(message) }
                    } else { Text(dinnerText("Online suggestions are unavailable. You can keep editing on this device.")) }
                } else { Text(dinnerText("The meal or draft changed. Open the suggestion again.")) }
            }.navigationTitle(dinnerText("Draft from my words"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(dinnerText("Cancel")) { dismiss() } } }
        }.privacySensitive()
        .task {
            guard active, let service = household.service else { loading = false; return }
            let offered = try? await service.languageAssistanceAvailable(purpose: original.purpose, scope: basis.account)
            guard !Task.isCancelled, active else { return }
            available = offered == true; loading = false
        }
        .onChange(of: wording) { _, _ in clear() }
        .onChange(of: active) { _, allowed in if !allowed { clear(); wording = ""; dismiss() } }
        .onDisappear { clear() }
    }

    private func clear() {
        sending?.cancel(); sending = nil; pending = nil; review = nil; message = nil
    }
    private func send() {
        guard available, active, pending == nil, attempts < 2, let service = household.service,
              let request = try? LanguageAssistanceRequest(consentingTo: [.init(id: UUID(), text: text)],
                locale: locale.language.languageCode?.identifier == "es" ? "es" : "en")
        else { return }
        attempts += 1; pending = request.requestID; message = nil
        sending = Task { @MainActor in
            do {
                try await verifyBasis?(basis)
                guard !Task.isCancelled, pending == request.requestID, active else { return }
                let reply: MealLanguageReply = try await service.languageSuggestion(purpose: original.purpose,
                    body: JSONEncoder().encode(request), scope: basis.account)
                try await verifyBasis?(basis)
                guard !Task.isCancelled, pending == request.requestID, active, text == request.sourceLines.first?.text else { return }
                review = try reply.review(for: request, basis: basis, draft: original)
                if review == nil { message = dinnerText("No addition was suggested. You can enter your choice manually.") }
            } catch {
                guard !Task.isCancelled, pending == request.requestID, active else { return }
                message = dinnerText("No usable addition was available. You can enter your choice manually.")
            }
            if pending == request.requestID { pending = nil; sending = nil }
        }
    }
}

extension MealLanguageChoice {
    var label: String {
        switch self {
        case .dislike: dinnerText("Soft preference · disliked ingredient")
        case .preferredBrand: dinnerText("Soft preference · preferred brand")
        case .makeAgain: dinnerText("Meal feedback · make again")
        case .tooMuchEffort: dinnerText("Meal feedback · too much effort")
        case .childrenLikedIt: dinnerText("Meal feedback · children liked it")
        case .tooManyLeftovers: dinnerText("Meal feedback · too many leftovers")
        }
    }
}
