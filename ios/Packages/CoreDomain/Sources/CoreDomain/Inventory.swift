import Foundation

public enum InventoryError: Error, Equatable, Sendable {
    case invalid(String), stale, wrongOrigin, capacity, duplicateIdentity
}

public enum InventoryLocation: String, Codable, CaseIterable, Sendable { case cupboard, fridge, freezer }

/// A physical source key survives recounts and copies into later shopping plans.
/// The origin identifies the private database lineage, not a current shop.
public enum InventorySource: Codable, Hashable, Sendable {
    case manual(originID: UUID, sourceID: UUID)
    case receipt(originID: UUID, key: ReceiptKey)

    public var originID: UUID {
        switch self { case .manual(let id, _), .receipt(let id, _): return id }
    }
    public func validate() throws {
        if case .receipt(_, let key) = self {
            for text in [key.sourceEventID, key.branchID, key.segmentID] {
                guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= 2_048 else {
                    throw InventoryError.invalid("sourceKey")
                }
            }
        }
    }
}

/// Qualitative answers replace numeric availability; they never mean zero.
public enum InventoryCount: Codable, Equatable, Sendable {
    case exact(Quantity), unknown, someLeft, haveEnough
    public var quantity: Quantity? { if case .exact(let value) = self { return value }; return nil }
    public var suppressesStaplePrompt: Bool { self == .haveEnough }
    public func validate() throws { try quantity?.validate() }

    public func validate(wording: String?) throws {
        try validate()
        guard let wording else { return }
        guard self == .someLeft, !wording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              wording.utf8.count <= 512 else { throw InventoryError.invalid("countWording") }
    }
}

public struct InventoryObservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let lotID: UUID
    public let operationID: UUID
    public let revision: Int64
    public let supersedesID: UUID?
    public let observedAt: Date
    public let count: InventoryCount
    public let countWording: String?
    public init(id: UUID, lotID: UUID, operationID: UUID, revision: Int64, supersedesID: UUID?, observedAt: Date, count: InventoryCount, countWording: String? = nil) {
        self.id = id; self.lotID = lotID; self.operationID = operationID; self.revision = revision
        self.supersedesID = supersedesID; self.observedAt = observedAt; self.count = count; self.countWording = countWording
    }
    public func validate() throws {
        guard revision >= 1, supersedesID != id, observedAt.timeIntervalSinceReferenceDate.isFinite else { throw InventoryError.invalid("observation") }
        try count.validate(wording: countWording)
    }
}

/// Bounded current state. Immutable observations/events are stored separately,
/// not accumulated in this head or copied into every shop.
public struct InventoryLot: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let foodID: UUID
    public let name: String
    public let source: InventorySource
    public let revision: Int64
    public let location: InventoryLocation
    public let openedAt: Date?
    public let unit: UnitOfMeasure
    public let count: InventoryCount
    public let countWording: String?
    public let observationID: UUID
    public let confirmedAt: Date
    public let updatedAt: Date
    public let useFirst: Bool

    public let splitFromLotID: UUID?
    public let discardUndo: InventoryDiscardUndo?
    public let discardedTimes: Int?

    public init(id: UUID, foodID: UUID, name: String, source: InventorySource, revision: Int64,
                location: InventoryLocation, openedAt: Date? = nil, unit: UnitOfMeasure, count: InventoryCount,
                observationID: UUID, confirmedAt: Date, updatedAt: Date, useFirst: Bool = false, countWording: String? = nil,
                splitFromLotID: UUID? = nil, discardUndo: InventoryDiscardUndo? = nil, discardedTimes: Int? = nil) {
        self.splitFromLotID = splitFromLotID; self.discardUndo = discardUndo; self.discardedTimes = discardedTimes
        self.id = id; self.foodID = foodID; self.name = name; self.source = source; self.revision = revision
        self.location = location; self.openedAt = openedAt; self.unit = unit; self.count = count; self.countWording = countWording
        self.observationID = observationID; self.confirmedAt = confirmedAt; self.updatedAt = updatedAt; self.useFirst = useFirst
    }
    public func validate() throws {
        guard splitFromLotID != id, (discardedTimes ?? 0) >= 0, revision >= 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              confirmedAt.timeIntervalSinceReferenceDate.isFinite, updatedAt.timeIntervalSinceReferenceDate.isFinite,
              confirmedAt <= updatedAt, count.quantity.map({ $0.unit == unit }) ?? true else { throw InventoryError.invalid("lot") }
        if let discardUndo {
            try discardUndo.previousCount.validate(wording: discardUndo.previousWording)
            guard (discardedTimes ?? 0) > 0, discardUndo.previousConfirmedAt == confirmedAt else { throw InventoryError.invalid("discardUndo") }
        }
        if let openedAt {
            guard openedAt.timeIntervalSinceReferenceDate.isFinite, openedAt <= updatedAt else { throw InventoryError.invalid("openedAt") }
        }
        try source.validate(); try count.validate(wording: countWording)
    }
}

