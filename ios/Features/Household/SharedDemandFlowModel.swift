import Foundation
import SwiftUI
import HouseholdClient
import CoreDomain

/// Entry parsing only. Allocation, capacity, duplicate classes and totals belong
/// to the service reducer. The exact entered literal survives normalization.
struct SharedFoodAmountDraft: Equatable {
    var literal = ""
    var unit: SharedDemandUnit = .count
    var unknown = true
    var useConversion = false
    var conversionUnit: SharedDemandUnit = .gram
    var conversionRate = ""
    var conversionNote = ""
    func quantity() throws -> SharedDemandQuantity? {
        if unknown { return nil }
        let text = literal.trimmingCharacters(in: .whitespacesAndNewlines)
        let rational: Rational
        let parts = text.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let n = Int64(parts[0]), let d = Int64(parts[1]) {
            rational = try Rational(n, d)
        } else { rational = try Rational(decimal: text.replacingOccurrences(of: ",", with: ".")) }
        var conversion: SharedDemandConversion?
        if useConversion {
            let rate = try DinnerEntry.rational(conversionRate)
            conversion = .init(sourceUnit: unit, targetUnit: conversionUnit,
                targetAmountPerSourceUnit: try .init(numerator: rate.numerator, denominator: rate.denominator),
                sourceNote: conversionNote, confirmedAt: ISO8601DateFormatter().string(from: Date()))
        }
        let value = SharedDemandQuantity(amount: try .init(numerator: rational.numerator, denominator: rational.denominator), unit: unit, originalLiteral: literal, confirmedConversion: conversion)
        try value.validate(); return value
    }
}
struct SharedFoodLineDraft: Identifiable, Equatable {
    var id: SharedDemandID
    var name: String
    var unit: SharedDemandUnit
    var packs: Int
    var priceMinor: Int?
    var feeEligible: Bool
    var usable = SharedFoodAmountDraft()
    var acceptUnresolved = false
    var existing = true
    var confirmExistingSources = false
    var confirmRename = false
}
/// Separate evidence for a fixed meal quantity: none is inherited from an old
/// amount, and the authoritative amount/unit/literal are never editable here.
struct SharedFoodFixedConversionDraft: Equatable {
    var enabled = false
    var targetUnit: SharedDemandUnit = .gram
    var rate = ""
    var note = ""
    func apply(to quantity: SharedDemandQuantity?, lineUnit: SharedDemandUnit, permitted: Bool, at: String) throws -> SharedDemandQuantity? {
        guard enabled else { return quantity }
        guard permitted, var quantity, quantity.confirmedConversion == nil,
              let from = UnitOfMeasure(rawValue: quantity.unit.rawValue), let line = UnitOfMeasure(rawValue: lineUnit.rawValue),
              let target = UnitOfMeasure(rawValue: targetUnit.rawValue), from.dimension != line.dimension,
              target.dimension == line.dimension, !note.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw ClientError.configuration }
        let ratio = try DinnerEntry.rational(rate)
        quantity.confirmedConversion = .init(sourceUnit: quantity.unit, targetUnit: targetUnit,
            targetAmountPerSourceUnit: try .init(numerator: ratio.numerator, denominator: ratio.denominator), sourceNote: note, confirmedAt: at)
        try quantity.validate(); return quantity
    }
    static func needed(for quantity: SharedDemandQuantity?, lineUnit: SharedDemandUnit?) -> Bool {
        guard let quantity, quantity.confirmedConversion == nil, let lineUnit,
              let from = UnitOfMeasure(rawValue: quantity.unit.rawValue), let line = UnitOfMeasure(rawValue: lineUnit.rawValue) else { return false }
        return from.dimension != line.dimension
    }
}
struct SharedFoodSourceDraft: Identifiable, Equatable {
    var id = SharedDemandID()
    var lineID: SharedDemandID?
    var source: SharedDemandSource = .manual
    var sourceLabel = ""
    var productName = ""
    var originalText = ""
    var amount = SharedFoodAmountDraft()
    var fixedQuantity: SharedDemandQuantity?
    var quantityIsFixed = false
    var requiredLineID: SharedDemandID?
    var restrictions: [SharedDemandSourceExclusion] = []
    var restrictionTags: [String] = []
    var exclusions = ""
    var contains = ""
    var productConfirmed = false
    var originalQuantityText: String?
    var fixedConversion = SharedFoodFixedConversionDraft()
    var previousContribution: SharedDemandContribution?
    var quantificationConfirmed = false
    // Only a user-confirmed same-product choice gives a new source the existing
    // line's product key. A name match alone is never an allocation permission.
    func contribution(line: SharedFoodLineDraft, productKey: String?, at: String, allowFixedConversion: Bool = false) throws -> SharedDemandContribution {
        guard productConfirmed, requiredLineID == nil || requiredLineID == line.id else { throw ClientError.configuration }
        var labels = restrictions
        var tags = Self.tags(exclusions)
        for label in labels { if case .mapped(let values, _) = label.resolution { tags += values } }
        for index in labels.indices {
            let mapped = Self.tags(restrictionTags.indices.contains(index) ? restrictionTags[index] : "")
            if !mapped.isEmpty { labels[index].resolution = .mapped(tags: mapped, confirmedAt: at); tags += mapped }
        }
        let quantity: SharedDemandQuantity?
        if quantityIsFixed { quantity = try fixedConversion.apply(to: fixedQuantity, lineUnit: line.unit, permitted: allowFixedConversion, at: at) } else { quantity = try amount.quantity() }
        // Retain a saved identity; explicit confirmation does not reassign it.
        let key = previousContribution?.productKey ?? productKey
        let result = SharedDemandContribution(id: id, lineId: line.id, source: source, productKey: key,
            productName: productName, originalText: originalText,
            quantity: quantity, sourceExclusions: labels.isEmpty ? nil : labels,
            exclusions: Array(Set(tags)).sorted(), contains: Self.tags(contains))
        try result.validate(); return result
    }
    static func tags(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
    }
}
struct SharedFoodLinkDraft: Identifiable, Equatable {
    var id = SharedDemandID()
    var kind: SharedDemandEdge.Kind = .withinExisting
    var demandID: SharedDemandID?
    var supplyID: SharedDemandID?
    var amount = SharedFoodAmountDraft()
    var confirmed = false
    var evidence = ""
}
enum SharedFoodEditorError: Error { case quoteExpired, retainedSources, removalReview, renameReview, requestIdentity, mealReview, protectedIdentity }

