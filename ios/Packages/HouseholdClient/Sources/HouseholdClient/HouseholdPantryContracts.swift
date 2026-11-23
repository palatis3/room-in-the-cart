import Foundation

public typealias HouseholdPantrySession = HouseholdDeviceSession

public struct HouseholdDeviceSession: Codable, Equatable, Sendable {
    public let householdID: UUID
    public let memberID: UUID
    public let deviceID: UUID
}

public enum HouseholdPantryLocation: String, Codable, CaseIterable, Sendable {
    case pantry, fridge, freezer
}

/// The household endpoint returns physical observations. Meal names, reservations
/// and shopping-list details belong to the separately authorized shop endpoint.
public struct HouseholdPantryPage: Decodable, Equatable, Sendable {
    public struct Lot: Decodable, Equatable, Identifiable, Sendable {
        public enum Origin: String, Decodable, Sendable { case manual, delivery }
        public var id: UUID { lotId }
        public let lotId: UUID
        public let origin: Origin
        public let foodName: String
        public let location: HouseholdPantryLocation
        public let storedAt: String?
        public let useFirstAt: String?
        public let exclusionTags: [String]
        public let observation: SharedPantryPage.Observation?
        /// Original received usable evidence, distinct from a current cook balance.
        /// Missing on older servers; never infer a purchase from the live count.
        public let purchaseObservation: SharedPantryPage.Observation?

        public let receiptEvidence: HouseholdReceiptEvidence?

        func validate() throws {
            if let receiptEvidence {
                guard householdReceiptText(receiptEvidence.merchant, 256), householdReceiptDay(receiptEvidence.purchaseDay),
                      receiptEvidence.reference.map({ householdReceiptText($0, 256) }) != false else { throw ClientError.invalidResponse }
                try receiptEvidence.validate()
            }
            guard sharedMealText(foodName, 240), exclusionTags.count <= 20,
                  exclusionTags.allSatisfy({ sharedMealText($0, 240) }),
                  storedAt.map(validHelperTimestamp) != false,
                  useFirstAt.map(validHelperTimestamp) != false else { throw ClientError.invalidResponse }
            if let purchaseObservation {
                guard origin == .delivery, validHelperTimestamp(purchaseObservation.confirmedAt),
                      let quantity = purchaseObservation.quantity, quantity.validStockQuantity else { throw ClientError.invalidResponse }
            }
            if let observation {
                guard validHelperTimestamp(observation.confirmedAt), observation.quantity?.validStockQuantity != false else {
                    throw ClientError.invalidResponse
                }
            }
        }
    }

    public let v: Int
    public let householdId: UUID
    public let grantEpoch: Int
    public let pantryRevision: Int
    public let asOf: String
    public let lots: [Lot]
    public let nextCursor: UUID?

    func validate(for session: HouseholdPantrySession, after previous: Self?) throws {
        guard v == 1, householdId == session.householdID, grantEpoch >= 0, pantryRevision >= 0,
              validHelperTimestamp(asOf), lots.count <= 50, nextCursor == nil || (lots.count == 50 && nextCursor == lots.last?.id) else {
            throw ClientError.invalidResponse
        }
        var cursor = previous?.nextCursor
        if let previous {
            guard cursor != nil, previous.householdId == householdId, previous.grantEpoch == grantEpoch else { throw ClientError.accessEnded }
            guard previous.pantryRevision == pantryRevision else {
                throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
            }
        }
        for lot in lots {
            guard cursor.map({ $0.uuidString < lot.id.uuidString }) != false else { throw ClientError.invalidResponse }
            try lot.validate()
            cursor = lot.id
        }
    }
}

public struct HouseholdPantryAddition: Codable, Equatable, Sendable {
    public let foodName: String
    public let location: HouseholdPantryLocation
    public let storedAt: String?
    public let useFirstAt: String?
    public let exclusionTags: [String]
    public let confirmedAt: String
    public let quantity: SharedMealQuantity?

    public init(foodName: String, location: HouseholdPantryLocation, storedAt: String? = nil,
                useFirstAt: String? = nil, exclusionTags: [String] = [], confirmedAt: String, quantity: SharedMealQuantity?) {
        self.foodName = foodName
        self.location = location
        self.storedAt = storedAt
        self.useFirstAt = useFirstAt
        self.exclusionTags = exclusionTags
        self.confirmedAt = confirmedAt
        self.quantity = quantity
    }

    public func validate() throws {
        guard sharedMealText(foodName, 240), validHelperTimestamp(confirmedAt), quantity?.validStockQuantity != false,
              exclusionTags.count <= 20, exclusionTags.allSatisfy({ sharedMealText($0, 240) }),
              storedAt.map(validHelperTimestamp) != false, useFirstAt.map(validHelperTimestamp) != false else { throw ClientError.configuration }
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(foodName, forKey: .foodName)
        try values.encode(location, forKey: .location)
        try values.encode(storedAt, forKey: .storedAt)
        try values.encode(useFirstAt, forKey: .useFirstAt)
        try values.encode(exclusionTags, forKey: .exclusionTags)
        try values.encode(confirmedAt, forKey: .confirmedAt)
        try values.encode(quantity, forKey: .quantity)
    }
}

public struct HouseholdPantryCountCorrection: Codable, Equatable, Sendable {
    public let lotId: UUID
    public let predecessorId: UUID
    public let confirmedAt: String
    public let quantity: SharedMealQuantity?

    public init(lot: HouseholdPantryPage.Lot, confirmedAt: String, quantity: SharedMealQuantity?) throws {
        guard lot.origin == .manual, let head = lot.observation else { throw ClientError.configuration }
        lotId = lot.id
        predecessorId = head.observationId
        self.confirmedAt = confirmedAt
        self.quantity = quantity
        try validate()
    }

