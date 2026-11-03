import Foundation

public enum LedgerError: Error, Equatable, Sendable {
    case invalid(String)
    case notFound(UUID)
    case duplicateDecisionRequired(UUID)
    case incompatibleMatch
    case excludedIngredient(String)
    case allocationExceedsQuantity
    case stalePreview
    case alreadyUndone
}

public enum FulfillmentMode: String, Codable, CaseIterable, Sendable { case pickup, delivery, inStore }
public enum BudgetScope: String, Codable, CaseIterable, Sendable { case wholeShop, dinnersOnly, selectedItems }
public enum CapFirmness: String, Codable, CaseIterable, Sendable { case firm, flexible }

/// Manually entered retailer evidence. This is not a calculated checkout quote.
public struct LedgerRetailerPreview: Codable, Equatable, Sendable {
    public var total: Money?
    public var source: String
    public var capturedAt: Date
    public var includedCharges: [String]
    public init(total: Money? = nil, source: String, capturedAt: Date, includedCharges: [String] = []) {
        self.total = total; self.source = source; self.capturedAt = capturedAt; self.includedCharges = includedCharges
    }
    public func validate() throws {
        try ledgerText(source, nonempty: true, maximum: 2048); try ledgerDate(capturedAt)
        guard total.map({ $0.minorUnits >= 0 }) ?? true, includedCharges.count <= 100 else { throw LedgerError.invalid("retailerPreview") }
        for charge in includedCharges { try ledgerText(charge, nonempty: true, maximum: 512) }
    }
}

public struct ShopBasis: Codable, Equatable, Sendable {
    public var branch: String
    public var mode: FulfillmentMode
    public var slot: Date?
    public var timeZoneIdentifier: String
    public var cap: Money?
    public var capScope: BudgetScope
    public var currency: Currency
    public var capFirmness: CapFirmness
    public var fixedReserve: Money?
    public var knownFees: Money?
    public var retailerPreview: LedgerRetailerPreview?

    public init(branch: String = "", mode: FulfillmentMode = .pickup, slot: Date? = nil,
                timeZoneIdentifier: String = TimeZone.current.identifier, cap: Money? = nil,
                capScope: BudgetScope = .wholeShop, currency: Currency = .usd,
                capFirmness: CapFirmness = .firm, fixedReserve: Money? = nil, knownFees: Money? = nil,
                retailerPreview: LedgerRetailerPreview? = nil) {
        self.branch = branch; self.mode = mode; self.slot = slot
        self.timeZoneIdentifier = timeZoneIdentifier; self.cap = cap; self.capScope = capScope
        self.currency = currency; self.capFirmness = capFirmness
        self.fixedReserve = fixedReserve; self.knownFees = knownFees; self.retailerPreview = retailerPreview
    }

    public func validate() throws {
        try ledgerText(branch, maximum: 512)
        guard TimeZone(identifier: timeZoneIdentifier) != nil else { throw LedgerError.invalid("timeZone") }
        try ledgerDate(slot); try retailerPreview?.validate()
        for amount in [cap, fixedReserve, knownFees, retailerPreview?.total].compactMap({ $0 }) {
            guard amount.minorUnits >= 0, amount.currency == currency else { throw LedgerError.invalid("money") }
        }
    }
}

/// A meal night is a civil day in an explicit zone, not a UTC instant.
public struct MealDay: Codable, Equatable, Hashable, Sendable {
    public let year: Int
    public let month: Int
    public let day: Int
    public let timeZoneIdentifier: String

    public init(year: Int, month: Int, day: Int, timeZoneIdentifier: String) throws {
        self.year = year; self.month = month; self.day = day; self.timeZoneIdentifier = timeZoneIdentifier
        try validate()
    }

    public init(date: Date, timeZoneIdentifier: String) throws {
        try ledgerDate(date)
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { throw LedgerError.invalid("timeZone") }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        try self.init(year: parts.year ?? 0, month: parts.month ?? 0, day: parts.day ?? 0,
                      timeZoneIdentifier: timeZoneIdentifier)
    }

    public var date: Date? {
        guard let zone = TimeZone(identifier: timeZoneIdentifier) else { return nil }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))
    }

    public var iso8601: String { String(format: "%04d-%02d-%02d", year, month, day) }

    public func validate() throws {
        guard (1...9999).contains(year), (1...12).contains(month), (1...31).contains(day),
              let zone = TimeZone(identifier: timeZoneIdentifier), let date else {
            throw LedgerError.invalid("mealDay")
        }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        guard parts.year == year, parts.month == month, parts.day == day else { throw LedgerError.invalid("mealDay") }
    }
}

public struct ServingGroup: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var servings: Rational
    public var isProtected: Bool
    public init(id: UUID = UUID(), name: String, servings: Rational, isProtected: Bool = false) {
        self.id = id; self.name = name; self.servings = servings; self.isProtected = isProtected
    }
}

public struct MealIngredient: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var quantity: Quantity?
    public var notes: String
    public var exclusions: [String]
    public init(id: UUID = UUID(), name: String, quantity: Quantity?, notes: String = "", exclusions: [String] = []) {
        self.id = id; self.name = name; self.quantity = quantity; self.notes = notes; self.exclusions = exclusions
    }
}

public struct MealTemplate: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var revision: Int
    public var title: String
    public var servings: Rational
    public var ingredients: [MealIngredient]
    public var notes: String
    public var sourceURL: String?
    public var sourceEvidence: RecipeSourceEvidence? = nil
    public var exclusions: [String]
    public var servingGroups: [ServingGroup]
    public var leadTimeMinutes: Int?
    public var completedSteps: [String]

    public init(id: UUID = UUID(), title: String, servings: Rational = .one,
                ingredients: [MealIngredient] = [], notes: String = "", sourceURL: String? = nil,
                exclusions: [String] = [], revision: Int = 0, servingGroups: [ServingGroup] = [],
                leadTimeMinutes: Int? = nil, completedSteps: [String] = [], sourceEvidence: RecipeSourceEvidence? = nil) {
        self.id = id; self.revision = revision; self.title = title; self.servings = servings
        self.ingredients = ingredients; self.notes = notes; self.sourceURL = sourceURL
        self.exclusions = exclusions; self.servingGroups = servingGroups
        self.leadTimeMinutes = leadTimeMinutes; self.completedSteps = completedSteps
        self.sourceEvidence = sourceEvidence
    }

    public func validate() throws {
        try ledgerText(title, nonempty: true, maximum: 512); try ledgerText(notes)
        if let sourceURL { try ledgerText(sourceURL, maximum: 2048) }
        try sourceEvidence?.validate()
        try validateExclusions(exclusions)
        guard revision >= 0, servings > .zero, ingredients.count <= 200,
              servingGroups.count <= 100, completedSteps.count <= 100,
              leadTimeMinutes.map({ (0...525_600).contains($0) }) ?? true else { throw LedgerError.invalid("mealTemplate") }
        try uniqueIDs(ingredients.map(\.id)); try uniqueIDs(servingGroups.map(\.id))
        for ingredient in ingredients {
            try ledgerText(ingredient.name, nonempty: true, maximum: 512)
            try ledgerText(ingredient.notes); try ingredient.quantity?.validate(); try validateExclusions(ingredient.exclusions)
            try permittedProduct(ingredient.name, exclusions: exclusions + ingredient.exclusions)
        }
        for group in servingGroups {
            try ledgerText(group.name, nonempty: true, maximum: 512)
            guard group.servings > .zero else { throw LedgerError.invalid("servingGroup") }
        }
        for step in completedSteps { try ledgerText(step) }
    }
}

public struct MealOccurrence: Codable, Equatable, Sendable, Identifiable {
    public var carryover: DinnerCarryoverLink? = nil
    public let id: UUID
    public let templateID: UUID?
    public let templateRevision: Int?
    public var title: String
    public var servings: Rational
    public var notes: String
    public var sourceURL: String?
    public var sourceEvidence: RecipeSourceEvidence? = nil
    public var exclusions: [String]
    public var servingGroups: [ServingGroup]
    public var leadTimeMinutes: Int?
    public var completedSteps: [String]
    public var ingredientContributionIDs: [UUID]
    public var scheduledDay: MealDay?
    public var isHidden: Bool
    public var removedAt: Date?
}

public enum ContributionSource: Codable, Equatable, Sendable {
    case manual
    case imported(batchID: UUID)
    case meal(occurrenceID: UUID)
    case protectedNeed(purpose: String)