/// Exact monetary decision retained before the request preview goes over the
/// wire. A fresh Add decision would generate a different basket UUID.
struct SharedRequestDecisionReview: Equatable {
    let request: OwnRequest
    let shop: ShopperShop
    let decision: ShopperDecision
    let preview: ShopperPreview
}
struct SharedRequestFoodContext: Identifiable, Equatable {
    let id = UUID()
    let sourceID = SharedDemandID()
    let reviewed: SharedRequestDecisionReview
    let page: SharedDemandPage
    let action: SharedDemandRequestApply
    let targetLineID: SharedDemandID
    let basket: [ShopperBasketLine]
    let reviewedNeeded: SharedDemandQuantity?
    let reviewedUsable: SharedDemandQuantity?
    init(reviewed: SharedRequestDecisionReview, page: SharedDemandPage, acceptOverage: Bool, acceptUnknown: Bool) throws {
        guard page.status == .enabled, page.graph != nil, page.shopId.string == reviewed.shop.shopId,
              page.shopRevision == reviewed.shop.shopRevision, page.authorityEpoch == reviewed.shop.authorityEpoch,
              reviewed.preview.shopRevision == page.shopRevision, reviewed.preview.authorityEpoch == page.authorityEpoch,
              reviewed.preview.requestRevision == reviewed.request.revision, reviewed.preview.choice == reviewed.decision.choice,
              reviewed.request.shopId == page.shopId.string,
              (serviceDate(reviewed.preview.expiresAt) ?? .distantPast) > Date(),
              (serviceDate(reviewed.shop.quote.expiresAt) ?? .distantPast) > Date(),
              !reviewed.preview.requiresOverageAcceptance || acceptOverage,
              !reviewed.preview.requiresUnknownAcceptance || acceptUnknown,
              let requestID = UUID(uuidString: reviewed.request.id), let previewID = UUID(uuidString: reviewed.preview.previewId) else { throw ClientError.cancelled }
        let target: String, lines: [ShopperBasketLine]
        let needed: SharedDemandQuantity?, usable: SharedDemandQuantity?
        switch reviewed.decision {
        case .add(let line, _, let evidence):
            guard !reviewed.shop.lines.contains(where: { $0.lineId == line.lineId }) else { throw ClientError.configuration }
            target = line.lineId; lines = reviewed.shop.lines + [line]
            if let evidence {
                guard evidence.productMatchConfirmed, evidence.availabilityConfirmed,
                      evidence.packs == line.packs, evidence.unitPriceMinor == line.unitPriceMinor else { throw ClientError.configuration }
                needed = try Self.quantity(evidence.needed); usable = try Self.quantity(evidence.usablePerPack)
            } else { needed = nil; usable = nil }
        case .link(let lineID, _):
            guard reviewed.shop.lines.contains(where: { $0.lineId == lineID }) else { throw ClientError.configuration }
            target = lineID; lines = reviewed.shop.lines; needed = nil; usable = nil
        default: throw ClientError.configuration
        }
        guard let targetID = UUID(uuidString: target) else { throw ClientError.configuration }
        self.reviewed = reviewed; self.page = page; targetLineID = .init(targetID); basket = lines
        reviewedNeeded = needed; reviewedUsable = usable
        action = .init(requestId: .init(requestID), previewId: .init(previewID), acceptOverage: acceptOverage, acceptUnknown: acceptUnknown)
    }
    private static func quantity(_ value: ReviewedRequestPackEvidence.Quantity) throws -> SharedDemandQuantity {
        guard let n = Int64(value.numerator), let d = Int64(value.denominator), let unit = SharedDemandUnit(rawValue: value.unit) else { throw ClientError.configuration }
        let result = SharedDemandQuantity(amount: try .init(numerator: n, denominator: d), unit: unit, originalLiteral: value.originalLiteral)
        try result.validate(); return result
    }
    func draft() throws -> SharedFoodDraft {
        let candidate = try ShopperShopCandidate(quote: reviewed.shop.quote, lines: basket, reviewedStoreBasisRevision: reviewed.shop.storeBasisRevision)
        var draft = try SharedFoodDraft(page: page, shop: reviewed.shop, candidate: candidate)
        var source = SharedFoodSourceDraft()
        source.id = sourceID; source.source = .request(requestId: action.requestId, appliedRequestRevision: reviewed.request.revision)
        source.sourceLabel = reviewed.request.originalItem; source.productName = reviewed.request.originalItem
        source.originalText = reviewed.request.originalItem; source.originalQuantityText = reviewed.request.ownQuantity
        source.lineID = targetLineID; source.requiredLineID = targetLineID
        if let reviewedNeeded {
            source.quantityIsFixed = true; source.fixedQuantity = reviewedNeeded
            if let index = draft.lines.firstIndex(where: { $0.id == targetLineID }) { draft.lines[index].unit = reviewedNeeded.unit }
        }
        // Contributor wording stays visible. Neither packs nor free-form wording
        // are interpreted as usable food; the shopper records known/unknown.
        draft.sources = [source]
        return draft
    }
    func validate(_ draft: SharedFoodDraft) throws {
        guard draft.removedLines.isEmpty, draft.sources.count == 1, draft.sources[0].id == sourceID,
              draft.sources[0].source == .request(requestId: action.requestId, appliedRequestRevision: reviewed.request.revision),
              draft.sources[0].originalText == reviewed.request.originalItem,
              draft.sources[0].originalQuantityText == reviewed.request.ownQuantity,
              draft.sources[0].lineID == targetLineID, draft.sources[0].requiredLineID == targetLineID,
              draft.sources[0].quantityIsFixed == (reviewedNeeded != nil), draft.sources[0].fixedQuantity == reviewedNeeded,
              draft.lines.count == basket.count,
              zip(draft.lines, basket).allSatisfy({ line, entered in
                  line.id.string == entered.lineId && line.name == entered.originalItem && line.packs == entered.packs &&
                  line.priceMinor == entered.unitPriceMinor && line.feeEligible == entered.feeEligible && !line.confirmRename &&
                  (!line.confirmExistingSources || line.id == targetLineID)
              }) else { throw ClientError.configuration }
        for source in page.graph?.contributions ?? [] where source.removedAt == nil && source.lineId == targetLineID && source.productKey == nil {
            switch source.source { case .manual, .imported: break
            default: throw SharedFoodEditorError.requestIdentity }
        }
        for link in draft.links {
            guard link.kind == .withinExisting, link.demandID == sourceID,
                  let supply = page.graph?.contributions.first(where: { $0.id == link.supplyID && $0.removedAt == nil && $0.lineId == targetLineID }) else { throw ClientError.configuration }
            switch supply.source { case .manual, .imported: break; default: throw ClientError.configuration }
        }
    }
}

