import Foundation
import CryptoKit
import CoreDomain
import LocalStore
import RecordArchive

/// Typed native payloads for owner-only pantry archive records. The Records layer owns
/// envelope versioning, multipart files, registry grouping, authorization and activation.
enum PantryArchiveCodec {
    enum Failure: Error, Equatable { case invalid, incomplete, mixedPackage, capacity, wrongOrigin }
    struct Descriptor: Codable, Equatable, Sendable {
        let originID: UUID
        let inventoryRevision: Int64
        let capturedAt: Date
    }
    struct ProjectionDisposition: Codable, Equatable {
        let recordID: UUID
        let value: PantryLedgerProjectionPort.ReviewDisposition
    }
    /// An archival statement of a past application, never accepted by a live replay API.
    struct ProjectionApplication: Codable, Equatable {
        let binding: LedgerInventoryProjectionBinding
        let requestDigest: Data
        let baseRevision: Int64
        let revision: Int64
        let payloadDigest: Data
        let savedAt: Date
        init(_ receipt: LedgerInventoryProjectionReceipt) {
            binding = receipt.binding; requestDigest = receipt.requestDigest
            baseRevision = receipt.baseRevision; revision = receipt.revision
            payloadDigest = receipt.payloadDigest; savedAt = receipt.savedAt
        }
    }
    struct ProjectionEvidence: Codable, Equatable {
        let sourceIntentID: UUID
        let binding: PantryLedgerProjectionPort.IntentBinding
        let needsReview: ProjectionDisposition?
        let application: ProjectionApplication?
        init(sourceIntentID: UUID, binding: PantryLedgerProjectionPort.IntentBinding,
             needsReview: ProjectionDisposition?, application: ProjectionApplication? = nil) {
            self.sourceIntentID = sourceIntentID; self.binding = binding
            self.needsReview = needsReview; self.application = application
        }
    }
    /// These facts never become live pending files, SQL operation receipts or ledger grants.
    enum History: Codable, Equatable {
        case migration(PantryMigrationPackage.Envelope)
        case sourceHead(originID: UUID, PantryLegacyMigration.SourceHead)
        case pickupPending(PantryPickupPendingStore.Entry)
        case foodPending(PantryPendingStore.Entry)
        case packPending(PantryPackSelectionPendingStore.Entry)
        case projection(ProjectionEvidence)
        case acquisition(originID: UUID, ReceiptAcquisition)
        case price(originID: UUID, PrivatePriceEvidence)
        case originalLot(InventoryLot)
        case originalObservation(originID: UUID, InventoryObservation)
        case originalEvent(InventoryEvent)
        case originalReservation(InventoryReservation)
        case originalSourceLink(PantryPersistenceCodec.SourceLink)
        case restoredFrom(Descriptor)
    }
    enum Item: Codable, Equatable {
        case lot(InventoryLot), observation(InventoryObservation), event(InventoryEvent)
        case reservation(InventoryReservation), sourceLink(PantryPersistenceCodec.SourceLink)
        case historical(History)
    }
    struct Snapshot: Equatable {
        let descriptor: Descriptor
        let lots: [InventoryLot]
        let observations: [InventoryObservation]
        let events: [InventoryEvent]
        let reservations: [InventoryReservation]
        let sourceLinks: [PantryPersistenceCodec.SourceLink]
        let history: [History]
    }
    struct Manifest: Codable, Equatable {
        let namespace: String
        let version: Int
        let bundleID: UUID
        let descriptor: Descriptor
        let chunkCount: Int
        let itemCount: Int
        let chainDigest: Data
    }
    struct Chunk: Codable, Equatable {
        let namespace: String
        let version: Int
        let bundleID: UUID
        let descriptor: Descriptor
        let index: Int
        let items: [Item]
    }
    struct Package: Equatable {
        let manifest: Manifest
        let chunks: [Data]
    }
    static let namespace = "pantry-owner-archive/v1"
    static let maximumChunkItems = 256
    static let maximumChunkBytes = ArchiveCodec.maximumNativeBytes
    private static let initialDigest = digest(Data("pantry-owner-archive-chain/v1".utf8))

