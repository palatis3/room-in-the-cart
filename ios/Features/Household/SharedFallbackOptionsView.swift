import CoreDomain
import HouseholdClient
import SwiftUI

struct SharedFallbackOptionsView: View {
    @ObservedObject var model: SharedFallbackModel
    @ObservedObject var shop: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedRecoveryPage
    let library: SharedFallbackLibrary
    let target: SharedRecoveryMeal
    let completed: () -> Void
    @State private var candidates: [CandidateReviewDraft]
    @State private var trip = FallbackTripDraft()
    @State private var message: String?
    @State private var decision: Decision?
    @State private var preparing = false
    @Environment(\.scenePhase) private var scene
    @FocusState private var editing: Bool

    private struct Decision: Identifiable {
        var id: UUID { preview.previewId }
        let intent: SharedRecoveryIntent
        let preview: SharedRecoveryPreview
    }

    init(model: SharedFallbackModel, shop: HouseholdShopModel, household: HouseholdModel, page: SharedRecoveryPage,
         library: SharedFallbackLibrary, target: SharedRecoveryMeal, completed: @escaping () -> Void) {
        self.model = model; self.shop = shop; self.household = household; self.page = page
        self.library = library; self.target = target; self.completed = completed
        _candidates = State(initialValue: library.candidates.map(CandidateReviewDraft.init))
    }

    private var live: Bool {
        scene == .active && model.canSuggest && model.library == library &&
        showsReviewedRecovery(page, model: shop, household: household) && shop.pending == nil
    }

    var body: some View {
        Form {
            if live {
                Section(target.title) {
                    if let date = sharedMealDayText(target.day, locale: .current) { Text(verbatim: date) }
                    if !target.exclusions.isEmpty { LabeledContent(ht("Meal exclusions"), value: target.exclusions.joined(separator: ", ")) }
                    LabeledContent(sharedRecoveryText("Meal deadline"), value: deadline)
                }
                Section {
                    Toggle(fallbackText("Compare a top-up trip"), isOn: $trip.include).accessibilityIdentifier("fallback.trip.include")
                    if trip.include {
                        TextField(fallbackText("Round-trip minutes"), text: $trip.minutes).keyboardType(.numberPad).focused($editing)
                        TextField(fallbackText("Whole-trip spending limit (USD)"), text: $trip.budget).keyboardType(.decimalPad).focused($editing)
                        TextField(fallbackText("Extra charges and travel cost (USD)"), text: $trip.charges).keyboardType(.decimalPad).focused($editing)
                    }
                }
                ForEach($candidates) { $draft in
                    Section {
                        Toggle(draft.candidate.recipe.title, isOn: $draft.selected).accessibilityIdentifier("fallback.select." + draft.id.uuidString)
                        if draft.selected {
                            NavigationLink(fallbackText("Review ingredients, food and time")) {
                                SharedFallbackIngredientView(draft: $draft, page: page, includeOffers: trip.include)
                            }.accessibilityIdentifier("fallback.food." + draft.id.uuidString)
                        }
                    }
                }
                Button(fallbackText("Compare reviewed recipes")) {
                    editing = false
                    Task { await compare() }
                }
                .disabled(model.busy || preparing || !candidates.contains(where: \.selected))
                .accessibilityIdentifier("fallback.compare")
                if let options = model.ranking, options.target.id == target.id, options.base == page.base {
                    ranked(options)
                }
            } else { Text(sharedRecoveryText("Refresh the current meal record.")) }
            if model.busy || preparing { ProgressView() }
            if let message { Text(verbatim: message) }
            if let notice = model.notice { Text(verbatim: notice) }
        }
        .keyboardDoneAction(visible: editing, title: ht("Done"), identifier: "fallback.trip.done") { editing = false }
        .navigationTitle(fallbackText("Compare fallback recipes"))
        .onChange(of: candidates) { _, _ in invalidate() }.onChange(of: trip) { _, _ in invalidate() }
        .onChange(of: live) { _, allowed in if !allowed { invalidate() } }
        .sheet(item: $decision) { chosen in
            if live {
                NavigationStack {
                    SharedRecoveryReview(model: shop, household: household, page: page, initial: chosen.preview,
                                         originalIntent: chosen.intent) { _ in decision = nil; completed() }
                }
            }
        }
    }

    private var deadline: String {
        guard let instant = target.due, let zone = target.zone else { return ht("Unknown") }
        return SharedMealDeadline(at: instant, zone: zone).display(locale: .current) ?? ht("Unknown")
    }

