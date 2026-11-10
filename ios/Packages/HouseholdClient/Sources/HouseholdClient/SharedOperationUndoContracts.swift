import Foundation

/// Complete operation Undo is distinct from graph-only Undo. Responses are never cached as source copies.
public struct SharedOperationUndoEligibility: Codable, Equatable, Sendable {
    public enum Status: String, Codable, Sendable { case reviewable, unavailable }
    public enum Reason: String, Codable, Sendable {
        case explicit_current_preview_required
        case food_undo_history_unavailable, food_undo_request_acceptance_unsupported, food_undo_first_adoption_unsupported
        case food_undo_meal_action_unsupported, food_undo_store_action_unsupported, food_undo_missing_snapshot_unsupported
        case food_undo_meal_history_unavailable, food_undo_meal_conflict, food_undo_meal_protected, food_undo_meal_creation_unsupported
        case food_undo_operation_unsupported, food_undo_already_reversed, food_undo_inverse_operation_unsupported
        case food_undo_line_conflict, food_undo_quote_conflict, food_undo_graph_conflict, food_undo_expired_quote, food_undo_no_effect
    }
    public let status: Status
    public let reason: Reason
    private enum K: String, CodingKey { case status, reason }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["status", "reason"])
        let c = try decoder.container(keyedBy: K.self)
        status = try c.decode(Status.self, forKey: .status)
        reason = try c.decode(Reason.self, forKey: .reason)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(status, forKey: .status)
        try c.encode(reason, forKey: .reason)
    }
}
public struct SharedOperationUndoHistoryItem: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case patch = "shop.patch", request = "request.apply" }
    public let operationId: SharedDemandID
    public let kind: Kind
    public let shopRevision: Int
    public let committedAt: String
    public let eligibility: SharedOperationUndoEligibility
    private enum K: String, CodingKey { case operationId, kind, shopRevision, committedAt, eligibility }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["operationId", "kind", "shopRevision", "committedAt", "eligibility"])
        let c = try decoder.container(keyedBy: K.self)
        operationId = try c.decode(SharedDemandID.self, forKey: .operationId)
        kind = try c.decode(Kind.self, forKey: .kind)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        committedAt = try c.decode(String.self, forKey: .committedAt)
        eligibility = try c.decode(SharedOperationUndoEligibility.self, forKey: .eligibility)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(operationId, forKey: .operationId)
        try c.encode(kind, forKey: .kind)
        try c.encode(shopRevision, forKey: .shopRevision)
        try c.encode(committedAt, forKey: .committedAt)
        try c.encode(eligibility, forKey: .eligibility)
    }
}
public struct SharedOperationUndoHistory: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let shopRevision: Int
    public let authorityEpoch: Int
    public let items: [SharedOperationUndoHistoryItem]
    public let nextBeforeRevision: String?
    private enum K: String, CodingKey { case schemaVersion, shopId, shopRevision, authorityEpoch, items, nextBeforeRevision }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["schemaVersion", "shopId", "shopRevision", "authorityEpoch", "items", "nextBeforeRevision"])
        let c = try decoder.container(keyedBy: K.self)
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        shopRevision = try c.decode(Int.self, forKey: .shopRevision)
        authorityEpoch = try c.decode(Int.self, forKey: .authorityEpoch)
        items = try c.decode([SharedOperationUndoHistoryItem].self, forKey: .items)
        nextBeforeRevision = try c.decode(String?.self, forKey: .nextBeforeRevision)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(shopId, forKey: .shopId)
        try c.encode(shopRevision, forKey: .shopRevision)
        try c.encode(authorityEpoch, forKey: .authorityEpoch)
        try c.encode(items, forKey: .items)
        try c.encode(nextBeforeRevision, forKey: .nextBeforeRevision)
    }
}
public struct SharedOperationUndoTouchedLine: Codable, Equatable, Sendable {
    public enum Field: String, Codable, Sendable { case membership, originalItem, packs, unitPriceMinor, feeEligible }
    public let lineId: SharedDemandID
    public let fields: [Field]
    private enum K: String, CodingKey { case lineId, fields }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["lineId", "fields"])
        let c = try decoder.container(keyedBy: K.self)
        lineId = try c.decode(SharedDemandID.self, forKey: .lineId)
        fields = try c.decode([Field].self, forKey: .fields)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(lineId, forKey: .lineId)
        try c.encode(fields, forKey: .fields)
    }
}
public struct SharedOperationUndoScope: Codable, Equatable, Sendable {
    public let targetOperationId: SharedDemandID
    public let baseShopRevision: Int
    public let resultShopRevision: Int
    public let touchedLines: [SharedOperationUndoTouchedLine]
    public let quoteChanged: Bool
    public let graphRows: Int
    public let mealsChanged: Bool
    public let requestsChanged: Bool
    private enum K: String, CodingKey { case targetOperationId, baseShopRevision, resultShopRevision, touchedLines, quoteChanged, graphRows, mealsChanged, requestsChanged }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["targetOperationId", "baseShopRevision", "resultShopRevision", "touchedLines", "quoteChanged", "graphRows", "mealsChanged", "requestsChanged"])
        let c = try decoder.container(keyedBy: K.self)
        targetOperationId = try c.decode(SharedDemandID.self, forKey: .targetOperationId)
        baseShopRevision = try c.decode(Int.self, forKey: .baseShopRevision)
        resultShopRevision = try c.decode(Int.self, forKey: .resultShopRevision)
        touchedLines = try c.decode([SharedOperationUndoTouchedLine].self, forKey: .touchedLines)
        quoteChanged = try c.decode(Bool.self, forKey: .quoteChanged)
        graphRows = try c.decode(Int.self, forKey: .graphRows)
        mealsChanged = try c.decode(Bool.self, forKey: .mealsChanged)
        requestsChanged = try c.decode(Bool.self, forKey: .requestsChanged)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(targetOperationId, forKey: .targetOperationId)
        try c.encode(baseShopRevision, forKey: .baseShopRevision)
        try c.encode(resultShopRevision, forKey: .resultShopRevision)
        try c.encode(touchedLines, forKey: .touchedLines)
        try c.encode(quoteChanged, forKey: .quoteChanged)
        try c.encode(graphRows, forKey: .graphRows)
        try c.encode(mealsChanged, forKey: .mealsChanged)
        try c.encode(requestsChanged, forKey: .requestsChanged)
    }
}
public struct SharedOperationUndoPatch: Codable, Equatable, Sendable {
    private enum QuoteKey: String, CodingKey { case fee }
    private enum FeeKey: String, CodingKey { case kind }
    public let lines: [ShopperBasketLine]
    public let quote: ShopperQuote
    public let mealEdit: SharedDemandMealEdit?
    private enum K: String, CodingKey { case lines, quote, mealEdit }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        try demandExactKeys(decoder, c.contains(.mealEdit) ? ["lines", "quote", "mealEdit"] : ["lines", "quote"])
        if c.contains(.mealEdit) {
            let edit = try c.superDecoder(forKey: .mealEdit)
            try demandExactKeys(edit, ["occurrenceId", "baseMealRevision", "meal"])
            mealEdit = try c.decode(SharedDemandMealEdit.self, forKey: .mealEdit)
            try undoMealShapeInEdit(edit)
        } else { mealEdit = nil }
        var rows = try c.nestedUnkeyedContainer(forKey: .lines)
        while !rows.isAtEnd { try demandExactKeys(rows.superDecoder(), ["lineId", "originalItem", "packs", "unitPriceMinor", "feeEligible"]) }
        let quoteDecoder = try c.superDecoder(forKey: .quote)
        try demandExactKeys(quoteDecoder, ["currency", "scope", "complete", "capMinor", "capScope", "fee", "taxesMinor", "depositsMinor", "discountsMinor", "observedAt", "expiresAt"])
        let fee = try quoteDecoder.container(keyedBy: QuoteKey.self).superDecoder(forKey: .fee)
        let kind = try fee.container(keyedBy: FeeKey.self).decode(String.self, forKey: .kind)
        guard kind == "fixed" || kind == "threshold" else { throw ClientError.invalidResponse }
        try demandExactKeys(fee, kind == "fixed" ? ["kind", "amountMinor"] : ["kind", "thresholdMinor", "belowMinor", "aboveMinor"])
        lines = try c.decode([ShopperBasketLine].self, forKey: .lines)
        quote = try c.decode(ShopperQuote.self, forKey: .quote)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(lines, forKey: .lines)
        try c.encode(quote, forKey: .quote)
        if let mealEdit {
            guard let meal = mealEdit.meal else { throw ClientError.invalidResponse }
            var body = try JSONDecoder().decode([String: JSONValue].self, from: encoded(mealEdit))
            body["meal"] = try undoEncodedMeal(meal)
            try c.encode(body, forKey: .mealEdit)
        }
    }
}
public struct SharedOperationUndoAction: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case patch = "shop.patch" }
    var commandAction: SharedDemandAction { .patch(.init(quote: body.quote, lines: body.lines, mealEdit: body.mealEdit)) }
    public let kind: Kind
    public let body: SharedOperationUndoPatch
    private enum K: String, CodingKey { case kind, body }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["kind", "body"])
        let c = try decoder.container(keyedBy: K.self)
        kind = try c.decode(Kind.self, forKey: .kind)
        body = try c.decode(SharedOperationUndoPatch.self, forKey: .body)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(kind, forKey: .kind)
        try c.encode(body, forKey: .body)
    }
}
public struct SharedOperationUndoMetadata: Codable, Equatable, Sendable {
    public let targetOperationId: SharedDemandID
    public let effectDigest: String
    public let scope: SharedOperationUndoScope
    private enum K: String, CodingKey { case targetOperationId, effectDigest, scope }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["targetOperationId", "effectDigest", "scope"])
        let c = try decoder.container(keyedBy: K.self)
        targetOperationId = try c.decode(SharedDemandID.self, forKey: .targetOperationId)
        effectDigest = try c.decode(String.self, forKey: .effectDigest)
        scope = try c.decode(SharedOperationUndoScope.self, forKey: .scope)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(targetOperationId, forKey: .targetOperationId)
        try c.encode(effectDigest, forKey: .effectDigest)
        try c.encode(scope, forKey: .scope)
    }
}
/// Opaque identity of the unchanged, server-authorized selected store basis.
/// Store names/quote source wording are not copied into Undo history.
public struct SharedOperationUndoStoreBasis: Codable, Equatable, Sendable {
    public enum Choice: String, Codable, Sendable { case first, second }
    public let revision: Int
    public let pairId: SharedDemandID
    public let choice: Choice
    public let selectionDigest: String
    private enum K: String, CodingKey { case revision, pairId, choice, selectionDigest }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["revision", "pairId", "choice", "selectionDigest"])
        let c = try decoder.container(keyedBy: K.self)
        revision = try c.decode(Int.self, forKey: .revision)
        pairId = try c.decode(SharedDemandID.self, forKey: .pairId)
        choice = try c.decode(Choice.self, forKey: .choice)
        selectionDigest = try c.decode(String.self, forKey: .selectionDigest)
        try demandIDs([pairId])
        try demandRequire(demandRevision(revision) && selectionDigest.range(of: "^[a-f0-9]{64}$", options: .regularExpression) != nil)
    }
}
public struct SharedOperationUndoCandidate: Codable, Equatable, Sendable {
    public let schemaVersion: Int
    public let shopId: SharedDemandID
    public let base: SharedDemandActionSourceBase
    public let targetOperationId: SharedDemandID
    public let effectDigest: String
    public let scope: SharedOperationUndoScope
    public let action: SharedOperationUndoAction
    public let before: SharedDemandGraph
    public let after: SharedDemandGraph
    public let beforeTotals: [SharedDemandLineTotal]
    public let afterTotals: [SharedDemandLineTotal]
    public let beforeCheckout: ShopperBudget
    public let afterCheckout: ShopperBudget
    public let packReviewLineIds: [SharedDemandID]
    public let mealUndo: SharedOperationUndoMeal?
    public let storeBasis: SharedOperationUndoStoreBasis?
    private enum K: String, CodingKey { case schemaVersion, shopId, base, targetOperationId, effectDigest, scope, action, before, after, beforeTotals, afterTotals, beforeCheckout, afterCheckout, packReviewLineIds, mealUndo, storeBasis }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        let mealScope = try c.decode(SharedOperationUndoScope.self, forKey: .scope).mealsChanged
        let keys: Set<String> = ["schemaVersion", "shopId", "base", "targetOperationId", "effectDigest", "scope", "action", "before", "after", "beforeTotals", "afterTotals", "beforeCheckout", "afterCheckout", "packReviewLineIds"]
        try demandExactKeys(decoder, (mealScope ? keys.union(["mealUndo"]) : keys).union(c.contains(.storeBasis) ? ["storeBasis"] : []))
        storeBasis = c.contains(.storeBasis) ? try c.decode(SharedOperationUndoStoreBasis.self, forKey: .storeBasis) : nil
        mealUndo = mealScope ? try c.decode(SharedOperationUndoMeal.self, forKey: .mealUndo) : nil
        schemaVersion = try c.decode(Int.self, forKey: .schemaVersion)
        shopId = try c.decode(SharedDemandID.self, forKey: .shopId)
        try demandExactKeys(c.superDecoder(forKey: .base), ["shopRevision", "authorityEpoch", "graphRevision", "graphDigest"])
        base = try c.decode(SharedDemandActionSourceBase.self, forKey: .base)
        targetOperationId = try c.decode(SharedDemandID.self, forKey: .targetOperationId)
        effectDigest = try c.decode(String.self, forKey: .effectDigest)
        scope = try c.decode(SharedOperationUndoScope.self, forKey: .scope)
        action = try c.decode(SharedOperationUndoAction.self, forKey: .action)
        try demandRequire(mealScope == (action.body.mealEdit != nil))
        before = try c.decode(SharedDemandGraph.self, forKey: .before)
        after = try c.decode(SharedDemandGraph.self, forKey: .after)
        beforeTotals = try c.decode([SharedDemandLineTotal].self, forKey: .beforeTotals)
        afterTotals = try c.decode([SharedDemandLineTotal].self, forKey: .afterTotals)
        beforeCheckout = try c.decode(ShopperBudget.self, forKey: .beforeCheckout)
        afterCheckout = try c.decode(ShopperBudget.self, forKey: .afterCheckout)
        packReviewLineIds = try c.decode([SharedDemandID].self, forKey: .packReviewLineIds)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: K.self)
        try c.encode(schemaVersion, forKey: .schemaVersion)
        try c.encode(shopId, forKey: .shopId)
        try c.encode(base, forKey: .base)
        try c.encode(targetOperationId, forKey: .targetOperationId)
        try c.encode(effectDigest, forKey: .effectDigest)
        try c.encode(scope, forKey: .scope)
        try c.encode(action, forKey: .action)
        try c.encode(before, forKey: .before)
        try c.encode(after, forKey: .after)
        try c.encode(beforeTotals, forKey: .beforeTotals)
        try c.encode(afterTotals, forKey: .afterTotals)
        try c.encode(beforeCheckout, forKey: .beforeCheckout)
        try c.encode(afterCheckout, forKey: .afterCheckout)
        try c.encode(packReviewLineIds, forKey: .packReviewLineIds)
        try c.encodeIfPresent(mealUndo, forKey: .mealUndo)
        try c.encodeIfPresent(storeBasis, forKey: .storeBasis)
    }
}

