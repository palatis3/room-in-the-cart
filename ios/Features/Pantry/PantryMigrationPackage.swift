import Foundation
import CryptoKit
import CoreDomain
import LocalStore

/// A pure packaging boundary. Only LocalStore's staged migration API may activate these records.
@MainActor enum PantryMigrationPackage {
    enum Failure: Error, Equatable { case invalidPlan, invalidRecord, capacity }

    struct Context: Codable, Equatable {
        let mapperVersion: Int
        let sourceToken: InventorySourceToken
        let ledgerOriginID: UUID?
        let ledgerRevision: Int64?
    }
    struct SourceHeadReference: Codable, Equatable {
        let id: UUID
        let revision: Int64
        let savedAt: Date
        let payloadSHA256: Data
    }
    /// This namespace is archival provenance, never a resumable projection instruction.
    enum Provenance: Codable, Equatable {
        case context(Context)
        case sourceHead(SourceHeadReference)
        case originalLot(InventoryLot, baselineID: UUID)
        case originalObservation(InventoryObservation, baselineID: UUID)
        case sourceReference(lotID: UUID, PantryLegacyMigration.LegacyReference)
        case observationLink(PantryLegacyMigration.ObservationLink, baselineID: UUID)
        case claimLink(reservationID: UUID, legacyNeedID: UUID, journeyID: UUID)
        case pending(PantryLegacyMigration.PendingLineage)
        case issue(PantryLegacyMigration.Issue)
    }
    struct Envelope: Codable, Equatable {
        let namespace: String
        let version: Int
        let id: UUID
        let migrationID: UUID
        let originID: UUID
        let body: Provenance
    }
    struct Package: Equatable {
        let plan: InventoryMigrationPlan
        let chunks: [InventoryMigrationChunk]
    }
    private static let namespace = "pantry-legacy-provenance/v1"

