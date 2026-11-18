import CoreDomain
import Foundation

/// Facts for one explicitly identified private batch. A printed date and a quality estimate
/// have different sources and meanings, even when their calendar dates overlap.
@MainActor
struct PantryVoiceDateEvidence {
    let printed: PrintedPackageDate?
    enum Guide: Equatable {
        case current(FoodKeeperReviewedRange), needsReview, unavailable
    }
    let guide: Guide
    var quality: FoodKeeperReviewedRange? {
        if case .current(let range) = guide { return range }
        return nil
    }

    private let scope: PantryDigestScope
    private let lot: InventoryLot
    private let inventoryRevision: Int64
    private let dayChecked: MealDay
    private let store: PantryDigestStore
    private let guideGeneration: UUID
    private let printedGeneration: Int

    static func read(lot: InventoryLot, model: PantryModel, access: PantryDigestAccess,
                     now: Date = Date(), store supplied: PantryDigestStore? = nil) async throws -> Self {
        let store = supplied ?? .shared
        guard access.authorized(), model.canEdit,
              let snapshot = model.snapshot, snapshot.state.workspaceID == access.scope.origin,
              snapshot.lots.contains(lot), lot.count.quantity?.amount != .zero else { throw PantryDigestFailure.changed }

        try await model.verifyDigestLot(lot, origin: access.scope.origin, inventoryRevision: snapshot.state.revision)
        guard !Task.isCancelled, access.authorized(), model.canEdit,
              model.snapshot?.state == snapshot.state, model.snapshot?.lots.contains(lot) == true else {
            throw PantryDigestFailure.changed
        }

        let printed = try? store.packageDates.load(access.scope, lot: lot.id)
        let document = try? store.document(access.scope)
        let selection = document?.selections.first { $0.lotID == lot.id }
        let zone = selection?.range.start.timeZoneIdentifier ?? TimeZone.current.identifier
        let today = try MealDay(date: now, timeZoneIdentifier: zone)
        let guide: Guide
        if let range = currentRange(selection, for: lot, today: today, reference: PantryFoodKeeperSelection.reference) {
            guide = .current(range)
        } else {
            guide = selection == nil ? .unavailable : .needsReview
        }
        guard access.authorized() else { throw PantryDigestFailure.changed }
        return Self(printed: printed, guide: guide, scope: access.scope, lot: lot,
                    inventoryRevision: snapshot.state.revision, dayChecked: today,
                    store: store, guideGeneration: store.generation, printedGeneration: store.packageDates.generation)
    }

    func isCurrent(lot currentLot: InventoryLot, model: PantryModel, access: PantryDigestAccess,
                   now: Date = Date()) -> Bool {
        access.scope == scope && access.authorized() && currentLot == lot && model.canEdit &&
            model.snapshot?.state.workspaceID == scope.origin && model.snapshot?.state.revision == inventoryRevision &&
            model.snapshot?.lots.contains(currentLot) == true && store.generation == guideGeneration &&
            store.packageDates.generation == printedGeneration &&
            (try? MealDay(date: now, timeZoneIdentifier: dayChecked.timeZoneIdentifier)) == dayChecked
    }

    static func currentRange(_ selection: PantryFoodKeeperSelection?, for lot: InventoryLot, today: MealDay,
                             reference: FoodKeeperReference?) -> FoodKeeperReviewedRange? {
        guard let selection, let reference, selection.lotID == lot.id, selection.revision == lot.revision,
              selection.range.storage == lot.location.foodKeeperStorage, selection.range.matches(reference, asOf: today)
        else { return nil }
        let range = selection.range
        if range.event == .opened, let recorded = lot.openedAt,
           (try? MealDay(date: recorded, timeZoneIdentifier: range.start.timeZoneIdentifier)) != range.start { return nil }
        return range
    }

    static func formatted(_ day: MealDay, locale: Locale) -> String {
        guard let date = day.date, let zone = TimeZone(identifier: day.timeZoneIdentifier) else { return day.iso8601 }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = zone
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale, calendar: calendar, timeZone: zone))
    }
}
