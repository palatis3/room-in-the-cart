import Foundation

/// Only the exact action/token and scope needed for retry are persisted. Catalog,
/// inverse disclosure and prior source history are not copied into the outbox.
public struct SharedTrackingOperationBinding: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, Sendable { case apply, freeze }
    public let kind: Kind
    public let mode: String
    public let context: SharedDemandContext
    public let shopID: SharedDemandID
    public let base: CommandBase
    public let graphRevision, privacyRevision: Int
    public let stateDigest: String
    public let previewID: SharedDemandID
    public let previewDigest: String
    public let action: SharedTrackingAction?
    public let targetOperationID: SharedDemandID?

    func body() throws -> [String: JSONValue] {
        let token: JSONValue = .object(["previewId": .string(previewID.string), "previewDigest": .string(previewDigest), "trackingVersion": .integer(2)])
        switch kind {
        case .apply:
            guard let action else { throw ClientError.invalidResponse }
            guard case .object(let value) = action.wire, case .object(var body) = value["body"] else { throw ClientError.invalidResponse }
            body["demandReview"] = token; return body
        case .freeze: return ["trackingReview": token]
        }
    }
    var commandKind: String { kind == .freeze ? "shop.freeze" : action?.command.kind ?? "" }
    @discardableResult func validate(_ operation: PendingOperation) throws -> CommandEnvelope {
        try demandRequire(operation.sharedRequestUndoBinding == nil && operation.sharedDemandBinding == nil && operation.sharedTrackingBinding == self && operation.requestQueueGrant == nil)
        try demandRequire(operation.householdID == context.householdID && operation.memberID == context.memberID && operation.deviceID == context.deviceID)
        try demandRequire(demandRevision(base.shopRevision) && base.shopRevision < Int(Int32.max) && demandRevision(base.authorityEpoch) && demandRevision(graphRevision, zero: true) && demandRevision(privacyRevision, zero: true))
        try demandRequire([previewDigest, stateDigest].allSatisfy { $0.range(of: "^[0-9a-f]{64}$", options: .regularExpression) != nil })
        if kind == .apply {
            try demandRequire(["adopt", "change", "review", "firstAdoptionUndo", "rebind", "recover"].contains(mode) && action != nil && graphRevision > 0)
            try demandRequire((mode == "firstAdoptionUndo") == (targetOperationID != nil))
        } else { try demandRequire(mode == "freeze" && action == nil && targetOperationID == nil && base.requestRevision == nil) }
        if case .request = action?.command { try demandRequire(base.requestRevision.map { demandRevision($0) && $0 < Int(Int32.max) } == true && ["change", "adopt"].contains(mode)) }
        else { try demandRequire(base.requestRevision == nil) }
        let envelope = try JSONDecoder().decode(CommandEnvelope.self, from: operation.bytes)
        let expectedBytes = try encoded(envelope)
        try demandRequire(operation.bytes == expectedBytes && operation.bytes.count <= 65_536)
        try demandRequire(envelope.v == 1 && envelope.clientKey == operation.clientKey && UUID(uuidString: envelope.clientKey) != nil && UUID(uuidString: envelope.replayWindow) != nil)
        let expectedBody = try body()
        try demandRequire(envelope.shopId == shopID.string && envelope.kind == commandKind && envelope.base == base && envelope.body == expectedBody)
        return envelope
    }
    func validateReceipt(_ receipt: ShopperReceipt) throws {
        guard let operationID = UUID(uuidString: receipt.operationId) else { throw ClientError.invalidResponse }
        try demandRequire(SharedDemandID(operationID).valid && receipt.operationId == operationID.uuidString.lowercased())
        try demandRequire(receipt.shopId == shopID.string && receipt.kind == commandKind && receipt.shopRevision == base.shopRevision + 1 && receipt.authorityEpoch == base.authorityEpoch)
        if kind == .freeze { try demandRequire(receipt.disposition == "frozen" && receipt.requestId == nil && receipt.requestRevision == nil) }
        else if case .request(let request) = action?.command {
            try demandRequire(receipt.disposition == "added" && receipt.requestId == request.requestId.string && receipt.requestRevision == base.requestRevision.map { $0 + 1 })
        } else { try demandRequire(receipt.disposition == "patched" && receipt.requestId == nil && receipt.requestRevision == nil) }
        // R2 does not expose the reserved operation ID before Apply. The server's
        // immutable clientKey/replay-window record binds that ID; do not invent it.
    }
}
