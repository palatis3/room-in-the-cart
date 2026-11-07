import Foundation

public struct ShopperFinancialEntry: Codable, Equatable, Identifiable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable {
        case postedCharge, postedTopUp, pendingCredit, postedCredit, includedCredit, paymentHold, holdRelease
    }
    public let id, evidenceKey: UUID
    public let kind: Kind
    public let amountMinor: Int
    public let currency: String
    public let occurredAt, sourceText: String
    public let creditId, chargeEvidenceKey, holdEvidenceKey: UUID?

    public init(kind: Kind, amountMinor: Int, occurredAt: String, sourceText: String,
                creditId: UUID? = nil, chargeEvidenceKey: UUID? = nil, holdEvidenceKey: UUID? = nil) {
        id = UUID(); evidenceKey = UUID()
        self.kind = kind; self.amountMinor = amountMinor; currency = "USD"
        self.occurredAt = occurredAt; self.sourceText = sourceText
        self.creditId = creditId; self.chargeEvidenceKey = chargeEvidenceKey; self.holdEvidenceKey = holdEvidenceKey
    }

    fileprivate var fields: [String: JSONValue] {
        func key(_ value: UUID?) -> JSONValue { value.map { .string($0.uuidString.lowercased()) } ?? .null }
        return ["id": key(id), "evidenceKey": key(evidenceKey), "kind": .string(kind.rawValue), "amountMinor": .integer(amountMinor),
                "currency": .string(currency), "occurredAt": .string(occurredAt), "sourceText": .string(sourceText),
                "creditId": key(creditId), "chargeEvidenceKey": key(chargeEvidenceKey), "holdEvidenceKey": key(holdEvidenceKey)]
    }
}

public struct ShopperFinancialRecord: Equatable, Sendable {
    public let shopID: UUID
    public let version: HistorySourceVersion
    public let entries: [ShopperFinancialEntry]
}

struct ShopperFinancialPage: Decodable, Sendable {
    let shopId: UUID
    let sourceVersion: HistorySourceVersion
    let evidenceSource: String
    let entries: [ShopperFinancialEntry]
    let nextCursor: UUID?
}

public enum ShopperFinancialAction: Codable, Equatable, Sendable {
    case append(ShopperFinancialEntry)
    case close
}

/// The reviewed source version and operation key stay together across retries.
public struct ShopperFinancialIntent: Codable, Equatable, Sendable {
    public let clientKey: UUID
    public let subject, householdID, memberID, deviceID: String
    public let shopID: UUID
    public let version: HistorySourceVersion
    public let action: ShopperFinancialAction

    var endpoint: String {
        switch action { case .append: "financial-evidence"; case .close: "financial-reviews" }
    }
    var body: [String: JSONValue] {
        var fields: [String: JSONValue] = ["clientKey": .string(clientKey.uuidString.lowercased()), "sourceVersion": .object([
            "shopRevision": .integer(version.shopRevision), "authorityEpoch": .integer(version.authorityEpoch),
            "financialRevision": .integer(version.financialRevision)])]
        switch action {
        case .append(let entry): fields["entry"] = .object(entry.fields)
        case .close: fields["allEvidenceEntered"] = .bool(false); fields["closeShop"] = .bool(true)
        }
        return fields
    }
}

struct ShopperFinancialReceipt: Decodable, Sendable {
    let shopId: UUID
    let sourceVersion: HistorySourceVersion
    let entryId, reviewId: UUID?
    let recorded, appShopClosed, allEvidenceEntered: Bool?
    let evidenceSource: String?

    func validate(_ intent: ShopperFinancialIntent) throws {
        try sourceVersion.validate()
        let version = intent.version
        guard shopId == intent.shopID, sourceVersion.authorityEpoch == version.authorityEpoch else { throw ClientError.invalidResponse }
        switch intent.action {
        case .append(let entry):
            guard recorded == true, evidenceSource == "shopper_reported", entryId == entry.id,
                  sourceVersion.shopRevision == version.shopRevision,
                  sourceVersion.financialRevision - 1 == version.financialRevision else { throw ClientError.invalidResponse }
        case .close:
            guard reviewId != nil, appShopClosed == true, allEvidenceEntered == false,
                  sourceVersion.financialRevision == version.financialRevision,
                  sourceVersion.shopRevision == version.shopRevision || sourceVersion.shopRevision - 1 == version.shopRevision else { throw ClientError.invalidResponse }
        }
    }
}
