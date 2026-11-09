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
            let rate = try Rational(decimal: conversionRate.replacingOccurrences(of: ",", with: "."))
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
    // Only a user-confirmed same-product choice gives a new source the existing
    // line's product key. A name match alone is never an allocation permission.
    func contribution(line: SharedFoodLineDraft, productKey: String?, at: String) throws -> SharedDemandContribution {
        guard productConfirmed, requiredLineID == nil || requiredLineID == line.id else { throw ClientError.configuration }
        var labels = restrictions
        var tags = Self.tags(exclusions)
        for index in labels.indices {
            let mapped = Self.tags(restrictionTags.indices.contains(index) ? restrictionTags[index] : "")
            if !mapped.isEmpty { labels[index].resolution = .mapped(tags: mapped, confirmedAt: at); tags += mapped }
        }
        let quantity: SharedDemandQuantity?
        if quantityIsFixed { quantity = fixedQuantity } else { quantity = try amount.quantity() }
        let result = SharedDemandContribution(id: id, lineId: line.id, source: source, productKey: productKey,
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
enum SharedFoodEditorError: Error { case quoteExpired, retainedSources, removalReview, renameReview }

struct SharedFoodEditorContext: Identifiable, Equatable {
    let id = UUID()
    let shop: ShopperShop
    let page: SharedDemandPage
    let candidate: ShopperShopCandidate
}
struct SharedFoodRemovedLine: Identifiable, Equatable {
    let line: SharedFoodLineDraft
    let sources: [SharedDemandContribution]
    var originalIndex = 0
    var confirmed = false
    var id: SharedDemandID { line.id }
    var mustKeep: Bool {
        sources.contains { source in
            switch source.source { case .manual, .imported: false; default: true }
        }
    }
}
struct SharedFoodDraft: Equatable {
    var lines: [SharedFoodLineDraft] = []
    var sources: [SharedFoodSourceDraft] = []
    var links: [SharedFoodLinkDraft] = []
    var removedLines: [SharedFoodRemovedLine] = []
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
    func request(page: SharedDemandPage, shop: ShopperShop, at: String) throws -> SharedDemandPreviewRequest {
        guard page.shopId.string == shop.shopId, page.shopRevision == shop.shopRevision, page.authorityEpoch == shop.authorityEpoch else { throw ClientError.cancelled }
        if removedLines.contains(where: \.mustKeep) { throw SharedFoodEditorError.retainedSources }
        if removedLines.contains(where: { !$0.confirmed }) { throw SharedFoodEditorError.removalReview }
        if let editedCandidate, (serviceDate(editedCandidate.quote.expiresAt) ?? .distantPast) <= Date() { throw SharedFoodEditorError.quoteExpired }
        let removedSourceIDs = removedLines.flatMap { $0.sources.map(\.id) }
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
        for line in lines where line.confirmExistingSources {
            let existing = active.filter { $0.lineId == line.id }
            let key = existing.compactMap(\.productKey).first ?? "food.\(line.id.string)"
            for var old in existing where old.productKey == nil {
                // Explicit review binds identity without replacing source IDs,
                // wording, amounts, provenance, restrictions or allocations.
                old.productKey = key; contributions.append(old)
                if case .reservation = old.source { clarifications.append(old.id) }
            }
        }
        for source in sources {
            guard let id = source.lineID, let line = lines.first(where: { $0.id == id }) else { throw ClientError.configuration }
            let existing = active.filter { $0.lineId == id }
            guard !existing.contains(where: { $0.productKey == nil }) || line.confirmExistingSources else { throw ClientError.configuration }
            let key = existing.compactMap(\.productKey).first ?? "food.\(id.string)"
            contributions.append(try source.contribution(line: line, productKey: key, at: at))
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
        let packs = try lines.map { SharedDemandPackReview(lineId: $0.id, usablePerPack: try $0.usable.quantity(), acceptUnresolved: $0.acceptUnresolved) }
        let change = SharedDemandChange(lines: newLines, contributions: contributions, edges: edges, removeSourceIds: removedSourceIDs, clarifyReservationProductIds: clarifications.isEmpty ? nil : clarifications)
        let mode: SharedDemandPreviewRequest.Mode = page.status == .legacy ? .adopt : (change.isEmpty ? .review : .change)
        let result = SharedDemandPreviewRequest(mode: mode,
            base: .init(shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch, graphRevision: page.graph?.revision ?? 0),
            change: change,
            action: .patch(.init(quote: editedCandidate?.quote ?? shop.quote, lines: basket, reviewedStoreBasisRevision: editedCandidate?.reviewedStoreBasisRevision)), packs: packs)
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
    @Published var draft = SharedFoodDraft()
    @Published private(set) var review: SharedDemandReview?
    @Published private(set) var busy = false
    @Published private(set) var submitted = false
    @Published private(set) var notice: String?
    @Published var acknowledged = false
    private let access: any SharedDemandFlowAccess
    private var generation = UUID()
    private let editorContext: SharedFoodEditorContext?
    init(access: any SharedDemandFlowAccess, editor: SharedFoodEditorContext? = nil) { self.access = access; editorContext = editor }
    var permitted: Bool { access.canReadFood && access.foodShop?.shopId == shop?.shopId && (editorContext == nil || access.foodEditorID == editorContext?.id) }
    var pending: Bool { access.foodPending }
    func load() async {
        guard !busy else { return }
        cancel(); let token = generation; busy = true; defer { if generation == token { busy = false } }
        do {
            let value = try await access.readFood()
            guard generation == token, access.canReadFood, let current = access.foodShop else { return }
            if let editorContext {
                guard access.foodEditorID == editorContext.id, current == editorContext.shop, value == editorContext.page else { throw ClientError.cancelled }
            }
            let entered = try SharedFoodDraft(page: value, shop: current, candidate: editorContext?.candidate)
            shop = current; page = value; draft = entered
        } catch { failed(error, token: token) }
    }
    func cancel() { generation = UUID(); busy = false; page = nil; shop = nil; draft = SharedFoodDraft(); review = nil; acknowledged = false; notice = nil; submitted = false }
    func editAgain() { review = nil; acknowledged = false }
    func preview() async {
        guard !busy, !pending, permitted, let page, let shop else { return }
        let token = generation; busy = true; defer { if token == generation { busy = false } }
        do {
            let request = try draft.request(page: page, shop: shop, at: ISO8601DateFormatter().string(from: Date()))
            let result = try await access.previewFood(request)
            guard token == generation else { return }
            guard permitted, access.foodShop == shop else { cancel(); return }
            review = result; acknowledged = false; notice = nil
        } catch { failed(error, token: token) }
    }
    func apply() async {
        guard !busy, !pending, permitted, acknowledged, let review else { return }
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
            case .quoteExpired: notice = SharedDemandCopy.text("The entered quote expired. Return to the item editor and update its expiry before reviewing again.")
            case .retainedSources: notice = SharedDemandCopy.text("These meal, request or protected commitments remain. Keep their item to save your other edits.")
            case .removalReview: notice = SharedDemandCopy.text("Review every source on each removed item before confirming its removal.")
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
