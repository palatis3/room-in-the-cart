import Foundation

public enum InventoryEngine {
    /// Prepares a new single-lot mutation. The caller must look up a persisted
    /// operation receipt first; replay after a later edit must not reapply a count.
    public static func prepare(_ command: InventoryCommand, current: InventoryLot?, at now: Date) throws -> InventoryPreparedChange {
        guard now.timeIntervalSinceReferenceDate.isFinite, command.occurredAt.timeIntervalSinceReferenceDate.isFinite,
              command.occurredAt <= now else { throw InventoryError.invalid("occurredAt") }
        let lot: InventoryLot
        let observation: InventoryObservation?
        if case .create(let seed, let observationID) = command.change {
            guard current == nil, command.expectedRevision == nil else { throw InventoryError.stale }
            guard seed.source.originID == command.originID else { throw InventoryError.wrongOrigin }
            let observedAt = seed.observedAt ?? command.occurredAt
            guard observedAt.timeIntervalSinceReferenceDate.isFinite, observedAt <= command.occurredAt else {
                throw InventoryError.invalid("observationChronology")
            }
            lot = InventoryLot(id: command.lotID, foodID: seed.foodID, name: seed.name, source: seed.source, revision: 1,
                location: seed.location, openedAt: seed.openedAt, unit: seed.unit, count: seed.count, observationID: observationID,
                confirmedAt: observedAt, updatedAt: command.occurredAt, useFirst: seed.useFirst, splitFromLotID: seed.splitFromLotID, packageCode: seed.packageCode, intakeOrdinal: seed.intakeOrdinal,
                namedPlace: seed.namedPlace, spreadsheetRow: seed.spreadsheetRow)
            observation = InventoryObservation(id: observationID, lotID: lot.id, operationID: command.id, revision: 1,
                supersedesID: nil, observedAt: observedAt, count: seed.count)
        } else {
            guard let current, current.id == command.lotID, command.expectedRevision == current.revision else { throw InventoryError.stale }
            try current.validate()
            guard current.source.originID == command.originID else { throw InventoryError.wrongOrigin }
            guard command.occurredAt >= current.updatedAt else { throw InventoryError.invalid("chronology") }
            let next = current.revision.addingReportingOverflow(1)
            guard !next.overflow else { throw DomainError.overflow }
            var count = current.count, observationID = current.observationID, confirmedAt = current.confirmedAt
            var location = current.location, openedAt = current.openedAt, unit = current.unit
            var foodID = current.foodID, name = current.name, useFirst = current.useFirst
            var physicalBasis: Int64?
            var namedPlace = current.namedPlace
            var spreadsheetRow = current.spreadsheetRow
            var countWording = current.countWording
            var discardUndo: InventoryDiscardUndo?
            var discardedTimes = current.discardedTimes
            var recordsObservation = false
            switch command.change {
            case .create: throw InventoryError.stale
            case .reservation: throw InventoryError.invalid("reservationNeedsClaims")
            case .count(let value, let id):
                countWording = nil
                count = value; observationID = id; confirmedAt = command.occurredAt
                unit = value.quantity?.unit ?? current.unit
                recordsObservation = true
            case .usedUp(let id):
                countWording = nil
                count = .exact(Quantity(amount: .zero, unit: unit, originalLiteral: "0"))
                observationID = id; confirmedAt = command.occurredAt
                recordsObservation = true
            case .move(let value):
                if value != location { namedPlace = nil }
                location = value
            case .opened(let value): openedAt = value
            case .revise(let revision):
                if revision.placeEdit != nil || revision.spreadsheetRow != nil {
                    guard revision.observation == nil, revision.portion == nil, revision.usage == nil,
                          revision.name == nil, revision.location == nil, revision.foodID == nil, revision.useFirst == nil
                    else { throw InventoryError.invalid("organizationOnly") }
                    physicalBasis = current.physicalBasis ?? current.revision
                    discardUndo = current.discardUndo
                }
                if let edit = revision.placeEdit {
                    switch edit {
                    case .assign(let value): namedPlace = value
                    case .clear: namedPlace = nil
                    }
                } else if let newLocation = revision.location, newLocation != location {
                    namedPlace = nil
                }
                if let row = revision.spreadsheetRow {
                    guard let previous = spreadsheetRow, previous.sourceName == row.sourceName,
                          previous.rowKey == row.rowKey else {
                        throw InventoryError.invalid("spreadsheetIdentity")
                    }
                    spreadsheetRow = row
                }
                if let action = revision.portion {
                    guard let reading = revision.observation, reading.observedAt == current.confirmedAt, reading.count == (try action.remainder(of: current)),
                          revision.usage == nil, revision.name == nil, revision.foodID == nil,
                          revision.location == nil, revision.useFirst == nil else { throw InventoryError.invalid("portion") }
                    switch action {
                    case .split: break
                    case .discard:
                        guard (discardedTimes ?? 0) < Int.max else { throw DomainError.overflow }
                        discardedTimes = (discardedTimes ?? 0) + 1
                        discardUndo = .init(eventID: command.eventID, previousCount: current.count,
                                            previousWording: current.countWording, previousConfirmedAt: current.confirmedAt)
                    case .undoDiscard:
                        guard let total = discardedTimes, total > 0,
                              reading.countWording == current.discardUndo?.previousWording else { throw InventoryError.stale }
                        discardedTimes = total == 1 ? nil : total - 1
                    }
                }
                try revision.validateUsage(replacing: current.count)
                guard revision.observation != nil || revision.foodID != nil || revision.name != nil
                        || revision.useFirst != nil || revision.location != nil || revision.placeEdit != nil || revision.spreadsheetRow != nil else {
                    throw InventoryError.invalid("emptyRevision")
                }
                if let observation = revision.observation {
                    guard observation.observedAt.timeIntervalSinceReferenceDate.isFinite,
                          observation.observedAt >= current.confirmedAt,
                          observation.observedAt <= command.occurredAt else {
                        throw InventoryError.invalid("observationChronology")
                    }
                    countWording = observation.countWording
                    count = observation.count; observationID = observation.observationID
                    confirmedAt = observation.observedAt
                    unit = count.quantity?.unit ?? current.unit
                    recordsObservation = true
                }
                foodID = revision.foodID ?? foodID
                name = revision.name ?? name
                useFirst = revision.useFirst ?? useFirst
                location = revision.location ?? location
            }
            if recordsObservation {
                guard observationID != current.observationID else { throw InventoryError.duplicateIdentity }
                observation = InventoryObservation(id: observationID, lotID: current.id, operationID: command.id,
                    revision: next.partialValue, supersedesID: current.observationID, observedAt: confirmedAt, count: count, countWording: countWording)
            } else {
                observation = nil
            }
            lot = InventoryLot(id: current.id, foodID: foodID, name: name, source: current.source,
                revision: next.partialValue, location: location, openedAt: openedAt, unit: unit, count: count,
                observationID: observationID, confirmedAt: confirmedAt, updatedAt: command.occurredAt, useFirst: useFirst, countWording: countWording,
                splitFromLotID: current.splitFromLotID, discardUndo: discardUndo, discardedTimes: discardedTimes,
                packageCode: foodID == current.foodID ? current.packageCode : nil, intakeOrdinal: current.intakeOrdinal,
                namedPlace: namedPlace, spreadsheetRow: spreadsheetRow, physicalBasis: physicalBasis)
        }
        try lot.validate(); try observation?.validate()
        let event = InventoryEvent(id: command.eventID, operationID: command.id, originID: command.originID,
            lotID: lot.id, revision: lot.revision, occurredAt: command.occurredAt, change: command.change)
        let receipt = InventoryOperationReceipt(id: command.id, originID: command.originID, lotID: lot.id,
            previousRevision: command.expectedRevision, revision: lot.revision, eventID: event.id, observationID: observation?.id)
        return InventoryPreparedChange(command: command, lot: lot, observation: observation, event: event, receipt: receipt)
    }
}
