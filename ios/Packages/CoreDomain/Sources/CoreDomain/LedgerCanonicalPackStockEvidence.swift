import Foundation
import CryptoKit

/// A bounded historical proof extracted from ONE complete canonical allocation.
/// Decoding proves internal consistency, never live authority. A new application
/// must regenerate this proof from the current private store and compare its basis.
public struct LedgerCanonicalPackStockEvidence: Codable, Equatable, Sendable {
    public static let maximumSourceHeads = 1_000
    public static let maximumProofRows = 10_000
    public static let maximumEncodedBytes = 262_144

    public struct SourceHead: Codable, Equatable, Sendable {
        public let journeyID: UUID
        public let revision: Int64
        public init(journeyID: UUID, revision: Int64) { self.journeyID = journeyID; self.revision = revision }
    }
    public struct Basis: Codable, Equatable, Sendable {
        public let originID: UUID
        public let inventoryRevision: Int64
        public let sourceHeads: [SourceHead]
        public init(originID: UUID, inventoryRevision: Int64, sourceHeads: [SourceHead]) {
            self.originID = originID; self.inventoryRevision = inventoryRevision; self.sourceHeads = sourceHeads
        }
    }
    public struct Scope: Codable, Equatable, Sendable {
        public let journeyID: UUID
        public let journeyRevision: Int64
        public let basketRevisionID: UUID
        public let shopRevisionID: UUID
        public let lineID: UUID
        public init(journeyID: UUID, journeyRevision: Int64, basketRevisionID: UUID, shopRevisionID: UUID, lineID: UUID) {
            self.journeyID = journeyID; self.journeyRevision = journeyRevision; self.basketRevisionID = basketRevisionID
            self.shopRevisionID = shopRevisionID; self.lineID = lineID
        }
    }
    public struct ClaimBinding: Codable, Equatable, Sendable {
        public let need: StockNeed
        /// Nil is permitted only for a genuine zero need, which has no canonical claim.
        public let reservationID: UUID?
        public init(need: StockNeed, reservationID: UUID?) { self.need = need; self.reservationID = reservationID }
    }
    public struct LotEligibility: Codable, Equatable, Sendable {
        public enum Status: String, Codable, Sendable { case eligible, unresolved, ineligible }
        public let lotID: UUID
        public let source: InventorySource
        public let observationID: UUID
        public let status: Status
        /// For a receipt, the app hashes its complete validated provenance across
        /// all source heads: original order, fragment, observation/supersession and
        /// alias mappings. A legacy observation UUID alone is not this proof.
        public let receiptEvidenceDigest: Data?
        public init(lotID: UUID, source: InventorySource, observationID: UUID, status: Status, receiptEvidenceDigest: Data?) {
            self.lotID = lotID; self.source = source; self.observationID = observationID
            self.status = status; self.receiptEvidenceDigest = receiptEvidenceDigest
        }
    }
    public struct ClaimProof: Codable, Equatable, Sendable {
        public let binding: ClaimBinding
        public let reservation: InventoryReservation?
        public let backed: Quantity?
        public let issues: [InventoryAvailabilityIssue]
    }
    public struct LotProof: Codable, Equatable, Sendable {
        public let lot: InventoryLot
        public let eligibility: LotEligibility
    }
    public let version: Int
    public let basis: Basis
    public let scope: Scope
    /// Covers ALL physical and claim heads plus receipt eligibility, not just this
    /// shop's rows. Source bookkeeping revisions are separately bound by `basis`.
    public let materialDigest: Data
    public let partition: [ClaimProof]
    public let lots: [LotProof]
    public let allocations: [StockAllocationEdge]

    private init(basis: Basis, scope: Scope, materialDigest: Data, partition: [ClaimProof],
                 lots: [LotProof], allocations: [StockAllocationEdge]) {
        version = 1; self.basis = basis; self.scope = scope; self.materialDigest = materialDigest
        self.partition = partition; self.lots = lots; self.allocations = allocations
    }

