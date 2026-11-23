import CoreDomain
import HouseholdClient
import LocalStore
import SwiftUI

struct PrivatePricePublicationView: View {
    @ObservedObject var pantry: PantryModel
    @ObservedObject var household: HouseholdModel
    let price: PrivatePriceEvidence
    let state: InventoryState
    @State private var history: HistoryFeatureModel?

    var body: some View {
        Group {
            if let history, pantry.phase == .ready, pantry.snapshot?.state == state, !household.locked,
               let scope = household.projection, scope.enrolled, scope.grantId == nil, household.identity != nil {
                PrivatePricePublicationForm(history: history, pantry: pantry, price: price, state: state)
            } else {
                WorkingForm { Text(HistoryCopy.text("Reopen the private price and the current shared shop.")) }
            }
        }
        .task { history = household.makeHistoryModel() }
        .onChange(of: household.projection) { _, _ in history?.enforceRuntime() }
        .onChange(of: household.identity?.subject) { _, _ in history?.enforceRuntime() }
        .onChange(of: household.locked) { _, _ in history?.enforceRuntime() }
        .privacySensitive()
    }
}

private struct PrivatePricePublicationForm: View {
    @ObservedObject var history: HistoryFeatureModel
    @ObservedObject var pantry: PantryModel
    let price: PrivatePriceEvidence
    let state: InventoryState
    @Environment(\.scenePhase) private var scene
    @State private var shopID = ""
    @State private var branch = ""
    @State private var mode: HistoryFulfillmentMode?
    @State private var notice: String?

    var body: some View {
        WorkingForm {
            if history.authorized {
                if let notice { Text(verbatim: notice) }
                if let notice = history.notice { Text(verbatim: notice) }
                if let saved = history.selectedObservation {
                    Text(saved.itemName).font(.headline)
                    LabeledContent(HistoryCopy.text("Observation reference"), value: saved.id)
                } else if history.hasUnresolvedWrite {
                    Text(HistoryCopy.text("Open household price history to reconcile the reviewed write."))
                } else if case .observation(let review) = history.reviewed {
                    Section(HistoryCopy.text("Publish selected price evidence")) {
                        Text(verbatim: review.itemName).font(.headline)
                        if let variant = review.variant { Text(verbatim: variant) }
                        if case .exact(let minor) = review.price {
                            LabeledContent(HistoryCopy.text("Entered price"), value: HistoryCopy.money(minor)).monospacedDigit()
                        }
                        Text(verbatim: review.packLabel)
                        Text(verbatim: review.store + " · " + review.branch)
                        Text(HistoryCopy.mode(review.mode.rawValue))
                        Text(HistoryCopy.priceKind(review.evidenceKind))
                        Text(verbatim: review.eligibility)
                        Text(verbatim: HistoryCopy.date(review.observedAt))
                        VStack(alignment: .leading, spacing: 4) {
                            Text(HistoryCopy.text("Original source text")).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.secondary)
                            Text(verbatim: review.sourceText).textSelection(.enabled)
                        }
                        if let assigned = history.ownedShops.first(where: { $0.shopId == review.shopId }) { Text(HistoryCopy.shop(assigned)) }
                        Text(HistoryCopy.text("The household receives these selected fields as a separate price record."))
                        Button(HistoryCopy.text("Publish this price to the selected shop")) {
                            Task {
                                do {
                                    try await pantry.verifyPriceSource(price, expected: state)
                                    guard scene == .active, history.authorized, history.reviewed == .observation(review) else { return }
                                    history.approved = true
                                    await history.applyReviewed()
                                } catch { history.cancelReview(); notice = HistoryCopy.text("Reopen the private price and the current shared shop.") }
                            }
                        }
                        .buttonStyle(PrimaryAction())
                        .disabled(history.busy)
                        Button(pantryText("Cancel")) { history.cancelReview() }
                    }
                } else {
                    Picker(HistoryCopy.text("Assigned shop"), selection: $shopID) {
                        Text(HistoryCopy.text("Choose shared shop")).tag("")
                        ForEach(history.ownedShops) { shop in Text(HistoryCopy.shop(shop)).tag(shop.shopId) }
                    }
                    if history.ownedShopCursor != nil {
                        Button(HistoryCopy.text("Load more assigned shops")) { Task { await history.loadOwnedShops(more: true) } }
                    }
                    let branchLabel = HistoryCopy.text("Branch or location")
                    WorkingField(branchLabel) {
                        TextField(branchLabel, text: $branch, prompt: Text("")).textFieldStyle(WorkingInputStyle())
                    }
                    Picker(HistoryCopy.text("Fulfillment mode"), selection: $mode) {
                        Text(HistoryCopy.text("Choose a fulfillment mode")).tag(nil as HistoryFulfillmentMode?)
                        ForEach(HistoryFulfillmentMode.allCases, id: \.self) { value in Text(HistoryCopy.mode(value.rawValue)).tag(Optional(value)) }
                    }
                    Button(HistoryCopy.text("Review selected fields")) {
                        do {
                            guard let assigned = history.ownedShops.first(where: { $0.shopId == shopID }), let mode else { throw HistoryDraftError.invalid }
                            try history.reviewPublication(try PrivatePricePublication.observation(price, workspace: state.workspaceID, shop: assigned,
                                branch: branch, mode: mode))
                            notice = nil
                        } catch { notice = HistoryCopy.text("Review the selected shop, branch and fulfillment mode.") }
                    }.disabled(!history.canBeginObservation)
                }
            }
        }
        .navigationTitle(HistoryCopy.text("Review for a shared shop"))
        .task {
            await history.load()
            shopID = history.currentShopID ?? ""
            branch = price.branch ?? ""
            mode = price.mode.flatMap { HistoryFulfillmentMode(rawValue: $0.rawValue) }
        }
        .onDisappear { history.cancelReview() }
        .onChange(of: scene) { _, next in if next != .active { history.cancelReview() } }
    }

}