    /// Does not impose a file-sized limit on the complete graph or omit oversized tails.
    /// The caller emits the chunks across as many bounded archive envelopes as necessary.
    static func encode(_ snapshot: Snapshot, bundleID: UUID = UUID()) throws -> Package {
        try validate(snapshot)
        let items: [Item] = snapshot.lots.sorted(by: { key($0.id) < key($1.id) }).map(Item.lot)
            + snapshot.observations.sorted(by: { key($0.id) < key($1.id) }).map(Item.observation)
            + snapshot.events.sorted(by: { key($0.id) < key($1.id) }).map(Item.event)
            + snapshot.reservations.sorted(by: { key($0.id) < key($1.id) }).map(Item.reservation)
            + snapshot.sourceLinks.sorted(by: { key($0.lotID) < key($1.lotID) }).map(Item.sourceLink)
            + snapshot.history.map(Item.historical)
        var chunks: [Data] = [], pending: [Item] = [], encodedBytes = 0
        func flush() throws {
            guard !pending.isEmpty else { return }
            let value = Chunk(namespace: namespace, version: 1, bundleID: bundleID,
                descriptor: snapshot.descriptor, index: chunks.count, items: pending)
            let bytes = try encodeChunk(value)
            chunks.append(bytes); pending = []; encodedBytes = 0
        }
        for item in items {
            let count = try ArchiveCodec.canonical(item).count
            // Reserve a fixed bounded header allowance, then verify exact encoded bytes at flush.
            guard count <= maximumChunkBytes - 2_048 else { throw Failure.capacity }
            if pending.count == maximumChunkItems || encodedBytes + count + 2_048 > maximumChunkBytes { try flush() }
            pending.append(item); encodedBytes += count + 1
        }
        try flush()
        var chain = initialDigest
        for chunk in chunks { chain = digest(chain + digest(chunk)) }
        return Package(manifest: Manifest(namespace: namespace, version: 1, bundleID: bundleID,
            descriptor: snapshot.descriptor, chunkCount: chunks.count, itemCount: items.count, chainDigest: chain), chunks: chunks)
    }

    static func decodeChunk(_ bytes: Data) throws -> Chunk {
        try ArchiveCodec.preflight(bytes, maximum: maximumChunkBytes)
        let chunk = try JSONDecoder().decode(Chunk.self, from: bytes)
        guard chunk.namespace == namespace, chunk.version == 1, chunk.index >= 0,
              !chunk.items.isEmpty, chunk.items.count <= maximumChunkItems,
              try ArchiveCodec.canonical(chunk) == bytes else { throw Failure.invalid }
        try validateDescriptor(chunk.descriptor)
        return chunk
    }

    /// Chunk primitives support protected-file streaming without a file-sized graph limit.
    /// A caller must still validate the complete graph before treating these as restorable state.
    static func encodeChunk(_ chunk: Chunk) throws -> Data {
        let bytes = try ArchiveCodec.canonical(chunk)
        guard bytes.count <= maximumChunkBytes else { throw Failure.capacity }
        _ = try decodeChunk(bytes)
        return bytes
    }
    static func decodeManifest(_ bytes: Data) throws -> Manifest {
        try ArchiveCodec.preflight(bytes, maximum: 8_192)
        let value = try JSONDecoder().decode(Manifest.self, from: bytes)
        guard value.namespace == namespace, value.version == 1, value.chunkCount >= 0,
              value.itemCount >= 0, value.chainDigest.count == 32,
              (value.chunkCount == 0) == (value.itemCount == 0), try ArchiveCodec.canonical(value) == bytes else { throw Failure.invalid }
        try validateDescriptor(value.descriptor)
        return value
    }

