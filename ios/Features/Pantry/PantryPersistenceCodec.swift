import Foundation
import CryptoKit
import CoreDomain
import LocalStore

/// The app owns food semantics; LocalStore owns atomic heads and replay receipts.
/// None of these conversions activate inventory or write a legacy pickup.
enum PantryPersistenceCodec {
    enum Failure: Error { case invalidRecord, unsupportedVersion }

    struct SourceLink: Codable, Equatable {
        let lotID: UUID
        let source: InventorySource
    }

    struct ReviewedRequest: Codable, Equatable {
        let version: Int
        let inventoryRevision: Int64
        let command: InventoryCommand
    }

    static func request(_ command: InventoryCommand, inventoryRevision: Int64) throws -> Data {
        guard inventoryRevision >= 0 else { throw Failure.invalidRecord }
        return try encode(ReviewedRequest(version: 1, inventoryRevision: inventoryRevision, command: command))
    }

    static func writes(_ change: InventoryPreparedChange) throws -> [InventoryWrite] {
        let lot = change.lot, command = change.command, event = change.event
        try lot.validate()
        guard lot.id == command.lotID, lot.source.originID == command.originID,
              event.id == command.eventID, event.operationID == command.id,
              event.originID == command.originID, event.lotID == lot.id,
              event.revision == lot.revision, event.occurredAt == command.occurredAt,
              event.change == command.change else { throw Failure.invalidRecord }
        var result = [InventoryWrite(record: InventoryRecord(key: .init(.lot, lot.id), revision: lot.revision,
            payload: try encode(lot)), expectedRevision: command.expectedRevision ?? 0)]
        if let observation = change.observation {
            try observation.validate()
            guard observation.id == lot.observationID, observation.lotID == lot.id,
                  observation.operationID == command.id, observation.revision == lot.revision,
                  observation.count == lot.count, observation.countWording == lot.countWording, observation.observedAt == lot.confirmedAt else { throw Failure.invalidRecord }
            // Observation revision denotes the lot revision; the immutable SQL row is revision one.
            result.append(InventoryWrite(record: InventoryRecord(key: .init(.observation, observation.id), revision: 1,
                payload: try encode(observation), lotID: lot.id), expectedRevision: 0))
        }
        result.append(InventoryWrite(record: InventoryRecord(key: .init(.event, event.id), revision: 1,
            payload: try encode(event), lotID: lot.id), expectedRevision: 0))
        if case .create = command.change {
            result.append(InventoryWrite(record: InventoryRecord(key: .init(.sourceLink, lot.id), revision: 1,
                payload: try encode(SourceLink(lotID: lot.id, source: lot.source)), lotID: lot.id,
                source: try sourceIdentity(lot.source)), expectedRevision: 0))
        }
        return result
    }

    static func write(_ claim: InventoryReservation, expectedRevision: Int64) throws -> InventoryWrite {
        try claim.validate()
        guard expectedRevision >= 0, expectedRevision < Int64.max, claim.revision == expectedRevision + 1 else {
            throw Failure.invalidRecord
        }
        return InventoryWrite(record: InventoryRecord(key: .init(.reservation, claim.id), revision: claim.revision,
            payload: try encode(claim), lotID: claim.lotID), expectedRevision: expectedRevision)
    }

    static func lot(_ record: InventoryRecord) throws -> InventoryLot {
        let value = try decode(InventoryLot.self, record, kind: .lot)
        try value.validate()
        guard record.key.id == value.id, record.revision == value.revision,
              record.lotID == nil, record.source == nil else { throw Failure.invalidRecord }
        return value
    }

    static func observation(_ record: InventoryRecord) throws -> InventoryObservation {
        let value = try decode(InventoryObservation.self, record, kind: .observation)
        try value.validate()
        guard record.key.id == value.id, record.revision == 1,
              record.lotID == value.lotID, record.source == nil else { throw Failure.invalidRecord }
        return value
    }

    static func reservation(_ record: InventoryRecord) throws -> InventoryReservation {
        let value = try decode(InventoryReservation.self, record, kind: .reservation)
        try value.validate()
        guard record.key.id == value.id, record.revision == value.revision,
              record.lotID == value.lotID, record.source == nil else { throw Failure.invalidRecord }
        return value
    }

    static func sourceLink(_ record: InventoryRecord) throws -> SourceLink {
        let value = try decode(SourceLink.self, record, kind: .sourceLink)
        try value.source.validate()
        guard record.key.id == value.lotID, record.revision == 1,
              record.lotID == value.lotID, record.source == (try sourceIdentity(value.source)) else { throw Failure.invalidRecord }
        return value
    }

    static func sourceIdentity(_ source: InventorySource) throws -> InventorySourceIdentity {
        try source.validate()
        // Store the complete reviewed address in SourceLink; its bounded index key is a digest.
        let digest = SHA256.hash(data: try encode(source)).map { String(format: "%02x", $0) }.joined()
        return InventorySourceIdentity(originID: source.originID, sourceID: "v1:" + digest)
    }

    private static func encode<T: Encodable>(_ value: T) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = try encoder.encode(value)
        guard data.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidRecord }
        return data
    }

    private static func decode<T: Decodable>(_ type: T.Type, _ record: InventoryRecord,
                                              kind: InventoryRecordKind) throws -> T {
        guard record.payloadVersion == 1 else { throw Failure.unsupportedVersion }
        guard record.key.kind == kind, record.revision > 0,
              record.payload.count <= InventoryPersistenceLimits.recordBytes else { throw Failure.invalidRecord }
        return try JSONDecoder().decode(type, from: record.payload)
    }
}
