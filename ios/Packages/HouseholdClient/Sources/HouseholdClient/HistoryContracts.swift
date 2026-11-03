import Foundation

public enum HistoryPriceChannel: String, Codable, CaseIterable, Sendable { case storeShelf, warehouse, retailerWebsite, retailerApp, other, unspecified }
public enum HistoryFulfillmentMode: String, Codable, CaseIterable, Sendable { case pickup, delivery, inStore }
public enum HistoryUnit: String, Codable, CaseIterable, Sendable { case count, gram, kilogram, ounce, pound, milliliter, liter, fluidOunce, cup }

public enum HistoryCostEvidence: Codable, Equatable, Sendable {
    case exact(minor: Int)
    case bounded(lowerMinor: Int, upperMinor: Int, reason: String)
    case unknown(reason: String)
    private enum Keys: String, CodingKey { case kind, minor, lowerMinor, upperMinor, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "exact": self = .exact(minor: try c.decode(Int.self, forKey: .minor))
        case "bounded": self = .bounded(lowerMinor: try c.decode(Int.self, forKey: .lowerMinor), upperMinor: try c.decode(Int.self, forKey: .upperMinor), reason: try c.decode(String.self, forKey: .reason))
        case "unknown": self = .unknown(reason: try c.decode(String.self, forKey: .reason))
        default: throw ClientError.invalidResponse
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .exact(let minor): try c.encode("exact", forKey: .kind); try c.encode(minor, forKey: .minor)
        case .bounded(let lower, let upper, let reason):
            try c.encode("bounded", forKey: .kind); try c.encode(lower, forKey: .lowerMinor); try c.encode(upper, forKey: .upperMinor); try c.encode(reason, forKey: .reason)
        case .unknown(let reason): try c.encode("unknown", forKey: .kind); try c.encode(reason, forKey: .reason)
        }
    }
    public func validate() throws {
        switch self {
        case .exact(let minor): guard HistoryValidation.cents(minor) else { throw ClientError.configuration }
        case .bounded(let lower, let upper, let reason): guard HistoryValidation.cents(lower), HistoryValidation.cents(upper), lower <= upper, HistoryValidation.text(reason, 2048) else { throw ClientError.configuration }
        case .unknown(let reason): guard HistoryValidation.text(reason, 2048) else { throw ClientError.configuration }
        }
    }
}
public struct HistoryUsablePack: Codable, Equatable, Sendable {
    public struct Amount: Codable, Equatable, Sendable {
        public var numerator: Int; public var denominator: Int
        public init(numerator: Int, denominator: Int) throws {
            guard (1...1_000_000_000_000).contains(numerator), (1...1_000_000_000_000).contains(denominator) else { throw ClientError.configuration }
            self.numerator = numerator; self.denominator = denominator
        }
    }
    public var amount: Amount; public var unit: HistoryUnit; public var originalLiteral: String
    public init(amount: Amount, unit: HistoryUnit, originalLiteral: String) throws {
        self.amount = amount; self.unit = unit; self.originalLiteral = originalLiteral; try validate()
    }
    public func validate() throws {
        _ = try Amount(numerator: amount.numerator, denominator: amount.denominator)
        guard HistoryValidation.text(originalLiteral, 512) else { throw ClientError.configuration }
    }
}
public struct HistoryPriceObservation: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var shopId: String; public var itemName: String; public var packLabel: String
    public var usablePack: HistoryUsablePack?; public var price: HistoryCostEvidence; public var currency: String
    public var store: String; public var branch: String; public var channel: HistoryPriceChannel; public var mode: HistoryFulfillmentMode
    public var eligibility: String; public var observedAt: String; public var sourceText: String; public var sourceLocale: String
    public init(id: String = UUID().uuidString.lowercased(), shopId: String, itemName: String, packLabel: String,
                usablePack: HistoryUsablePack?, price: HistoryCostEvidence, store: String, branch: String,
                channel: HistoryPriceChannel, mode: HistoryFulfillmentMode, eligibility: String,
                observedAt: String, sourceText: String, sourceLocale: String) throws {
        self.id = id; self.shopId = shopId; self.itemName = itemName; self.packLabel = packLabel; self.usablePack = usablePack
        self.price = price; currency = "USD"; self.store = store; self.branch = branch; self.channel = channel; self.mode = mode
        self.eligibility = eligibility; self.observedAt = observedAt; self.sourceText = sourceText; self.sourceLocale = sourceLocale
        try validate()
    }
    public func validate() throws {
        guard HistoryValidation.ids([id, shopId]), currency == "USD", HistoryValidation.date(observedAt) != nil,
              [itemName, packLabel, store, branch, sourceLocale].allSatisfy({ HistoryValidation.text($0, 512) }),
              HistoryValidation.text(eligibility, 2048, empty: true), HistoryValidation.text(sourceText, 8192) else { throw ClientError.configuration }
        try usablePack?.validate(); try price.validate()
    }
    private enum CodingKeys: String, CodingKey { case id, shopId, itemName, packLabel, usablePack, price, currency, store, branch, channel, mode, eligibility, observedAt, sourceText, sourceLocale }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(shopId, forKey: .shopId); try c.encode(itemName, forKey: .itemName); try c.encode(packLabel, forKey: .packLabel)
        try c.encode(usablePack, forKey: .usablePack); try c.encode(price, forKey: .price); try c.encode(currency, forKey: .currency)
        try c.encode(store, forKey: .store); try c.encode(branch, forKey: .branch); try c.encode(channel, forKey: .channel); try c.encode(mode, forKey: .mode)
        try c.encode(eligibility, forKey: .eligibility); try c.encode(observedAt, forKey: .observedAt); try c.encode(sourceText, forKey: .sourceText); try c.encode(sourceLocale, forKey: .sourceLocale)
    }
}
public enum HistoryReservationState: Codable, Equatable, Sendable {
    case reserved, released, applied(shopID: String)
    private enum Keys: String, CodingKey { case kind, shopId }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "reserved": self = .reserved
        case "released": self = .released
        case "applied": self = .applied(shopID: try c.decode(String.self, forKey: .shopId))
        default: throw ClientError.invalidResponse
        }
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .reserved: try c.encode("reserved", forKey: .kind)
        case .released: try c.encode("released", forKey: .kind)
        case .applied(let shopID): try c.encode("applied", forKey: .kind); try c.encode(shopID, forKey: .shopId)
        }
    }
}
public struct HistoryFutureReservation: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var originalText: String; public var amountMinor: Int; public var plannedAt: String; public var state: HistoryReservationState
    public init(id: String = UUID().uuidString.lowercased(), originalText: String, amountMinor: Int, plannedAt: String, state: HistoryReservationState) throws {
        self.id = id; self.originalText = originalText; self.amountMinor = amountMinor; self.plannedAt = plannedAt; self.state = state; try validate()
    }
    public func validate() throws {
        guard HistoryValidation.ids([id]), HistoryValidation.text(originalText, 2048), HistoryValidation.cents(amountMinor), HistoryValidation.date(plannedAt) != nil else { throw ClientError.configuration }
        if case .applied(let shopID) = state, !HistoryValidation.ids([shopID]) { throw ClientError.configuration }
    }
}
public struct HistoryBudgetPeriod: Codable, Equatable, Identifiable, Sendable {
    public var id: String; public var title: String; public var startsAt: String; public var endsAt: String; public var timeZoneId: String
    public var currency: String; public var shopBudgetMinor: Int; public var alreadyExcludedReserveMinor: Int?
    public var shopIds: [String]; public var reservations: [HistoryFutureReservation]; public var reviewedCompleteAt: String?
    public init(id: String = UUID().uuidString.lowercased(), title: String, startsAt: String, endsAt: String, timeZoneId: String,
                shopBudgetMinor: Int, alreadyExcludedReserveMinor: Int?, shopIds: [String], reservations: [HistoryFutureReservation], reviewedCompleteAt: String?) throws {
        self.id = id; self.title = title; self.startsAt = startsAt; self.endsAt = endsAt; self.timeZoneId = timeZoneId; currency = "USD"
        self.shopBudgetMinor = shopBudgetMinor; self.alreadyExcludedReserveMinor = alreadyExcludedReserveMinor
        self.shopIds = shopIds; self.reservations = reservations; self.reviewedCompleteAt = reviewedCompleteAt; try validate()
    }
    public func validate() throws {
        guard HistoryValidation.ids([id]), HistoryValidation.text(title, 512), HistoryValidation.text(timeZoneId, 100), TimeZone(identifier: timeZoneId) != nil,
              let start = HistoryValidation.date(startsAt), let end = HistoryValidation.date(endsAt), start < end, currency == "USD",
              HistoryValidation.cents(shopBudgetMinor), alreadyExcludedReserveMinor.map(HistoryValidation.cents) ?? true,
              shopIds.count <= 100, HistoryValidation.uniqueIDs(shopIds), reservations.count <= 1000,
              HistoryValidation.uniqueIDs(reservations.map(\.id)) else { throw ClientError.configuration }
        for reservation in reservations {
            try reservation.validate()
            if case .applied(let shopID) = reservation.state, !shopIds.contains(where: { HistoryValidation.sameID($0, shopID) }) { throw ClientError.configuration }
        }
        if let reviewedCompleteAt {
            guard let reviewed = HistoryValidation.date(reviewedCompleteAt), reviewed >= end,
                  !reservations.contains(where: { $0.state == .reserved }) else { throw ClientError.configuration }
        }
    }
    private enum CodingKeys: String, CodingKey { case id, title, startsAt, endsAt, timeZoneId, currency, shopBudgetMinor, alreadyExcludedReserveMinor, shopIds, reservations, reviewedCompleteAt }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id); try c.encode(title, forKey: .title); try c.encode(startsAt, forKey: .startsAt); try c.encode(endsAt, forKey: .endsAt)
        try c.encode(timeZoneId, forKey: .timeZoneId); try c.encode(currency, forKey: .currency); try c.encode(shopBudgetMinor, forKey: .shopBudgetMinor)
        try c.encode(alreadyExcludedReserveMinor, forKey: .alreadyExcludedReserveMinor); try c.encode(shopIds, forKey: .shopIds)
        try c.encode(reservations, forKey: .reservations); try c.encode(reviewedCompleteAt, forKey: .reviewedCompleteAt)
    }
}