public struct InventoryLotSeed: Codable, Equatable, Sendable {
    public let foodID: UUID
    public let name: String
    public let source: InventorySource
    public let location: InventoryLocation
    public let unit: UnitOfMeasure
    public let count: InventoryCount
    public let useFirst: Bool
    public let observedAt: Date?
    public let openedAt: Date?
    public let splitFromLotID: UUID?
    public init(foodID: UUID, name: String, source: InventorySource, location: InventoryLocation,
                unit: UnitOfMeasure, count: InventoryCount, useFirst: Bool = false, observedAt: Date? = nil,
                openedAt: Date? = nil, splitFromLotID: UUID? = nil) {
        self.openedAt = openedAt; self.splitFromLotID = splitFromLotID
        self.foodID = foodID; self.name = name; self.source = source; self.location = location
        self.unit = unit; self.count = count; self.useFirst = useFirst
        self.observedAt = observedAt
    }
}

/// An observation's time is distinct from the time a reviewed edit is saved.
public struct InventoryCountRevision: Codable, Equatable, Sendable {
    public let count: InventoryCount
    public let countWording: String?
    public let observationID: UUID
    public let observedAt: Date
    public init(count: InventoryCount, observationID: UUID, observedAt: Date, countWording: String? = nil) {
        self.countWording = countWording
        self.count = count; self.observationID = observationID; self.observedAt = observedAt
    }
}

/// A use is a historical action, distinct from an observation of what remains.
public struct InventoryUsage: Codable, Equatable, Sendable, Identifiable {
    public enum Kind: Codable, Equatable, Sendable {
        case measured(Quantity), all, some
    }
    public let id: UUID
    public let kind: Kind
    public init(id: UUID, kind: Kind) { self.id = id; self.kind = kind }
}

/// One reviewed source edit advances a head once. Omitted fields retain the
/// canonical pantry value; changing a label must never manufacture a recount.
public struct InventoryLotRevision: Codable, Equatable, Sendable {
    public let observation: InventoryCountRevision?
    public let portion: InventoryPortionAction?
    public let usage: [InventoryUsage]?
    public let foodID: UUID?
    public let name: String?
    public let useFirst: Bool?
    public let location: InventoryLocation?
    public init(observation: InventoryCountRevision? = nil, foodID: UUID? = nil,
                name: String? = nil, useFirst: Bool? = nil, location: InventoryLocation? = nil, usage: [InventoryUsage]? = nil,
                portion: InventoryPortionAction? = nil) {
        self.portion = portion
        self.usage = usage
        self.observation = observation; self.foodID = foodID; self.name = name
        self.useFirst = useFirst; self.location = location
    }

