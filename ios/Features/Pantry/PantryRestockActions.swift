import CoreDomain
import HouseholdClient
import SwiftUI

enum PantryRestockReview: Equatable {
    case onList, pendingRequest, chooseShop, firstList
    case shop(UUID, String)

    static func destination(food: String, workspace: LedgerWorkspace, closed: Set<UUID>,
                            requestNames: [String], sharedLineNames: [String] = []) -> Self {
        let key = normalized(food)
        guard !key.isEmpty else { return .chooseShop }
        for shop in workspace.shops where !closed.contains(shop.id) {
            if shop.lines.contains(where: {
                !$0.isTrashed && !$0.isChecked && !$0.isHandled && normalized($0.name) == key
            }) { return .onList }
        }
        if sharedLineNames.contains(where: { normalized($0) == key }) { return .onList }
        if requestNames.contains(where: { normalized($0) == key }) { return .pendingRequest }
        if workspace.shops.isEmpty { return .firstList }
        guard let shop = workspace.shops.first(where: {
            $0.id == workspace.selectedShopID && !closed.contains($0.id)
        }) else { return .chooseShop }
        return .shop(shop.id, shop.title)
    }

    static func foodName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    static func draftIncludes(food: String, text: String, preview: StagedListImport?) -> Bool {
        let key = normalized(food)
        return text.split(whereSeparator: \.isNewline).contains { normalized(String($0)) == key }
            || preview?.lines.contains { normalized($0.name) == key } == true
    }

    private static func normalized(_ name: String) -> String {
        foodName(name).folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }

    /// A saved food name such as “5 spice” contains no evidence of a purchase quantity.
    /// Other rows, including quantities the shopper types, use the regular import parser.
    static func stage(food: String, text: String, source: ImportSource, id: UUID, shop: ShoppingLedger) throws -> StagedListImport {
        var draft = try shop.stageImport(text: text, source: source, importID: id)
        for index in draft.lines.indices where draft.lines[index].originalText == food {
            let row = draft.lines[index]
            draft.lines[index] = StagedImportLine(id: row.id, proposedLineID: row.proposedLineID, originalText: food,
                name: food, quantity: nil, unresolvedReason: "Review the quantity and unit.", duplicateLineIDs: [])
        }
        return try shop.refreshImportMatches(draft)
    }

    static func canSetCheckDate(for lot: InventoryLot) -> Bool { lot.count.quantity?.amount != .zero }
}

