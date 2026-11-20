import Foundation
import CoreDomain

@MainActor enum TonightPlanChoice {
    struct Review {
        fileprivate let selection: TonightDinnerSelection
        fileprivate let identity: CapturePrivateIdentity
        fileprivate let ledgerID: UUID
        fileprivate let pantryGeneration: UUID
        fileprivate let match: PantryMealMatcher.Review
        let estimate: TonightPurchaseEstimate?
        let pantryBasis: LedgerCanonicalPackStockEvidence.Basis
        var plannedDay: MealDay { selection.plannedDay }
        var recipe: MealTemplate { selection.recipe }
        var destinationTitle: String { selection.destinationTitle }
        var createsPickup: Bool { selection.createsPickup }
        var preview: DinnerPreview { selection.preview }
    }

    static func prepare(match: PantryMealMatcher.Review, pantryBasis: LedgerCanonicalPackStockEvidence.Basis,
                        destinationShopID: UUID?, newShopTitle: String, ledger: LedgerModel, pickup: PickupModel,
                        plannedDate: Date? = nil, currentIdentity: () -> CapturePrivateIdentity?) throws -> Review {
        guard let identity = currentIdentity(), ledger.ready, !ledger.saving, !ledger.hasPendingSave,
              let ledgerID = ledger.sourceWorkspaceID, let current = try pickup.pantryReviewContext() else {
            throw DinnerPlanningError.forbidden
        }
        let heads = current.mapping.sourceHeads.map {
            LedgerCanonicalPackStockEvidence.SourceHead(journeyID: $0.id, revision: $0.revision)
        }
        let basis = LedgerCanonicalPackStockEvidence.Basis(originID: current.snapshot.state.workspaceID,
            inventoryRevision: current.snapshot.state.revision, sourceHeads: heads.sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
        guard pantryBasis == basis else { throw DinnerPlanningError.stalePreview }

        let destination: ShoppingLedger
        if let destinationShopID {
            guard let shop = ledger.workspace.shops.first(where: { $0.id == destinationShopID }) else { throw DinnerPlanningError.stalePreview }
            destination = shop
        } else {
            let title = newShopTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { throw DinnerPlanningError.invalid("shopTitle") }
            destination = ShoppingLedger(title: title)
        }
        let now = Date()
        let context = access(identity, ledgerID: ledgerID, shopID: destination.id, now: now)
        let selection = try TonightDinnerSelection.prepare(match: match, destination: destination, createsPickup: destinationShopID == nil,
            workspace: ledger.workspace, access: context, phase: phase(pickup, shopID: destination.id), now: now, plannedDate: plannedDate)
        let estimate = try? TonightPurchaseEstimate.estimate(match, workspace: ledger.workspace,
            workspaceID: ledgerID, shopID: destinationShopID, at: now)
        return Review(selection: selection, identity: identity, ledgerID: ledgerID,
                      pantryGeneration: pickup.privatePantryGeneration, match: match, estimate: estimate, pantryBasis: basis)
    }

    static func apply(_ review: Review, ledger: LedgerModel, pickup: PickupModel,
                      currentIdentity: @escaping @MainActor () -> CapturePrivateIdentity?) async -> Bool {
        let proposal = review.preview.proposal
        let authorized = {
            currentIdentity() == review.identity && ledger.sourceWorkspaceID == review.ledgerID &&
                pickup.privatePantryGeneration == review.pantryGeneration && pickup.sourceWorkspaceID == review.pantryBasis.originID
        }
        guard authorized() else { return false }
        return await ledger.change(key: "tonight-\(proposal.id)", reviewedPantryBasis: review.pantryBasis, authorize: authorized) { workspace in
            let now = Date()
            if !workspace.dinnerPlanning.applyReceipts.contains(where: { $0.id == proposal.id }) {
                let estimate = try? TonightPurchaseEstimate.estimate(review.match, workspace: workspace, workspaceID: review.ledgerID,
                    shopID: review.createsPickup ? nil : proposal.shopID, at: now)
                guard estimate == review.estimate else { throw DinnerPlanningError.stalePreview }
            }
            try review.selection.apply(to: &workspace,
                access: access(review.identity, ledgerID: review.ledgerID, shopID: proposal.shopID, now: now),
                phase: phase(pickup, shopID: proposal.shopID), now: now)
        }
    }

    private static func access(_ identity: CapturePrivateIdentity, ledgerID: UUID, shopID: UUID, now: Date) -> DinnerAccessContext {
        let actor = identity.actorID.uuidString
        return DinnerAccessContext(scope: .local(workspaceID: ledgerID), actorID: actor, shopID: shopID,
            assignedShopperID: actor, canPlan: true, canReadBudget: false, hasPaidTools: false, roleRevision: 0,
            verifiedAt: now, validUntil: now.addingTimeInterval(30))
    }

    private static func phase(_ pickup: PickupModel, shopID: UUID) -> BasketPhase {
        guard pickup.ready, !pickup.saving, !pickup.hasPendingSave else { return .frozen }
        let journey = pickup.journeys.first { $0.id == shopID }
        guard journey?.closedAt == nil else { return .frozen }
        return journey?.basket?.phase ?? .draft
    }
}
