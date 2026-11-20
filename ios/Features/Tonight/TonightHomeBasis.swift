import Foundation
import CoreDomain
import CryptoKit

/// Private-only evidence. The widget receives no recipe, food or journey identifiers.
struct TonightHomeBasis: Codable, Equatable {
    let ledger: UUID
    let ledgerRevision: Int64
    let stockDigest: Data
    init(ledger: UUID, revision: Int64, stock: LedgerCanonicalPackStockEvidence.Basis) throws {
        self.ledger = ledger; self.ledgerRevision = revision
        let canonical = LedgerCanonicalPackStockEvidence.Basis(originID: stock.originID,
            inventoryRevision: stock.inventoryRevision,
            sourceHeads: stock.sourceHeads.sorted { $0.journeyID.uuidString < $1.journeyID.uuidString })
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        stockDigest = Data(SHA256.hash(data: try encoder.encode(canonical)))
    }
    @MainActor static func current(ledger: LedgerModel, pickup: PickupModel) throws -> Self {
        guard ledger.ready, !ledger.saving, !ledger.hasPendingSave, !ledger.hasPendingLedgerDeletion,
              let origin = ledger.sourceWorkspaceID, let context = try pickup.pantryReviewContext() else {
            throw TonightMealModel.Failure.unavailable
        }
        let live = try PantryLiveStockProjection.buildGlobal(snapshot: context.snapshot, mapping: context.mapping, at: context.asOf)
        let stock = LedgerCanonicalPackStockEvidence.Basis(originID: live.basis.originID, inventoryRevision: live.basis.inventoryRevision,
            sourceHeads: live.basis.sourceHeads.map { .init(journeyID: $0.journeyID, revision: $0.storeRevision) })
        return try Self(ledger: origin, revision: ledger.revision, stock: stock)
    }
}

/// The private calendar can contain more than one pickup on a civil day. In
/// that case the widget shows a count, without choosing a dinner for the adult.
struct TonightPlannedDinners: Equatable {
    let count: Int
    let title: String?

    static func current(workspace: LedgerWorkspace, ledgerID: UUID, journeys: [PickupJourney],
                        now: Date, zone: TimeZone) throws -> Self {
        let titles = try meals(workspace: workspace, ledgerID: ledgerID, journeys: journeys, now: now, zone: zone).map(\.title)
        guard titles.count == 1 else { return Self(count: titles.count, title: nil) }
        let title = String(titles[0].prefix(64))
        let displayable = !title.isEmpty && title.utf8.count <= 256 && title.rangeOfCharacter(from: .controlCharacters) == nil
        return Self(count: 1, title: displayable ? title : nil)
    }

    struct PlanRow: Identifiable {
        let id: UUID
        let title: String
        let pickup: String
    }

    static func meals(workspace: LedgerWorkspace, ledgerID: UUID, journeys: [PickupJourney],
                      now: Date, zone: TimeZone) throws -> [PlanRow] {
        let day = try MealDay(date: now, timeZoneIdentifier: zone.identifier)
        let away = Set(workspace.dinnerPlanning.weekNotes.filter { $0.kind == .away && $0.day.hasSameCivilDate(as: day) }.map(\.shopID))
        var rows: [PlanRow] = []
        for shop in workspace.shops where !away.contains(shop.id) {
            let journey = journeys.first { $0.id == shop.id }
            var recovered = Set<UUID>()
            var definitions: [PickupRecoveryMealDefinition] = []
            if let journey, let history = journey.mealRecovery, !history.domain.events.isEmpty {
                let checked = try journey.checkedMealRecoveryHistory(shop: shop, workspaceID: ledgerID, at: now)
                recovered = Set(checked.domain.events.map { $0.request.target.id })
                definitions = try recovered.compactMap { try checked.definition(for: $0) }
            }
            let current = try DinnerCurrentMeals.project(shop: shop, definitions: definitions, recovered: recovered)
            for meal in current.on(day) where !meal.isHidden {
                if case let .original(original) = meal, original.carryover != nil { continue }
                rows.append(PlanRow(id: meal.id, title: meal.title, pickup: shop.title))
            }
        }
        return rows
    }
}

@MainActor extension AdultHomeSummaryStore {
    func refreshTonight(_ model: TonightMealModel, access: PantryDigestAccess, ledgerID: UUID,
                        liveBasis: () throws -> TonightHomeBasis) {
        guard model.batch == nil, access.authorized(), enabled(.tonight, scope: access.scope),
              let input = model.input else { return }
        do {
            let basis = try TonightHomeBasis(ledger: ledgerID, revision: input.ledgerRevision, stock: input.basis)
            let choices = model.homeScreenChoices
            guard try liveBasis() == basis, let first = choices.first else {
                try invalidate(.tonight, origin: access.scope.origin, forget: false)
                return
            }
            try update(.tonight, access: access, count: choices.count, reviewedTitle: String(first.recipe.title.prefix(64)), tonightBasis: basis)
        } catch { try? invalidate(.tonight, origin: access.scope.origin, forget: false) }
    }
}
