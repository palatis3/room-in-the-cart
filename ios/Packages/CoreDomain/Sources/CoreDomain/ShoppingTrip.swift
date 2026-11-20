import Foundation

/// A visit is distinct from the retailer. Returning to the same store on another
/// visit never asserts that a grocery is still unavailable.
public struct ShoppingStop: Codable, Equatable, Sendable {
    public let id: UUID
    public let name: String
}

public enum ShoppingStopOutcome: String, Codable, Sendable {
    case unavailable, deferred
}

public struct ShoppingStopObservation: Codable, Equatable, Sendable {
    public let stopID: UUID
    public let outcome: ShoppingStopOutcome
}

public struct PhysicalGroceryPick: Codable, Equatable, Sendable {
    public let amount: Quantity
    public let at: Date
    /// Pack composition at the time of the pick, before a list edit can change
    /// the labels that originally explained the purchase. Older picks omit it.
    public internal(set) var packages: [BasketPackage]? = nil

    public func checkoutPackages(requested: Quantity?, sourcePackages: [BasketPackage]) throws -> [BasketPackage] {
        if let packages { return packages }
        guard let requested, !sourcePackages.isEmpty,
              let picked = try amount.converted(to: requested.unit),
              try Self.total(sourcePackages, in: requested.unit) == requested.amount else { return [] }
        if picked == requested.amount { return sourcePackages }
        guard picked < requested.amount, let first = sourcePackages.first,
              sourcePackages.allSatisfy({ $0.unit == first.unit && $0.amountPerPack == first.amountPerPack }),
              let converted = try amount.converted(to: first.unit) else { return [] }
        let count = try converted.divided(by: first.amountPerPack)
        guard count.denominator == 1 else { return [] }
        return [BasketPackage(count: count.numerator, amountPerPack: first.amountPerPack, unit: first.unit)]
    }

    fileprivate static func total(_ packages: [BasketPackage], in unit: UnitOfMeasure) throws -> Rational? {
        var total = Rational.zero
        for pack in packages {
            let size = Quantity(amount: pack.amountPerPack, unit: pack.unit, originalLiteral: "")
            guard pack.count > 0, pack.amountPerPack > .zero, let value = try size.converted(to: unit) else { return nil }
            total = try total.adding(value.multiplied(by: Rational(pack.count)))
        }
        return total
    }
}

public enum GroceryTripAction: String, Codable, Sendable {
    case pick, unavailable, deferPick, addFind
}

public struct GroceryTripUndo: Codable, Equatable, Sendable {
    public let action: GroceryTripAction
    public let at: Date
    let pick: PhysicalGroceryPick?
    let checkedAt: Date?
    let observed: ShoppingStopObservation?
    let price: PickedLinePrice?

    init(_ line: ShoppingLine, action: GroceryTripAction, at: Date) {
        self.action = action
        self.at = at
        pick = line.tripPick
        checkedAt = line.checkedAt
        observed = line.stopObservation
        price = line.pickedPrice
    }
}

extension ShoppingLine {
    public var inStorePickedAt: Date? { tripPick?.at ?? checkedAt }
    public var canUndoInStore: Bool { !isHandled && !isTrashed && (tripUndo != nil || isChecked) }

    public func eligibleForStop(named store: String) -> Bool {
        guard !store.isEmpty, let stores = preferredStores, !stores.isEmpty else { return true }
        return stores.contains { $0.caseInsensitiveCompare(store) == .orderedSame }
    }

    func validateTrip() throws {
        for pick in [tripPick, tripUndo?.pick].compactMap({ $0 }) {
            try pick.amount.validate()
            try ledgerDate(pick.at)
            guard pick.amount.amount > .zero else { throw LedgerError.invalid("tripPick") }
            if let packages = pick.packages, !packages.isEmpty,
               try PhysicalGroceryPick.total(packages, in: pick.amount.unit) != pick.amount.amount {
                throw LedgerError.invalid("tripPickPackages")
            }
        }
        try ledgerDate(tripUndo?.at)
        try ledgerDate(tripUndo?.checkedAt)
        try tripUndo?.price?.validate()
        try Self.validateStorePreferences(preferredStores ?? [])
    }

    static func validateStorePreferences(_ stores: [String]) throws {
        guard stores.count <= 30, Set(stores.map { $0.lowercased() }).count == stores.count else {
            throw LedgerError.invalid("preferredStores")
        }
        for store in stores {
            try ledgerText(store, nonempty: true, maximum: 512)
            guard store == store.trimmingCharacters(in: .whitespacesAndNewlines) else {
                throw LedgerError.invalid("preferredStores")
            }
        }
    }
}

extension ShoppingLedger {
    public var currentStop: ShoppingStop { shoppingStop ?? ShoppingStop(id: id, name: basis.branch) }

    public func outcomeAtCurrentStop(_ line: ShoppingLine) -> ShoppingStopOutcome? {
        guard let observation = line.stopObservation else { return nil }
        if observation.outcome == .deferred { return .deferred }
        return observation.stopID == currentStop.id ? observation.outcome : nil
    }

    public func belongsInCurrentBasket(_ line: ShoppingLine) -> Bool {
        guard !line.isTrashed, !line.isHandled else { return false }
        return line.inStorePickedAt != nil || (outcomeAtCurrentStop(line) == nil && line.eligibleForStop(named: currentStop.name))
    }

