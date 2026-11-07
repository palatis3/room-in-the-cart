import XCTest
import Combine
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
    private func fixture(paid: Bool = false, catalog: [MealTemplate] = []) -> (MemoryDinnerStore, DinnerFeatureModel) {
        let store = MemoryDinnerStore()
        let shop = ShoppingLedger(title: "Actual pickup", basis: ShopBasis(timeZoneIdentifier: "America/Los_Angeles"))
        store.workspace.shops = [shop]; store.workspace.selectedShopID = shop.id
        let model = DinnerFeatureModel(store: store, access: { id in
            DinnerAccessContext(scope: .local(workspaceID: store.sourceWorkspaceID!), actorID: "local", shopID: id,
                assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: paid,
                roleRevision: 0, verifiedAt: self.now, validUntil: self.now.addingTimeInterval(3600))
        }, phase: { _ in .draft }, ideaCatalog: catalog, clock: { self.now })
        return (store, model)
    }
    func testTotalServingsValidationNamesTheFieldAndRetainsDraftAndStore() throws {
        let (store, model) = fixture()
        var original = try recipe()
        original.notes = "Keep the beans separate."
        original.sourceURL = "https://example.invalid/unavailable-recipe"
        original.servingGroups = [ServingGroup(name: "Dinner", servings: .one)]
        let before = store.workspace
        for input in ["", "0", "-1", "beans", "1/0"] {
            var draft = DinnerTemplateDraft(original)
            draft.servings = input
            XCTAssertThrowsError(try draft.template()) { failure in
                XCTAssertEqual(failure as? DinnerDraftValidationError, .totalServings)
                model.report(failure)
            }
            XCTAssertEqual(model.error, dinnerText("Total servings: enter a number greater than zero."))
            XCTAssertEqual(draft.servings, input)
            XCTAssertEqual(draft.title, original.title)
            XCTAssertEqual(draft.notes, original.notes)
            XCTAssertEqual(draft.source, original.sourceURL)
            XCTAssertEqual(draft.ingredients.map(\.id), original.ingredients.map(\.id))
            XCTAssertEqual(draft.groups.map(\.id), original.servingGroups.map(\.id))
            XCTAssertEqual(draft.original, original)
            XCTAssertEqual(store.workspace, before)
            XCTAssertEqual(store.commits, 0)
            XCTAssertNil(model.preview)
        }
    }

    func testCorrectedServingsReviewClearsStaleFeedbackAndSavesRetainedDraft() async throws {
        let (store, model) = fixture()
        var original = try recipe()
        original.notes = "Keep the beans separate."
        original.sourceURL = "https://example.invalid/unavailable-recipe"
        var draft = DinnerTemplateDraft(original)
        draft.servings = "0"
        do { _ = try draft.template(); XCTFail("Zero servings must reject") }
        catch { model.report(error) }
        XCTAssertNotNil(model.error)
        let before = store.workspace
        draft.servings = "1,5"
        let reviewed = try draft.template()
        model.clearErrorAfterSuccessfulReview()
        XCTAssertNil(model.error)
        XCTAssertEqual(store.workspace, before)
        XCTAssertEqual(store.commits, 0)
        XCTAssertEqual(reviewed.servings, try Rational(3, 2))
        XCTAssertEqual(reviewed.notes, original.notes)
        XCTAssertEqual(reviewed.sourceURL, original.sourceURL)
        XCTAssertEqual(reviewed.ingredients, original.ingredients)
        let saved = await model.accept(reviewed, id: UUID(), fallback: false)
        XCTAssertTrue(saved)
        XCTAssertNil(model.error)
        XCTAssertEqual(store.workspace.dinnerPlanning.acceptedDinners.map(\.template), [reviewed])
        XCTAssertEqual(store.workspace.shops, before.shops)
        XCTAssertEqual(store.commits, 1)
    }

    func testOtherInvalidNumericFieldsAreNotReportedAsTotalServings() throws {
        let (_, model) = fixture()
        var draft = DinnerTemplateDraft(try recipe())
        draft.ingredients[0].amount = "not an amount"
        XCTAssertThrowsError(try draft.template()) { failure in
            XCTAssertNil(failure as? DinnerDraftValidationError)
            model.report(failure)
        }
        XCTAssertEqual(model.error, dinnerText("Check the entered amounts, dates and required fields. Nothing has been applied."))
        for input in ["2", "1/2", "1,5"] {
            var valid = DinnerTemplateDraft(try recipe())
            valid.servings = input
            XCTAssertGreaterThan(try valid.template().servings, .zero)
        }
    }

    func testBundledFreeIdeasAreEditableAndApprovalKeepsShoppingListUntouched() async throws {
        let patterns = DinnerPatternCatalog.patterns
        let (store, model) = fixture(catalog: patterns)
        let before = store.workspace
        XCTAssertEqual(Set(patterns.map(\.id)).count, 3)
        for (index, pattern) in patterns.enumerated() {
            try pattern.validate()
            XCTAssertGreaterThan(pattern.ingredients.count, 1)
            XCTAssertNotNil(pattern.leadTimeMinutes)
            XCTAssertFalse(pattern.notes.isEmpty)
            let draft = try model.newIdea(seed: UInt64(index), exclusions: [])
            XCTAssertEqual(draft.template, pattern)
            XCTAssertFalse(draft.availabilityConfirmed)
            XCTAssertFalse(draft.yieldConfirmed)
            XCTAssertFalse(DinnerIdeaEngine.review(draft).canClaimCoverage)
        }
        XCTAssertEqual(store.workspace, before)
        let excluded = try XCTUnwrap(patterns.first?.ingredients.first?.name)
        var proposal = try model.newIdea(seed: 0, exclusions: [excluded])
        proposal.yieldConfirmed = true
        proposal.availabilityConfirmed = true
        XCTAssertFalse(DinnerIdeaEngine.review(proposal).canAccept)
        proposal.template.ingredients.removeAll { $0.name == excluded }
        let approved = await model.acceptIdea(proposal, acceptedID: UUID())
        XCTAssertTrue(approved)
        XCTAssertEqual(store.workspace.dinnerPlanning.acceptedDinners.count, 1)
        XCTAssertEqual(store.workspace.shops, before.shops)
    }
    func testIdeaPreparationAbandonRepeatSaveAcceptAndChooseHaveSeparateEffects() async throws {
        // Preparation is synchronous: abandoning means dropping an unsaved value,
        // not cancelling an invented asynchronous generator or persistence job.
        let (store, model) = fixture(catalog: DinnerPatternCatalog.patterns)
        let before = store.workspace
        var abandoned: DinnerIdeaDraft? = try model.newIdea(seed: 0, exclusions: [])
        let abandonedID = try XCTUnwrap(abandoned).id
        let preparedTemplate = try XCTUnwrap(abandoned).template
        XCTAssertEqual(store.workspace, before); XCTAssertEqual(store.commits, 0)
        abandoned = nil
        XCTAssertNil(abandoned)
        XCTAssertEqual(store.workspace, before); XCTAssertEqual(store.commits, 0)

        var draft = try model.newIdea(seed: 0, exclusions: [])
        XCTAssertNotEqual(draft.id, abandonedID)
        XCTAssertEqual(draft.template, preparedTemplate)
        XCTAssertEqual(store.workspace, before); XCTAssertEqual(store.commits, 0)
        draft.availabilityConfirmed = true; draft.yieldConfirmed = true
        XCTAssertTrue(DinnerIdeaEngine.review(draft).canAccept)
        let saved = await model.saveIdea(draft); XCTAssertTrue(saved)
        let afterSave = store.workspace
        XCTAssertEqual(afterSave.dinnerPlanning.ideas.map(\.id), [draft.id])
        XCTAssertTrue(afterSave.dinnerPlanning.acceptedDinners.isEmpty)
        XCTAssertEqual(afterSave.shops, before.shops); XCTAssertEqual(store.commits, 1)
        let savedAgain = await model.saveIdea(draft); XCTAssertTrue(savedAgain)
        XCTAssertEqual(store.workspace, afterSave); XCTAssertEqual(store.commits, 1)

        let acceptedID = UUID()
        let accepted = await model.acceptIdea(draft, acceptedID: acceptedID); XCTAssertTrue(accepted)
        let afterAccept = store.workspace
        XCTAssertEqual(afterAccept.dinnerPlanning.ideas.map(\.id), [draft.id])
        XCTAssertEqual(afterAccept.dinnerPlanning.acceptedDinners.map(\.id), [acceptedID])
        XCTAssertEqual(afterAccept.dinnerPlanning.freeReusableDinnerID, acceptedID)
        XCTAssertEqual(afterAccept.shops, before.shops); XCTAssertEqual(store.commits, 2)
        let acceptedAgain = await model.acceptIdea(draft, acceptedID: acceptedID); XCTAssertTrue(acceptedAgain)
        XCTAssertEqual(store.workspace, afterAccept); XCTAssertEqual(store.commits, 2)

        // Only a separately reviewed choose may create grocery needs.
        let acceptedDinner = try XCTUnwrap(model.state.acceptedDinners.first)
        let choice = PlannedDinner(acceptedDinnerID: acceptedID, template: acceptedDinner.template)
        XCTAssertTrue(model.prepare([.choose(choice)]))
        XCTAssertEqual(store.workspace, afterAccept); XCTAssertEqual(store.commits, 2)
        model.cancelPreview()
        XCTAssertEqual(store.workspace, afterAccept); XCTAssertEqual(store.commits, 2)
        XCTAssertTrue(model.prepare([.choose(choice)]))
        let applied = await model.applyPreview(); XCTAssertTrue(applied)
        let afterChoose = store.workspace
        let shop = try XCTUnwrap(model.shop)
        XCTAssertEqual(shop.mealOccurrences.map(\.id), [choice.occurrenceID])
        XCTAssertEqual(Set(shop.contributions.map(\.id)), Set(choice.contributionIDs))
        XCTAssertEqual(shop.contributions.count, choice.contributionIDs.count)
        XCTAssertEqual(afterChoose.dinnerPlanning.applyReceipts.count, 1)
        XCTAssertEqual(store.commits, 3)
        let appliedAgain = await model.applyPreview(); XCTAssertFalse(appliedAgain)
        XCTAssertEqual(store.workspace, afterChoose); XCTAssertEqual(store.commits, 3)
    }

    func testIdeaGenerateSaveAndAcceptRecheckDeniedRuntimeWithoutAnyCommit() async throws {
        let (store, _) = fixture()
        var runtimeAvailable = true
        var canPlan = true
        let model = DinnerFeatureModel(store: store, access: { id in
            guard runtimeAvailable else { return nil }
            return DinnerAccessContext(scope: .local(workspaceID: store.sourceWorkspaceID!), actorID: "adult", shopID: id,
                assignedShopperID: "adult", canPlan: canPlan, canReadBudget: true, hasPaidTools: false,
                roleRevision: 1, verifiedAt: self.now, validUntil: self.now.addingTimeInterval(3600))
        }, phase: { _ in .draft }, ideaCatalog: DinnerPatternCatalog.patterns, clock: { self.now })
        var draft = try model.newIdea(seed: 0, exclusions: [])
        draft.availabilityConfirmed = true; draft.yieldConfirmed = true
        XCTAssertTrue(DinnerIdeaEngine.review(draft).canAccept)
        let baseline = store.workspace
        let acceptedID = UUID()
        for missingContext in [true, false] {
            runtimeAvailable = !missingContext; canPlan = false
            XCTAssertThrowsError(try model.newIdea(seed: 0, exclusions: [])) { error in
                XCTAssertEqual(error as? DinnerPlanningError, .forbidden)
            }
            XCTAssertEqual(store.workspace, baseline); XCTAssertEqual(store.commits, 0)
            let saved = await model.saveIdea(draft); XCTAssertFalse(saved)
            XCTAssertEqual(store.workspace, baseline); XCTAssertEqual(store.commits, 0)
            let accepted = await model.acceptIdea(draft, acceptedID: acceptedID); XCTAssertFalse(accepted)
            XCTAssertEqual(store.workspace, baseline); XCTAssertEqual(store.commits, 0)
        }
        // Identical draft and accepted ID succeed once genuine access is restored;
        // malformed content or a store that rejects everything cannot satisfy this test.
        runtimeAvailable = true; canPlan = true
        XCTAssertNoThrow(try model.newIdea(seed: 0, exclusions: []))
        XCTAssertEqual(store.workspace, baseline); XCTAssertEqual(store.commits, 0)
        let saved = await model.saveIdea(draft); XCTAssertTrue(saved)
        let accepted = await model.acceptIdea(draft, acceptedID: acceptedID); XCTAssertTrue(accepted)
        XCTAssertEqual(model.state.ideas.map(\.id), [draft.id])
        XCTAssertEqual(model.state.acceptedDinners.map(\.id), [acceptedID])
        XCTAssertEqual(store.workspace.shops, baseline.shops); XCTAssertEqual(store.commits, 2)
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
    func testCancellingContextualReviewRestoresOnlyTheStillCurrentPendingDecision() async throws {
        let (store,model) = fixture()
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        let pending = try XCTUnwrap(model.preview)
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: try recipe()))]))
        XCTAssertNotEqual(model.preview?.proposal.id, pending.proposal.id)
        model.endDecision(restoring: pending)
        XCTAssertEqual(model.preview?.proposal.id,pending.proposal.id)
        XCTAssertEqual(store.commits,0)
        let applied = await model.applyPreview()
        XCTAssertTrue(applied)
        model.endDecision(restoring: pending)
        XCTAssertNil(model.preview)
        XCTAssertEqual(store.commits,1)
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

    func testRetryAcceptedDinnerPreservesOriginalTimestampAndOneCommit() async throws {
        let (store, original) = fixture(); var clock = now
        let model = DinnerFeatureModel(store: store, access: original.accessProvider, phase: { _ in .draft }, clock: { clock })
        let id = UUID(); let template = try recipe()
        let first = await model.accept(template, id: id, fallback: false); XCTAssertTrue(first)
        clock = now.addingTimeInterval(60)
        let retry = await model.accept(template, id: id, fallback: false); XCTAssertTrue(retry)
        XCTAssertEqual(store.commits, 1); XCTAssertEqual(model.state.acceptedDinners.first?.acceptedAt, now)
    }

    func testLegacyTemplatesAndChosenOccurrencesRemainReadableWithoutAdoption() async throws {
        let (store, model) = fixture(); var template = try recipe(); template.revision = 3
        store.workspace.mealTemplates = [template]
        _ = try store.workspace.shops[0].chooseMeal(template)
        let savedShop = store.workspace.shops[0]
        XCTAssertTrue(model.state.acceptedDinners.isEmpty)
        let start = try MealDay(date: now, timeZoneIdentifier: savedShop.basis.timeZoneIdentifier)
        XCTAssertEqual(try model.week(start: start).unscheduled.map(\.id), savedShop.mealOccurrences.map(\.id))
        let accepted = await model.accept(template, id: UUID(), fallback: false); XCTAssertTrue(accepted)
        XCTAssertEqual(model.state.acceptedDinners.first?.template, template)
        XCTAssertEqual(model.workspace.mealTemplates, [template]); XCTAssertEqual(model.shop, savedShop)
    }
    func testRuntimePublisherRefreshesVisibleFeatureState() async {
        let (_, model) = fixture(); let changes = PassthroughSubject<Void, Never>()
        model.observeRuntime(changes.eraseToAnyPublisher())
        let expectation = expectation(description: "Runtime change forwarded")
        let subscription = model.objectWillChange.sink { expectation.fulfill() }
        changes.send(())
        await fulfillment(of: [expectation], timeout: 2)
        withExtendedLifetime(subscription) {}
    }

    func testReviewedGuestTotalChangesOnlySelectedUnprotectedGroup() async throws {
        let (_, model) = fixture(paid: true)
        let dinner = ServingGroup(name: "Dinner", servings: try Rational(2))
        let lunch = ServingGroup(name: "Lunch", servings: .one, isProtected: true)
        var template = try recipe(); template.servings = try Rational(3); template.servingGroups = [dinner, lunch]
        template.ingredients[0].quantity = Quantity(amount: try Rational(9), unit: .count, originalLiteral: "9")
        XCTAssertTrue(model.prepare([.choose(PlannedDinner(template: template))])); _ = await model.applyPreview()
        let meal = model.shop!.mealOccurrences[0]; let source = model.shop!.contributions[0]
        let bindings = [DinnerPortionBinding(occurrenceID: meal.id, contributionID: source.id, groupID: dinner.id,
            quantity: Quantity(amount: try Rational(6), unit: .count, originalLiteral: "6"), servings: dinner.servings),
            DinnerPortionBinding(occurrenceID: meal.id, contributionID: source.id, groupID: lunch.id,
                quantity: Quantity(amount: try Rational(3), unit: .count, originalLiteral: "3"), servings: lunch.servings)]
        _ = await model.saveBindings(bindings, occurrenceID: meal.id)
        let original = model.shop!; let revision = original.revisionID
        XCTAssertTrue(model.previewGuestTotal(occurrenceID: meal.id, groupID: dinner.id, total: try Rational(4), reviewedRevision: revision))
        XCTAssertEqual(model.shop, original)
        XCTAssertEqual(model.preview?.projectedMeals[0].servingGroups.first { $0.id == lunch.id }?.servings, .one)
        XCTAssertEqual(model.preview?.projectedContributions[0].quantity?.amount, try Rational(15))
        XCTAssertFalse(model.previewGuestTotal(occurrenceID: meal.id, groupID: lunch.id, total: try Rational(2), reviewedRevision: revision))
        XCTAssertNil(model.preview)
        XCTAssertFalse(model.previewGuestTotal(occurrenceID: meal.id, groupID: dinner.id, total: try Rational(4), reviewedRevision: UUID()))
        XCTAssertEqual(model.shop, original)
    }

}