    public var isProtected: Bool { if case .protectedNeed = self { return true }; return false }
    public var isMeal: Bool { if case .meal = self { return true }; return false }
    public var canSupplyExistingQuantity: Bool { !isProtected && !isMeal }
}

public struct LedgerContribution: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var lineID: UUID
    public var source: ContributionSource
    public var productName: String
    public var quantity: Quantity?
    public var originalText: String
    public var notes: String
    public var exclusions: [String]
    public var removedAt: Date?
    public var capture: CaptureImportMetadata? = nil
}

public enum AllocationKind: String, Codable, Sendable { case duplicate, withinExisting }

/// Duplicate edges retain provenance; withinExisting edges reserve a finite part
/// of a manual/import source for a meal or protected need. Neither is a stock lot.
public struct AllocationEdge: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var demandContributionID: UUID
    public var supplyContributionID: UUID
    public var quantity: Quantity
    public var kind: AllocationKind
}

public struct ShoppingLine: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var name: String
    public var notes: String
    public var aisle: String
    public let originalOrder: Int
    public var checkedAt: Date?
    public var handledBy: String?
    public var handledAt: Date?
    public var trashedAt: Date?
    public var stapleApproval: StapleApproval?
    public var isChecked: Bool { checkedAt != nil }
    public var isHandled: Bool { handledAt != nil }
    public var isTrashed: Bool { trashedAt != nil }
}

public enum ImportSource: String, Codable, CaseIterable, Sendable { case typed, paste, selectedText, voice, photoOCR }
public enum ImportResolution: Codable, Equatable, Sendable {
    case addNew
    case addToLine(UUID)
    case mergeDuplicate(UUID)
    case skip
}

public struct StagedImportLine: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let proposedLineID: UUID
    public let originalText: String
    public var name: String
    public var quantity: Quantity?
    public var unresolvedReason: String?
    public var duplicateLineIDs: [UUID]
    public var exclusions: [String]
    public var capture: CaptureImportMetadata?

    public init(id: UUID, proposedLineID: UUID, originalText: String, name: String, quantity: Quantity?,
                unresolvedReason: String?, duplicateLineIDs: [UUID], exclusions: [String] = [],
                capture: CaptureImportMetadata? = nil) {
        self.id = id; self.proposedLineID = proposedLineID; self.originalText = originalText; self.name = name
        self.quantity = quantity; self.unresolvedReason = unresolvedReason; self.duplicateLineIDs = duplicateLineIDs
        self.exclusions = exclusions; self.capture = capture
    }
    private enum CodingKeys: String, CodingKey {
        case id, proposedLineID, originalText, name, quantity, unresolvedReason, duplicateLineIDs, exclusions, capture
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(UUID.self, forKey: .id); proposedLineID = try c.decode(UUID.self, forKey: .proposedLineID)
        originalText = try c.decode(String.self, forKey: .originalText); name = try c.decode(String.self, forKey: .name)
        quantity = try c.decodeIfPresent(Quantity.self, forKey: .quantity)
        unresolvedReason = try c.decodeIfPresent(String.self, forKey: .unresolvedReason)
        duplicateLineIDs = try c.decode([UUID].self, forKey: .duplicateLineIDs)
        exclusions = try c.decodeIfPresent([String].self, forKey: .exclusions) ?? []
        capture = try c.decodeIfPresent(CaptureImportMetadata.self, forKey: .capture)
    }
}

public struct StagedListImport: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let shopID: UUID
    public let baseRevision: Int
    public let source: ImportSource
    public let originalText: String
    public var lines: [StagedImportLine]
}

public struct LedgerImportBatch: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let preview: StagedListImport
    public let decisions: [UUID: ImportResolution]
    public let contributionIDs: [UUID]
    public let createdAt: Date
    public var undoneAt: Date?
    public var originalText: String { preview.originalText }
    public var source: ImportSource { preview.source }
}

public struct LedgerQuoteReference: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let basisRevision: Int
    public let ledgerRevision: Int
    public let createdAt: Date
    public let source: String
    public init(id: UUID = UUID(), basisRevision: Int, ledgerRevision: Int, createdAt: Date = Date(), source: String = "") {
        self.id = id; self.basisRevision = basisRevision; self.ledgerRevision = ledgerRevision
        self.createdAt = createdAt; self.source = source
    }
}

public struct LedgerRevision: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let parentID: UUID?
    public let number: Int
    public let basisRevision: Int
    public let createdAt: Date
    public let operation: String
}

public struct LedgerWorkspace: Codable, Equatable, Sendable {
    public var shops: [ShoppingLedger]
    public var mealTemplates: [MealTemplate]
    public var selectedShopID: UUID?
    public var dinnerPlanning: DinnerPlanningState
    public var listLayout = LedgerListLayout()
    public var packSelections: [LedgerPackSelection]
    public init(shops: [ShoppingLedger] = [], mealTemplates: [MealTemplate] = [], selectedShopID: UUID? = nil,
                dinnerPlanning: DinnerPlanningState = DinnerPlanningState(), packSelections: [LedgerPackSelection] = []) {
        self.shops = shops; self.mealTemplates = mealTemplates; self.selectedShopID = selectedShopID
        self.dinnerPlanning = dinnerPlanning
        self.packSelections = packSelections
    }
    private enum CodingKeys: String, CodingKey { case shops, mealTemplates, selectedShopID, dinnerPlanning, packSelections, listLayout }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shops, forKey: .shops)
        try c.encode(mealTemplates, forKey: .mealTemplates)
        try c.encodeIfPresent(selectedShopID, forKey: .selectedShopID)
        try c.encode(dinnerPlanning, forKey: .dinnerPlanning)
        try c.encode(packSelections, forKey: .packSelections)
        // A previously exported workspace keeps its canonical digest until its contents change.
        if listLayout != LedgerListLayout() { try c.encode(listLayout, forKey: .listLayout) }
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        listLayout = try c.decodeIfPresent(LedgerListLayout.self, forKey: .listLayout) ?? LedgerListLayout()
        shops = try c.decode([ShoppingLedger].self, forKey: .shops)
        mealTemplates = try c.decode([MealTemplate].self, forKey: .mealTemplates)
        selectedShopID = try c.decodeIfPresent(UUID.self, forKey: .selectedShopID)
        dinnerPlanning = try c.decodeIfPresent(DinnerPlanningState.self, forKey: .dinnerPlanning) ?? DinnerPlanningState()
        packSelections = try c.decodeIfPresent([LedgerPackSelection].self, forKey: .packSelections) ?? []
        try validate()
    }
    public func validate() throws {
        guard shops.count <= 100, mealTemplates.count <= 500 else { throw LedgerError.invalid("workspaceSize") }
        try uniqueIDs(shops.map(\.id)); try uniqueIDs(mealTemplates.map(\.id))
        if let selectedShopID, !shops.contains(where: { $0.id == selectedShopID }) { throw LedgerError.notFound(selectedShopID) }
        for shop in shops { try shop.validate() }
        for meal in mealTemplates { try meal.validate() }
        try dinnerPlanning.validate(shops: shops)
        try listLayout.validate(shops: shops)
        guard packSelections.count <= 10_000 else { throw LedgerError.invalid("packSelections") }
        try uniqueIDs(packSelections.map(\.id))
        for selection in packSelections {
            guard let shop = shops.first(where: { $0.id == selection.shopID }) else { throw LedgerPackError.invalidEvidence }
            try selection.validateReference(in: shop)
        }
    }
}

