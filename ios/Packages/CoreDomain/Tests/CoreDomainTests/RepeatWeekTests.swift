import XCTest
@testable import CoreDomain

final class RepeatWeekTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let workspaceID = UUID()
    private func quantity(_ n: Int64) throws -> Quantity { .init(amount: try Rational(n), unit: .count, originalLiteral: String(n)) }
    private func day(_ d: Int, _ zone: String = "America/New_York") throws -> MealDay {
        try MealDay(year: 2026, month: 11, day: d, timeZoneIdentifier: zone)
    }
    private func access(_ shop: ShoppingLedger, paid: Bool = false, actor: String = "adult", scope: DinnerAccessContext.Scope? = nil) -> DinnerAccessContext {
        .init(scope: scope ?? .local(workspaceID: workspaceID), actorID: actor, shopID: shop.id, assignedShopperID: "adult",
              canPlan: true, canReadBudget: false, hasPaidTools: paid, roleRevision: 1, verifiedAt: now.addingTimeInterval(-10),
              validUntil: now.addingTimeInterval(300))
    }
    private func fixture(protected: Bool = false) throws -> LedgerWorkspace {
        var history = ShoppingLedger(title: "Prior market", basis: .init(branch: "Market", timeZoneIdentifier: "Pacific/Kiritimati"))
        let recipe = MealTemplate(title: "Tuesday beans", servings: try Rational(2),
            ingredients: [.init(name: "Beans", quantity: try quantity(1)), .init(name: "Rice", quantity: try quantity(4)), .init(name: "Salt", quantity: nil)],
            servingGroups: protected ? [.init(name: "Lunch", servings: .one, isProtected: true)] : [], completedSteps: ["Chopped"])
        _ = try history.chooseMeal(recipe, on: day(3, "Pacific/Kiritimati").date, at: now)
        let sources = history.mealOccurrences[0].ingredientContributionIDs
        try history.updateContribution(contributionID: sources[0], quantity: quantity(3), notes: "actual amount", at: now)
        _ = try history.chooseMeal(recipe, on: day(9, "Pacific/Kiritimati").date, at: now)
        _ = try history.chooseMeal(recipe, at: now)
        let coffee = try history.addManualLine(name: "Coffee", quantity: quantity(1), at: now)
        try history.approveStaple(lineID: coffee, purpose: "Breakfast", at: now)
        var target = ShoppingLedger(title: "This market", basis: .init(branch: "Market", timeZoneIdentifier: "America/New_York"))
        _ = try target.addManualLine(name: "Coffee", quantity: quantity(1), at: now)
        return .init(shops: [history, target], mealTemplates: [recipe], selectedShopID: target.id)
    }

    func testWeeklyReceiptCapturesBasketOnceAndRequiresBudgetAuthority() throws {
        var workspace = try fixture()
        let shop = workspace.shops[1]
        let context = DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "adult", shopID: shop.id,
            assignedShopperID: "adult", canPlan: true, canReadBudget: true, hasPaidTools: false, roleRevision: 1,
            verifiedAt: now.addingTimeInterval(-10), validUntil: now.addingTimeInterval(300))
        let start = try day(9)
        let candidates = try RepeatWeekEngine.candidates(targetStart: start, workspace: workspace, access: context, at: now)
        let meal = RepeatWeek.Selection(try XCTUnwrap(candidates.first))
        let preview = try RepeatWeekEngine.preview(targetStart: start, meals: [meal], staples: [], workspace: workspace,
                                                   access: context, phase: .draft, at: now)
        var restricted = workspace
        let redacted = try RepeatWeekEngine.apply(preview.proposal, workspace: &restricted, access: access(shop), phase: .draft, at: now)
        XCTAssertNil(redacted.costBaseline)
        let applied = try RepeatWeekEngine.apply(preview.proposal, workspace: &workspace, access: context, phase: .draft, at: now)
        let baseline = try XCTUnwrap(applied.costBaseline)
        XCTAssertEqual(Set(baseline.lines.map(\.name)), Set(["Coffee", "Beans", "Rice", "Salt"]))
        XCTAssertTrue(baseline.lines.allSatisfy { $0.estimate == nil })
        XCTAssertEqual(workspace.ledgerDocumentVersion, 2)
        _ = try workspace.shops[1].addManualLine(name: "Later", quantity: nil, at: now)
        let reopened = try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(workspace))
        XCTAssertEqual(reopened.dinnerPlanning.applyReceipts.first?.costBaseline, baseline)
        XCTAssertEqual(try RepeatWeekEngine.apply(preview.proposal, workspace: &workspace, access: context, phase: .draft, at: now).costBaseline, baseline)
    }

    func testCivilLabelsEditedContributionsNewIdentitiesAndFreeRetryAcrossSourceChange() throws {
        var w = try fixture()
        let historical = w.shops[0], originalRecipes = w.mealTemplates, target = w.shops[1], auth = access(target)
        let start = try day(9)
        let rows = try RepeatWeekEngine.candidates(targetStart: start, workspace: w, access: auth, at: now)
        XCTAssertEqual(rows.count, 1)
        let candidate = rows[0]
        XCTAssertEqual(candidate.sourceDay, try day(3, "Pacific/Kiritimati"))
        XCTAssertEqual(candidate.targetDay, try day(10))
        XCTAssertEqual(candidate.template.ingredients[0].quantity, try quantity(3))
        XCTAssertEqual(candidate.template.ingredients[0].notes, "actual amount")
        XCTAssertTrue(candidate.template.completedSteps.isEmpty)
        var edit = RepeatWeek.Selection(candidate)
        edit.servings = try Rational(4)
        edit.day = try day(11)
        edit.ingredientEdits = [.init(contributionID: candidate.template.ingredients[1].id, quantity: try quantity(7))]
        let operation = UUID()
        XCTAssertThrowsError(try RepeatWeekEngine.preview(id: operation, targetStart: start, meals: [edit], staples: [], workspace: w,
            access: access(target, scope: .local(workspaceID: UUID())), phase: .draft, at: now))
        let review = try RepeatWeekEngine.preview(id: operation, targetStart: start, meals: [edit], staples: [], workspace: w, access: auth, phase: .draft, at: now)
        let repeated = try RepeatWeekEngine.preview(id: operation, targetStart: start, meals: [edit], staples: [], workspace: w, access: auth, phase: .draft, at: now)
        XCTAssertEqual(review.proposal, repeated.proposal)
        XCTAssertEqual(w.shops[1], target)
        XCTAssertEqual(review.proposal.repeatWeek?.sourceShopIDs, [historical.id])
        var ledger = target, state = w.dinnerPlanning
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(review.proposal, ledger: &ledger, state: &state, access: auth, phase: .draft, at: now))
        let encoded = try JSONEncoder().encode(review.proposal)
        let proposal = try JSONDecoder().decode(DinnerProposal.self, from: encoded)
        let receipt = try RepeatWeekEngine.apply(proposal, workspace: &w, access: auth, phase: .draft, at: now)
        XCTAssertEqual(w.shops[0], historical)
        XCTAssertEqual(w.mealTemplates, originalRecipes)
        let new = try XCTUnwrap(w.shops[1].mealOccurrences.first)
        XCTAssertEqual(new.repeatedFrom, candidate.source)
        XCTAssertNotEqual(new.id, candidate.source.occurrenceID)
        XCTAssertEqual(new.scheduledDay, try day(11))
        XCTAssertTrue(Set(new.ingredientContributionIDs).isDisjoint(with: historical.mealOccurrences[0].ingredientContributionIDs))
        let amounts = w.shops[1].contributions.filter { $0.source == .meal(occurrenceID: new.id) }.map(\.quantity)
        XCTAssertEqual(amounts, [try quantity(6), try quantity(7), nil])
        _ = try w.shops[0].addManualLine(name: "Later edit", quantity: nil, at: now)
        let after = w
        XCTAssertEqual(try RepeatWeekEngine.apply(proposal, workspace: &w, access: auth, phase: .frozen, at: now), receipt)
        XCTAssertEqual(w, after)
        XCTAssertEqual(try JSONDecoder().decode(LedgerWorkspace.self, from: JSONEncoder().encode(w)), w)
        XCTAssertThrowsError(try RepeatWeekEngine.apply(proposal, workspace: &w, access: access(target, scope: .local(workspaceID: UUID())), phase: .draft, at: now))
    }

    func testRememberedStaplesArePaidAtomicAndCanBeTheOnlyReviewedChoice() throws {
        var w = try fixture()
        let target = w.shops[1], auth = access(target, paid: true), start = try day(9)
        let review = try XCTUnwrap(w.priorStaples(for: target.id).first)
        let current = try XCTUnwrap(target.lines.first)
        let handled = RepeatWeek.StapleSelection(review: review, choice: .alreadyHandled, handledLine: .init(lineID: current.id, boughtBy: "Partner"))
        let wrong = RepeatWeek.StapleSelection(review: review, choice: .needed, quantity: try quantity(1))
        let meal = try XCTUnwrap(RepeatWeekEngine.candidates(targetStart: start, workspace: w, access: auth, at: now).first)
        XCTAssertThrowsError(try RepeatWeekEngine.preview(targetStart: start, meals: [.init(meal)], staples: [wrong], workspace: w, access: auth, phase: .draft, at: now))
        XCTAssertThrowsError(try RepeatWeekEngine.preview(targetStart: start, meals: [], staples: [handled], workspace: w, access: access(target), phase: .draft, at: now))
        for meals in [[RepeatWeek.Selection](), [.init(meal)]] {
            var copy = w
            let p = try RepeatWeekEngine.preview(targetStart: start, meals: meals, staples: [handled], workspace: copy, access: auth, phase: .draft, at: now).proposal
            XCTAssertThrowsError(try RepeatWeekEngine.apply(p, workspace: &copy, access: auth, phase: .reportedPlaced, at: now))
            XCTAssertEqual(copy, w)
            XCTAssertThrowsError(try RepeatWeekEngine.apply(p, workspace: &copy, access: access(target), phase: .draft, at: now))
            let first = try RepeatWeekEngine.apply(p, workspace: &copy, access: auth, phase: .draft, at: now)
            XCTAssertEqual(copy.shops[1].revision, target.revision + 1)
            XCTAssertEqual(copy.shops[1].lines.first { $0.id == current.id }?.handledBy, "Partner")
            XCTAssertEqual(copy.shops[1].mealOccurrences.count, meals.count)
            XCTAssertEqual(copy.shops[1].stapleReviews?.first?.source, review.source)
            XCTAssertEqual(try RepeatWeekEngine.apply(p, workspace: &copy, access: access(target), phase: .draft, at: now), first)
        }
        let p = try RepeatWeekEngine.preview(targetStart: start, meals: [.init(meal)], staples: [handled], workspace: w, access: auth, phase: .draft, at: now).proposal
        _ = try w.shops[0].addManualLine(name: "Changed source", quantity: nil, at: now)
        let changed = w
        XCTAssertThrowsError(try RepeatWeekEngine.apply(p, workspace: &w, access: auth, phase: .draft, at: now))
        XCTAssertEqual(w, changed)
    }

    func testDecidedStapleHistoryUsesExactSourceAndIsNeverOfferedAgain() throws {
        var w = try fixture()
        let target = w.shops[1]
        let reviewed = try XCTUnwrap(w.priorStaples(for: target.id).first)
        try w.applyStaple(reviewed, choice: .alreadyHandled, quantity: nil, at: now)
        let similar = try w.shops[0].addManualLine(name: "Coffee", quantity: quantity(2), at: now)
        try w.shops[0].approveStaple(lineID: similar, purpose: "Second purpose", at: now)
        let history = w.reviewedStapleHistory(for: target.id)
        XCTAssertEqual(history.map(\.source), [reviewed.source])
        XCTAssertEqual(history.first?.line.id, reviewed.line.id)
        XCTAssertEqual(history.first?.sourceRevision, w.shops[0].revisionID)
        XCTAssertEqual(history.first?.targetRevision, w.shops[1].revisionID)
        XCTAssertEqual(history.first?.approval, reviewed.approval)
        XCTAssertEqual(w.priorStaples(for: target.id).map(\.line.id), [similar])
        XCTAssertTrue(w.reviewedStapleHistory(for: w.shops[0].id).isEmpty)
    }

    func testNewStapleAndNewMealShareOneRevisionAndRetainTheirReviewedLineIDs() throws {
        var w = try fixture()
        let target = ShoppingLedger(title: "New destination", basis: w.shops[1].basis)
        w.shops[1] = target
        w.selectedShopID = target.id
        let auth = access(target, paid: true), start = try day(9)
        let originalShop = w.shops[0]
        let prior = try XCTUnwrap(w.priorStaples(for: target.id).first)
        let selection = RepeatWeek.StapleSelection(review: prior, choice: .needed, quantity: try quantity(2))
        let meal = try XCTUnwrap(RepeatWeekEngine.candidates(targetStart: start, workspace: w, access: auth, at: now).first)
        let preview = try RepeatWeekEngine.preview(targetStart: start, meals: [.init(meal)], staples: [selection], workspace: w,
                                                  access: auth, phase: .draft, at: now)
        let proposed = try XCTUnwrap(preview.projectedContributions.first { $0.productName == "Coffee" && $0.removedAt == nil })
        let receipt = try RepeatWeekEngine.apply(preview.proposal, workspace: &w, access: auth, phase: .draft, at: now)
        XCTAssertEqual(receipt.revisionID, w.shops[1].revisionID)
        XCTAssertEqual(w.shops[1].revision, target.revision + 1)
        XCTAssertEqual(w.shops[1].stapleReviews?.first?.newLineID, proposed.lineID)
        XCTAssertEqual(w.shops[1].contributions.first { $0.id == proposed.id }, proposed)
        XCTAssertNotEqual(proposed.lineID, prior.source.lineID)
        let added = try XCTUnwrap(w.shops[1].lines.first { $0.id == proposed.lineID })
        XCTAssertFalse(added.isHandled)
        XCTAssertFalse(added.isChecked)
        XCTAssertEqual(w.shops[0], originalShop)
    }

    func testReopenedWeekExcludesAnAppliedDinnerAndPersistsExplicitSkipWithoutAddingGroceries() throws {
        var workspace = try fixture()
        let target = workspace.shops[1], start = try day(9), actor = access(target, paid: true)
        let rows = try RepeatWeekEngine.candidates(targetStart: start, workspace: workspace, access: actor, at: now)
        let source = try XCTUnwrap(rows.first), staple = try XCTUnwrap(workspace.priorStaples(for: target.id).first)
        var selected = RepeatWeek.Selection(source)
        selected.day = try day(11)
        let reviewed = try RepeatWeekEngine.preview(targetStart: start, meals: [selected], staples: [.init(review: staple, choice: .skip)],
            workspace: workspace, access: actor, phase: .draft, at: now)
        let receipt = try RepeatWeekEngine.apply(reviewed.proposal, workspace: &workspace, access: actor, phase: .draft, at: now)
        let saved = workspace
        XCTAssertEqual(try RepeatWeekEngine.apply(reviewed.proposal, workspace: &workspace, access: actor, phase: .draft, at: now), receipt)
        XCTAssertEqual(workspace, saved)
        XCTAssertTrue(try RepeatWeekEngine.candidates(targetStart: start, workspace: workspace, access: actor, at: now).isEmpty)
        XCTAssertEqual(workspace.shops[1].stapleReviews?.first?.choice, .skip)
        XCTAssertNil(workspace.shops[1].stapleReviews?.first?.newLineID)
        XCTAssertThrowsError(try RepeatWeekEngine.preview(targetStart: start, meals: [selected], staples: [],
            workspace: workspace, access: actor, phase: .draft, at: now))
    }

    func testRenamedFoodDoesNotInheritRecipeCertificationAcrossDSTTransition() throws {
        let zone = "America/New_York"
        let sourceDay = try MealDay(year: 2026, month: 3, day: 3, timeZoneIdentifier: zone)
        let targetDay = try MealDay(year: 2026, month: 3, day: 10, timeZoneIdentifier: zone)
        let start = try MealDay(year: 2026, month: 3, day: 9, timeZoneIdentifier: zone)
        var shop = ShoppingLedger(basis: .init(timeZoneIdentifier: zone))
        var meal = MealTemplate(title: "Snack", ingredients: [.init(name: "Original wrap", quantity: try quantity(1), exclusions: ["sesame"])])
        var evidence = MealEligibilityEvidence(); evidence.reviewedIngredientDetails = ["rice flour"]
        meal.eligibilityEvidence = evidence
        _ = try shop.chooseMeal(meal, on: sourceDay.date, at: now)
        var w = LedgerWorkspace(shops: [shop], mealTemplates: [meal], selectedShopID: shop.id)
        let auth = access(shop)
        let before = try XCTUnwrap(RepeatWeekEngine.candidates(targetStart: start, workspace: w, access: auth, at: now).first)
        XCTAssertEqual(before.targetDay, targetDay)
        XCTAssertEqual(before.template.eligibilityEvidence, evidence)
        let line = try XCTUnwrap(shop.lines.first)
        try w.shops[0].updateLine(lineID: line.id, name: "Different wrap", notes: "", aisle: "", at: now)
        let after = try XCTUnwrap(RepeatWeekEngine.candidates(targetStart: start, workspace: w, access: auth, at: now).first)
        XCTAssertNil(after.template.eligibilityEvidence)
        XCTAssertEqual(after.template.ingredients.first?.name, "Different wrap")
        XCTAssertEqual(after.template.ingredients.first?.exclusions, ["sesame"])
    }

    func testProtectedGroupAndRecoveredReplacementRequireTheirOwnExactEvidence() throws {
        var w = try fixture(protected: true)
        let auth = access(w.shops[1]), start = try day(9)
        let original = try XCTUnwrap(RepeatWeekEngine.candidates(targetStart: start, workspace: w, access: auth, at: now).first)
        var changed = RepeatWeek.Selection(original); changed.servings = try Rational(3)
        XCTAssertThrowsError(try RepeatWeekEngine.preview(targetStart: start, meals: [changed], staples: [], workspace: w, access: auth, phase: .draft, at: now))
        changed.ingredientEdits = original.template.ingredients.map { .init(contributionID: $0.id, quantity: $0.quantity) }
        let safe = try RepeatWeekEngine.preview(targetStart: start, meals: [changed], staples: [], workspace: w, access: auth, phase: .draft, at: now)
        XCTAssertEqual(safe.projectedMeals.last?.servingGroups.first?.servings, .one)
        let q = try quantity(2), id = UUID(), need = StockNeed(id: UUID(), foodID: UUID(), name: "Soup", amount: q, priority: .required)
        let replacement = RecoveryMeal(id: original.source.occurrenceID, revisionID: UUID(), templateID: id, templateVersion: 1, title: "Replacement soup",
            servings: .one, ingredients: [.init(ingredientID: UUID(), groupID: nil, foodName: "Soup", need: need)],
            scheduledDay: try day(4), due: nil, timeZoneID: "America/New_York", exclusions: [], remainingElapsedMinutes: nil, requiredLeadMinutes: nil, advanceStepsCompleted: false)
        let recipe = MealTemplate(id: id, title: replacement.title, ingredients: [.init(id: need.id, name: "Soup", quantity: q)], revision: 1)
        let recoveries = [replacement.id: RepeatWeek.Recovery(meal: replacement, template: recipe)]
        let rows = try RepeatWeekEngine.candidates(targetStart: start, workspace: w, recoveredMeals: recoveries, access: auth, at: now)
        XCTAssertEqual(rows.first?.targetDay, try day(11))
        XCTAssertEqual(rows.first?.source.recoveryRevision, replacement.revisionID)
        XCTAssertEqual(rows.first?.template.ingredients.first?.id, need.id)
        let p = try RepeatWeekEngine.preview(targetStart: start, meals: [.init(try XCTUnwrap(rows.first))], staples: [], workspace: w, recoveredMeals: recoveries,
                                             access: auth, phase: .draft, at: now).proposal
        XCTAssertThrowsError(try RepeatWeekEngine.apply(p, workspace: &w, access: auth, phase: .draft, at: now))
        XCTAssertThrowsError(try RepeatWeekEngine.candidates(targetStart: start, workspace: w, access: access(w.shops[1], scope: .household(id: "other")), at: now))
        _ = try RepeatWeekEngine.apply(p, workspace: &w, recoveredMeals: recoveries, access: auth, phase: .draft, at: now)
        XCTAssertEqual(w.shops[1].mealOccurrences.first?.title, "Replacement soup")
    }
}
