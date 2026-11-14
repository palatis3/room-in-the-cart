import Foundation
import Combine
import CryptoKit
import CoreDomain
import LocalStore

func pTr(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Pickup") }
func pCook(_ key: String, language: String) -> String {
    let code = language.hasPrefix("es") ? "es" : "en"
    let bundle = Bundle.main.path(forResource: code, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
    return bundle.localizedString(forKey: key, value: key, table: "Pickup")
}
func pMoney(_ money: Money) -> String { Decimal(money.minorUnits).dividing(by: 100).formatted(.currency(code: "USD")) }
private extension Decimal { func dividing(by value: Decimal) -> Decimal { self / value } }
func pExclusions(_ values: [String]) -> String {
    var seen = Set<String>()
    return values.filter { seen.insert($0).inserted }.joined(separator: ", ")
}
func pQuantity(_ quantity: Quantity, language: String? = nil) -> String {
    pQuantity(quantity.amount, unit: quantity.unit, language: language)
}
func pQuantity(_ amount: Rational, unit: UnitOfMeasure, language: String? = nil) -> String {
    pQuantity(amount.description, unit: unit, singular: amount == .one, language: language)
}

// Coverage from the shared service can contain exact fractions larger than Int64.
func pQuantity(_ exactAmount: String, unit: UnitOfMeasure, singular: Bool, language: String?) -> String {
    let label = pUnitLabel(unit, singular: singular, language: language)
    return "\(exactAmount) \(label)"
}

func pUnitLabel(_ unit: UnitOfMeasure, singular: Bool, language: String?) -> String {
    let key: String
    if unit == .count {
        key = singular ? "One count unit" : "count"
    } else {
        key = singular ? unit.rawValue : "Quantity plural " + unit.rawValue
    }
    return language.map { pCook(key, language: $0) } ?? pTr(key)
}

enum NextShopDisposition: String, Codable, CaseIterable {
    case keep, accept, handled, dismissed
}

struct NextShopReview: Codable, Equatable {
    let sourceRevision: Int64
    let choices: [UUID: NextShopDisposition]
}

/// The review and the new draft use the same confirmed stock and remaining portions.
struct NextShopMealNeeds: Equatable {
    let urgent: [UrgentMealNeed]
    let meals: [AllocationNeed]
    let unverified: Set<UUID>
}

extension PickupJourney {
    func nextShopMealNeeds(closing: [UUID: NextShopDisposition], at instant: Date) throws -> NextShopMealNeeds {
        let coverage = try carryoverAllocation(at: instant)
        let byID = Dictionary(uniqueKeysWithValues: coverage.demands.map { ($0.id, $0) })
        let currentUrgent = recoveryCurrentUrgent
        let urgentIDs = Set(currentUrgent.map(\.id))
        let urgent = currentUrgent.compactMap { original -> UrgentMealNeed? in
            guard !original.resolved, byID[original.id]?.shortfall != .zero else { return nil }
            var need = original
            if let demand = byID[original.id], let shortfall = demand.shortfall {
                need.required = Quantity(amount: shortfall, unit: demand.unit, originalLiteral: shortfall.description)
            }
            need.carriedFromID = id
            return need
        }
        let handledLines = Set(deferred.filter {
            ["handled", "dismissed"].contains(closing[$0.id]?.rawValue ?? $0.status)
        }.map { $0.line.id })
        // Earlier deferrals may have no active allocation on this pickup.
        var meals = carriedMeals.filter { !handledLines.contains($0.orderLineID) && byID[$0.id] == nil }
        for original in recoveryCurrentAllocationNeeds where !urgentIDs.contains(original.id) && !handledLines.contains(original.orderLineID) {
            guard let demand = byID[original.id], demand.shortfall != .zero else { continue }
            let remaining = demand.shortfall.map { Quantity(amount: $0, unit: demand.unit, originalLiteral: $0.description) }
            meals.append(AllocationNeed(id: original.id, orderLineID: original.orderLineID, name: original.name,
                                        amount: remaining ?? original.amount, priority: original.priority))
        }
        return NextShopMealNeeds(urgent: urgent, meals: meals, unverified: Set(coverage.demands.filter { $0.shortfall == nil }.map(\.id)))
    }
}

struct DeferredPickupNeed: Codable, Equatable, Identifiable {
    let id: UUID
    let sourceShopID: UUID
    let line: BasketLine
    var status: String = "review"
}
struct UrgentMealNeed: Codable, Equatable, Identifiable {
    let id: UUID
    let food: String
    let meal: String
    var required: Quantity
    let available: Quantity
    let due: Date?
    let confirmedAt: Date
    var repair: String = ""
    var resolved: Bool = false
    var carriedFromID: UUID? = nil
}
struct PickupRepair: Codable, Equatable, Identifiable {
    let id: UUID
    let needID: UUID
    let instruction: String
    let createdAt: Date
    let extraTripAgreed: Bool
    let repeatMealAgreed: Bool
    let elapsedMinutes: Int?
    let due: Date?
    var timingConfirmed: Bool {
        guard let elapsedMinutes, let due else { return false }
        return createdAt.addingTimeInterval(TimeInterval(elapsedMinutes * 60)) <= due
    }
}
struct PickupCookShareEvent: Codable, Equatable, Identifiable {
    let id: UUID
    let noteID: UUID
    let occurredAt: Date
    let action: HandoffActionKind
    let destination: String?
}
struct PickupCookNote: Codable, Equatable, Identifiable {
    let id: UUID
    let text: String
    let language: String
    let createdAt: Date
    let revision: Int64
    var sentTo: String?
    var sentAt: Date?
    var reviewedHandoff: CookHandoffReview?
}
struct PickupOfferAction: Codable, Equatable, Identifiable {
    let id: UUID
    let offerID: UUID
    let kind: HandoffActionKind
    let occurredAt: Date
}
struct PickupOffer: Codable, Equatable, Identifiable {
    let id: UUID
    let lineID: UUID
    let replacement: String
    let required: Quantity
    let remainingOriginal: Quantity
    let price: CostEvidence
    let ceiling: Money?
    let deadline: RetailerDeadline
    let fallback: String
    var householdPreference: String
    var retailerResponse: String
    var evaluation: PickupOfferEvaluationEvidence? = nil
}
struct PickupRecoveryPreparation: Codable, Equatable {
    let requiredLeadMinutes: Int?
    let advanceComplete: Bool
}
struct PickupNeedDetail: Codable, Equatable, Identifiable {
    let id: UUID
    let mealName: String
    let exclusions: [String]
    var scheduledDay: MealDay?
    let leadTimeMinutes: Int?
    let completedSteps: [String]
    var sourceContributionID: UUID? = nil
    var sourceOccurrenceID: UUID? = nil
    var sourceGroupID: UUID? = nil
    var sourceLedgerRevisionID: UUID? = nil
    var due: Date? = nil
    var preparationNotes: [String]? = nil
    var recoveryPreparation: PickupRecoveryPreparation? = nil
    var sourceURL: String? = nil
}
struct EarlierCheckoutQuote: Codable, Equatable, Identifiable {
    let id: Int64 // The durable pickup revision that held this quote.
    let basketRevisionID: UUID
    let quote: CheckoutQuote
    let cap: CheckoutCap?
}

struct PickupJourney: Codable, Equatable, Identifiable {
    let id: UUID
    var version = 1
    var revision: Int64 = 0
    var basket: BasketPlan?
    var context: CheckoutContext?
    var cap: CheckoutCap?
    var quote: CheckoutQuote?
    var quotedRevisionID: UUID?
    var basketPriceTerms: PickupPricingTerms?
    var earlierQuotes: [EarlierCheckoutQuote] = []
    var frozenQuotes: [UUID: CheckoutQuote] = [:]
    // A missing entry also covers older snapshots whose cap was never recorded.
    var frozenCaps: [String: CheckoutCap]?
    var pickup: PickupLedger?
    var needs: [AllocationNeed] = []
    var plannedNeeds: [AllocationNeed] = []
    var needDetails: [PickupNeedDetail] = []
    var mealSource: PickupCheckoutMealSource?
    var mealRecovery: PickupMealRecoveryHistory?
    var ledgerBasis: ShopBasis?
    var ledgerSourceRevisionID: UUID?
    var ledgerPackSelections: [LedgerPackSelection] = []
    var originShopID: UUID?
    var nextShopReview: NextShopReview?
    var carriedMeals: [AllocationNeed] = []
    var urgent: [UrgentMealNeed] = []
    var stockLots: [ConfirmedStockLot] = []
    var stockNeeds: [StockNeed] = []
    var awayCarryovers: [AwayCarryoverRecord] = []
    var repairs: [PickupRepair] = []
    var deferred: [DeferredPickupNeed] = []
    var flexible: Set<UUID> = []
    var proposals: [BasketProposal] = []
    var undoneProposals: Set<UUID> = []
    var offers: [PickupOffer] = []
    var offerActions: [PickupOfferAction] = []
    var notes: [PickupCookNote] = []
    var recipientSends: [RecipientSend]?
    var cookShareEvents: [PickupCookShareEvent] = []
    var settlement = SettlementLedger()
    var feedback: PickupFeedback?
    var closedAt: Date?
    var savedAt: Date
}

// New optional local projections can be absent in an earlier version-one document.
// Required identity/version/date still fail closed, and validate checks all links.
extension PickupJourney {
    func unfilledOffers(at instant: Date) -> [PickupOffer] {
        guard closedAt == nil else { return [] }
        let observed = Set(pickup?.receipts.filter { $0.receivedAt <= instant }.map(\.key.orderLineID) ?? [])
        let activeLines = Set(retailerOrderLines.map(\.id))
        return offers.filter { activeLines.contains($0.lineID) && !observed.contains($0.lineID) }
    }

    func nextUnfilledOffer(at date: Date) -> PickupOffer? {
        let outstanding = unfilledOffers(at: date).sorted { $0.deadline.cutoff < $1.deadline.cutoff }
        return outstanding.first { date < $0.deadline.cutoff } ?? outstanding.last
    }

    private enum CodingKeys: String, CodingKey {
        case recipientSends, mealSource, mealRecovery, earlierQuotes, basketPriceTerms
        case awayCarryovers, id, savedAt, version, revision, basket, context, cap, quote, quotedRevisionID, frozenQuotes, frozenCaps, pickup, needs, plannedNeeds, needDetails, ledgerBasis, ledgerSourceRevisionID, ledgerPackSelections, originShopID, nextShopReview, carriedMeals, urgent, stockLots, stockNeeds, repairs, deferred, flexible, proposals, undoneProposals, offers, offerActions, notes, cookShareEvents, settlement, closedAt, feedback
    }
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(id: try container.decode(UUID.self, forKey: .id), savedAt: try container.decode(Date.self, forKey: .savedAt))
        version = try container.decode(Int.self, forKey: .version)
        revision = try container.decode(Int64.self, forKey: .revision)
        basket = try container.decodeIfPresent(BasketPlan.self, forKey: .basket)
        context = try container.decodeIfPresent(CheckoutContext.self, forKey: .context)
        cap = try container.decodeIfPresent(CheckoutCap.self, forKey: .cap)
        quote = try container.decodeIfPresent(CheckoutQuote.self, forKey: .quote)
        quotedRevisionID = try container.decodeIfPresent(UUID.self, forKey: .quotedRevisionID)
        basketPriceTerms = try container.decodeIfPresent(PickupPricingTerms.self, forKey: .basketPriceTerms)
        earlierQuotes = try container.decodeIfPresent([EarlierCheckoutQuote].self, forKey: .earlierQuotes) ?? []
        if let decoded = try container.decodeIfPresent([UUID: CheckoutQuote].self, forKey: .frozenQuotes) { frozenQuotes = decoded }
        frozenCaps = try container.decodeIfPresent([String: CheckoutCap].self, forKey: .frozenCaps)
        pickup = try container.decodeIfPresent(PickupLedger.self, forKey: .pickup)
        if let decoded = try container.decodeIfPresent([AllocationNeed].self, forKey: .needs) { needs = decoded }
        if let decoded = try container.decodeIfPresent([AllocationNeed].self, forKey: .plannedNeeds) { plannedNeeds = decoded }
        if let decoded = try container.decodeIfPresent([PickupNeedDetail].self, forKey: .needDetails) { needDetails = decoded }
        ledgerBasis = try container.decodeIfPresent(ShopBasis.self, forKey: .ledgerBasis)
        ledgerSourceRevisionID = try container.decodeIfPresent(UUID.self, forKey: .ledgerSourceRevisionID)
        ledgerPackSelections = try container.decodeIfPresent([LedgerPackSelection].self, forKey: .ledgerPackSelections) ?? []
        originShopID = try container.decodeIfPresent(UUID.self, forKey: .originShopID)
        nextShopReview = try container.decodeIfPresent(NextShopReview.self, forKey: .nextShopReview)
        if let decoded = try container.decodeIfPresent([AllocationNeed].self, forKey: .carriedMeals) { carriedMeals = decoded }
        if let decoded = try container.decodeIfPresent([UrgentMealNeed].self, forKey: .urgent) { urgent = decoded }
        if let decoded = try container.decodeIfPresent([ConfirmedStockLot].self, forKey: .stockLots) { stockLots = decoded }
        if let decoded = try container.decodeIfPresent([StockNeed].self, forKey: .stockNeeds) { stockNeeds = decoded }
        awayCarryovers = try container.decodeIfPresent([AwayCarryoverRecord].self, forKey: .awayCarryovers) ?? []
        if let decoded = try container.decodeIfPresent([PickupRepair].self, forKey: .repairs) { repairs = decoded }
        if let decoded = try container.decodeIfPresent([DeferredPickupNeed].self, forKey: .deferred) { deferred = decoded }
        if let decoded = try container.decodeIfPresent(Set<UUID>.self, forKey: .flexible) { flexible = decoded }
        if let decoded = try container.decodeIfPresent([BasketProposal].self, forKey: .proposals) { proposals = decoded }
        if let decoded = try container.decodeIfPresent(Set<UUID>.self, forKey: .undoneProposals) { undoneProposals = decoded }
        if let decoded = try container.decodeIfPresent([PickupOffer].self, forKey: .offers) { offers = decoded }
        if let decoded = try container.decodeIfPresent([PickupOfferAction].self, forKey: .offerActions) { offerActions = decoded }
        if let decoded = try container.decodeIfPresent([PickupCookNote].self, forKey: .notes) { notes = decoded }
        recipientSends = try container.decodeIfPresent([RecipientSend].self, forKey: .recipientSends)
        mealSource = try container.decodeIfPresent(PickupCheckoutMealSource.self, forKey: .mealSource)
        mealRecovery = try container.decodeIfPresent(PickupMealRecoveryHistory.self, forKey: .mealRecovery)
        if let decoded = try container.decodeIfPresent([PickupCookShareEvent].self, forKey: .cookShareEvents) { cookShareEvents = decoded }
        if let decoded = try container.decodeIfPresent(SettlementLedger.self, forKey: .settlement) { settlement = decoded }
        feedback = try container.decodeIfPresent(PickupFeedback.self, forKey: .feedback)
        closedAt = try container.decodeIfPresent(Date.self, forKey: .closedAt)
        if let basket, !basket.amendments.isEmpty, let pickup, let branch = context?.branchID,
           let original = basket.reportedOrderLines,
           Dictionary(uniqueKeysWithValues: pickup.orderLines.map { ($0.id, $0) }) ==
            Dictionary(uniqueKeysWithValues: original.map { ($0.id, PickupOrderLine(id: $0.id, branchID: branch, name: $0.name, ordered: $0.quantity)) }) {
            self.pickup = try pickup.withOrderLines(basket.physicalOrderLines(branch: branch))
        }

    }
}

private enum PickupModelError: Error { case missing, invalid, pending, unsupported }

struct PickupPersistenceLocation {
    let databaseURL: URL
    let resetTestDatabase: Bool

    /// An injected database is authoritative, including in UI-test processes.
    /// Resolve the default support location only when no database was supplied.
    static func resolve(databaseURL: URL?, arguments: [String],
                        applicationSupport: () throws -> URL) rethrows -> PickupPersistenceLocation {
        if let databaseURL { return PickupPersistenceLocation(databaseURL: databaseURL, resetTestDatabase: false) }
        let base = try applicationSupport()
        #if DEBUG
        if arguments.contains("--ui-testing") {
            return PickupPersistenceLocation(databaseURL: base.appendingPathComponent("UITestWorkspace", isDirectory: true).appendingPathComponent("pickup.sqlite"),
                resetTestDatabase: arguments.contains("--reset-test-workspace"))
        }
        #endif
        return PickupPersistenceLocation(databaseURL: base.appendingPathComponent("RoomInTheCart", isDirectory: true).appendingPathComponent("pickup.sqlite"), resetTestDatabase: false)
    }
}

/// One durable document per journey. Candidate data is published only after SQLite
/// commits; retry writes the identical encoded candidate and original event IDs.
@MainActor final class PickupModel: ObservableObject {
    @Published private(set) var journeys: [PickupJourney] = []
    @Published var selectedID: UUID?
    @Published private(set) var ready = false
    @Published private(set) var saving = false
    @Published private(set) var hasPendingSave = false
    @Published var error: String?
    private var store: ComparisonStore?
    private let databaseURL: URL?
    private let clock: () -> Date
    private let launchArguments: [String]
    private var opening = false
    private var storeRevisions: [UUID: Int64] = [:]
    private weak var cookLedger: LedgerModel?
    private struct Pending {
        let value: PickupJourney
        let payload: Data
        let requiredRevisions: [UUID: Int64]
        let selectsPickup: Bool
        let recoveryOperationID: UUID?
        let authorize: (@MainActor () -> Bool)?
    }
    private var pending: Pending?
    // Ephemeral review receipts allow an exact double tap to succeed without another write.
    var appliedStockReviewRevisions: [UUID: Int64] = [:]
    init(store: ComparisonStore? = nil, databaseURL: URL? = nil, clock: @escaping () -> Date = Date.init,
         launchArguments: [String] = ProcessInfo.processInfo.arguments) {
        self.store = store; self.databaseURL = databaseURL; self.clock = clock; self.launchArguments = launchArguments
    }
    var sourceWorkspaceID: UUID? { store?.workspaceID }
    var recoveryLedger: LedgerModel? { cookLedger }
    func saveRecoveryCandidate(_ value: PickupJourney, operationID: UUID,
                               authorize: @escaping @MainActor () -> Bool) async -> Bool {
        await save(value, selecting: false, recoveryOperationID: operationID, authorize: authorize)
    }
    func retryRecoveryCandidate(operationID: UUID, matches: (PickupJourney) -> Bool) async -> Bool {
        guard let pending, pending.recoveryOperationID == operationID, matches(pending.value) else { return false }
        return await retrySave()
    }
    var journey: PickupJourney? { journeys.first { $0.id == selectedID } }
    var cookJourney: PickupJourney? {
        guard let journey else { return nil }
        guard journey.ledgerSourceRevisionID != nil, let cookLedger else { return journey }
        guard cookLedger.ready, !cookLedger.saving, !cookLedger.hasPendingSave else { return nil }
        guard let shop = cookLedger.workspace.shops.first(where: { $0.id == journey.id }) else { return journey }
        return journey.withCurrentMealDates(from: shop)
    }
    func bindCookLedger(_ ledger: LedgerModel) {
        cookLedger = ledger
    }
    var cookLedgerRevisions: AnyPublisher<Int64, Never> {
        cookLedger?.$revision.removeDuplicates().dropFirst().eraseToAnyPublisher() ?? Empty().eraseToAnyPublisher()
    }
    var reminderJourneys: [PickupJourney] {
        let previousTrips = Set(journeys.compactMap(\.originShopID))
        return journeys.filter { !previousTrips.contains($0.id) }
    }
    func resumableJourney(for shopID: UUID?) -> PickupJourney? {
        let target = shopID ?? selectedID
        return reminderJourneys.first { $0.id == target && $0.closedAt == nil }
    }
    var hasCurrentBasketStockBasis: Bool {
        guard let value = journey else { return true }
        return LedgerPackStockReview.basketBasisIsCurrent(value, pickupWorkspaceID: sourceWorkspaceID)
    }
    var result: CheckoutResult? {
        guard hasCurrentBasketStockBasis, let value = journey, let quote = value.quote,
              value.basket?.amendments.isEmpty != false, value.quotedRevisionID == value.basket?.current.id else { return nil }
        return try? CheckoutEngine.evaluate(quote, cap: value.cap)
    }
    var allocation: StockAllocationResult? {
        guard let value = journey else { return nil }
        return try? value.carryoverAllocation(at: clock())
    }
    var stockAllocation: StockAllocationResult? { allocation }
    var stockReviewDate: Date { clock() }
    func load() async {
        guard !ready, !opening else { return }
        opening = true; defer { opening = false }
        do {
            if store == nil {
                let location = try PickupPersistenceLocation.resolve(databaseURL: databaseURL, arguments: launchArguments) {
                    try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                }
                let directory = location.databaseURL.deletingLastPathComponent()
                try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                #if os(iOS)
                try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: directory.path)
                #endif
                if location.resetTestDatabase {
                    for suffix in ["", "-wal", "-shm"] {
                        let file = URL(fileURLWithPath: location.databaseURL.path + suffix)
                        if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                    }
                }
                store = try ComparisonStore(url: location.databaseURL)
            }
            guard let store else { throw PickupModelError.missing }
            let records = try await store.list()
            let decoded = try records.map { record -> PickupJourney in
                let value = try JSONDecoder().decode(PickupJourney.self, from: record.payload)
                guard value.feedback == nil || value.eligibleForFeedback, value.version == 1, value.id == record.id else { throw PickupModelError.unsupported }
                try Self.validate(value)
                return value
            }
            storeRevisions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.revision) })
            journeys = decoded
            if !decoded.contains(where: { $0.id == selectedID }) { selectedID = decoded.first?.id }
            ready = true; error = nil
        } catch { self.error = pTr("Could not open saved pickups. Retry; existing records have not been replaced.") }
    }
    func archiveSnapshot() async throws -> (workspaceID: UUID, records: [SavedComparison]) {
        if !ready { await load() }
        guard ready, let store else { throw PickupModelError.missing }
        return (store.workspaceID, try await store.list())
    }
    func archiveListing() async throws -> (workspaceID: UUID, listing: ComparisonListing) {
        if store == nil { await load() }
        guard let store else { throw PickupModelError.missing }
        return (store.workspaceID, try await store.listing())
    }
    func archiveTombstones() async throws -> [ComparisonTombstone] {
        if store == nil { await load() }
        guard let store else { throw PickupModelError.missing }
        return try await store.tombstones()
    }
    func deleteArchived(id: UUID, expectedRevision: Int64, operationID: UUID) async throws {
        if !ready { await load() }
        guard ready, !saving, pending == nil, let store else { throw PickupModelError.pending }
        saving = true; defer { saving = false }
        _ = try await store.erase(id: id, expectedRevision: expectedRevision, operationID: operationID, at: clock())
        // Once erasure commits, never leave its content visible even if refreshing
        // another record fails. An exact operation retry returns the same tombstone.
        storeRevisions[id] = nil
        journeys.removeAll { $0.id == id }
        if selectedID == id { selectedID = journeys.first?.id }
        do {
            let records = try await store.list()
            let refreshed = try records.map { record -> PickupJourney in
                let value = try JSONDecoder().decode(PickupJourney.self, from: record.payload)
                guard value.id == record.id else { throw PickupModelError.invalid }
                try Self.validate(value)
                return value
            }
            storeRevisions = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0.revision) })
            journeys = refreshed
            if selectedID == nil { selectedID = refreshed.first?.id }
            error = nil
        } catch {
            self.error = pTr("The record was deleted, but remaining records could not be refreshed. Retry opening.")
            ready = false
            throw error
        }
    }
    @discardableResult func start(from lines: [BasketLine], shopID: UUID, context: CheckoutContext, cap: CheckoutCap? = nil, plannedNeeds: [AllocationNeed] = [], ledgerBasis: ShopBasis? = nil,
                                  ledgerSourceRevisionID: UUID? = nil, needDetails: [PickupNeedDetail] = [], ledgerPackSelections: [LedgerPackSelection] = [], mealSource: PickupCheckoutMealSource? = nil) async -> Bool {
        if !ready { await load() }
        guard ready, !saving, pending == nil else { return false }
        if journeys.contains(where: { $0.id == shopID }) { selectedID = shopID; return true }
        do {
            let basket = try BasketPlan(id: shopID, revisionID: UUID(), lines: lines, createdAt: clock())
            var value = PickupJourney(id: shopID, savedAt: clock())
            value.basketPriceTerms = .from(context, scope: PickupPricingTerms.scope(cap: cap, basis: ledgerBasis))
            value.basket = basket; value.context = context; value.cap = cap; value.plannedNeeds = plannedNeeds
            value.ledgerBasis = ledgerBasis; value.ledgerSourceRevisionID = ledgerSourceRevisionID; value.needDetails = needDetails
            value.ledgerPackSelections = ledgerPackSelections; value.mealSource = mealSource
            return await save(value)
        } catch { self.error = pTr("Check the amounts and units. Your saved pickup has not changed."); return false }
    }
    @discardableResult private func save(_ value: PickupJourney, reviewing source: UUID? = nil, selecting: Bool = true,
        recoveryOperationID: UUID? = nil, authorize: (@MainActor () -> Bool)? = nil) async -> Bool {
        guard ready, !saving, pending == nil, authorize?() != false else { return false }
        do {
            let instant = clock()
            var candidate = value; candidate.savedAt = instant
            let previous = journeys.first(where: { $0.id == value.id })
            guard candidate.revision == (previous?.revision ?? 0) else {
                error = pTr("The saved pickup changed or was removed. Reopen its current details before trying again.")
                return false
            }
            if let previous, let quote = previous.quote, let basketRevisionID = previous.quotedRevisionID,
               previous.quote != candidate.quote || previous.cap != candidate.cap || previous.quotedRevisionID != candidate.quotedRevisionID {
                candidate.earlierQuotes.append(EarlierCheckoutQuote(id: previous.revision, basketRevisionID: basketRevisionID,
                                                                    quote: quote, cap: previous.cap))
            }
            try candidate.synchronizeRecoveryOutside(at: instant)
            let increment = candidate.revision.addingReportingOverflow(1)
            guard !increment.overflow else { throw PickupModelError.invalid }
            candidate.revision = increment.partialValue
            try Self.validate(candidate)
            let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
            var revisions = [value.id: storeRevisions[value.id] ?? 0]
            if let source {
                guard let revision = storeRevisions[source] else { throw PickupModelError.missing }
                revisions[source] = revision
            }
            pending = Pending(value: candidate, payload: try encoder.encode(candidate), requiredRevisions: revisions, selectsPickup: selecting,
                recoveryOperationID: recoveryOperationID, authorize: authorize)
            hasPendingSave = true
            return await retrySave()
        } catch { self.error = pTr("Could not prepare this change. Your saved pickup has not changed."); return false }
    }
    @discardableResult func retrySave() async -> Bool {
        guard !saving, let pending, let store else { return false }
        guard pending.authorize?() != false else {
            if pending.recoveryOperationID == nil {
                discardPending()
                error = pTr("Feedback was not saved. Check your pickup and feedback setting before trying again.")
            } else {
                error = recoveryText("Your access or selection changed. Discard this pending recovery and review it again.")
            }
            return false
        }
        saving = true; defer { saving = false }
        do {
            let saved = try await store.save(id: pending.value.id, title: "Pickup", payload: pending.payload,
                                             savedAt: pending.value.savedAt, requiring: pending.requiredRevisions)
            storeRevisions[saved.id] = saved.revision
            journeys.removeAll { $0.id == pending.value.id }; journeys.insert(pending.value, at: 0)
            if pending.selectsPickup { selectedID = pending.value.id }
            self.pending = nil; hasPendingSave = false; error = nil; return true
        } catch ComparisonStoreError.staleRevision, ComparisonStoreError.erased {
            self.pending = nil; hasPendingSave = false
            await reloadAfterStaleRevision()
            return false
        } catch { self.error = pTr("Not saved. Retry this change before continuing; your last saved pickup is intact."); return false }
    }
    private func reloadAfterStaleRevision() async {
        ready = false
        journeys = []; storeRevisions = [:]
        await load()
        error = pTr("The saved pickup changed or was removed. Reopen its current details before trying again.")
    }
    func discardPending() { guard !saving else { return }; pending = nil; hasPendingSave = false; error = nil }
    func recordFeedback(_ feedback: PickupFeedback?, shopID: UUID, revision: Int64,
                        consent: LocalPickupFeedbackConsent) async -> Bool {
        guard let workspaceID = sourceWorkspaceID, var current = journey else { return false }
        let currentConsent = consent.authorization(for: workspaceID)
        let authorized: @MainActor () -> Bool = { [weak self] in
            guard let self, self.sourceWorkspaceID == workspaceID, let selected = self.journey,
                  selected.id == shopID, selected.revision == revision, selected.eligibleForFeedback else { return false }
            return feedback == nil || currentConsent()
        }
        current.feedback = feedback
        return await save(current, selecting: false, authorize: authorized)
    }

    @discardableResult func change(_ edit: (inout PickupJourney) throws -> Void) async -> Bool {
        guard var value = journey, !saving, pending == nil else { return false }
        do { try edit(&value); return await save(value) }
        catch { self.error = pTr("Check the amounts and units. Your saved pickup has not changed."); return false }
    }
    @discardableResult func setQuote(_ quote: CheckoutQuote, cap: CheckoutCap?, reviewed draft: PickupCheckoutDraft? = nil) async -> Bool {
        guard hasCurrentBasketStockBasis else { error = ledgerText("Confirmed stock changed. Review ingredient needs and whole packs before continuing checkout."); return false }
        return await change { value in
            guard let basket = value.basket, basket.phase == .draft else { throw PickupModelError.invalid }
            if let draft {
                let expected = try draft.submission(for: value, workspaceID: sourceWorkspaceID)
                guard expected.quote == quote, expected.cap == cap else { throw PickupCheckoutDraftError.staleSource }
            }
            _ = try CheckoutEngine.evaluate(quote, cap: cap)
            if value.basketPriceTerms == nil, value.quote == nil, let source = value.context {
                value.basketPriceTerms = .from(source, scope: PickupPricingTerms.scope(cap: value.cap, basis: value.ledgerBasis))
            }
            value.quote = quote; value.context = quote.context; value.cap = cap; value.quotedRevisionID = basket.current.id
        }
    }
    func deferralPreview(_ ids: Set<UUID>) throws -> (BasketProposal, CheckoutComparison) {
        guard let value = journey, let basket = value.basket, basket.phase == .draft, let quote = value.quote,
              value.quotedRevisionID == basket.current.id, ids.isSubset(of: value.flexible), !ids.isEmpty else { throw PickupModelError.invalid }
        let proposal = BasketProposal(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: ids.map { .remove($0) })
        let changed = try repriced(quote, removing: ids)
        return (proposal, try CheckoutEngine.compare(before: quote, after: changed, cap: value.cap))
    }
    private func repriced(_ quote: CheckoutQuote, removing ids: Set<UUID>) throws -> CheckoutQuote {
        guard case let .components(lines, complete, fees, discounts, tax, deposits) = quote.pricing else { throw PickupModelError.invalid }
        return CheckoutQuote(scope: quote.scope, context: quote.context, pricing: .components(lines: lines.filter { !ids.contains($0.id) }, lineSetComplete: complete, fees: fees, discounts: discounts, tax: tax, deposits: deposits))
    }
    @discardableResult func applyDeferral(_ proposal: BasketProposal) async -> Bool {
        await change { value in
            guard var basket = value.basket, let quote = value.quote else { throw PickupModelError.missing }
            if value.proposals.contains(where: { $0.id == proposal.id }) { return }
            guard basket.phase == .draft else { throw PickupModelError.invalid }
            let ids = Set(proposal.changes.compactMap { change -> UUID? in if case let .remove(id) = change { return id }; return nil })
            guard ids.isSubset(of: value.flexible), !value.plannedNeeds.contains(where: { ids.contains($0.orderLineID) && $0.priority == .protected }) else { throw PickupModelError.invalid }
            value.carriedMeals += value.plannedNeeds.filter { ids.contains($0.orderLineID) }
            value.plannedNeeds.removeAll { ids.contains($0.orderLineID) }
            let removed = basket.current.lines.filter { ids.contains($0.id) }
            try basket.apply(proposal, at: clock()); value.basket = basket
            value.quote = try repriced(quote, removing: ids); value.quotedRevisionID = basket.current.id
            value.proposals.append(proposal)
            value.deferred += removed.map { DeferredPickupNeed(id: UUID(), sourceShopID: value.id, line: $0) }
        }
    }
    @discardableResult func undoDeferral(_ proposal: BasketProposal) async -> Bool {
        await change { value in
            guard var basket = value.basket else { throw PickupModelError.missing }
            guard basket.phase == .draft else { throw PickupModelError.invalid }
            try basket.undo(operationID: UUID(), proposalID: proposal.id, expectedRevision: basket.current.id, revisionID: UUID(), at: clock())
            value.basket = basket; value.quote = nil; value.quotedRevisionID = nil; value.undoneProposals.insert(proposal.id)
            let restored = Set(basket.current.lines.map(\.id)); value.deferred.removeAll { restored.contains($0.line.id) }
            value.plannedNeeds += value.carriedMeals.filter { restored.contains($0.orderLineID) }
            value.carriedMeals.removeAll { restored.contains($0.orderLineID) }
        }
    }
    @discardableResult func freeze(reviewing reviewed: PickupJourney? = nil) async -> Bool {
        guard hasCurrentBasketStockBasis else { error = ledgerText("Confirmed stock changed. Review ingredient needs and whole packs before continuing checkout."); return false }
        return await change { value in
            if let reviewed, value.id != reviewed.id || value.revision != reviewed.revision {
                throw PickupModelError.invalid
            }
            guard var basket = value.basket, !basket.current.lines.isEmpty, let quote = value.quote, value.quotedRevisionID == basket.current.id else { throw PickupModelError.missing }
            if basket.snapshots.contains(where: { $0.revision.id == basket.current.id }) { return }
            let snapshot = try basket.freeze(snapshotID: UUID(), expectedRevision: basket.current.id, at: clock())
            value.frozenQuotes[snapshot.id] = quote
            if let cap = value.cap {
                if value.frozenCaps == nil { value.frozenCaps = [:] }
                value.frozenCaps?[snapshot.id.uuidString] = cap
            }
            value.basket = basket
        }
    }
    @discardableResult func reopenDraft(reviewing reviewed: HandoffSnapshot? = nil) async -> Bool {
        guard let snapshot = currentFrozenSnapshot(reviewing: reviewed) else { return false }
        return await change { value in
            guard var basket = value.basket, basket.phase == .frozen, basket.id == snapshot.basketID,
                  basket.current.id == snapshot.revision.id, !basket.current.lines.isEmpty else { throw PickupModelError.invalid }
            let revision = BasketProposal(id: UUID(), baseRevisionID: basket.current.id, revisionID: UUID(), changes: basket.current.lines.map { .upsert($0) })
            try basket.apply(revision, at: clock())
            value.basket = basket; value.quote = nil; value.quotedRevisionID = nil
        }
    }
    var frozenSnapshot: HandoffSnapshot? {
        guard let basket = journey?.basket else { return nil }
        return basket.snapshots.last { $0.revision.id == basket.current.id }
    }
    private func currentFrozenSnapshot(reviewing reviewed: HandoffSnapshot?) -> HandoffSnapshot? {
        let current = frozenSnapshot
        if let reviewed, reviewed != current {
            error = pTr("The saved pickup changed or was removed. Reopen its current details before trying again.")
            return nil
        }
        return current
    }
    @discardableResult func recordHandoff(_ kind: HandoffActionKind, snapshot: HandoffSnapshot? = nil, destination: String? = nil) async -> Bool {
        guard let snapshot = snapshot ?? frozenSnapshot,
              var value = journeys.first(where: { $0.id == snapshot.basketID }),
              var basket = value.basket, basket.snapshots.contains(snapshot) else { return false }
        if [.prepared, .copyAttempted, .shareOpened].contains(kind) {
            guard frozenSnapshot?.id == snapshot.id else { return false }
            guard hasCurrentBasketStockBasis else {
                error = ledgerText("Confirmed stock changed. Review ingredient needs and whole packs before continuing checkout.")
                return false
            }
        }
        do {
            try basket.recordHandoff(HandoffAction(id: UUID(), snapshotID: snapshot.id, kind: kind, occurredAt: clock(), destination: destination))
            value.basket = basket
            return await save(value, selecting: false)
        } catch {
            self.error = pTr("Could not prepare this change. Your saved pickup has not changed.")
            return false
        }
    }
    @discardableResult func recordCookShare(_ kind: HandoffActionKind, copy: HandoffCopy, destination: String? = nil) async -> Bool {
        guard copy.channel == .cook, var value = journeys.first(where: { $0.id == copy.shopID }),
              let note = value.notes.first(where: { $0.id == copy.versionID }),
              HandoffCopy.cook(note, shopID: value.id) == copy else { return false }
        if kind == .shareOpened, copy.shopID != selectedID { return false }
        value.cookShareEvents.append(PickupCookShareEvent(id: UUID(), noteID: note.id, occurredAt: clock(), action: kind, destination: destination))
        return await save(value, selecting: false)
    }
    @discardableResult func reportPlaced(reviewing reviewed: HandoffSnapshot? = nil, by localActorID: UUID? = nil,
                                         acknowledgingChangedStock: Bool = false) async -> Bool {
        guard let snapshot = currentFrozenSnapshot(reviewing: reviewed) else { return false }
        if let existing = journey?.basket?.placements.first { return existing.snapshotID == snapshot.id }
        guard hasCurrentBasketStockBasis || acknowledgingChangedStock else {
            error = ledgerText("Confirmed stock changed. If you already placed this frozen order with the retailer, record that original order explicitly."); return false
        }
        guard !snapshot.revision.lines.isEmpty else { return false }
        return await change { value in
            guard var basket = value.basket, basket.id == snapshot.basketID,
                  basket.current.id == snapshot.revision.id, basket.placements.isEmpty else { throw PickupModelError.invalid }
            if let frozenQuote = value.frozenQuotes[snapshot.id] {
                // Older versions allowed checkout terms to change after this handoff was frozen.
                if let frozenCap = value.frozenCaps?[snapshot.id.uuidString] {
                    value.cap = frozenCap
                } else if value.quote != frozenQuote || value.context != frozenQuote.context {
                    value.cap = nil
                }
                value.context = frozenQuote.context
                value.quote = frozenQuote
                value.quotedRevisionID = snapshot.revision.id
            }
            guard let context = value.context else { throw PickupModelError.invalid }
            let placement = ReportedPlacement(id: UUID(), intentID: UUID(), snapshotID: snapshot.id,
                                              reportedAt: clock(), reportedByLocalActorID: localActorID)
            try basket.reportPlaced(placement); value.basket = basket
            value.needs = value.plannedNeeds
            value.pickup = try PickupLedger(orderID: placement.id, orderLines: snapshot.revision.lines.map { PickupOrderLine(id: $0.id, branchID: context.branchID, name: $0.name, ordered: $0.quantity) })
        }
    }
    @discardableResult func confirmRetailerAmendment(_ review: PickupAmendmentReview,
            currentActor: @escaping @MainActor () -> UUID?) async -> Bool {
        let base = review.base, event = review.event
        let authorized: @MainActor () -> Bool = { [weak self] in
            guard let self, let journey = self.journey else { return false }
            return self.ready && self.sourceWorkspaceID == base.workspaceID && journey.id == base.shopID &&
                journey.basket?.placements.first?.id == base.placementID && currentActor() == base.actorID &&
                event.recordedByLocalActorID == base.actorID && event.placementID == base.placementID
        }
        guard authorized(), var value = journey, var basket = value.basket, let pickup = value.pickup,
              let branch = value.context?.branchID else { return false }
        if let saved = basket.amendments.first(where: { $0.id == event.id }) {
            guard saved == event else { error = pTr("This confirmation has different details. Reopen the placed order."); return false }
            return true
        }
        guard value.revision == base.revision, basket.amendments.last?.id == base.predecessor,
              basket.effectiveOrderLines == base.lines else {
            error = pTr("The order changed. Reopen the placed order and review the retailer confirmation again.")
            return false
        }
        if hasPendingSave {
            return await retryRecoveryCandidate(operationID: event.id) { $0.basket?.amendments.last == event }
        }
        do {
            try review.validate(in: basket, now: clock())
            try basket.confirmAmendment(event)
            value.basket = basket
            value.pickup = try pickup.withOrderLines(basket.physicalOrderLines(branch: branch))
            return await save(value, selecting: false, recoveryOperationID: event.id, authorize: authorized)
        } catch {
            self.error = pTr("Check the confirmed lines, retailer reference and confirmation time.")
            return false
        }
    }

    @discardableResult func receive(_ fragment: ReceiptFragment, usable: UsableObservation?) async -> Bool {
        guard ready, !saving, pending == nil else { return false }
        if let usable, usable.receipt != fragment.key {
            error = pTr("Check the amounts and units. Your saved pickup has not changed.")
            return false
        }
        let receiptExists = journey?.pickup?.receipts.contains(fragment) == true
        let observationExists = usable.map { journey?.pickup?.usableObservations.contains($0) == true } ?? true
        if receiptExists && observationExists {
            error = nil
            return true
        }
        let observedAt = clock()
        guard fragment.receivedAt <= observedAt, usable.map({ $0.confirmedAt <= observedAt }) ?? true else {
            error = pTr("Record an arrival or usable confirmation only after it has happened.")
            return false
        }
        return await change { value in
            guard var pickup = value.pickup else { throw PickupModelError.missing }
            try pickup.receive(fragment)
            if let usable { try pickup.confirmUsable(usable) }
            value.pickup = pickup
        }
    }
    @discardableResult func confirmUsable(_ observation: UsableObservation) async -> Bool {
        let observedAt = clock()
        let alreadyRecorded = journey?.pickup?.usableObservations.contains(observation) == true
        guard alreadyRecorded || (observation.confirmedAt <= observedAt &&
            journey?.pickup?.receipts.first(where: { $0.key == observation.receipt }).map { $0.receivedAt <= observedAt } == true) else {
            error = pTr("Record an arrival or usable confirmation only after it has happened.")
            return false
        }
        return await change { value in
            guard var pickup = value.pickup else { throw PickupModelError.missing }
            try pickup.confirmUsable(observation); value.pickup = pickup
        }
    }
    @discardableResult func addUrgent(_ need: UrgentMealNeed) async -> Bool {
        if !ready { await load() }
        guard ready, !saving, pending == nil else { return false }
        if let original = journeys.first(where: { $0.urgent.contains { $0.id == need.id && $0.carriedFromID == nil } }) {
            guard original.urgent.contains(need) else { error = pTr("This saved operation already has different content. Review it before trying again."); return false }
            saving = true
            defer { saving = false }
            do {
                guard let store, let revision = storeRevisions[original.id],
                      try await store.load(id: original.id)?.revision == revision else {
                    await reloadAfterStaleRevision()
                    return false
                }
            } catch {
                self.error = pTr("Could not open saved pickups. Retry; existing records have not been replaced.")
                return false
            }
            selectedID = original.id
            error = nil
            return true
        }
        var value: PickupJourney
        if let current = journey, current.basket == nil, current.closedAt == nil {
            value = current
        } else {
            value = PickupJourney(id: PickupCheckoutMealSource.identity("urgent-meal-plan", [need.id]), savedAt: clock())
        }
        value.urgent.append(need)
        value.stockLots.append(ConfirmedStockLot(id: need.id, foodID: need.id, name: need.food, usable: need.available, confirmedAt: need.confirmedAt))
        value.stockNeeds.append(StockNeed(id: need.id, foodID: need.id, name: need.meal, amount: need.required, priority: .required))
        do { _ = try ConfirmedStockAllocator.allocate(lots: value.stockLots, needs: value.stockNeeds) }
        catch { self.error = pTr("Check the confirmed food amounts and matching units."); return false }
        return await save(value)
    }
    @discardableResult func saveStockLot(_ lot: ConfirmedStockLot, in journeyID: UUID,
                                         replacing original: ConfirmedStockLot? = nil,
                                         carriedFrom priorLot: ConfirmedStockLot? = nil,
                                         createIfEmpty: Bool = false) async -> Bool {
        if !ready { await load() }
        var candidate = journey
        if createIfEmpty, ready, journeys.isEmpty, original == nil, priorLot == nil {
            candidate = PickupJourney(id: journeyID, savedAt: clock())
        }
        guard let current = candidate, current.id == journeyID, !saving, pending == nil else { return false }
        do {
            let updated = try PickupStockReviewEngine.candidate(lot, current: current, replacing: original,
                carriedFrom: priorLot, previous: journeys.first { $0.id == current.originShopID }, at: clock())
            if current.stockLots.first(where: { $0.id == lot.id }) == lot { return true }
            return await save(updated, reviewing: priorLot == nil ? nil : current.originShopID)
        } catch {
            self.error = pTr((error as? PickupStockReviewError) == .stale
                ? "Review the saved batch again before changing it." : "Check the confirmed food amounts and matching units.")
            return false
        }
    }
    @discardableResult func settle(_ entry: SettlementEntry) async -> Bool {
        guard ready, var value = journey, !saving, pending == nil else { return false }
        do {
            guard value.pickup != nil else { throw PickupModelError.invalid }
            guard try value.settlement.append(entry) else {
                // Another window or Records can change or erase the pickup after this model loads.
                saving = true
                defer { saving = false }
                guard let store, let expected = storeRevisions[value.id],
                      try await store.load(id: value.id)?.revision == expected else {
                    await reloadAfterStaleRevision()
                    return false
                }
                error = nil
                return true
            }
            guard entry.occurredAt <= clock() else {
                error = pTr("Choose the date the financial evidence was observed.")
                return false
            }
            return await save(value)
        } catch {
            self.error = pTr("Check the amounts and units. Your saved pickup has not changed.")
            return false
        }
    }
    static func validate(_ value: PickupJourney) throws {
        guard value.feedback == nil || value.eligibleForFeedback, value.version == 1, value.revision >= 0, value.savedAt.timeIntervalSinceReferenceDate.isFinite,
              value.basket != nil || !value.urgent.isEmpty || value.stockLots.contains(where: { $0.id == $0.foodID && $0.source != .manual }),
              value.basket == nil || value.basket?.id == value.id,
              Set(value.urgent.map(\.id)).count == value.urgent.count,
              Set(value.notes.map(\.id)).count == value.notes.count,
              Set(value.repairs.map(\.id)).count == value.repairs.count,
              Set(value.deferred.map(\.id)).count == value.deferred.count else { throw PickupModelError.invalid }
        try value.validateRecipientSends()
        try value.mealSource?.validate()
        if let history = value.mealRecovery {
            try history.validate()
            try value.validateRecoveryRawBasis(history)
        }
        try value.validateAwayCarryovers()
        try value.ledgerBasis?.validate()
        guard value.ledgerPackSelections.count <= 10_000,
              Set(value.ledgerPackSelections.map(\.lineID)).count == value.ledgerPackSelections.count else { throw PickupModelError.invalid }
        let noPurchaseLineIDs = Set(value.ledgerPackSelections.filter(\.isNoPurchase).map(\.lineID))
        for selection in value.ledgerPackSelections {
            try selection.validate()
            guard selection.shopID == value.id, selection.shopRevisionID == value.ledgerSourceRevisionID,
                  (noPurchaseLineIDs.contains(selection.lineID) || value.basket?.revisions.contains(where: { revision in revision.lines.contains(where: { $0.id == selection.lineID }) }) == true) else { throw PickupModelError.invalid }
        }
        guard value.originShopID != value.id, Set(value.needDetails.map(\.id)).count == value.needDetails.count else { throw PickupModelError.invalid }
        if let review = value.nextShopReview {
            guard value.originShopID != nil, review.sourceRevision >= 0,
                  review.choices.values.allSatisfy({ $0 != .keep }) else { throw PickupModelError.invalid }
        }
        for detail in value.needDetails {
            let hasMealProvenance = detail.sourceOccurrenceID != nil || detail.sourceGroupID != nil || detail.sourceLedgerRevisionID != nil
            if hasMealProvenance {
                guard detail.sourceContributionID != nil, detail.sourceOccurrenceID != nil, detail.sourceLedgerRevisionID != nil else { throw PickupModelError.invalid }
            }
            try detail.scheduledDay?.validate()
            guard detail.due.map({ $0.timeIntervalSince1970.isFinite }) ?? true else { throw PickupModelError.invalid }
            guard [detail.leadTimeMinutes, detail.recoveryPreparation?.requiredLeadMinutes]
                .compactMap({ $0 }).allSatisfy({ (0...525_600).contains($0) }) else { throw PickupModelError.invalid }
        }
        let plannedLineIDs = Set(value.basket?.current.lines.map(\.id) ?? []).union(noPurchaseLineIDs)
        guard Set(value.plannedNeeds.map(\.id)).count == value.plannedNeeds.count,
              value.plannedNeeds.allSatisfy({ plannedLineIDs.contains($0.orderLineID) }) else { throw PickupModelError.invalid }
        _ = try ConfirmedStockAllocator.allocate(lots: [], needs: value.plannedNeeds.map { StockNeed(id: $0.id, foodID: $0.orderLineID, name: $0.name, amount: $0.amount, priority: $0.priority) })
        if let pickup = value.pickup {
            guard let basket = value.basket, let placement = basket.placements.first,
                  pickup.orderID == placement.id, let branch = value.context?.branchID,
                  Dictionary(uniqueKeysWithValues: pickup.orderLines.map { ($0.id, $0) }) ==
                    Dictionary(uniqueKeysWithValues: basket.physicalOrderLines(branch: branch).map { ($0.id, $0) }) else { throw PickupModelError.invalid }
            let actualLineIDs = Set(pickup.orderLines.map(\.id))
            guard value.needs.allSatisfy({ actualLineIDs.contains($0.orderLineID) || noPurchaseLineIDs.contains($0.orderLineID) }) else { throw PickupModelError.invalid }
            _ = try pickup.allocate(value.needs.filter { actualLineIDs.contains($0.orderLineID) })
        } else {
            guard value.needs.isEmpty, value.settlement.entries.isEmpty, value.basket?.placements.isEmpty != false else { throw PickupModelError.invalid }
        }
        let basketRevisionIDs = Set(value.basket?.revisions.map(\.id) ?? [])
        if let caps = value.frozenCaps {
            let snapshots = Set(value.basket?.snapshots.map(\.id) ?? [])
            for (key, cap) in caps {
                guard let id = UUID(uuidString: key), id.uuidString == key, snapshots.contains(id),
                      let quote = value.frozenQuotes[id] else { throw PickupModelError.invalid }
                _ = try CheckoutEngine.evaluate(quote, cap: cap)
            }
        }
        var previousRevision: Int64 = -1
        for earlier in value.earlierQuotes {
            guard earlier.id > previousRevision, earlier.id < value.revision, basketRevisionIDs.contains(earlier.basketRevisionID)
            else { throw PickupModelError.invalid }
            _ = try CheckoutEngine.evaluate(earlier.quote, cap: earlier.cap)
            previousRevision = earlier.id
        }
        if let quote = value.quote {
            guard let revisionID = value.quotedRevisionID,
                  value.basket?.revisions.contains(where: { $0.id == revisionID }) == true else { throw PickupModelError.invalid }
            _ = try CheckoutEngine.evaluate(quote, cap: value.cap)
        } else if value.quotedRevisionID != nil { throw PickupModelError.invalid }
        for need in value.urgent {
            guard !need.food.isEmpty, !need.meal.isEmpty, need.confirmedAt.timeIntervalSinceReferenceDate.isFinite,
                  need.due?.timeIntervalSinceReferenceDate.isFinite != false else { throw PickupModelError.invalid }
            _ = try ConfirmedStockAllocator.allocate(lots: [ConfirmedStockLot(id: need.id, foodID: need.id, name: need.food, usable: need.available, confirmedAt: need.confirmedAt)], needs: [StockNeed(id: need.id, foodID: need.id, name: need.meal, amount: need.required, priority: .required)])
        }
        _ = try ConfirmedStockAllocator.allocate(lots: value.stockLots, needs: value.stockNeeds)
        guard value.cookShareEvents.allSatisfy({ event in value.notes.contains { $0.id == event.noteID } }),
              value.offerActions.allSatisfy({ event in value.offers.contains { $0.id == event.offerID } }) else { throw PickupModelError.invalid }
        _ = try value.settlement.summary()
    }
    private func nextDraftID(for source: UUID) -> UUID {
        var bytes = Array(SHA256.hash(data: Data(("room-in-the-cart/next-shop/" + source.uuidString).utf8)).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80
        bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
                           bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }

    @discardableResult func startNextShop(accept ids: Set<UUID>, closing: [UUID: NextShopDisposition] = [:],
                                          sourceID: UUID? = nil, sourceRevision: Int64? = nil,
                                          reviewedMeals: NextShopMealNeeds? = nil) async -> Bool {
        guard let previous = journey, sourceID == nil || sourceID == previous.id,
              sourceRevision == nil || sourceRevision == previous.revision else {
            error = pTr("Reopen the next-shop review to use the current pickup.")
            return false
        }
        let reviewable = Set(previous.deferred.filter { $0.status == "review" }.map(\.id))
        guard ids.isSubset(of: Set(previous.deferred.map(\.id))), Set(closing.keys).isSubset(of: reviewable),
              ids.isDisjoint(with: closing.keys), closing.values.allSatisfy({ $0 == .handled || $0 == .dismissed }) else {
            error = pTr("Reopen the next-shop review to use the current pickup.")
            return false
        }
        var choices = closing
        for id in ids where reviewable.contains(id) { choices[id] = .accept }
        let review = NextShopReview(sourceRevision: previous.revision, choices: choices)
        if let existing = journeys.first(where: { $0.originShopID == previous.id }) {
            if sourceRevision != nil, existing.nextShopReview != review {
                error = pTr("A next-shop draft already exists. Open it to review its saved choices.")
                return false
            }
            selectedID = existing.id
            return true
        }
        let accepted = previous.deferred.filter { ids.contains($0.id) && $0.status == "review" }
        do {
            let newID = nextDraftID(for: previous.id)
            let lines = accepted.map { BasketLine(id: UUID(), name: $0.line.name, quantity: $0.line.quantity, expectedCost: .unknown(reason: pTr("Recheck the price for this shop")), itemExclusions: $0.line.itemExclusions ?? []) }
            var next = PickupJourney(id: newID, savedAt: clock())
            next.originShopID = previous.id
            next.nextShopReview = review
            next.basket = try BasketPlan(id: newID, revisionID: UUID(), lines: lines, createdAt: clock())
            next.deferred = previous.deferred.filter { !ids.contains($0.id) && $0.status == "review" }.map { need in
                DeferredPickupNeed(id: need.id, sourceShopID: need.sourceShopID,
                                   line: BasketLine(id: need.line.id, name: need.line.name, quantity: need.line.quantity,
                                                    expectedCost: .unknown(reason: pTr("Recheck the price for this shop")), itemExclusions: need.line.itemExclusions ?? []),
                                   status: closing[need.id]?.rawValue ?? "review")
            }
            let remaining = try previous.nextShopMealNeeds(closing: closing, at: clock())
            guard reviewedMeals == nil || reviewedMeals == remaining else {
                error = pTr("Reopen the next-shop review to use the current pickup.")
                return false
            }
            next.urgent = remaining.urgent
            next.carriedMeals = remaining.meals
            next.stockNeeds = next.urgent.map { need in
                StockNeed(id: need.id, foodID: need.id, name: need.meal, amount: need.required, priority: .required)
            }
            let carriedIDs = Set(next.carriedMeals.map(\.id) + next.stockNeeds.map(\.id))
            next.needDetails = previous.recoveryCurrentDetails.filter { carriedIDs.contains($0.id) }
            return await save(next, reviewing: previous.id)
        } catch { self.error = pTr("Could not prepare this change. Your saved pickup has not changed."); return false }
    }
}
