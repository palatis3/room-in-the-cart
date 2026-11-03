import Foundation

/// The manual comparison permission belongs to one adult, one shop, and one shopper epoch.
public struct StoreQuoteContext: Codable, Equatable, Sendable {
    public let subject: String; public let householdID: String; public let memberID: String; public let deviceID: String
    public init(subject: String, householdID: String, memberID: String, deviceID: String) {
        self.subject = subject; self.householdID = householdID; self.memberID = memberID; self.deviceID = deviceID
    }
}
public enum StoreQuoteChoice: String, Codable, CaseIterable, Sendable { case first, second }
public struct EnteredStoreQuote: Codable, Equatable, Sendable {
    public var label: String; public var store: String; public var branch: String; public var mode: String
    public var slot: String; public var observedAt: String; public var source: String; public var currency: String; public var terms: String
    public var itemsMinor: Int?; public var checkoutMinor: Int?; public var allChargesIncluded: Bool
    public var available: Bool?; public var quantitiesMatched: Bool; public var singleStore: Bool
    public var tripAlreadyPlanned: Bool; public var tripMinor: Int?; public var extraMinutes: Int?
    public var capMinor: Int?; public var capScope: String; public var eligibilityConfirmed: Bool
    public init(label: String, store: String, branch: String, mode: String, slot: String, observedAt: String, source: String,
                currency: String = "USD", terms: String = "", itemsMinor: Int?, checkoutMinor: Int?, allChargesIncluded: Bool,
                available: Bool?, quantitiesMatched: Bool, singleStore: Bool, tripAlreadyPlanned: Bool, tripMinor: Int?, extraMinutes: Int?,
                capMinor: Int? = nil, capScope: String = "wholeCheckout", eligibilityConfirmed: Bool) {
        self.label = label; self.store = store; self.branch = branch; self.mode = mode; self.slot = slot; self.observedAt = observedAt
        self.source = source; self.currency = currency; self.terms = terms; self.itemsMinor = itemsMinor; self.checkoutMinor = checkoutMinor
        self.allChargesIncluded = allChargesIncluded; self.available = available; self.quantitiesMatched = quantitiesMatched; self.singleStore = singleStore
        self.tripAlreadyPlanned = tripAlreadyPlanned; self.tripMinor = tripMinor; self.extraMinutes = extraMinutes
        self.capMinor = capMinor; self.capScope = capScope; self.eligibilityConfirmed = eligibilityConfirmed
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(label, forKey: .label); try c.encode(store, forKey: .store); try c.encode(branch, forKey: .branch); try c.encode(mode, forKey: .mode)
        try c.encode(slot, forKey: .slot); try c.encode(observedAt, forKey: .observedAt); try c.encode(source, forKey: .source)
        try c.encode(currency, forKey: .currency); try c.encode(terms, forKey: .terms); try c.encode(itemsMinor, forKey: .itemsMinor)
        try c.encode(checkoutMinor, forKey: .checkoutMinor); try c.encode(allChargesIncluded, forKey: .allChargesIncluded)
        try c.encode(available, forKey: .available); try c.encode(quantitiesMatched, forKey: .quantitiesMatched); try c.encode(singleStore, forKey: .singleStore)
        try c.encode(tripAlreadyPlanned, forKey: .tripAlreadyPlanned); try c.encode(tripMinor, forKey: .tripMinor); try c.encode(extraMinutes, forKey: .extraMinutes)
        try c.encode(capMinor, forKey: .capMinor); try c.encode(capScope, forKey: .capScope); try c.encode(eligibilityConfirmed, forKey: .eligibilityConfirmed)
    }
    public func validate() throws {
        func text(_ s: String, limit: Int = 240) -> Bool { !s.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && s.utf16.count <= limit }
        guard [label,store,branch,source].allSatisfy({ text($0) }), ["pickup","delivery","inStore"].contains(mode), currency == "USD",
              HistoryValidation.date(slot) != nil, HistoryValidation.date(observedAt) != nil, terms.utf16.count <= 500,
              [itemsMinor,checkoutMinor,tripMinor,capMinor].allSatisfy({ $0 == nil || (0...1_000_000_000).contains($0!) }),
              extraMinutes == nil || (0...525_600).contains(extraMinutes!), ["wholeCheckout","itemsOnly"].contains(capScope) else { throw ClientError.configuration }
    }
}
public struct EnteredStoreQuoteOptions: Codable, Equatable, Sendable {
    public let first: EnteredStoreQuote; public let second: EnteredStoreQuote
    public init(first: EnteredStoreQuote, second: EnteredStoreQuote) { self.first = first; self.second = second }
    public subscript(_ choice: StoreQuoteChoice) -> EnteredStoreQuote { choice == .first ? first : second }
    public func validate() throws { try first.validate(); try second.validate() }
}
public struct StoreQuoteComparison: Codable, Equatable, Sendable {
    public struct Cap: Codable, Equatable, Sendable {
        public let amountMinor: Int?; public let scope: String; public let status: String; public let overMinor: Int?; public let headroomMinor: Int?
    }
    public let comparable: Bool
    public let firstCheckout: Int?; public let secondCheckout: Int?; public let firstTrip: Int?; public let secondTrip: Int?
    public let itemDelta: Int?; public let checkoutDelta: Int?; public let cashDelta: Int?; public let minutesDelta: Int?
    public let preferred: StoreQuoteChoice?; public let secondBreakEven: Int?
    public let firstCap: Cap?; public let secondCap: Cap?
}
public struct StoreQuotePage: Codable, Equatable, Sendable {
    public struct Adult: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID; public let label: String; public let revision: Int; public let enabled: Bool
    }
    public struct Commitment: Codable, Equatable, Identifiable, Sendable {
        public let id: UUID; public let label: String; public let packs: Int
    }
    public struct Basis: Codable, Equatable, Sendable {
        public let store: String; public let branch: String; public let mode: String; public let slot: String; public let revision: Int
    }
    public struct Proposal: Codable, Equatable, Identifiable, Sendable {
        public let proposalId: UUID; public let choice: StoreQuoteChoice
        public var id: UUID { proposalId }
    }
    public struct Pair: Codable, Equatable, Identifiable, Sendable {
        public let pairId: UUID; public let baseRevision: Int; public let authorityEpoch: Int; public let grantRevision: Int; public let stale: Bool
        public let savedAt: String; public let own: Bool; public let commitments: [Commitment]; public let options: EnteredStoreQuoteOptions
        public let comparison: StoreQuoteComparison; public let proposals: [Proposal]
        public var id: UUID { pairId }
        public func current(in page: StoreQuotePage) -> Bool {
            !stale && page.phase == "draft" && baseRevision == page.shopRevision && authorityEpoch == page.authorityEpoch && commitments == page.commitments
        }
    }
    public let shopId: UUID; public let shopRevision: Int; public let authorityEpoch: Int; public let grantRevision: Int
    public let shopper: Bool; public let phase: String; public let adults: [Adult]; public let commitments: [Commitment]
    public let currentBasis: Basis?; public let pairs: [Pair]; public let nextCursor: UUID?
    public func validate() throws {
        guard shopRevision > 0, authorityEpoch > 0, grantRevision >= 0, ["draft","frozen","placed","closed"].contains(phase),
              pairs.count <= 30, Set(pairs.map(\.id)).count == pairs.count, adults.count <= 100,
              Set(adults.map(\.id)).count == adults.count, !shopper || grantRevision == 0,
              shopper || adults.isEmpty, commitments.count <= 500 else { throw ClientError.invalidResponse }
        for p in pairs {
            try p.options.validate()
            guard p.baseRevision > 0, p.authorityEpoch > 0, p.grantRevision >= 0, HistoryValidation.date(p.savedAt) != nil,
                  p.proposals.count <= 100, Set(p.proposals.map(\.id)).count == p.proposals.count,
                  shopper || p.own else { throw ClientError.invalidResponse }
        }
        for c in commitments + pairs.flatMap(\.commitments) {
            guard !c.label.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, c.label.utf16.count <= 240, (1...10000).contains(c.packs) else { throw ClientError.invalidResponse }
        }
    }
}
public enum StoreQuoteAction: String, Codable, Sendable { case pairs, proposals, adoptions, grants }
/// The outbound body deliberately includes null unknowns and excludes unrelated action fields.
public struct StoreQuoteWrite: Codable, Equatable, Sendable {
    public let operationId: UUID; public let shopRevision: Int; public let authorityEpoch: Int; public let grantRevision: Int
    public let options: EnteredStoreQuoteOptions?; public let pairId: UUID?; public let choice: StoreQuoteChoice?; public let proposalId: UUID?
    public let adultId: UUID?; public let enabled: Bool?; public let targetRevision: Int?
    public init(operationId: UUID = UUID(), page: StoreQuotePage, options: EnteredStoreQuoteOptions? = nil,
                pairId: UUID? = nil, choice: StoreQuoteChoice? = nil, proposalId: UUID? = nil, adultId: UUID? = nil, enabled: Bool? = nil, targetRevision: Int? = nil) {
        self.operationId = operationId; shopRevision = page.shopRevision; authorityEpoch = page.authorityEpoch; grantRevision = page.grantRevision
        self.options = options; self.pairId = pairId; self.choice = choice; self.proposalId = proposalId
        self.adultId = adultId; self.enabled = enabled; self.targetRevision = targetRevision
    }
    public func body(for action: StoreQuoteAction) throws -> Data {
        guard shopRevision > 0, authorityEpoch > 0, grantRevision >= 0 else { throw ClientError.configuration }
        var body: [String:JSONValue] = ["operationId":.string(operationId.uuidString.lowercased()),"shopRevision":.integer(shopRevision),"authorityEpoch":.integer(authorityEpoch),"grantRevision":.integer(grantRevision)]
        switch action {
        case .pairs:
            guard let options, pairId == nil, choice == nil, proposalId == nil, adultId == nil, enabled == nil, targetRevision == nil else { throw ClientError.configuration }
            try options.validate(); body["options"] = try JSONDecoder().decode(JSONValue.self, from: encoded(options))
        case .proposals, .adoptions:
            guard let pairId, let choice, options == nil, adultId == nil, enabled == nil, targetRevision == nil else { throw ClientError.configuration }
            body["pairId"] = .string(pairId.uuidString.lowercased()); body["choice"] = .string(choice.rawValue)
            if action == .adoptions { body["proposalId"] = proposalId.map { .string($0.uuidString.lowercased()) } ?? .null }
            else { guard proposalId == nil else { throw ClientError.configuration } }
        case .grants:
            guard let adultId, let enabled, let targetRevision, targetRevision >= 0, options == nil, pairId == nil, choice == nil, proposalId == nil else { throw ClientError.configuration }
            body["adultId"] = .string(adultId.uuidString.lowercased()); body["enabled"] = .bool(enabled); body["targetRevision"] = .integer(targetRevision)
        }
        return try encoded(body)
    }
}
public struct StoreQuoteIntent: Codable, Equatable, Identifiable, Sendable {
    public let context: StoreQuoteContext; public let shopID: UUID; public let action: StoreQuoteAction
    public let request: StoreQuoteWrite; public let reviewedCommitments: [StoreQuotePage.Commitment]; public let bytes: Data
    public var id: UUID { request.operationId }
    public init(context: StoreQuoteContext, shopID: UUID, action: StoreQuoteAction, request: StoreQuoteWrite, reviewedCommitments: [StoreQuotePage.Commitment] = []) throws {
        self.context = context; self.shopID = shopID; self.action = action; self.request = request; self.reviewedCommitments = reviewedCommitments; bytes = try request.body(for: action)
        try validate()
    }
    public func validate() throws {
        guard !context.subject.isEmpty, !context.deviceID.isEmpty, UUID(uuidString: context.householdID) != nil, UUID(uuidString: context.memberID) != nil,
              bytes == (try request.body(for: action)), reviewedCommitments.count <= 500,
              Set(reviewedCommitments.map(\.id)).count == reviewedCommitments.count,
              reviewedCommitments.allSatisfy({ !$0.label.isEmpty && $0.label.utf16.count <= 240 && (1...10000).contains($0.packs) }) else { throw ClientError.configuration }
    }
}
public struct StoreQuoteReceipt: Codable, Equatable, Sendable {
    public let operationId: UUID; public let shopRevision: Int
}