    public func isLeftForNextTrip(_ line: ShoppingLine) -> Bool { outcomeAtCurrentStop(line) == .deferred }

    public var inStorePickedLines: [ShoppingLine] {
        lines.filter { !$0.isHandled && !$0.isTrashed && $0.inStorePickedAt != nil }
            .sorted { ($0.inStorePickedAt ?? .distantPast) > ($1.inStorePickedAt ?? .distantPast) }
    }

    /// For old full checkoffs, the original line was the picked amount. An
    /// unresolved name-only item can still be checked without inventing a unit.
    public func pickedQuantity(forLineID id: UUID) throws -> Quantity? {
        guard let line = lines.first(where: { $0.id == id }) else { throw LedgerError.notFound(id) }
        if let actual = line.tripPick?.amount { return actual }
        return line.isChecked ? try quantity(forLineID: id) : nil
    }

    public func outstandingQuantity(forLineID id: UUID) throws -> Quantity? {
        guard let line = lines.first(where: { $0.id == id }) else { throw LedgerError.notFound(id) }
        guard let need = try quantity(forLineID: id) else { return nil }
        if line.isChecked { return Quantity(amount: .zero, unit: need.unit, originalLiteral: "") }
        guard let pick = line.tripPick else { return need }
        guard let bought = try pick.amount.converted(to: need.unit) else { return nil }
        return Quantity(amount: try need.amount.subtractingClampedToZero(bought), unit: need.unit, originalLiteral: "")
    }

    public mutating func pickPart(lineID: UUID, amount: Rational, expectedRevision: UUID, at: Date = Date()) throws {
        guard revisionID == expectedRevision, let remaining = try outstandingQuantity(forLineID: lineID),
              amount > .zero, amount <= remaining.amount, let need = try quantity(forLineID: lineID) else {
            throw LedgerError.stalePreview
        }
        let actual = try need.amount.subtracting(remaining.amount).adding(amount)
        try editTripLine(lineID: lineID, operation: "pickPart", at: at) { line in
            guard !line.isChecked else { throw LedgerError.stalePreview }
            line.tripUndo = GroceryTripUndo(line, action: .pick, at: at)
            line.tripPick = PhysicalGroceryPick(amount: Quantity(amount: actual, unit: need.unit, originalLiteral: ""), at: at)
            line.checkedAt = amount == remaining.amount ? at : nil
            line.stopObservation = nil
            line.pickedPrice = nil
        }
    }

    public mutating func markUnavailable(lineID: UUID, expectedRevision: UUID, at: Date = Date()) throws {
        guard revisionID == expectedRevision else { throw LedgerError.stalePreview }
        let stop = currentStop
        try editTripLine(lineID: lineID, operation: "markUnavailable", at: at) { line in
            guard !line.isChecked, line.stopObservation?.stopID != stop.id else { throw LedgerError.stalePreview }
            line.tripUndo = GroceryTripUndo(line, action: .unavailable, at: at)
            line.stopObservation = .init(stopID: stop.id, outcome: .unavailable)
        }
    }

    public mutating func leaveForNextTrip(lineID: UUID, expectedRevision: UUID, at: Date = Date()) throws {
        guard revisionID == expectedRevision else { throw LedgerError.stalePreview }
        _ = try previewBudgetDeferral(lineID: lineID)
        let stop = currentStop
        try editTripLine(lineID: lineID, operation: "deferTripPick", at: at) { line in
            line.tripUndo = GroceryTripUndo(line, action: .deferPick, at: at)
            line.tripPick = nil
            line.checkedAt = nil
            line.pickedPrice = nil
            line.stopObservation = .init(stopID: stop.id, outcome: .deferred)
        }
    }

    public mutating func undoInStore(lineID: UUID, expectedRevision: UUID, at: Date = Date()) throws {
        guard revisionID == expectedRevision, let line = lines.first(where: { $0.id == lineID }), line.canUndoInStore
        else { throw LedgerError.stalePreview }
        if line.tripUndo != nil { try undoTripChange(lineID: lineID, expectedRevision: expectedRevision, at: at) }
        else { try setChecked(lineID: lineID, checked: false, at: at) }
    }

    public mutating func undoTripChange(lineID: UUID, expectedRevision: UUID, at: Date = Date()) throws {
        guard revisionID == expectedRevision else { throw LedgerError.stalePreview }
        try editTripLine(lineID: lineID, operation: "undoTripPick", at: at) { line in
            guard let undo = line.tripUndo else { throw LedgerError.stalePreview }
            line.checkedAt = undo.checkedAt
            line.tripPick = undo.pick
            line.stopObservation = undo.observed
            if undo.action != .unavailable { line.pickedPrice = undo.price }
            line.tripUndo = nil
            if undo.action == .addFind { line.trashedAt = at }
        }
    }

    public mutating func setPreferredStores(_ stores: [String], lineID: UUID, expectedRevision: UUID, at: Date = Date()) throws {
        guard revisionID == expectedRevision else { throw LedgerError.stalePreview }
        try ShoppingLine.validateStorePreferences(stores)
        try editTripLine(lineID: lineID, operation: "setPreferredStores", at: at) { line in
            line.preferredStores = stores.isEmpty ? nil : stores
        }
    }
}