public struct HistorySourceVersion: Codable, Equatable, Sendable {
    public let shopRevision: Int; public let authorityEpoch: Int; public let financialRevision: Int
    public init(shopRevision: Int, authorityEpoch: Int, financialRevision: Int) { self.shopRevision = shopRevision; self.authorityEpoch = authorityEpoch; self.financialRevision = financialRevision }
    func validate() throws { guard shopRevision > 0, authorityEpoch > 0, financialRevision >= 0 else { throw ClientError.invalidResponse } }
}
public struct HistoryMoneyRange: Codable, Equatable, Sendable {
    public let lowerMinor: Int; public let upperMinor: Int?
    public init(lowerMinor: Int, upperMinor: Int?) { self.lowerMinor = lowerMinor; self.upperMinor = upperMinor }
    func validate() throws { guard HistoryValidation.safe(lowerMinor), upperMinor.map({ HistoryValidation.safe($0) && $0 >= lowerMinor }) ?? true else { throw ClientError.invalidResponse } }
}
public struct HistoryShopBudgetSummary: Codable, Equatable, Sendable {
    public let shopId: String; public let sourceVersion: HistorySourceVersion; public let currency: String
    public let postedNetMinor: Int; public let pendingCreditsMinor: Int; public let includedCreditsMinor: Int; public let paymentHoldsMinor: Int
    public let expectedUnpaid: HistoryMoneyRange; public let projectedCommitment: HistoryMoneyRange; public let reconciledEntered: Bool
    public init(shopId: String, sourceVersion: HistorySourceVersion, currency: String = "USD", postedNetMinor: Int, pendingCreditsMinor: Int, includedCreditsMinor: Int, paymentHoldsMinor: Int, expectedUnpaid: HistoryMoneyRange, projectedCommitment: HistoryMoneyRange, reconciledEntered: Bool) {
        self.shopId = shopId; self.sourceVersion = sourceVersion; self.currency = currency; self.postedNetMinor = postedNetMinor
        self.pendingCreditsMinor = pendingCreditsMinor; self.includedCreditsMinor = includedCreditsMinor; self.paymentHoldsMinor = paymentHoldsMinor
        self.expectedUnpaid = expectedUnpaid; self.projectedCommitment = projectedCommitment; self.reconciledEntered = reconciledEntered
    }
    func validate() throws {
        guard HistoryValidation.ids([shopId]), currency == "USD", HistoryValidation.safe(postedNetMinor),
              [pendingCreditsMinor, includedCreditsMinor, paymentHoldsMinor].allSatisfy({ $0 >= 0 && HistoryValidation.safe($0) }),
              !reconciledEntered || (pendingCreditsMinor == 0 && paymentHoldsMinor == 0) else { throw ClientError.invalidResponse }
        try sourceVersion.validate(); try expectedUnpaid.validate(); try projectedCommitment.validate()
    }
}
public struct HistoryPermittedSubtotal: Codable, Equatable, Sendable {
    public let shops: [HistoryShopBudgetSummary]; public let currency: String; public let postedNetMinor: Int
    public let pendingCreditsMinor: Int; public let includedCreditsMinor: Int; public let paymentHoldsMinor: Int
    public let expectedUnpaid: HistoryMoneyRange; public let projectedCommitment: HistoryMoneyRange
    public init(shops: [HistoryShopBudgetSummary], currency: String = "USD", postedNetMinor: Int, pendingCreditsMinor: Int, includedCreditsMinor: Int, paymentHoldsMinor: Int, expectedUnpaid: HistoryMoneyRange, projectedCommitment: HistoryMoneyRange) {
        self.shops = shops; self.currency = currency; self.postedNetMinor = postedNetMinor; self.pendingCreditsMinor = pendingCreditsMinor
        self.includedCreditsMinor = includedCreditsMinor; self.paymentHoldsMinor = paymentHoldsMinor
        self.expectedUnpaid = expectedUnpaid; self.projectedCommitment = projectedCommitment
    }
    func validate(allowedShopIDs: [String]? = nil) throws {
        guard currency == "USD", shops.count <= 100, HistoryValidation.uniqueIDs(shops.map(\.shopId)) else { throw ClientError.invalidResponse }
        for shop in shops {
            try shop.validate()
            if let allowedShopIDs, !allowedShopIDs.contains(where: { HistoryValidation.sameID($0, shop.shopId) }) { throw ClientError.invalidResponse }
        }
        guard try postedNetMinor == HistoryValidation.sum(shops.map(\.postedNetMinor)),
              try pendingCreditsMinor == HistoryValidation.sum(shops.map(\.pendingCreditsMinor)),
              try includedCreditsMinor == HistoryValidation.sum(shops.map(\.includedCreditsMinor)),
              try paymentHoldsMinor == HistoryValidation.sum(shops.map(\.paymentHoldsMinor)),
              try expectedUnpaid == HistoryValidation.rangeSum(shops.map(\.expectedUnpaid)),
              try projectedCommitment == HistoryValidation.rangeSum(shops.map(\.projectedCommitment)) else { throw ClientError.invalidResponse }
    }
}
public struct HistoryPriceObservationPage: Codable, Equatable, Sendable {
    public let observations: [HistoryPriceObservation]; public let nextCursor: String?
    public init(observations: [HistoryPriceObservation], nextCursor: String?) { self.observations = observations; self.nextCursor = nextCursor }
}
public struct HistoryBudgetPeriodReference: Codable, Equatable, Identifiable, Sendable {
    public var id: String { periodId }
    public let periodId: String; public let revision: Int; public let updatedAt: String
    public init(periodId: String, revision: Int, updatedAt: String) { self.periodId = periodId; self.revision = revision; self.updatedAt = updatedAt }
}
public struct HistoryBudgetPeriodPage: Codable, Equatable, Sendable {
    public let periods: [HistoryBudgetPeriodReference]; public let nextCursor: String?
    public init(periods: [HistoryBudgetPeriodReference], nextCursor: String?) { self.periods = periods; self.nextCursor = nextCursor }
}
public struct HistorySavedBudgetPeriod: Codable, Equatable, Sendable {
    public let periodId: String; public let revision: Int; public let period: HistoryBudgetPeriod
    public init(periodId: String, revision: Int, period: HistoryBudgetPeriod) { self.periodId = periodId; self.revision = revision; self.period = period }
    func validate(id: String) throws {
        guard HistoryValidation.sameID(periodId, id), HistoryValidation.sameID(period.id, id), revision > 0 else { throw ClientError.invalidResponse }
        do { try period.validate() } catch { throw ClientError.invalidResponse }
    }
}
public struct HistoryRemainingRange: Codable, Equatable, Sendable {
    public let minimumMinor: Int?; public let maximumMinor: Int
    public init(minimumMinor: Int?, maximumMinor: Int) { self.minimumMinor = minimumMinor; self.maximumMinor = maximumMinor }
}
public struct HistoryCompletePeriod: Codable, Equatable, Sendable {
    public let periodId: String; public let revision: Int; public let period: HistoryBudgetPeriod; public let permitted: HistoryPermittedSubtotal
    public let futureReservedMinor: Int; public let remaining: HistoryRemainingRange; public let reconciledEnteredPeriod: Bool
    public init(periodId: String, revision: Int, period: HistoryBudgetPeriod, permitted: HistoryPermittedSubtotal, futureReservedMinor: Int, remaining: HistoryRemainingRange, reconciledEnteredPeriod: Bool) {
        self.periodId = periodId; self.revision = revision; self.period = period; self.permitted = permitted
        self.futureReservedMinor = futureReservedMinor; self.remaining = remaining; self.reconciledEnteredPeriod = reconciledEnteredPeriod
    }
    func validate(id: String) throws {
        try HistorySavedBudgetPeriod(periodId: periodId, revision: revision, period: period).validate(id: id)
        try permitted.validate(allowedShopIDs: period.shopIds)
        guard permitted.shops.count == period.shopIds.count,
              try futureReservedMinor == HistoryValidation.sum(period.reservations.filter { $0.state == .reserved }.map(\.amountMinor)),
              try remaining.maximumMinor == HistoryValidation.sum([period.shopBudgetMinor, -permitted.projectedCommitment.lowerMinor, -futureReservedMinor]) else { throw ClientError.invalidResponse }
        if let upper = permitted.projectedCommitment.upperMinor {
            guard try remaining.minimumMinor == HistoryValidation.sum([period.shopBudgetMinor, -upper, -futureReservedMinor]) else { throw ClientError.invalidResponse }
        } else if remaining.minimumMinor != nil { throw ClientError.invalidResponse }
        guard !reconciledEnteredPeriod || (period.reviewedCompleteAt != nil && futureReservedMinor == 0 && permitted.shops.allSatisfy(\.reconciledEntered)) else { throw ClientError.invalidResponse }
    }
}
/// Partial access has no envelope, title, remaining balance or hidden-source metadata to accidentally display.
public enum HistoryPeriodResponse: Codable, Equatable, Sendable {
    case permittedOnly(HistoryPermittedSubtotal)
    case complete(HistoryCompletePeriod)
    private enum Keys: String, CodingKey { case permitted }
    public init(from decoder: Decoder) throws {
        let all = try decoder.container(keyedBy: HistoryCodingKey.self)
        let names = Set(all.allKeys.map(\.stringValue))
        if names == ["permitted"] {
            self = .permittedOnly(try decoder.container(keyedBy: Keys.self).decode(HistoryPermittedSubtotal.self, forKey: .permitted))
        } else {
            guard names == ["periodId", "revision", "period", "permitted", "futureReservedMinor", "remaining", "reconciledEnteredPeriod"] else { throw ClientError.invalidResponse }
            self = .complete(try HistoryCompletePeriod(from: decoder))
        }
    }
    public func encode(to encoder: Encoder) throws {
        switch self {
        case .permittedOnly(let subtotal): var c = encoder.container(keyedBy: Keys.self); try c.encode(subtotal, forKey: .permitted)
        case .complete(let response): try response.encode(to: encoder)
        }
    }
}