    /// Never supplies a free-standing total and never invokes an allocator. The
    /// caller supplies the repository's complete graph/projection and the live
    /// reader's validated receipt eligibility, not a selected-shop stock subset.
    public static func review(scope: Scope, basis: Basis, requirement: LedgerPackRequirement,
                              claimBindings: [ClaimBinding], canonicalLots: [InventoryLot],
                              canonicalReservations: [InventoryReservation], projection: InventoryProjection,
                              eligibility: [LotEligibility]) throws -> Self {
        guard canonicalLots.count <= InventoryProjection.maximumLots,
              canonicalReservations.count <= InventoryProjection.maximumReservations,
              projection.allocations.count <= 200_000,
              claimBindings.count <= maximumProofRows else { throw LedgerPackError.invalidEvidence }
        let lotIDs = Set(canonicalLots.map(\.id)), claimIDs = Set(canonicalReservations.map(\.id))
        guard lotIDs.count == canonicalLots.count, Set(canonicalLots.map(\.source)).count == canonicalLots.count,
              claimIDs.count == canonicalReservations.count,
              Set(projection.lots.map(\.id)) == lotIDs, projection.lots.count == canonicalLots.count,
              Set(eligibility.map(\.lotID)) == lotIDs, eligibility.count == canonicalLots.count else { throw LedgerPackError.invalidEvidence }
        let projectedLots = Dictionary(uniqueKeysWithValues: projection.lots.map { ($0.id, $0) })
        let lotIndex = Dictionary(uniqueKeysWithValues: canonicalLots.map { ($0.id, $0) })
        let claims = Dictionary(uniqueKeysWithValues: canonicalReservations.map { ($0.id, $0) })
        let eligible = Dictionary(uniqueKeysWithValues: eligibility.map { ($0.lotID, $0) })
        let held = canonicalReservations.filter { $0.state != .released }
        guard Set(projection.reservations.map(\.id)) == Set(held.map(\.id)),
              projection.reservations.count == held.count else { throw LedgerPackError.invalidEvidence }
        let coverage = Dictionary(uniqueKeysWithValues: projection.reservations.map { ($0.id, $0) })
        for lot in canonicalLots {
            try lot.validate()
            guard lot.source.originID == basis.originID,
                  let row = projectedLots[lot.id], row.revision == lot.revision, row.count == lot.count,
                  let eligibility = eligible[lot.id] else { throw LedgerPackError.invalidEvidence }
            try validate(eligibility, lot: lot)
        }
        for claim in canonicalReservations {
            try claim.validate()
            guard claim.originID == basis.originID else { throw LedgerPackError.invalidEvidence }
            if claim.state != .released {
                guard coverage[claim.id]?.requested == claim.amount else { throw LedgerPackError.invalidEvidence }
            }
        }
        for edge in projection.allocations {
            guard let claim = claims[edge.needID], claim.state == .active,
                  let lot = lotIndex[edge.lotID], edge.foodID == claim.foodID, edge.foodID == lot.foodID,
                  edge.amount > .zero else { throw LedgerPackError.invalidEvidence }
        }
        let targetIDs = Set(claimBindings.compactMap(\.reservationID))
        guard targetIDs.count == claimBindings.compactMap(\.reservationID).count,
              Set(claimBindings.map { $0.need.id }).count == claimBindings.count else { throw LedgerPackError.invalidEvidence }
        let edges = projection.allocations.filter { targetIDs.contains($0.needID) }.sorted(by: edgeOrder)
        let proofs = try claimBindings.map { binding -> ClaimProof in
            if binding.need.amount.amount == .zero {
                guard binding.reservationID == nil else { throw LedgerPackError.invalidEvidence }
                return ClaimProof(binding: binding, reservation: nil,
                    backed: Quantity(amount: .zero, unit: binding.need.amount.unit, originalLiteral: "0"), issues: [])
            }
            guard let id = binding.reservationID, let claim = claims[id] else { throw LedgerPackError.invalidEvidence }
            let row = coverage[id]
            return ClaimProof(binding: binding, reservation: claim, backed: row?.backed,
                issues: row?.issues ?? [.reservationUnresolved])
        }.sorted { $0.binding.need.id.uuidString < $1.binding.need.id.uuidString }
        let selectedLotIDs = Set(edges.map(\.lotID))
        let selectedLots = canonicalLots.filter { selectedLotIDs.contains($0.id) }.sorted { $0.id.uuidString < $1.id.uuidString }.map {
            LotProof(lot: $0, eligibility: eligible[$0.id]!)
        }
        struct Material: Encodable { let lots: [InventoryLot]; let reservations: [InventoryReservation]; let eligibility: [LotEligibility] }
        let material = Material(lots: canonicalLots.sorted { $0.id.uuidString < $1.id.uuidString },
            reservations: canonicalReservations.sorted { $0.id.uuidString < $1.id.uuidString },
            eligibility: eligibility.sorted { $0.lotID.uuidString < $1.lotID.uuidString })
        let value = Self(basis: Basis(originID: basis.originID, inventoryRevision: basis.inventoryRevision,
            sourceHeads: basis.sourceHeads.sorted { $0.journeyID.uuidString < $1.journeyID.uuidString }),
            scope: scope, materialDigest: Data(SHA256.hash(data: try encode(material))), partition: proofs, lots: selectedLots, allocations: edges)
        _ = try value.confirmedQuantity(for: requirement)
        return value
    }

