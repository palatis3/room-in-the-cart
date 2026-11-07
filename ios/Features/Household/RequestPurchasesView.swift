import HouseholdClient
import SwiftUI

func purchaseStatus(_ outcome: ConfirmedRequestPurchase?) -> String {
    switch outcome {
    case .bought: ht("Shopper confirmed bought")
    case .notBought: ht("Shopper confirmed not bought")
    case nil: ht("Purchase unconfirmed")
    }
}

struct RequestPurchasesView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var inbox: HouseholdInboxModel
    let shopID: String
    @State private var reviewing: RequestPurchaseMatch?

    private var placed: SharedDeliveryPage? {
        guard model.canReadDelivery, model.scope.capabilities.contains("request_purchase_confirmation"),
              inbox.supportsPurchaseConfirmation, model.scope.memberId == inbox.memberID,
              model.scope.household.id == inbox.householdID, model.scope.shopId == shopID, inbox.shopID == shopID,
              let page = model.deliveryRecord, UUID(uuidString: shopID) == page.shopId else { return nil }
        return page
    }

    var body: some View {
        List {
            if let placed {
                ShopperDeliverySection(model: inbox)
                Section {
                    let matches = inbox.purchaseMatches(placed: placed)
                    ForEach(matches) { match in
                        Button {
                            reviewing = match
                        } label: {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(match.request.originalItem).font(.headline)
                                if let author = match.request.authorAlias { Text(author) }
                                Text(purchaseStatus(match.request.purchaseOutcome)).foregroundStyle(.secondary)
                            }
                        }
                        .accessibilityIdentifier("purchase.request." + match.request.id)
                        .disabled(inbox.busy || model.busy || inbox.pending != nil || model.pending != nil)
                    }
                    if !inbox.busy && matches.isEmpty { Text(ht("No linked requests on this page.")) }
                    if inbox.nextCursor != nil {
                        Button(ht("Load more requests")) { Task { await inbox.load(more: true) } }.disabled(inbox.busy)
                    }
                }
                Button(ht("Refresh requests")) { Task {
                    await model.load()
                    await model.loadDelivery()
                    await inbox.load()
                } }.disabled(model.busy || inbox.busy)
                if let notice = inbox.notice { Text(notice) }
            } else { Text(ht("Shopper access has ended. Return to household settings.")) }
        }
        .navigationTitle(ht("Family request purchases"))
        .task { await inbox.load() }
        .sheet(item: $reviewing) { reviewed in
            NavigationStack {
                if let page = placed, let match = inbox.purchaseMatch(reviewed.id, placed: page), match == reviewed {
                    RequestPurchaseEditor(match: match, busy: inbox.busy || model.busy || inbox.pending != nil || model.pending != nil) { outcome in
                        guard let current = placed, model.pending == nil else { return }
                        await inbox.confirmPurchase(match, outcome: outcome, placed: current)
                        reviewing = nil
                    }
                } else {
                    ContentUnavailableView(ht("Request details changed"), systemImage: "arrow.clockwise",
                                           description: Text(ht("Refresh requests and review the current placed order.")))
                        .toolbar { Button(ht("Done")) { reviewing = nil } }
                }
            }
        }
        .onChange(of: placed == nil) { _, unavailable in if unavailable { reviewing = nil } }
    }
}

private struct RequestPurchaseEditor: View {
    let match: RequestPurchaseMatch
    let busy: Bool
    let save: (ConfirmedRequestPurchase?) async -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var review: Choice?

    private enum Choice: CaseIterable {
        case bought, notBought, clear
        var outcome: ConfirmedRequestPurchase? {
            switch self { case .bought: .bought; case .notBought: .notBought; case .clear: nil }
        }
        var label: String {
            switch self { case .bought: ht("Bought"); case .notBought: ht("Not bought"); case .clear: ht("Clear purchase confirmation") }
        }
    }

    var body: some View {
        Form {
            Section(ht("Received request")) {
                Text(match.request.originalItem).font(.headline).accessibilityIdentifier("purchase.review.original")
                LabeledContent(ht("Requested by"), value: match.request.authorAlias ?? ht("Unknown"))
                LabeledContent(ht("Quantity"), value: match.request.ownQuantity ?? ht("Unknown amount"))
                LabeledContent(ht("Received"), value: householdTime(match.request.receivedAt))
            }
            Section(ht("Matched line in the placed order")) {
                Text(match.line.name)
                LabeledContent(ht("Placed revision"), value: match.placedRevision.formatted())
            }
            Section(ht("Current purchase status")) { Text(purchaseStatus(match.request.purchaseOutcome)) }
            if let review {
                Section(ht("Review purchase confirmation")) {
                    Text(review.label).font(.headline)
                    Text(ht("The requester will see the updated purchase status."))
                    Button(ht("Save reviewed status")) { Task { await save(review.outcome) } }
                        .accessibilityIdentifier("purchase.save")
                    Button(ht("Change choice")) { self.review = nil }
                }
            } else {
                Section(ht("What happened to this request?")) {
                    ForEach(Choice.allCases, id: \.self) { choice in
                        if match.request.purchaseOutcome != choice.outcome {
                            Button(choice.label) { review = choice }
                                .accessibilityIdentifier("purchase.choice." + (choice.outcome?.rawValue ?? "unknown"))
                        }
                    }
                }
            }
        }
        .disabled(busy)
        .navigationTitle(ht("Review request"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Cancel")) { dismiss() }.disabled(busy) } }
    }
}
