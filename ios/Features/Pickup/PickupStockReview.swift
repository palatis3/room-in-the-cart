import Foundation
import CoreDomain

/// A live private-workspace identity; never restored from a saved batch or imported document.
struct PickupStockReviewScope: Equatable {
    let workspaceID: UUID
    let localActorID: UUID
    let accountSubject: String?
    let householdID: String?
    let memberID: String?
    let role: String?
    let householdLocked: Bool
    let projection: PickupStockReviewProjection?
    let presentationID: UUID?
    init(workspaceID: UUID, localActorID: UUID, accountSubject: String?, householdID: String?, memberID: String?, role: String?,
         householdLocked: Bool = false, projection: PickupStockReviewProjection? = nil, presentationID: UUID? = nil) {
        self.workspaceID = workspaceID; self.localActorID = localActorID; self.accountSubject = accountSubject
        self.householdID = householdID; self.memberID = memberID; self.role = role
        self.householdLocked = householdLocked; self.projection = projection; self.presentationID = presentationID
    }
    var permitsReview: Bool {
        // A retained sign-in is a boundary fingerprint, not permission over this private SQLite workspace.
        guard let role else { return householdID == nil && memberID == nil && projection == nil }
        if let projection {
            guard projection.enrolled, projection.householdID == householdID, projection.memberID == memberID,
                  projection.role == role else { return false }
        }
        return ["shopper", "organizer"].contains(role) && accountSubject != nil && householdID != nil && memberID != nil
    }
}

struct PickupStockReviewProjection: Equatable {
    let householdID: String
    let memberID: String
    let role: String
    let enrolled: Bool
    let shopID: String?
    let grantID: String?
    let capabilities: [String]
    let selectionRequired: Bool?
    let canSelectShop: Bool?
    init(householdID: String, memberID: String, role: String, enrolled: Bool, shopID: String?, grantID: String?,
         capabilities: [String], selectionRequired: Bool? = nil, canSelectShop: Bool? = nil) {
        self.householdID = householdID; self.memberID = memberID; self.role = role; self.enrolled = enrolled
        self.shopID = shopID; self.grantID = grantID; self.capabilities = capabilities
        self.selectionRequired = selectionRequired; self.canSelectShop = canSelectShop
    }
}

/// The local device-owner admission is independent of network account unlock.
/// Account/projection facts remain in the fingerprint so no review crosses a persona transition.
struct PickupStockReviewPresentation: Equatable {
    let workspaceID: UUID?
    let localActorID: UUID
    let workspaceUnlocked: Bool
    let sceneActive: Bool
    let childPresented: Bool
    let guardianChildOnly: Bool
    let accountSubject: String?
    let householdLocked: Bool
    let projection: PickupStockReviewProjection?

    func scope(presentationID: UUID) -> PickupStockReviewScope? {
        guard sceneActive, workspaceUnlocked, !childPresented, !guardianChildOnly, let workspaceID else { return nil }
        if let projection {
            guard accountSubject != nil, projection.enrolled, ["shopper", "organizer"].contains(projection.role) else { return nil }
        }
        return .init(workspaceID: workspaceID, localActorID: localActorID, accountSubject: accountSubject,
            householdID: projection?.householdID, memberID: projection?.memberID, role: projection?.role,
            householdLocked: householdLocked, projection: projection, presentationID: presentationID)
    }
}

/// A changed boundary cancels the draft and rotates its ephemeral lease, even for A → B → A.
struct PickupStockReviewSession {
    private(set) var presentation: PickupStockReviewPresentation?
    private(set) var id = UUID()
    @discardableResult mutating func refresh(_ value: PickupStockReviewPresentation) -> Bool {
        guard presentation != value else { return false }
        presentation = value; id = UUID(); return true
    }
    func scope(for current: PickupStockReviewPresentation) -> PickupStockReviewScope? {
        guard presentation == current else { return nil }
        return current.scope(presentationID: id)
    }
}

struct PickupStockMealEffect: Identifiable {
    var id: UUID { need.id }
    let need: StockNeed
    let before: StockDemandCoverage?
    let after: StockDemandCoverage?
}

struct PickupStockMatch: Identifiable {
    let id: UUID
    let name: String
}
extension PickupJourney {
    /// Retained meal demands still name their food when a reviewed at-home plan has no purchase line.
    var reviewedStockMatches: [PickupStockMatch] {
        var matches: [PickupStockMatch] = [], seen = Set<UUID>()
        for line in basket?.current.lines ?? [] where seen.insert(line.id).inserted {
            matches.append(.init(id: line.id, name: line.name))
        }
        for line in pickup?.orderLines ?? [] where seen.insert(line.id).inserted {
            matches.append(.init(id: line.id, name: line.name))
        }
        for need in physicalStockNeeds where seen.insert(need.foodID).inserted {
            matches.append(.init(id: need.foodID, name: urgent.first { $0.id == need.id }?.food ?? need.name))
        }
        return matches
    }
}

