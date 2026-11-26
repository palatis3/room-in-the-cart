import CryptoKit
import Foundation

/// A manual recap binds each selected occurrence to the private shop that authored it.
public enum RepeatWeek {
    public struct Source: Codable, Hashable, Sendable {
        public let workspaceID: UUID
        public let shopID: UUID
        public let shopRevision: UUID
        public let occurrenceID: UUID
        public let recoveryRevision: UUID?
    }

    public struct Recovery: Equatable, Sendable {
        public let meal: RecoveryMeal
        /// Ingredient IDs are the exact replacement need IDs, including distinct group needs.
        public let template: MealTemplate
        public init(meal: RecoveryMeal, template: MealTemplate) { self.meal = meal; self.template = template }
    }

    public struct Candidate: Identifiable, Equatable, Sendable {
        public var id: Source { source }
        public let source: Source
        public let shopTitle: String
        public let sourceDay: MealDay
        public let targetDay: MealDay
        public let template: MealTemplate
    }

    public struct Selection: Codable, Equatable, Identifiable, Sendable {
        public var id: Source { source }
        public let source: Source
        public var day: MealDay
        public var servings: Rational
        public var ingredientEdits: [DinnerQuantityEdit]
        public init(_ candidate: Candidate) {
            source = candidate.source; day = candidate.targetDay
            servings = candidate.template.servings; ingredientEdits = []
        }
    }

    public struct StapleSelection: Codable, Equatable, Sendable {
        public let review: ReviewedStaple
        public let choice: StapleChoice
        public let quantity: Quantity?
        public let handledLine: HandledStapleLine?
        public init(review: ReviewedStaple, choice: StapleChoice, quantity: Quantity? = nil, handledLine: HandledStapleLine? = nil) {
            self.review = review; self.choice = choice; self.quantity = quantity; self.handledLine = handledLine
        }
    }

    public struct Plan: Codable, Equatable, Sendable {
        public let targetStart: MealDay
        public let meals: [Selection]
        public let staples: [StapleSelection]
        public var sourceShopIDs: Set<UUID> {
            Set(meals.map(\.source.shopID)).union(staples.map(\.review.source.shopID))
        }

        func validate() throws {
            try targetStart.validate()
            guard !meals.isEmpty || !staples.isEmpty, meals.count + staples.count <= 500,
                  Set(meals.map(\.source)).count == meals.count,
                  Set(staples.map(\.review.source)).count == staples.count else { throw DinnerPlanningError.invalid("repeatWeek") }
            let days = try (0..<7).map { try dinnerDay(targetStart, adding: $0) }
            for row in meals {
                guard days.contains(row.day), row.servings > .zero, row.ingredientEdits.count <= 200 else { throw DinnerPlanningError.invalid("repeatMeal") }
                try dinnerUnique(row.ingredientEdits.map(\.contributionID))
                for edit in row.ingredientEdits { try edit.quantity?.validate() }
            }
            for row in staples {
                guard row.review.source.lineID == row.review.line.id, row.review.line.stapleApproval == row.review.approval,
                      !row.review.line.isTrashed, row.choice == .alreadyHandled || row.handledLine == nil,
                      row.choice == .needed || row.quantity == nil, row.quantity.map({ $0.amount > .zero }) ?? true
                else { throw DinnerPlanningError.invalid("repeatStaple") }
                try row.quantity?.validate()
            }
        }
    }

    struct PreparedStaple {
        let selection: StapleSelection
        let exclusions: [String]
        let lineID: UUID
        let contributionID: UUID
    }
}

public enum RepeatWeekEngine {
    private static func target(_ workspace: LedgerWorkspace, access: DinnerAccessContext, at now: Date, applying: Bool = false) throws -> Int {
        try access.validate(shopID: access.shopID, at: now, applying: applying)
        guard case .local = access.scope, workspace.selectedShopID == access.shopID,
              let index = workspace.shops.firstIndex(where: { $0.id == access.shopID }) else { throw DinnerPlanningError.forbidden }
        return index
    }

