import CoreDomain
import SwiftUI

struct PantryLotFoodKeeperSection: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let accessAllowed: Bool
    @Environment(\.pantryDigestAccess) private var access
    @Environment(\.locale) private var locale
    @ObservedObject private var store = PantryDigestStore.shared
    @State private var failure: String?

    private var activeAccess: PantryDigestAccess? {
        guard accessAllowed, let access, access.authorized(), model.snapshot?.state.workspaceID == access.scope.origin,
              model.phase == .ready else { return nil }
        return access
    }

    var body: some View {
        Section {
            NavigationLink(helpText("Food storage guide")) {
                PantryLotStorageReference(model: model, lotID: lot.id, accessAllowed: accessAllowed)
            }.accessibilityIdentifier("pantry.foodKeeper")
            if let access = activeAccess,
               let selection = try? store.document(access.scope).selections.first(where: { $0.lotID == lot.id }) {
                let range = selection.range
                let language: FoodKeeperLanguage = locale.language.languageCode?.identifier == "es" ? .spanish : .english
                if let reference = PantryFoodKeeperSelection.reference, reference.version == range.version,
                   let food = reference.products.first(where: { $0.id == range.productID }) {
                    Text(verbatim: food.name(language)).font(.headline)
                }
                Text(verbatim: "USDA FSIS · FoodKeeper v" + String(range.version) + " · #" + String(range.productID))
                    .accessibilityIdentifier("pantry.foodKeeper.source")
                LabeledContent(helpText("Batch storage"), value: range.storage.title)
                LabeledContent(range.condition.anchorTitle, value: range.start.iso8601)
                if selection.applies(to: lot) {
                    LabeledContent(helpText("Estimated quality range"), value: range.earliest.iso8601 + " – " + range.latest.iso8601)
                        .accessibilityIdentifier("pantry.foodKeeper.range")
                } else {
                    Text(helpText("This batch or reference has changed. Review its current storage and starting date again."))
                        .accessibilityIdentifier("pantry.foodKeeper.needsReview")
                }
                Button(helpText("Remove saved quality range")) {
                    Task {
                        do {
                            try await model.verifyDigestLot(lot, origin: access.scope.origin)
                            try await store.saveRange(nil, scope: access.scope, lot: lot, authorized: access.authorized)
                            failure = nil
                        } catch { failure = helpText("Could not save this range. Check the current batch and try again.") }
                    }
                }.accessibilityIdentifier("pantry.foodKeeper.remove")
            }
            if let failure { Text(failure) }
        }
    }
}

struct PantryLotStorageReference: View {
    @ObservedObject private var store = PantryDigestStore.shared
    @ObservedObject var model: PantryModel
    let lotID: UUID
    let accessAllowed: Bool
    @Environment(\.pantryDigestAccess) private var access

    var body: some View {
        if accessAllowed, model.phase == .ready, let lot = model.snapshot?.lots.first(where: { $0.id == lotID }) {
            let day = lot.openedAt.flatMap { try? MealDay(date: $0, timeZoneIdentifier: TimeZone.current.identifier) }
            let match = matchAction(for: lot)
            let range = match.flatMap { try? store.document($0.scope).currentGuideRange(for: lot) }
            FoodKeeperLookupView(context: .init(foodName: lot.name, storage: lot.location.foodKeeperStorage,
                                                 openedDay: day, reviewedRange: range, matchLot: match, saveRange: saveAction(for: lot)))
                .id(lot.revision)
        } else {
            Text(pantryText("Unlock the authorized private workspace to view pantry food."))
        }
    }

    private func matchAction(for lot: InventoryLot) -> FoodKeeperMatchLot? {
        guard let access, access.authorized(), model.snapshot?.state.workspaceID == access.scope.origin else { return nil }
        return .init(id: lot.id, revision: lot.revision, scope: access.scope, current: {
            access.authorized() && model.canEdit && model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot
        }, verify: {
            guard access.authorized() else { throw PantryDigestFailure.changed }
            try await model.verifyDigestLot(lot, origin: access.scope.origin)
            guard access.authorized() else { throw PantryDigestFailure.changed }
        })
    }

    private func saveAction(for lot: InventoryLot) -> ((FoodKeeperReviewedRange) async throws -> Void)? {
        guard let access, access.authorized(), model.snapshot?.state.workspaceID == access.scope.origin,
              lot.count.quantity?.amount != .zero else { return nil }
        return { range in
            try await model.verifyDigestLot(lot, origin: access.scope.origin)
            try await PantryDigestStore.shared.saveRange(range, scope: access.scope, lot: lot, authorized: access.authorized)
        }
    }
}