public struct ShoppingLedger: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public var title: String
    public private(set) var basis: ShopBasis
    public private(set) var basisRevision: Int
    public private(set) var stapleReviews: [StapleRecallReceipt]?
    public private(set) var revision: Int
    public private(set) var revisionID: UUID
    public private(set) var revisions: [LedgerRevision]
    public private(set) var quoteReference: LedgerQuoteReference?
    public private(set) var lines: [ShoppingLine]
    public private(set) var contributions: [LedgerContribution]
    public private(set) var allocations: [AllocationEdge]
    public private(set) var mealOccurrences: [MealOccurrence]
    public private(set) var importBatches: [LedgerImportBatch]

    public init(id: UUID = UUID(), title: String = "Pickup", basis: ShopBasis = ShopBasis()) {
        self.id = id; self.title = title; self.basis = basis; basisRevision = 0; revision = 0
        revisionID = UUID(); revisions = []; quoteReference = nil
        lines = []; contributions = []; allocations = []; mealOccurrences = []; importBatches = []
    }

    public func contributions(forLineID lineID: UUID) -> [LedgerContribution] {
        contributions.filter { $0.lineID == lineID && $0.removedAt == nil }
    }

    public func search(_ query: String) -> [ShoppingLine] {
        let term = normalizedProduct(query)
        let visible = lines.filter { !$0.isTrashed }
        guard !term.isEmpty else { return visible.sorted { $0.originalOrder < $1.originalOrder } }
        // Search each source once, rather than rescanning every source for each line.
        let matchingSourceLines = Set(contributions.lazy.filter {
            $0.removedAt == nil && normalizedProduct($0.originalText + " " + $0.notes).contains(term)
        }.map(\.lineID))
        return visible.filter { line in
            matchingSourceLines.contains(line.id)
                || normalizedProduct(line.name + " " + line.notes + " " + line.aisle).contains(term)
        }.sorted { $0.originalOrder < $1.originalOrder }
    }

    public var recentlyChecked: [ShoppingLine] {
        lines.filter { $0.isChecked && !$0.isTrashed }.sorted { $0.checkedAt! > $1.checkedAt! }
    }
    public var handled: [ShoppingLine] { lines.filter { $0.isHandled && !$0.isTrashed }.sorted { $0.originalOrder < $1.originalOrder } }
    public var trash: [ShoppingLine] { lines.filter(\.isTrashed).sorted { $0.originalOrder < $1.originalOrder } }

    public func trashImpact(lineID: UUID) throws -> [LedgerContribution] {
        _ = try lineIndex(lineID)
        return contributions(forLineID: lineID).filter { $0.source.isMeal || $0.source.isProtected }
    }

    /// Nil is unresolved, including any missing or nonconvertible contribution.
    /// A trashed line retains its need for inspection and restoration.
    public func quantity(forLineID lineID: UUID) throws -> Quantity? {
        let line = lines[try lineIndex(lineID)]
        return try quantity(for: line, members: contributions(forLineID: lineID), edges: allocations)
    }

    private func quantity(for line: ShoppingLine, members: [LedgerContribution], edges: [AllocationEdge]) throws -> Quantity? {
        guard !members.isEmpty else { return nil }
        guard let unit = members.first?.quantity?.unit else { return nil }
        let activeIDs = Set(members.map(\.id))
        let roots = duplicateRoots(for: members, edges: edges)
        var totals: [UUID: Rational] = [:]
        for member in members {
            guard let quantity = member.quantity, let amount = try quantity.converted(to: unit) else { return nil }
            let root = roots[member.id] ?? member.id
            totals[root] = max(totals[root] ?? .zero, amount)
        }
        var total = Rational.zero
        for amount in totals.values { total = try total.adding(amount) }
        for edge in edges where edge.kind == .withinExisting
            && activeIDs.contains(edge.demandContributionID) && activeIDs.contains(edge.supplyContributionID) {
            guard let amount = try edge.quantity.converted(to: unit) else { return nil }
            total = try total.subtracting(amount)
        }
        return Quantity(amount: total, unit: unit, originalLiteral: "\(total) \(line.name)")
    }

    @discardableResult
    public mutating func addManualLine(name: String, quantity: Quantity?, notes: String = "",
                                       exclusions: [String] = [], at: Date = Date()) throws -> UUID {
        try mutate("addManualLine", at: at) { next in
            let lineID = next.appendLine(name: name, notes: notes)
            next.contributions.append(LedgerContribution(id: UUID(), lineID: lineID, source: .manual,
                productName: name, quantity: quantity, originalText: quantity?.originalLiteral ?? name,
                notes: notes, exclusions: exclusions, removedAt: nil))
            return lineID
        }
    }

    public mutating func approveStaple(lineID: UUID, purpose: String?, at date: Date = Date()) throws {
        try mutate("reviewStaple", at: date) { next in
            let index = try next.lineIndex(lineID)
            if let purpose {
                let branch = next.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
                let label = purpose.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !branch.isEmpty, !next.lines[index].isTrashed else { throw LedgerError.invalid("stapleStore") }
                try ledgerText(label, nonempty: true, maximum: 512)
                next.lines[index].stapleApproval = StapleApproval(purpose: label, branch: branch, approvedAt: date)
            } else { next.lines[index].stapleApproval = nil }
        }
    }

    public func matchingStapleLine(named name: String) -> ShoppingLine? {
        lines.first { normalizedProduct($0.name) == normalizedProduct(name) }
    }

    mutating func recordStaple(_ review: ReviewedStaple, choice: StapleChoice, quantity: Quantity?, exclusions: [String], at date: Date) throws {
        var next = self
        let newID: UUID?
        if choice == .needed {
            guard matchingStapleLine(named: review.line.name) == nil else { throw LedgerError.invalid("stapleAlreadyListed") }
            newID = try next.addManualLine(name: review.line.name, quantity: quantity, notes: review.approval.purpose, exclusions: exclusions, at: date)
        } else {
            try next.mutate("reviewPriorStaple", at: date) { _ in }
            newID = nil
        }
        var receipts = next.stapleReviews ?? []
        receipts.append(.init(source: review.source, choice: choice, newLineID: newID, quantity: quantity))
        next.stapleReviews = receipts
        try next.validate()
        self = next
    }
    /// External capture/inbox callers persist the returned preview before Apply.
    /// Reuse its full bytes for retries; re-staging a new preview with this ID is
    /// deliberately not equivalent to replaying an already committed preview.
    public func stageImport(text: String, source: ImportSource = .typed, importID: UUID = UUID()) -> StagedListImport {
        var staged: [StagedImportLine] = []
        var candidatesByName = importCandidatesByName()
        for original in text.components(separatedBy: .newlines) where !original.trimmingCharacters(in: .whitespaces).isEmpty {
            let parsed = Self.parseLine(original)
            let name = normalizedProduct(parsed.name), proposedLineID = UUID()
            staged.append(StagedImportLine(id: UUID(), proposedLineID: proposedLineID, originalText: original,
                name: parsed.name, quantity: parsed.quantity, unresolvedReason: parsed.reason,
                duplicateLineIDs: candidatesByName[name] ?? []))
            candidatesByName[name, default: []].append(proposedLineID)
        }
        return StagedListImport(id: importID, shopID: id, baseRevision: revision, source: source, originalText: text, lines: staged)
    }

    /// Refresh suggestions after editing a staged product name without changing
    /// the staged identities, original evidence, or the reviewed shop revision.
    public func refreshImportMatches(_ preview: StagedListImport) throws -> StagedListImport {
        guard preview.shopID == id, preview.baseRevision == revision else { throw LedgerError.stalePreview }
        try validatePreview(preview)
        var refreshed = preview
        var candidatesByName = importCandidatesByName()
        for index in refreshed.lines.indices {
            let name = normalizedProduct(refreshed.lines[index].name)
            refreshed.lines[index].duplicateLineIDs = candidatesByName[name] ?? []
            candidatesByName[name, default: []].append(refreshed.lines[index].proposedLineID)
        }
        return refreshed
    }

    private func importCandidatesByName() -> [String: [UUID]] {
        var candidates: [String: [UUID]] = [:]
        for line in lines where !line.isTrashed { candidates[normalizedProduct(line.name), default: []].append(line.id) }
        return candidates
    }

    @discardableResult
    public mutating func commitImport(_ preview: StagedListImport, decisions: [UUID: ImportResolution] = [:],
                                       at: Date = Date()) throws -> UUID {
        if let receipt = importBatches.first(where: { $0.id == preview.id }) {
            guard receipt.preview == preview, receipt.decisions == decisions else { throw LedgerError.invalid("importReplay") }
            guard receipt.undoneAt == nil else { throw LedgerError.alreadyUndone }
            return receipt.id
        }
        guard preview.shopID == id, preview.baseRevision == revision else { throw LedgerError.stalePreview }
        try validatePreview(preview)
        guard Set(decisions.keys).isSubset(of: Set(preview.lines.map(\.id))) else { throw LedgerError.invalid("importDecision") }
        return try mutate("commitImport", at: at) { next in
            var contributionIDs: [UUID] = []
            var existingNames = Set(next.lines.lazy.filter { !$0.isTrashed }.map { normalizedProduct($0.name) })
            for entry in preview.lines {
                let name = normalizedProduct(entry.name)
                if existingNames.contains(name) && decisions[entry.id] == nil { throw LedgerError.duplicateDecisionRequired(entry.id) }
                let resolution = decisions[entry.id] ?? .addNew
                if case .skip = resolution { continue }
                if let capture = entry.capture, !capture.blockingFields.isEmpty {
                    throw CaptureImportError.reviewRequired(capture.blockingFields)
                }
                let lineID: UUID
                var duplicateSupply: LedgerContribution?
                switch resolution {
                case .addNew:
                    lineID = next.appendLine(id: entry.proposedLineID, name: entry.name)
                    existingNames.insert(name)
                case let .addToLine(target):
                    try next.requireMatch(name: entry.name, quantity: entry.quantity, exclusions: entry.exclusions, lineID: target)
                    lineID = target
                case let .mergeDuplicate(target):
                    try next.requireMatch(name: entry.name, quantity: entry.quantity, exclusions: entry.exclusions, lineID: target)
                    guard let quantity = entry.quantity,
                          let source = try next.contributions(forLineID: target).first(where: { candidate in
                              guard candidate.source.canSupplyExistingQuantity, let original = candidate.quantity,
                                    let amount = try quantity.converted(to: original.unit) else { return false }
                              return amount == original.amount
                          }) else { throw LedgerError.incompatibleMatch }
                    duplicateSupply = source; lineID = target
                case .skip: continue
                }
                next.contributions.append(LedgerContribution(id: entry.id, lineID: lineID, source: .imported(batchID: preview.id),
                    productName: entry.name, quantity: entry.quantity, originalText: entry.originalText,
                    notes: [entry.capture?.purpose, entry.capture?.destination, entry.unresolvedReason]
                        .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n"),
                    exclusions: entry.exclusions, removedAt: nil, capture: entry.capture))
                if let supply = duplicateSupply, let quantity = entry.quantity {
                    next.allocations.append(AllocationEdge(id: UUID(), demandContributionID: entry.id,
                        supplyContributionID: supply.id, quantity: quantity, kind: .duplicate))
                }
                contributionIDs.append(entry.id)
            }
            next.importBatches.append(LedgerImportBatch(id: preview.id, preview: preview, decisions: decisions,
                contributionIDs: contributionIDs, createdAt: at, undoneAt: nil))
            return preview.id
        }
    }

    public mutating func undoImport(batchID: UUID, at: Date = Date()) throws {
        guard let index = importBatches.firstIndex(where: { $0.id == batchID }) else { throw LedgerError.notFound(batchID) }
        if importBatches[index].undoneAt != nil { return }
        try mutate("undoImport", at: at) { next in
            let removed = Set(next.importBatches[index].contributionIDs)
            try next.removeSources(removed, at: at)
            next.importBatches[index].undoneAt = at
        }
    }

    public mutating func updateLine(lineID: UUID, name: String, notes: String, aisle: String, at: Date = Date()) throws {
        try mutate("updateLine", at: at) { next in
            let index = try next.lineIndex(lineID)
            for source in next.contributions(forLineID: lineID) { try permittedProduct(name, exclusions: source.exclusions) }
            next.lines[index].name = name; next.lines[index].notes = notes; next.lines[index].aisle = aisle
            for index in next.contributions.indices where next.contributions[index].lineID == lineID && next.contributions[index].removedAt == nil {
                next.contributions[index].productName = name
            }
            // Keep original source wording independently of the edited product name.
        }
    }

    public mutating func updateContribution(contributionID: UUID, quantity: Quantity?, notes: String, at: Date = Date()) throws {
        try mutate("updateContribution", at: at) { next in
            let index = try next.contributionIndex(contributionID)
            guard next.contributions[index].removedAt == nil else { throw LedgerError.invalid("removedContribution") }
            next.contributions[index].quantity = quantity; next.contributions[index].notes = notes
        }
    }

    public mutating func removeContribution(contributionID: UUID, at: Date = Date()) throws {
        let index = try contributionIndex(contributionID)
        guard contributions[index].removedAt == nil else { return }
        try mutate("removeContribution", at: at) { next in
            try next.removeSources([contributionID], at: at)
        }
    }

    public mutating func unlinkContribution(contributionID: UUID, at: Date = Date()) throws {
        _ = try contributionIndex(contributionID)
        try mutate("unlinkContribution", at: at) { next in
            next.allocations.removeAll { $0.kind == .withinExisting && $0.demandContributionID == contributionID }
        }
    }

    public mutating func setChecked(lineID: UUID, checked: Bool, at: Date = Date()) throws {
        try mutate("setChecked", at: at) { next in
            let index = try next.lineIndex(lineID)
            next.lines[index].checkedAt = checked ? at : nil
        }
    }
    public mutating func handle(lineID: UUID, by: String, at: Date = Date()) throws {
        try ledgerText(by, nonempty: true, maximum: 512)
        try mutate("handle", at: at) { next in
            let index = try next.lineIndex(lineID)
            next.lines[index].handledBy = by; next.lines[index].handledAt = at
        }
    }
    public mutating func reopen(lineID: UUID, at: Date = Date()) throws {
        try mutate("reopen", at: at) { next in
            let index = try next.lineIndex(lineID)
            next.lines[index].checkedAt = nil; next.lines[index].handledBy = nil; next.lines[index].handledAt = nil
        }
    }
    public mutating func trash(lineID: UUID, at: Date = Date()) throws {
        try mutate("trash", at: at) { next in next.lines[try next.lineIndex(lineID)].trashedAt = at }
    }
    /// Restoring deletion preserves the separately recorded check/handling status.
    public mutating func restore(lineID: UUID, at: Date = Date()) throws {
        try mutate("restore", at: at) { next in
            guard !next.contributions(forLineID: lineID).isEmpty else { throw LedgerError.invalid("noActiveSources") }
            next.lines[try next.lineIndex(lineID)].trashedAt = nil
        }
    }

    public mutating func updateBasis(_ newBasis: ShopBasis, at: Date = Date()) throws {
        try newBasis.validate()
        guard basis != newBasis else { return }
        try mutate("updateBasis", at: at) { next in
            next.basis = newBasis; next.basisRevision = try increment(next.basisRevision)
        }
    }
    public mutating func attachQuote(_ reference: LedgerQuoteReference) throws {
        guard reference.basisRevision == basisRevision, reference.ledgerRevision == revision else { throw LedgerError.stalePreview }
        try ledgerDate(reference.createdAt); try ledgerText(reference.source)
        quoteReference = reference
    }

    /// Only the coordinated physical-carryover path may create this calendar target.
    /// It retains source recipe identity and creates no grocery lines/contributions.
    public mutating func appendConfirmedCarryover(_ plan: DinnerCarryoverPlan, at: Date) throws {
        try plan.validate()
        guard plan.link.sourceShopID == id else { throw LedgerError.invalid("carryoverShop") }
        let source = plan.source
        let target = MealOccurrence(carryover: plan.link, id: plan.occurrenceID,
            templateID: source.templateID, templateRevision: source.templateRevision,
            title: source.title, servings: plan.servings, notes: source.notes, sourceURL: source.sourceURL,
            sourceEvidence: source.sourceEvidence, exclusions: source.exclusions, servingGroups: [],
            leadTimeMinutes: nil, completedSteps: [], ingredientContributionIDs: [],
            scheduledDay: plan.day, isHidden: false, removedAt: nil)
        if let prior = mealOccurrences.first(where: { $0.id == plan.occurrenceID }) {
            guard prior == target else { throw DinnerPlanningError.operationConflict }; return
        }
        guard revisionID == plan.baseRevisionID,
              mealOccurrences.first(where: { $0.id == source.id }) == source else { throw DinnerPlanningError.stalePreview }
        try mutate("physical-carryover:v1:\(plan.link.operationID)", at: at, revisionID: plan.revisionID) { next in
            next.mealOccurrences.append(target)
        }
    }

    @discardableResult
    public mutating func chooseMeal(_ template: MealTemplate, on: Date? = nil, at: Date = Date()) throws -> UUID {
        try template.validate()
        let scheduledDay = try on.map { try MealDay(date: $0, timeZoneIdentifier: basis.timeZoneIdentifier) }
        return try mutate("chooseMeal", at: at) { next in
            let occurrenceID = UUID()
            var ingredientIDs: [UUID] = []
            for ingredient in template.ingredients {
                let lineID = next.appendLine(name: ingredient.name, notes: ingredient.notes)
                let contributionID = UUID(); ingredientIDs.append(contributionID)
                next.contributions.append(LedgerContribution(id: contributionID, lineID: lineID,
                    source: .meal(occurrenceID: occurrenceID), productName: ingredient.name, quantity: ingredient.quantity,
                    originalText: ingredient.quantity?.originalLiteral ?? ingredient.name, notes: ingredient.notes,
                    exclusions: template.exclusions + ingredient.exclusions, removedAt: nil))
            }
            next.mealOccurrences.append(MealOccurrence(id: occurrenceID, templateID: template.id, templateRevision: template.revision,
                title: template.title, servings: template.servings, notes: template.notes, sourceURL: template.sourceURL,
                sourceEvidence: template.sourceEvidence, exclusions: template.exclusions, servingGroups: template.servingGroups, leadTimeMinutes: template.leadTimeMinutes,
                completedSteps: template.completedSteps, ingredientContributionIDs: ingredientIDs, scheduledDay: scheduledDay,
                isHidden: false, removedAt: nil))
            return occurrenceID
        }
    }

    public mutating func scheduleMeal(occurrenceID: UUID, on: Date?, at: Date = Date()) throws {
        let day = try on.map { try MealDay(date: $0, timeZoneIdentifier: basis.timeZoneIdentifier) }
        try scheduleMeal(occurrenceID: occurrenceID, day: day, at: at)
    }
    public mutating func scheduleMeal(occurrenceID: UUID, day: MealDay?, at: Date = Date()) throws {
        try day?.validate()
        try mutate("scheduleMeal", at: at) { next in
            let index = try next.mealIndex(occurrenceID)
            guard next.mealOccurrences[index].carryover == nil else { throw DinnerPlanningError.reviewRequired("physicalCarryover") }
            next.mealOccurrences[index].scheduledDay = day
        }
    }
    public mutating func updateMeal(occurrenceID: UUID, title: String, notes: String, at: Date = Date()) throws {
        try mutate("updateMeal", at: at) { next in
            let index = try next.mealIndex(occurrenceID)
            guard next.mealOccurrences[index].carryover == nil else { throw DinnerPlanningError.reviewRequired("physicalCarryover") }
            next.mealOccurrences[index].title = title; next.mealOccurrences[index].notes = notes
        }
    }
    public mutating func setMealHidden(occurrenceID: UUID, hidden: Bool, at: Date = Date()) throws {
        try mutate("setMealHidden", at: at) { next in
            let index = try next.mealIndex(occurrenceID)
            guard next.mealOccurrences[index].carryover == nil else { throw DinnerPlanningError.reviewRequired("physicalCarryover") }
            next.mealOccurrences[index].isHidden = hidden
        }
    }
    public mutating func removeMeal(occurrenceID: UUID, at: Date = Date()) throws {
        try mutate("removeMeal", at: at) { next in
            let index = try next.mealIndex(occurrenceID)
            guard next.mealOccurrences[index].carryover == nil else { throw DinnerPlanningError.reviewRequired("physicalCarryover") }
            try next.removeSources(Set(next.mealOccurrences[index].ingredientContributionIDs), at: at)
            next.mealOccurrences[index].removedAt = at
        }
    }

    /// Moves the need to the supply line and links a reviewed amount within it.
    /// Partial links leave the remaining need additive; existing links are replaced.
    public mutating func linkContribution(contributionID: UUID, within supplyID: UUID, quantity: Quantity,
                                           at: Date = Date()) throws {
        try mutate("linkContribution", at: at) { next in
            try next.link(contributionID: contributionID, supplyID: supplyID, quantity: quantity, at: at)
        }
    }

    @discardableResult
    public mutating func addProtectedNeed(name: String, quantity: Quantity?, purpose: String, within: UUID? = nil,
                                          exclusions: [String] = [], at: Date = Date()) throws -> UUID {
        try ledgerText(purpose, nonempty: true, maximum: 512)
        return try mutate("addProtectedNeed", at: at) { next in
            let lineID = next.appendLine(name: name)
            let sourceID = UUID()
            next.contributions.append(LedgerContribution(id: sourceID, lineID: lineID,
                source: .protectedNeed(purpose: purpose), productName: name, quantity: quantity,
                originalText: quantity?.originalLiteral ?? name, notes: "", exclusions: exclusions, removedAt: nil))
            if let within {
                guard let quantity else { throw LedgerError.incompatibleMatch }
                try next.link(contributionID: sourceID, supplyID: within, quantity: quantity, at: at)
            }
            return sourceID
        }
    }

    /// Candidate matching always applies hard exclusions before any ranking.
    public func matchingLines(name: String, quantity: Quantity?, exclusions: [String] = []) -> [ShoppingLine] {
        lines.filter { line in
            (try? requireMatch(name: name, quantity: quantity, exclusions: exclusions, lineID: line.id)) != nil
        }.sorted { $0.originalOrder < $1.originalOrder }
    }

    public func validate() throws {
        try basis.validate(); try ledgerText(title, nonempty: true, maximum: 512)
        guard revision >= 0, basisRevision >= 0, basisRevision <= revision,
              lines.count <= 10_000, contributions.count <= 20_000, allocations.count <= 20_000,
              mealOccurrences.count <= 2_000, importBatches.count <= 2_000, revisions.count <= 100_000 else {
            throw LedgerError.invalid("ledgerSizeOrRevision")
        }
        try uniqueIDs(lines.map(\.id)); try uniqueIDs(contributions.map(\.id)); try uniqueIDs(allocations.map(\.id))
        try uniqueIDs(mealOccurrences.map(\.id)); try uniqueIDs(importBatches.map(\.id)); try uniqueIDs(revisions.map(\.id))
        guard Set(lines.map(\.originalOrder)) == Set(0..<lines.count) else { throw LedgerError.invalid("originalOrder") }
        let lineIDs = Set(lines.map(\.id))
        let mealSources = Dictionary(uniqueKeysWithValues: mealOccurrences.map { ($0.id, Set($0.ingredientContributionIDs)) })
        let batchSources = Dictionary(uniqueKeysWithValues: importBatches.map { ($0.id, Set($0.contributionIDs)) })
        let sources = Dictionary(uniqueKeysWithValues: contributions.map { ($0.id, $0) })
        let receipts = stapleReviews ?? []
        guard receipts.count <= 10_000, Set(receipts.map(\.source)).count == receipts.count,
              receipts.allSatisfy({ $0.source.shopID != id && ($0.newLineID != nil) == ($0.choice == .needed) &&
                  ($0.newLineID.map(lineIDs.contains) ?? true) }) else { throw LedgerError.invalid("stapleReviews") }
        for receipt in receipts {
            if let quantity = receipt.quantity {
                guard receipt.choice == .needed, quantity.amount > .zero else { throw LedgerError.invalid("stapleQuantity") }
                try quantity.validate()
            }
        }
        for line in lines {
            if let approval = line.stapleApproval {
                try ledgerText(approval.purpose, nonempty: true, maximum: 512)
                try ledgerText(approval.branch, nonempty: true, maximum: 512)
                try ledgerDate(approval.approvedAt)
            }
            try ledgerText(line.name, nonempty: true, maximum: 512); try ledgerText(line.notes); try ledgerText(line.aisle, maximum: 512)
            guard line.originalOrder >= 0, (line.handledAt == nil) == (line.handledBy == nil) else { throw LedgerError.invalid("lineState") }
            if let by = line.handledBy { try ledgerText(by, nonempty: true, maximum: 512) }
            try ledgerDate(line.checkedAt); try ledgerDate(line.handledAt); try ledgerDate(line.trashedAt)
        }
        for source in contributions {
            guard lineIDs.contains(source.lineID) else { throw LedgerError.notFound(source.lineID) }
            try ledgerText(source.productName, nonempty: true, maximum: 512); try ledgerText(source.originalText)
            try ledgerText(source.notes); try source.quantity?.validate(); try validateExclusions(source.exclusions)
            _ = try source.capture?.resolvedQuantity()
            try permittedProduct(source.productName, exclusions: source.exclusions); try ledgerDate(source.removedAt)
            switch source.source {
            case .manual: break
            case let .imported(batchID):
                guard batchSources[batchID]?.contains(source.id) == true
                else { throw LedgerError.invalid("importSource") }
            case let .meal(occurrenceID):
                guard mealSources[occurrenceID]?.contains(source.id) == true
                else { throw LedgerError.invalid("mealSource") }
            case let .protectedNeed(purpose): try ledgerText(purpose, nonempty: true, maximum: 512)
            }
        }
        for meal in mealOccurrences {
            if let carryover = meal.carryover {
                try carryover.validate()
                guard carryover.sourceShopID == id, carryover.sourceOccurrenceID != meal.id,
                      mealOccurrences.contains(where: { $0.id == carryover.sourceOccurrenceID }),
                      meal.ingredientContributionIDs.isEmpty, meal.servingGroups.isEmpty,
                      meal.scheduledDay != nil else { throw LedgerError.invalid("physicalCarryover") }
            }
            try ledgerText(meal.title, nonempty: true, maximum: 512); try ledgerText(meal.notes); try validateExclusions(meal.exclusions)
            if let url = meal.sourceURL { try ledgerText(url, maximum: 2048) }
            guard meal.servings > .zero, meal.templateRevision.map({ $0 >= 0 }) ?? true,
                  meal.ingredientContributionIDs.count <= 200 else { throw LedgerError.invalid("mealOccurrence") }
            try uniqueIDs(meal.ingredientContributionIDs); try meal.scheduledDay?.validate(); try ledgerDate(meal.removedAt)
            let validationTemplate = MealTemplate(title: meal.title, servings: meal.servings, notes: meal.notes,
                sourceURL: meal.sourceURL, exclusions: meal.exclusions, servingGroups: meal.servingGroups,
                leadTimeMinutes: meal.leadTimeMinutes, completedSteps: meal.completedSteps, sourceEvidence: meal.sourceEvidence)
            try validationTemplate.validate()
            for sourceID in meal.ingredientContributionIDs {
                guard let source = sources[sourceID], source.source == .meal(occurrenceID: meal.id),
                      (meal.removedAt == nil || source.removedAt != nil) else { throw LedgerError.invalid("mealSource") }
            }
        }
        for batch in importBatches {
            try validatePreview(batch.preview); try ledgerDate(batch.createdAt); try ledgerDate(batch.undoneAt)
            let previewIDs = Set(batch.preview.lines.map(\.id))
            guard batch.id == batch.preview.id, batch.preview.shopID == id,
                  batch.preview.baseRevision < revision,
                  Set(batch.decisions.keys).isSubset(of: previewIDs) else { throw LedgerError.invalid("importBatch") }
            try uniqueIDs(batch.contributionIDs)
            for sourceID in batch.contributionIDs {
                guard let source = sources[sourceID], source.source == .imported(batchID: batch.id),
                      previewIDs.contains(sourceID),
                      (batch.undoneAt == nil || source.removedAt != nil) else { throw LedgerError.invalid("importSource") }
            }
        }
        try validateAllocations(sources: sources)
        // Preserve every per-line arithmetic/overflow check, using indexes for this
        // validation pass only. No cached state can outlive a mutation or decode.
        let membersByLine = Dictionary(grouping: contributions.filter { $0.removedAt == nil }, by: \.lineID)
        let edgesByLine = Dictionary(grouping: allocations) { sources[$0.demandContributionID]?.lineID }
        for line in lines {
            _ = try quantity(for: line, members: membersByLine[line.id] ?? [], edges: edgesByLine[line.id] ?? [])
        }
        var parent: UUID?
        var number = 0
        for entry in revisions {
            number = try increment(number)
            guard entry.number == number, entry.basisRevision >= 0, entry.basisRevision <= basisRevision,
                  entry.parentID == parent else { throw LedgerError.invalid("revisionChain") }
            try ledgerDate(entry.createdAt); try ledgerText(entry.operation, nonempty: true, maximum: 128)
            parent = entry.id
        }
        guard revisions.count == revision, revisions.last.map({ $0.id == revisionID }) ?? (revision == 0)
        else { throw LedgerError.invalid("revisionHead") }
        if let quoteReference {
            guard quoteReference.basisRevision == basisRevision, quoteReference.ledgerRevision == revision else { throw LedgerError.stalePreview }
            try ledgerDate(quoteReference.createdAt); try ledgerText(quoteReference.source)
        }
    }

    /// Internal allowlisted transaction port. Runtime authorization and operation replay are
    /// owned by DinnerPlanningEngine; no public arbitrary workspace replacement is exposed.
    mutating func applyDinnerChanges(_ changes: [DinnerLedgerChange], expectedRevisionID: UUID,
                                    revisionID: UUID, operationID: UUID, at: Date) throws {
        guard self.revisionID == expectedRevisionID else { throw DinnerPlanningError.stalePreview }
        guard !changes.isEmpty, changes.count <= 500 else { throw DinnerPlanningError.invalid("changes") }
        try mutate("dinner:\(operationID.uuidString)", at: at, revisionID: revisionID) { next in
            var touchedMeals = Set<UUID>()
            var adoptedBasis = false
            for change in changes {
                switch change {
                case .choose(let dinner):
                    try dinner.validate()
                    guard touchedMeals.insert(dinner.occurrenceID).inserted,
                          !next.mealOccurrences.contains(where: { $0.id == dinner.occurrenceID }) else { throw DinnerPlanningError.operationConflict }
                    for (index, ingredient) in dinner.template.ingredients.enumerated() {
                        let lineID = next.appendLine(id: dinner.lineIDs[index], name: ingredient.name, notes: ingredient.notes)
                        next.contributions.append(LedgerContribution(id: dinner.contributionIDs[index], lineID: lineID,
                            source: .meal(occurrenceID: dinner.occurrenceID), productName: ingredient.name, quantity: ingredient.quantity,
                            originalText: ingredient.quantity?.originalLiteral ?? ingredient.name, notes: ingredient.notes,
                            exclusions: dinner.template.exclusions + ingredient.exclusions, removedAt: nil))
                    }
                    let template = dinner.template
                    next.mealOccurrences.append(MealOccurrence(id: dinner.occurrenceID, templateID: template.id, templateRevision: template.revision,
                        title: template.title, servings: template.servings, notes: template.notes, sourceURL: template.sourceURL,
                        sourceEvidence: template.sourceEvidence, exclusions: template.exclusions, servingGroups: template.servingGroups, leadTimeMinutes: template.leadTimeMinutes,
                        completedSteps: template.completedSteps, ingredientContributionIDs: dinner.contributionIDs,
                        scheduledDay: dinner.day, isHidden: false, removedAt: nil))
                case .move(let occurrenceID, let day):
                    guard touchedMeals.insert(occurrenceID).inserted else { throw DinnerPlanningError.invalid("duplicateMealChange") }
                    try day?.validate()
                    let index = try next.mealIndex(occurrenceID)
                    guard next.mealOccurrences[index].carryover == nil else { throw DinnerPlanningError.reviewRequired("physicalCarryover") }
                    next.mealOccurrences[index].scheduledDay = day
                case .adjust(let adjustment):
                    guard touchedMeals.insert(adjustment.occurrenceID).inserted else { throw DinnerPlanningError.invalid("duplicateMealChange") }
                    let index = try next.mealIndex(adjustment.occurrenceID)
                    let meal = next.mealOccurrences[index]
                    guard meal.carryover == nil else { throw DinnerPlanningError.reviewRequired("physicalCarryover") }
                    guard Set(adjustment.quantities.map(\.contributionID)).isSubset(of: Set(meal.ingredientContributionIDs)) else { throw DinnerPlanningError.invalid("unrelatedContribution") }
                    for group in meal.servingGroups where group.isProtected {
                        guard adjustment.groups.contains(group) else { throw DinnerPlanningError.reviewRequired("protectedGroup") }
                    }
                    next.mealOccurrences[index].servings = adjustment.servings
                    next.mealOccurrences[index].servingGroups = adjustment.groups
                    for edit in adjustment.quantities {
                        let source = try next.contributionIndex(edit.contributionID)
                        guard next.contributions[source].removedAt == nil else { throw DinnerPlanningError.invalid("removedContribution") }
                        next.contributions[source].quantity = edit.quantity
                    }
                case .remove(let occurrenceID):
                    guard touchedMeals.insert(occurrenceID).inserted else { throw DinnerPlanningError.invalid("duplicateMealChange") }
                    let index = try next.mealIndex(occurrenceID)
                    guard !next.mealOccurrences[index].servingGroups.contains(where: \.isProtected) else { throw DinnerPlanningError.reviewRequired("separateProtectedNeedsBeforeRemoval") }
                    guard next.mealOccurrences[index].carryover == nil else { throw DinnerPlanningError.reviewRequired("physicalCarryover") }
            try next.removeSources(Set(next.mealOccurrences[index].ingredientContributionIDs), at: at)
                    next.mealOccurrences[index].removedAt = at
                case .reserve(let reservation):
                    let lineID = next.appendLine(id: reservation.lineID, name: reservation.name)
                    next.contributions.append(LedgerContribution(id: reservation.contributionID, lineID: lineID,
                        source: .protectedNeed(purpose: reservation.purpose), productName: reservation.name,
                        quantity: reservation.quantity, originalText: reservation.quantity.originalLiteral,
                        notes: "", exclusions: [], removedAt: nil))
                    if let supply = reservation.withinContributionID {
                        try next.link(contributionID: reservation.contributionID, supplyID: supply, quantity: reservation.quantity, at: at)
                        // Linking uses an internal random ID; replace it with the proposal's reserved ID.
                        if let index = next.allocations.firstIndex(where: { $0.kind == .withinExisting && $0.demandContributionID == reservation.contributionID }) {
                            let edge = next.allocations[index]
                            next.allocations[index] = AllocationEdge(id: reservation.allocationID,
                                demandContributionID: edge.demandContributionID, supplyContributionID: edge.supplyContributionID,
                                quantity: edge.quantity, kind: edge.kind)
                        }
                    }
                case .adoptBasis(let basis):
                    guard !adoptedBasis else { throw DinnerPlanningError.invalid("duplicateBasis") }; adoptedBasis = true
                    try basis.validate()
                    if basis != next.basis { next.basis = basis; next.basisRevision = try increment(next.basisRevision) }
                }
            }
        }
    }

    private mutating func mutate<T>(_ operation: String, at: Date, revisionID proposedRevisionID: UUID? = nil, _ action: (inout Self) throws -> T) throws -> T {
        try ledgerDate(at)
        try validate()
        var next = self
        let result = try action(&next)
        next.revision = try increment(next.revision)
        let parent = next.revisions.last?.id
        next.revisionID = proposedRevisionID ?? UUID()
        guard !next.revisions.contains(where: { $0.id == next.revisionID }) else { throw LedgerError.invalid("duplicateRevision") }
        next.revisions.append(LedgerRevision(id: next.revisionID, parentID: parent, number: next.revision,
            basisRevision: next.basisRevision, createdAt: at, operation: operation))
        next.quoteReference = nil
        try next.validate()
        self = next
        return result
    }

    private mutating func appendLine(id: UUID = UUID(), name: String, notes: String = "") -> UUID {
        // validate() requires originalOrder to be exactly 0..<lines.count; lines
        // remain as tombstones when removed. Appending preserves that invariant.
        let order = lines.count
        lines.append(ShoppingLine(id: id, name: name, notes: notes, aisle: "", originalOrder: order,
                                  checkedAt: nil, handledBy: nil, handledAt: nil, trashedAt: nil))
        return id
    }
    private func lineIndex(_ id: UUID) throws -> Int {
        guard let index = lines.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound(id) }; return index
    }
    private func contributionIndex(_ id: UUID) throws -> Int {
        guard let index = contributions.firstIndex(where: { $0.id == id }) else { throw LedgerError.notFound(id) }; return index
    }
    private func mealIndex(_ id: UUID) throws -> Int {
        guard let index = mealOccurrences.firstIndex(where: { $0.id == id && $0.removedAt == nil }) else { throw LedgerError.notFound(id) }
        return index
    }

    private func requireMatch(name: String, quantity: Quantity?, exclusions: [String], lineID: UUID) throws {
        let line = lines[try lineIndex(lineID)]
        guard !line.isTrashed, normalizedProduct(line.name) == normalizedProduct(name) else { throw LedgerError.incompatibleMatch }
        try permittedProduct(line.name, exclusions: exclusions)
        let sources = contributions(forLineID: lineID)
        guard !sources.isEmpty, let quantity else { throw LedgerError.incompatibleMatch }
        for source in sources {
            try permittedProduct(name, exclusions: source.exclusions)
            try permittedProduct(source.productName, exclusions: exclusions)
            guard normalizedProduct(source.productName) == normalizedProduct(name), let existing = source.quantity,
                  try quantity.converted(to: existing.unit) != nil else { throw LedgerError.incompatibleMatch }
        }
    }

    private mutating func link(contributionID: UUID, supplyID: UUID, quantity: Quantity, at: Date) throws {
        let demandIndex = try contributionIndex(contributionID); let supplyIndex = try contributionIndex(supplyID)
        let demand = contributions[demandIndex]; let supply = contributions[supplyIndex]
        guard demand.removedAt == nil, supply.removedAt == nil,
              demand.source.isMeal || demand.source.isProtected, supply.source.canSupplyExistingQuantity,
              let needed = demand.quantity, let amount = try quantity.converted(to: needed.unit),
              amount > .zero, amount <= needed.amount else { throw LedgerError.incompatibleMatch }
        try requireMatch(name: demand.productName, quantity: demand.quantity, exclusions: demand.exclusions, lineID: supply.lineID)
        let oldLineID = demand.lineID
        contributions[demandIndex].lineID = supply.lineID
        allocations.removeAll { $0.kind == .withinExisting && $0.demandContributionID == contributionID }
        allocations.append(AllocationEdge(id: UUID(), demandContributionID: contributionID,
            supplyContributionID: supplyID, quantity: quantity, kind: .withinExisting))
        if oldLineID != supply.lineID && contributions(forLineID: oldLineID).isEmpty {
            lines[try lineIndex(oldLineID)].trashedAt = at
        }
    }

    private mutating func removeSources(_ removed: Set<UUID>, at: Date) throws {
        // If one duplicate source is undone, transfer its reservations to an
        // equal surviving alias. With no alias, the surviving need becomes additive.
        let active = contributions.filter { $0.removedAt == nil }
        let roots = duplicateRoots(for: active)
        for index in allocations.indices where allocations[index].kind == .withinExisting {
            let edge = allocations[index]
            if removed.contains(edge.supplyContributionID), !removed.contains(edge.demandContributionID),
               let original = active.first(where: { $0.id == edge.supplyContributionID }),
               let replacement = active.first(where: {
                   !removed.contains($0.id) && $0.source.canSupplyExistingQuantity && $0.lineID == original.lineID
                       && roots[$0.id] == roots[original.id]
               }) {
                allocations[index].supplyContributionID = replacement.id
            }
        }
        // Retain the remaining equivalence class even if its connecting node is removed.
        let survivors = active.filter { !removed.contains($0.id) }
        let grouped = Dictionary(grouping: survivors) { roots[$0.id] ?? $0.id }
        allocations.removeAll { removed.contains($0.demandContributionID) || removed.contains($0.supplyContributionID) }
        for members in grouped.values where members.count > 1 {
            guard let first = members.first, let quantity = first.quantity else { continue }
            let survivorRoots = duplicateRoots(for: survivors)
            for member in members.dropFirst() where survivorRoots[member.id] != survivorRoots[first.id] {
                allocations.append(AllocationEdge(id: UUID(), demandContributionID: member.id,
                    supplyContributionID: first.id, quantity: quantity, kind: .duplicate))
            }
        }
        for index in contributions.indices where removed.contains(contributions[index].id) { contributions[index].removedAt = at }
        for index in lines.indices where contributions(forLineID: lines[index].id).isEmpty { lines[index].trashedAt = at }
    }

    private func duplicateRoots(for members: [LedgerContribution], edges: [AllocationEdge]? = nil) -> [UUID: UUID] {
        var parent = Dictionary(uniqueKeysWithValues: members.map { ($0.id, $0.id) })
        func root(_ id: UUID) -> UUID {
            var result = id
            while let next = parent[result], next != result { result = next }
            return result
        }
        for edge in edges ?? allocations where edge.kind == .duplicate && parent[edge.demandContributionID] != nil && parent[edge.supplyContributionID] != nil {
            let a = root(edge.demandContributionID), b = root(edge.supplyContributionID)
            if a != b { parent[a] = b }
        }
        for key in Array(parent.keys) { parent[key] = root(key) }
        return parent
    }

    private func validateAllocations(sources: [UUID: LedgerContribution]) throws {
        let active = contributions.filter { $0.removedAt == nil }
        let roots = duplicateRoots(for: active)
        var graph: [UUID: [UUID]] = [:]
        var pairs = Set<String>()
        var demandAmounts: [UUID: Rational] = [:]
        var supplyAmounts: [UUID: Rational] = [:]
        var groupQuantities: [UUID: Quantity] = [:]
        for member in active where member.source.canSupplyExistingQuantity {
            guard let quantity = member.quantity else { continue }
            let root = roots[member.id] ?? member.id
            if let current = groupQuantities[root], let amount = try quantity.converted(to: current.unit) {
                if amount > current.amount { groupQuantities[root] = Quantity(amount: amount, unit: current.unit, originalLiteral: quantity.originalLiteral) }
            } else { groupQuantities[root] = quantity }
        }
        for edge in allocations {
            guard edge.demandContributionID != edge.supplyContributionID,
                  let demand = sources[edge.demandContributionID], let supply = sources[edge.supplyContributionID],
                  demand.removedAt == nil, supply.removedAt == nil, demand.lineID == supply.lineID,
                  normalizedProduct(demand.productName) == normalizedProduct(supply.productName),
                  let needed = demand.quantity, let available = supply.quantity,
                  try needed.converted(to: available.unit) != nil else { throw LedgerError.invalid("allocationReference") }
            try edge.quantity.validate()
            try permittedProduct(supply.productName, exclusions: demand.exclusions)
            try permittedProduct(demand.productName, exclusions: supply.exclusions)
            let pair = "\(edge.kind.rawValue):\(demand.id):\(supply.id)"
            guard pairs.insert(pair).inserted else { throw LedgerError.invalid("duplicateAllocation") }
            graph[demand.id, default: []].append(supply.id)
            switch edge.kind {
            case .duplicate:
                guard demand.source.canSupplyExistingQuantity, supply.source.canSupplyExistingQuantity,
                      try edge.quantity.converted(to: needed.unit) != nil else { throw LedgerError.incompatibleMatch }
            case .withinExisting:
                guard demand.source.isMeal || demand.source.isProtected, supply.source.canSupplyExistingQuantity,
                      let used = try edge.quantity.converted(to: needed.unit), used > .zero,
                      let group = groupQuantities[roots[supply.id] ?? supply.id],
                      let reserved = try edge.quantity.converted(to: group.unit) else { throw LedgerError.incompatibleMatch }
                demandAmounts[demand.id] = try (demandAmounts[demand.id] ?? .zero).adding(used)
                let root = roots[supply.id] ?? supply.id
                supplyAmounts[root] = try (supplyAmounts[root] ?? .zero).adding(reserved)
            }
        }
        for (id, used) in demandAmounts {
            guard let needed = sources[id]?.quantity, used <= needed.amount else { throw LedgerError.allocationExceedsQuantity }
        }
        for (id, used) in supplyAmounts {
            guard let available = groupQuantities[id], used <= available.amount else { throw LedgerError.allocationExceedsQuantity }
        }
        // Iterative DFS bounds stack use even for a corrupt persisted graph.
        var visiting = Set<UUID>(), visited = Set<UUID>()
        for start in graph.keys where !visited.contains(start) {
            var stack: [(UUID, Bool)] = [(start, false)]
            while let (node, exiting) = stack.popLast() {
                if exiting { visiting.remove(node); visited.insert(node); continue }
                if visited.contains(node) { continue }
                guard visiting.insert(node).inserted else { throw LedgerError.invalid("allocationCycle") }
                stack.append((node, true))
                for child in graph[node] ?? [] { stack.append((child, false)) }
            }
        }
    }

    private func validatePreview(_ preview: StagedListImport) throws {
        try ledgerText(preview.originalText, maximum: 262_144)
        guard preview.baseRevision >= 0, preview.lines.count <= 1_000 else { throw LedgerError.invalid("importSize") }
        try uniqueIDs(preview.lines.map(\.id)); try uniqueIDs(preview.lines.map(\.proposedLineID))
        for line in preview.lines {
            try ledgerText(line.originalText); try ledgerText(line.name, nonempty: true, maximum: 512)
            try line.quantity?.validate()
            try validateExclusions(line.exclusions)
            if let capture = line.capture {
                guard line.quantity == (try capture.resolvedQuantity()) else { throw CaptureImportError.conflictingQuantity }
            }
            if let reason = line.unresolvedReason { try ledgerText(reason) }
            guard line.duplicateLineIDs.count <= 11_000 else { throw LedgerError.invalid("duplicateCandidates") }
        }
    }

    private static func parseLine(_ original: String) -> (name: String, quantity: Quantity?, reason: String?) {
        var text = original.trimmingCharacters(in: .whitespaces)
        if text.hasPrefix("- ") || text.hasPrefix("• ") || text.hasPrefix("* ") { text.removeFirst(2) }
        let tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)
        guard tokens.count >= 2, let number = parseAmount(tokens[0]) else {
            return (text, nil, "Review the quantity and unit.")
        }
        var unit: UnitOfMeasure = .count
        var nameStart = 1
        let units: [String: UnitOfMeasure] = ["g": .gram, "gram": .gram, "grams": .gram, "kg": .kilogram,
            "kilogram": .kilogram, "kilograms": .kilogram, "oz": .ounce, "ounce": .ounce, "ounces": .ounce,
            "lb": .pound, "lbs": .pound, "pound": .pound, "pounds": .pound, "ml": .milliliter,
            "milliliter": .milliliter, "milliliters": .milliliter, "l": .liter, "liter": .liter, "liters": .liter,
            "cup": .cup, "cups": .cup, "count": .count, "ct": .count, "each": .count,
            "gramo": .gram, "gramos": .gram, "kilo": .kilogram, "kilos": .kilogram,
            "libra": .pound, "libras": .pound, "litro": .liter, "litros": .liter,
            "taza": .cup, "tazas": .cup, "unidades": .count]
        if let parsed = units[tokens[1].lowercased()] { unit = parsed; nameStart = 2 }
        else if tokens.count > 2 && tokens[1].lowercased() == "fl" && ["oz", "ounce", "ounces"].contains(tokens[2].lowercased()) {
            unit = .fluidOunce; nameStart = 3
        } else if ["tbsp", "tsp", "tablespoon", "tablespoons", "teaspoon", "teaspoons", "dozen", "dozens", "scoop", "scoops", "handful", "handfuls", "pinch", "pinches", "about", "approximately"].contains(tokens[1].lowercased()) {
            return (tokens.dropFirst().joined(separator: " "), nil, "Review the unsupported or approximate unit.")
        }
        let name = tokens.dropFirst(nameStart).joined(separator: " ")
        guard !name.isEmpty else { return (text, nil, "Add the item name.") }
        return (name, Quantity(amount: number, unit: unit, originalLiteral: original), nil)
    }
    private static func parseAmount(_ text: String) -> Rational? {
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let top = Int64(parts[0]), let bottom = Int64(parts[1]) { return try? Rational(top, bottom) }
        return try? Rational(decimal: text)
    }
}