/// A write-free candidate. The saved revision, matching identity and source batch must still
/// be current when the adult explicitly confirms its complete dependent-meal effects.
struct PickupStockLotReview: Identifiable {
    let id = UUID()
    let journeyID: UUID
    let revision: Int64
    let sourceRevision: Int64?
    let scope: PickupStockReviewScope
    let lot: ConfirmedStockLot
    let original: ConfirmedStockLot?
    let carriedFrom: ConfirmedStockLot?
    let before: StockAllocationResult
    let after: StockAllocationResult
    let meals: [PickupStockMealEffect]
}

enum PickupStockReviewError: Error, Equatable { case invalid, stale }

enum PickupStockReviewEngine {
    /// Shared by preview and save so neither can silently use a different batch edit.
    static func candidate(_ lot: ConfirmedStockLot, current: PickupJourney,
                          replacing original: ConfirmedStockLot?, carriedFrom priorLot: ConfirmedStockLot?,
                          previous: PickupJourney?, at: Date) throws -> PickupJourney {
        guard current.closedAt == nil, lot.source != .manual,
              !lot.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              lot.confirmedAt.timeIntervalSinceReferenceDate.isFinite, lot.confirmedAt <= at,
              lot.id == lot.foodID || current.physicalStockNeeds.contains(where: { $0.foodID == lot.foodID })
                || current.basket?.current.lines.contains(where: { $0.id == lot.foodID }) == true
                || current.pickup?.orderLines.contains(where: { $0.id == lot.foodID }) == true else {
            throw PickupStockReviewError.invalid
        }
        let existing = current.stockLots.first { $0.id == lot.id }
        if let priorLot {
            guard original == nil, lot.id == priorLot.id, priorLot.source != .manual,
                  previous?.id == current.originShopID, previous?.stockLots.contains(priorLot) == true,
                  lot.confirmedAt >= priorLot.confirmedAt else { throw PickupStockReviewError.stale }
        }
        if existing == lot { return current }
        let canCorrect = original.map {
            $0.id == lot.id && $0.source != .manual && ($0.foodID == lot.foodID || $0.foodID == $0.id)
        } ?? true
        guard existing == original, canCorrect else { throw PickupStockReviewError.stale }
        var value = current
        if let index = value.stockLots.firstIndex(where: { $0.id == lot.id }) { value.stockLots[index] = lot }
        else { value.stockLots.append(lot) }
        return value
    }
}

extension PickupModel {
    func previewStockLot(_ lot: ConfirmedStockLot, in journeyID: UUID, replacing original: ConfirmedStockLot? = nil,
                         carriedFrom priorLot: ConfirmedStockLot? = nil, scope: PickupStockReviewScope) throws -> PickupStockLotReview {
        guard ready, !saving, !hasPendingSave, scope.permitsReview, scope.workspaceID == sourceWorkspaceID,
              let current = journey, current.id == journeyID else { throw PickupStockReviewError.stale }
        let previous = journeys.first { $0.id == current.originShopID }
        let candidate = try PickupStockReviewEngine.candidate(lot, current: current, replacing: original,
            carriedFrom: priorLot, previous: previous, at: stockReviewDate)
        try Self.validate(candidate)
        let before = try current.carryoverAllocation(), after = try candidate.carryoverAllocation()
        let affectedFoods = Set([lot.foodID, original?.foodID, priorLot?.foodID].compactMap { $0 })
        let meals = candidate.physicalStockNeeds.filter { affectedFoods.contains($0.foodID) }.map { need in
            PickupStockMealEffect(need: need, before: before.demands.first { $0.id == need.id }, after: after.demands.first { $0.id == need.id })
        }
        return PickupStockLotReview(journeyID: journeyID, revision: current.revision,
            sourceRevision: priorLot == nil ? nil : previous?.revision, scope: scope, lot: lot, original: original,
            carriedFrom: priorLot, before: before, after: after, meals: meals)
    }

    func isCurrentStockLotReview(_ review: PickupStockLotReview, scope: PickupStockReviewScope?) -> Bool {
        guard ready, !saving, !hasPendingSave, let scope, scope.permitsReview, scope == review.scope,
              scope.workspaceID == sourceWorkspaceID, let current = journey, current.id == review.journeyID,
              current.closedAt == nil else { return false }
        if let applied = appliedStockReviewRevisions[review.id] {
            return current.revision == applied && current.stockLots.first { $0.id == review.lot.id } == review.lot
        }
        guard current.revision == review.revision else { return false }
        if let carriedFrom = review.carriedFrom {
            guard let previous = journeys.first(where: { $0.id == current.originShopID }),
                  previous.revision == review.sourceRevision, previous.stockLots.contains(carriedFrom) else { return false }
        }
        return true
    }

    @discardableResult
    func applyStockLotReview(_ review: PickupStockLotReview, scope: PickupStockReviewScope?, confirmed: Bool) async -> Bool {
        guard confirmed, isCurrentStockLotReview(review, scope: scope) else {
            error = pTr("The batch or meal commitments changed. Review the effects again before saving.")
            return false
        }
        if appliedStockReviewRevisions[review.id] != nil { return true }
        guard await saveStockLot(review.lot, in: review.journeyID, replacing: review.original, carriedFrom: review.carriedFrom) else { return false }
        appliedStockReviewRevisions[review.id] = journey?.revision
        return true
    }
}