@MainActor final class DinnerScenarioDraftTests: XCTestCase {
    private func fixture(exclusions: [String] = []) throws -> (ShoppingLedger, DinnerPlanningState, DinnerScenarioDraft) {
        let shop = ShoppingLedger(title: "Actual shop", basis: ShopBasis(branch: "Branch", timeZoneIdentifier: "America/Los_Angeles"))
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "a", shopID: shop.id, assignedShopperID: "a",
            canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(3600))
        let wraps = MealIngredient(name: "Wraps", quantity: Quantity(amount: try Rational(6), unit: .count, originalLiteral: "6"))
        let beans = MealIngredient(name: "Beans", quantity: Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2"))
        let first = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Wrap dinner", servings: try Rational(2), ingredients: [wraps, beans], exclusions: exclusions), acceptedAt: now)
        let second = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Alternative", servings: try Rational(2), ingredients: [wraps, beans], exclusions: exclusions), acceptedAt: now, acceptedFallback: true)
        var state = DinnerPlanningState(); try state.accept(first, access: access, at: now); try state.accept(second, access: access, at: now)
        var draft = DinnerScenarioDraft(shop: shop, state: state)
        draft.meals[0].name = "Dinner"; draft.meals[0].portions = "2"; draft.meals[0].currentDinnerID = first.id; draft.meals[0].candidateDinnerID = second.id
        try draft.prepareMatches(accepted: state.acceptedDinners)
        var wrapFood = DinnerFoodEvidenceDraft(); wrapFood.name = "Wraps"; wrapFood.packLabel = "Wrap pack"; wrapFood.packAmount = "10"; wrapFood.packPrice = "3"; wrapFood.yieldReviewed = true; wrapFood.availability = 1
        var beanFood = DinnerFoodEvidenceDraft(); beanFood.name = "Beans"; beanFood.packLabel = "Bean pack"; beanFood.packAmount = "4"; beanFood.packPrice = "2"; beanFood.yieldReviewed = true; beanFood.availability = 1
        draft.foods = [wrapFood, beanFood]
        for index in draft.matches.indices {
            // These assignments stand in for explicit picker choices, never a production name matcher.
            draft.matches[index].foodID = draft.matches[index].ingredientID == wraps.id ? wrapFood.id : beanFood.id
        }
        draft.store = "Retailer"; draft.source = "Reviewed shelf observation"; draft.recipeYieldsReviewed = true
        draft.baselineComplete = true; draft.baselineExcludesComparedRecipes = true
        draft.fee = "0"; draft.tax = "0"; draft.deposits = "0"
        draft.currentHands = "15"; draft.currentLead = "20"; draft.candidateHands = "15"; draft.candidateLead = "20"; draft.availableMinutes = "60"
        return (shop, state, draft)
    }
    func testEveryDemandRetainsExplicitRecipeIngredientIdentity() throws {
        let (shop, state, draft) = try fixture()
        let review = try draft.build(shop: shop, state: state)
        XCTAssertEqual(Set(review.current.demands.compactMap(\.ingredientID)), Set(state.acceptedDinners[0].template.ingredients.map(\.id)))
        XCTAssertEqual(review.current.commitments, review.candidate.commitments)
        XCTAssertEqual(review.current.baselineLines, review.candidate.baselineLines)
        let result = try DinnerScenarioEngine.evaluate(review.candidate, acceptedDinners: state.acceptedDinners)
        XCTAssertTrue(result.foodCoverageComplete); XCTAssertEqual(result.checkout.total.exact, Money(minorUnits: 500))
    }
    func testBlankFoodChoiceDoesNotGuessFromEqualNames() throws {
        let (shop, state, original) = try fixture(); var draft = original; draft.matches[0].foodID = nil
        XCTAssertThrowsError(try draft.build(shop: shop, state: state))
    }
    func testPortionChangeRequiresNewReviewAndScalesExactRecipeQuantities() throws {
        let (shop, state, original) = try fixture(); var draft = original; draft.meals[0].portions = "3"
        XCTAssertThrowsError(try draft.build(shop: shop, state: state))
        try draft.prepareMatches(accepted: state.acceptedDinners)
        XCTAssertTrue(draft.matches.allSatisfy { $0.foodID == nil })
        let quantities = draft.matches.compactMap { $0.quantity?.amount }
        XCTAssertTrue(quantities.contains(try Rational(9))); XCTAssertTrue(quantities.contains(try Rational(3)))
    }
    func testConfirmedStockCannotIgnoreUnreviewedOutsideReservations() throws {
        let (shop, state, original) = try fixture(); var draft = original
        draft.foods[0].stockAmount = "2"; draft.foods[0].stockConfirmed = true
        XCTAssertThrowsError(try draft.build(shop: shop, state: state))
        draft.foods[0].outsideReservationsReviewed = true; draft.foods[0].outsideAmount = "1"
        let review = try draft.build(shop: shop, state: state)
        let result = try DinnerScenarioEngine.evaluate(review.current, acceptedDinners: state.acceptedDinners)
        XCTAssertEqual(review.current.stock.count, 1); XCTAssertEqual(review.current.otherReservations.count, 1)
        let wrapNeed = review.current.demands.first { $0.foodID == draft.foods[0].id }!
        XCTAssertEqual(result.stockAllocation.demands.first { $0.id == wrapNeed.id }?.allocated, .one)
    }
    func testUnknownPackYieldAndPriceNeverBecomeZeroOrCoverage() throws {
        let (shop, state, original) = try fixture(); var draft = original
        draft.foods[0].yieldReviewed = false; draft.foods[0].packPrice = ""
        let review = try draft.build(shop: shop, state: state)
        let result = try DinnerScenarioEngine.evaluate(review.candidate, acceptedDinners: state.acceptedDinners)
        XCTAssertFalse(result.foodCoverageComplete); XCTAssertNil(result.checkout.total.exact)
    }
    func testIncompleteUnchangedBasketPreventsExactCheckout() throws {
        let (shop, state, original) = try fixture(); var draft = original
        draft.baselineExcludesComparedRecipes = false
        let review = try draft.build(shop: shop, state: state)
        XCTAssertNil(try DinnerScenarioEngine.evaluate(review.candidate, acceptedDinners: state.acceptedDinners).checkout.total.exact)
    }
    func testStaleLedgerBlocksEvidenceBuiltBeforeEdit() throws {
        var (shop, state, draft) = try fixture()
        _ = try shop.addManualLine(name: "New staple", quantity: nil)
        XCTAssertThrowsError(try draft.build(shop: shop, state: state))
    }
    func testProtectedRecipeDoesNotAutomaticallyScaleAllGroups() throws {
        var (shop, state, draft) = try fixture()
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let access = DinnerAccessContext(scope: .local(workspaceID: UUID()), actorID: "a", shopID: shop.id, assignedShopperID: "a",
            canPlan: true, canReadBudget: true, hasPaidTools: true, roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(100))
        var recipe = state.acceptedDinners[0].template; recipe.revision += 1; recipe.servingGroups = [ServingGroup(name: "Lunch", servings: .one, isProtected: true)]
        let protected = AcceptedDinner(id: UUID(), template: recipe, acceptedAt: now)
        try state.accept(protected, access: access, at: now)
        draft = DinnerScenarioDraft(shop: shop, state: state); draft.meals[0].name = "Dinner"; draft.meals[0].portions = "3"; draft.meals[0].candidateDinnerID = protected.id
        XCTAssertThrowsError(try draft.prepareMatches(accepted: state.acceptedDinners))
    }
    func testExcludedFoodAndPackLabelsCannotPassAnExplicitMatch() throws {
        let (shop, state, original) = try fixture(exclusions: ["peanut"])
        var draft = original; draft.foods[0].name = "Peanut wraps"
        XCTAssertThrowsError(try draft.build(shop: shop, state: state)) { error in
            guard case LedgerError.excludedIngredient = error else { return XCTFail("Expected exclusion rejection") }
        }
        draft = original; draft.foods[0].packLabel = "Peanut wrap pack"
        XCTAssertThrowsError(try draft.build(shop: shop, state: state)) { error in
            guard case LedgerError.excludedIngredient = error else { return XCTFail("Expected exclusion rejection") }
        }
    }
    func testTwoDinnerDemandsUseOneConfirmedStockLotOnlyOnce() throws {
        let (shop, state, original) = try fixture(); var draft = original
        var next = DinnerScenarioMealDraft(); next.name = "Second dinner"; next.portions = "2"
        next.currentDinnerID = draft.meals[0].currentDinnerID; next.candidateDinnerID = draft.meals[0].candidateDinnerID
        draft.meals.append(next); try draft.prepareMatches(accepted: state.acceptedDinners); draft.recipeYieldsReviewed = true
        let wrapIngredientID = state.acceptedDinners[0].template.ingredients[0].id
        for index in draft.matches.indices { draft.matches[index].foodID = draft.matches[index].ingredientID == wrapIngredientID ? draft.foods[0].id : draft.foods[1].id }
        draft.foods[0].stockAmount = "6"; draft.foods[0].stockConfirmed = true; draft.foods[0].outsideReservationsReviewed = true
        let review = try draft.build(shop: shop, state: state)
        let result = try DinnerScenarioEngine.evaluate(review.candidate, acceptedDinners: state.acceptedDinners)
        let allocated = try result.stockAllocation.demands.filter { $0.foodID == draft.foods[0].id }.reduce(Rational.zero) { try $0.adding($1.allocated ?? .zero) }
        XCTAssertEqual(allocated, try Rational(6))
        XCTAssertEqual(result.packs.first { $0.foodID == draft.foods[0].id }?.result?.packsToBuy, 1)
    }

}
