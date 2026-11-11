import Foundation

public enum DinnerPlanningError: Error, Equatable, Sendable {
    case invalid(String), notFound(UUID), forbidden, paidAccessRequired, stalePreview
    case operationConflict, lockedBasket, reviewRequired(String)
}

/// This is a runtime binding supplied by the authenticated coordinator, never archive data.
/// The service must independently authorize/commit shared commands; an offline device may
/// save a shared proposal but cannot turn it into a service-confirmed basket revision.
public struct DinnerAccessContext: Equatable, Sendable {
    public enum Scope: Equatable, Sendable { case local(workspaceID: UUID), household(id: String) }
    public let scope: Scope
    public let actorID: String
    public let shopID: UUID
    public let assignedShopperID: String
    public let canPlan: Bool
    public let canReadBudget: Bool
    public let hasPaidTools: Bool
    public let roleRevision: Int
    public let verifiedAt: Date
    public let validUntil: Date
    public let sharedCommitAuthorized: Bool
    public init(scope: Scope, actorID: String, shopID: UUID, assignedShopperID: String,
                canPlan: Bool, canReadBudget: Bool, hasPaidTools: Bool, roleRevision: Int,
                verifiedAt: Date, validUntil: Date, sharedCommitAuthorized: Bool = false) {
        self.scope = scope; self.actorID = actorID; self.shopID = shopID
        self.assignedShopperID = assignedShopperID; self.canPlan = canPlan
        self.canReadBudget = canReadBudget; self.hasPaidTools = hasPaidTools
        self.roleRevision = roleRevision; self.verifiedAt = verifiedAt; self.validUntil = validUntil
        self.sharedCommitAuthorized = sharedCommitAuthorized
    }
    public func validate(shopID: UUID, at now: Date, applying: Bool = false, budget: Bool = false) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite, verifiedAt.timeIntervalSinceReferenceDate.isFinite,
              validUntil.timeIntervalSinceReferenceDate.isFinite, verifiedAt <= now, now < validUntil,
              self.shopID == shopID, !actorID.isEmpty, !assignedShopperID.isEmpty, canPlan, roleRevision >= 0,
              !budget || canReadBudget else { throw DinnerPlanningError.forbidden }
        if case .household(let id) = scope {
            guard !id.isEmpty, !applying || sharedCommitAuthorized else { throw DinnerPlanningError.forbidden }
        }
        if applying && actorID != assignedShopperID { throw DinnerPlanningError.forbidden }
    }
    var namespace: String {
        switch scope { case .local(let id): return "local:\(id.uuidString)"; case .household(let id): return "household:\(id)" }
    }
}

public enum DinnerPlanningTool: String, Codable, Sendable {
    case manual, reusableDinner, rotation, pairing, guests, recovery, quoteAdoption
    public var requiresPaidAccess: Bool { [.rotation, .pairing, .guests, .recovery].contains(self) }
}

public struct AcceptedDinner: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let template: MealTemplate
    public let acceptedAt: Date
    public let sourceIdeaID: UUID?
    public let acceptedFallback: Bool
    public init(id: UUID, template: MealTemplate, acceptedAt: Date, sourceIdeaID: UUID? = nil, acceptedFallback: Bool = false) {
        self.id = id; self.template = template; self.acceptedAt = acceptedAt
        self.sourceIdeaID = sourceIdeaID; self.acceptedFallback = acceptedFallback
    }
}

public struct DinnerRotationEntry: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let acceptedDinnerID: UUID
    /// Offset from the explicitly selected local week start, not a weekday number.
    public let dayOffset: Int?
    public let pinned: Bool
    public init(id: UUID = UUID(), acceptedDinnerID: UUID, dayOffset: Int?, pinned: Bool = false) {
        self.id = id; self.acceptedDinnerID = acceptedDinnerID; self.dayOffset = dayOffset; self.pinned = pinned
    }
}
public struct DinnerRotation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let revision: Int
    public let title: String
    public let entries: [DinnerRotationEntry]
    public init(id: UUID = UUID(), revision: Int = 0, title: String, entries: [DinnerRotationEntry]) {
        self.id = id; self.revision = revision; self.title = title; self.entries = entries
    }
}

/// Each output identity is reserved while preparing the proposal, then reused on Apply/retry.
public struct PlannedDinner: Codable, Equatable, Sendable {
    public let acceptedDinnerID: UUID?
    public let template: MealTemplate
    public let occurrenceID: UUID
    public let lineIDs: [UUID]
    public let contributionIDs: [UUID]
    public let day: MealDay?
    public init(acceptedDinnerID: UUID? = nil, template: MealTemplate, occurrenceID: UUID = UUID(),
                lineIDs: [UUID]? = nil, contributionIDs: [UUID]? = nil, day: MealDay? = nil) {
        self.acceptedDinnerID = acceptedDinnerID; self.template = template; self.occurrenceID = occurrenceID
        self.lineIDs = lineIDs ?? template.ingredients.map { _ in UUID() }
        self.contributionIDs = contributionIDs ?? template.ingredients.map { _ in UUID() }; self.day = day
    }
    func validate() throws {
        try template.validate(); try day?.validate()
        guard lineIDs.count == template.ingredients.count, contributionIDs.count == lineIDs.count else { throw DinnerPlanningError.invalid("plannedIDs") }
        try dinnerUnique(lineIDs + contributionIDs + [occurrenceID])
    }
}

public struct DinnerQuantityEdit: Codable, Equatable, Sendable {
    public let contributionID: UUID
    public let quantity: Quantity?
    public init(contributionID: UUID, quantity: Quantity?) { self.contributionID = contributionID; self.quantity = quantity }
}
public struct DinnerAdjustment: Codable, Equatable, Sendable {
    public let occurrenceID: UUID
    public let servings: Rational
    public let groups: [ServingGroup]
    public let quantities: [DinnerQuantityEdit]
    /// Explicit resulting allocations for a manual edit. Absent in older proposals.
    public let portionBindings: [DinnerPortionBinding]?
    public init(occurrenceID: UUID, servings: Rational, groups: [ServingGroup], quantities: [DinnerQuantityEdit],
                portionBindings: [DinnerPortionBinding]? = nil) {
        self.occurrenceID = occurrenceID; self.servings = servings; self.groups = groups; self.quantities = quantities
        self.portionBindings = portionBindings
    }
}
public struct DinnerReservation: Codable, Equatable, Sendable {
    public let contributionID: UUID
    public let lineID: UUID
    public let name: String
    public let quantity: Quantity
    public let purpose: String
    public let day: MealDay?
    public let withinContributionID: UUID?
    public let allocationID: UUID
    public init(contributionID: UUID = UUID(), lineID: UUID = UUID(), name: String, quantity: Quantity,
                purpose: String, day: MealDay?, withinContributionID: UUID? = nil, allocationID: UUID = UUID()) {
        self.contributionID = contributionID; self.lineID = lineID; self.name = name; self.quantity = quantity
        self.purpose = purpose; self.day = day; self.withinContributionID = withinContributionID; self.allocationID = allocationID
    }
}
public enum DinnerLedgerChange: Codable, Equatable, Sendable {
    case choose(PlannedDinner)
    case move(occurrenceID: UUID, day: MealDay?)
    case adjust(DinnerAdjustment)
    case remove(occurrenceID: UUID)
    case reserve(DinnerReservation)
    case adoptBasis(ShopBasis)
    var isCalendarOnly: Bool { if case .move = self { return true }; return false }
}

