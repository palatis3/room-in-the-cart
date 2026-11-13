import Foundation

/// The only persistent request Undo copy is the exact command plus the binding
/// required for retry. Private candidate/catalog/checkout history is transient.
public struct SharedRequestUndoOperationBinding: Codable, Equatable, Sendable {
    public let context: SharedDemandContext
    public let shopID, targetOperationID, reservedOperationID, previewID: SharedDemandID
    public let previewDigest: SharedRequestUndoDigest
    public let base: CommandBase
    public let action: SharedRequestUndoAction
    func body() throws -> [String: JSONValue] {
        var result = try JSONDecoder().decode([String: JSONValue].self, from: encoded(action.body))
        result["operationUndoReview"] = .object(["previewId": .string(previewID.string), "previewDigest": .string(previewDigest.value)])
        return result
    }
    @discardableResult func validate(_ operation: PendingOperation) throws -> CommandEnvelope {
        try demandRequire(operation.sharedRequestUndoBinding == self && operation.sharedDemandBinding == nil && operation.sharedTrackingBinding == nil && operation.requestQueueGrant == nil)
        try demandIDs([shopID, targetOperationID, reservedOperationID, previewID, action.body.requestId])
        try demandRequire(targetOperationID == action.body.targetOperationId && reservedOperationID != targetOperationID && base.requestRevision == action.body.baseRequestRevision)
        try demandRequire(demandRevision(base.shopRevision) && demandRevision(base.authorityEpoch) && (base.requestRevision ?? 0) > 0)
        try demandRequire(operation.householdID == context.householdID && operation.memberID == context.memberID && operation.deviceID == context.deviceID)
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        let bytes = try encoded(envelope), expected = try body()
        try demandRequire(bytes == operation.bytes && bytes.count <= 65_536)
        try demandRequire(envelope.v == 1 && envelope.clientKey == operation.clientKey && UUID(uuidString: envelope.clientKey) != nil && UUID(uuidString: envelope.replayWindow) != nil)
        try demandRequire(envelope.shopId == shopID.string && envelope.kind == "request.undoAcceptance" && envelope.base == base && envelope.body == expected)
        return envelope
    }
    func validateReceipt(_ receipt: ShopperReceipt) throws {
        try demandRequire(receipt.operationId == reservedOperationID.string && receipt.kind == "request.undoAcceptance" && receipt.shopId == shopID.string)
        try demandRequire(receipt.shopRevision == base.shopRevision + 1 && receipt.authorityEpoch == base.authorityEpoch && receipt.disposition == "acceptanceUndone")
        try demandRequire(receipt.requestId == action.body.requestId.string && receipt.requestRevision == base.requestRevision.map { $0 + 1 })
    }
}