    /// Nil preserves an unresolved basis. Pack comparison may then buy the gross
    /// requirement with no numeric home credit, but cannot claim no purchase.
    public func confirmedQuantity(for requirement: LedgerPackRequirement) throws -> Quantity? {
        try validate()
        try requirement.quantity.validate(); try requirement.protectedQuantity.validate()
        guard requirement.quantity.amount > .zero, requirement.protectedQuantity.unit == requirement.quantity.unit else {
            throw LedgerPackError.invalidEvidence
        }
        var gross = Rational.zero, protected = Rational.zero, confirmed = Rational.zero
        var resolved = true
        let lotsByID = Dictionary(uniqueKeysWithValues: lots.map { ($0.lot.id, $0) })
        for proof in partition {
            let need = proof.binding.need
            guard let amount = try need.amount.converted(to: requirement.quantity.unit) else { throw LedgerPackError.invalidEvidence }
            gross = try gross.adding(amount)
            if need.priority == .protected { protected = try protected.adding(amount) }
            if !proof.issues.isEmpty || proof.reservation.map({ $0.state != .active }) == true { resolved = false }
            let edges = allocations.filter { $0.needID == proof.binding.reservationID }
            if edges.contains(where: { lotsByID[$0.lotID]?.eligibility.status != .eligible }) { resolved = false }
            if let backed = proof.backed, let amount = try backed.converted(to: requirement.quantity.unit, using: need.amount.confirmedConversion) {
                confirmed = try confirmed.adding(amount)
            } else { resolved = false }
        }
        guard gross == requirement.quantity.amount, protected == requirement.protectedQuantity.amount, confirmed <= gross else {
            throw LedgerPackError.staleSource
        }
        return resolved ? Quantity(amount: confirmed, unit: requirement.quantity.unit, originalLiteral: confirmed.description) : nil
    }

    /// This only compares material backing. It is NOT permission for a new
    /// selection or checkout application; the exact retained application basket
    /// and selection must separately be proved by isCurrentForAppliedBasket.
    public func hasSameMaterial(as current: Self) throws -> Bool {
        try validate(); try current.validate()
        return basis.originID == current.basis.originID && scope.journeyID == current.scope.journeyID &&
            scope.shopRevisionID == current.scope.shopRevisionID && scope.lineID == current.scope.lineID &&
            materialDigest == current.materialDigest && partition == current.partition && lots == current.lots && allocations == current.allocations
    }