/// Reviewed ingredient amounts for individual groups. The sum of bindings must equal
/// the current ingredient contribution. A protected binding never scales with guests.
public struct DinnerPortionBinding: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let occurrenceID: UUID
    public let contributionID: UUID
    public let groupID: UUID
    public let quantity: Quantity
    public let servings: Rational
    public init(id: UUID = UUID(), occurrenceID: UUID, contributionID: UUID, groupID: UUID, quantity: Quantity, servings: Rational) {
        self.id = id; self.occurrenceID = occurrenceID; self.contributionID = contributionID
        self.groupID = groupID; self.quantity = quantity; self.servings = servings
    }
}
public struct DinnerProtectedDay: Codable, Equatable, Sendable {
    public let shopID: UUID
    public let contributionID: UUID
    public let day: MealDay?
    public init(shopID: UUID, contributionID: UUID, day: MealDay?) { self.shopID = shopID; self.contributionID = contributionID; self.day = day }
}
public struct DinnerWeekNote: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable { case away, guests, side, carryoverReview }
    public let id: UUID
    public let shopID: UUID
    public let day: MealDay
    public let kind: Kind
    public let text: String
    public init(id: UUID = UUID(), shopID: UUID, day: MealDay, kind: Kind, text: String) {
        self.id = id; self.shopID = shopID; self.day = day; self.kind = kind; self.text = text
    }
}
public struct DinnerQuoteSelection: Codable, Equatable, Sendable {
    public let pairID: UUID
    public let optionID: UUID
    public init(pairID: UUID, optionID: UUID) { self.pairID = pairID; self.optionID = optionID }
}
public struct DinnerProposal: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let shopID: UUID
    public let baseRevisionID: UUID
    public let basisRevision: Int
    public let planningRevisionID: UUID
    public let proposedRevisionID: UUID
    public let authorID: String
    public let namespace: String
    public let tool: DinnerPlanningTool
    public let changes: [DinnerLedgerChange]
    public let createdAt: Date
    public let isIsolatedPreview: Bool
    public let quoteSelection: DinnerQuoteSelection?
}
public struct DinnerApplyReceipt: Codable, Equatable, Sendable, Identifiable {
    public let proposal: DinnerProposal
    public let appliedBy: String
    public let appliedAt: Date
    public let revisionID: UUID
    public var id: UUID { proposal.id }
}
public struct DinnerPreview: Equatable, Sendable {
    public let proposal: DinnerProposal
    // Internal candidate supports validation/tests without exposing a private cap to a planner view.
    let projectedLedger: ShoppingLedger
    public let projectedMeals: [MealOccurrence]
    public let projectedContributions: [LedgerContribution]
    public let budgetBasis: ShopBasis?
    public let changedContributionIDs: [UUID]
    public let changedOccurrenceIDs: [UUID]
    public let needsPurchaseAmendment: Bool
}
public struct DinnerMealWeek: Equatable, Sendable {
    public struct Day: Equatable, Sendable {
        public let day: MealDay
        public let meals: [MealOccurrence]
        public let protectedContributionIDs: [UUID]
        public let notes: [DinnerWeekNote]
    }
    public let days: [Day]
    public let unscheduled: [MealOccurrence]
}

public struct DinnerIdeaDraft: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let requestID: UUID
    public let catalogVersion: String
    public var template: MealTemplate
    public var assumptions: [String]
    public let hardExclusions: [String]
    public var yieldConfirmed: Bool
    public var availabilityConfirmed: Bool
    public var supplyEvidence: [DinnerIdeaFoodEvidence]? = nil
    public let createdAt: Date
    public init(id: UUID = UUID(), requestID: UUID, catalogVersion: String, template: MealTemplate,
                assumptions: [String] = [], hardExclusions: [String] = [], yieldConfirmed: Bool = false, availabilityConfirmed: Bool = false, createdAt: Date) {
        self.id = id; self.requestID = requestID; self.catalogVersion = catalogVersion; self.template = template
        self.assumptions = assumptions; self.hardExclusions = hardExclusions; self.yieldConfirmed = yieldConfirmed
        self.availabilityConfirmed = availabilityConfirmed; self.createdAt = createdAt
    }
}
public struct DinnerIdeaReview: Equatable, Sendable {
    public let canAccept: Bool
    public let canClaimCoverage: Bool
    public let issues: [String]
}

