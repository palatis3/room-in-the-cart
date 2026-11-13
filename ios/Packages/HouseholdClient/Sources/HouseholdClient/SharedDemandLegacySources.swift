import Foundation

/// Server-selected adoption sources. The app chooses matches and explicit
/// quantities; it does not reconstruct protected bindings or accepted revisions.
public struct SharedDemandLegacySources: Codable, Equatable, Sendable {
    public let sources: [SharedDemandLegacySource]
}
public struct SharedDemandLegacySource: Codable, Equatable, Sendable {
    public let id: SharedDemandID
    public let source: SharedDemandSource
    public let sourceLabel, productName, originalText: String
    @SharedDemandNullable public var originalQuantityText: String?
    @SharedDemandNullable public var quantity: SharedDemandQuantity?
    public let sourceExclusions: [SharedDemandSourceExclusion]
    @SharedDemandNullable public var requiredLineId: SharedDemandID?
}
extension SharedDemandLegacySources {
    func validate() throws {
        try demandRequire(sources.count <= 2000 && demandUnique(sources.map(\.id)))
        let identities = sources.compactMap { $0.source.identityKey }
        try demandRequire(identities.count == sources.count && demandUnique(identities))
        for row in sources {
            try demandIDs([row.id, row.requiredLineId]); try row.source.validate()
            try demandRequire(demandText(row.sourceLabel) && demandText(row.productName) && demandText(row.originalText))
            try demandRequire(row.originalQuantityText.map { demandText($0) } ?? true)
            switch row.source {
            case .manual, .imported: throw ClientError.invalidResponse
            case .request:
                try demandRequire(row.requiredLineId != nil && row.quantity == nil && row.sourceExclusions.isEmpty)
            case .meal, .reservation: try demandRequire(row.requiredLineId == nil)
            }
            try demandRequire(row.sourceExclusions.allSatisfy { $0.resolution == .unresolved })
            try SharedDemandContribution(id: row.id, lineId: row.requiredLineId ?? row.id, source: row.source,
                productKey: nil, productName: row.productName, originalText: row.originalText, quantity: row.quantity,
                sourceExclusions: row.sourceExclusions).validate()
        }
    }
}
