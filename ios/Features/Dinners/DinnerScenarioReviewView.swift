import SwiftUI
import CoreDomain

/// Composition seam for an explicit scenario-evidence editor. The initial dinner
/// home does not expose an empty or fabricated search. Callers supply reviewed
/// food/ingredient identities, stock, pack offers and the complete unchanged basket.
struct DinnerScenarioReviewView: View {
    @ObservedObject var model: DinnerFeatureModel
    let current: DinnerScenario
    let alternatives: [DinnerScenario]
    let selectedAcceptedDinnerIDs: Set<UUID>
    let cap: CheckoutCap?
    @State private var pairing: DinnerPairingResult?
    @State private var recovery: DinnerRecoveryResult?
    @State private var acceptsExtraTrip = false
    var body: some View {
        List {
            Section {
                Text(dinnerText("Review complete scenarios before changing a chosen dinner."))
                Button(model.paid ? dinnerText("Compare dinner pairings") : dinnerText("Explore pairings without applying")) {
                    do { pairing = try model.pair(current: current, alternatives: alternatives, selected: selectedAcceptedDinnerIDs, cap: cap, isolated: !model.paid); recovery = nil }
                    catch { model.report(error) }
                }
                Toggle(dinnerText("I accept an extra trip for a fallback"), isOn: $acceptsExtraTrip)
                Button(dinnerText("Review accepted fallbacks")) {
                    do { recovery = try model.recover(alternatives: alternatives, cap: cap, extraTripAccepted: acceptsExtraTrip); pairing = nil }
                    catch { model.report(error) }
                }.disabled(!model.paid)
            }
            if let pairing {
                Section(dinnerText("Pairing review")) {
                    Text(pairingStatus(pairing.status))
                    if pairing.untestedCount > 0 { Text(dinnerFormat("Untested alternatives: %d", pairing.untestedCount)) }
                    scenario(pairing.baseline)
                    ForEach(pairing.alternatives, id: \.scenarioID) { scenario($0) }
                }
            }
            if let recovery {
                Section(dinnerText("Fallback review")) {
                    if recovery.needsExtraTripConfirmation { Text(dinnerText("The preferred fallback requires an extra trip. Review that choice explicitly.")) }
                    if recovery.unresolved { Text(dinnerText("A complete feasible fallback has not been confirmed.")) }
                    ForEach(recovery.alternatives, id: \.scenarioID) { scenario($0) }
                }
            }
            Section { Text(dinnerText("These comparisons are read-only. Choosing, replacing or amending a dinner requires a separate reviewed action.")) }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Dinner scenarios")).dinnerAccess(model, budget: true)
    }
    private func scenario(_ result: DinnerScenarioResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(dinnerFormat("Checkout: %@", dinnerMoney(result.checkout.total.exact))).font(.headline)
            Text(result.foodCoverageComplete ? dinnerText("Reviewed food coverage is complete") : dinnerText("Food coverage is unresolved"))
            Text(result.timingFeasible == true ? dinnerText("Reviewed preparation fits the available time") : dinnerText("Preparation timing is unresolved or does not fit"))
            ForEach(result.issues, id: \.self) { Text(dinnerIssue($0)) }
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
    }
    private func pairingStatus(_ status: DinnerPairingResult.Status) -> String {
        switch status {
        case .proposals: return dinnerText("Reviewed pairing alternatives")
        case .noNewPairing: return dinnerText("No new pairing; these dinners are already selected.")
        case .noFeasiblePair: return dinnerText("No feasible new pair has been confirmed.")
        case .searchIncomplete: return dinnerText("The pairing search is incomplete.")
        }
    }
}