/// Shown only for an explicitly saved observation. The shopping and digest editors own their writes.
struct PantryRestockActions: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let sourceCurrent: @MainActor () -> Bool
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var pickup: PickupModel
    @EnvironmentObject private var household: HouseholdModel
    @EnvironmentObject private var access: WorkspaceAccess
    @Environment(\.pantryDigestAccess) private var digest
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.scenePhase) private var scene
    @State private var grocery: GroceryReview?

    private struct GroceryReview: Identifiable {
        let id = UUID()
        let adult: CapturePrivateIdentity
        let workspace: UUID
        let destination: PantryRestockReview
    }

    private var food: String { PantryRestockReview.foodName(lot.name) }
    private var adult: CapturePrivateIdentity? {
        guard scene == .active, UIApplication.shared.isProtectedDataAvailable, child?.presented != true,
              household.projection?.grantId == nil, sourceCurrent(), pickup.pantryReadIsCurrent,
              let state = model.snapshot?.state, pickup.pantrySnapshot?.state.revision == state.revision,
              state.workspaceID == pickup.sourceWorkspaceID, model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot
        else { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }
    private var destination: PantryRestockReview? {
        guard adult != nil, ledger.ready, pickup.ready, !pickup.saving, !pickup.hasPendingSave,
              !ledger.hasPendingLedgerDeletion else { return nil }
        let closed = Set(pickup.journeys.filter { $0.closedAt != nil }.map(\.id))
        var requests = household.requests
        var deferred: [String] = []
        var sharedLines: [String] = []
        if let inbox = household.shopperInbox, inbox.authorized, inbox.householdID == household.projection?.household.id,
           inbox.memberID == household.projection?.memberId, inbox.shopID == household.projection?.shopId {
            requests += inbox.requests
            deferred = inbox.deferredRequests.map(\.originalItem)
        }
        if let shared = household.sharedShop, shared.canManage, shared.scope == household.projection,
           let shop = shared.shop, shop.shopId == shared.scope.shopId, ["draft", "frozen"].contains(shop.phase) {
            sharedLines = shop.lines.map(\.originalItem)
        }
        let names = requests.filter {
            ["pending", "clarified", "added", "deferred"].contains($0.status) && $0.purchaseOutcome == nil &&
                (UUID(uuidString: $0.shopId).map { !closed.contains($0) } ?? true)
        }.map(\.originalItem)
        return PantryRestockReview.destination(food: food, workspace: ledger.workspace, closed: closed,
            requestNames: names + deferred, sharedLineNames: sharedLines)
    }

    private func current(_ review: GroceryReview) -> Bool {
        adult == review.adult && ledger.sourceWorkspaceID == review.workspace && destination == review.destination
    }

    private func open(_ choice: PantryRestockReview) {
        guard grocery == nil, !ledger.hasPendingSave, !ledger.saving, destination == choice,
              let adult, let workspace = ledger.sourceWorkspaceID else { return }
        grocery = GroceryReview(adult: adult, workspace: workspace, destination: choice)
    }

    var body: some View {
        Group {
            if adult != nil {
                if let choice = destination {
                    switch choice {
                    case .onList:
                        Text(pantryFormat("%@ is already on an open shopping list.", food))
                            .accessibilityIdentifier("pantry.restock.onList")
                    case .pendingRequest:
                        Text(pantryFormat("There is an open household request for %@.", food))
                            .accessibilityIdentifier("pantry.restock.pendingRequest")
                    case .firstList: reviewButton(pantryFormat("Review %@ for a new shopping list", food), choice)
                    case .shop(_, let title): reviewButton(pantryFormat("Review adding %@ to %@", food, title), choice)
                    case .chooseShop:
                        Text(pantryText("Choose an open shopping list to review this item."))
                        NavigationLink(pantryText("Open shopping list")) { LedgerHomeView(model: ledger) }
                    }
                }
                if let digest, digest.authorized(), PantryRestockReview.canSetCheckDate(for: lot) {
                    let scope = PantryDigestAccess(scope: digest.scope, authorized: { adult != nil && digest.authorized() })
                    NavigationLink(pantryFormat("Set a check date for %@", food)) {
                        PantryDigestDayEditor(model: model, access: scope, lot: lot)
                    }.accessibilityIdentifier("pantry.restock.checkDate")
                    NavigationLink(pantryText("Review daily notification settings")) {
                        PantryDigestList(model: model, access: scope)
                    }.accessibilityIdentifier("pantry.restock.notificationSettings")
                    Text(pantryText("A check date stays in My Pantry. For an alert, choose a time and turn on daily notifications."))
                        .font(.footnote)
                }
            }
        }
    }

    // A Form expands the Group above into several rows. Only the tapped grocery row presents this sheet.
    private func reviewButton(_ title: String, _ choice: PantryRestockReview) -> some View {
        Button(title) { open(choice) }
            .disabled(ledger.saving || ledger.hasPendingSave)
            .accessibilityIdentifier("pantry.restock.review")
            .sheet(item: $grocery) { review in
                NavigationStack {
                    if current(review) {
                        switch review.destination {
                        case .firstList:
                            FirstListEntry(model: ledger, prefill: food, pantryFoodPrefill: true,
                                authorizeEntry: { current(review) }, onSaved: { _ in grocery = nil })
                        case .shop(let id, _):
                            LedgerImportView(model: ledger, shopID: id, prefill: food, pantryFoodPrefill: true,
                                authorizeEntry: { current(review) })
                        default: EmptyView()
                        }
                    } else { Text(pantryText("This food is unavailable. Return to My Pantry and refresh.")) }
                }
            }
    }
}