    public static func candidates(targetStart: MealDay, workspace: LedgerWorkspace, recoveredMeals: [UUID: RepeatWeek.Recovery] = [:],
                                  access: DinnerAccessContext, at now: Date) throws -> [RepeatWeek.Candidate] {
        let targetIndex = try target(workspace, access: access, at: now)
        guard case .local(let workspaceID) = access.scope else { throw DinnerPlanningError.forbidden }
        // Match the calendar label saved with the prior meal. Converting its noon instant
        // into the target zone would shift weekday on trips crossing the date line.
        let dates = try (0..<7).map { (try dinnerDay(targetStart, adding: $0 - 7), try dinnerDay(targetStart, adding: $0)) }
        let days = Dictionary(uniqueKeysWithValues: dates.map { ($0.0.iso8601, $0.1) })
        // A reopened review has a fresh operation ID. Match the saved receipt to its
        // live target occurrence so a retry cannot add the same dinner a second time.
        let targetShop = workspace.shops[targetIndex]
        let liveTargetIDs = Set(targetShop.mealOccurrences.filter { $0.removedAt == nil }.map(\.id))
        var repeated: [UUID: Set<UUID>] = [:]
        for receipt in workspace.dinnerPlanning.applyReceipts where receipt.proposal.shopID == targetShop.id {
            guard let plan = receipt.proposal.repeatWeek else { continue }
            for meal in plan.meals where meal.source.workspaceID == workspaceID {
                let source = meal.source
                let id = identity(receipt.id, source: source.shopID, member: source.occurrenceID, kind: "occurrence")
                if liveTargetIDs.contains(id) {
                    repeated[source.shopID, default: []].insert(source.occurrenceID)
                }
            }
        }
        var result = [RepeatWeek.Candidate]()
        var recoveredIDs = Set<UUID>()
        for shop in workspace.shops {
            let contributions = Dictionary(grouping: shop.contributions, by: \.id)
            let liveLines = Set(shop.lines.filter { !$0.isTrashed }.map(\.id))
            for occurrence in shop.mealOccurrences where occurrence.removedAt == nil && !occurrence.isHidden && occurrence.carryover == nil {
                guard repeated[shop.id]?.contains(occurrence.id) != true else { continue }
                let recovery = recoveredMeals[occurrence.id]
                if recovery != nil, !recoveredIDs.insert(occurrence.id).inserted { throw DinnerPlanningError.invalid("ambiguousRecoveredMeal") }
                let sourceDay = recovery.map { $0.meal.scheduledDay } ?? occurrence.scheduledDay
                guard let sourceDay, let targetDay = days[sourceDay.iso8601] else { continue }
                let template: MealTemplate
                if let recovery {
                    guard recovery.meal.id == occurrence.id else { throw DinnerPlanningError.stalePreview }
                    try MealRecoveryEngine.validate(recovery.meal)
                    template = try recoveredTemplate(recovery)
                } else {
                    let ingredients = try occurrence.ingredientContributionIDs.compactMap { id -> MealIngredient? in
                        guard let rows = contributions[id], rows.count == 1, let row = rows.first,
                              row.source == .meal(occurrenceID: occurrence.id) else { throw DinnerPlanningError.stalePreview }
                        guard row.removedAt == nil, liveLines.contains(row.lineID) else { return nil }
                        return .init(id: row.id, name: row.productName, quantity: row.quantity, notes: row.notes,
                                     exclusions: row.exclusions.filter { !occurrence.exclusions.contains($0) })
                    }
                    var snapshot = MealTemplate(id: occurrence.templateID ?? occurrence.id, title: occurrence.title, servings: occurrence.servings,
                        ingredients: ingredients, notes: occurrence.notes, sourceURL: occurrence.sourceURL, exclusions: occurrence.exclusions,
                        revision: occurrence.templateRevision ?? 0, servingGroups: occurrence.servingGroups, leadTimeMinutes: occurrence.leadTimeMinutes,
                        sourceEvidence: occurrence.sourceEvidence)
                    if let exact = workspace.mealTemplates.first(where: { $0.id == occurrence.templateID && $0.revision == occurrence.templateRevision }) {
                        // A substitution can invalidate explicit allergen or appliance evidence from the old recipe.
                        if exact.ingredients.map(\.name) == ingredients.map(\.name) {
                            snapshot.eligibilityEvidence = exact.eligibilityEvidence
                        }
                    }
                    template = snapshot
                }
                try template.validate()
                let source = RepeatWeek.Source(workspaceID: workspaceID, shopID: shop.id, shopRevision: shop.revisionID, occurrenceID: occurrence.id,
                                               recoveryRevision: recovery?.meal.revisionID)
                result.append(.init(source: source, shopTitle: shop.title, sourceDay: sourceDay, targetDay: targetDay, template: template))
            }
        }
        return result.sorted { ($0.sourceDay.iso8601, $0.source.shopID.uuidString, $0.source.occurrenceID.uuidString)
                               < ($1.sourceDay.iso8601, $1.source.shopID.uuidString, $1.source.occurrenceID.uuidString) }
    }

