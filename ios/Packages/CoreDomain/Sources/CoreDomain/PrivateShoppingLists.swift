import Foundation

public struct PickedLinePrice: Codable, Sendable, Equatable {
    public let total: Money?
    public let membership: Bool
    public let weighted: Bool
    public let conditionsConfirmed: Bool
    let checkedAt: Date
    let name: String
    let quantity: Quantity?
    let basisRevision: Int
    public internal(set) var shelf: PickedShelfPrice? = nil

    /// Confirmed reduction for this entire picked line, in the same currency as its recorded price.
    public internal(set) var discount: Money? = nil

    public static func netPrice(total: Money?, discount: Money?) throws -> Money? {
        guard let discount else { return total }
        guard let total, discount.currency == total.currency, discount.minorUnits >= 0, discount.minorUnits <= total.minorUnits
        else { throw LedgerError.invalid("pickedDiscount") }
        return try total.subtracting(discount)
    }

    func validate(currency: Currency) throws {
        guard total.map({ $0.currency == currency }) != false,
              shelf.map({ $0.rate.currency == currency }) != false else { throw LedgerError.invalid("pickedCurrency") }
        // Bounded well above a grocery line, so the subtotal of 10,000 lines also fits.
        if let total, !(0...1_000_000_000).contains(total.minorUnits) { throw LedgerError.invalid("pickedPrice") }
        _ = try Self.netPrice(total: total, discount: discount)
        guard checkedAt.timeIntervalSinceReferenceDate.isFinite, basisRevision >= 0 else { throw LedgerError.invalid("pickedPrice") }
        try ledgerText(name, nonempty: true, maximum: 512)
        try quantity?.validate()
        if let shelf {
            guard try shelf.lineTotal() == total, weighted == (shelf.unit.dimension == .mass) else {
                throw LedgerError.invalid("shelfPrice")
            }
        }
    }

    public var includedTotal: Money? {
        guard (!membership && !weighted) || conditionsConfirmed else { return nil }
        return try? Self.netPrice(total: total, discount: discount)
    }
}

public struct PickedCartSubtotal: Equatable, Sendable {
    public let total: Money
    public let priced: Int
    public let picked: Int
}

extension ShoppingLedger {
    public func priceForCurrentPick(lineID: UUID) -> PickedLinePrice? {
        guard let line = lines.first(where: { $0.id == lineID }) else { return nil }
        return currentPrice(for: line)
    }

    private func currentPrice(for line: ShoppingLine) -> PickedLinePrice? {
        guard let price = line.pickedPrice, !line.isTrashed, !line.isHandled, price.checkedAt == line.inStorePickedAt,
              price.name == line.name, price.basisRevision == basisRevision,
              price.total.map({ $0.currency == basis.currency }) != false else { return nil }
        let actual = line.tripPick?.amount ?? (try? quantity(forLineID: line.id))
        return price.quantity == actual ? price : nil
    }

    public var pickedCartSubtotal: PickedCartSubtotal {
        let picked = lines.filter { $0.inStorePickedAt != nil && !$0.isTrashed && !$0.isHandled }
        let amounts = picked.compactMap { currentPrice(for: $0)?.includedTotal }
        return PickedCartSubtotal(total: Money(minorUnits: amounts.reduce(0) { $0 + $1.minorUnits }, currency: basis.currency),
                                  priced: amounts.count, picked: picked.count)
    }
}

/// List intent only. It deliberately carries no pantry, retailer, or checkout evidence.
public struct ShoppingKitRow: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var quantity: Quantity?
    public var notes: String
    public var exclusions: [String]
    public var optional: Bool

    public init(id: UUID = UUID(), name: String, quantity: Quantity? = nil, notes: String = "",
                exclusions: [String] = [], optional: Bool = false) {
        self.id = id
        self.name = name
        self.quantity = quantity
        self.notes = notes
        self.exclusions = exclusions
        self.optional = optional
    }

    public func overlaps(in shop: ShoppingLedger) -> [ShoppingLine] {
        shop.lines.filter { !$0.isTrashed && normalizedProduct($0.name) == normalizedProduct(name) }
    }

    func validate() throws {
        try ledgerText(name, nonempty: true, maximum: 512)
        try ledgerText(notes)
        try quantity?.validate()
        guard quantity.map({ $0.amount >= .zero }) ?? true, exclusions.count <= 100 else { throw LedgerError.invalid("listItem") }
        for value in exclusions { try ledgerText(value, nonempty: true, maximum: 512) }
        try permittedProduct(name, exclusions: exclusions)
    }

    @discardableResult func append(to shop: inout ShoppingLedger) throws -> UUID {
        try shop.addManualLine(name: name, quantity: quantity, notes: notes, exclusions: exclusions)
    }
}