    /// The coordinator must retain the token used to enumerate these exact source heads.
    /// Never fetch a newer token for an older mapped plan: tombstones are not present in
    /// Plan, so this converter cannot recompute LocalStore's complete source-token digest.
    static func build(_ mapped: PantryLegacyMigration.Plan, migrationID: UUID,
                      sourceToken: InventorySourceToken, inventoryRevision: Int64, at now: Date,
                      readLimits: PantryRepository.ReadLimits = .standard) throws -> Package {
        guard (1...PantryRepository.ReadLimits.standard.payloadBytes).contains(readLimits.payloadBytes),
              (1...PantryRepository.ReadLimits.standard.observations).contains(readLimits.observations),
              inventoryRevision >= 0, inventoryRevision < Int64.max,
              sourceToken.workspaceID == mapped.originID, sourceToken.generation >= 0,
              sourceToken.digest.count == 32 else { throw Failure.invalidPlan }
        try validate(mapped, at: now)
        var records: [InventoryRecord] = []
        func archive(_ body: Provenance) throws {
            let id = try provenanceID(body, migrationID: migrationID, originID: mapped.originID)
            let value = Envelope(namespace: namespace, version: 1, id: id, migrationID: migrationID,
                originID: mapped.originID, body: body)
            records.append(.init(key: .init(.intent, id), revision: 1, payload: try bounded(value)))
        }
        let context = Context(mapperVersion: 1, sourceToken: sourceToken,
            ledgerOriginID: mapped.ledgerOriginID, ledgerRevision: mapped.ledgerRevision)
        try archive(.context(context))
        for head in mapped.sourceHeads {
            try archive(.sourceHead(.init(id: head.id, revision: head.revision, savedAt: head.savedAt,
                payloadSHA256: Data(SHA256.hash(data: head.payload)))))
        }
        var baselineIDs: [UUID: UUID] = [:]
        for original in mapped.lots {
            let baselineID = try identity("baseline", [migrationID, mapped.originID, original.id])
            baselineIDs[original.id] = baselineID
            let lot = InventoryLot(id: original.id, foodID: original.foodID, name: original.name, source: original.source,
                revision: 1, location: original.location, openedAt: original.openedAt, unit: original.unit,
                count: original.count, observationID: baselineID, confirmedAt: original.confirmedAt,
                updatedAt: original.updatedAt, useFirst: original.useFirst)
            let observation = InventoryObservation(id: baselineID, lotID: lot.id, operationID: migrationID,
                revision: 1, supersedesID: nil, observedAt: lot.confirmedAt, count: lot.count)
            let source = PantryPersistenceCodec.SourceLink(lotID: lot.id, source: lot.source)
            records.append(.init(key: .init(.lot, lot.id), revision: 1, payload: try bounded(lot)))
            records.append(.init(key: .init(.observation, baselineID), revision: 1,
                payload: try bounded(observation), lotID: lot.id))
            records.append(.init(key: .init(.sourceLink, lot.id), revision: 1, payload: try bounded(source),
                lotID: lot.id, source: try PantryPersistenceCodec.sourceIdentity(lot.source)))
            try archive(.originalLot(original, baselineID: baselineID))
        }
        for observation in mapped.observations {
            guard let baseline = baselineIDs[observation.lotID] else { throw Failure.invalidPlan }
            try archive(.originalObservation(observation, baselineID: baseline))
        }
        for claim in mapped.reservations {
            let normalized = InventoryReservation(id: claim.id, originID: claim.originID, revision: 1,
                foodID: claim.foodID, lotID: claim.lotID, name: claim.name, amount: claim.amount,
                priority: claim.priority, state: claim.state)
            records.append(.init(key: .init(.reservation, claim.id), revision: 1,
                payload: try bounded(normalized), lotID: claim.lotID))
        }
        for link in mapped.sourceLinks {
            for reference in link.references { try archive(.sourceReference(lotID: link.lotID, reference)) }
        }
        for link in mapped.observationLinks {
            guard let baseline = baselineIDs[link.lotID] else { throw Failure.invalidPlan }
            try archive(.observationLink(link, baselineID: baseline))
        }
        for link in mapped.claimLinks {
            for journey in link.journeyIDs {
                try archive(.claimLink(reservationID: link.reservationID, legacyNeedID: link.legacyNeedID, journeyID: journey))
            }
        }
        for pending in mapped.pendingLineage { try archive(.pending(pending)) }
        for issue in mapped.issues { try archive(.issue(issue)) }
        let live = records.filter { $0.key.kind != .intent }
        guard live.reduce(0, { $0 + $1.payload.count }) <= readLimits.payloadBytes,
              live.filter({ $0.key.kind == .observation }).count <= readLimits.observations else { throw Failure.capacity }
        guard Set(records.map(\.key)).count == records.count else { throw Failure.invalidPlan }
        records.sort { ($0.key.kind.rawValue, $0.key.id.uuidString) < ($1.key.kind.rawValue, $1.key.id.uuidString) }
        var chunks: [InventoryMigrationChunk] = [], current: [InventoryRecord] = []
        for record in records {
            let candidate = InventoryMigrationChunk(index: chunks.count, records: current + [record])
            let candidateBytes = try canonical(candidate).count
            if candidate.records.count > InventoryPersistenceLimits.batchItems || candidateBytes > InventoryPersistenceLimits.batchBytes {
                guard !current.isEmpty else { throw Failure.capacity }
                chunks.append(.init(index: chunks.count, records: current)); current = []
            }
            current.append(record)
        }
        if !current.isEmpty { chunks.append(.init(index: chunks.count, records: current)) }
        var digest = InventoryMigrationManifest.initialDigest
        for chunk in chunks { digest = try InventoryMigrationManifest.appending(chunk, to: digest) }
        let plan = InventoryMigrationPlan(migrationID: migrationID, workspaceID: mapped.originID,
            expectedRevision: inventoryRevision, sourceToken: sourceToken, reviewContext: try bounded(context),
            expectedChunkCount: chunks.count, expectedRecordCount: records.count, manifestDigest: digest)
        return Package(plan: plan, chunks: chunks)
    }

