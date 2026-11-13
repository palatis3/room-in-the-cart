import SwiftUI
import HouseholdClient

enum PickupDecision: String, Codable, CaseIterable {
    case acted, unchanged, tooLate, unknown, alreadyKnew, wrong

    var label: String {
        switch self {
        case .acted: pTr("I took action")
        case .unchanged: pTr("I kept my plan")
        case .tooLate: pTr("I found out too late")
        case .unknown: pTr("I am unsure")
        case .alreadyKnew: pTr("I already knew")
        case .wrong: pTr("The information was wrong")
        }
    }
}

enum PickupBaseline: String, Codable, CaseIterable {
    case retailer, list, usualRoutine, unknown

    var label: String {
        switch self {
        case .retailer: pTr("Retailer order preview")
        case .list: pTr("My usual list or notes")
        case .usualRoutine: pTr("Another usual shopping routine")
        case .unknown: pTr("I am unsure")
        }
    }
}

enum PickupComparison: String, Codable, CaseIterable {
    case same, different, unknown

    var label: String {
        switch self {
        case .same: pTr("Same result")
        case .different: pTr("Different result")
        case .unknown: pTr("I am unsure")
        }
    }
}

struct PickupFeedback: Codable, Equatable {
    let decision: PickupDecision
    let baseline: PickupBaseline
    let comparison: PickupComparison

    // A different self-reported result alone does not establish a verified benefit.
    var incrementalBenefit: Int? {
        comparison == .same || [.unchanged, .tooLate, .alreadyKnew, .wrong].contains(decision) ? 0 : nil
    }
}

extension PickupJourney {
    var eligibleForFeedback: Bool { closedAt != nil && pickup != nil }
}

/// Versioned local-workspace preference, separate from pickup/archive payloads,
/// billing and household service consent. Legacy unversioned booleans confer nothing.
@MainActor final class LocalPickupFeedbackConsent: ObservableObject {
    static let shared = LocalPickupFeedbackConsent()
    static let noticeVersion = "local-pickup-feedback-2026-11-03.v1"
    @Published private var acceptedVersions: [String: String]
    private var consentChanges: [UUID: UUID] = [:]
    private let defaults: UserDefaults
    private let storageKey: String
    init(defaults: UserDefaults = .standard, storageKey: String? = nil) {
        self.defaults = defaults
        #if DEBUG
        let prefix = ProcessInfo.processInfo.arguments.contains("--ui-testing") ? "uiTest." : ""
        #else
        let prefix = ""
        #endif
        self.storageKey = storageKey ?? prefix + "pickup.optionalFeedback.versionedConsents"
        acceptedVersions = defaults.dictionary(forKey: self.storageKey) as? [String: String] ?? [:]
    }
    func enabled(for workspaceID: UUID?) -> Bool {
        guard let workspaceID else { return false }
        return acceptedVersions[workspaceID.uuidString.lowercased()] == Self.noticeVersion
    }
    func authorization(for workspaceID: UUID) -> @MainActor () -> Bool {
        let change = consentChanges[workspaceID]
        return { self.enabled(for: workspaceID) && self.consentChanges[workspaceID] == change }
    }
    func setEnabled(_ value: Bool, for workspaceID: UUID?) {
        guard let workspaceID else { return }
        if enabled(for: workspaceID) != value { consentChanges[workspaceID] = UUID() }
        acceptedVersions[workspaceID.uuidString.lowercased()] = value ? Self.noticeVersion : nil
        defaults.set(acceptedVersions, forKey: storageKey)
    }
    func resetForUITest() { acceptedVersions = [:]; consentChanges = [:]; defaults.removeObject(forKey: storageKey) }
}

struct PickupFeedbackSection: View {
    static let consentKey: String = {
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") { return "uiTest.pickup.optionalFeedback.enabled" }
        #endif
        return "pickup.optionalFeedback.enabled"
    }()
    @ObservedObject private var consent = LocalPickupFeedbackConsent.shared
    @ObservedObject var model: PickupModel
    let journey: PickupJourney

