import Foundation
import CoreDomain
import LocalStore

/// A selection names a private physical batch. A spoken name or package label is never its identity.
struct PantryConsumptionSelection: Codable, Equatable {
    enum Use: Codable, Equatable {
        case amount(Quantity), all, usedSome(remainingWording: String?), low(String), unknown, empty

        var usageKind: InventoryUsage.Kind? {
            switch self {
            case .amount(let amount): return .measured(amount)
            case .all: return .all
            case .usedSome: return .some
            case .low, .unknown, .empty: return nil
            }
        }

        var remainingWording: String? {
            switch self {
            case .low(let value): return value
            case .usedSome(let value): return value
            default: return nil
            }
        }
    }
    let lotID: UUID
    let use: Use
}

enum PantryConsumptionFailure: Error, Equatable {
    case invalidAmount, incompatibleUnit, insufficientFree, countNeeded, reserved, emptyBatch, stale, unavailable
}

/// Ordered review and immutable command identities are saved together in the existing food journal.
struct PantryConsumptionIntent: Codable, Equatable {
    let selections: [PantryConsumptionSelection]
    let additionalCommands: [InventoryCommand]

    func validate(first: InventoryCommand) throws {
        let commands = [first] + additionalCommands
        guard !selections.isEmpty, selections.count <= PantryConsumptionReview.maximumLines,
              commands.count <= selections.count,
              Set(commands.map(\.lotID)).count == commands.count,
              Set(commands.map(\.eventID)).count == commands.count,
              Set(commands.map(\.lotID)) == Set(selections.map(\.lotID)) else { throw PantryConsumptionFailure.invalidAmount }
        let grouped = Dictionary(grouping: selections, by: \.lotID)
        var observationIDs = Set<UUID>()
        for command in commands {
            guard command.originID == first.originID, command.id == first.id,
                  command.occurredAt == first.occurredAt, let revision = command.expectedRevision,
                  revision > 0, revision < Int64.max, let rows = grouped[command.lotID],
                  case .revise(let edit) = command.change,
                  edit.foodID == nil, edit.name == nil, edit.location == nil, edit.useFirst == nil,
                  let reading = edit.observation, reading.observedAt == command.occurredAt,
                  observationIDs.insert(reading.observationID).inserted else { throw PantryConsumptionFailure.invalidAmount }
            try reading.count.validate(wording: reading.countWording)
            try edit.validateUsage()
            guard (edit.usage ?? []).map(\.kind) == rows.compactMap({ $0.use.usageKind }) else {
                throw PantryConsumptionFailure.invalidAmount
            }
            for selection in rows {
                switch selection.use {
                case .amount(let used):
                    try used.validate()
                    guard used.amount > .zero, reading.count.quantity != nil else { throw PantryConsumptionFailure.invalidAmount }
                case .low(let wording):
                    guard rows.count == 1, reading.count == .someLeft, reading.countWording == wording else {
                        throw PantryConsumptionFailure.invalidAmount
                    }
                case .unknown:
                    guard rows.count == 1, reading.count == .unknown else { throw PantryConsumptionFailure.invalidAmount }
                case .usedSome(let wording):
                    guard rows.count == 1, reading.count == (wording == nil ? .unknown : .someLeft),
                          reading.countWording == wording else { throw PantryConsumptionFailure.invalidAmount }
                case .all, .empty:
                    guard rows.count == 1, reading.count.quantity?.amount == .zero else { throw PantryConsumptionFailure.invalidAmount }
                }
            }
        }
    }
}

struct PantryConsumptionReview {
    static let maximumLines = 64
    struct Line {
        let lot: InventoryLot
        let before: InventoryCount
        let after: InventoryCount
        let used: Quantity?
    }
    let lines: [Line]
    let entry: PantryPendingStore.Entry

