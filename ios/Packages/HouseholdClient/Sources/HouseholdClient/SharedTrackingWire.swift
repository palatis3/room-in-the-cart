import Foundation

// V1 DTOs remain unchanged. The v2 reader closes unknown-key holes in the reused
// graph/quantity/pack DTOs before decoding them; optional sourceExclusions stays
// optional, while required JSON nulls must actually be present.
private struct TrackingKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
    init(_ value: String) { stringValue = value }
}
indirect enum TrackingWireShape {
    case scalar, nullable(TrackingWireShape), array(TrackingWireShape)
    case object([String: TrackingWireShape], optional: [String: TrackingWireShape] = [:])
    case graph, contribution, quantity, restriction, pack, total

    func validate(_ decoder: Decoder) throws {
        switch self {
        case .scalar: break // The reused typed decoder validates the scalar type.
        case .nullable(let shape):
            if try !decoder.singleValueContainer().decodeNil() { try shape.validate(decoder) }
        case .array(let shape):
            var c = try decoder.unkeyedContainer()
            while !c.isAtEnd { try shape.validate(c.superDecoder()) }
        case .object(let fields, let optional):
            let c = try decoder.container(keyedBy: TrackingKey.self), keys = Set(c.allKeys.map(\.stringValue))
            try demandRequire(Set(fields.keys).isSubset(of: keys) && keys.isSubset(of: Set(fields.keys).union(optional.keys)))
            for (key, shape) in fields { try shape.validate(c.superDecoder(forKey: TrackingKey(key))) }
            for (key, shape) in optional where keys.contains(key) { try shape.validate(c.superDecoder(forKey: TrackingKey(key))) }
        case .quantity:
            try TrackingWireShape.object([
                "amount": .object(["numerator": .scalar, "denominator": .scalar]), "unit": .scalar, "originalLiteral": .scalar,
                "confirmedConversion": .nullable(.object(["sourceUnit": .scalar, "targetUnit": .scalar,
                    "targetAmountPerSourceUnit": .object(["numerator": .scalar, "denominator": .scalar]), "sourceNote": .scalar, "confirmedAt": .scalar]))
            ]).validate(decoder)
        case .restriction:
            try TrackingWireShape.object(["occurrenceId": .scalar, "ingredientId": .scalar, "label": .scalar, "resolution": .scalar]).validate(decoder)
            // SharedDemandExclusionResolution already enforces discriminated exact keys.
        case .contribution:
            try TrackingWireShape.object(["id": .scalar, "lineId": .scalar, "source": .scalar, "productKey": .scalar,
                "productName": .scalar, "originalText": .scalar, "quantity": .nullable(.quantity), "exclusions": .scalar,
                "contains": .scalar, "removedAt": .scalar], optional: ["sourceExclusions": .array(.restriction)]).validate(decoder)
        case .graph:
            try TrackingWireShape.object(["schemaVersion": .scalar, "conversionTableVersion": .scalar, "householdId": .scalar,
                "shopId": .scalar, "revision": .scalar, "usedIds": .scalar,
                "lines": .array(.object(["id": .scalar, "name": .scalar, "unit": .scalar, "originalOrder": .scalar, "trashedAt": .scalar])),
                "contributions": .array(.contribution),
                "edges": .array(.object(["id": .scalar, "kind": .scalar, "demandId": .scalar, "supplyId": .scalar,
                    "quantity": .quantity, "confirmation": .object(["productMatchConfirmed": .scalar, "confirmedAt": .scalar, "evidence": .scalar])]))
            ]).validate(decoder)
        case .pack:
            try TrackingWireShape.object(["lineId": .scalar, "usablePerPack": .nullable(.quantity), "acceptUnresolved": .scalar]).validate(decoder)
        case .total:
            try TrackingWireShape.object(["lineId": .scalar, "unit": .scalar,
                "quantity": .nullable(.object(["numerator": .scalar, "denominator": .scalar])), "activeContributionIds": .scalar]).validate(decoder)
        }
    }
}
func trackingDecode<T: Decodable>(_ type: T.Type, from decoder: Decoder, shape: TrackingWireShape) throws -> T {
    try shape.validate(decoder)
    return try T(from: decoder)
}

/// The entry point caps route bytes before JSON parsing. Individual DTO decoders
/// also enforce exact shapes and structure, including required-null presence.
public enum SharedTrackingWire {
    public static let maximumResponseBytes = 1_800_000
    public static func page(from data: Data) throws -> SharedTrackingPage {
        try demandRequire(data.count <= maximumResponseBytes)
        return try JSONDecoder().decode(SharedTrackingPage.self, from: data)
    }
    public static func history(from data: Data) throws -> SharedTrackingHistory {
        try demandRequire(data.count <= maximumResponseBytes)
        return try JSONDecoder().decode(SharedTrackingHistory.self, from: data)
    }
}