    public func validate() throws {
        guard version == 1, basis.inventoryRevision >= 0, scope.journeyRevision >= 0,
              !basis.sourceHeads.isEmpty, basis.sourceHeads.count <= Self.maximumSourceHeads,
              Set(basis.sourceHeads.map(\.journeyID)).count == basis.sourceHeads.count,
              basis.sourceHeads.allSatisfy({ $0.revision > 0 }), basis.sourceHeads.contains(where: { $0.journeyID == scope.journeyID }),
              basis.sourceHeads == basis.sourceHeads.sorted(by: { $0.journeyID.uuidString < $1.journeyID.uuidString }),
              materialDigest.count == 32, !partition.isEmpty, partition.count <= Self.maximumProofRows,
              lots.count <= Self.maximumProofRows, allocations.count <= Self.maximumProofRows,
              Set(partition.map { $0.binding.need.id }).count == partition.count,
              Set(lots.map { $0.lot.id }).count == lots.count,
              Set(allocations.map { $0.needID.uuidString + "/" + $0.lotID.uuidString }).count == allocations.count else {
            throw LedgerPackError.invalidEvidence
        }
        let claims = partition.compactMap { $0.reservation }
        guard Set(claims.map(\.id)).count == claims.count else { throw LedgerPackError.invalidEvidence }
        let lotIndex = Dictionary(uniqueKeysWithValues: lots.map { ($0.lot.id, $0) })
        let claimIndex = Dictionary(uniqueKeysWithValues: claims.map { ($0.id, $0) })
        guard Set(lots.map { $0.lot.id }) == Set(allocations.map(\.lotID)) else { throw LedgerPackError.invalidEvidence }
        for proof in partition {
            let binding = proof.binding, need = binding.need
            try need.amount.validate()
            guard need.foodID == scope.lineID, !need.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  need.name.utf8.count <= 512, Set(proof.issues).count == proof.issues.count else { throw LedgerPackError.invalidEvidence }
            let edges = allocations.filter { $0.needID == binding.reservationID }
            let allocated = try edges.reduce(Rational.zero) { total, edge in
                guard let value = try Quantity(amount: edge.amount, unit: edge.unit, originalLiteral: edge.amount.description)
                    .converted(to: need.amount.unit, using: need.amount.confirmedConversion) else { throw LedgerPackError.invalidEvidence }
                return try total.adding(value)
            }
            if need.amount.amount == .zero {
                guard binding.reservationID == nil, proof.reservation == nil, edges.isEmpty, proof.issues.isEmpty,
                      proof.backed?.amount == .zero, proof.backed?.unit == need.amount.unit else { throw LedgerPackError.invalidEvidence }
            } else {
                guard let claim = proof.reservation, binding.reservationID == claim.id,
                      claim.originID == basis.originID, claim.foodID == need.foodID,
                      claim.state != .active || (claim.amount == need.amount && claim.priority == need.priority),
                      allocated <= need.amount.amount else { throw LedgerPackError.invalidEvidence }
                try claim.validate()
                if let backed = proof.backed {
                    try backed.validate()
                    guard try backed.converted(to: need.amount.unit, using: need.amount.confirmedConversion) == allocated else { throw LedgerPackError.invalidEvidence }
                } else {
                    guard !proof.issues.isEmpty, allocated == .zero else { throw LedgerPackError.invalidEvidence }
                }
                if claim.state != .active { guard !proof.issues.isEmpty else { throw LedgerPackError.invalidEvidence } }
            }
        }
        for edge in allocations {
            guard let lot = lotIndex[edge.lotID]?.lot, let claim = claimIndex[edge.needID],
                  claim.state == .active, edge.amount > .zero, edge.foodID == scope.lineID,
                  edge.foodID == lot.foodID, edge.foodID == claim.foodID,
                  claim.lotID == nil || claim.lotID == lot.id else { throw LedgerPackError.invalidEvidence }
        }
        for proof in lots {
            try proof.lot.validate(); try Self.validate(proof.eligibility, lot: proof.lot)
            guard proof.lot.source.originID == basis.originID, let count = proof.lot.count.quantity else { throw LedgerPackError.invalidEvidence }
            let allocated = try allocations.filter { $0.lotID == proof.lot.id }.reduce(Rational.zero) { total, edge in
                guard let value = try Quantity(amount: edge.amount, unit: edge.unit, originalLiteral: edge.amount.description)
                    .converted(to: count.unit, using: count.confirmedConversion) else { throw LedgerPackError.invalidEvidence }
                return try total.adding(value)
            }
            guard allocated <= count.amount else { throw LedgerPackError.invalidEvidence }
        }
        guard try Self.encode(self).count <= Self.maximumEncodedBytes else { throw LedgerPackError.invalidEvidence }
    }

    private static func validate(_ eligibility: LotEligibility, lot: InventoryLot) throws {
        guard eligibility.lotID == lot.id, eligibility.source == lot.source,
              eligibility.observationID == lot.observationID else { throw LedgerPackError.invalidEvidence }
        switch lot.source {
        case .manual: guard eligibility.receiptEvidenceDigest == nil else { throw LedgerPackError.invalidEvidence }
        case .receipt: guard eligibility.receiptEvidenceDigest?.count == 32 else { throw LedgerPackError.invalidEvidence }
        }
    }
    private static func edgeOrder(_ a: StockAllocationEdge, _ b: StockAllocationEdge) -> Bool {
        (a.needID.uuidString, a.lotID.uuidString) < (b.needID.uuidString, b.lotID.uuidString)
    }
    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
}