public struct PriceObservationReceipt: Codable, Equatable, Sendable {
    public let observationId: String; public let shopId: String; public let recorded: Bool
    public init(observationId: String, shopId: String, recorded: Bool = true) { self.observationId = observationId; self.shopId = shopId; self.recorded = recorded }
}
public struct BudgetPeriodReceipt: Codable, Equatable, Sendable {
    public let periodId: String; public let revision: Int; public let saved: Bool
    public init(periodId: String, revision: Int, saved: Bool = true) { self.periodId = periodId; self.revision = revision; self.saved = saved }
}
public struct PriceObservationIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: String; public let subject: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public let observation: HistoryPriceObservation; public let bytes: Data
    public init(subject: String, householdID: String, memberID: String, deviceID: String, observation: HistoryPriceObservation) throws {
        id = UUID().uuidString.lowercased(); self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.deviceID = deviceID; self.observation = observation
        bytes = try encoded(Input(clientKey: id, observation: observation)); try validate()
    }
    private struct Input: Codable { let clientKey: String; let observation: HistoryPriceObservation }
    public func validate() throws {
        try HistoryValidation.scope(id: id, subject: subject, household: householdID, member: memberID, device: deviceID); try observation.validate()
        guard bytes == (try encoded(Input(clientKey: id, observation: observation))) else { throw ClientError.configuration }
    }
}
public struct BudgetPeriodIntent: Codable, Equatable, Identifiable, Sendable {
    public let id: String; public let subject: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public let baseRevision: Int; public let period: HistoryBudgetPeriod; public let bytes: Data
    public init(subject: String, householdID: String, memberID: String, deviceID: String, baseRevision: Int, period: HistoryBudgetPeriod) throws {
        id = UUID().uuidString.lowercased(); self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.deviceID = deviceID
        self.baseRevision = baseRevision; self.period = period; bytes = try encoded(Input(clientKey: id, baseRevision: baseRevision, period: period)); try validate()
    }
    private struct Input: Codable { let clientKey: String; let baseRevision: Int; let period: HistoryBudgetPeriod }
    public func validate() throws {
        try HistoryValidation.scope(id: id, subject: subject, household: householdID, member: memberID, device: deviceID); try period.validate()
        guard baseRevision >= 0, baseRevision < Int.max, bytes == (try encoded(Input(clientKey: id, baseRevision: baseRevision, period: period))) else { throw ClientError.configuration }
    }
}