    private static func recoveredTemplate(_ recovery: RepeatWeek.Recovery) throws -> MealTemplate {
        let meal = recovery.meal
        var template = recovery.template
        guard template.servings == meal.servings, template.title == meal.title, Set(meal.exclusions).isSubset(of: Set(template.exclusions)), meal.templateID.map({ $0 == template.id }) ?? true,
              meal.templateVersion.map({ $0 == template.revision }) ?? true,
              template.ingredients.map(\.id) == meal.ingredients.map(\.need.id),
              zip(template.ingredients, meal.ingredients).allSatisfy({ $0.quantity == $1.need.amount && $0.name == $1.foodName })
        else { throw DinnerPlanningError.stalePreview }
        template.completedSteps = []
        return template
    }

    private static func identity(_ operation: UUID, source: UUID, member: UUID, kind: String) -> UUID {
        let bytes = Array(SHA256.hash(data: Data("ritc.repeat-week.v1/\(operation)/\(source)/\(member)/\(kind)".utf8)))
        return UUID(uuid: (bytes[0],bytes[1],bytes[2],bytes[3],bytes[4],bytes[5],bytes[6],bytes[7],
                           bytes[8],bytes[9],bytes[10],bytes[11],bytes[12],bytes[13],bytes[14],bytes[15]))
    }

    public static func projectedTemplate(_ selection: RepeatWeek.Selection, candidate: RepeatWeek.Candidate) throws -> MealTemplate {
        guard selection.source == candidate.source, selection.servings > .zero, selection.ingredientEdits.count <= 200 else {
            throw DinnerPlanningError.invalid("repeatIngredient")
        }
        try dinnerUnique(selection.ingredientEdits.map(\.contributionID))
        var template = candidate.template
        let edits = Dictionary(grouping: selection.ingredientEdits, by: \.contributionID)
        guard Set(edits.keys).isSubset(of: Set(template.ingredients.map(\.id))) else { throw DinnerPlanningError.invalid("repeatIngredient") }
        let scale = try selection.servings.divided(by: template.servings)
        let protected = try template.servingGroups.filter(\.isProtected).reduce(Rational.zero) { try $0.adding($1.servings) }
        if scale != .one, !template.servingGroups.isEmpty {
            let previous = try template.servings.subtracting(protected), next = try selection.servings.subtracting(protected)
            guard previous > .zero, next > .zero else { throw DinnerPlanningError.reviewRequired("protectedGroup") }
            let groupScale = try next.divided(by: previous)
            for index in template.servingGroups.indices where !template.servingGroups[index].isProtected {
                template.servingGroups[index].servings = try template.servingGroups[index].servings.multiplied(by: groupScale)
            }
            if protected > .zero, edits.count != template.ingredients.count { throw DinnerPlanningError.reviewRequired("protectedIngredientAmounts") }
        }
        template.servings = selection.servings
        for index in template.ingredients.indices {
            if let edit = edits[template.ingredients[index].id]?.first { template.ingredients[index].quantity = edit.quantity }
            else if scale != .one, let quantity = template.ingredients[index].quantity {
                let adjusted = try quantity.amount.multiplied(by: scale)
                template.ingredients[index].quantity = .init(amount: adjusted, unit: quantity.unit, originalLiteral: adjusted.description,
                                                           confirmedConversion: quantity.confirmedConversion)
            }
        }
        try template.validate()
        return template
    }

    private static func planned(_ selection: RepeatWeek.Selection, candidate: RepeatWeek.Candidate, operation: UUID) throws -> PlannedDinner {
        let template = try projectedTemplate(selection, candidate: candidate)
        let source = selection.source
        let id = identity(operation, source: source.shopID, member: source.occurrenceID, kind: "occurrence")
        return PlannedDinner(template: template, occurrenceID: id,
            lineIDs: template.ingredients.map { identity(operation, source: id, member: $0.id, kind: "line") },
            contributionIDs: template.ingredients.map { identity(operation, source: id, member: $0.id, kind: "contribution") }, day: selection.day)
    }