    var body: some View {
        if journey.eligibleForFeedback {
            if let answer = journey.feedback {
                Section(pTr("Your pickup feedback")) {
                    Text(answer.decision.label)
                    LabeledContent(pTr("Usual workflow"), value: answer.baseline.label)
                    LabeledContent(pTr("Compared with your usual workflow"), value: answer.comparison.label)
                    if answer.incrementalBenefit == 0 {
                        Text(answer.comparison == .same ? pTr("You reported the same result. This pickup counts as zero additional benefit.") : pTr("This response counts as zero additional benefit."))
                            .font(.footnote)
                    }
                    Button(pTr("Remove this response"), role: .destructive) {
                        Task { _ = await model.recordFeedback(nil, shopID: journey.id, revision: journey.revision, consent: consent) }
                    }
                }
            } else if consent.enabled(for: model.sourceWorkspaceID) {
                Section(pTr("Optional pickup feedback")) {
                    NavigationLink(pTr("Record how this pickup turned out")) {
                        PickupFeedbackEditor(model: model, shopID: journey.id, revision: journey.revision)
                    }
                    Button(pTr("Stop offering feedback")) { consent.setEnabled(false, for: model.sourceWorkspaceID) }
                }
            }
        }
    }
}

private struct PickupFeedbackEditor: View {
    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var consent = LocalPickupFeedbackConsent.shared
    @ObservedObject var model: PickupModel
    @State private var shopID: UUID
    @State private var revision: Int64
    init(model: PickupModel, shopID: UUID, revision: Int64) {
        self.model = model
        _shopID = State(initialValue: shopID)
        _revision = State(initialValue: revision)
    }
    private var current: Bool { model.journey?.id == shopID && model.journey?.revision == revision }
    @State private var decision: PickupDecision?
    @State private var baseline: PickupBaseline?
    @State private var comparison: PickupComparison?
    @State private var failed = false

