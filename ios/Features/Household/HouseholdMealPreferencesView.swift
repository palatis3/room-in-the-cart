import CoreDomain
import HouseholdClient
import SwiftUI

struct HouseholdPreferenceScope: Hashable {
    let generation: UUID
    let enrollment: UUID
    let subject: String
    let householdID: String
    let memberID: String
    let administer: Bool
}

struct HouseholdMealPreferencesLink: View {
    @ObservedObject var household: HouseholdModel
    var source: FamilyDecisionRecord? = nil
    var body: some View {
        if let scope = household.mealPreferenceScope, let service = household.service {
            NavigationLink(dinnerText(source == nil ? "Household meal preferences" : "Review a household preference from this note")) {
                HouseholdMealPreferencesView(household: household, scope: scope, service: service, source: source, sourceAccess: household.decisionAccess)
            }.accessibilityIdentifier("household.mealPreferences")
        }
    }
}

private struct HouseholdMealPreferencesView: View {
    @ObservedObject var household: HouseholdModel
    let scope: HouseholdPreferenceScope
    let service: HouseholdService
    let source: FamilyDecisionRecord?
    let sourceAccess: FamilyDecisionAccess?
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.guardianChildCoordinator) private var child
    @State private var session: HouseholdDeviceSession?
    @State private var page: HouseholdPreferencePage<MealPreferenceSettings>?
    @State private var grants: HouseholdAdultGrants?
    @State private var failed = false
    @State private var busy = false
    @State private var editing = false
    @State private var request = UUID()
    @State private var saveIssue: String?
    private var active: Bool {
        scenePhase == .active && household.mealPreferenceScope == scope &&
            (source == nil || (sourceAccess != nil && household.decisionAccess == sourceAccess))
    }
    var body: some View {
        Group {
            if active {
                JournalList {
                    if let page {
                        if let settings = page.settings { MealPreferenceSummary(settings: settings) }
                        else { Text(dinnerText("No household meal preferences saved.")) }
                        if page.canWrite && scope.administer {
                            if let source, let session {
                                HistoricalPreferencePromotion(record: source, settings: page.settings ?? .init()) { proposed, reference in
                                    await save(proposed, reviewed: page, session: session, source: reference)
                                }
                                .id(page.revision)
                            }
                            Button(dinnerText("Edit household preferences")) { editing = true }
                                .accessibilityIdentifier("household.preferences.edit")
                            if let grants {
                                Section(dinnerText("Adults who can read preferences")) {
                                    ForEach(grants.adults) { adult in
                                        Toggle(adult.label, isOn: Binding(get: { adult.enabled }, set: { enabled in
                                            Task { await changeGrant(adult, enabled: enabled) }
                                        }))
                                    }
                                }
                            }
                        }
                    }
                    if busy { ProgressView() }
                    if let saveIssue { Text(saveIssue) }
                    if failed { Text(dinnerText("Household preferences are unavailable. Refresh to check current access.")) }
                    Button(dinnerText("Refresh household preferences")) { Task { await load() } }
                }.disabled(busy)
            } else { Text(dinnerText("Household preference access changed. Reopen Settings.")) }
        }.navigationTitle(dinnerText("Household meal preferences"))
        .task(id: active) {
            revoke()
            if active { await load() }
        }
        .onDisappear { revoke() }
        .sheet(isPresented: $editing) {
            if active, let page, page.canWrite, let session {
                NavigationStack {
                    MealPreferenceEditor(profile: page.revision.map { MealPreferenceProfile(revision: $0, settings: page.settings ?? .init()) },
                        canSetTimeLimit: page.supportsTimeLimit == true, languageBasis: { revision in
                            languageBasis(revision: revision, reviewed: page, session: session)
                        }, verifyLanguageBasis: { expected in
                            guard languageBasis(revision: expected.revision, reviewed: page, session: session) == expected,
                                  try await service.preferencePage(MealPreferenceSettings.self, session: session) == page,
                                  languageBasis(revision: expected.revision, reviewed: page, session: session) == expected
                            else { throw ClientError.accessEnded }
                        }) { settings, revision, assisted in
                        guard page.revision == revision else { return false }
                        return await save(settings, reviewed: page, session: session, assisted: assisted)
                    }.environmentObject(household)
                    .navigationTitle(dinnerText("Edit household preferences"))
                }
            }
        }
    }
    private func languageBasis(revision: UUID?, reviewed: HouseholdPreferencePage<MealPreferenceSettings>,
                               session: HouseholdDeviceSession) -> MealLanguageBasis? {
        guard active, UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable, child?.presented != true,
              self.session == session, page == reviewed, let projection = household.projection,
              ["organizer", "shopper"].contains(projection.role) else { return nil }
        return .householdPreferences(scope: scope, session: session, page: reviewed, revision: revision, selectedShop: projection.shopId)
    }
    private func save(_ settings: MealPreferenceSettings, reviewed: HouseholdPreferencePage<MealPreferenceSettings>,
                      session: HouseholdDeviceSession, source: HouseholdPreferenceSource? = nil,
                      assisted: MealLanguageBasis? = nil) async -> Bool {
        let current = request
        func authorized() -> Bool {
            active && scope.administer && reviewed.canWrite && page == reviewed && self.session == session &&
                current == request && (assisted == nil || languageBasis(revision: reviewed.revision, reviewed: reviewed, session: session) == assisted)
        }
        guard authorized(), !busy else { return false }
        busy = true
        defer { if current == request { busy = false } }
        do {
            try settings.validate()
            let value = settings == MealPreferenceSettings() ? nil : settings
            let intent = try await service.preparePreferenceWrite(value, reviewed: reviewed, session: session, sourceDecision: source, timeLimitReviewed: true)
            guard authorized() else { return false }
            let updated = try await service.savePreferences(intent, as: MealPreferenceSettings.self)
            guard authorized() else { return false }
            try updated.settings?.validate()
            page = updated
            return true
        } catch {
            // Read authoritative state after a lost response or stale source.
            if current == request {
                await load()
                guard active else { return false }
                if case ClientError.service(403, "membership_inactive", _, _) = error {
                    saveIssue = dinnerText("A current household seat is required to promote a saved note.")
                } else {
                    saveIssue = dinnerText("Check the current profile before reviewing this change again.")
                }
            }
            return false
        }
    }
    private func revoke() {
        request = UUID()
        editing = false
        page = nil; grants = nil; session = nil; busy = false; failed = false; saveIssue = nil
    }
    private func load() async {
        revoke()
        guard active, let projection = household.projection else { return }
        let current = request
        busy = true
        defer { if current == request { busy = false } }
        do {
            let session = try await service.preferenceSession(for: projection)
            let page = try await service.preferencePage(MealPreferenceSettings.self, session: session)
            try page.settings?.validate()
            if let source {
                let latest = try await service.familyDecision(shopID: source.shopId, id: source.id)
                guard source == latest else { throw ClientError.accessEnded }
            }
            let grants = scope.administer && page.canWrite ? try await service.preferenceGrants(session: session) : nil
            guard current == request, active, !Task.isCancelled else { return }
            self.session = session; self.page = page; self.grants = grants
        } catch { if current == request && active { failed = true } }
    }
    private func changeGrant(_ adult: HouseholdAdultGrants.Adult, enabled: Bool) async {
        guard active, scope.administer, let session, !busy else { return }
        let current = request
        busy = true
        defer { if current == request { busy = false } }
        do {
            let result = try await service.setPreferenceRead(enabled, adult: adult, session: session)
            guard current == request, active else { return }
            grants = result
        } catch { await load() }
    }
}