    /// A fragment is evidence only. No current snapshot is returned until the entire manifest matches.
    static func decode(_ package: Package) throws -> Snapshot {
        let manifest = package.manifest
        guard manifest.namespace == namespace, manifest.version == 1,
              manifest.chunkCount >= 0, manifest.itemCount >= 0, manifest.chainDigest.count == 32,
              (manifest.chunkCount == 0) == (manifest.itemCount == 0) else { throw Failure.invalid }
        try validateDescriptor(manifest.descriptor)
        guard package.chunks.count == manifest.chunkCount else { throw Failure.incomplete }
        var lots: [InventoryLot] = [], observations: [InventoryObservation] = [], events: [InventoryEvent] = []
        var reservations: [InventoryReservation] = [], links: [PantryPersistenceCodec.SourceLink] = [], history: [History] = []
        var count = 0, chain = initialDigest
        for (index, bytes) in package.chunks.enumerated() {
            let chunk = try decodeChunk(bytes)
            guard chunk.bundleID == manifest.bundleID, chunk.descriptor == manifest.descriptor else { throw Failure.mixedPackage }
            guard chunk.index == index else { throw Failure.incomplete }
            let next = count.addingReportingOverflow(chunk.items.count)
            guard !next.overflow, next.partialValue <= manifest.itemCount else { throw Failure.invalid }
            count = next.partialValue; chain = digest(chain + digest(bytes))
            for item in chunk.items {
                switch item {
                case .lot(let value): lots.append(value)
                case .observation(let value): observations.append(value)
                case .event(let value): events.append(value)
                case .reservation(let value): reservations.append(value)
                case .sourceLink(let value): links.append(value)
                case .historical(let value): history.append(value)
                }
            }
        }
        guard count == manifest.itemCount, chain == manifest.chainDigest else { throw Failure.incomplete }
        let result = Snapshot(descriptor: manifest.descriptor, lots: lots, observations: observations, events: events,
            reservations: reservations, sourceLinks: links, history: history)
        try validate(result)
        return result
    }

    static func validate(_ value: Snapshot) throws {
        try validateDescriptor(value.descriptor)
        guard value.lots.count <= InventoryProjection.maximumLots, value.reservations.count <= InventoryProjection.maximumReservations else { throw Failure.capacity }
        let lots = try unique(value.lots, id: { $0.id }), observations = try unique(value.observations, id: { $0.id })
        _ = try unique(value.reservations, id: { $0.id }); _ = try unique(value.events, id: { $0.id })
        let links = try unique(value.sourceLinks, id: { $0.lotID })
        guard Set(links.keys) == Set(lots.keys) else { throw Failure.invalid }
        let histories = Dictionary(grouping: value.observations, by: \.lotID)
        guard Set(histories.keys) == Set(lots.keys) else { throw Failure.invalid }
        for lot in value.lots {
            try lot.validate()
            guard lot.revision <= value.descriptor.inventoryRevision else { throw Failure.invalid }
            guard lot.source.originID == value.descriptor.originID, lot.updatedAt <= value.descriptor.capturedAt,
                  links[lot.id]?.source == lot.source else { throw Failure.wrongOrigin }
            try links[lot.id]?.source.validate()
            var previous: InventoryObservation?
            for observation in (histories[lot.id] ?? []).sorted(by: { $0.revision < $1.revision }) {
                try observation.validate()
                guard observation.revision <= lot.revision, observation.supersedesID == previous?.id,
                      previous.map({ $0.revision < observation.revision && $0.observedAt <= observation.observedAt }) ?? true,
                      observation.observedAt <= lot.updatedAt else { throw Failure.invalid }
                previous = observation
            }
            guard let latest = previous, latest.id == lot.observationID, latest.count == lot.count, latest.countWording == lot.countWording,
                  latest.observedAt == lot.confirmedAt else { throw Failure.invalid }
        }
        for reservation in value.reservations {
            try reservation.validate()
            guard reservation.revision <= value.descriptor.inventoryRevision else { throw Failure.invalid }
            guard reservation.originID == value.descriptor.originID else { throw Failure.wrongOrigin }
            if let parent = reservation.lotID {
                guard let lot = lots[parent], lot.foodID == reservation.foodID else { throw Failure.invalid }
            }
        }
        var eventRevisions: Set<String> = []
        for event in value.events {
            guard let lot = lots[event.lotID], event.originID == value.descriptor.originID,
                  event.revision >= 1, event.revision <= lot.revision, event.occurredAt.timeIntervalSinceReferenceDate.isFinite,
                  event.occurredAt <= lot.updatedAt,
                  eventRevisions.insert(key(event.lotID) + "/" + String(event.revision)).inserted else { throw Failure.invalid }
            try validateEvent(event, observations: observations)
        }
        try validateEventReplay(value, observations: observations)
        var priceRevisions: [UUID: [UUID: [Int64: PrivatePriceEvidence]]] = [:]
        for case .price(let origin, let price) in value.history {
            guard priceRevisions[origin, default: [:]][price.id, default: [:]].updateValue(price, forKey: price.revision) == nil else { throw Failure.invalid }
            if origin == value.descriptor.originID, let lot = price.linkedLotID {
                guard let physical = lots[lot], physical.foodID == price.foodID else { throw Failure.invalid }
            }
        }
        for origin in priceRevisions.values {
            for revisions in origin.values {
                guard let first = revisions[1], revisions.keys.max() == Int64(revisions.count),
                      revisions.values.allSatisfy({ $0.source == first.source && $0.linkedLotID == first.linkedLotID && $0.foodID == first.foodID }) else { throw Failure.invalid }
            }
        }
        var acquisitions: [UUID: [UUID: ReceiptAcquisition]] = [:]
        for case .acquisition(let origin, let row) in value.history {
            guard acquisitions[origin, default: [:]].updateValue(row, forKey: row.id) == nil else { throw Failure.invalid }
        }
        for (origin, rows) in acquisitions {
            var receiptCurrencies: [UUID: Currency] = [:]
            for row in rows.values {
                if let previous = receiptCurrencies.updateValue(row.currency, forKey: row.receiptID),
                   previous != row.currency { throw Failure.invalid }
                if origin == value.descriptor.originID { try PantryAcquisitionCodec.validateLot(row, lot: lots[row.lotID]) }
                if let id = row.supersedesID {
                    guard let prior = rows[id], try prior.correctingPaidTotal(row.paidLineTotal) == row else { throw Failure.invalid }
                }
            }
        }
        for (origin, prices) in priceRevisions {
            for revisions in prices.values {
                for adjustment in revisions.values {
                    guard case .adjustment(let target, let version, _) = adjustment.source else { continue }
                    let receiptID = ReceiptAcquisition.identity(["observation", target.uuidString, String(version)])
                    let candidate = try prices[target]?[version] ?? acquisitions[origin]?[receiptID].map(PrivatePriceEvidence.init(receipt:))
                    guard let candidate else { throw Failure.invalid }
                    try adjustment.validateAdjustmentTarget(candidate)
                }
            }
        }
        var evidence: Set<Data> = []
        for history in value.history {
            try validateHistory(history, at: value.descriptor.capturedAt)
            guard evidence.insert(digest(try ArchiveCodec.canonical(history))).inserted else { throw Failure.invalid }
        }
        _ = try InventoryLot.splitRoots(in: value.lots)
        _ = try InventoryProjection.build(originID: value.descriptor.originID, lots: value.lots,
            reservations: value.reservations, at: value.descriptor.capturedAt)
    }