public struct DinnerPlanningState: Codable, Equatable, Sendable {
    public private(set) var revisionID: UUID
    public private(set) var acceptedDinners: [AcceptedDinner]
    public private(set) var freeReusableDinnerID: UUID?
    public private(set) var rotations: [DinnerRotation]
    public private(set) var portionBindings: [DinnerPortionBinding]
    public private(set) var protectedDays: [DinnerProtectedDay]
    public private(set) var weekNotes: [DinnerWeekNote]
    public private(set) var ideas: [DinnerIdeaDraft]
    public private(set) var proposals: [DinnerProposal]
    public private(set) var applyReceipts: [DinnerApplyReceipt]
    public private(set) var quotePairs: [TwoStoreQuotePair]
    public init() {
        revisionID = UUID(uuidString: "00000000-0000-0000-0000-000000000001")!; acceptedDinners = []; freeReusableDinnerID = nil; rotations = []
        portionBindings = []; protectedDays = []; weekNotes = []; ideas = []; proposals = []; applyReceipts = []; quotePairs = []
    }
    public func validate() throws {
        guard acceptedDinners.count <= 500, rotations.count <= 100, portionBindings.count <= 20_000,
              protectedDays.count <= 10_000, weekNotes.count <= 2_000, ideas.count <= 500,
              proposals.count <= 2_000, applyReceipts.count <= 10_000, quotePairs.count <= 500 else { throw DinnerPlanningError.invalid("stateSize") }
        try dinnerUnique(acceptedDinners.map(\.id)); try dinnerUnique(rotations.map(\.id)); try dinnerUnique(portionBindings.map(\.id))
        try dinnerUnique(weekNotes.map(\.id)); try dinnerUnique(ideas.map(\.id)); try dinnerUnique(ideas.map(\.requestID))
        try dinnerUnique(proposals.map(\.id)); try dinnerUnique(applyReceipts.map(\.id)); try dinnerUnique(quotePairs.map(\.id))
        if let id = freeReusableDinnerID, !acceptedDinners.contains(where: { $0.id == id }) { throw DinnerPlanningError.notFound(id) }
        for dinner in acceptedDinners { try dinner.template.validate(); try dinnerDate(dinner.acceptedAt) }
        var versions = Set<String>()
        for dinner in acceptedDinners {
            guard versions.insert("\(dinner.template.id):\(dinner.template.revision)").inserted else { throw DinnerPlanningError.invalid("duplicateTemplateVersion") }
        }
        for rotation in rotations {
            try dinnerText(rotation.title); try dinnerUnique(rotation.entries.map(\.id))
            guard rotation.revision >= 0, !rotation.entries.isEmpty, rotation.entries.count <= 100 else { throw DinnerPlanningError.invalid("rotation") }
            for entry in rotation.entries {
                guard acceptedDinners.contains(where: { $0.id == entry.acceptedDinnerID }), entry.dayOffset.map({ (0...6).contains($0) }) ?? true
                else { throw DinnerPlanningError.invalid("rotationEntry") }
            }
        }
        for binding in portionBindings { try binding.quantity.validate(); guard binding.servings > .zero else { throw DinnerPlanningError.invalid("portionBinding") } }
        for date in protectedDays { try date.day?.validate() }
        guard Set(protectedDays.map { "\($0.shopID):\($0.contributionID)" }).count == protectedDays.count else { throw DinnerPlanningError.invalid("protectedDay") }
        for note in weekNotes { try note.day.validate(); try dinnerText(note.text) }
        for idea in ideas { try DinnerIdeaEngine.validateDraft(idea) }
        for proposal in proposals { try Self.validate(proposal) }
        for receipt in applyReceipts {
            try Self.validate(receipt.proposal); try dinnerText(receipt.appliedBy); try dinnerDate(receipt.appliedAt)
            guard receipt.revisionID == receipt.proposal.proposedRevisionID else { throw DinnerPlanningError.invalid("receipt") }
        }
        for pair in quotePairs { try pair.validate() }
    }
    static func validate(_ proposal: DinnerProposal) throws {
        try dinnerDate(proposal.createdAt); try dinnerText(proposal.authorID); try dinnerText(proposal.namespace)
        guard proposal.basisRevision >= 0, !proposal.changes.isEmpty, proposal.changes.count <= 500 else { throw DinnerPlanningError.invalid("proposal") }
        if proposal.tool == .quoteAdoption {
            guard proposal.changes.count == 1, proposal.quoteSelection != nil,
                  case .adoptBasis = proposal.changes[0] else { throw DinnerPlanningError.invalid("quoteAdoption") }
        } else {
            guard proposal.quoteSelection == nil, !proposal.changes.contains(where: { if case .adoptBasis = $0 { return true }; return false })
            else { throw DinnerPlanningError.invalid("quoteAdoptionTool") }
        }
        for change in proposal.changes {
            switch change {
            case .choose(let dinner): try dinner.validate()
            case .move(_, let day): try day?.validate()
            case .adjust(let adjustment):
                guard adjustment.servings > .zero, adjustment.groups.count <= 100, adjustment.quantities.count <= 200 else { throw DinnerPlanningError.invalid("adjustment") }
                try dinnerUnique(adjustment.groups.map(\.id)); try dinnerUnique(adjustment.quantities.map(\.contributionID))
                for group in adjustment.groups { try dinnerText(group.name); guard group.servings > .zero else { throw DinnerPlanningError.invalid("group") } }
                for quantity in adjustment.quantities { try quantity.quantity?.validate() }
                if let bindings = adjustment.portionBindings {
                    guard proposal.tool == .manual, !bindings.isEmpty, bindings.count <= 20_000 else { throw DinnerPlanningError.invalid("portionBindings") }
                    try dinnerUnique(bindings.map(\.id))
                    for binding in bindings {
                        guard binding.occurrenceID == adjustment.occurrenceID, binding.servings > .zero,
                              binding.quantity.amount >= .zero else { throw DinnerPlanningError.invalid("portionBinding") }
                        try binding.quantity.validate()
                    }
                }
            case .remove: break
            case .reserve(let reservation): try dinnerText(reservation.name); try dinnerText(reservation.purpose); try reservation.quantity.validate(); try reservation.day?.validate()
            case .adoptBasis(let basis): try basis.validate()
            }
        }
    }
    public func validate(shops: [ShoppingLedger]) throws {
        try validate()
        for binding in portionBindings {
            guard let meal = shops.flatMap(\.mealOccurrences).first(where: { $0.id == binding.occurrenceID }),
                  meal.ingredientContributionIDs.contains(binding.contributionID), meal.servingGroups.contains(where: { $0.id == binding.groupID })
            else { throw DinnerPlanningError.invalid("bindingReference") }
        }
        for protected in protectedDays {
            guard let shop = shops.first(where: { $0.id == protected.shopID }),
                  shop.contributions.contains(where: { $0.id == protected.contributionID && $0.source.isProtected })
            else { throw DinnerPlanningError.invalid("protectedReference") }
        }
        for note in weekNotes where !shops.contains(where: { $0.id == note.shopID }) { throw DinnerPlanningError.notFound(note.shopID) }
        for proposal in proposals where !shops.contains(where: { $0.id == proposal.shopID }) { throw DinnerPlanningError.notFound(proposal.shopID) }
        for receipt in applyReceipts {
            guard let shop = shops.first(where: { $0.id == receipt.proposal.shopID }), shop.revisions.contains(where: { $0.id == receipt.revisionID })
            else { throw DinnerPlanningError.invalid("receiptRevision") }
        }
    }
    private enum CodingKeys: String, CodingKey {
        case revisionID, acceptedDinners, freeReusableDinnerID, rotations, portionBindings, protectedDays, weekNotes, ideas, proposals, applyReceipts, quotePairs
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        revisionID = try c.decode(UUID.self, forKey: .revisionID)
        acceptedDinners = try c.decode([AcceptedDinner].self, forKey: .acceptedDinners)
        freeReusableDinnerID = try c.decodeIfPresent(UUID.self, forKey: .freeReusableDinnerID)
        rotations = try c.decode([DinnerRotation].self, forKey: .rotations)
        portionBindings = try c.decode([DinnerPortionBinding].self, forKey: .portionBindings)
        protectedDays = try c.decode([DinnerProtectedDay].self, forKey: .protectedDays)
        weekNotes = try c.decode([DinnerWeekNote].self, forKey: .weekNotes)
        ideas = try c.decode([DinnerIdeaDraft].self, forKey: .ideas)
        proposals = try c.decode([DinnerProposal].self, forKey: .proposals)
        applyReceipts = try c.decode([DinnerApplyReceipt].self, forKey: .applyReceipts)
        quotePairs = try c.decode([TwoStoreQuotePair].self, forKey: .quotePairs)
        try validate()
    }
    public mutating func accept(_ dinner: AcceptedDinner, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: access.shopID, at: now)
        if let old = acceptedDinners.first(where: { $0.id == dinner.id }) { guard old == dinner else { throw DinnerPlanningError.operationConflict }; return }
        var next = self; next.acceptedDinners.append(dinner)
        if next.freeReusableDinnerID == nil { next.freeReusableDinnerID = dinner.id }
        try next.validate(); next.revisionID = UUID(); self = next
    }
    public mutating func selectFreeReusableDinner(_ id: UUID, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: access.shopID, at: now)
        guard acceptedDinners.contains(where: { $0.id == id }) else { throw DinnerPlanningError.notFound(id) }
        if freeReusableDinnerID != id { freeReusableDinnerID = id; revisionID = UUID() }
    }
    public mutating func saveRotation(_ rotation: DinnerRotation, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: access.shopID, at: now); guard access.hasPaidTools else { throw DinnerPlanningError.paidAccessRequired }
        var next = self
        if let index = next.rotations.firstIndex(where: { $0.id == rotation.id }) {
            if next.rotations[index] == rotation { return }
            let (expected, overflow) = next.rotations[index].revision.addingReportingOverflow(1)
            guard !overflow, rotation.revision == expected else { throw DinnerPlanningError.stalePreview }
            next.rotations[index] = rotation
        } else { guard rotation.revision == 0 else { throw DinnerPlanningError.stalePreview }; next.rotations.append(rotation) }
        try next.validate(); next.revisionID = UUID(); self = next
    }
    public mutating func setPortionBindings(_ bindings: [DinnerPortionBinding], for occurrenceID: UUID,
                                            ledger: ShoppingLedger, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: ledger.id, at: now)
        guard bindings.allSatisfy({ $0.occurrenceID == occurrenceID }) else { throw DinnerPlanningError.invalid("bindingOccurrence") }
        var next = self; next.portionBindings.removeAll { $0.occurrenceID == occurrenceID }; next.portionBindings += bindings
        try next.validate(); try DinnerPlanningEngine.validateBindings(bindings, occurrenceID: occurrenceID, ledger: ledger)
        next.revisionID = UUID(); self = next
    }
    public mutating func saveIdea(_ draft: DinnerIdeaDraft, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: access.shopID, at: now); try DinnerIdeaEngine.validateDraft(draft)
        if let rows = draft.supplyEvidence, !rows.isEmpty {
            guard case .local(let workspaceID) = access.scope,
                  rows.allSatisfy({ $0.workspaceID == workspaceID && $0.shopID == access.shopID &&
                      ($0.pack?.price == nil || access.canReadBudget) }) else { throw DinnerPlanningError.forbidden }
        }
        var next = self
        if let index = next.ideas.firstIndex(where: { $0.requestID == draft.requestID }) {
            guard next.ideas[index].id == draft.id, next.ideas[index].createdAt == draft.createdAt,
                  next.ideas[index].catalogVersion == draft.catalogVersion, next.ideas[index].hardExclusions == draft.hardExclusions else { throw DinnerPlanningError.operationConflict }
            if next.ideas[index] == draft { return }; next.ideas[index] = draft
        } else { next.ideas.append(draft) }
        try next.validate(); next.revisionID = UUID(); self = next
    }
    public mutating func acceptIdea(_ draft: DinnerIdeaDraft, acceptedID: UUID, access: DinnerAccessContext, at now: Date) throws -> AcceptedDinner {
        try access.validate(shopID: access.shopID, at: now)
        var acceptedTemplate = draft.template
        acceptedTemplate.exclusions = Array(Set(acceptedTemplate.exclusions + draft.hardExclusions)).sorted()
        if let old = acceptedDinners.first(where: { $0.sourceIdeaID == draft.id }) {
            guard old.id == acceptedID, old.template == acceptedTemplate else { throw DinnerPlanningError.operationConflict }; return old
        }
        guard DinnerIdeaEngine.review(draft).canAccept else { throw DinnerPlanningError.reviewRequired("idea") }
        let dinner = AcceptedDinner(id: acceptedID, template: acceptedTemplate, acceptedAt: now, sourceIdeaID: draft.id)
        var next = self; try next.saveIdea(draft, access: access, at: now); try next.accept(dinner, access: access, at: now); self = next
        return dinner
    }
    public mutating func recordWeekNote(_ note: DinnerWeekNote, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: note.shopID, at: now)
        var next = self
        if let i = next.weekNotes.firstIndex(where: { $0.id == note.id }) { next.weekNotes[i] = note } else { next.weekNotes.append(note) }
        try next.validate(); next.revisionID = UUID(); self = next
    }
    public mutating func saveProposal(_ proposal: DinnerProposal, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: proposal.shopID, at: now)
        guard proposal.namespace == access.namespace, proposal.authorID == access.actorID else { throw DinnerPlanningError.forbidden }
        try Self.validate(proposal)
        if let old = proposals.first(where: { $0.id == proposal.id }) { guard old == proposal else { throw DinnerPlanningError.operationConflict }; return }
        var next = self; next.proposals.append(proposal); try next.validate(); self = next
        // Saving an unchanged proposal does not stale its own reviewed planning basis.
    }
    public mutating func saveQuotePair(_ pair: TwoStoreQuotePair, access: DinnerAccessContext, at now: Date) throws {
        try access.validate(shopID: pair.shopID, at: now, budget: true); try pair.validate()
        var next = self
        if let i = next.quotePairs.firstIndex(where: { $0.id == pair.id }) { guard next.quotePairs[i] == pair else { throw DinnerPlanningError.operationConflict }; return }
        next.quotePairs.append(pair); try next.validate(); self = next
    }
    mutating func applied(_ receipt: DinnerApplyReceipt) throws {
        applyReceipts.append(receipt)
        for change in receipt.proposal.changes {
            if case .reserve(let reservation) = change {
                protectedDays.append(DinnerProtectedDay(shopID: receipt.proposal.shopID, contributionID: reservation.contributionID, day: reservation.day))
            }
            if case .adjust(let adjustment) = change {
                if let bindings = adjustment.portionBindings {
                    portionBindings.removeAll { $0.occurrenceID == adjustment.occurrenceID }
                    portionBindings += bindings
                } else if receipt.proposal.tool == .guests {
                    portionBindings = try portionBindings.map { binding in
                        guard binding.occurrenceID == adjustment.occurrenceID,
                              let group = adjustment.groups.first(where: { $0.id == binding.groupID }) else { return binding }
                        let amount = try binding.quantity.amount.multiplied(by: group.servings.divided(by: binding.servings))
                        return DinnerPortionBinding(id: binding.id, occurrenceID: binding.occurrenceID,
                            contributionID: binding.contributionID, groupID: binding.groupID,
                            quantity: Quantity(amount: amount, unit: binding.quantity.unit, originalLiteral: binding.quantity.originalLiteral,
                                confirmedConversion: binding.quantity.confirmedConversion), servings: group.servings)
                    }
                } else if receipt.proposal.tool == .pairing {
                    let retained = Set(adjustment.groups.map(\.id))
                    portionBindings.removeAll { $0.occurrenceID == adjustment.occurrenceID && !retained.contains($0.groupID) }
                } else { portionBindings.removeAll { $0.occurrenceID == adjustment.occurrenceID } }
            }
        }
        revisionID = UUID()
    }
}