struct SharedFoodEditorContext: Identifiable, Equatable {
    let id = UUID()
    let shop: ShopperShop
    let page: SharedDemandPage
    let candidate: ShopperShopCandidate
    var meal: SharedMealFoodContext? = nil
}
struct SharedFoodRemovedLine: Identifiable, Equatable {
    let line: SharedFoodLineDraft
    let sources: [SharedDemandContribution]
    var mealRetirementIDs = Set<SharedDemandID>()
    var originalIndex = 0
    var confirmed = false
    var id: SharedDemandID { line.id }
    var mustKeep: Bool {
        sources.contains { source in
            if mealRetirementIDs.contains(source.id) { return false }
            return switch source.source { case .manual, .imported: false; default: true }
        }
    }
}
struct SharedFoodDraft: Equatable {
    var lines: [SharedFoodLineDraft] = []
    var sources: [SharedFoodSourceDraft] = []
    var links: [SharedFoodLinkDraft] = []
    var removedLines: [SharedFoodRemovedLine] = []
    var mealRetirements: [SharedFoodRetirement] = []
    var mealRelationships: [SharedFoodRelationshipReview] = []
    var mealSourcesReviewed = false
    private(set) var editedCandidate: ShopperShopCandidate?

    init() {}
    init(page: SharedDemandPage, shop: ShopperShop, candidate: ShopperShopCandidate? = nil) throws {
        guard page.shopId.string == shop.shopId, page.shopRevision == shop.shopRevision, page.authorityEpoch == shop.authorityEpoch else { throw ClientError.cancelled }
        lines = try shop.lines.map { row in
            guard let id = UUID(uuidString: row.lineId) else { throw ClientError.invalidResponse }
            let graphLine = page.graph?.lines.first { $0.id.uuid == id && $0.trashedAt == nil }
            return .init(id: .init(id), name: row.originalItem, unit: graphLine?.unit ?? .count, packs: row.packs, priceMinor: row.unitPriceMinor, feeEligible: row.feeEligible)
        }
        if page.status == .legacy, page.legacySources == nil { throw ClientError.configuration }
        if let catalog = page.legacySources {
            sources = catalog.sources.map { item in
                var row = SharedFoodSourceDraft()
                row.id = item.id; row.sourceLabel = item.sourceLabel
                row.source = item.source; row.lineID = item.requiredLineId; row.requiredLineID = item.requiredLineId
                row.productName = item.productName; row.originalText = item.originalText
                row.fixedQuantity = item.quantity
                switch item.source { case .meal, .reservation: row.quantityIsFixed = true; default: break }
                row.restrictions = item.sourceExclusions; row.restrictionTags = Array(repeating: "", count: item.sourceExclusions.count)
                row.originalQuantityText = item.originalQuantityText
                return row
            }
        }
        if let candidate { try useEditorCandidate(candidate, page: page, shop: shop) }
    }
    mutating func useEditorCandidate(_ candidate: ShopperShopCandidate, page: SharedDemandPage, shop: ShopperShop) throws {
        guard page.status == .enabled || page.status == .reviewRequired, let graph = page.graph else { throw ClientError.configuration }
        if page.status == .reviewRequired {
            guard candidate.lines.count == shop.lines.count,
                  zip(candidate.lines, shop.lines).allSatisfy({ entered, original in entered.lineId == original.lineId && entered.originalItem == original.originalItem }) else { throw ClientError.configuration }
        }
        let original = lines
        let kept = Set(candidate.lines.map(\.lineId))
        removedLines = original.filter { !kept.contains($0.id.string) }.map { line in
            .init(line: line, sources: graph.contributions.filter { $0.removedAt == nil && $0.lineId == line.id }, originalIndex: original.firstIndex(where: { $0.id == line.id }) ?? 0)
        }
        lines = try candidate.lines.map { item in
            guard let id = UUID(uuidString: item.lineId) else { throw ClientError.configuration }
            var line = original.first { $0.id.uuid == id } ?? .init(id: .init(id), name: item.originalItem, unit: .count, packs: item.packs, priceMinor: item.unitPriceMinor, feeEligible: item.feeEligible, existing: false)
            line.name = item.originalItem; line.packs = item.packs; line.priceMinor = item.unitPriceMinor; line.feeEligible = item.feeEligible
            return line
        }
        editedCandidate = candidate
    }
    mutating func restoreRemovedLine(_ id: SharedDemandID) {
        guard let removed = removedLines.first(where: { $0.id == id }) else { return }
        // This is an explicit user action, never an automatic fallback. Preserve
        // the removed line's original identity, packs, price and source bindings.
        lines.insert(removed.line, at: min(removed.originalIndex, lines.count)); removedLines.removeAll { $0.id == id }
    }
    mutating func removeUnsavedLine(_ id: SharedDemandID) {
        guard lines.contains(where: { $0.id == id && !$0.existing }) else { return }
        lines.removeAll { $0.id == id }
        let affected = Set(sources.filter { $0.lineID == id }.map(\.id))
        for index in sources.indices where sources[index].lineID == id {
            sources[index].lineID = nil; sources[index].productConfirmed = false
        }
        for index in links.indices where links[index].demandID.map(affected.contains) == true || links[index].supplyID.map(affected.contains) == true {
            links[index].confirmed = false
        }
    }
    func request(page: SharedDemandPage, shop: ShopperShop, at: String, requestContext: SharedRequestFoodContext? = nil, mealContext: SharedMealFoodContext? = nil) throws -> SharedDemandPreviewRequest {
        if let mealContext { try mealContext.validate(self, page: page) }
        if let requestContext {
            guard requestContext.page == page, requestContext.reviewed.shop == shop else { throw ClientError.cancelled }
            try requestContext.validate(self)
        }
        guard page.shopId.string == shop.shopId, page.shopRevision == shop.shopRevision, page.authorityEpoch == shop.authorityEpoch else { throw ClientError.cancelled }
        if removedLines.contains(where: \.mustKeep) { throw SharedFoodEditorError.retainedSources }
        if removedLines.contains(where: { !$0.confirmed }) { throw SharedFoodEditorError.removalReview }
        if let editedCandidate, (serviceDate(editedCandidate.quote.expiresAt) ?? .distantPast) <= Date() { throw SharedFoodEditorError.quoteExpired }
        var removedIDs = Set<SharedDemandID>()
        let removedSourceIDs = (removedLines.flatMap { $0.sources.map(\.id) } + mealRetirements.map { $0.source.id }).filter { removedIDs.insert($0).inserted }
        let removing = Set(removedSourceIDs)
        let active = page.graph?.contributions.filter { $0.removedAt == nil && !removing.contains($0.id) } ?? []
        let oldLines = page.graph?.lines ?? []
        var contributions: [SharedDemandContribution] = []
        var clarifications: [SharedDemandID] = []
        if page.status == .reviewRequired {
            guard sources.isEmpty, links.isEmpty, removedLines.isEmpty,
                  lines.count == shop.lines.count,
                  zip(lines, shop.lines).allSatisfy({ line, original in
                      line.id.string == original.lineId && line.name == original.originalItem && !line.confirmExistingSources && !line.confirmRename
                  }) else { throw ClientError.configuration }
            let monetaryBase = editedCandidate?.lines ?? shop.lines
            guard zip(lines, monetaryBase).allSatisfy({ line, entered in
                line.id.string == entered.lineId && line.packs == entered.packs && line.priceMinor == entered.unitPriceMinor && line.feeEligible == entered.feeEligible
            }) else { throw ClientError.configuration }
        }
        let updatingIDs = Set(sources.map(\.id))
        for line in lines where line.confirmExistingSources {
            let existing = active.filter { $0.lineId == line.id }
            let key = existing.compactMap(\.productKey).first ?? "food.\(line.id.string)"
            for var old in existing where old.productKey == nil && !updatingIDs.contains(old.id) {
                // Explicit review binds identity without replacing source IDs,
                // wording, amounts, provenance, restrictions or allocations.
                old.productKey = key; contributions.append(old)
                if case .reservation = old.source { clarifications.append(old.id) }
            }
        }
        for source in sources {
            guard let id = source.lineID, let line = lines.first(where: { $0.id == id }) else { throw ClientError.configuration }
            let existing = active.filter { $0.lineId == id }
            guard !existing.contains(where: { $0.productKey == nil && $0.id != source.id }) || line.confirmExistingSources else { throw ClientError.configuration }
            let key = existing.compactMap(\.productKey).first ?? "food.\(id.string)"
            var changed = try source.contribution(line: line, productKey: key, at: at, allowFixedConversion: mealContext != nil)
            if let old = source.previousContribution, case .reservation = old.source {
                changed.productKey = old.productKey // Never combine protected quantity and identity edits.
            }
            contributions.append(changed)
        }
        let replaced = Set(contributions.map(\.id))
        let allSources = active.filter { !replaced.contains($0.id) } + contributions
        // Each basket line must explicitly contain at least one need. We never
        // infer a manual contribution from its pack count or copied basket label.
        guard lines.allSatisfy({ line in allSources.contains { $0.lineId == line.id } }) else { throw ClientError.configuration }
        let edges = try links.map { link -> SharedDemandEdge in
            guard link.confirmed, let demandID = link.demandID, let supplyID = link.supplyID,
                  let quantity = try link.amount.quantity(), !link.evidence.isEmpty,
                  allSources.contains(where: { $0.id == demandID }), allSources.contains(where: { $0.id == supplyID }) else { throw ClientError.configuration }
            return .init(id: link.id, kind: link.kind, demandId: demandID, supplyId: supplyID, quantity: quantity,
                         confirmation: .init(confirmedAt: at, evidence: link.evidence))
        }
        let newLines = try lines.enumerated().compactMap { index, line -> SharedDemandLine? in
            if var old = oldLines.first(where: { $0.id == line.id }) {
                guard old.name != line.name else { return nil }
                guard line.confirmRename else { throw SharedFoodEditorError.renameReview }
                old.name = line.name; return old
            }
            return .init(id: line.id, name: line.name, unit: line.unit, originalOrder: (oldLines.map(\.originalOrder).max() ?? -1) + index + 1)
        }
        let basket = lines.map { ShopperBasketLine(lineId: $0.id.uuid, originalItem: $0.name, packs: $0.packs, unitPriceMinor: $0.priceMinor, feeEligible: $0.feeEligible) }
        let packs = try lines.map { line in
            let fixed = requestContext?.targetLineID == line.id ? requestContext?.reviewedUsable : nil
            let usable = try fixed ?? line.usable.quantity()
            return SharedDemandPackReview(lineId: line.id, usablePerPack: usable, acceptUnresolved: line.acceptUnresolved)
        }
        let quantifying = sources.filter { source in
            guard let old = source.previousContribution, case .reservation = old.source else { return false }
            return old.quantity == nil && source.fixedQuantity != nil && source.quantificationConfirmed
        }.map(\.id)
        let change = SharedDemandChange(lines: newLines, contributions: contributions, edges: edges, removeSourceIds: removedSourceIDs,
            removeEdgeIds: mealRelationships.filter { $0.decision == .remove }.map(\.id), quantifyReservationIds: quantifying.isEmpty ? nil : quantifying, clarifyReservationProductIds: clarifications.isEmpty ? nil : clarifications)
        let mode: SharedDemandPreviewRequest.Mode = page.status == .legacy ? .adopt : (change.isEmpty ? .review : .change)
        let result = SharedDemandPreviewRequest(mode: mode,
            base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch, graphRevision: page.graph?.revision ?? 0),
            change: change,
            action: requestContext.map { SharedDemandAction.request($0.action) } ?? .patch(.init(quote: editedCandidate?.quote ?? shop.quote, lines: basket, mealEdit: mealContext?.mealEdit, reviewedStoreBasisRevision: editedCandidate?.reviewedStoreBasisRevision)), packs: packs)
        try result.validate(); return result
    }
}