    /// Reject a different origin/migration, substituted body/key, or SQL metadata before exposing provenance.
    static func provenance(_ record: InventoryRecord, migrationID: UUID, originID: UUID) throws -> Envelope {
        guard record.key.kind == .intent, record.revision == 1, record.payloadVersion == 1,
              record.lotID == nil, record.source == nil, !record.payload.isEmpty,
              record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidRecord }
        let envelope = try JSONDecoder().decode(Envelope.self, from: record.payload)
        guard envelope.namespace == namespace, envelope.version == 1, envelope.id == record.key.id,
              envelope.migrationID == migrationID, envelope.originID == originID,
              envelope.id == (try provenanceID(envelope.body, migrationID: migrationID, originID: originID)) else {
            throw Failure.invalidRecord
        }
        switch envelope.body {
        case .context(let value):
            guard value.mapperVersion == 1, value.sourceToken.workspaceID == originID,
                  value.sourceToken.generation >= 0, value.sourceToken.digest.count == 32,
                  (value.ledgerOriginID == nil) == (value.ledgerRevision == nil),
                  value.ledgerRevision.map({ $0 >= 0 }) ?? true else { throw Failure.invalidRecord }
        case .sourceHead(let value):
            guard value.revision > 0, value.savedAt.timeIntervalSinceReferenceDate.isFinite,
                  value.payloadSHA256.count == 32 else { throw Failure.invalidRecord }
        case .originalLot(let value, let baseline):
            try value.validate()
            guard value.source.originID == originID,
                  baseline == (try identity("baseline", [migrationID, originID, value.id])) else { throw Failure.invalidRecord }
        case .originalObservation(let value, let baseline):
            try value.validate()
            guard baseline == (try identity("baseline", [migrationID, originID, value.lotID])) else { throw Failure.invalidRecord }
        case .observationLink(let value, let baseline):
            guard baseline == (try identity("baseline", [migrationID, originID, value.lotID])) else { throw Failure.invalidRecord }
        case .sourceReference(_, let value):
            guard (value.legacyLotID == nil) != (value.receiptKey == nil),
                  Set(value.observationIDs).count == value.observationIDs.count else { throw Failure.invalidRecord }
        case .pending(let value): try AwayCarryoverEngine.validate(value.record.intent)
        case .claimLink, .issue: break // Their cross-record membership is checked before packaging.
        }
        return envelope
    }

    private static func validate(_ plan: PantryLegacyMigration.Plan, at now: Date) throws {
        guard now.timeIntervalSinceReferenceDate.isFinite,
              plan.sourceHeads.count <= PantryLegacyMigration.maximumHeads,
              plan.sourceHeads.reduce(0, { $0 + $1.payload.count }) <= PantryLegacyMigration.maximumSourceBytes,
              plan.observations.count <= PantryLegacyMigration.maximumObservations,
              (plan.ledgerOriginID == nil) == (plan.ledgerRevision == nil),
              plan.ledgerRevision.map({ $0 >= 0 }) ?? true else { throw Failure.invalidPlan }
        func unique<T>(_ values: [T], _ id: (T) -> UUID) throws -> [UUID: T] {
            guard Set(values.map(id)).count == values.count else { throw Failure.invalidPlan }
            return Dictionary(uniqueKeysWithValues: values.map { (id($0), $0) })
        }
        let heads = try unique(plan.sourceHeads, { $0.id })
        var journeys: [UUID: PickupJourney] = [:]
        for head in plan.sourceHeads {
            guard head.revision > 0, head.payload.count <= ComparisonStore.maximumPayloadBytes,
                  head.savedAt.timeIntervalSinceReferenceDate.isFinite, head.savedAt <= now else { throw Failure.invalidPlan }
            let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            try PickupModel.validate(journey)
            guard journey.id == head.id, journey.savedAt == head.savedAt else { throw Failure.invalidPlan }
            journeys[head.id] = journey
        }
        let lots = try unique(plan.lots, { $0.id }), observations = try unique(plan.observations, { $0.id })
        let claims = try unique(plan.reservations, { $0.id })
        let sources = try unique(plan.sourceLinks, { $0.lotID }), claimLinks = try unique(plan.claimLinks, { $0.reservationID })
        guard Set(lots.keys) == Set(sources.keys), Set(claims.keys) == Set(claimLinks.keys) else { throw Failure.invalidPlan }
        for lot in plan.lots {
            try lot.validate()
            guard lot.source.originID == plan.originID, lot.updatedAt <= now,
                  let current = observations[lot.observationID], current.lotID == lot.id,
                  current.revision == lot.revision, current.count == lot.count,
                  current.observedAt == lot.confirmedAt, sources[lot.id]?.source == lot.source else { throw Failure.invalidPlan }
            let chain = plan.observations.filter { $0.lotID == lot.id }.sorted { $0.revision < $1.revision }
            guard chain.last?.id == lot.observationID else { throw Failure.invalidPlan }
            var previous: UUID?
            for (index, value) in chain.enumerated() {
                guard value.revision == Int64(index + 1), value.supersedesID == previous else { throw Failure.invalidPlan }
                previous = value.id
            }
        }
        for observation in plan.observations {
            try observation.validate()
            guard lots[observation.lotID] != nil, observation.observedAt <= now else { throw Failure.invalidPlan }
        }
        for link in plan.sourceLinks {
            guard !link.references.isEmpty else { throw Failure.invalidPlan }
            for reference in link.references {
                guard let journey = journeys[reference.journeyID] else { throw Failure.invalidPlan }
                switch link.source {
                case .manual(_, let oldID):
                    guard reference.legacyLotID == oldID, reference.receiptKey == nil, reference.observationIDs.isEmpty,
                          journey.stockLots.contains(where: { $0.id == oldID }) else { throw Failure.invalidPlan }
                case .receipt(_, let key):
                    guard reference.legacyLotID == nil, reference.receiptKey == key,
                          journey.pickup?.receipts.contains(where: { $0.key == key }) == true,
                          Set(reference.observationIDs).count == reference.observationIDs.count,
                          Set(reference.observationIDs) == Set((journey.pickup?.usableObservations ?? []).filter { $0.receipt == key }.map(\.id)) else { throw Failure.invalidPlan }
                }
            }
        }
        for link in plan.observationLinks {
            guard let observation = observations[link.observationID], observation.lotID == link.lotID,
                  let source = sources[link.lotID], source.references.contains(where: {
                      $0.journeyID == link.journeyID && $0.observationIDs.contains(link.legacyObservationID)
                  }) else { throw Failure.invalidPlan }
        }
        for claim in plan.reservations {
            try claim.validate()
            guard claim.state != .released else { throw Failure.invalidPlan }
        }
        func demandKey(_ journey: UUID, _ need: UUID, _ food: UUID) -> String {
            journey.uuidString + "/" + need.uuidString + "/" + food.uuidString
        }
        var expectedDemands = Set<String>()
        for journey in journeys.values {
            let demands: [StockNeed]
            if let history = journey.mealRecovery {
                try history.validate(); try journey.validateRecoveryRawBasis(history)
                demands = try MealRecoveryEngine.project(history.domain).demands
            } else { demands = journey.rawPhysicalStockNeeds }
            for need in demands where need.amount.amount > .zero {
                expectedDemands.insert(demandKey(journey.id, need.id, need.foodID))
            }
            for pending in journey.awayCarryovers where pending.phase != .cancelled {
                let need = AwayCarryoverEngine.targetNeed(pending.intent)
                expectedDemands.insert(demandKey(journey.id, need.id, need.foodID))
            }
        }
        var actualDemands = Set<String>()
        for link in plan.claimLinks {
            guard !link.journeyIDs.isEmpty, Set(link.journeyIDs).count == link.journeyIDs.count,
                  link.journeyIDs.allSatisfy({ heads[$0] != nil }), let claim = claims[link.reservationID] else { throw Failure.invalidPlan }
            for journey in link.journeyIDs { actualDemands.insert(demandKey(journey, link.legacyNeedID, claim.foodID)) }
        }
        guard actualDemands == expectedDemands else { throw Failure.invalidPlan }
        let expectedReferences = journeys.values.reduce(0) { $0 + $1.stockLots.count + ($1.pickup?.receipts.count ?? 0) }
        guard plan.sourceLinks.reduce(0, { $0 + $1.references.count }) == expectedReferences else { throw Failure.invalidPlan }
        var pendingKeys = Set<String>()
        for pending in plan.pendingLineage {
            guard pendingKeys.insert(pending.journeyID.uuidString + "/" + pending.record.id.uuidString).inserted,
                  journeys[pending.journeyID]?.awayCarryovers.contains(pending.record) == true,
                  pending.lotID.map({ lots[$0] != nil }) ?? true,
                  pending.record.phase == .cancelled || claims[pending.reservationID] != nil else { throw Failure.invalidPlan }
            try AwayCarryoverEngine.validate(pending.record.intent)
        }
        let expectedPending = journeys.values.reduce(0) { $0 + $1.awayCarryovers.count }
        guard plan.pendingLineage.count == expectedPending else { throw Failure.invalidPlan }
        _ = try InventoryProjection.build(originID: plan.originID, lots: plan.lots, reservations: plan.reservations, at: now)
    }

    private static func bounded<T: Encodable>(_ value: T) throws -> Data {
        let bytes = try canonical(value)
        guard !bytes.isEmpty, bytes.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.capacity }
        return bytes
    }
    private static func canonical<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try encoder.encode(value)
    }
    private static func provenanceID(_ body: Provenance, migrationID: UUID, originID: UUID) throws -> UUID {
        try identity("\(migrationID.uuidString)/\(originID.uuidString)", body)
    }
    private static func identity<T: Encodable>(_ scope: String, _ value: T) throws -> UUID {
        let payload = try canonical(value)
        var bytes = Array(SHA256.hash(data: Data((namespace + "/" + scope + "/").utf8) + payload).prefix(16))
        bytes[6] = (bytes[6] & 0x0f) | 0x80; bytes[8] = (bytes[8] & 0x3f) | 0x80
        return UUID(uuid: (bytes[0], bytes[1], bytes[2], bytes[3], bytes[4], bytes[5], bytes[6], bytes[7],
            bytes[8], bytes[9], bytes[10], bytes[11], bytes[12], bytes[13], bytes[14], bytes[15]))
    }
}