    func validate() throws {
        guard validHelperTimestamp(confirmedAt), quantity?.validStockQuantity != false else { throw ClientError.configuration }
    }

    private enum CodingKeys: CodingKey { case lotId, predecessorId, confirmedAt, quantity }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        lotId = try values.decode(UUID.self, forKey: .lotId)
        predecessorId = try values.decode(UUID.self, forKey: .predecessorId)
        confirmedAt = try values.decode(String.self, forKey: .confirmedAt)
        quantity = try values.decode(SharedMealQuantity?.self, forKey: .quantity)
        try validate()
    }

    public func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(lotId, forKey: .lotId)
        try values.encode(predecessorId, forKey: .predecessorId)
        try values.encode(confirmedAt, forKey: .confirmedAt)
        try values.encode(quantity, forKey: .quantity)
    }
}

public enum HouseholdPantryChange: Codable, Equatable, Sendable {
    case addition(HouseholdPantryAddition)
    case correction(HouseholdPantryCountCorrection)
    case receipt(HouseholdReceiptAcquisition)

    var kind: String {
        switch self { case .addition: "pantry.addLot"; case .correction: "pantry.correctCount"; case .receipt: "pantry.acquireReceipt" }
    }

    private enum Keys: CodingKey { case lotId, receiptId }
    public init(from decoder: Decoder) throws {
        if try decoder.container(keyedBy: Keys.self).contains(.receiptId) {
            self = .receipt(try HouseholdReceiptAcquisition(from: decoder))
        } else if try decoder.container(keyedBy: Keys.self).contains(.lotId) {
            self = .correction(try HouseholdPantryCountCorrection(from: decoder))
        } else {
            self = .addition(try HouseholdPantryAddition(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .addition(let addition): try addition.encode(to: encoder)
        case .correction(let correction): try correction.encode(to: encoder)
        case .receipt(let receipt): try receipt.encode(to: encoder)
        }
    }

    func validate() throws {
        switch self {
        case .addition(let addition): try addition.validate()
        case .correction(let correction): try correction.validate()
        case .receipt(let receipt): try receipt.validate()
        }
    }
}

public struct HouseholdPantryIntent: Codable, Equatable, Sendable {
    struct Command: Codable, Equatable, Sendable {
        let v: Int
        let kind: String
        let clientKey: UUID
        let replayWindow: UUID
        let grantEpoch: Int
        let pantryRevision: Int
        let body: HouseholdPantryChange
    }

    public let session: HouseholdPantrySession
    public let expiresAt: String
    let command: Command
    public var change: HouseholdPantryChange { command.body }
    public var id: UUID { command.clientKey }
    public var grantEpoch: Int { command.grantEpoch }

    public func validate(for expected: HouseholdPantrySession) throws {
        guard session == expected, command.v == 1, command.kind == change.kind,
              command.pantryRevision >= 0, grantEpoch >= 0, validHelperTimestamp(expiresAt) else {
            throw ClientError.configuration
        }
        try change.validate()
    }
}

public struct HouseholdPantryReceipt: Decodable, Equatable, Sendable {
    public let v: Int
    public let householdId: UUID
    public let kind: String
    public let operationId: UUID
    public struct SavedLine: Decodable, Equatable, Sendable {
        public let ordinal: Int, lotId: UUID
    }
    public let lotId: UUID?
    public let receiptId: UUID?
    public let receiptLines: [SavedLine]?
    public let savedCount: Int?
    public let grantEpoch: Int
    public let pantryRevision: Int

    func validate(_ intent: HouseholdPantryIntent) throws {
        let revision = intent.command.pantryRevision
        guard v == 1, kind == intent.command.kind, householdId == intent.session.householdID,
              grantEpoch == intent.grantEpoch, revision >= 0 && revision < Int.max,
              pantryRevision == revision + (savedCount == 0 ? 0 : 1) else { throw ClientError.invalidResponse }
        switch intent.change {
        case .receipt(let receipt):
            guard lotId == nil, receiptId != nil, let receiptLines, let savedCount, (0...receipt.lines.count).contains(savedCount),
                  receiptLines.map(\.ordinal) == receipt.lines.map(\.ordinal),
                  Set(receiptLines.map(\.lotId)).count == receiptLines.count,
                  zip(receiptLines, receipt.lines).allSatisfy({ saved, line in line.delivery.map { $0.lotId == saved.lotId } ?? true })
            else { throw ClientError.invalidResponse }
        case .addition: guard savedCount == nil, receiptLines == nil, lotId == operationId else { throw ClientError.invalidResponse }
        case .correction(let correction):
            guard savedCount == nil, receiptLines == nil, lotId == correction.lotId, operationId != lotId, operationId != correction.predecessorId else {
                throw ClientError.invalidResponse
            }
        }
    }
}

public typealias HouseholdPantryGrants = HouseholdAdultGrants

public struct HouseholdAdultGrants: Decodable, Equatable, Sendable {
    public struct Adult: Decodable, Equatable, Identifiable, Sendable {
        public var id: UUID { memberId }
        public let memberId: UUID
        public let label: String
        public let enabled: Bool
        public let grantEpoch: Int
    }

    public let v: Int
    public let adults: [Adult]
    func validate(for session: HouseholdPantrySession) throws {
        guard v == 1, Set(adults.map(\.id)).count == adults.count,
              adults.allSatisfy({ $0.id != session.memberID && sharedMealText($0.label, 240) && $0.grantEpoch >= 0 }) else {
            throw ClientError.invalidResponse
        }
    }
}
