import Foundation

/// Plans future portions. An applied week adds the two cook occurrences and their
/// grocery demand; only a separate cook completion can create physical stock.
public struct BatchCookingWeek: Codable, Equatable, Sendable {
    public struct Session: Codable, Equatable, Sendable {
        public let offset: Int
        public let acceptedID: UUID
        public let lunchGroupID: UUID
        public init(offset: Int, acceptedID: UUID, lunchGroupID: UUID = UUID()) {
            self.offset = offset; self.acceptedID = acceptedID; self.lunchGroupID = lunchGroupID
        }
    }

    public struct Day: Codable, Equatable, Sendable {
        public let diners: Int
        public let lunches: Int
        /// Whole dinner portions already reserved and physically backed on this date.
        public let covered: Int
        public init(diners: Int, lunches: Int, covered: Int = 0) {
            self.diners = diners; self.lunches = lunches; self.covered = covered
        }
    }

    public let start: MealDay
    public let days: [Day]
    public let sessions: [Session]
    public let lunchLabel: String

    public init(start: MealDay, days: [Day], sessions: [Session], lunchLabel: String) throws {
        self.start = start; self.days = days; self.sessions = sessions; self.lunchLabel = lunchLabel
        try validate()
    }

    public func date(_ offset: Int) throws -> MealDay {
        guard (0..<7).contains(offset) else { throw DinnerPlanningError.invalid("batchDay") }
        return try dinnerDay(start, adding: offset)
    }

    private func validate() throws {
        try start.validate(); _ = try date(6)
        try dinnerText(lunchLabel)
        guard days.count == 7, sessions.count == 2, sessions[0].offset < sessions[1].offset,
              sessions.allSatisfy({ (0..<7).contains($0.offset) }),
              sessions[0].lunchGroupID != sessions[1].lunchGroupID,
              days.allSatisfy({ (0...100).contains($0.diners) && (0...100).contains($0.lunches) && (0...$0.diners).contains($0.covered) })
        else { throw DinnerPlanningError.invalid("batchWeek") }
    }

    public func sessionIndex(on offset: Int) -> Int? {
        sessions.lastIndex { $0.offset <= offset }
    }

    public func target(for index: Int) -> Int {
        days.enumerated().filter { sessionIndex(on: $0.offset) == index }.reduce(0) { sum, row in
            sum + row.element.diners - row.element.covered + row.element.lunches
        }
    }

    /// A yield shortfall protects promised lunches first, then covers eating dates in order.
    /// This calculation never changes a reservation or implies an unmeasured batch exists.
    public func shortfalls(actual: [Int?], currentCovered: [Int]? = nil) throws -> [Day] {
        try validate()
        let covered = currentCovered ?? days.map(\.covered)
        guard actual.count == 2, actual.allSatisfy({ $0.map { (0...100_000).contains($0) } ?? true }),
              covered.count == 7, covered.allSatisfy({ (0...100).contains($0) }) else { throw DinnerPlanningError.invalid("batchYield") }
        var remaining = sessions.indices.map { actual[$0] ?? target(for: $0) }
        var lunchGaps = Array(repeating: 0, count: 7)
        for (i, day) in days.enumerated() {
            guard let session = sessionIndex(on: i) else { lunchGaps[i] = day.lunches; continue }
            let taken = min(remaining[session], day.lunches)
            remaining[session] -= taken; lunchGaps[i] = day.lunches - taken
        }
        return days.enumerated().map { i, day in
            let need = max(0, day.diners - covered[i])
            guard let session = sessionIndex(on: i) else { return Day(diners: need, lunches: lunchGaps[i]) }
            let taken = min(remaining[session], need)
            remaining[session] -= taken
            return Day(diners: need - taken, lunches: lunchGaps[i])
        }
    }

    public struct MeasuredYield: Sendable {
        public enum Hold: Sendable {
            case lunch(Rational)
            case dinner(Rational, offset: Int?)
            case other(Rational)
        }
        public let made: Rational
        public let holds: [Hold]
        public init(made: Rational, holds: [Hold]) { self.made = made; self.holds = holds }
    }

    public struct Coverage: Sendable {
        public let gaps: [Day]
        public let covered: [Int]
    }

    /// Previously reserved physical dinners can cross cooking sessions. Debit their
    /// producing batch once and credit only their confirmed day; keep outside holds intact.
    public func reconcile(yields: [MeasuredYield?], otherDinnerCoverage: [Int]) throws -> Coverage {
        try validate()
        guard yields.count == 2, otherDinnerCoverage.count == 7,
              otherDinnerCoverage.allSatisfy({ (0...100).contains($0) }) else { throw DinnerPlanningError.invalid("batchYield") }
        var covered = otherDinnerCoverage
        var available: [Int?] = [nil, nil]
        for (session, yield) in yields.enumerated() {
            guard let yield else { continue }
            var remaining = yield.made
            var reservedLunch = Rational.zero
            for hold in yield.holds {
                switch hold {
                case .lunch(let amount):
                    reservedLunch = try reservedLunch.adding(amount)
                case .dinner(let amount, let offset):
                    remaining = try remaining.subtracting(amount)
                    if let offset {
                        guard days.indices.contains(offset) else { throw DinnerPlanningError.invalid("batchDay") }
                        covered[offset] = min(100, covered[offset] + Int(min(100, amount.numerator / amount.denominator)))
                    }
                case .other(let amount):
                    remaining = try remaining.subtracting(amount)
                }
            }
            guard remaining >= reservedLunch else { throw DinnerPlanningError.reviewRequired("batchYield") }
            let lunchCount = days.indices.filter { sessionIndex(on: $0) == session }.reduce(0) { $0 + days[$1].lunches }
            let extra = try reservedLunch.subtractingClampedToZero(Rational(Int64(lunchCount)))
            let flexible = try remaining.subtracting(extra)
            available[session] = Int(min(100_000, flexible.numerator / flexible.denominator))
        }
        return Coverage(gaps: try shortfalls(actual: available, currentCovered: covered), covered: covered)
    }