private struct MealPreferenceSummary: View {
    let settings: MealPreferenceSettings
    var body: some View {
        Section(dinnerText("Hard constraints")) {
            ForEach(settings.exclusions, id: \.self) { Text(dinnerFormat("Excluded ingredient: %@", $0)) }
            if let appliances = settings.availableAppliances {
                LabeledContent(dinnerText("Available appliances"), value: appliances.joined(separator: ", "))
            }
        }
        Section(dinnerText("Preferences")) {
            ForEach(settings.dislikes, id: \.self) { Text(dinnerFormat("Disliked ingredient: %@", $0)) }
            if settings.strictDislikes { Text(dinnerText("Require meals without these dislikes")) }
            if !settings.preferredBrands.isEmpty {
                LabeledContent(dinnerText("Preferred brands"), value: settings.preferredBrands.joined(separator: ", "))
                if settings.strictBrands { Text(dinnerText("Require preferred brands")) }
            }
            if let limit = settings.timeLimit {
                LabeledContent(dinnerText("Available cooking minutes"), value: limit.maximumMinutes.formatted())
                if limit.strict { Text(dinnerText("Require meals within this time")) }
            }
            if let effort = settings.maximumEffort {
                switch effort {
                case .low: Text(dinnerText("Low effort"))
                case .medium: Text(dinnerText("Medium effort"))
                case .high: Text(dinnerText("High effort"))
                }
                if settings.strictEffort { Text(dinnerText("Require this effort limit")) }
            }
        }
    }
}

private struct HistoricalPreferencePromotion: View {
    let record: FamilyDecisionRecord
    let settings: MealPreferenceSettings
    let save: (MealPreferenceSettings, HouseholdPreferenceSource) async -> Bool
    @State private var field = HouseholdPreferenceSource.Field.dislikes
    @State private var term = ""
    @State private var reviewing = false
    @FocusState private var focused: Bool
    private var clean: String { term.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var proposed: MealPreferenceSettings {
        var result = settings
        switch field {
        case .exclusions: result.exclusions.append(clean)
        case .dislikes: result.dislikes.append(clean)
        case .preferredBrands: result.preferredBrands.append(clean)
        }
        return result
    }
    private func title(_ field: HouseholdPreferenceSource.Field) -> String {
        switch field {
        case .exclusions: dinnerText("Excluded ingredient")
        case .dislikes: dinnerText("Disliked ingredient")
        case .preferredBrands: dinnerText("Preferred brand")
        }
    }
    var body: some View {
        Section(dinnerText("Review a household preference from this note")) {
            Text(verbatim: record.decision)
            Picker(dinnerText("Preference type"), selection: $field) {
                ForEach(HouseholdPreferenceSource.Field.allCases, id: \.self) { field in Text(title(field)).tag(field) }
            }
            TextField(dinnerText("Exact ingredient or brand"), text: $term).focused($focused)
            Button(dinnerText("Review household rule")) { focused = false; reviewing = true }
                .disabled((try? proposed.validate()) == nil)
        }
        .confirmationDialog(dinnerText("Save this household rule?"), isPresented: $reviewing, titleVisibility: .visible) {
            Button(dinnerText("Save household rule")) {
                let reference = HouseholdPreferenceSource(record: record, field: field, term: clean)
                let candidate = proposed
                Task { _ = await save(candidate, reference) }
            }
        } message: { Text(verbatim: "\(title(field)) · \(clean)") }
    }
}