struct HistoryCodingKey: CodingKey {
    let stringValue: String; let intValue: Int? = nil
    init?(stringValue: String) { self.stringValue = stringValue }
    init?(intValue: Int) { return nil }
}
enum HistoryValidation {
    static func cents(_ value: Int) -> Bool { (0...1_000_000_000_000).contains(value) }
    static func safe(_ value: Int) -> Bool { (-9_007_199_254_740_991...9_007_199_254_740_991).contains(value) }
    static func text(_ value: String, _ maximum: Int, empty: Bool = false) -> Bool { value.utf8.count <= maximum && (empty || !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
    static func ids(_ values: [String]) -> Bool { values.allSatisfy { UUID(uuidString: $0) != nil } }
    static func uniqueIDs(_ values: [String]) -> Bool { ids(values) && Set(values.compactMap(UUID.init(uuidString:))).count == values.count }
    static func sameID(_ a: String, _ b: String) -> Bool { UUID(uuidString: a) != nil && UUID(uuidString: a) == UUID(uuidString: b) }
    static func date(_ value: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: value) { return date }
        formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: value)
    }
    static func sum(_ values: [Int]) throws -> Int {
        var result = 0
        for value in values { let added = result.addingReportingOverflow(value); guard safe(value), !added.overflow, safe(added.partialValue) else { throw ClientError.invalidResponse }; result = added.partialValue }
        return result
    }
    static func rangeSum(_ values: [HistoryMoneyRange]) throws -> HistoryMoneyRange {
        for value in values { try value.validate() }
        return try .init(lowerMinor: sum(values.map(\.lowerMinor)), upperMinor: values.contains(where: { $0.upperMinor == nil }) ? nil : sum(values.compactMap(\.upperMinor)))
    }
    static func scope(id: String, subject: String, household: String, member: String, device: String) throws {
        guard ids([id, household, member]), !subject.isEmpty, !device.isEmpty else { throw ClientError.configuration }
    }
}

public struct HistoryOwnedShop: Codable, Equatable, Identifiable, Sendable {
    public var id: String { shopId }
    public let shopId: String; public let createdAt: String; public let phase: String; public let role: String; public let revision: Int; public let authorityEpoch: Int
    public init(shopId: String, createdAt: String, phase: String, role: String = "shopper", revision: Int, authorityEpoch: Int) {
        self.shopId = shopId; self.createdAt = createdAt; self.phase = phase; self.role = role; self.revision = revision; self.authorityEpoch = authorityEpoch
    }
}
public struct HistoryOwnedShopPage: Codable, Equatable, Sendable {
    public let shops: [HistoryOwnedShop]; public let nextCursor: String?
    public init(shops: [HistoryOwnedShop], nextCursor: String?) { self.shops = shops; self.nextCursor = nextCursor }
}