public enum DinnerPlanningEngine {
    public static func preview(id: UUID = UUID(), changes: [DinnerLedgerChange], tool: DinnerPlanningTool,
                               ledger: ShoppingLedger, state: DinnerPlanningState, access: DinnerAccessContext,
                               phase: BasketPhase, at now: Date, isolated: Bool = false, quoteSelection: DinnerQuoteSelection? = nil) throws -> DinnerPreview {
        try access.validate(shopID: ledger.id, at: now, budget: tool == .quoteAdoption)
        if tool.requiresPaidAccess && !access.hasPaidTools && !isolated { throw DinnerPlanningError.paidAccessRequired }
        try state.validate(); try ledger.validate()
        let proposal = DinnerProposal(id: id, shopID: ledger.id, baseRevisionID: ledger.revisionID,
            basisRevision: ledger.basisRevision, planningRevisionID: state.revisionID, proposedRevisionID: UUID(),
            authorID: access.actorID, namespace: access.namespace, tool: tool, changes: changes, createdAt: now, isIsolatedPreview: isolated, quoteSelection: quoteSelection)
        try DinnerPlanningState.validate(proposal)
        try validateChosen(proposal, state: state, access: access)
        try validateProtectedAdjustments(proposal, ledger: ledger, state: state)
        var projected = ledger; try projected.applyDinnerChanges(changes, expectedRevisionID: ledger.revisionID,
            revisionID: proposal.proposedRevisionID, operationID: proposal.id, at: now)
        try validateManualBindings(proposal, ledger: ledger, projected: projected, state: state)
        let changedSources = projected.contributions.filter { source in ledger.contributions.first(where: { $0.id == source.id }) != source }.map(\.id)
        let changedMeals = projected.mealOccurrences.filter { meal in ledger.mealOccurrences.first(where: { $0.id == meal.id }) != meal }.map(\.id)
        return DinnerPreview(proposal: proposal, projectedLedger: projected, projectedMeals: projected.mealOccurrences,
            projectedContributions: projected.contributions, budgetBasis: access.canReadBudget ? projected.basis : nil, changedContributionIDs: changedSources,
            changedOccurrenceIDs: changedMeals, needsPurchaseAmendment: phase != .draft && !changes.allSatisfy(\.isCalendarOnly))
    }
    static func validateChosen(_ proposal: DinnerProposal, state: DinnerPlanningState, access: DinnerAccessContext) throws {
        if let selection = proposal.quoteSelection {
            guard let pair = state.quotePairs.first(where: { $0.id == selection.pairID }),
                  pair.shopID == proposal.shopID, pair.baseRevisionID == proposal.baseRevisionID, pair.basisRevision == proposal.basisRevision,
                  pair.first.commitments == pair.second.commitments, pair.first.quote.scope == pair.second.quote.scope,
                  pair.first.singleStore, pair.second.singleStore, pair.first.quantitiesMatched, pair.second.quantitiesMatched,
                  let option = [pair.first, pair.second].first(where: { $0.id == selection.optionID }), option.available == true,
                  let basis = option.adoptionBasis, case .adoptBasis(let proposed) = proposal.changes[0] else { throw DinnerPlanningError.reviewRequired("quoteProof") }
            var expected = basis; expected.retailerPreview = nil
            guard proposed == expected else { throw DinnerPlanningError.reviewRequired("quoteBasis") }
        }
        let chosen = proposal.changes.compactMap { change -> PlannedDinner? in if case .choose(let meal) = change { return meal }; return nil }
        for meal in chosen {
            if let acceptedID = meal.acceptedDinnerID {
                guard state.acceptedDinners.contains(where: { $0.id == acceptedID && $0.template == meal.template }) else { throw DinnerPlanningError.reviewRequired("acceptedVersion") }
                if !access.hasPaidTools && !proposal.isIsolatedPreview {
                    guard chosen.count == 1, state.freeReusableDinnerID == acceptedID else { throw DinnerPlanningError.paidAccessRequired }
                }
            } else if proposal.tool != .manual { throw DinnerPlanningError.reviewRequired("acceptedDinner") }
        }
    }
    /// A reviewed replacement retains the original group, occurrence and grocery identities
    /// for every serving group except the one explicitly moved to another recipe.
    public static func removingServingGroup(_ groupID: UUID, from occurrenceID: UUID, ledger: ShoppingLedger,
                                             state: DinnerPlanningState) throws -> DinnerAdjustment? {
        guard let meal = ledger.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }),
              let removed = meal.servingGroups.first(where: { $0.id == groupID }), !removed.isProtected else { return nil }
        let remaining = meal.servingGroups.filter { $0.id != groupID }
        guard !remaining.isEmpty, try meal.servingGroups.reduce(Rational.zero, { try $0.adding($1.servings) }) == meal.servings
        else { return nil }
        let bindings = state.portionBindings.filter { $0.occurrenceID == occurrenceID }
        try validateBindings(bindings, occurrenceID: occurrenceID, ledger: ledger)
        let edits = try meal.ingredientContributionIDs.map { id in
            let ingredient = bindings.filter { $0.contributionID == id }
            guard Set(ingredient.map(\.groupID)) == Set(meal.servingGroups.map(\.id)),
                  let original = ledger.contributions.first(where: { $0.id == id })?.quantity else { throw DinnerPlanningError.reviewRequired("portionBindings") }
            let kept = try ingredient.filter { $0.groupID != groupID }.reduce(Rational.zero) { total, binding in
                guard let value = try binding.quantity.converted(to: original.unit) else { throw DinnerPlanningError.reviewRequired("portionBindingUnit") }
                return try total.adding(value)
            }
            return DinnerQuantityEdit(contributionID: id, quantity: Quantity(amount: kept, unit: original.unit,
                originalLiteral: original.originalLiteral, confirmedConversion: original.confirmedConversion))
        }
        return DinnerAdjustment(occurrenceID: occurrenceID, servings: try meal.servings.subtracting(removed.servings), groups: remaining, quantities: edits)
    }

    /// Existing allocations for a manual review. Legacy meals without any saved
    /// bindings use the same proportional interpretation as their current checkout.
    /// These rows are a draft only; no new evidence is saved before Apply.
    public static func manualPortionBindings(occurrenceID: UUID, ledger: ShoppingLedger,
                                            state: DinnerPlanningState) throws -> [DinnerPortionBinding] {
        guard let meal = ledger.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }) else { throw DinnerPlanningError.notFound(occurrenceID) }
        let saved = state.portionBindings.filter { $0.occurrenceID == occurrenceID }
        if !saved.isEmpty {
            try validateBindings(saved, occurrenceID: occurrenceID, ledger: ledger)
            for sourceID in meal.ingredientContributionIDs {
                guard Set(saved.filter { $0.contributionID == sourceID }.map(\.groupID)) == Set(meal.servingGroups.map(\.id))
                else { throw DinnerPlanningError.reviewRequired("allIngredientBindings") }
            }
            return saved
        }
        return try meal.ingredientContributionIDs.flatMap { id in
            guard let source = ledger.contributions.first(where: { $0.id == id && $0.removedAt == nil }),
                  let quantity = source.quantity else { throw DinnerPlanningError.reviewRequired("quantity") }
            let portions = try LedgerMealPortions.review(meal: meal, contribution: source, in: ledger, unit: quantity.unit, bindings: [])
            return try meal.servingGroups.map { group in
                guard let amount = portions.groups[group.id] else { throw DinnerPlanningError.reviewRequired("portionBinding") }
                return DinnerPortionBinding(occurrenceID: occurrenceID, contributionID: id, groupID: group.id,
                    quantity: Quantity(amount: amount, unit: quantity.unit, originalLiteral: amount.description,
                        confirmedConversion: quantity.confirmedConversion), servings: group.servings)
            }
        }
    }

    static func validateProtectedAdjustments(_ proposal: DinnerProposal, ledger: ShoppingLedger, state: DinnerPlanningState) throws {
        for change in proposal.changes {
            guard case .adjust(let adjustment) = change,
                  let meal = ledger.mealOccurrences.first(where: { $0.id == adjustment.occurrenceID }) else { continue }
            if proposal.tool == .pairing {
                let removed = meal.servingGroups.filter { group in !adjustment.groups.contains(where: { $0.id == group.id }) }
                guard removed.count == 1,
                      try removingServingGroup(removed[0].id, from: meal.id, ledger: ledger, state: state) == adjustment
                else { throw DinnerPlanningError.reviewRequired("reviewPortionBindings") }
            }
            let protectedGroups = Set(meal.servingGroups.filter(\.isProtected).map(\.id))
            guard !protectedGroups.isEmpty, !adjustment.quantities.isEmpty else { continue }
            let bindings: [DinnerPortionBinding]
            if proposal.tool == .manual {
                bindings = try manualPortionBindings(occurrenceID: meal.id, ledger: ledger, state: state)
            } else {
                bindings = state.portionBindings.filter { $0.occurrenceID == meal.id }
                try validateBindings(bindings, occurrenceID: meal.id, ledger: ledger)
            }
            for edit in adjustment.quantities {
                guard let quantity = edit.quantity else { throw DinnerPlanningError.reviewRequired("protectedQuantity") }
                var reserved = Rational.zero
                for binding in bindings where binding.contributionID == edit.contributionID && protectedGroups.contains(binding.groupID) {
                    guard let amount = try binding.quantity.converted(to: quantity.unit) else { throw DinnerPlanningError.reviewRequired("protectedConversion") }
                    reserved = try reserved.adding(amount)
                }
                guard quantity.amount >= reserved else { throw DinnerPlanningError.reviewRequired("protectedQuantity") }
            }
        }
    }
    static func validateManualBindings(_ proposal: DinnerProposal, ledger: ShoppingLedger,
                                      projected: ShoppingLedger, state: DinnerPlanningState) throws {
        for change in proposal.changes {
            guard case .adjust(let adjustment) = change, proposal.tool == .manual,
                  let meal = ledger.mealOccurrences.first(where: { $0.id == adjustment.occurrenceID }) else { continue }
            let protectedGroups = Set(meal.servingGroups.filter(\.isProtected).map(\.id))
            if !protectedGroups.isEmpty {
                // A bindings-only/servings-only edit must also authenticate its
                // prior protected amounts; omitted quantity edits are no bypass.
                _ = try manualPortionBindings(occurrenceID: meal.id, ledger: ledger, state: state)
            }
            guard let bindings = adjustment.portionBindings else {
                // Old unprotected manual edits may still discard stale allocations.
                // Reviewed protected food must never become an inferred serving ratio.
                guard protectedGroups.isEmpty else { throw DinnerPlanningError.reviewRequired("reviewPortionBindings") }
                continue
            }
            try validateBindings(bindings, occurrenceID: meal.id, ledger: projected)
            for sourceID in meal.ingredientContributionIDs {
                guard Set(bindings.filter { $0.contributionID == sourceID }.map(\.groupID)) == Set(adjustment.groups.map(\.id))
                else { throw DinnerPlanningError.reviewRequired("allIngredientBindings") }
            }
            let old = state.portionBindings.filter { $0.occurrenceID == meal.id }
            for binding in bindings {
                if let prior = old.first(where: { $0.contributionID == binding.contributionID && $0.groupID == binding.groupID }) {
                    guard prior.id == binding.id else { throw DinnerPlanningError.reviewRequired("portionBindingIdentity") }
                } else {
                    guard !state.portionBindings.contains(where: { $0.id == binding.id }) else { throw DinnerPlanningError.invalid("portionBindingIdentity") }
                }
            }
            for binding in old where protectedGroups.contains(binding.groupID) {
                guard bindings.contains(binding) else { throw DinnerPlanningError.reviewRequired("protectedQuantity") }
            }
            if old.isEmpty && !protectedGroups.isEmpty {
                let baseline = try manualPortionBindings(occurrenceID: meal.id, ledger: ledger, state: state)
                for binding in baseline where protectedGroups.contains(binding.groupID) {
                    guard let reviewed = bindings.first(where: { $0.contributionID == binding.contributionID && $0.groupID == binding.groupID }),
                          reviewed.quantity == binding.quantity, reviewed.servings == binding.servings
                    else { throw DinnerPlanningError.reviewRequired("protectedQuantity") }
                }
            }
        }
    }
    @discardableResult
    public static func apply(_ proposal: DinnerProposal, ledger: inout ShoppingLedger, state: inout DinnerPlanningState,
                             access: DinnerAccessContext, phase: BasketPhase, at now: Date) throws -> DinnerApplyReceipt {
        try access.validate(shopID: ledger.id, at: now, applying: true, budget: proposal.tool == .quoteAdoption)
        guard proposal.shopID == ledger.id, proposal.namespace == access.namespace, !proposal.isIsolatedPreview else { throw DinnerPlanningError.forbidden }
        try DinnerPlanningState.validate(proposal); try ledger.validate(); try state.validate()
        if let receipt = state.applyReceipts.first(where: { $0.id == proposal.id }) {
            guard receipt.proposal == proposal, receipt.appliedBy == access.actorID else { throw DinnerPlanningError.operationConflict }
            guard ledger.revisions.contains(where: { $0.id == receipt.revisionID }) else { throw DinnerPlanningError.invalid("receiptRevision") }
            return receipt
        }
        if proposal.tool.requiresPaidAccess && !access.hasPaidTools { throw DinnerPlanningError.paidAccessRequired }
        guard phase == .draft || proposal.changes.allSatisfy(\.isCalendarOnly) else { throw DinnerPlanningError.lockedBasket }
        guard proposal.baseRevisionID == ledger.revisionID, proposal.basisRevision == ledger.basisRevision,
              proposal.planningRevisionID == state.revisionID else { throw DinnerPlanningError.stalePreview }
        try validateChosen(proposal, state: state, access: access)
        try validateProtectedAdjustments(proposal, ledger: ledger, state: state)
        var nextLedger = ledger, nextState = state
        try nextLedger.applyDinnerChanges(proposal.changes, expectedRevisionID: proposal.baseRevisionID,
            revisionID: proposal.proposedRevisionID, operationID: proposal.id, at: now)
        try validateManualBindings(proposal, ledger: ledger, projected: nextLedger, state: state)
        let receipt = DinnerApplyReceipt(proposal: proposal, appliedBy: access.actorID, appliedAt: now, revisionID: nextLedger.revisionID)
        try nextState.applied(receipt); try nextState.validate()
        ledger = nextLedger; state = nextState; return receipt
    }
    public static func previewRotation(rotationID: UUID, selectedEntryIDs: [UUID], weekStart: MealDay,
        ledger: ShoppingLedger, state: DinnerPlanningState, access: DinnerAccessContext, phase: BasketPhase, at now: Date) throws -> DinnerPreview {
        guard let rotation = state.rotations.first(where: { $0.id == rotationID }) else { throw DinnerPlanningError.notFound(rotationID) }
        try dinnerUnique(selectedEntryIDs); try weekStart.validate()
        guard !selectedEntryIDs.isEmpty, selectedEntryIDs.allSatisfy({ id in rotation.entries.contains(where: { $0.id == id }) }) else { throw DinnerPlanningError.invalid("rotationSelection") }
        let changes = try rotation.entries.filter { selectedEntryIDs.contains($0.id) }.map { entry -> DinnerLedgerChange in
            guard let meal = state.acceptedDinners.first(where: { $0.id == entry.acceptedDinnerID }) else { throw DinnerPlanningError.notFound(entry.acceptedDinnerID) }
            let day = try entry.dayOffset.map { try dinnerDay(weekStart, adding: $0) }
            return .choose(PlannedDinner(acceptedDinnerID: meal.id, template: meal.template, day: day))
        }
        return try preview(changes: changes, tool: .rotation, ledger: ledger, state: state, access: access, phase: phase, at: now)
    }
    static func validateBindings(_ bindings: [DinnerPortionBinding], occurrenceID: UUID, ledger: ShoppingLedger) throws {
        guard let meal = ledger.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }), !bindings.isEmpty else { throw DinnerPlanningError.reviewRequired("portionBindings") }
        try dinnerUnique(bindings.map(\.id))
        guard Set(bindings.map { "\($0.contributionID):\($0.groupID)" }).count == bindings.count,
              Set(bindings.map(\.contributionID)) == Set(meal.ingredientContributionIDs) else { throw DinnerPlanningError.reviewRequired("allIngredientBindings") }
        for sourceID in meal.ingredientContributionIDs {
            guard let source = ledger.contributions.first(where: { $0.id == sourceID && $0.removedAt == nil }), let quantity = source.quantity else { throw DinnerPlanningError.reviewRequired("quantity") }
            var sum = Rational.zero
            for binding in bindings.filter({ $0.contributionID == sourceID }) {
                guard binding.occurrenceID == occurrenceID, let group = meal.servingGroups.first(where: { $0.id == binding.groupID }),
                      group.servings == binding.servings, let amount = try binding.quantity.converted(to: quantity.unit)
                else { throw DinnerPlanningError.reviewRequired("portionBinding") }
                sum = try sum.adding(amount)
            }
            guard sum == quantity.amount else { throw DinnerPlanningError.reviewRequired("bindingTotal") }
        }
    }
    public static func previewGuests(occurrenceID: UUID, servingsByGroup: [UUID: Rational], ledger: ShoppingLedger,
        state: DinnerPlanningState, access: DinnerAccessContext, phase: BasketPhase, at now: Date, isolated: Bool = false) throws -> DinnerPreview {
        guard let meal = ledger.mealOccurrences.first(where: { $0.id == occurrenceID && $0.removedAt == nil }) else { throw DinnerPlanningError.notFound(occurrenceID) }
        let bindings = state.portionBindings.filter { $0.occurrenceID == occurrenceID }
        try validateBindings(bindings, occurrenceID: occurrenceID, ledger: ledger)
        guard !servingsByGroup.isEmpty, Set(servingsByGroup.keys).isSubset(of: Set(meal.servingGroups.map(\.id))) else { throw DinnerPlanningError.invalid("guestGroups") }
        var groups = meal.servingGroups
        for i in groups.indices {
            if let servings = servingsByGroup[groups[i].id] {
                guard servings > .zero, !groups[i].isProtected || servings == groups[i].servings else { throw DinnerPlanningError.reviewRequired("protectedGroup") }
                groups[i].servings = servings
            }
        }
        var quantities: [DinnerQuantityEdit] = []
        for sourceID in meal.ingredientContributionIDs {
            guard let original = ledger.contributions.first(where: { $0.id == sourceID })?.quantity else { throw DinnerPlanningError.reviewRequired("quantity") }
            var sum = Rational.zero
            for binding in bindings.filter({ $0.contributionID == sourceID }) {
                let group = groups.first(where: { $0.id == binding.groupID })!
                guard let quantity = try binding.quantity.converted(to: original.unit) else { throw DinnerPlanningError.reviewRequired("conversion") }
                sum = try sum.adding(quantity.multiplied(by: group.servings.divided(by: binding.servings)))
            }
            quantities.append(DinnerQuantityEdit(contributionID: sourceID, quantity: Quantity(amount: sum, unit: original.unit,
                originalLiteral: original.originalLiteral, confirmedConversion: original.confirmedConversion)))
        }
        // A template's total may include protected groups; explicit bindings are the scaling basis.
        let total = try groups.reduce(Rational.zero) { try $0.adding($1.servings) }
        return try preview(changes: [.adjust(DinnerAdjustment(occurrenceID: occurrenceID, servings: total, groups: groups, quantities: quantities))],
            tool: .guests, ledger: ledger, state: state, access: access, phase: phase, at: now, isolated: isolated)
    }
    public static func week(start: MealDay, ledger: ShoppingLedger, state: DinnerPlanningState,
                            access: DinnerAccessContext, at now: Date) throws -> DinnerMealWeek {
        try access.validate(shopID: ledger.id, at: now); try start.validate()
        let meals = ledger.mealOccurrences.filter { $0.removedAt == nil }
        let days = try (0..<7).map { offset -> DinnerMealWeek.Day in
            let day = try dinnerDay(start, adding: offset)
            return DinnerMealWeek.Day(day: day, meals: meals.filter { $0.scheduledDay?.hasSameCivilDate(as: day) == true },
                protectedContributionIDs: state.protectedDays.filter { $0.shopID == ledger.id && $0.day?.hasSameCivilDate(as: day) == true }.map(\.contributionID),
                notes: state.weekNotes.filter { $0.shopID == ledger.id && $0.day.hasSameCivilDate(as: day) })
        }
        return DinnerMealWeek(days: days, unscheduled: meals.filter { $0.scheduledDay == nil })
    }
}