public struct SharedOperationUndoCandidateRequest: Codable, Equatable, Sendable {
    public let targetOperationId: SharedDemandID
    public let base: SharedDemandActionSourceBase
    public init(targetOperationID: SharedDemandID, page: SharedDemandPage) throws {
        targetOperationId = targetOperationID; base = try .init(page: page); try demandIDs([targetOperationID])
    }
}
public struct SharedOperationUndoPreviewRequest: Codable, Equatable, Sendable {
    public let targetOperationId: SharedDemandID
    public let effectDigest: String
    public let base: SharedDemandActionSourceBase
    public let packs: [SharedDemandPackReview]
    public init(candidate: SharedOperationUndoCandidate, packs: [SharedDemandPackReview]) throws {
        targetOperationId = candidate.targetOperationId; effectDigest = candidate.effectDigest; base = candidate.base; self.packs = packs
        try validate(candidate: candidate)
    }
    public func validate(candidate: SharedOperationUndoCandidate) throws {
        try base.validate(); try demandIDs([targetOperationId])
        try demandRequire(targetOperationId == candidate.targetOperationId && effectDigest == candidate.effectDigest && base == candidate.base)
        try demandRequire(packs.count <= 200 && demandUnique(packs.map(\.lineId)) && Set(packs.map(\.lineId)) == Set(candidate.packReviewLineIds))
        for pack in packs {
            try pack.usablePerPack?.validate()
            try demandRequire(pack.usablePerPack != nil || pack.acceptUnresolved)
        }
    }
}
public struct SharedOperationUndoPreview: Decodable, Equatable, Sendable {
    public let preview: SharedDemandPreview
    public let operationUndo: SharedOperationUndoMetadata
    public let action: SharedOperationUndoAction
    public let beforeCheckout, afterCheckout: ShopperBudget
    public let mealUndo: SharedOperationUndoMeal?
    public let storeBasis: SharedOperationUndoStoreBasis?
    private enum K: String, CodingKey { case operationUndo, action, beforeCheckout, afterCheckout, mealUndo, storeBasis }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        operationUndo = try c.decode(SharedOperationUndoMetadata.self, forKey: .operationUndo)
        let keys: Set<String> = ["previewId", "previewDigest", "expiresAt", "before", "after", "receipt", "packs", "beforeTotals", "afterTotals", "shopRevision", "authorityEpoch", "operationUndo", "action", "beforeCheckout", "afterCheckout"]
        try demandExactKeys(decoder, (operationUndo.scope.mealsChanged ? keys.union(["mealUndo"]) : keys).union(c.contains(.storeBasis) ? ["storeBasis"] : []))
        storeBasis = c.contains(.storeBasis) ? try c.decode(SharedOperationUndoStoreBasis.self, forKey: .storeBasis) : nil
        mealUndo = operationUndo.scope.mealsChanged ? try c.decode(SharedOperationUndoMeal.self, forKey: .mealUndo) : nil
        preview = try SharedDemandPreview(from: decoder)
        action = try c.decode(SharedOperationUndoAction.self, forKey: .action)
        try demandRequire(operationUndo.scope.mealsChanged == (action.body.mealEdit != nil))
        beforeCheckout = try c.decode(ShopperBudget.self, forKey: .beforeCheckout)
        afterCheckout = try c.decode(ShopperBudget.self, forKey: .afterCheckout)
    }
}
public struct SharedOperationUndoReview: Equatable, Sendable {
    public let context: SharedDemandContext
    public let page: SharedDemandPage
    public let target: SharedOperationUndoHistoryItem
    public let shop: ShopperShop
    public let candidate: SharedOperationUndoCandidate
    public let request: SharedOperationUndoPreviewRequest
    public let response: SharedOperationUndoPreview
    public init(context: SharedDemandContext, page: SharedDemandPage, shop: ShopperShop, target: SharedOperationUndoHistoryItem,
                candidate: SharedOperationUndoCandidate, request: SharedOperationUndoPreviewRequest, response: SharedOperationUndoPreview) throws {
        self.context = context; self.page = page; self.shop = shop; self.target = target; self.candidate = candidate; self.request = request; self.response = response
        try validate()
    }
}