    private static func prepare(_ plan: RepeatWeek.Plan, operation: UUID, workspace: LedgerWorkspace,
                                recoveredMeals: [UUID: RepeatWeek.Recovery], access: DinnerAccessContext, at date: Date) throws
        -> ([DinnerLedgerChange], [RepeatWeek.PreparedStaple]) {
        try plan.validate()
        guard plan.staples.isEmpty || access.hasPaidTools else { throw DinnerPlanningError.paidAccessRequired }
        let rows = try candidates(targetStart: plan.targetStart, workspace: workspace, recoveredMeals: recoveredMeals, access: access, at: date)
        let meals = Dictionary(grouping: rows, by: \.source)
        let changes = try plan.meals.map { selection -> DinnerLedgerChange in
            guard let matches = meals[selection.source], matches.count == 1, let candidate = matches.first else { throw DinnerPlanningError.stalePreview }
            return try .choose(planned(selection, candidate: candidate, operation: operation))
        }
        let prior = Dictionary(grouping: workspace.priorStaples(for: access.shopID), by: \.source)
        let staples = try plan.staples.map { selection -> RepeatWeek.PreparedStaple in
            let review = selection.review, source = review.source
            guard prior[source] == [review], let shop = workspace.shops.first(where: { $0.id == source.shopID }) else { throw DinnerPlanningError.stalePreview }
            let exclusions = Array(Set(shop.contributions(forLineID: source.lineID).flatMap(\.exclusions))).sorted()
            return .init(selection: selection, exclusions: exclusions, lineID: identity(operation, source: source.shopID, member: source.lineID, kind: "stapleLine"),
                         contributionID: identity(operation, source: source.shopID, member: source.lineID, kind: "stapleContribution"))
        }
        return (changes, staples)
    }

    public static func preview(id: UUID = UUID(), targetStart: MealDay, meals: [RepeatWeek.Selection], staples: [RepeatWeek.StapleSelection],
                               workspace: LedgerWorkspace, recoveredMeals: [UUID: RepeatWeek.Recovery] = [:], access: DinnerAccessContext,
                               phase: BasketPhase, at now: Date) throws -> DinnerPreview {
        let index = try target(workspace, access: access, at: now)
        let plan = RepeatWeek.Plan(targetStart: targetStart, meals: meals, staples: staples)
        let (changes, rows) = try prepare(plan, operation: id, workspace: workspace, recoveredMeals: recoveredMeals, access: access, at: now)
        return try DinnerPlanningEngine.makePreview(id: id, changes: changes, tool: .manual, ledger: workspace.shops[index], state: workspace.dinnerPlanning,
            access: access, phase: phase, at: now, isolated: false, quoteSelection: nil, repeatWeek: plan, staples: rows,
            revisionID: identity(id, source: access.shopID, member: id, kind: "revision"))
    }

    public static func apply(_ proposal: DinnerProposal, workspace: inout LedgerWorkspace, recoveredMeals: [UUID: RepeatWeek.Recovery] = [:],
                             access: DinnerAccessContext, phase: BasketPhase, at now: Date) throws -> DinnerApplyReceipt {
        let index = try target(workspace, access: access, at: now, applying: true)
        guard let plan = proposal.repeatWeek, proposal.authorID == access.actorID, proposal.namespace == access.namespace,
              proposal.shopID == access.shopID, proposal.tool == .manual, !proposal.isIsolatedPreview else { throw DinnerPlanningError.forbidden }
        if let receipt = workspace.dinnerPlanning.applyReceipts.first(where: { $0.id == proposal.id }) {
            guard receipt.proposal == proposal, receipt.appliedBy == access.actorID else { throw DinnerPlanningError.operationConflict }
            guard workspace.shops[index].revisions.contains(where: { $0.id == receipt.revisionID }) else { throw DinnerPlanningError.invalid("receiptRevision") }
            return receipt
        }
        let (changes, rows) = try prepare(plan, operation: proposal.id, workspace: workspace, recoveredMeals: recoveredMeals, access: access, at: now)
        guard changes == proposal.changes, proposal.proposedRevisionID == identity(proposal.id, source: access.shopID, member: proposal.id, kind: "revision")
        else { throw DinnerPlanningError.stalePreview }
        var ledger = workspace.shops[index], state = workspace.dinnerPlanning
        let receipt = try DinnerPlanningEngine.applyValidated(proposal, ledger: &ledger, state: &state, access: access, phase: phase, at: now, staples: rows, weeklyPackSelections: workspace.packSelections)
        workspace.shops[index] = ledger; workspace.dinnerPlanning = state
        return receipt
    }
}