    /// Rebuild the review from the same heads on retry. A changed allocation cannot silently alter a reviewed result.
    static func prepare(_ selections: [PantryConsumptionSelection], before: PantryRepository.Snapshot,
                        at now: Date, replay: PantryPendingStore.Entry? = nil) throws
        -> (review: Self, writes: [InventoryWrite]) {
        guard !selections.isEmpty, selections.count <= maximumLines else { throw PantryConsumptionFailure.invalidAmount }
        let lots = Dictionary(uniqueKeysWithValues: before.lots.map { ($0.id, $0) })
        let availability = Dictionary(uniqueKeysWithValues: before.availability.lots.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: selections, by: \.lotID)
        let existing = replay.map { [$0.command] + ($0.consumption?.additionalCommands ?? []) } ?? []
        let identities = Dictionary(uniqueKeysWithValues: existing.map { ($0.lotID, $0) })
        let operation = replay?.operationID ?? UUID(), date = replay?.command.occurredAt ?? now
        var counts: [UUID: InventoryCount] = [:], lines: [Line] = []
        var commands: [InventoryCommand] = [], writes: [InventoryWrite] = []
        var proposed = lots
        for selection in selections {
            guard let lot = lots[selection.lotID], let stock = availability[lot.id] else { throw PantryConsumptionFailure.stale }
            let current = counts[lot.id] ?? lot.count
            if selection.use.usageKind != nil, current.quantity?.amount == .zero { throw PantryConsumptionFailure.emptyBatch }
            let result: InventoryCount
            let used: Quantity?
            switch selection.use {
            case .amount(let quantity):
                try quantity.validate()
                guard quantity.amount > .zero else { throw PantryConsumptionFailure.invalidAmount }
                guard let remaining = current.quantity else { throw PantryConsumptionFailure.countNeeded }
                guard quantity.unit.dimension == remaining.unit.dimension,
                      let amount = try quantity.converted(to: remaining.unit) else { throw PantryConsumptionFailure.incompatibleUnit }
                guard let held = stock.held, stock.free != nil else { throw PantryConsumptionFailure.reserved }
                guard amount <= remaining.amount, try remaining.amount.subtracting(amount) >= held.amount else {
                    throw PantryConsumptionFailure.insufficientFree
                }
                let balance = try remaining.amount.subtracting(amount)
                result = .exact(Quantity(amount: balance, unit: lot.unit, originalLiteral: balance.description,
                                         confirmedConversion: remaining.confirmedConversion))
                used = Quantity(amount: amount, unit: lot.unit, originalLiteral: amount.description)
            case .all, .usedSome, .low, .unknown, .empty:
                guard grouped[lot.id]?.count == 1 else { throw PantryConsumptionFailure.invalidAmount }
                guard stock.held?.amount == .zero,
                      before.availability.reservations(for: lot, among: before.reservations).isEmpty else {
                    throw PantryConsumptionFailure.reserved
                }
                switch selection.use {
                case .all:
                    result = .exact(Quantity(amount: .zero, unit: lot.unit, originalLiteral: "0"))
                    used = current.quantity
                case .empty:
                    result = .exact(Quantity(amount: .zero, unit: lot.unit, originalLiteral: "0"))
                    used = nil
                case .usedSome(let wording):
                    result = wording == nil ? .unknown : .someLeft
                    try result.validate(wording: wording)
                    used = nil
                case .low(let wording):
                    try InventoryCount.someLeft.validate(wording: wording)
                    result = .someLeft
                    used = nil
                case .unknown:
                    result = .unknown
                    used = nil
                case .amount: throw PantryConsumptionFailure.invalidAmount
                }
            }
            lines.append(.init(lot: lot, before: current, after: result, used: used))
            counts[lot.id] = result
        }
        // Repeated numeric uses advance the physical batch and its observation chain exactly once.
        for line in lines {
            let lot = line.lot
            guard let count = counts.removeValue(forKey: lot.id) else { continue }
            let original = identities[lot.id]
            let observationID: UUID
            if case .revise(let edit) = original?.change, let observation = edit.observation {
                observationID = observation.observationID
            } else { observationID = UUID() }
            let rows = grouped[lot.id] ?? []
            let wording = rows.first?.use.remainingWording
            let oldUsage: [InventoryUsage]
            if case .revise(let edit) = original?.change { oldUsage = edit.usage ?? [] } else { oldUsage = [] }
            let usage = rows.compactMap { $0.use.usageKind }.enumerated().map { index, kind in
                InventoryUsage(id: oldUsage.indices.contains(index) ? oldUsage[index].id : UUID(), kind: kind)
            }
            let reading = InventoryCountRevision(count: count, observationID: observationID, observedAt: date, countWording: wording)
            let command = InventoryCommand(id: operation, originID: before.state.workspaceID, lotID: lot.id,
                eventID: original?.eventID ?? UUID(), expectedRevision: lot.revision, occurredAt: date, change: .revise(.init(observation: reading, usage: usage.isEmpty ? nil : usage)))
            let mutation = try InventoryEngine.prepare(command, current: lot, at: now)
            commands.append(command)
            proposed[lot.id] = mutation.lot
            writes += try PantryPersistenceCodec.writes(mutation)
        }
        let after = try InventoryProjection.build(originID: before.state.workspaceID, lots: before.lots.compactMap { proposed[$0.id] },
                                                  reservations: before.reservations, at: now)
        guard after.reservations == before.availability.reservations,
              after.allocations == before.availability.allocations else { throw PantryConsumptionFailure.reserved }
        let intent = PantryConsumptionIntent(selections: selections, additionalCommands: Array(commands.dropFirst()))
        let entry = PantryPendingStore.Entry(command: commands[0], reviewedInventoryRevision: before.state.revision, consumption: intent)
        try PantryPendingStore.validateArchiveEntry(entry, inventoryWorkspaceID: before.state.workspaceID)
        if let replay, !replay.hasSameOriginal(as: entry) { throw PantryConsumptionFailure.stale }
        return (Self(lines: lines, entry: entry), writes)
    }
}

/// Only explicit consumption actions contribute rows. A recount or remaining observation is not a use.
struct PantryUsageHistoryRow: Identifiable, Equatable {
    let id: UUID
    let occurredAt: Date
    let kind: InventoryUsage.Kind
    let remainingWording: String?

    static func entries(from event: InventoryEvent) throws -> [Self] {
        guard case .revise(let revision) = event.change else { return [] }
        try revision.validateUsage()
        return (revision.usage ?? []).map {
            Self(id: $0.id, occurredAt: event.occurredAt, kind: $0.kind, remainingWording: revision.observation?.countWording)
        }
    }
}
