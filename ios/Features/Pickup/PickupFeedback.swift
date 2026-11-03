import SwiftUI

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
    var incrementalBenefit: Int? { comparison == .same ? 0 : nil }
}

extension PickupJourney {
    var eligibleForFeedback: Bool { closedAt != nil && pickup != nil }
}

extension PickupModel {
    func recordFeedback(_ feedback: PickupFeedback?, shopID: UUID, revision: Int64, consent: Bool) async -> Bool {
        guard let current = journey, current.id == shopID, current.revision == revision,
              current.eligibleForFeedback, consent || feedback == nil else { return false }
        return await change { $0.feedback = feedback }
    }
}

struct PickupFeedbackSection: View {
    static let consentKey = "pickup.optionalFeedback.enabled"
    @AppStorage(Self.consentKey) private var enabled = false
    @ObservedObject var model: PickupModel
    let journey: PickupJourney

    var body: some View {
        if journey.eligibleForFeedback {
            if let answer = journey.feedback {
                Section(pTr("Your pickup feedback")) {
                    Text(answer.decision.label)
                    LabeledContent(pTr("Usual workflow"), value: answer.baseline.label)
                    LabeledContent(pTr("Compared with your usual workflow"), value: answer.comparison.label)
                    Button(pTr("Remove this response"), role: .destructive) {
                        Task { _ = await model.recordFeedback(nil, shopID: journey.id, revision: journey.revision, consent: enabled) }
                    }
                }
            } else if enabled {
                Section(pTr("Optional pickup feedback")) {
                    NavigationLink(pTr("Record how this pickup turned out")) {
                        PickupFeedbackEditor(model: model, shopID: journey.id, revision: journey.revision)
                    }
                    Button(pTr("Stop offering feedback")) { enabled = false }
                }
            }
        }
    }
}

private struct PickupFeedbackEditor: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage(PickupFeedbackSection.consentKey) private var enabled = false
    @ObservedObject var model: PickupModel
    let shopID: UUID
    let revision: Int64
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
            if failed { Text(pTr("Reopen this pickup to review its current version.")) }
            Button(pTr("Save my response")) {
                guard let decision, let baseline, let comparison else { return }
                Task {
                    let answer = PickupFeedback(decision: decision, baseline: baseline, comparison: comparison)
                    if await model.recordFeedback(answer, shopID: shopID, revision: revision, consent: enabled) { dismiss() }
                    else { failed = true }
                }
            }.disabled(!enabled || decision == nil || baseline == nil || comparison == nil || model.saving)
            Button(pTr("Stop offering feedback")) { enabled = false; dismiss() }
        }.navigationTitle(pTr("Optional pickup feedback"))
    }
}
