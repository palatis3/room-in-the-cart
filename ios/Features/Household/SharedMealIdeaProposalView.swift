import SwiftUI
import HouseholdClient

struct SharedMealIdeaProposalView: View {
    @ObservedObject var household: HouseholdModel
    let idea: SharedMealIdeaPage.Idea
    let scope: SharedMealChangeScope
    @State private var model: SharedMealChangeModel?
    var body: some View {
        Group {
            if let model {
                SharedMealIdeaProposalContent(household: household, idea: idea, scope: scope, model: model)
            } else { Text(ht("Refresh the household and check meal planning access.")) }
        }.navigationTitle(ht("Propose approved household meal"))
        .task {
            guard household.sharedMealChangeScope == scope, let service = household.service else { return }
            let next = SharedMealChangeModel(scope: scope, service: service, store: household.decisionStore,
                                            runtime: { household.sharedMealChangeScope })
            model = next; await next.load()
        }.onDisappear { model?.invalidate() }
    }
}

private struct SharedMealIdeaProposalContent: View {
    @ObservedObject var household: HouseholdModel
    let idea: SharedMealIdeaPage.Idea
    let scope: SharedMealChangeScope
    @ObservedObject var model: SharedMealChangeModel
    @State private var day = Date()
    @State private var showingShopperReview = false
    @State private var openSharedShop = false
    @State private var sharedReviewReady = false
    var body: some View {
        Form {
            Text(verbatim: idea.draft.title)
            SharedMealIdeaPreviewView(idea: idea)
            Text(ht("An approved idea stays separate from the week. Choose a real date and review this proposal; only the current shopper can apply shared packs."))
            if model.live {
                if let review = model.review {
                    SharedMealFacts(meal: review.request.meal)
                    Button(ht("Send reviewed proposal")) { Task { await model.sendReviewed() } }.accessibilityIdentifier("household-idea-send-proposal")
                    Button(ht("Cancel proposal review")) { model.cancelReview() }
                } else if let pending = model.pending {
                    SharedMealFacts(meal: pending.request.meal)
                    Button(ht("Retry saved proposal")) { Task { await model.retry() } }
                } else if !model.hasPending {
                    DatePicker(ht("Meal day"), selection: $day, displayedComponents: .date)
                        .environment(\.timeZone, TimeZone(secondsFromGMT: 0)!)
                    Button(ht("Review new household meal proposal")) { Task { await model.prepareNew(idea: idea, day: sharedMealDay(day)) } }
                        .accessibilityIdentifier("household-idea-prepare-proposal")
                }
                if let notice = model.notice { Text(notice) }
                if household.projection?.role == "shopper", model.page?.shopper == true {
                    Button(ht("Review shared meal proposals")) { showingShopperReview = true }
                }
                Button(ht("Refresh shared changes")) { Task { await model.load() } }
            } else { Text(ht("Refresh the household and check meal planning access.")) }
        }.disabled(model.busy || household.sharedMealChangeScope != scope)
        .sheet(isPresented: $showingShopperReview, onDismiss: {
            if sharedReviewReady { sharedReviewReady = false; openSharedShop = true }
        }) {
            NavigationStack {
                SharedMealChangesView(household: household, onReviewOpened: { sharedReviewReady = true; showingShopperReview = false })
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Close")) { showingShopperReview = false } } }
            }
        }
        .navigationDestination(isPresented: $openSharedShop) {
            if household.sharedMealChangeScope == scope, household.projection?.role == "shopper" { HouseholdShopView(model: household) }
            else { Text(ht("Refresh the household and check meal planning access.")) }
        }
    }
}
