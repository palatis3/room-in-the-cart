import SwiftUI
import CoreDomain

/// Composition seam for an explicit scenario-evidence editor. The initial dinner
/// home does not expose an empty or fabricated search. Callers supply reviewed
/// food/ingredient identities, stock, pack offers and the complete unchanged basket.
struct DinnerScenarioReviewView: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.closeDinnerDecision) private var closeDecision
    @Environment(\.dinnerHousehold) private var household
    @Environment(\.guardianChildCoordinator) private var child
    let current: DinnerScenario
    let alternatives: [DinnerScenario]
    let selectedAcceptedDinnerIDs: Set<UUID>
    let cap: CheckoutCap?
    var excludedByRules: [String] = []
    var library: DinnerLibraryPairings?
    var reviewedPantryBasis: LedgerCanonicalPackStockEvidence.Basis?
    @State private var showReplacement = false
    @State private var currentCost: DinnerScenarioResult?
    @State private var suggestedPair: UUID?
    @State private var pairing: DinnerPairingResult?
    @State private var recovery: DinnerRecoveryResult?
    @State private var acceptsExtraTrip = false
    var body: some View {
        JournalList {
            Section {
                Text(dinnerText("Review complete scenarios before changing a chosen dinner."))
                Button(dinnerText("Price the current dinner plan")) {
                    do {
                        currentCost = try model.cost(of: current, cap: cap)
                        pairing = nil; recovery = nil
                    }
                    catch { currentCost = nil; model.report(error) }
                }.accessibilityIdentifier("dinnerCurrentCost")
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
            if let currentCost, pairing == nil, recovery == nil {
                Section { scenario(currentCost) }
            }
            if let pairing {
                Section(dinnerText("Pairing review")) {
                    Text(pairingStatus(pairing.status))
                    if !excludedByRules.isEmpty { Text(dinnerFormat("Excluded by the reviewed food rules: %@",excludedByRules.joined(separator: ", "))) }
                    if pairing.untestedCount > 0 { Text(dinnerFormat("Untested alternatives: %d", pairing.untestedCount)) }
                    if !model.paid, let household, household.canOpenMembership, child?.presented != true {
                        NavigationLink(mtr("Review Household for dinner comparisons")) {
                            MembershipEntryView(household: household)
                        }.accessibilityIdentifier("dinner.pairings.membership")
                    }
                    scenario(pairing.baseline)
                    if model.paid, model.localIdeaWorkspaceID != nil, let library,
                       pairing.alternatives.contains(where: { $0.feasible && $0.checkout.total.exact != nil }) {
                        MealChoiceWordingLink(refresh: {
                            if pickup.pantryIsActive { return await pickup.refreshPantryStock() }
                            return pickup.ready
                        }, makeSource: { try wordingPairings(library, pairing: pairing) })
                    }
                    let ordered = pairing.alternatives.sorted { $0.scenarioID == suggestedPair && $1.scenarioID != suggestedPair }
                    ForEach(ordered, id: \.scenarioID) { result in
                        if result.scenarioID == suggestedPair { Text(mealExplanationText("Selected for local review")) }
                        scenario(result)
                        if let library, result.feasible, result.checkout.total.exact != nil, let shop = model.shop,
                           let candidate = alternatives.first(where: { $0.id == result.scenarioID }) {
                            if (try? library.replacement(for: candidate, shop: shop, state: model.state)) != nil {
                                Button(dinnerText("Preview this exact dinner replacement")) {
                                    do {
                                        if model.paid && model.localIdeaWorkspaceID != nil {
                                            let review = try model.prepareSwap(library: library, scenario: candidate,
                                                reviewedPantryBasis: reviewedPantryBasis, pickup: pickup)
                                            showReplacement = model.installSwap(review, pickup: pickup)
                                        } else {
                                            let changes = try library.replacement(for: candidate, shop: shop, state: model.state)
                                            showReplacement = model.prepare(changes, tool: .pairing, isolated: !model.paid,
                                                expectedRevision: library.shopRevision, reviewedPantryBasis: reviewedPantryBasis)
                                        }
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
    private func wordingPairings(_ library: DinnerLibraryPairings, pairing evidence: DinnerPairingResult) throws -> MealChoiceSource {
        guard model.paid, let owner = model.editorIdentity, let workspaceID = model.localIdeaWorkspaceID else {
            throw DinnerPlanningError.forbidden
        }
        let workspace = model.workspace, inventory = pickup.pantrySnapshot?.state, selectedPickup = pickup.journey
        func candidates() throws -> [MealChoiceWording.Option] {
            guard model.editorIdentity == owner, model.paid, model.localIdeaWorkspaceID == workspaceID, model.workspace == workspace,
                  pickup.journey == selectedPickup, pickup.pantrySnapshot?.state == inventory,
                  try model.pair(current: current, alternatives: alternatives, selected: selectedAcceptedDinnerIDs, cap: cap) == evidence
            else { throw DinnerPlanningError.stalePreview }
            return evidence.alternatives.compactMap { result in
                guard result.feasible, result.checkout.total.exact != nil,
                      let scenario = alternatives.first(where: { $0.id == result.scenarioID }),
                      let review = try? model.prepareSwap(library: library, scenario: scenario, reviewedPantryBasis: reviewedPantryBasis, pickup: pickup)
                else { return nil }
                return .init(id: scenario.id, title: review.replacement.title)
            }
        }
        let options = try candidates()
        return .init(options: options, isCurrent: { (try? candidates()) == options }) { id in
            guard try candidates() == options, options.contains(where: { $0.id == id }) else { throw DinnerPlanningError.stalePreview }
            suggestedPair = id
        }
    }

    private func scenario(_ result: DinnerScenarioResult) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            let source = ([current] + alternatives).first { $0.id == result.scenarioID }
            Text(result.scenarioID == current.id ? dinnerText("Current plan") : dinnerText("Candidate plan")).font(.title3.bold())
            if let total = result.checkout.total.exact {
                Text(dinnerFormat("Checkout: %@", dinnerMoney(total))).font(.headline)
            } else if let upper = result.checkout.total.upperBound {
                Text(dinnerFormat("Estimated checkout range: %@ to %@", dinnerMoney(result.checkout.total.lowerBound), dinnerMoney(upper))).font(.headline)
            } else {
                Text(dinnerFormat("Incomplete checkout · at least %@", dinnerMoney(result.checkout.total.lowerBound))).font(.headline)
            }
            Text(dinnerCap(result.checkout.cap))
            if let source {
                Text(dinnerFormat("Price evidence: %@ · %@", source.context.source,
                    source.context.observedAt.formatted(date: .abbreviated, time: .shortened)))
                ForEach(source.acceptedDinnerIDs, id: \.self) { id in
                    if let dinner = model.state.acceptedDinners.first(where: { $0.id == id }) { Text(dinner.template.title).font(.headline) }
                }
                Text(dinnerText("Ingredient values include food on hand at the reviewed pack prices. Each estimate is rounded to the nearest cent."))
                ForEach(source.commitments.commitments) { c in
                    Text("\(c.name) · \(c.portions.description) \(c.protected ? dinnerText("Protected commitment") : dinnerText("Required portions"))")
                    let value = result.ingredientValues[c.id]
                    Text(dinnerFormat("Ingredients used at reviewed pack prices: %@", dinnerMoney(value?.total)))
                    Text(dinnerFormat("Ingredient value per serving: %@", dinnerMoney(value?.perServing)))
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
                ForEach(source.baselineLines) { line in
                    if case .exact(let cost) = line.cost {
                        Text(dinnerFormat("Other basket item · %@ · %@", line.name, dinnerMoney(cost)))
                    } else {
                        Text(dinnerFormat("Other basket item · %@ · %@", line.name, dinnerText("Unresolved")))
                    }
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
            ForEach(Array(result.preferenceResults.enumerated()), id: \.offset) { match in
                MealPreferenceIssues(result: match.element)
            }
            ForEach(result.issues, id: \.self) { Text(dinnerIssue($0)) }
        }.padding(.vertical, 6).accessibilityElement(children: .combine)
            .accessibilityIdentifier("dinnerCost-\(result.scenarioID)")
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
        JournalList {
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