@MainActor protocol SharedDemandFlowAccess: AnyObject {
    var foodShop: ShopperShop? { get }
    var canReadFood: Bool { get }
    var foodPending: Bool { get }
    var foodEditorID: UUID? { get }
    func readFood() async throws -> SharedDemandPage
    func previewFood(_ request: SharedDemandPreviewRequest) async throws -> SharedDemandReview
    func applyFood(_ review: SharedDemandReview) async throws
}

@MainActor extension SharedDemandFlowAccess { var foodEditorID: UUID? { nil } }

@MainActor final class SharedDemandFlowModel: ObservableObject {
    @Published private(set) var page: SharedDemandPage?
    @Published private(set) var shop: ShopperShop?
    @Published var draft = SharedFoodDraft() { didSet { if oldValue != draft { review = nil; reviewedDraft = nil; acknowledged = false } } }
    @Published private(set) var review: SharedDemandReview?
    @Published private(set) var busy = false
    @Published private(set) var submitted = false
    @Published private(set) var notice: String?
    @Published var acknowledged = false
    private let access: any SharedDemandFlowAccess
    private var generation = UUID()
    private let editorContext: SharedFoodEditorContext?
    let requestContext: SharedRequestFoodContext?
    var mealContext: SharedMealFoodContext? { editorContext?.meal }
    private var reviewedDraft: SharedFoodDraft?
    init(access: any SharedDemandFlowAccess, editor: SharedFoodEditorContext? = nil, request: SharedRequestFoodContext? = nil) {
        self.access = access; editorContext = editor; requestContext = request
    }
    var permitted: Bool { access.canReadFood && access.foodShop?.shopId == shop?.shopId && (editorContext == nil || access.foodEditorID == editorContext?.id) && (requestContext == nil || access.foodEditorID == requestContext?.id) }
    var pending: Bool { access.foodPending }
    /// SwiftUI may retain a row binding while Cancel/revocation removes its row.
    /// Resolve by identity on every access; never retain an array position or a
    /// private row as the fallback. A prior load cannot write into a later draft.
    func draftRowBinding<Row: Identifiable>(_ path: WritableKeyPath<SharedFoodDraft, [Row]>, id: Row.ID, empty: Row) -> Binding<Row> {
        let token = generation
        return Binding(get: { [weak self] in
            guard let self, self.generation == token, self.permitted else { return empty }
            return self.draft[keyPath: path].first { $0.id == id } ?? empty
        }, set: { [weak self] value in
            guard let self, self.generation == token, self.permitted, !self.busy, !self.pending, !self.submitted,
                  value.id == id, let index = self.draft[keyPath: path].firstIndex(where: { $0.id == id }) else { return }
            self.draft[keyPath: path][index] = value
        })
    }
    private func emptyLine(_ id: SharedDemandID) -> SharedFoodLineDraft {
        .init(id: id, name: "", unit: .count, packs: 1, priceMinor: nil, feeEligible: false)
    }
    func lineBinding(_ id: SharedDemandID) -> Binding<SharedFoodLineDraft> {
        draftRowBinding(\.lines, id: id, empty: emptyLine(id))
    }
    func sourceBinding(_ id: SharedDemandID) -> Binding<SharedFoodSourceDraft> {
        var empty = SharedFoodSourceDraft(); empty.id = id
        return draftRowBinding(\.sources, id: id, empty: empty)
    }
    func linkBinding(_ id: SharedDemandID) -> Binding<SharedFoodLinkDraft> {
        var empty = SharedFoodLinkDraft(); empty.id = id
        return draftRowBinding(\.links, id: id, empty: empty)
    }
    func removedLineBinding(_ id: SharedDemandID) -> Binding<SharedFoodRemovedLine> {
        draftRowBinding(\.removedLines, id: id, empty: .init(line: emptyLine(id), sources: []))
    }
    func restrictionBinding(sourceID: SharedDemandID, restriction: SharedDemandSourceExclusion) -> Binding<String> {
        let source = sourceBinding(sourceID)
        func index(in row: SharedFoodSourceDraft) -> Int? {
            row.restrictions.firstIndex { $0.occurrenceId == restriction.occurrenceId && $0.ingredientId == restriction.ingredientId && $0.label == restriction.label }
        }
        return Binding(get: {
            let row = source.wrappedValue
            guard let index = index(in: row), row.restrictionTags.indices.contains(index) else { return "" }
            return row.restrictionTags[index]
        }, set: { value in
            var row = source.wrappedValue
            guard let index = index(in: row), row.restrictionTags.indices.contains(index) else { return }
            row.restrictionTags[index] = value; source.wrappedValue = row
        })
    }
    func load() async {
        guard !busy else { return }
        cancel(); let token = generation; busy = true; defer { if generation == token { busy = false } }
        do {
            let value = try await access.readFood()
            guard generation == token, access.canReadFood, let current = access.foodShop else { return }
            if let editorContext {
                guard access.foodEditorID == editorContext.id, current == editorContext.shop, value == editorContext.page else { throw ClientError.cancelled }
            }
            if let requestContext {
                guard access.foodEditorID == requestContext.id, current == requestContext.reviewed.shop, value == requestContext.page else { throw ClientError.cancelled }
            }
            var entered = try requestContext?.draft() ?? SharedFoodDraft(page: value, shop: current, candidate: editorContext?.candidate)
            try mealContext?.prepare(&entered, page: value)
            shop = current; page = value; draft = entered
        } catch { failed(error, token: token) }
    }
    func cancel() { generation = UUID(); busy = false; page = nil; shop = nil; draft = SharedFoodDraft(); review = nil; reviewedDraft = nil; acknowledged = false; notice = nil; submitted = false }
    func editAgain() { review = nil; reviewedDraft = nil; acknowledged = false }
    func preview() async {
        guard !busy, !pending, permitted, let page, let shop else { return }
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            let entered = draft
            let request = try entered.request(page: page, shop: shop, at: ISO8601DateFormatter().string(from: Date()), requestContext: requestContext, mealContext: mealContext)
            let result = try await access.previewFood(request)
            guard token == generation else { return }
            guard permitted, access.foodShop == shop else { cancel(); return }
            guard entered == draft else { review = nil; acknowledged = false; return }
            reviewedDraft = entered; review = result; acknowledged = false; notice = nil
        } catch { failed(error, token: token) }
    }
    func apply() async {
        guard !busy, !pending, permitted, acknowledged, reviewedDraft == draft, let review else { return }
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            try await access.applyFood(review)
            guard token == generation else { return }
            guard permitted else { cancel(); return }
            self.review = nil; draft = SharedFoodDraft(); acknowledged = false; submitted = true
            notice = SharedDemandCopy.text("Return to the shared shop for confirmation or retry. A pending change is not yet confirmed.")
        } catch { failed(error, token: token) }
    }
    private func failed(_ error: Error, token: UUID) {
        guard token == generation else { return }
        review = nil; acknowledged = false
        if let input = error as? SharedFoodEditorError {
            switch input {
            case .mealReview: notice = SharedDemandCopy.text("Review the meal sources, removals and existing relationships before continuing.")
            case .protectedIdentity: notice = SharedDemandCopy.text("Review the protected food identity separately in Food quantities, then return to this meal change.")
            case .quoteExpired: notice = SharedDemandCopy.text("The entered quote expired. Return to the item editor and update its expiry before reviewing again.")
            case .retainedSources: notice = SharedDemandCopy.text("These meal, request or protected commitments remain. Keep their item to save your other edits.")
            case .removalReview: notice = SharedDemandCopy.text("Review every source on each removed item before confirming its removal.")
            case .requestIdentity: notice = SharedDemandCopy.text("Confirm the existing food identities in Food quantities, then return and review this request again.")
            case .renameReview: notice = SharedDemandCopy.text("Confirm that each changed basket label still refers to the same food sources.")
            }
            return
        }
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded: cancel(); notice = SharedDemandCopy.text("Shared food access ended. Return to the household.")
        case .cancelled: cancel(); notice = SharedDemandCopy.text("The shop changed. Refresh and review again.")
        case .service(let status, _, _, _) where status == 409 || status == 403 || status == 404:
            cancel(); notice = SharedDemandCopy.text("The shop changed. Refresh and review again.")
        default: notice = SharedDemandCopy.text("Not confirmed. Check explicit quantities, source matches, restrictions and pack coverage, then review again.")
        }
    }
}
