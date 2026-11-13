import Foundation
import HouseholdClient

/// Entry parsing and intent construction only. Totals, allocation and source
/// permission remain server decisions. No v1 completeness projection is made.
struct TrackingAmountEntry: Equatable {
    var unknown = true
    var numerator = ""
    var denominator = "1"
    var unit: SharedDemandUnit = .count
    var preserved: SharedDemandQuantity?
    init() {}
    init(_ quantity: SharedDemandQuantity?) {
        guard let quantity else { return }
        unknown = false; numerator = String(quantity.amount.numerator); denominator = String(quantity.amount.denominator)
        unit = quantity.unit; preserved = quantity
    }
    func value() throws -> SharedDemandQuantity? {
        if unknown { return nil }
        guard let n = Int64(numerator), let d = Int64(denominator), n > 0, d > 0 else { throw ClientError.configuration }
        var a = n, b = d
        while b != 0 { (a, b) = (b, a % b) }
        let value = SharedDemandQuantity(amount: try .init(numerator: n / a, denominator: d / a), unit: unit,
            originalLiteral: denominator == "1" ? numerator : numerator + "/" + denominator)
        try value.validate()
        if let preserved, preserved.amount == value.amount, preserved.unit == value.unit { return preserved }
        return value
    }
}
struct TrackingPackEntry: Identifiable, Equatable {
    let id: SharedDemandID
    let name: String
    var lineUnit: SharedDemandUnit = .count
    var usable = TrackingAmountEntry()
    var acceptUnresolved = false
    var confirmExistingSources = false
    var includeForUndo = true
    var fixedUsable: SharedDemandQuantity?
    func review() throws -> SharedDemandPackReview {
        .init(lineId: id, usablePerPack: try fixedUsable ?? usable.value(), acceptUnresolved: acceptUnresolved)
    }
}
struct TrackingFixedConversionEntry: Equatable {
    var enabled = false
    var target: SharedDemandUnit = .gram
    var numerator = ""
    var denominator = "1"
    var note = ""
    func apply(to original: SharedDemandQuantity?) throws -> SharedDemandQuantity? {
        guard enabled else { return original }
        guard var value = original, value.confirmedConversion == nil,
              Self.dimension(value.unit) != Self.dimension(target), !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.configuration }
        var rate = TrackingAmountEntry(); rate.unknown = false; rate.numerator = numerator; rate.denominator = denominator
        guard let amount = try rate.value()?.amount else { throw ClientError.configuration }
        value.confirmedConversion = .init(sourceUnit: value.unit, targetUnit: target, targetAmountPerSourceUnit: amount,
            sourceNote: note, confirmedAt: ISO8601DateFormatter().string(from: Date()))
        try value.validate(); return value
    }
    static func dimension(_ unit: SharedDemandUnit) -> Int {
        switch unit { case .count: 0; case .gram, .kilogram, .ounce, .pound: 1; case .milliliter, .liter, .fluidOunce, .cup: 2 }
    }
}
struct TrackingFactEntry: Identifiable, Equatable {
    let fact: SharedTrackingFact
    var id: SharedDemandID { fact.id }
    var lineID: SharedDemandID?
    var productConfirmed = false
    var conversion = TrackingFixedConversionEntry()
    var requestAmount = TrackingAmountEntry()
    var productName: String
    init(fact: SharedTrackingFact, lineID: SharedDemandID? = nil, productName: String? = nil) {
        self.fact = fact; self.lineID = lineID; self.productName = productName ?? fact.originalText
        requestAmount = .init(fact.quantity)
    }
    func quantity() throws -> SharedDemandQuantity? {
        if case .request = fact.source { return try requestAmount.value() }
        return try conversion.apply(to: fact.quantity)
    }
}
struct TrackingManualEntry: Identifiable, Equatable {
    let id: SharedDemandID
    init(id: SharedDemandID = SharedDemandID()) { self.id = id }
    var lineID: SharedDemandID?
    var name = ""
    var original = ""
    var amount = TrackingAmountEntry()
    var productConfirmed = false
    var exclusions = ""
    var contains = ""
    var enabled = false
}
struct TrackingShopEditorContext: Identifiable, Equatable {
    let id = UUID()
    let shop: ShopperShop
    let candidate: ShopperShopCandidate
    var mealEdit: SharedDemandMealEdit? = nil
}
struct TrackingRequestContext: Identifiable, Equatable {
    let id = UUID()
    let sourceID = SharedDemandID()
    let reviewed: SharedRequestDecisionReview
    let acceptOverage: Bool
    let acceptUnknown: Bool
    var action: SharedDemandAction {
        .request(.init(requestId: .init(UUID(uuidString: reviewed.request.id)!),
            previewId: .init(UUID(uuidString: reviewed.preview.previewId)!),
            acceptOverage: acceptOverage, acceptUnknown: acceptUnknown))
    }
    func validate(shop: ShopperShop) throws {
        guard reviewed.shop == shop, UUID(uuidString: reviewed.request.id) != nil,
              UUID(uuidString: reviewed.preview.previewId) != nil,
              reviewed.preview.requestRevision == reviewed.request.revision,
              reviewed.preview.shopRevision == shop.shopRevision,
              reviewed.preview.authorityEpoch == shop.authorityEpoch,
              reviewed.preview.choice == reviewed.decision.choice,
              reviewed.request.shopId == shop.shopId,
              !reviewed.preview.requiresOverageAcceptance || acceptOverage,
              !reviewed.preview.requiresUnknownAcceptance || acceptUnknown else { throw ClientError.cancelled }
    }
    var fixedNeeded: SharedDemandQuantity? {
        if case .add(_, _, let evidence) = reviewed.decision, let evidence { return try? TrackingFlowDraft.quantity(evidence.needed) }; return nil
    }
    var target: ShopperBasketLine? {
        switch reviewed.decision {
        case .add(let line, _, _): line
        case .link(let id, _): reviewed.shop.lines.first { $0.lineId == id }
        default: nil
        }
    }
    var basket: [ShopperBasketLine] {
        if case .add(let line, _, _) = reviewed.decision { return reviewed.shop.lines + [line] }
        return reviewed.shop.lines
    }
}