    static func validateDescriptor(_ descriptor: Descriptor) throws {
        guard descriptor.inventoryRevision >= 0, descriptor.capturedAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalid }
    }
    static func validateEvent(_ event: InventoryEvent, observations: [UUID: InventoryObservation]) throws {
        try validateEventShape(event)
        func observation(_ id: UUID, count: InventoryCount?, at date: Date) throws {
            guard let value = observations[id], value.lotID == event.lotID, value.operationID == event.operationID,
                  value.revision == event.revision, value.observedAt == date,
                  count.map({ value.count == $0 }) ?? true else { throw Failure.invalid }
        }
        switch event.change {
        case .reservation: throw Failure.invalid // Claim-only writes never create physical lot events.
        case let .create(seed, id):
            try seed.source.validate(); try seed.count.validate()
            guard event.revision == 1, seed.source.originID == event.originID, !seed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  seed.name.utf8.count <= 512, seed.count.quantity.map({ $0.unit == seed.unit }) ?? true else { throw Failure.invalid }
            try observation(id, count: seed.count, at: seed.observedAt ?? event.occurredAt)
        case let .count(count, id): try count.validate(); try observation(id, count: count, at: event.occurredAt)
        case let .usedUp(id):
            try observation(id, count: nil, at: event.occurredAt)
            guard observations[id]?.count.quantity?.amount == .zero else { throw Failure.invalid }
        case .move: break
        case .opened(let date):
            guard date.timeIntervalSinceReferenceDate.isFinite, date <= event.occurredAt else { throw Failure.invalid }
        case .revise(let revision):
            guard revision.observation != nil || revision.foodID != nil || revision.name != nil || revision.useFirst != nil || revision.location != nil else { throw Failure.invalid }
            if let name = revision.name { guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512 else { throw Failure.invalid } }
            if let changed = revision.observation {
                try changed.count.validate(wording: changed.countWording)
                guard changed.observedAt <= event.occurredAt else { throw Failure.invalid }
                try observation(changed.observationID, count: changed.count, at: changed.observedAt)
            }
        }
    }
    private static func validateEventReplay(_ snapshot: Snapshot, observations: [UUID: InventoryObservation]) throws {
        let groups = Dictionary(grouping: snapshot.events, by: \.lotID)
        for lot in snapshot.lots {
            let events = (groups[lot.id] ?? []).sorted { $0.revision < $1.revision }
            var current: InventoryLot?
            if events.first?.revision != 1 {
                if lot.revision == 1 { current = lot }
                else {
                    var baselines: [InventoryLot] = []
                    for history in snapshot.history {
                        switch history {
                        case .originalLot(let original) where original.id == lot.id && original.source == lot.source && original.revision == 1:
                            baselines.append(original)
                        case .migration(let envelope):
                            if case let .originalLot(original, baselineID) = envelope.body,
                               original.id == lot.id, original.source == lot.source {
                                baselines.append(InventoryLot(id: original.id, foodID: original.foodID, name: original.name,
                                    source: original.source, revision: 1, location: original.location, openedAt: original.openedAt,
                                    unit: original.unit, count: original.count, observationID: baselineID,
                                    confirmedAt: original.confirmedAt, updatedAt: original.updatedAt, useFirst: original.useFirst, countWording: original.countWording,
                                    splitFromLotID: original.splitFromLotID, discardedTimes: original.discardedTimes,
                                    namedPlace: original.namedPlace, spreadsheetRow: original.spreadsheetRow))
                            }
                        default: break
                        }
                    }
                    guard let baseline = baselines.first, baselines.allSatisfy({ $0 == baseline }) else { throw Failure.invalid }
                    current = baseline
                }
                guard let current, let first = observations[current.observationID], first.lotID == current.id,
                      first.revision == 1, first.supersedesID == nil, first.count == current.count, first.countWording == current.countWording,
                      first.observedAt == current.confirmedAt else { throw Failure.invalid }
            }
            for event in events {
                let command = InventoryCommand(id: event.operationID, originID: event.originID, lotID: event.lotID,
                    eventID: event.id, expectedRevision: current?.revision, occurredAt: event.occurredAt, change: event.change)
                let prepared = try InventoryEngine.prepare(command, current: current, at: snapshot.descriptor.capturedAt)
                guard prepared.event == event else { throw Failure.invalid }
                if let observed = prepared.observation { guard observations[observed.id] == observed else { throw Failure.invalid } }
                current = prepared.lot
            }
            guard current == lot else { throw Failure.invalid }
        }
    }
    static func validateEventShape(_ event: InventoryEvent) throws {
        guard event.revision >= 1, event.occurredAt.timeIntervalSinceReferenceDate.isFinite else { throw Failure.invalid }
        switch event.change {
        case .reservation: throw Failure.invalid // Claim-only writes never create physical lot events.
        case let .create(seed, _):
            try seed.source.validate(); try seed.count.validate()
            guard event.revision == 1, seed.source.originID == event.originID,
                  !seed.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, seed.name.utf8.count <= 512,
                  seed.count.quantity.map({ $0.unit == seed.unit }) ?? true,
                  seed.observedAt.map({ $0.timeIntervalSinceReferenceDate.isFinite && $0 <= event.occurredAt }) ?? true else { throw Failure.invalid }
        case .count(let count, _): try count.validate(); guard event.revision > 1 else { throw Failure.invalid }
        case .usedUp, .move: guard event.revision > 1 else { throw Failure.invalid }
        case .opened(let date):
            guard event.revision > 1, date.timeIntervalSinceReferenceDate.isFinite, date <= event.occurredAt else { throw Failure.invalid }
        case .revise(let change):
            try change.validateUsage()
            guard event.revision > 1, change.observation != nil || change.foodID != nil || change.name != nil || change.useFirst != nil || change.location != nil else { throw Failure.invalid }
            if let name = change.name { guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512 else { throw Failure.invalid } }
            if let observed = change.observation {
                try observed.count.validate(wording: observed.countWording)
                guard observed.observedAt.timeIntervalSinceReferenceDate.isFinite, observed.observedAt <= event.occurredAt else { throw Failure.invalid }
            }
        }
    }
    static func validateHistory(_ history: History, at date: Date) throws {
        switch history {
        case .price(_, let evidence):
            _ = try PantryPriceCodec.row(evidence)
            guard evidence.date <= date else { throw Failure.invalid }
        case .acquisition(_, let fact):
            try fact.validate()
            guard fact.purchaseDate <= date else { throw Failure.invalid }
        case .migration(let value):
            let row = InventoryRecord(key: .init(.intent, value.id), revision: 1, payload: try ArchiveCodec.canonical(value))
            _ = try PantryMigrationPackage.provenance(row, migrationID: value.migrationID, originID: value.originID)
        case let .sourceHead(_, head):
            guard head.revision > 0, head.savedAt.timeIntervalSinceReferenceDate.isFinite, head.savedAt <= date,
                  head.payload.count <= ComparisonStore.maximumPayloadBytes else { throw Failure.invalid }
            try ArchiveCodec.preflight(head.payload, maximum: ComparisonStore.maximumPayloadBytes)
            let journey = try JSONDecoder().decode(PickupJourney.self, from: head.payload)
            guard journey.id == head.id, journey.savedAt == head.savedAt else { throw Failure.invalid }
            try PickupModel.validate(journey)
        case .pickupPending(let entry):
            guard let ledger = entry.submission.request.ledgerOriginID, entry.submission.preparedAt <= date else { throw Failure.invalid }
            for head in entry.submission.changedHeads { try ArchiveCodec.preflight(head.payload, maximum: ComparisonStore.maximumPayloadBytes) }
            try PantryPickupPendingStore.validateArchiveEntry(entry, inventoryWorkspaceID: entry.submission.request.originID, ledgerWorkspaceID: ledger)
        case .foodPending(let entry):
            guard entry.command.occurredAt <= date else { throw Failure.invalid }
            try PantryPendingStore.validateArchiveEntry(entry, inventoryWorkspaceID: entry.command.originID)
        case .packPending(let entry):
            guard entry.request.selection.reviewedAt <= date else { throw Failure.invalid }
            try PantryPackSelectionPendingStore.validateArchiveEntry(entry,
                inventoryWorkspaceID: entry.request.inventoryWorkspaceID, ledgerWorkspaceID: entry.request.ledgerWorkspaceID)
        case .projection(let value):
            let row = InventoryRecord(key: .init(.intent, value.sourceIntentID), revision: 1, payload: try ArchiveCodec.canonical(value.binding))
            _ = try PantryLedgerProjectionPort.archiveBinding(row)
            guard value.binding.savedAt <= date else { throw Failure.invalid }
            if let applied = value.application {
                let next = applied.baseRevision.addingReportingOverflow(1)
                guard applied.binding == value.binding.binding, applied.requestDigest == value.binding.requestDigest,
                      applied.payloadDigest == value.binding.payloadDigest, applied.baseRevision == value.binding.expectedRevision,
                      !next.overflow, applied.revision == next.partialValue, applied.savedAt == value.binding.savedAt else { throw Failure.invalid }
            }
            if let disposition = value.needsReview {
                _ = try PantryLedgerProjectionPort.archiveDisposition(.init(key: .init(.intent, disposition.recordID), revision: 1,
                    payload: try ArchiveCodec.canonical(disposition.value)), bindingRecord: row)
            }
        case .originalLot(let value): try value.validate(); guard value.updatedAt <= date else { throw Failure.invalid }
        case .originalObservation(_, let value): try value.validate(); guard value.observedAt <= date else { throw Failure.invalid }
        case .originalEvent(let value):
            try validateEventShape(value)
            guard value.occurredAt <= date else { throw Failure.invalid }
        case .originalReservation(let value): try value.validate()
        case .originalSourceLink(let value): try value.source.validate()
        case .restoredFrom(let value): try validateDescriptor(value); guard value.capturedAt <= date else { throw Failure.invalid }
        }
    }
    private static func unique<T>(_ values: [T], id: (T) -> UUID) throws -> [UUID: T] {
        var result: [UUID: T] = [:]
        for value in values { guard result.updateValue(value, forKey: id(value)) == nil else { throw Failure.invalid } }
        return result
    }
    private static func key(_ id: UUID) -> String { id.uuidString }
    private static func digest(_ bytes: Data) -> Data { Data(SHA256.hash(data: bytes)) }
}