    public func validateUsage(replacing prior: InventoryCount? = nil) throws {
        guard let usage else { return }
        guard !usage.isEmpty, usage.count <= 64, Set(usage.map(\.id)).count == usage.count,
              let observation else { throw InventoryError.invalid("usage") }
        if prior?.quantity?.amount == .zero { throw InventoryError.invalid("useOfEmptyLot") }
        var remaining = prior?.quantity?.amount
        for action in usage {
            switch action.kind {
            case .measured(let quantity):
                try quantity.validate()
                guard quantity.amount > .zero, let observed = observation.count.quantity else { throw InventoryError.invalid("measuredUse") }
                if let prior {
                    guard let initial = prior.quantity, let available = remaining, initial.unit == observed.unit,
                          quantity.unit.dimension == initial.unit.dimension, let used = try quantity.converted(to: initial.unit),
                          used <= available else { throw InventoryError.invalid("measuredUse") }
                    remaining = try available.subtracting(used)
                }
            case .all:
                guard usage.count == 1, observation.count.quantity?.amount == .zero else { throw InventoryError.invalid("usedUp") }
            case .some:
                guard usage.count == 1, observation.count == .unknown || observation.count == .someLeft else {
                    throw InventoryError.invalid("unmeasuredUse")
                }
            }
        }
        if let remaining, case .measured = usage[0].kind, remaining != observation.count.quantity?.amount {
            throw InventoryError.invalid("measuredUse")
        }
    }
}

public enum InventoryChange: Codable, Equatable, Sendable {
    case create(InventoryLotSeed, observationID: UUID)
    case count(InventoryCount, observationID: UUID)
    case move(InventoryLocation)
    case opened(Date)
    case usedUp(observationID: UUID)
    case revise(InventoryLotRevision)
    case reservation(InventoryReservationEdit)
}

/// The persistence adapter binds the canonical encoded request (including origin,
/// operation identity and expected base) before checking for a durable replay.
public struct InventoryCommand: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let originID: UUID
    public let lotID: UUID
    public let eventID: UUID
    public let expectedRevision: Int64?
    public let occurredAt: Date
    public let change: InventoryChange
    public init(id: UUID, originID: UUID, lotID: UUID, eventID: UUID, expectedRevision: Int64?, occurredAt: Date, change: InventoryChange) {
        self.id = id; self.originID = originID; self.lotID = lotID; self.eventID = eventID
        self.expectedRevision = expectedRevision; self.occurredAt = occurredAt; self.change = change
    }
}

public struct InventoryEvent: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let operationID: UUID
    public let originID: UUID
    public let lotID: UUID
    public let revision: Int64
    public let occurredAt: Date
    public let change: InventoryChange
}

/// This is a proposed receipt until the adapter atomically commits it with the
/// head, event and observation. It is not an in-memory replay cache.
public struct InventoryOperationReceipt: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let originID: UUID
    public let lotID: UUID
    public let previousRevision: Int64?
    public let revision: Int64
    public let eventID: UUID
    public let observationID: UUID?
}

public struct InventoryPreparedChange: Equatable, Sendable {
    public let command: InventoryCommand
    public let lot: InventoryLot
    public let observation: InventoryObservation?
    public let event: InventoryEvent
    public let receipt: InventoryOperationReceipt
}

public enum InventoryReservationState: String, Codable, Sendable { case active, unresolved, released }

/// id is the stable promise/claim identity, shared by its meal and pantry views.
/// Unresolved migration claims survive counts and never become released implicitly.
public struct InventoryReservation: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let originID: UUID
    public let revision: Int64
    public let foodID: UUID
    public let lotID: UUID?
    public let name: String
    public let amount: Quantity?
    public let priority: AllocationPriority
    public let state: InventoryReservationState
    public let personal: InventoryPersonalReservation?
    public init(id: UUID, originID: UUID, revision: Int64, foodID: UUID, lotID: UUID?, name: String,
                amount: Quantity?, priority: AllocationPriority = .required, state: InventoryReservationState = .active,
                personal: InventoryPersonalReservation? = nil) {
        self.id = id; self.originID = originID; self.revision = revision; self.foodID = foodID; self.lotID = lotID
        self.name = name; self.amount = amount; self.priority = priority; self.state = state; self.personal = personal
    }
    public func validate() throws {
        guard revision >= 1, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, name.utf8.count <= 512,
              state != .active || amount != nil, amount.map({ $0.amount > .zero }) ?? true else { throw InventoryError.invalid("reservation") }
        if let personal {
            guard priority == .protected, state != .active || lotID != nil else { throw InventoryError.invalid("personalReservation") }
            try personal.day?.validate()
        }
        try amount?.validate()
    }
}