enum PrivatePricePublication {
    static func observation(_ price: PrivatePriceEvidence, workspace: UUID, shop: HistoryOwnedShop,
                            branch: String, mode: HistoryFulfillmentMode) throws -> HistoryPriceObservation {
        try price.validateForRecording()
        guard price.currencyCode == "USD", let minor = price.amountMinor, let amount = Int(exactly: minor),
              let revision = Int(exactly: price.revision) else { throw HistoryDraftError.invalid }
        let kind: HistoryPriceKind
        switch price.source {
        case .paidReceipt: kind = .paidReceipt
        case .paidManual: kind = .paidManual
        case .shelf: kind = .shelf
        case .currentQuote: kind = .quote
        case .adjustment: throw HistoryDraftError.invalid
        }
        let sourceID = ReceiptAcquisition.identity(["share-price", shop.shopId, workspace.uuidString, price.id.uuidString]).uuidString.lowercased()
        let sharedID = ReceiptAcquisition.identity(["shared-price-version", sourceID, String(price.revision)]).uuidString.lowercased()
        var pack: HistoryUsablePack?
        if let basis = price.pack, let unit = HistoryUnit(rawValue: basis.perPackage.unit.rawValue) {
            let combined = try basis.perPackage.amount.multiplied(by: Rational(basis.count))
            pack = try .init(amount: .init(numerator: Int(combined.numerator), denominator: Int(combined.denominator)), unit: unit,
                             originalLiteral: String(basis.count) + " × " + basis.perPackage.originalLiteral)
        }
        return try .init(id: sharedID, shopId: shop.shopId, itemName: price.name, packLabel: pack?.originalLiteral ?? HistoryCopy.text("Package quantity unknown"),
            usablePack: pack, price: .exact(minor: amount), store: price.store, branch: branch, channel: kind == .shelf ? .storeShelf : .unspecified,
            mode: mode, eligibility: price.eligibility ?? "", observedAt: HistoryDate.string(price.date), sourceText: price.sourceText,
            sourceLocale: Locale.current.identifier, evidenceKind: kind, sourceRevision: .init(sourceId: sourceID, revision: revision,
                shopRevision: shop.revision, authorityEpoch: shop.authorityEpoch), variant: price.variant)
    }
}