    private func invalidate() { decision = nil; model.discardRanking(); message = nil }

    private func compare() async {
        guard live, !preparing else { return }
        do {
            let enteredTrip = try trip.trip()
            let reviews = try candidates.filter(\.selected).map { try $0.review(includeOffers: enteredTrip != nil) }
            message = nil
            await model.rank(reviews, trip: enteredTrip, occurrence: target.id, page: page, reviewed: library)
        } catch { message = fallbackText("Review the minutes, pack quantities, prices and available budget.") }
    }

    private func choose(_ option: SharedFallbackOptions.Option, reviewed ranking: SharedFallbackOptions) async {
        guard live, !preparing, !model.busy, model.ranking == ranking else { return }
        preparing = true
        defer { preparing = false }
        do {
            let preview = try await shop.previewMealRecovery(option.intent, reviewed: page)
            guard live, model.ranking == ranking else { return }
            decision = .init(intent: option.intent, preview: preview)
        } catch { message = shop.notice ?? sharedRecoveryText("Reconnect and preview the current meal again.") }
    }

    @ViewBuilder private func ranked(_ result: SharedFallbackOptions) -> some View {
        if result.options.isEmpty { Text(fallbackText("No reviewed recipe meets all requirements. The current meal and deadline remain open.")) }
        if let usual = result.usualMinutes {
            LabeledContent(fallbackText("Usual accepted option (minutes)"), value: usual.formatted())
        }
        ForEach(result.options) { option in
            Section(option.title) {
                LabeledContent(fallbackText("Total minutes including travel"), value: option.minutes.formatted())
                if option.kind == "topUp", let currency = option.currency {
                    LabeledContent(fallbackText("Whole-trip extra cash"), value: cash(option.extraCashMinor, currency))
                    ForEach(option.buys, id: \.ingredientId) { buy in
                        LabeledContent(buy.label, value: fallbackText("Packs required") + " " + buy.packs.formatted() + " · " + cash(buy.subtotalMinor, currency))
                    }
                }
                if option.repeatRequired { Text(fallbackText("Repeating this meal requires agreement.")) }
                Button(fallbackText("Review this replacement")) { Task { await choose(option, reviewed: result) } }
                    .disabled(model.busy || preparing).accessibilityIdentifier("fallback.choose." + option.id.uuidString)
            }
        }
        ForEach(result.conditional, id: \.candidateId) { row in
            if let candidate = library.candidates.first(where: { $0.id == row.candidateId && $0.revision == row.revision }) {
                Section(candidate.recipe.title) {
                    Text(fallbackReason(row.reason))
                    if let minutes = row.minutes { LabeledContent(fallbackText("Minutes needed"), value: minutes.formatted()) }
                    if let minutes = row.availableMinutes { LabeledContent(fallbackText("Minutes available"), value: minutes.formatted()) }
                    if let packs = row.requiredPacks { LabeledContent(fallbackText("Packs required"), value: packs.formatted()) }
                    if let packs = row.availablePacks { LabeledContent(fallbackText("Packs available"), value: packs.formatted()) }
                    if let currency = row.currency {
                        if let amount = row.extraCashMinor { LabeledContent(fallbackText("Whole-trip extra cash"), value: cash(amount, currency)) }
                        if let limit = row.budgetMinor { LabeledContent(fallbackText("Whole-trip spending limit (USD)"), value: cash(limit, currency)) }
                    }
                }
            }
        }
    }
    private func cash(_ cents: Int, _ currency: String) -> String {
        (Decimal(cents) / 100).formatted(.currency(code: currency))
    }
}

private func fallbackReason(_ reason: String) -> String {
    switch reason {
    case "timingUnknown": fallbackText("The meal deadline or the remaining preparation time is unknown.")
    case "topUpUnreviewed": fallbackText("A needed ingredient has no reviewed top-up offer.")
    case "deadlineExceeded": fallbackText("Preparation and travel would miss the saved meal deadline.")
    case "leadStepUnconfirmed": fallbackText("An advance preparation step still needs confirmation.")
    case "exclusionConflict": fallbackText("A reviewed food conflicts with a recorded exclusion.")
    case "insufficientPacks": fallbackText("Too few packs are available for this recipe.")
    case "overBudget": fallbackText("The top-up exceeds the entered spending limit.")
    case "protectedCommitment": fallbackText("This option would use food committed to another meal.")
    default: fallbackText("The confirmed food does not cover the reviewed portions.")
    }
}
