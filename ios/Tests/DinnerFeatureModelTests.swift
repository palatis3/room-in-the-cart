import XCTest
import CoreDomain
@testable import RoomInTheCart

@MainActor private final class MemoryDinnerStore: DinnerWorkspaceStore {
    var workspace = LedgerWorkspace()
    var sourceWorkspaceID: UUID? = UUID()
    var ready = true
    var saving = false
    var hasPendingSave = false
    var failSave = false
    var commits = 0
    func change(key: String, _ edit: (inout LedgerWorkspace) throws -> Void) async -> Bool {
        do {
            var candidate = workspace; try edit(&candidate); try candidate.validate()
            guard !failSave else { return false }
            if candidate != workspace { workspace = candidate; commits += 1 }; return true
        } catch { return false }
    }
}
@MainActor final class DinnerFeatureModelTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    private func fixture(paid: Bool = false) -> (MemoryDinnerStore, DinnerFeatureModel) {
        let store = MemoryDinnerStore()
        let shop = ShoppingLedger(title: "Actual pickup", basis: ShopBasis(timeZoneIdentifier: "America/Los_Angeles"))
        store.workspace.shops = [shop]; store.workspace.selectedShopID = shop.id
        let model = DinnerFeatureModel(store: store, access: { id in
            DinnerAccessContext(scope: .local(workspaceID: store.sourceWorkspaceID!), actorID: "local", shopID: id,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: paid,
                roleRevision: 0, verifiedAt: self.now, validUntil: self.now.addingTimeInterval(3600))
        }, phase: { _ in .draft }, clock: { self.now })
        return (store, model)
    }
    private func recipe() throws -> MealTemplate {
        MealTemplate(title: "Wraps", servings: try Rational(2), ingredients: [MealIngredient(name: "Wraps",
            quantity: Quantity(amount: try Rational(6), unit: .count, originalLiteral: "6"))])
    }
    func testFreeManualPreviewIsReadonlyCancelAndApplyOnce() async throws {
        let (store, model) = fixture(); let before = store.workspace
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        XCTAssertEqual(store.workspace, before); XCTAssertTrue(model.canApply)
        model.cancelPreview(); XCTAssertEqual(store.workspace, before)
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        let proposal = try XCTUnwrap(model.preview?.proposal)
        let saved = await model.applyPreview(); XCTAssertTrue(saved)
        XCTAssertEqual(store.workspace.shops[0].mealOccurrences.count, 1)
        XCTAssertEqual(store.workspace.dinnerPlanning.applyReceipts.map(\.id), [proposal.id])
        let again = await model.applyPreview(); XCTAssertFalse(again); XCTAssertEqual(store.commits, 1)
    }
    func testFailedDurableSaveRetainsExactPreviewAndSavedWorkspace() async throws {
        let (store, model) = fixture(); let before = store.workspace
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))])); let preview = model.preview
        store.failSave = true
        let failed = await model.applyPreview(); XCTAssertFalse(failed)
        XCTAssertEqual(store.workspace, before); XCTAssertEqual(model.preview, preview)
        store.failSave = false
        let retried = await model.applyPreview(); XCTAssertTrue(retried)
        XCTAssertEqual(store.workspace.dinnerPlanning.applyReceipts.first?.id, preview?.proposal.id)
    }
    func testChangedLedgerRejectsReviewedApply() async throws {
        let (store, model) = fixture()
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        _ = try store.workspace.shops[0].addManualLine(name: "Milk", quantity: nil)
        let revision = store.workspace.shops[0].revisionID
        let saved = await model.applyPreview(); XCTAssertFalse(saved)
        XCTAssertEqual(store.workspace.shops[0].revisionID, revision)
        XCTAssertTrue(store.workspace.shops[0].mealOccurrences.isEmpty)
    }
    func testAuthRevocationIsRecheckedBeforeApply() async throws {
        let (store, _) = fixture(); var allowed = true
        let model = DinnerFeatureModel(store: store, access: { id in
            guard allowed else { return nil }
            return DinnerAccessContext(scope: .local(workspaceID: store.sourceWorkspaceID!), actorID: "a", shopID: id,
                assignedShopperID: "a", canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 1,
                verifiedAt: self.now, validUntil: self.now.addingTimeInterval(3600))
        }, phase: { _ in .draft }, clock: { self.now })
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        allowed = false
        XCTAssertFalse(model.canApply)
        let saved = await model.applyPreview(); XCTAssertFalse(saved); XCTAssertEqual(store.commits, 0)
    }
    func testSharedEvenAuthorizedFlagCannotApplyThroughLocalAdapter() async throws {
        let (store, _) = fixture()
        let model = DinnerFeatureModel(store: store, access: { id in
            DinnerAccessContext(scope: .household(id: "verified-household"), actorID: "adult", shopID: id,
                assignedShopperID: "adult", canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 1,
                verifiedAt: self.now, validUntil: self.now.addingTimeInterval(3600), sharedCommitAuthorized: true)
        }, phase: { _ in .draft }, clock: { self.now })
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        XCTAssertFalse(model.canApply); XCTAssertTrue(model.sharedPreview)
        let saved = await model.savePreviewAsProposal(); XCTAssertTrue(saved)
        XCTAssertEqual(store.workspace.dinnerPlanning.proposals.count, 1)
        XCTAssertTrue(store.workspace.shops[0].mealOccurrences.isEmpty)
    }
    func testLocalBindingCannotUseImportedWorkspaceIdentity() throws {
        let (store, _) = fixture()
        let model = DinnerFeatureModel(store: store, access: { id in
            DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "local", shopID: id,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 0,
                verifiedAt: self.now, validUntil: self.now.addingTimeInterval(3600))
        }, phase: { _ in .draft }, clock: { self.now })
        XCTAssertFalse(model.prepare([.choose(PlannedDinner(template: try recipe()))])); XCTAssertFalse(model.accessAvailable)
    }
    func testIdeaAcceptDoesNotChooseAndFreeSlotSwitchIsExplicit() async throws {
        let (store, model) = fixture()
        let idea = try model.newIdea(seed: 0, exclusions: [], manual: recipe())
        let firstID = UUID(); let accepted = await model.acceptIdea(idea, acceptedID: firstID); XCTAssertTrue(accepted)
        XCTAssertTrue(store.workspace.shops[0].mealOccurrences.isEmpty)
        XCTAssertTrue(store.workspace.shops[0].contributions.isEmpty)
        XCTAssertEqual(store.workspace.dinnerPlanning.freeReusableDinnerID, firstID)
        let secondID = UUID(); let saved = await model.accept(try recipe(), id: secondID, fallback: true); XCTAssertTrue(saved)
        let second = try XCTUnwrap(model.state.acceptedDinners.first { $0.id == secondID })
        XCTAssertFalse(model.choose(second, day: nil))
        let switched = await model.selectFree(secondID); XCTAssertTrue(switched)
        XCTAssertTrue(model.choose(second, day: nil)); XCTAssertTrue(store.workspace.shops[0].mealOccurrences.isEmpty)
    }
    func testUndatedOccurrenceGetsCivilDateWithoutNewNeeds() async throws {
        let (store, model) = fixture()
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))])); _ = await model.applyPreview()
        let meal = try XCTUnwrap(model.shop?.mealOccurrences.first); let needs = model.shop?.contributions
        let day = try MealDay(year: 2026, month: 11, day: 8, timeZoneIdentifier: "America/Los_Angeles")
        XCTAssertTrue(model.prepare([.move(occurrenceID: meal.id, day: day)])); _ = await model.applyPreview()
        XCTAssertEqual(store.workspace.shops[0].mealOccurrences.first?.id, meal.id)
        XCTAssertEqual(store.workspace.shops[0].mealOccurrences.first?.scheduledDay, day)
        XCTAssertEqual(store.workspace.shops[0].contributions, needs)
    }
    func testGuestBindingsAreRequiredAndFreeExplorationCannotApply() async throws {
        let (_, model) = fixture()
        let group = ServingGroup(name: "Dinner", servings: try Rational(2))
        var template = try recipe(); template.servingGroups = [group]
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: template))])); _ = await model.applyPreview()
        let meal = try XCTUnwrap(model.shop?.mealOccurrences.first)
        XCTAssertFalse(model.previewGuests(occurrenceID: meal.id, servings: [group.id: try Rational(4)], isolated: true))
        let source = try XCTUnwrap(model.shop?.contributions.first)
        let saved = await model.saveBindings([DinnerPortionBinding(occurrenceID: meal.id, contributionID: source.id, groupID: group.id,
            quantity: source.quantity!, servings: group.servings)], occurrenceID: meal.id)
        XCTAssertTrue(saved)
        XCTAssertTrue(model.previewGuests(occurrenceID: meal.id, servings: [group.id: try Rational(4)], isolated: true))
        XCTAssertEqual(model.preview?.projectedContributions.first?.quantity?.amount, try Rational(12))
        XCTAssertFalse(model.canApply)
        let applied = await model.applyPreview(); XCTAssertFalse(applied)
        XCTAssertEqual(model.shop?.contributions.first?.quantity?.amount, try Rational(6))
    }
    func testAwayNoteDoesNotRemoveDinner() async throws {
        let (_, model) = fixture()
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))])); _ = await model.applyPreview()
        let before = model.shop
        let day = try MealDay(year: 2026, month: 11, day: 8, timeZoneIdentifier: "America/Los_Angeles")
        let saved = await model.saveNote(DinnerWeekNote(shopID: model.shop!.id, day: day, kind: .away, text: "Away"))
        XCTAssertTrue(saved); XCTAssertEqual(model.shop, before); XCTAssertEqual(try model.week(start: day).days[0].notes.count, 1)
    }
    func testLockedBasketPreviewOnlyAndCalendarRemainsManual() async throws {
        let (store, _) = fixture()
        let model = DinnerFeatureModel(store: store, access: { id in
            DinnerAccessContext(scope: .local(workspaceID: store.sourceWorkspaceID!), actorID: "a", shopID: id, assignedShopperID: "a",
                canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 0, verifiedAt: self.now, validUntil: self.now.addingTimeInterval(3600))
        }, phase: { _ in .frozen }, clock: { self.now })
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))])); XCTAssertTrue(model.preview!.needsPurchaseAmendment)
        XCTAssertFalse(model.canApply)
    }
    func testParsingExactFractionSpanishDecimalAndUnknown() throws {
        XCTAssertEqual(try DinnerEntry.rational("1/3"), try Rational(1, 3))
        XCTAssertEqual(try DinnerEntry.rational("1,25"), try Rational(5, 4))
        XCTAssertNil(try DinnerEntry.quantity("", unit: .count))
        XCTAssertNil(try DinnerEntry.money(" "))
        XCTAssertThrowsError(try DinnerEntry.money("0.001"))
        XCTAssertThrowsError(try DinnerEntry.rational("1,000.25"))
        XCTAssertThrowsError(try DinnerEntry.positive("0"))
    }
    func testStoreDraftNeverInventsChargesOrTravel() throws {
        var draft = DinnerStoreDraft(); draft.label = "Store"; draft.storeID = "store"; draft.branch = "branch"; draft.source = "Retailer receipt"; draft.total = "12.50"
        let commitments = DinnerCommitmentSet(commitments: [DinnerCommitment(name: "Dinner", kind: .dinner, portions: .one)])
        let option = try draft.option(commitments: commitments, basis: ShopBasis())
        XCTAssertNil(try CheckoutEngine.evaluate(option.quote).total.exact)
        XCTAssertNil(option.available)
        if case .unknown = option.trip.incrementalCash {} else { XCTFail("Missing trip cash must stay unknown") }
        draft.allChargesIncluded = true
        let reviewed = try draft.option(commitments: commitments, basis: ShopBasis())
        XCTAssertEqual(try CheckoutEngine.evaluate(reviewed.quote).total.exact, Money(minorUnits: 1250))
    }
    func testEditorBaseChangeRejectsRatherThanOverwritingCurrentAmounts() throws {
        let (store, model) = fixture(); let base = model.shop!.revisionID
        _ = try store.workspace.shops[0].addManualLine(name: "New item", quantity: nil)
        XCTAssertFalse(model.prepare([.choose(PlannedDinner(template: try recipe()))], expectedRevision: base))
        XCTAssertNil(model.preview); XCTAssertTrue(model.shop!.mealOccurrences.isEmpty)
    }
    func testSwitchingShopHidesOldPreviewAndCannotApplyIt() throws {
        let (store, model) = fixture()
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        let second = ShoppingLedger(title: "Other pickup"); store.workspace.shops.append(second); store.workspace.selectedShopID = second.id
        XCTAssertFalse(model.canReviewPreview); XCTAssertFalse(model.canApply)
    }
    func testInvalidReplacementPreviewClearsPreviousPendingPreview() throws {
        let (_, model) = fixture()
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        XCTAssertFalse(model.prepare([.choose(PlannedDinner(template: MealTemplate(title: "")))]))
        XCTAssertNil(model.preview)
    }
    func testTemplateRevisionPreservedUntilAnExplicitEdit() throws {
        var original = try recipe(); original.revision = 4
        var draft = DinnerTemplateDraft(original)
        XCTAssertEqual(try draft.template(), original)
        draft.notes = "Reviewed change"
        XCTAssertEqual(try draft.template().revision, 5)
        XCTAssertEqual(try draft.template().id, original.id)
    }
    func testFreeRotationCannotSaveButManualStillWorks() async throws {
        let (_, model) = fixture(); let id = UUID()
        _ = await model.accept(try recipe(), id: id, fallback: false)
        let rotation = DinnerRotation(title: "Usual week", entries: [DinnerRotationEntry(acceptedDinnerID: id, dayOffset: 0)])
        let saved = await model.saveRotation(rotation); XCTAssertFalse(saved); XCTAssertTrue(model.state.rotations.isEmpty)
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
    }
    func testQuoteProofSavedThenBasisAdoptionIsExplicitAndStalesOnEdit() async throws {
        let (store, model) = fixture()
        let commitments = DinnerCommitmentSet(commitments: [DinnerCommitment(name: "Dinner", kind: .dinner, portions: .one)])
        var a = DinnerStoreDraft(); a.label = "A"; a.storeID = "a"; a.branch = "branch-a"; a.source = "Reviewed retailer total"
        a.allChargesIncluded = true; a.total = "12"; a.quantitiesMatched = true; a.singleStore = true; a.availability = 1; a.tripCash = "0"
        var b = a; b.id = UUID(); b.label = "B"; b.storeID = "b"; b.branch = "branch-b"; b.total = "10"
        let shop = model.shop!
        let pair = TwoStoreQuotePair(shopID: shop.id, baseRevisionID: shop.revisionID, basisRevision: shop.basisRevision,
            first: try a.option(commitments: commitments, basis: shop.basis), second: try b.option(commitments: commitments, basis: shop.basis))
        XCTAssertFalse(model.previewAdoption(pair, option: pair.second))
        let saved = await model.saveQuotePair(pair); XCTAssertTrue(saved)
        XCTAssertTrue(model.previewAdoption(pair, option: pair.second)); XCTAssertEqual(model.shop, shop)
        let applied = await model.applyPreview(); XCTAssertTrue(applied)
        XCTAssertEqual(model.shop?.basis.branch, "branch-b"); XCTAssertEqual(model.shop?.basisRevision, shop.basisRevision + 1)
        XCTAssertEqual(model.shop?.contributions, shop.contributions)
        XCTAssertEqual(store.workspace.dinnerPlanning.quotePairs, [pair])
        XCTAssertFalse(model.previewAdoption(pair, option: pair.first)); XCTAssertNil(model.preview)
    }

}
