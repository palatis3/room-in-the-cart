import SwiftUI
import CoreDomain

/// Composition seam for an explicit scenario-evidence editor. The initial dinner
/// home does not expose an empty or fabricated search. Callers supply reviewed
/// food/ingredient identities, stock, pack offers and the complete unchanged basket.
struct DinnerScenarioReviewView: View {
    @ObservedObject var model: DinnerFeatureModel
    @Environment(\.closeDinnerDecision) private var closeDecision
    let current: DinnerScenario
    let alternatives: [DinnerScenario]
    let selectedAcceptedDinnerIDs: Set<UUID>
    let cap: CheckoutCap?
    var excludedByRules: [String] = []
    var library: DinnerLibraryPairings?
    @State private var showReplacement = false
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
                .accessibilityIdentifier("dinnerComparePairings")
                Toggle(dinnerText("I accept an extra trip for a fallback"), isOn: $acceptsExtraTrip)
                Button(dinnerText("Review accepted fallbacks")) {
                    do { recovery = try model.recover(alternatives: alternatives, cap: cap, extraTripAccepted: acceptsExtraTrip); pairing = nil }
                    catch { model.report(error) }
                }.disabled(!model.paid)
            }
            if let pairing {
                Section(dinnerText("Pairing review")) {
                    Text(pairingStatus(pairing.status))
                    if !excludedByRules.isEmpty { Text(dinnerFormat("Excluded by the reviewed food rules: %@",excludedByRules.joined(separator: ", "))) }
                    if pairing.untestedCount > 0 { Text(dinnerFormat("Untested alternatives: %d", pairing.untestedCount)) }
                    scenario(pairing.baseline)
                    ForEach(pairing.alternatives, id: \.scenarioID) { result in
                        scenario(result)
                        if let library, result.feasible, result.checkout.total.exact != nil, let shop = model.shop,
                           let candidate = alternatives.first(where: { $0.id == result.scenarioID }) {
                            if (try? library.replacement(for: candidate, shop: shop, state: model.state)) != nil {
                                Button(dinnerText("Preview this exact dinner replacement")) {
                                    do {
                                        let changes = try library.replacement(for: candidate, shop: shop, state: model.state)
                                        showReplacement = model.prepare(changes, tool: .pairing, isolated: !model.paid, expectedRevision: library.shopRevision)
                                    } catch { model.report(error) }
                                }
                                .accessibilityLabel(dinnerFormat("Preview %@ for %@",library.candidates.first(where: { $0.id == candidate.id })?.title ?? dinnerText("Candidate plan"),
                                    candidate.commitments.commitments.first(where: { $0.id == library.target })?.name ?? dinnerText("Current plan")))
                                .accessibilityIdentifier("dinnerReplacement-\(candidate.id)")
                            } else { Text(dinnerText("This comparison changes a serving group or a linked recipe. Review a manual edit to keep the other portions.")) }
                        }
                    }
                }
            }
            if let recovery, model.paid {
                Section(dinnerText("Fallback review")) {
                    if recovery.needsExtraTripConfirmation { Text(dinnerText("The preferred fallback requires an extra trip. Review that choice explicitly.")) }
                    if recovery.unresolved { Text(dinnerText("A complete feasible fallback has not been confirmed.")) }
                    ForEach(recovery.alternatives, id: \.scenarioID) { scenario($0) }
                }
            }
            Section {
                Text(dinnerText("These comparisons are read-only. Choosing, replacing or amending a dinner requires a separate reviewed action."))
                NavigationLink(dinnerText("Review candidate dinners separately")) {
                    DinnerScenarioChoicesView(model: model, acceptedIDs: Set(alternatives.flatMap(\.acceptedDinnerIDs)))
                }
                NavigationLink(dinnerText("Add a manual dinner")) { DinnerTemplateEditor(model: model, purpose: .manual) }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Dinner scenarios")).dinnerAccess(model, budget: true)
            .toolbar {
                if let closeDecision {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(dinnerText("Cancel"), action: closeDecision).accessibilityIdentifier("dinnerDecisionCancel")
                    }
                }
            }
            .dinnerApplyPresentation(model, presented: $showReplacement)
    }
    private func scenario(_ result: DinnerScenarioResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let source = ([current] + alternatives).first { $0.id == result.scenarioID }
            Text(result.scenarioID == current.id ? dinnerText("Current plan") : dinnerText("Candidate plan")).font(.title3.bold())
            Text(dinnerFormat("Checkout: %@", dinnerMoney(result.checkout.total.exact))).font(.headline)
            Text(dinnerCap(result.checkout.cap))
            if let source {
                ForEach(source.acceptedDinnerIDs, id: \.self) { id in
                    if let dinner = model.state.acceptedDinners.first(where: { $0.id == id }) { Text(dinner.template.title).font(.headline) }
                }
                ForEach(source.commitments.commitments) { c in
                    Text("\(c.name) · \(c.portions.description) \(c.protected ? dinnerText("Protected commitment") : dinnerText("Required portions"))")
                }
                if let baseline = pairing?.baseline, baseline.scenarioID != result.scenarioID,
                   baseline.feasible && result.feasible {
                    let changed = Set(baseline.packs.map(\.foodID) + result.packs.map(\.foodID))
                    ForEach(changed.sorted(by: { $0.uuidString < $1.uuidString }), id: \.self) { id in
                        let old = baseline.packs.first { $0.foodID == id }?.result?.packsToBuy ?? 0
                        let new = result.packs.first { $0.foodID == id }?.result?.packsToBuy ?? 0
                        if old != new {
                            let name = (source.demands + current.demands).first { $0.foodID == id }?.name ?? dinnerText("Food name")
                            Text(dinnerFormat("%@ · packages change from %lld to %lld",name,old,new))
                        }
                    }
                }
                ForEach(result.stockAllocation.demands) { need in
                    let name = source.demands.first { $0.id == need.id }?.name ?? source.otherReservations.first { $0.id == need.id }?.name ?? dinnerText("Protected need")
                    Text(dinnerFormat("%@ · confirmed stock allocated: %@ %@", name, need.allocated?.description ?? dinnerText("Unresolved"), dinnerUnit(need.unit)))
                }
                ForEach(result.packs, id: \.foodID) { pack in
                    let demand = source.demands.first { $0.foodID == pack.foodID }
                    let unit = demand?.quantity?.unit
                    Text(demand?.name ?? dinnerText("Food name")).font(.headline)
                    if let calculated = pack.result {
                        Text(dinnerFormat("Packs to buy: %@", calculated.packsToBuy.map(String.init) ?? dinnerText("Unresolved")))
                        Text(dinnerFormat("Pack purchase cost: %@", dinnerMoney(calculated.totalCost)))
                        if let leftover = calculated.leftover, let unit { Text(dinnerFormat("Usable leftover: %@ %@", leftover.description, dinnerUnit(unit))) }
                    } else { Text(pack.availabilityConfirmed ? dinnerText("Need covered by confirmed stock") : dinnerText("Pack amount or coverage is unresolved")) }
                }
            }
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

private struct DinnerScenarioChoicesView: View {
    @ObservedObject var model: DinnerFeatureModel
    let acceptedIDs: Set<UUID>
    @State private var showPreview = false
    var body: some View {
        List {
            Section {
                Text(dinnerText("Choosing uses the accepted recipe's saved servings. It does not apply scenario portions, stock allocations, pack purchases or quoted costs."))
                Text(dinnerText("Existing chosen dinners remain. Review a separate removal when replacing a dinner."))
            }
            ForEach(model.state.acceptedDinners.filter { acceptedIDs.contains($0.id) }) { dinner in
                Section(dinner.template.title) {
                    Text(dinnerFormat("Servings: %@", dinner.template.servings.description))
                    ForEach(dinner.template.ingredients) { ingredient in Text(dinnerFormat("%@ · %@", ingredient.name, dinnerQuantity(ingredient.quantity))) }
                    if !model.paid && model.state.freeReusableDinnerID != dinner.id {
                        Button(dinnerText("Use as Free reusable dinner")) { Task { _ = await model.selectFree(dinner.id) } }
                    }
                    Button(dinnerText("Choose for this pickup")) { showPreview = model.choose(dinner, day: nil) }
                        .disabled(!model.editable || (!model.paid && model.state.freeReusableDinnerID != dinner.id))
                }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Candidate dinners")).dinnerAccess(model)
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
