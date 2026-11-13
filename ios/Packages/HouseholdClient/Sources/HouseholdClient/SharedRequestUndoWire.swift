import Foundation

let requestUndoBasketShape = TrackingWireShape.array(.object(["lineId": .scalar, "originalItem": .scalar, "packs": .scalar, "unitPriceMinor": .scalar, "feeEligible": .scalar]))
let requestUndoBudgetShape = TrackingWireShape.object(["currency": .scalar, "totalMinor": .scalar, "overCapMinor": .scalar,
    "headroomMinor": .scalar, "status": .scalar, "scope": .scalar, "missing": .scalar, "lowerBoundMinor": .scalar,
    "upperBoundMinor": .scalar, "wholeCheckoutWithinCap": .scalar])
func requestUndoQuoteShape(_ decoder: Decoder) throws {
    enum K: String, CodingKey { case fee, kind }
    try demandExactKeys(decoder, ["currency", "scope", "complete", "capMinor", "capScope", "fee", "taxesMinor", "depositsMinor", "discountsMinor", "observedAt", "expiresAt"])
    let c = try decoder.container(keyedBy: K.self), fee = try c.superDecoder(forKey: .fee)
    let kind = try fee.container(keyedBy: K.self).decode(String.self, forKey: .kind)
    switch kind {
    case "fixed": try demandExactKeys(fee, ["kind", "amountMinor"])
    case "threshold": try demandExactKeys(fee, ["kind", "thresholdMinor", "belowMinor", "aboveMinor"])
    default: throw ClientError.invalidResponse
    }
}
func requestUndoReceipt(_ decoder: Decoder) throws -> SharedDemandReceipt {
    let line = TrackingWireShape.object(["id": .scalar, "name": .scalar, "unit": .scalar, "originalOrder": .scalar, "trashedAt": .scalar])
    let edge = TrackingWireShape.object(["id": .scalar, "kind": .scalar, "demandId": .scalar, "supplyId": .scalar, "quantity": .quantity,
        "confirmation": .object(["productMatchConfirmed": .scalar, "confirmedAt": .scalar, "evidence": .scalar])])
    func delta(_ shape: TrackingWireShape) -> TrackingWireShape { .array(.object(["id": .scalar, "before": .nullable(shape), "after": .nullable(shape)])) }
    return try trackingDecode(SharedDemandReceipt.self, from: decoder, shape: .object(["schemaVersion": .scalar, "operationId": .scalar,
        "householdId": .scalar, "shopId": .scalar, "baseRevision": .scalar, "resultRevision": .scalar,
        "lines": delta(line), "contributions": delta(.contribution), "edges": delta(edge)]))
}
func requestUndoBudget(_ value: ShopperBudget) throws {
    let maxMoney = 9_007_199_254_740_991
    try demandRequire(value.currency == "USD" && ["withinCap", "overCap", "unresolved", "scopeMismatch"].contains(value.status))
    try demandRequire(["wholeCheckout", "item", "dinner"].contains(value.scope) && (0...maxMoney).contains(value.lowerBoundMinor))
    try demandRequire([value.totalMinor, value.overCapMinor, value.upperBoundMinor].compactMap { $0 }.allSatisfy { (0...maxMoney).contains($0) })
    try demandRequire(value.headroomMinor.map { (-maxMoney...maxMoney).contains($0) } ?? true)
    try demandRequire(value.upperBoundMinor.map { $0 >= value.lowerBoundMinor } ?? true)
    let missing = ["remaining_original_items", "line_price", "fee", "tax", "deposit", "discount", "cap", "scope_mismatch"]
    try demandRequire(value.missing.count <= 8 && value.missing.allSatisfy(missing.contains))
    if value.wholeCheckoutWithinCap { try demandRequire(value.scope == "wholeCheckout" && value.status == "withinCap" && value.totalMinor != nil) }
}

public enum SharedRequestUndoWire {
    public static let maximumResponseBytes = 1_800_000
    public static func candidate(from data: Data) throws -> SharedRequestUndoCandidate {
        try demandRequire(data.count <= maximumResponseBytes); return try JSONDecoder().decode(SharedRequestUndoCandidate.self, from: data)
    }
    public static func preview(from data: Data) throws -> SharedRequestUndoPreview {
        try demandRequire(data.count <= maximumResponseBytes); return try JSONDecoder().decode(SharedRequestUndoPreview.self, from: data)
    }
}