    var body: some View {
        Form {
            Text(pTr("This response stays with this pickup on your device. It contains only your choices."))
            Picker(pTr("What happened?"), selection: $decision) {
                Text(pTr("Choose a response")).tag(nil as PickupDecision?)
                ForEach(PickupDecision.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            Picker(pTr("Usual workflow"), selection: $baseline) {
                Text(pTr("Choose a response")).tag(nil as PickupBaseline?)
                ForEach(PickupBaseline.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            Picker(pTr("Compared with your usual workflow"), selection: $comparison) {
                Text(pTr("Choose a response")).tag(nil as PickupComparison?)
                ForEach(PickupComparison.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
            }
            if failed || !current { Text(pTr("Reopen this pickup to review its current version.")) }
            Button(pTr("Save my response")) {
                guard let decision, let baseline, let comparison else { return }
                Task {
                    let answer = PickupFeedback(decision: decision, baseline: baseline, comparison: comparison)
                    if await model.recordFeedback(answer, shopID: shopID, revision: revision, consent: consent) { dismiss() }
                    else { failed = true }
                }
            }.disabled(!current || !consent.enabled(for: model.sourceWorkspaceID) || decision == nil || baseline == nil || comparison == nil || model.saving)
            Button(pTr("Stop offering feedback")) { consent.setEnabled(false, for: model.sourceWorkspaceID); dismiss() }
        }.navigationTitle(pTr("Optional pickup feedback"))
    }
}

private struct MeasurementActionResult {
    let id = UUID()
    let scope: String
    let text: String
}

/// Separate opt-in for the authenticated household service. This view never reads
/// local feedback, shopping lists, receipts, grocery text, prices or membership files.
struct MeasurementSettingsView: View {
    @ObservedObject var household: HouseholdModel
    @State private var status: MeasurementStatus?
    @State private var busy = false
    @State private var failed = false
    @State private var actionResult: MeasurementActionResult?
    @AccessibilityFocusState private var resultFocused: Bool
    private var scope: String? {
        guard !household.locked, let identity = household.identity, let projection = household.projection,
              projection.grantId == nil else { return nil }
        return identity.subject + "/" + projection.household.id + "/" + projection.memberId
    }
    private var statusMessage: String? {
        if let actionResult { return actionResult.text }
        guard let status else { return nil }
        return status.consent == nil ? pTr("Household measurement is off") : pTr("Household measurement is enabled")
    }

    var body: some View {
        ScrollViewReader { proxy in
        Form {
            if scope != nil {
                if let result = statusMessage {
                    Text(result)
                        .id("measurement-consent-result")
                        .accessibilityIdentifier("measurement.consent.result")
                        .accessibilityFocused($resultFocused)
                }
                Section(pTr("Optional household measurement")) {
                    Text(pTr("If you choose to participate, the household service stores your response codes, shop identity, eligible week and this notice version. It can match verified membership status once per household to study purchase retention. Grocery text, prices, member names and existing local responses are not sent."))
                    Text(pTr("Participation is optional. You can keep using the entire pickup without sending feedback. Withdrawal removes responses sent under that consent and stops counting your participation."))
                    Text(MeasurementNotice.currentVersion).font(.caption).textSelection(.enabled)
                    if let status {
                        if let consent = status.consent {
                            Button(pTr("Withdraw household measurement consent"), role: .destructive) {
                                perform(successText: pTr("Household measurement consent was withdrawn.")) { service in try await service.withdrawMeasurementConsent(consent); return try await service.measurementStatus() }
                            }
                        } else {
                            Button(pTr("I agree to optional household measurement")) {
                                perform(successText: pTr("Household measurement is enabled")) { try await $0.grantMeasurementConsent(noticeVersion: MeasurementNotice.currentVersion) }
                            }
                        }
                    }
                    Button(pTr("Refresh measurement consent")) { perform { try await $0.measurementStatus() } }
                }
                if failed { Text(pTr("The service result is unconfirmed. Refresh before trying again.")) }
                if busy { ProgressView() }
            } else { Text(pTr("Return to the current authenticated adult household.")) }
        }
        .navigationTitle(pTr("Optional household measurement"))
        .disabled(busy)
        .task(id: scope) { status = nil; actionResult = nil; resultFocused = false; if scope != nil { perform { try await $0.measurementStatus() } } }
        .onChange(of: actionResult?.id) { _, id in
            resultFocused = false
            guard let id, let expected = scope, actionResult?.scope == expected else { return }
            Task { @MainActor in
                await Task.yield()
                guard scope == expected, actionResult?.id == id, actionResult?.scope == expected, !busy else { return }
                proxy.scrollTo("measurement-consent-result", anchor: .center)
                resultFocused = true
            }
        }
        }
    }
    private func perform(successText: String? = nil, _ operation: @escaping (HouseholdService) async throws -> MeasurementStatus) {
        guard !busy, let expected = scope, let service = household.service else { return }
        status = nil; busy = true; failed = false; actionResult = nil; resultFocused = false
        Task {
            defer { busy = false }
            do {
                let result = try await operation(service)
                guard scope == expected else { status = nil; return }
                status = result
                if let successText { actionResult = MeasurementActionResult(scope: expected, text: successText) }
            }
            catch { guard scope == expected else { status = nil; return }; failed = true }
        }
    }
}

/// Entered from a closed, placed shared shop. Every send is a new explicit choice;
/// no historical local response is populated or uploaded here.
struct SharedMeasurementFeedbackView: View {
    @ObservedObject var household: HouseholdModel
    let shopID: UUID
    @State private var status: MeasurementStatus?
    @State private var page: MeasurementFeedbackPage?
    @State private var decision: PickupDecision?
    @State private var baseline: PickupBaseline?
    @State private var comparison: PickupComparison?
    @State private var draftScope: String?
    @State private var draftConsentID: UUID?
    @State private var activeRequest: UUID?
    private var busy: Bool { activeRequest != nil }
    @State private var failed = false
    @State private var actionResult: MeasurementActionResult?
    @AccessibilityFocusState private var resultFocused: Bool
    private var scope: String? {
        guard !household.locked, let identity = household.identity, let projection = household.projection,
              projection.grantId == nil, projection.shopId?.lowercased() == shopID.uuidString.lowercased(), projection.role == "shopper" else { return nil }
        return identity.subject + "/" + projection.household.id + "/" + projection.memberId + "/" + shopID.uuidString
    }
    var body: some View {
        ScrollViewReader { proxy in
        Form {
            if let scope, scope == draftScope {
                Text(actionResult?.text ?? (page?.feedback != nil ? pTr("Household response recorded") : pTr("Only the choices entered here are sent to the household service. Your local pickup feedback stays on this device.")))
                    .id("measurement-feedback-result")
                    .accessibilityIdentifier("measurement.feedback.result")
                    .accessibilityFocused($resultFocused)
                if let page {
                    LabeledContent(pTr("Eligible week"), value: page.eligibleWeek)
                    if let feedback = page.feedback {
                        Text(localDecision(feedback.outcome).label)
                        if feedback.incrementalBenefit == 0 { Text(pTr("This response counts as zero additional benefit.")) }
                        Button(pTr("Remove household response"), role: .destructive) {
                            run(reportRemoval: true) { service in try await service.removeMeasurementFeedback(shopID: shopID, feedbackID: feedback.feedbackId) }
                        }
                    } else if status?.consent != nil {
                        Picker(pTr("What happened?"), selection: $decision) {
                            Text(pTr("Choose a response")).tag(nil as PickupDecision?)
                            ForEach(PickupDecision.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }
                        Picker(pTr("Usual workflow"), selection: $baseline) {
                            Text(pTr("Choose a response")).tag(nil as PickupBaseline?)
                            ForEach(PickupBaseline.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }
                        Picker(pTr("Compared with your usual workflow"), selection: $comparison) {
                            Text(pTr("Choose a response")).tag(nil as PickupComparison?)
                            ForEach(PickupComparison.allCases, id: \.self) { Text($0.label).tag(Optional($0)) }
                        }
                        Button(pTr("Send this coded household response")) {
                            guard let decision, let baseline, let comparison, let consent = status?.consent else { return }
                            let outcome: MeasurementAnswer.Outcome = decision == .tooLate ? .late : decision == .alreadyKnew ? .alreadyKnew : MeasurementAnswer.Outcome(rawValue: decision.rawValue)!
                            let answer = MeasurementAnswer(outcome: outcome, baseline: MeasurementAnswer.Baseline(rawValue: baseline.rawValue)!, comparison: MeasurementAnswer.Comparison(rawValue: comparison.rawValue)!)
                            run { service in _ = try await service.sendMeasurementFeedback(shopID: shopID, answer: answer, consent: consent) }
                        }.disabled(decision == nil || baseline == nil || comparison == nil)
                    }
                }
                if let status, status.consent == nil {
                    NavigationLink(pTr("Review optional household measurement")) { MeasurementSettingsView(household: household) }
                }
                Button(pTr("Refresh household response")) { run { _ in } }
                if failed { Text(pTr("The service result is unconfirmed. Refresh before trying again.")) }
                if busy { ProgressView() }
            } else if scope == nil { Text(pTr("Return to the current authenticated adult household.")) }
            else { ProgressView() }
        }.navigationTitle(pTr("Optional pickup feedback"))
            .disabled(busy)
            .task(id: scope) {
                activeRequest = nil; draftScope = scope; draftConsentID = nil; clearDraft()
                status = nil; page = nil; actionResult = nil; resultFocused = false
                if scope != nil { run { _ in } }
            }
            .onChange(of: actionResult?.id) { _, id in
                resultFocused = false
                guard let id, let expected = scope, actionResult?.scope == expected else { return }
                Task { @MainActor in
                    await Task.yield()
                    guard scope == expected, actionResult?.id == id, actionResult?.scope == expected, !busy else { return }
                    proxy.scrollTo("measurement-feedback-result", anchor: .center)
                    resultFocused = true
                }
            }
        }
    }
    private func run(reportRemoval: Bool = false, _ operation: @escaping (HouseholdService) async throws -> Void) {
        guard !busy, let expected = scope, expected == draftScope, let service = household.service else { return }
        let request = UUID()
        activeRequest = request
        status = nil; page = nil; failed = false; actionResult = nil; resultFocused = false
        Task {
            defer { if activeRequest == request { activeRequest = nil } }
            guard activeRequest == request, scope == expected else { return }
            do {
                try await operation(service)
                let currentStatus = try await service.measurementStatus()
                let currentPage = try await service.measurementFeedback(shopID: shopID)
                guard activeRequest == request, scope == expected else { return }
                // Keep unsent choices on an ordinary refresh of the same live
                // consent. A recorded answer or changed consent ends that draft.
                if currentPage.feedback != nil || currentStatus.consent?.consentId != draftConsentID {
                    clearDraft()
                }
                draftConsentID = currentStatus.consent?.consentId
                status = currentStatus; page = currentPage
                if currentPage.feedback != nil {
                    actionResult = MeasurementActionResult(scope: expected, text: pTr("Household response recorded"))
                } else if reportRemoval {
                    actionResult = MeasurementActionResult(scope: expected, text: pTr("Household response removed."))
                }
            } catch {
                guard activeRequest == request, scope == expected else { return }
                failed = true
            }
        }
    }
    private func clearDraft() {
        decision = nil; baseline = nil; comparison = nil
    }
    private func localDecision(_ value: MeasurementAnswer.Outcome) -> PickupDecision {
        value == .late ? .tooLate : value == .alreadyKnew ? .alreadyKnew : PickupDecision(rawValue: value.rawValue)!
    }
}