public struct ShoppingKit: Identifiable, Codable, Equatable, Sendable {
    public let id: UUID
    public var name: String
    public var rows: [ShoppingKitRow]
    public init(id: UUID = UUID(), name: String, rows: [ShoppingKitRow]) {
        self.id = id
        self.name = name
        self.rows = rows
    }
    func validate() throws {
        try ledgerText(name, nonempty: true, maximum: 512)
        guard (1...100).contains(rows.count), Set(rows.map(\.id)).count == rows.count else { throw LedgerError.invalid("kitRows") }
        for row in rows { try row.validate() }
    }
}

public struct StandingListItem: Identifiable, Codable, Equatable, Sendable {
    public var id: UUID { row.id }
    public var row: ShoppingKitRow
    public var stores: [String]
    public internal(set) var checkedAt: Date?
    public internal(set) var transfer: Transfer?
    public struct Transfer: Codable, Equatable, Sendable {
        public let shopID: UUID
        public let lineID: UUID
        public let contributionID: UUID
    }
    public init(row: ShoppingKitRow, stores: [String]) {
        self.row = row
        self.stores = stores
    }
    public func eligible(at store: String) -> Bool {
        stores.contains { $0.caseInsensitiveCompare(store.trimmingCharacters(in: .whitespacesAndNewlines)) == .orderedSame }
    }
    func validate() throws {
        try row.validate()
        if let checkedAt {
            guard checkedAt.timeIntervalSinceReferenceDate.isFinite, transfer == nil else { throw LedgerError.invalid("standingCheck") }
        }
        guard !row.optional, (1...30).contains(stores.count), Set(stores.map { $0.lowercased() }).count == stores.count else {
            throw LedgerError.invalid("standingStoreTags")
        }
        for store in stores {
            try ledgerText(store, nonempty: true, maximum: 512)
            guard store == store.trimmingCharacters(in: .whitespacesAndNewlines) else { throw LedgerError.invalid("standingStoreTags") }
        }
    }
}

public struct PrivateShoppingLists: Codable, Equatable, Sendable {
    public private(set) var kits: [ShoppingKit] = []
    public internal(set) var standing: [StandingListItem] = []
    public init() {}

    public mutating func saveKit(_ kit: ShoppingKit, replacing original: ShoppingKit?) throws {
        try kit.validate()
        guard kits.first(where: { $0.id == kit.id }) == original, original == nil || original?.id == kit.id else { throw LedgerError.stalePreview }
        if let index = kits.firstIndex(where: { $0.id == kit.id }) { kits[index] = kit }
        else {
            guard kits.count < 100 else { throw LedgerError.invalid("kitLimit") }
            kits.append(kit)
        }
    }

    public mutating func deleteKit(_ original: ShoppingKit) throws {
        guard let index = kits.firstIndex(of: original) else { throw LedgerError.stalePreview }
        kits.remove(at: index)
    }

    public mutating func saveStanding(_ item: StandingListItem, replacing original: StandingListItem?) throws {
        try item.validate()
        guard item.transfer == nil, item.checkedAt == original?.checkedAt, standing.first(where: { $0.id == item.id }) == original,
              original == nil || (original?.id == item.id && original?.transfer == nil) else { throw LedgerError.stalePreview }
        if let index = standing.firstIndex(where: { $0.id == item.id }) { standing[index] = item }
        else {
            guard standing.count < 1_000 else { throw LedgerError.invalid("standingLimit") }
            standing.append(item)
        }
    }

    public mutating func setStandingChecked(_ original: StandingListItem, checked: Bool, at: Date = Date()) throws {
        guard at.timeIntervalSinceReferenceDate.isFinite, original.transfer == nil,
              let index = standing.firstIndex(of: original) else { throw LedgerError.stalePreview }
        standing[index].checkedAt = checked ? at : nil
    }