public enum DinnerIdeaEngine {
    /// Catalog order does not affect the chosen pattern. Seed is caller-owned and stable.
    /// Draft edits stay in memory until the user explicitly saves them.
    public static func draft(requestID: UUID, draftID: UUID, catalogVersion: String, catalog: [MealTemplate],
                             seed: UInt64, householdExclusions: [String], at now: Date) throws -> DinnerIdeaDraft {
        try dinnerDate(now); try dinnerText(catalogVersion)
        guard !catalog.isEmpty, catalog.count <= 500 else { throw DinnerPlanningError.reviewRequired("manualIdeaEntry") }
        try dinnerUnique(catalog.map(\.id))
        let ordered = catalog.sorted { $0.id.uuidString < $1.id.uuidString }
        var template = ordered[Int(seed % UInt64(ordered.count))]
        template.exclusions = Array(Set(template.exclusions + householdExclusions)).sorted()
        let draft = DinnerIdeaDraft(id: draftID, requestID: requestID, catalogVersion: catalogVersion,
            template: template, assumptions: ["Availability and usable yield require review"], hardExclusions: householdExclusions, createdAt: now)
        try validateDraft(draft); return draft
    }
    static func validateDraft(_ draft: DinnerIdeaDraft) throws {
        try dinnerDate(draft.createdAt); try dinnerText(draft.catalogVersion)
        // Disallowed content remains editable but cannot pass review/acceptance.
        var structural = draft.template; structural.exclusions = []
        structural.ingredients = structural.ingredients.map { MealIngredient(id: $0.id, name: $0.name, quantity: $0.quantity, notes: $0.notes) }
        try structural.validate()
        guard draft.assumptions.count <= 100, draft.template.exclusions.count <= 100, draft.hardExclusions.count <= 100 else { throw DinnerPlanningError.invalid("idea") }
        if let evidence = draft.supplyEvidence {
            try dinnerUnique(evidence.map(\.id))
            let ingredients = draft.template.ingredients
            for row in evidence {
                guard ingredients.contains(where: { $0.id == row.id && $0.name == row.ingredientName }) else { throw DinnerPlanningError.invalid("ideaIngredient") }
                try row.validate()
            }
        }
        for text in draft.assumptions + draft.template.exclusions + draft.hardExclusions + draft.template.ingredients.flatMap(\.exclusions) { try dinnerText(text) }
    }
    public static func review(_ draft: DinnerIdeaDraft) -> DinnerIdeaReview {
        var issues: [String] = []
        do {
            try validateDraft(draft)
            var constrained = draft.template
            constrained.exclusions = Array(Set(constrained.exclusions + draft.hardExclusions)).sorted()
            try constrained.validate()
        } catch { issues.append("Correct invalid or excluded ingredients") }
        if draft.template.ingredients.isEmpty { issues.append("Review ingredients") }
        if draft.template.ingredients.contains(where: { $0.quantity == nil }) { issues.append("Review unknown ingredient quantities") }
        let acceptable = issues.isEmpty
        if !draft.yieldConfirmed { issues.append("Usable yield is unconfirmed") }
        if !draft.availabilityConfirmed { issues.append("Availability is unconfirmed") }
        return DinnerIdeaReview(canAccept: acceptable, canClaimCoverage: acceptable && draft.yieldConfirmed && draft.availabilityConfirmed, issues: issues)
    }
}

func dinnerUnique(_ ids: [UUID]) throws { guard Set(ids).count == ids.count else { throw DinnerPlanningError.invalid("duplicateID") } }
func dinnerText(_ value: String) throws { guard !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, value.utf8.count <= 8192 else { throw DinnerPlanningError.invalid("text") } }
func dinnerDate(_ value: Date) throws { guard value.timeIntervalSinceReferenceDate.isFinite else { throw DinnerPlanningError.invalid("date") } }
func dinnerDay(_ day: MealDay, adding offset: Int) throws -> MealDay {
    try day.validate(); var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: day.timeZoneIdentifier)!
    guard let date = day.date, let shifted = calendar.date(byAdding: .day, value: offset, to: date) else { throw DinnerPlanningError.invalid("day") }
    return try MealDay(date: shifted, timeZoneIdentifier: day.timeZoneIdentifier)
}
