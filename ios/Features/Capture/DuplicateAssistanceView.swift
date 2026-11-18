import HouseholdClient
import SwiftUI

/// The only effect of accepting a suggestion is to prefill the existing local review.
struct DuplicateAssistanceView: View {
    let source: LanguageSourceLine
    let candidates: [LanguageSourceLine]
    var family: FamilyDuplicateBasis?
    var language: String?
    let authorized: @MainActor () -> Bool
    var familyHouseholdID: String?
    var familyMemberID: String?
    let select: @MainActor (UUID) async -> Void
    @Environment(\.offersDuplicateAssistance) private var configured

    var body: some View {
        if configured {
            DuplicateAssistanceControls(source: source, candidates: candidates, family: family, language: language, authorized: authorized,
                select: select, familyHouseholdID: familyHouseholdID, familyMemberID: familyMemberID)
        }
    }
}

private struct DuplicateAssistanceKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var offersDuplicateAssistance: Bool {
        get { self[DuplicateAssistanceKey.self] }
        set { self[DuplicateAssistanceKey.self] = newValue }
    }
}

private struct DuplicateAssistanceControls: View {
    let source: LanguageSourceLine
    let candidates: [LanguageSourceLine]
    let family: FamilyDuplicateBasis?
    let language: String?
    let authorized: @MainActor () -> Bool
    let select: @MainActor (UUID) async -> Void
    let familyHouseholdID: String?
    let familyMemberID: String?
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var guardian
    @Environment(\.scenePhase) private var scene
    @State private var expanded = false
    @State private var available = false
    @State private var checked = false
    @State private var attempt: UUID?
    @State private var suggested: UUID?
    @State private var finished = false

    private struct Preview: Equatable {
        let scope: ReceiptAssistanceScope
        let actor: UUID
        let locale: String
        let source: LanguageSourceLine
        let candidates: [LanguageSourceLine]
        let family: FamilyDuplicateBasis?
    }

    private var preview: Preview? {
        guard scene == .active, !household.guardianChildOnly, guardian?.presented != true, authorized(),
              let projection = household.projection, projection.enrolled, projection.grantId == nil,
              !household.locked, let subject = household.identity?.subject,
              ["shopper", "organizer"].contains(projection.role),
              !candidates.isEmpty, source.text == source.text.trimmingCharacters(in: .whitespacesAndNewlines),
              ReceiptLineAssistanceRequest.accepts(source.text) else { return nil }
        if let family {
            guard projection.role == "shopper", projection.household.id == familyHouseholdID, projection.memberId == familyMemberID,
                  projection.shopId.flatMap(UUID.init(uuidString:)) == family.shopID else { return nil }
        } else if CapturePrivateIdentity.current(access: access, household: household) == nil { return nil }
        let offered = candidates.filter { ReceiptLineAssistanceRequest.accepts($0.text) &&
            $0.text == $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }.prefix(8)
        guard !offered.isEmpty else { return nil }
        return .init(scope: .init(subject: subject, householdID: projection.household.id, memberID: projection.memberId, shopID: projection.shopId),
                     actor: access.localActorID, locale: language ?? (Bundle.main.preferredLocalizations.first?.hasPrefix("es") == true ? "es" : "en"), source: source, candidates: Array(offered), family: family)
    }

    var body: some View {
        Group {
            if let shown = preview {
                if expanded {
                    Text(duplicateHelpText("Only these words and candidate labels will be shared with OpenAI."))
                    Text(verbatim: shown.source.text)
                    ForEach(shown.candidates) { candidate in Text(verbatim: candidate.text) }
                    if let suggested, let match = shown.candidates.first(where: { $0.id == suggested }) {
                        Text(duplicateHelpText("Suggested match")).font(.headline)
                        Text(verbatim: match.text)
                        Button(duplicateHelpText("Use this candidate in my review")) {
                            guard preview == shown, authorized() else { reset(); return }
                            Task {
                                guard expanded, suggested == match.id, preview == shown else { return }
                                await select(match.id)
                                reset()
                            }
                        }.accessibilityIdentifier("duplicates.assistance.use")
                    } else if finished {
                        Text(duplicateHelpText("No suggestion is available. You can compare the choices yourself."))
                    } else if !checked || attempt != nil {
                        ProgressView()
                    } else if available {
                        Button(duplicateHelpText("Send these words and compare")) { attempt = UUID() }
                            .accessibilityIdentifier("duplicates.assistance.send")
                    } else {
                        Text(duplicateHelpText("Online matching is unavailable. You can compare the choices yourself."))
                    }
                    Button(duplicateHelpText("Cancel comparison")) { reset() }
                } else {
                    Button(duplicateHelpText("Get help comparing these choices")) { expanded = true }
                        .accessibilityIdentifier("duplicates.assistance.open")
                }
            }
        }
        .privacySensitive()
        .onChange(of: preview) { _, _ in reset() }
        .onDisappear { reset() }
        .task(id: expanded) {
            guard expanded, let shown = preview else { return }
            guard let service = household.service else { checked = true; return }
            let result = try? await service.languageAssistanceAvailable(purpose: family == nil ? "receipt-alias" : "request-duplicate", scope: shown.scope)
            guard !Task.isCancelled, expanded, preview == shown else { return }
            available = result == true; checked = true
        }
        .task(id: attempt) {
            guard let attempt, let shown = preview, expanded, available, let service = household.service else { return }
            do {
                let request = try DuplicateAssistanceRequest(consentingTo: shown.source, candidates: shown.candidates,
                                                             locale: shown.locale, family: shown.family)
                let reply: DuplicateAssistanceReply = try await service.languageSuggestion(purpose: request.purpose,
                    body: JSONEncoder().encode(request), scope: shown.scope)
                let id = try reply.candidate(for: request)
                guard !Task.isCancelled, self.attempt == attempt, preview == shown, expanded else { return }
                suggested = id
            } catch {
                guard !Task.isCancelled, self.attempt == attempt, preview == shown, expanded else { return }
            }
            finished = true; self.attempt = nil
        }
    }

    private func reset() {
        expanded = false; available = false; checked = false
        attempt = nil; suggested = nil; finished = false
    }
}

private func duplicateHelpText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "RequestDuplicates")
}
