import Foundation

public enum LedgerListOrder: String, Codable, CaseIterable, Sendable { case entered, manual, aisle }

public struct ShopListLayout: Codable, Equatable, Sendable {
    public var mode: LedgerListOrder = .entered
    public var lineOrder: [UUID] = []
    public var aisleOverride: [String]?
    public var branch = ""
    public init() {}
}

public struct LedgerListLayout: Codable, Equatable, Sendable {
    public struct Group: Identifiable, Sendable {
        public let aisle: String
        public let lines: [ShoppingLine]
        public var id: String { aisle }
    }
    public var storeAisles: [String: [String]] = [:]
    public var shopLayouts: [String: ShopListLayout] = [:]
    public init() {}

    public func layout(for shop: ShoppingLedger) -> ShopListLayout {
        shopLayouts[shop.id.uuidString.lowercased()] ?? ShopListLayout()
    }
    public func aisleNames(in shop: ShoppingLedger) -> [String] {
        let layout = layout(for: shop)
        let branch = shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let preferred = (layout.branch == branch ? layout.aisleOverride : nil) ?? storeAisles[branch] ?? []
        var seen = Set<String>()
        return (preferred + shop.lines.filter { !$0.isTrashed }.sorted { $0.originalOrder < $1.originalOrder }.map(\.aisle))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    public func groups(shop: ShoppingLedger, search: String = "") -> [Group] {
        let layout = layout(for: shop)
        var lines = shop.search(search).filter { !$0.isChecked && !$0.isHandled && !$0.isTrashed }
        if layout.mode != .entered {
            let rank = Dictionary(uniqueKeysWithValues: layout.lineOrder.enumerated().map { ($0.element,$0.offset) })
            lines.sort { (rank[$0.id] ?? Int.max,$0.originalOrder) < (rank[$1.id] ?? Int.max,$1.originalOrder) }
        }
        guard layout.mode == .aisle else { return [Group(aisle:"",lines:lines)] }
        let byAisle = Dictionary(grouping: lines) { $0.aisle.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (aisleNames(in: shop) + [""]).compactMap { key in byAisle[key].map { Group(aisle:key,lines:$0) } }
    }
    public func validate(shops: [ShoppingLedger]) throws {
        guard storeAisles.count <= 500, shopLayouts.count <= shops.count else { throw LedgerError.invalid("listLayout") }
        func validateAisles(_ names: [String]) throws {
            guard names.count <= 10_000, Set(names).count == names.count,
                  names.allSatisfy({ !$0.isEmpty && $0.count <= 512 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            else { throw LedgerError.invalid("aisleOrder") }
        }
        for (branch,names) in storeAisles {
            guard !branch.isEmpty,branch.count <= 512 else { throw LedgerError.invalid("storeOrder") }
            try validateAisles(names)
        }
        for (id,layout) in shopLayouts {
            guard let shop = shops.first(where: { $0.id.uuidString.lowercased() == id }),
                  layout.branch.count <= 512, Set(layout.lineOrder).count == layout.lineOrder.count,
                  Set(layout.lineOrder).isSubset(of: Set(shop.lines.map(\.id))) else { throw LedgerError.invalid("shopOrder") }
            try validateAisles(layout.aisleOverride ?? [])
        }
    }
}
