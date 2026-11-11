import XCTest
import SwiftUI
import CoreDomain
@testable import RoomInTheCart

@MainActor final class DinnerDraftBindingTests: XCTestCase {
    @MainActor private final class Box<Value> {
        var value: Value
        init(_ value: Value) { self.value = value }
        var binding: Binding<Value> { Binding(get: { self.value }, set: { self.value = $0 }) }
    }
    private func group(_ name: String, protected: Bool = false) -> DinnerGroupDraft {
        DinnerGroupDraft(ServingGroup(name: name, servings: .one, isProtected: protected))
    }

    func testRetainedProtectedToggleReadsFallbackAfterEditorCollectionIsCleared() {
        let lunch = group("Lunch", protected: true), box = Box([lunch])
        let row = dinnerDraftBinding(lunch, in: box.binding)
        let retainedToggle = row.isProtected
        box.value = []
        XCTAssertTrue(retainedToggle.wrappedValue, "Outgoing Switch teardown may still read its row")
        retainedToggle.wrappedValue = false
        XCTAssertTrue(box.value.isEmpty, "Late UI writes must not recreate a removed group")
    }

    func testBindingsFollowIdentityAcrossRemovalAndReordering() {
        let first = group("First"), lunch = group("Lunch"), last = group("Last")
        let box = Box([first, lunch, last])
        let lunchBinding = dinnerDraftBinding(lunch, in: box.binding)
        box.value.removeFirst()
        box.value.reverse()
        lunchBinding.isProtected.wrappedValue = true
        lunchBinding.servings.wrappedValue = "2"
        XCTAssertEqual(box.value.map(\.id), [last.id, lunch.id])
        XCTAssertEqual(box.value[1].servings, "2"); XCTAssertTrue(box.value[1].isProtected)
        XCTAssertFalse(box.value[0].isProtected); XCTAssertEqual(box.value[0].servings, "1")
    }

    func testRemovedBindingCannotReadOrWriteReplacementAtSameIndex() {
        let removed = group("Removed", protected: true), replacement = group("Different")
        let box = Box([removed])
        let stale = dinnerDraftBinding(removed, in: box.binding)
        box.value = [replacement]
        XCTAssertEqual(stale.wrappedValue.id, removed.id)
        XCTAssertEqual(stale.name.wrappedValue, "Removed")
        stale.isProtected.wrappedValue = true
        stale.name.wrappedValue = "Late rename"
        XCTAssertEqual(box.value.count, 1); XCTAssertEqual(box.value[0].id, replacement.id)
        XCTAssertEqual(box.value[0].name, "Different"); XCTAssertFalse(box.value[0].isProtected)
    }

    func testCurrentReadsRemainLiveAndIdentityChangingWritesAreIgnored() {
        let initial = group("Initial"), box = Box([group("Other")])
        box.value.append(initial)
        let row = dinnerDraftBinding(initial, in: box.binding)
        box.value[1].name = "Latest name"; box.value[1].servings = "6"
        XCTAssertEqual(row.name.wrappedValue, "Latest name")
        row.isProtected.wrappedValue = true
        XCTAssertEqual(box.value[1].name, "Latest name"); XCTAssertEqual(box.value[1].servings, "6")
        var wrongIdentity = row.wrappedValue; wrongIdentity.id = UUID(); wrongIdentity.name = "Wrong"
        row.wrappedValue = wrongIdentity
        XCTAssertEqual(box.value[1].id, initial.id); XCTAssertEqual(box.value[1].name, "Latest name")
    }

    func testIngredientBindingSurvivesRemovalWithoutRedirectingTextOrUnitEdits() {
        var ingredient = DinnerIngredientDraft(); ingredient.name = "Wraps"; ingredient.amount = "6"
        var replacement = DinnerIngredientDraft(); replacement.name = "Rice"
        let box = Box([ingredient]), row = dinnerDraftBinding(ingredient, in: Binding(get: { box.value }, set: { box.value = $0 }))
        box.value = [replacement]
        XCTAssertEqual(row.name.wrappedValue, "Wraps")
        row.amount.wrappedValue = "99"; row.unit.wrappedValue = .kilogram
        XCTAssertEqual(box.value[0].name, "Rice"); XCTAssertEqual(box.value[0].amount, "")
        XCTAssertEqual(box.value[0].unit, .count)
    }

    func testManualAllocationDraftPreservesProtectedObservationAndReviewsMutableResultWithoutSaving() throws {
        let lunch = ServingGroup(name: "Lunch", servings: .one, isProtected: true)
        let dinner = ServingGroup(name: "Dinner", servings: try Rational(3))
        let basis = UnitBasis(sourceUnit: .count, targetUnit: .gram,
            targetAmountPerSourceUnit: try Rational(30), sourceNote: "Reviewed package")
        let protectedQuantity = Quantity(amount: try Rational(2), unit: .count,
            originalLiteral: "two lunch wraps", confirmedConversion: basis)
        let total = Quantity(amount: try Rational(8), unit: .count, originalLiteral: "eight wraps", confirmedConversion: basis)
        var ledger = ShoppingLedger()
        let occurrence = try ledger.chooseMeal(MealTemplate(title: "Wraps", servings: try Rational(4),
            ingredients: [.init(name: "Wraps", quantity: total)], servingGroups: [dinner, lunch]), at: Date())
        let source = try XCTUnwrap(ledger.contributions.first), sourceID = source.id
        let original = DinnerPortionBinding(occurrenceID: occurrence, contributionID: sourceID,
            groupID: lunch.id, quantity: protectedQuantity, servings: lunch.servings)
        let protectedDraft = DinnerBindingDraft(contribution: source, group: lunch, existing: original)
        XCTAssertEqual(try protectedDraft.binding(occurrenceID: occurrence), original)
        let mutable = DinnerPortionBinding(occurrenceID: occurrence, contributionID: sourceID,
            groupID: dinner.id, quantity: Quantity(amount: try Rational(6), unit: .count, originalLiteral: "six dinner wraps"), servings: dinner.servings)
        var draft = DinnerBindingDraft(contribution: source, group: dinner, existing: mutable)
        draft.amount = "7"
        let reviewed = try draft.binding(occurrenceID: occurrence, servings: Rational(4))
        XCTAssertEqual(reviewed.id, mutable.id); XCTAssertEqual(reviewed.quantity.amount, try Rational(7))
        XCTAssertEqual(reviewed.servings, try Rational(4)); XCTAssertEqual(mutable.quantity.amount, try Rational(6))
        draft.amount = ""
        XCTAssertThrowsError(try draft.binding(occurrenceID: occurrence), "Missing amounts cannot become zero")
        var ingredient = DinnerIngredientDraft(MealIngredient(id: sourceID, name: "Wraps", quantity: total))
        XCTAssertEqual(try ingredient.reviewedQuantity(), total, "Untouched observations retain their literal and conversion")
        ingredient.amount = "9"
        XCTAssertEqual(try ingredient.reviewedQuantity()?.amount, try Rational(9))
        XCTAssertNil(try ingredient.reviewedQuantity()?.confirmedConversion, "Changed observations do not silently inherit evidence")
    }
}
