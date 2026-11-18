import Foundation
import HouseholdClient
import SwiftUI

extension CaptureLineDraft {
    mutating func useLanguageSuggestion(_ suggestion: NaturalListSuggestion) {
        guard id == suggestion.sourceLineID, !skip else { return }
        name = suggestion.itemName
        if purpose.isEmpty, let proposed = suggestion.purpose { purpose = proposed }
        if exclusions.isEmpty, let proposed = suggestion.exclusion { exclusions = proposed }
        if !warnings.contains(.ambiguous) { warnings.append(.ambiguous) }
        confirmed = false
    }
}

@MainActor struct NaturalListLanguageEntry: View {
    @Binding var lines: [CaptureLineDraft]
    let locale: String
    let authorize: () -> Bool
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scene
    @State private var session: Session?

    private struct Session: Identifiable {
        let id = UUID()
        let identity: CapturePrivateIdentity
        let generation: FamilyDecisionAccess
        let scope: ReceiptAssistanceScope
        let lines: [CaptureLineDraft]
    }

    private var identity: CapturePrivateIdentity? {
        guard scene == .active, authorize(), !household.guardianChildOnly, household.projection?.grantId == nil,
              let current = CapturePrivateIdentity.current(access: access, household: household), current.subject != nil else { return nil }
        return current
    }
    private var scope: ReceiptAssistanceScope? {
        guard let identity, let subject = identity.subject, let member = identity.memberID, let house = identity.householdID else { return nil }
        return .init(subject: subject, householdID: house, memberID: member, shopID: household.projection?.shopId)
    }

    var body: some View {
        if let identity, let scope, let generation = household.decisionAccess, let service = household.service {
            Button(captureText("Get online help with item wording")) {
                session = .init(identity: identity, generation: generation, scope: scope, lines: lines)
            }.disabled(lines.allSatisfy(\.skip)).accessibilityIdentifier("capture.language.open")
            .sheet(item: $session) { snapshot in
                NavigationStack {
                    NaturalListLanguageReview(lines: snapshot.lines, locale: locale, service: service, scope: snapshot.scope,
                        isCurrent: { self.identity == snapshot.identity && household.decisionAccess == snapshot.generation && self.scope == snapshot.scope && lines == snapshot.lines },
                        use: { proposals in
                            guard self.identity == snapshot.identity, household.decisionAccess == snapshot.generation, self.scope == snapshot.scope, lines == snapshot.lines else { return }
                            for proposal in proposals {
                                if let index = lines.firstIndex(where: { $0.id == proposal.sourceLineID }) {
                                    lines[index].useLanguageSuggestion(proposal)
                                }
                            }
                            session = nil
                        })
                }
            }
            .onChange(of: self.scope) { _, _ in session = nil }
            .onChange(of: household.decisionAccess) { _, _ in session = nil }
            .onChange(of: scene) { _, phase in if phase != .active { session = nil } }
        }
    }
}

@MainActor private struct NaturalListLanguageReview: View {
    let lines: [CaptureLineDraft]
    let locale: String
    let service: HouseholdService
    let scope: ReceiptAssistanceScope
    let isCurrent: () -> Bool
    let use: ([NaturalListSuggestion]) -> Void

    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @State private var available: Bool?
    @State private var selected = Set<UUID>()
    @State private var excerpts: [UUID: String] = [:]
    @State private var applying = Set<UUID>()
    @State private var result: NaturalListReply?
    @State private var task: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var sending = false
    @State private var failed = false

    private var sourceLines: [LanguageSourceLine] {
        lines.filter { selected.contains($0.id) && !$0.skip }.map {
            .init(id: $0.id, text: (excerpts[$0.id] ?? $0.originalText).trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
    private var request: LanguageAssistanceRequest? {
        let language = Locale(identifier: locale).language.languageCode?.identifier ?? ""
        return try? .init(consentingTo: sourceLines, locale: language)
    }

    var body: some View {
        Form {
            if scene == .active, isCurrent() {
                if available == nil { ProgressView() }
                else if available == false { Text(captureText("Online help is unavailable. You can review every item on this device.")) }
                else if let result {
                    Section(captureText("Review proposed wording")) {
                        if result.suggestions.isEmpty { Text(captureText("No item wording was suggested.")) }
                        ForEach(result.suggestions, id: \.sourceLineID) { suggestion in
                            if let source = lines.first(where: { $0.id == suggestion.sourceLineID }) {
                                VStack(alignment: .leading) {
                                    Text(verbatim: source.originalText)
                                    Toggle(suggestion.itemName, isOn: membership(suggestion.sourceLineID, in: $applying))
                                    if source.purpose.isEmpty, let purpose = suggestion.purpose { LabeledContent(captureText("Purpose"), value: purpose) }
                                    if source.exclusions.isEmpty, let exclusion = suggestion.exclusion { LabeledContent(captureText("Exclusions"), value: exclusion) }
                                }
                            }
                        }
                        Button(captureText("Use selected wording in editable items")) {
                            guard isCurrent(), scene == .active else { return }
                            use(result.suggestions.filter { applying.contains($0.sourceLineID) })
                        }.disabled(applying.isEmpty).accessibilityIdentifier("capture.language.use")
                    }
                } else {
                    Section(captureText("Choose wording to share with OpenAI")) {
                        Text(captureText("Select up to eight items. Edit each excerpt to remove personal details. Sending shares just those excerpts, their reference IDs and the selected language."))
                        ForEach(lines.filter { !$0.skip }) { line in
                            Toggle(line.originalText, isOn: membership(line.id, in: $selected))
                                .disabled(sending || (!selected.contains(line.id) && selected.count >= 8))
                            if selected.contains(line.id) {
                                TextField(captureText("Wording to share"), text: Binding(get: { excerpts[line.id] ?? line.originalText },
                                    set: { excerpts[line.id] = $0 }), axis: .vertical).disabled(sending)
                            }
                        }
                        Button(captureText("Send selected wording for suggestions")) { send() }
                            .disabled(request == nil || sending).accessibilityIdentifier("capture.language.send")
                        if sending { ProgressView() }
                        if failed { Text(captureText("The suggestion could not be read. Keep editing your local items or try again.")) }
                    }
                }
            }
        }
        .navigationTitle(captureText("Item wording suggestions"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(captureText("Cancel")) { cancel(); dismiss() } } }
        .task {
            let value = (try? await service.languageAssistanceAvailable(purpose: "natural-list", scope: scope)) ?? false
            if !Task.isCancelled, isCurrent() { available = value }
        }
        .onDisappear { cancel() }
        .onChange(of: scene) { _, phase in if phase != .active { cancel(); dismiss() } }
    }

    private func membership(_ id: UUID, in values: Binding<Set<UUID>>) -> Binding<Bool> {
        Binding(get: { values.wrappedValue.contains(id) }, set: { chosen in
            if chosen { values.wrappedValue.insert(id) } else { values.wrappedValue.remove(id) }
        })
    }
    private func send() {
        guard let request, available == true, isCurrent(), scene == .active, !sending else { return }
        let token = UUID(); operation = token; failed = false; sending = true
        task = Task { @MainActor in
            do {
                let reply = try await service.naturalListSuggestion(request, scope: scope)
                guard token == operation, !Task.isCancelled, scene == .active, isCurrent() else { return }
                result = reply
            } catch { if token == operation && !Task.isCancelled && isCurrent() { failed = true } }
            if token == operation { sending = false }
        }
    }
    private func cancel() {
        operation = UUID(); task?.cancel(); task = nil; sending = false
    }
}