    private func scaled(_ original: MealTemplate, for index: Int) throws -> MealTemplate {
        let target = target(for: index)
        guard target > 0, !original.ingredients.isEmpty,
              original.ingredients.allSatisfy({ $0.quantity != nil || $0.checkedWithoutAmount == true }),
              original.servingGroups.isEmpty else { throw DinnerPlanningError.reviewRequired("batchRecipe") }
        let servings = try Rational(Int64(target))
        let factor = try servings.divided(by: original.servings)
        var result = original
        result.servings = servings
        for i in result.ingredients.indices {
            if let source = result.ingredients[i].quantity {
                let amount = try source.amount.multiplied(by: factor)
                if factor != .one {
                    // A source label such as “two 400 g cans” belongs to the original yield.
                    // Checkout must not infer those old pack counts for the new batch.
                    result.ingredients[i].originalWording = nil
                }
                result.ingredients[i].quantity = Quantity(amount: amount, unit: source.unit,
                    originalLiteral: amount.description, confirmedConversion: source.confirmedConversion)
            }
        }
        let lunches = days.enumerated().filter { sessionIndex(on: $0.offset) == index }.reduce(0) { $0 + $1.element.lunches }
        if lunches > 0 {
            result.servingGroups = [ServingGroup(id: sessions[index].lunchGroupID, name: lunchLabel,
                                                servings: try Rational(Int64(lunches)), isProtected: true)]
        }
        return result
    }

    public func preview(ledger: ShoppingLedger, state: DinnerPlanningState, access: DinnerAccessContext,
                        phase: BasketPhase, at now: Date) throws -> DinnerPreview {
        try validate()
        guard case .local = access.scope, access.hasPaidTools, phase == .draft else { throw DinnerPlanningError.forbidden }
        let changes = try sessions.enumerated().map { index, session -> DinnerLedgerChange in
            guard let recipe = state.acceptedDinners.first(where: { $0.id == session.acceptedID }) else {
                throw DinnerPlanningError.reviewRequired("batchRecipe")
            }
            return .choose(PlannedDinner(acceptedDinnerID: recipe.id, template: try scaled(recipe.template, for: index),
                                         day: try date(session.offset)))
        }
        return try DinnerPlanningEngine.makePreview(id: UUID(), changes: changes, tool: .rotation, ledger: ledger, state: state,
            access: access, phase: phase, at: now, isolated: false, quoteSelection: nil, repeatWeek: nil, staples: [],
            revisionID: UUID(), batchWeek: self)
    }

    func validate(proposal: DinnerProposal) throws {
        try validate()
        guard proposal.tool == .rotation, proposal.namespace.hasPrefix("local:"), !proposal.isIsolatedPreview,
              proposal.repeatWeek == nil, proposal.swapOriginalID == nil, proposal.changes.count == 2 else {
            throw DinnerPlanningError.invalid("batchProposal")
        }
        for (index, change) in proposal.changes.enumerated() {
            guard case .choose(let planned) = change, planned.acceptedDinnerID == sessions[index].acceptedID,
                  planned.day == (try date(sessions[index].offset)), planned.plannedServings == nil,
                  planned.template.servings == (try Rational(Int64(target(for: index)))),
                  planned.reviewedGroceryLines == nil, planned.lunchHold == nil, planned.pantryProducts == nil else {
                throw DinnerPlanningError.invalid("batchSession")
            }
        }
    }

    func validateSources(proposal: DinnerProposal, ledger: ShoppingLedger, state: DinnerPlanningState,
                         access: DinnerAccessContext) throws {
        let activeDays = try Set(days.indices.filter { days[$0].diners > days[$0].covered || days[$0].lunches > 0 }.map { try date($0).iso8601 })
        for receipt in state.applyReceipts where receipt.proposal.shopID == ledger.id {
            guard let saved = receipt.proposal.batchWeek else { continue }
            let earlierDays = try Set(saved.days.indices.filter {
                saved.days[$0].diners > saved.days[$0].covered || saved.days[$0].lunches > 0
            }.map { try saved.date($0).iso8601 })
            guard saved.start != start, activeDays.isDisjoint(with: earlierDays) else { throw DinnerPlanningError.stalePreview }
        }
        guard case .local = access.scope, access.hasPaidTools, start.timeZoneIdentifier == ledger.basis.timeZoneIdentifier else {
            throw DinnerPlanningError.stalePreview
        }
        for (index, session) in sessions.enumerated() {
            guard let recipe = state.acceptedDinners.first(where: { $0.id == session.acceptedID }),
                  case .choose(let planned) = proposal.changes[index],
                  planned.template == (try scaled(recipe.template, for: index)) else { throw DinnerPlanningError.stalePreview }
        }
        for (index, demand) in days.enumerated() where demand.diners > demand.covered || demand.lunches > 0 {
            let day = try date(index)
            guard !ledger.mealOccurrences.contains(where: { $0.removedAt == nil && !$0.isHidden && $0.scheduledDay?.hasSameCivilDate(as: day) == true }),
                  !state.weekNotes.contains(where: { $0.shopID == ledger.id && $0.kind == .away && $0.day.hasSameCivilDate(as: day) })
            else { throw DinnerPlanningError.reviewRequired("openNights") }
        }
    }
}
