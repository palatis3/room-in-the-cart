import Foundation

/// Private shopper-reviewed evidence. Optional on add decisions; never projected to request authors.
public struct ReviewedRequestPackEvidence: Codable, Equatable, Sendable {
    public struct Quantity: Codable, Equatable, Sendable {
        public let numerator: String
        public let denominator: String
        public let unit: String
        public let originalLiteral: String
        public init(numerator: String, denominator: String, unit: String, originalLiteral: String) {
            self.numerator=numerator; self.denominator=denominator; self.unit=unit; self.originalLiteral=originalLiteral
        }
    }
    public let version: Int
    public let offerId: String
    public let label: String
    public let needed: Quantity
    public let usablePerPack: Quantity
    public let packs: Int
    public let unitPriceMinor: Int?
    public let productMatchConfirmed: Bool
    public let availabilityConfirmed: Bool
    public let availablePackLimit: Int?
    public let quoteSource: String
    public let quoteObservedAt: String
    public let reviewedAt: String
    public init(offerId:String,label:String,needed:Quantity,usablePerPack:Quantity,packs:Int,unitPriceMinor:Int?,availablePackLimit:Int?,quoteSource:String,quoteObservedAt:Date,reviewedAt:Date) throws {
        guard !offerId.isEmpty,offerId.utf8.count<=128,!label.isEmpty,label.count<=240,(1...10_000).contains(packs),
              unitPriceMinor.map({(0...1_000_000_000).contains($0)}) ?? true,
              availablePackLimit.map({(packs...10_000).contains($0)}) ?? true,
              !quoteSource.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty,quoteSource.utf8.count<=2048,
              quoteObservedAt.timeIntervalSince1970.isFinite,reviewedAt.timeIntervalSince1970.isFinite,
              quoteObservedAt<=reviewedAt.addingTimeInterval(300) else { throw ClientError.configuration }
        for quantity in [needed,usablePerPack] {
            guard let numerator=Int64(quantity.numerator),numerator>0,let denominator=Int64(quantity.denominator),denominator>0,
                  String(numerator)==quantity.numerator,String(denominator)==quantity.denominator,
                  ["count","gram","kilogram","ounce","pound","milliliter","liter","fluidOunce","cup"].contains(quantity.unit),quantity.originalLiteral.utf8.count<=2048 else { throw ClientError.configuration }
        }
        version=1;self.offerId=offerId;self.label=label;self.needed=needed;self.usablePerPack=usablePerPack;self.packs=packs;self.unitPriceMinor=unitPriceMinor
        productMatchConfirmed=true;availabilityConfirmed=true;self.availablePackLimit=availablePackLimit;self.quoteSource=quoteSource
        let format=ISO8601DateFormatter(); self.quoteObservedAt=format.string(from:quoteObservedAt);self.reviewedAt=format.string(from:reviewedAt)
    }
    private enum CodingKeys:String,CodingKey {case version,offerId,label,needed,usablePerPack,packs,unitPriceMinor,productMatchConfirmed,availabilityConfirmed,availablePackLimit,quoteSource,quoteObservedAt,reviewedAt}
    public func encode(to encoder:Encoder)throws {
        var c=encoder.container(keyedBy:CodingKeys.self)
        try c.encode(version,forKey:.version);try c.encode(offerId,forKey:.offerId);try c.encode(label,forKey:.label)
        try c.encode(needed,forKey:.needed);try c.encode(usablePerPack,forKey:.usablePerPack);try c.encode(packs,forKey:.packs)
        try c.encode(unitPriceMinor,forKey:.unitPriceMinor);try c.encode(productMatchConfirmed,forKey:.productMatchConfirmed)
        try c.encode(availabilityConfirmed,forKey:.availabilityConfirmed);try c.encode(availablePackLimit,forKey:.availablePackLimit)
        try c.encode(quoteSource,forKey:.quoteSource);try c.encode(quoteObservedAt,forKey:.quoteObservedAt);try c.encode(reviewedAt,forKey:.reviewedAt)
    }
}