private func normalizedProduct(_ value: String) -> String {
    value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
}
private func ledgerText(_ value: String, nonempty: Bool = false, maximum: Int = 8192) throws {
    guard value.utf8.count <= maximum, !nonempty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
        throw LedgerError.invalid("text")
    }
}
private func ledgerDate(_ date: Date?) throws {
    if let date, !date.timeIntervalSinceReferenceDate.isFinite { throw LedgerError.invalid("date") }
}
private func uniqueIDs(_ ids: [UUID]) throws {
    guard Set(ids).count == ids.count else { throw LedgerError.invalid("duplicateID") }
}
private func increment(_ value: Int) throws -> Int {
    let (result, overflow) = value.addingReportingOverflow(1)
    guard !overflow else { throw DomainError.overflow }; return result
}
private func validateExclusions(_ exclusions: [String]) throws {
    guard exclusions.count <= 100 else { throw LedgerError.invalid("exclusions") }
    for exclusion in exclusions { try ledgerText(exclusion, nonempty: true, maximum: 512) }
}
private func permittedProduct(_ name: String, exclusions: [String]) throws {
    guard !exclusions.isEmpty else { return }
    let words = normalizedProduct(name).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }
    let product = " " + words.joined(separator: " ") + " "
    for exclusion in exclusions {
        let term = normalizedProduct(exclusion).components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
        if !term.isEmpty && product.contains(" " + term + " ") { throw LedgerError.excludedIngredient(exclusion) }
    }
}