    public mutating func deleteStanding(_ original: StandingListItem) throws {
        guard original.transfer == nil, let index = standing.firstIndex(of: original) else { throw LedgerError.stalePreview }
        standing.remove(at: index)
    }

    /// A library recovery is independent of every pickup. Already-transferred intents
    /// are represented by the purchased/planned rows in their own pickup record.
    public var librarySelection: Self {
        var selection = self
        selection.standing.removeAll { $0.transfer != nil }
        return selection
    }

    func validate(shops: [ShoppingLedger]) throws {
        guard kits.count <= 100, standing.count <= 1000,
              Set(kits.map(\.id)).count == kits.count, Set(standing.map(\.id)).count == standing.count else { throw LedgerError.invalid("listCollection") }
        for kit in kits { try kit.validate() }
        for item in standing {
            try item.validate()
            if let transfer = item.transfer {
                guard let shop = shops.first(where: { $0.id == transfer.shopID }),
                      shop.lines.contains(where: { $0.id == transfer.lineID }),
                      shop.contributions.contains(where: { $0.id == transfer.contributionID }) else { throw LedgerError.invalid("standingTransfer") }
            }
        }
    }
}

extension LedgerWorkspace {
    private func selectedPickup(_ shopID: UUID, revision: UUID) throws -> Int {
        guard selectedShopID == shopID, let index = shops.firstIndex(where: { $0.id == shopID }),
              shops[index].revisionID == revision else { throw LedgerError.stalePreview }
        return index
    }

    public mutating func applyKit(_ kit: ShoppingKit, selected: Set<UUID>, shopID: UUID, revision: UUID) throws {
        let index = try selectedPickup(shopID, revision: revision)
        guard shoppingLists.kits.contains(kit), !selected.isEmpty,
              selected.isSubset(of: Set(kit.rows.map(\.id))) else { throw LedgerError.stalePreview }
        try shops[index].appendKitRows(kit.rows.filter { selected.contains($0.id) })
    }

    public mutating func transferStanding(_ item: StandingListItem, shopID: UUID, revision: UUID) throws {
        let targetIndex = try selectedPickup(shopID, revision: revision)
        var target = shops[targetIndex]
        guard item.transfer == nil, item.checkedAt == nil, let index = shoppingLists.standing.firstIndex(of: item),
              item.eligible(at: target.basis.branch),
              item.row.overlaps(in: target).isEmpty else { throw LedgerError.stalePreview }
        let lineID = try item.row.append(to: &target)
        try target.setPreferredStores(item.stores, lineID: lineID, expectedRevision: target.revisionID)
        guard let source = target.contributions(forLineID: lineID).first else { throw LedgerError.stalePreview }
        shoppingLists.standing[index].transfer = .init(shopID: shopID, lineID: lineID, contributionID: source.id)
        shops[targetIndex] = target
    }

    public func canReturnStanding(_ item: StandingListItem, from target: ShoppingLedger) -> Bool {
        guard let transfer = item.transfer, transfer.shopID == target.id, let line = target.lines.first(where: { $0.id == transfer.lineID }),
              line.inStorePickedAt == nil, line.stopObservation == nil, !line.isHandled, line.stapleApproval == nil, line.name == item.row.name, line.notes == item.row.notes,
              !packSelections.contains(where: { $0.shopID == target.id && $0.lineID == transfer.lineID }),
              let source = target.contributions.first(where: { $0.id == transfer.contributionID }),
              source.lineID == line.id, source.quantity == item.row.quantity, source.notes == item.row.notes, source.exclusions == item.row.exclusions
        else { return false }
        let active = target.contributions(forLineID: line.id)
        return active.isEmpty || (active.count == 1 && active[0].id == source.id)
    }

    public mutating func returnStanding(_ item: StandingListItem, shopID: UUID, revision: UUID) throws {
        let targetIndex = try selectedPickup(shopID, revision: revision)
        guard let index = shoppingLists.standing.firstIndex(of: item), let transfer = item.transfer,
              canReturnStanding(item, from: shops[targetIndex]) else { throw LedgerError.stalePreview }
        var target = shops[targetIndex]
        try target.removeContribution(contributionID: transfer.contributionID)
        shoppingLists.standing[index].transfer = nil
        shops[targetIndex] = target
    }
}