struct TrackingFlowDraft: Equatable {
    var packs: [TrackingPackEntry] = []
    // Tombstoned graph lines may return in a whole-operation inverse even
    // when they no longer occur in today's basket. These entries are never
    // offered as ordinary manual/binding input or sent by an ordinary review.
    var historicalUndoPacks: [TrackingPackEntry] = []
    var manuals = [TrackingManualEntry()]
    // Preserve the first-entry editing surface for existing callers.
    var manual: TrackingManualEntry {
        get { manuals[0] }
        set { manuals[0] = newValue }
    }
    var facts: [TrackingFactEntry] = []
    var mealChanges: TrackingPartialMealDraft?
    var requestAmount = TrackingAmountEntry()
    var requestMatched = false
    var confirmBasketLabels = false
    var requestLineUnit: SharedDemandUnit = .count
    var rebindFactID: SharedDemandID?
    var rebindName = ""
    var rebindUnit: SharedDemandUnit = .count
    var rebindPacks = 1
    var rebindPrice = ""
    var rebindFeeEligible = true
    var rebindUsable = TrackingAmountEntry()
    var rebindUnresolved = false
    var rebindConfirmed = false

    init() {}
    init(page: SharedTrackingPage, shop: ShopperShop, request: TrackingRequestContext? = nil, edited: ShopperShopCandidate? = nil, actionSources: SharedTrackingActionSources? = nil, mealSources: SharedTrackingMealSources? = nil) throws {
        guard page.shopId.string == shop.shopId, page.shopRevision == shop.shopRevision,
              page.authorityEpoch == shop.authorityEpoch else { throw ClientError.cancelled }
        try request?.validate(shop: shop)
        if let mealSources {
            guard request == nil, actionSources == nil else { throw ClientError.configuration }
            mealChanges = try .init(page: page, catalog: mealSources)
        }
        let basket = request?.basket ?? edited?.lines ?? shop.lines
        packs = try basket.map { row in
            guard let id = UUID(uuidString: row.lineId) else { throw ClientError.invalidResponse }
            var entry = TrackingPackEntry(id: .init(id), name: row.originalItem)
            entry.lineUnit = (page.state?.graph ?? page.projection?.state.graph)?.lines.first { $0.id.uuid == id }?.unit ?? .count
            if let previous = page.state?.packReviews.first(where: { $0.lineId.uuid == id }) { entry.usable = .init(previous.usablePerPack) }
            entry.includeForUndo = (page.state?.graph ?? page.projection?.state.graph)?.lines.contains { $0.id.uuid == id && $0.trashedAt == nil } == true
            return entry
        }
        let currentBasketIDs = Set(packs.map(\.id))
        let graph = page.state?.graph ?? page.projection?.state.graph
        historicalUndoPacks = (graph?.lines ?? []).filter { !currentBasketIDs.contains($0.id) }.map { line in
            var entry = TrackingPackEntry(id: line.id, name: line.name)
            entry.lineUnit = line.unit; entry.includeForUndo = false
            if let previous = page.state?.packReviews.first(where: { $0.lineId == line.id }) {
                entry.usable = .init(previous.usablePerPack)
            }
            return entry
        }
        if let request, case .add(let line, _, let evidence) = request.reviewed.decision, let evidence,
           let index = packs.firstIndex(where: { $0.id.string == line.lineId }) {
            packs[index].fixedUsable = try Self.quantity(evidence.usablePerPack)
            requestLineUnit = try Self.quantity(evidence.needed).unit
        }
        manuals = packs.map { pack in
            var entry = TrackingManualEntry(); entry.lineID = pack.id; return entry
        }
        if manuals.isEmpty { manuals = [TrackingManualEntry()] }
        if page.status == .legacy {
            if let actionSources { facts = actionSources.sources.map { TrackingFactEntry(fact: $0.fact, lineID: $0.fact.requiredLineId, productName: $0.productName) } }
            else { facts = (page.state?.catalog ?? []).map { TrackingFactEntry(fact: $0, lineID: $0.requiredLineId) } }
        }
    }
    func reviewLineIDs(page: SharedTrackingPage, request: TrackingRequestContext?) -> Set<SharedDemandID> {
        let graph = page.state?.graph ?? page.projection?.state.graph
        let retiring = Set(mealChanges?.catalog.retirementCandidates ?? [])
        var tracked = Set(graph?.lines.filter { line in
            line.trashedAt == nil && (retiring.isEmpty || graph?.contributions.contains {
                $0.lineId == line.id && $0.removedAt == nil && !retiring.contains($0.id)
            } == true)
        }.map(\.id) ?? [])
        for manual in manuals where manual.enabled { if let id = manual.lineID { tracked.insert(id) } }
        for fact in facts { if let id = fact.lineID { tracked.insert(id) } }
        for row in mealChanges?.rows ?? [] where row.canBind { if let id = row.lineID { tracked.insert(id) } }
        if let id = request?.target.flatMap({ UUID(uuidString: $0.lineId) }) { tracked.insert(.init(id)) }
        return tracked
    }
    func packReviews() throws -> [SharedDemandPackReview] { try packs.map { try $0.review() } }
    /// The service derives which lines an inverse restores. The user supplies
    /// explicit pack evidence for that resulting set, without reviving a line
    /// locally or treating its old food commitments as available supply.
    func undoPackReviews() throws -> [SharedDemandPackReview] {
        let selected = (packs + historicalUndoPacks).filter(\.includeForUndo)
        guard Set(selected.map(\.id)).count == selected.count else { throw ClientError.configuration }
        return try selected.map { entry in
            let review = try entry.review()
            guard review.usablePerPack != nil || review.acceptUnresolved else { throw ClientError.configuration }
            return review
        }
    }
    func intent(page: SharedTrackingPage, shop: ShopperShop, request: TrackingRequestContext? = nil,
                edited: ShopperShopCandidate? = nil, mealEdit: SharedDemandMealEdit? = nil, actionSources: SharedTrackingActionSources? = nil) throws -> SharedTrackingIntentKind {
        guard page.shopId.string == shop.shopId, page.shopRevision == shop.shopRevision,
              page.authorityEpoch == shop.authorityEpoch else { throw ClientError.cancelled }
        let tracked = reviewLineIDs(page: page, request: request)
        let packs = try self.packs.filter { tracked.contains($0.id) }.map { try $0.review() }
        if page.status == .reviewRequired {
            guard request == nil, edited == nil, !manuals.contains(where: \.enabled), facts.isEmpty else { throw ClientError.configuration }
            return .recover(packs: packs)
        }
        guard let state = page.state else { throw ClientError.invalidResponse }
        let basket = request?.basket ?? edited?.lines ?? shop.lines
        var additions: [SharedDemandContribution] = []
        let retiring = Set(mealChanges?.catalog.retirementCandidates ?? [])
        for manual in manuals where manual.enabled {
            guard manual.productConfirmed, let id = manual.lineID,
                  basket.contains(where: { $0.lineId == id.string }),
                  !manual.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !manual.original.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.configuration }
            // An explicit identity confirmation may use an existing product key;
            // never create a shared identity just because two labels are equal.
            let active = state.graph.contributions.filter { $0.lineId == id && $0.removedAt == nil && !retiring.contains($0.id) }
            guard active.allSatisfy({ $0.productKey != nil }) || self.packs.first(where: { $0.id == id })?.confirmExistingSources == true else { throw ClientError.configuration }
            additions.append(.init(id: manual.id, lineId: id, source: .manual,
                productKey: active.compactMap(\.productKey).first ?? "food.\(id.string)",
                productName: manual.name, originalText: manual.original, quantity: try manual.amount.value(),
                exclusions: Self.tags(manual.exclusions), contains: Self.tags(manual.contains)))
        }
        var clarifyingProtected: [SharedDemandID] = []
        for pack in self.packs where pack.confirmExistingSources {
            let active = state.graph.contributions.filter { $0.lineId == pack.id && $0.removedAt == nil && !retiring.contains($0.id) }
            let key = active.compactMap(\.productKey).first ?? "food.\(pack.id.string)"
            for var source in active where source.productKey == nil {
                source.productKey = key; additions.append(source)
                if case .reservation = source.source { clarifyingProtected.append(source.id) }
            }
        }
        for original in facts {
            var entry = original
            if let request, case .request(let id, _) = entry.fact.source, id.string == request.reviewed.request.id {
                entry.productConfirmed = requestMatched; entry.requestAmount = request.fixedNeeded.map(TrackingAmountEntry.init) ?? requestAmount
                entry.productName = request.reviewed.request.originalItem
            }
            guard page.status == .legacy, entry.productConfirmed, let id = entry.lineID,
                  entry.fact.requiredLineId == nil || entry.fact.requiredLineId == id,
                  basket.contains(where: { $0.lineId == id.string }) else { throw ClientError.configuration }
            let tags = entry.fact.sourceExclusions.flatMap { restriction -> [String] in
                if case .mapped(let tags, _) = restriction.resolution { return tags }; return []
            }
            additions.append(.init(id: entry.fact.id, lineId: id, source: entry.fact.source,
                productKey: "food.\(id.string)", productName: entry.productName,
                originalText: entry.fact.originalText, quantity: try entry.quantity(),
                sourceExclusions: entry.fact.sourceExclusions.isEmpty ? nil : entry.fact.sourceExclusions,
                exclusions: Array(Set(tags)).sorted(), contains: []))
        }
        if page.status == .legacy { guard facts.map(\.fact) == (actionSources?.sources.map(\.fact) ?? state.catalog) else { throw ClientError.configuration } }
        let action: SharedDemandAction
        if let request {
            try request.validate(shop: shop)
            guard requestMatched, let target = request.target,
                  let lineID = UUID(uuidString: target.lineId) else { throw ClientError.configuration }
            let id = SharedDemandID(lineID)
            let active = state.graph.contributions.filter { $0.lineId == id && $0.removedAt == nil && !retiring.contains($0.id) }
            guard active.allSatisfy({ $0.productKey != nil }) || self.packs.first(where: { $0.id == id })?.confirmExistingSources == true else { throw ClientError.configuration }
            var quantity = try requestAmount.value()
            if case .add(_, _, let evidence) = request.reviewed.decision, let evidence {
                quantity = try Self.quantity(evidence.needed)
                guard let pack = packs.first(where: { $0.lineId == id }), pack.usablePerPack == (try Self.quantity(evidence.usablePerPack)) else { throw ClientError.configuration }
            }
            if state.graph.revision > 0 { additions.append(.init(id: request.sourceID, lineId: id,
                source: .request(requestId: .init(UUID(uuidString: request.reviewed.request.id)!), appliedRequestRevision: request.reviewed.preview.requestRevision),
                productKey: active.compactMap(\.productKey).first ?? "food.\(id.string)",
                productName: request.reviewed.request.originalItem, originalText: request.reviewed.request.originalItem,
                quantity: quantity, exclusions: [], contains: [])) }
            action = request.action
        } else {
            action = actionSources?.normalizedAction.command ?? .patch(.init(quote: edited?.quote ?? shop.quote, lines: basket,
                mealEdit: mealEdit, reviewedStoreBasisRevision: edited?.reviewedStoreBasisRevision))
        }
        if page.status == .enabled, mealEdit != nil { guard mealChanges != nil else { throw ClientError.configuration } }
        if mealChanges != nil { guard request == nil, actionSources == nil else { throw ClientError.configuration } }
        let mealDelta = try mealChanges?.delta(page: page, action: action, packs: self.packs, basket: basket)
        for source in mealDelta?.change.contributions ?? [] {
            if let index = additions.firstIndex(where: { $0.id == source.id }) {
                // A simultaneous explicit identity clarification may accompany
                // a meal update, but must not replace any meal facts.
                guard let old = state.graph.contributions.first(where: { $0.id == source.id }), old.productKey == nil,
                      additions[index].productKey != nil else { throw ClientError.configuration }
                var clarified = old; clarified.productKey = additions[index].productKey
                guard clarified == additions[index] else { throw ClientError.configuration }
                var merged = source; merged.productKey = clarified.productKey; additions[index] = merged
            } else { additions.append(source) }
        }
        let old = state.graph.lines
        guard old.filter({ $0.trashedAt == nil }).allSatisfy({ line in basket.contains { $0.lineId == line.id.string } }) else { throw ClientError.configuration }
        let newLines = try Set(additions.map(\.lineId)).sorted { $0.string < $1.string }.compactMap { id -> SharedDemandLine? in
            if old.contains(where: { $0.id == id && $0.trashedAt == nil }) { return nil }
            guard let line = basket.first(where: { $0.lineId == id.string }) else { throw ClientError.configuration }
            if var historical = old.first(where: { $0.id == id }) {
                guard mealChanges?.rows.contains(where: { $0.canBind && $0.lineID == id && $0.productConfirmed }) == true else { throw ClientError.configuration }
                historical.trashedAt = nil; historical.name = line.originalItem; return historical
            }
            return .init(id: id, name: line.originalItem,
                unit: request?.target?.lineId == id.string ? requestLineUnit : (self.packs.first { $0.id == id }?.lineUnit ?? .count),
                originalOrder: (old.map(\.originalOrder).max() ?? -1) + basket.firstIndex(where: { $0.lineId == id.string })! + 1)
        }
        let renamed = try old.filter { $0.trashedAt == nil }.compactMap { line -> SharedDemandLine? in
            guard let basket = basket.first(where: { $0.lineId == line.id.string }), line.name != basket.originalItem else { return nil }
            guard confirmBasketLabels else { throw ClientError.configuration }
            var value = line; value.name = basket.originalItem; return value
        }
        let change = SharedDemandChange(lines: newLines + renamed, contributions: additions, edges: [],
            removeSourceIds: mealDelta?.change.removeSourceIds ?? [], removeEdgeIds: mealDelta?.change.removeEdgeIds ?? [],
            quantifyReservationIds: mealDelta?.change.quantifyReservationIds,
            clarifyReservationProductIds: clarifyingProtected.isEmpty ? nil : clarifyingProtected)
        guard Set(clarifyingProtected).isDisjoint(with: change.quantifyReservationIds ?? []) else { throw ClientError.configuration }
        if state.graph.revision == 0 {
            // First adoption must cover the whole basket. No source or food
            // amount is inferred for unrelated grocery rows from their packs.
            guard Set(newLines.map(\.id.string)) == Set(basket.map(\.lineId)),
                  Set(packs.map(\.lineId)) == Set(newLines.map(\.id)) else { throw ClientError.configuration }
            return .adopt(action: action, change: change, packs: packs)
        }
        if change.isEmpty && request == nil && mealChanges == nil { return .review(action: action, packs: packs) }
        return .change(action: action, change: change, packs: packs, unboundFactIds: mealDelta?.unboundFactIDs ?? state.unbound.map(\.factId))
    }
    func rebind(page: SharedTrackingPage) throws -> SharedTrackingIntentKind {
        guard let state = page.state, let factID = rebindFactID, rebindConfirmed,
              let source = state.unbound.first(where: { $0.factId == factID })?.transferred else { throw ClientError.configuration }
        let old = state.graph.lines.first { $0.id == source.lineId }
        let line = SharedDemandLine(id: source.lineId, name: old?.name ?? rebindName, unit: old?.unit ?? rebindUnit,
            originalOrder: old?.originalOrder ?? ((state.graph.lines.map(\.originalOrder).max() ?? -1) + 1))
        let price: Int?
        if rebindPrice.isEmpty { price = nil }
        else { guard let value = Int(rebindPrice), value >= 0 else { throw ClientError.configuration }; price = value }
        let basket = try state.basket.first { $0.id == line.id } ?? .reviewed(id: line.id, name: line.name,
            packs: rebindPacks, priceMinor: price, feeEligible: rebindFeeEligible)
        let pack = try state.packReviews.first { $0.lineId == line.id } ?? .init(lineId: line.id,
            usablePerPack: rebindUsable.value(), acceptUnresolved: rebindUnresolved)
        return .rebind(bindings: [.init(factId: factID, line: line, basket: basket, packReview: pack)])
    }
    static func tags(_ text: String) -> [String] {
        Array(Set(text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
    }
    static func quantity(_ value: ReviewedRequestPackEvidence.Quantity) throws -> SharedDemandQuantity {
        guard let n = Int64(value.numerator), let d = Int64(value.denominator), let unit = SharedDemandUnit(rawValue: value.unit) else { throw ClientError.configuration }
        return .init(amount: try .init(numerator: n, denominator: d), unit: unit, originalLiteral: value.originalLiteral)
    }
}

/// Pure two-part review gate. A changed draft or selection discards the exact
/// candidate and both acknowledgements; no accepted review survives refresh.
struct TrackingReviewGate: Equatable {
    var changes = false
    var pickup = false
    var canApply: Bool { changes && pickup }
    mutating func reset() { self = .init() }
}
