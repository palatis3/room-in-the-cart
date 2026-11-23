import Foundation

public struct StoreOrderMinimum: Codable, Equatable, Sendable {
    public enum Kind: String, Codable, CaseIterable, Sendable { case unknown, noneRequired, required }
    public enum Status: String, Codable, Sendable { case unknown, noneRequired, met, notMet }
    public let kind: Kind
    public let minimum: Money?
    /// The retailer's reviewed qualifying merchandise subtotal. Fees and trip cash never satisfy an order minimum.
    public let eligibleSubtotal: Money?
    public init(_ kind: Kind, minimum: Money? = nil, eligibleSubtotal: Money? = nil) {
        self.kind = kind; self.minimum = minimum; self.eligibleSubtotal = eligibleSubtotal
    }
    public func status() throws -> Status {
        guard minimum.map({ $0.minorUnits >= 0 }) ?? true, eligibleSubtotal.map({ $0.minorUnits >= 0 }) ?? true else { throw DinnerPlanningError.invalid("orderMinimum") }
        switch kind {
        case .unknown, .noneRequired:
            guard minimum == nil, eligibleSubtotal == nil else { throw DinnerPlanningError.invalid("orderMinimum") }
            return kind == .unknown ? .unknown : .noneRequired
        case .required:
            guard let minimum else { throw DinnerPlanningError.invalid("orderMinimum") }
            guard let eligibleSubtotal else { return .unknown }
            guard eligibleSubtotal.currency == minimum.currency else { throw DinnerPlanningError.invalid("orderMinimum") }
            return eligibleSubtotal < minimum ? .notMet : .met
        }
    }
}

public struct StoreCommitmentSupply: Codable, Equatable, Sendable, Identifiable {
    public var id: UUID { commitmentID }
    public let commitmentID: UUID
    public let unit: UnitOfMeasure
    public let requiredUnits: Int64
    public let usableUnitsPerPackage: Int64
    public let packages: Int64
    public init(commitmentID: UUID, unit: UnitOfMeasure, requiredUnits: Int64, usableUnitsPerPackage: Int64, packages: Int64) {
        self.commitmentID = commitmentID; self.unit = unit; self.requiredUnits = requiredUnits
        self.usableUnitsPerPackage = usableUnitsPerPackage; self.packages = packages
    }
    public func surplus() throws -> Int64 {
        guard [.count, .gram, .milliliter].contains(unit), (1...1_000_000_000).contains(requiredUnits),
              (1...1_000_000_000).contains(usableUnitsPerPackage), (0...100_000).contains(packages) else {
            throw DinnerPlanningError.invalid("commitmentSupply")
        }
        return try checkedMultiply(usableUnitsPerPackage, packages) - requiredUnits
    }
}
