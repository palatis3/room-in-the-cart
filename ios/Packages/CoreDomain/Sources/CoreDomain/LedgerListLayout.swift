import Foundation

public enum LedgerListOrder: String, Codable, CaseIterable, Sendable { case entered, manual, aisle }

public struct ShopListLayout: Codable, Equatable, Sendable {
    public var mode: LedgerListOrder = .entered
    public var lineOrder: [UUID] = []
    public var aisleOverride: [String]?
    public var branch = ""
    public var departmentStore: ShopDepartmentSnapshot?
    public var rowDepartments: [String: String]?
    public init() {}

    /// Reorder the editable rows while preserving the positions of checked, handled and trashed rows.
    public mutating func setActiveOrder(_ activeIDs: [UUID], in shop: ShoppingLedger) throws {
        let active = Set(activeIDs)
        let expected = shop.lines.filter { !$0.isChecked && !$0.isHandled && !$0.isTrashed }
        guard active.count == activeIDs.count, active == Set(expected.map(\.id)) else { throw LedgerError.stalePreview }
        let ranked = Set(lineOrder)
        let unranked = shop.lines.sorted { $0.originalOrder < $1.originalOrder }.map(\.id).filter { !ranked.contains($0) }
        var next = activeIDs.makeIterator()
        lineOrder = (lineOrder + unranked).map { id in
            if active.contains(id), let replacement = next.next() { return replacement }
            return id
        }
    }
}

/// Department assignments are private list presentation. A dated list keeps the assignments
/// that were known when its rows were added, even after a shopper corrects the store memory.
public struct ShopDepartmentSnapshot: Codable, Equatable, Sendable {
    public let storeID: UUID
    public let branch: String
    public var order: [String]
    public var rows: [String: String]
}

public struct DepartmentStore: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public var products: [String: String]
    public var order: [String]
}

public struct DepartmentDirectory: Codable, Equatable, Sendable {
    public var stores: [String: DepartmentStore] = [:]
    public var aliases: [String: UUID] = [:]
}

public struct LedgerListLayout: Codable, Equatable, Sendable {
    public struct Group: Identifiable, Sendable {
        public let aisle: String
        public let lines: [ShoppingLine]
        public var id: String { aisle }
    }
    public private(set) var departmentDirectory: DepartmentDirectory?
    public var storeAisles: [String: [String]] = [:]
    public var shopLayouts: [String: ShopListLayout] = [:]
    public init() {}

    public func layout(for shop: ShoppingLedger) -> ShopListLayout {
        shopLayouts[shop.id.uuidString.lowercased()] ?? ShopListLayout()
    }
    private static func branch(_ shop: ShoppingLedger) -> String {
        shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Full, shopper-reviewed item label. Keep accents, brand, variant and package wording.
    private static func product(_ name: String) -> String {
        name.lowercased(with: Locale(identifier: "en_US_POSIX"))
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    public func department(for line: ShoppingLine, in shop: ShoppingLedger) -> String {
        let layout = layout(for: shop)
        let key = line.id.uuidString.lowercased()
        if let explicit = layout.rowDepartments?[key] { return explicit }
        if let saved = layout.departmentStore, saved.branch == Self.branch(shop), let department = saved.rows[key] {
            return department
        }
        if !line.aisle.isEmpty { return line.aisle }
        return GroceryDepartment.suggested(for: line.name)?.label(spanish: GroceryDepartment.usesSpanish) ?? ""
    }

    public func matchedStore(in shop: ShoppingLedger) -> UUID? {
        let branch = Self.branch(shop)
        if let snapshot = layout(for: shop).departmentStore, snapshot.branch == branch {
            return snapshot.storeID
        }
        return departmentDirectory?.aliases[branch]
    }

    /// The shopper explicitly confirms this spelling as a branch alias or creates a separate store.
    @discardableResult
    public mutating func matchStore(in shop: ShoppingLedger, to existing: UUID?, name: String? = nil) throws -> UUID {
        let branch = Self.branch(shop)
        guard !branch.isEmpty else { throw LedgerError.invalid("storeBranch") }
        var directory = departmentDirectory ?? DepartmentDirectory()
        let id = existing ?? UUID()
        let key = id.uuidString.lowercased()
        if existing == nil {
            let label = (name ?? branch).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !label.isEmpty, !directory.stores.values.contains(where: { $0.name == label }) else {
                throw LedgerError.invalid("storeName")
            }
            directory.stores[key] = DepartmentStore(id: id, name: label, products: [:], order: storeAisles[branch] ?? [])
        }
        guard let store = directory.stores[key] else { throw LedgerError.stalePreview }
        directory.aliases[branch] = id
        departmentDirectory = directory
        attach(store, to: shop)
        return id
    }

    private mutating func attach(_ store: DepartmentStore, to shop: ShoppingLedger) {
        let shopKey = shop.id.uuidString.lowercased()
        var layout = layout(for: shop)
        if let previous = layout.departmentStore, previous.storeID != store.id {
            layout.aisleOverride = nil
        }
        let rows = shop.lines.compactMap { line -> (String, String)? in
            guard line.aisle.isEmpty, let value = store.products[Self.product(line.name)] else { return nil }
            return (line.id.uuidString.lowercased(), value)
        }
        layout.departmentStore = ShopDepartmentSnapshot(storeID: store.id, branch: Self.branch(shop),
            order: store.order, rows: Dictionary(rows, uniquingKeysWith: { first, _ in first }))
        shopLayouts[shopKey] = layout
    }

    private mutating func confirmedStore(in shop: ShoppingLedger) throws -> UUID {
        if let saved = layout(for: shop).departmentStore, saved.branch == Self.branch(shop) { return saved.storeID }
        return try matchStore(in: shop, to: matchedStore(in: shop))
    }

    public mutating func setDepartment(_ value: String, for line: ShoppingLine, in shop: ShoppingLedger,
                                       remember: Bool) throws {
        guard shop.lines.contains(line) else { throw LedgerError.stalePreview }
        let department = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard department.utf8.count <= 512 else { throw LedgerError.invalid("department") }
        let shopKey = shop.id.uuidString.lowercased(), row = line.id.uuidString.lowercased()
        if remember {
            let id = try confirmedStore(in: shop)
            let key = id.uuidString.lowercased(), product = Self.product(line.name)
            guard !product.isEmpty, var store = departmentDirectory?.stores[key] else { throw LedgerError.stalePreview }
            store.products[product] = department
            departmentDirectory?.stores[key] = store
            shopLayouts[shopKey]?.departmentStore?.rows[row] = department
            shopLayouts[shopKey]?.rowDepartments?[row] = nil
            return
        }
        var layout = layout(for: shop)
        var rows = layout.rowDepartments ?? [:]
        rows[row] = department
        layout.rowDepartments = rows
        shopLayouts[shopKey] = layout
    }

    public mutating func setStoreOrder(_ names: [String], in shop: ShoppingLedger) throws {
        let id = try confirmedStore(in: shop)
        departmentDirectory?.stores[id.uuidString.lowercased()]?.order = names
        shopLayouts[shop.id.uuidString.lowercased()]?.departmentStore?.order = names
    }

    public mutating func applyDepartmentMemory(to shops: [ShoppingLedger], previous: [ShoppingLedger]) {
        guard let directory = departmentDirectory else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for shop in shops {
            let prior = previousByID[shop.id]
            guard prior?.revisionID != shop.revisionID else { continue }
            let branch = Self.branch(shop), shopKey = shop.id.uuidString.lowercased()
            if prior == nil || prior.map(Self.branch) != branch {
                if let id = directory.aliases[branch], let store = directory.stores[id.uuidString.lowercased()] {
                    let newList = (prior == nil || prior?.basis.branch.isEmpty == true) && shopLayouts[shopKey] == nil
                    attach(store, to: shop)
                    if newList { shopLayouts[shopKey]?.mode = .aisle }
                } else { shopLayouts[shopKey]?.departmentStore = nil }
                continue
            }
            guard let id = matchedStore(in: shop), let store = directory.stores[id.uuidString.lowercased()] else { continue }
            var layout = layout(for: shop)
            // A pre-existing list can gain new rows after another pickup taught
            // this branch a correction. Snapshot only newly added/renamed rows.
            var saved = layout.departmentStore.flatMap { $0.branch == branch ? $0 : nil } ??
                ShopDepartmentSnapshot(storeID: store.id, branch: branch, order: store.order, rows: [:])
            let oldNames = Dictionary(uniqueKeysWithValues: (prior?.lines ?? []).map { ($0.id, $0.name) })
            for line in shop.lines where oldNames[line.id] != line.name {
                let row = line.id.uuidString.lowercased()
                if oldNames[line.id] == nil || saved.rows[row] != store.products[Self.product(line.name)] {
                    saved.rows[row] = line.aisle.isEmpty ? store.products[Self.product(line.name)] : nil
                }
            }
            layout.departmentStore = saved
            shopLayouts[shopKey] = layout
        }
    }

    public func aisleNames(in shop: ShoppingLedger) -> [String] {
        let layout = layout(for: shop)
        let branch = shop.basis.branch.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = layout.departmentStore.flatMap { $0.branch == branch ? $0.order : nil }
        let preferred = (layout.branch == branch ? layout.aisleOverride : nil) ?? saved ?? storeAisles[branch] ?? []
        var seen = Set<String>()
        return (preferred + shop.lines.filter { !$0.isTrashed }.sorted { $0.originalOrder < $1.originalOrder }.map { department(for: $0, in: shop) })
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }
    public func departmentChoices(in shop: ShoppingLedger, spanish: Bool = GroceryDepartment.usesSpanish) -> [String] {
        let defaults = GroceryDepartment.allCases.map { $0.label(spanish: spanish) }
        return Set(aisleNames(in: shop) + defaults).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    public func groups(shop: ShoppingLedger, search: String = "", excluding lineIDs: Set<UUID> = []) -> [Group] {
        let layout = layout(for: shop)
        let matches = shop.search(search, department: { department(for: $0, in: shop) })
        var lines = matches.filter { !$0.isChecked && !$0.isHandled && !$0.isTrashed && !lineIDs.contains($0.id) }
        if layout.mode != .entered {
            let rank = Dictionary(uniqueKeysWithValues: layout.lineOrder.enumerated().map { ($0.element,$0.offset) })
            lines.sort { (rank[$0.id] ?? Int.max,$0.originalOrder) < (rank[$1.id] ?? Int.max,$1.originalOrder) }
        }
        guard layout.mode == .aisle else { return [Group(aisle:"",lines:lines)] }
        let byAisle = Dictionary(grouping: lines) { $0.aisle.trimmingCharacters(in: .whitespacesAndNewlines) }
        return (aisleNames(in: shop) + [""]).compactMap { key in byAisle[key].map { Group(aisle:key,lines:$0) } }
    }
    public func scoped(to shop: ShoppingLedger) -> LedgerListLayout {
        let key = shop.id.uuidString.lowercased(), branch = Self.branch(shop)
        let visible = Set(shop.lines.map { department(for: $0, in: shop).trimmingCharacters(in: .whitespacesAndNewlines) })
        var result = LedgerListLayout()
        if var layout = shopLayouts[key] {
            layout.aisleOverride = layout.aisleOverride?.filter(visible.contains)
            if var saved = layout.departmentStore, saved.branch == branch,
               var store = departmentDirectory?.stores[saved.storeID.uuidString.lowercased()] {
                var products: [String: String] = [:]
                var visibleRows: [String: String] = [:]
                for line in shop.lines {
                    let product = Self.product(line.name)
                    let value = department(for: line, in: shop)
                    if store.products[product] == value { products[product] = value }
                    visibleRows[line.id.uuidString.lowercased()] = value
                }
                store.products = products
                store.order = store.order.filter(visible.contains)
                // A separate pickup’s name or previously matched alias is outside this export.
                store = DepartmentStore(id: store.id, name: branch, products: store.products, order: store.order)
                saved.order = saved.order.filter(visible.contains)
                saved.rows = saved.rows.filter { visibleRows[$0.key] == $0.value }
                layout.departmentStore = saved
                var directory = DepartmentDirectory()
                directory.stores[store.id.uuidString.lowercased()] = store
                directory.aliases[branch] = store.id
                result.departmentDirectory = directory
            } else { layout.departmentStore = nil }
            result.shopLayouts[key] = layout
        }
        if let order = storeAisles[branch]?.filter(visible.contains), !order.isEmpty {
            result.storeAisles[branch] = order
        }
        return result
    }

    public func validate(shops: [ShoppingLedger]) throws {
        guard storeAisles.count <= 500, shopLayouts.count <= shops.count else { throw LedgerError.invalid("listLayout") }
        func validateAisles(_ names: [String]) throws {
            guard names.count <= 10_000, Set(names).count == names.count,
                  names.allSatisfy({ !$0.isEmpty && $0.count <= 512 && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines) })
            else { throw LedgerError.invalid("aisleOrder") }
        }
        func validLabel(_ value: String) -> Bool {
            !value.isEmpty && value.utf8.count <= 512 && value == value.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        if let directory = departmentDirectory {
            guard directory.stores.count <= 500, directory.aliases.count <= 1_000,
                  Set(directory.stores.values.map(\.name)).count == directory.stores.count else { throw LedgerError.invalid("departmentStores") }
            for (key, store) in directory.stores {
                guard key == store.id.uuidString.lowercased(), validLabel(store.name), store.products.count <= 10_000,
                      store.products.allSatisfy({ $0.key.utf8.count <= 8192 && !$0.key.isEmpty &&
                          $0.key == Self.product($0.key) && ($0.value.isEmpty || validLabel($0.value)) }) else { throw LedgerError.invalid("departmentProducts") }
                try validateAisles(store.order)
            }
            for (alias, id) in directory.aliases {
                guard validLabel(alias), directory.stores[id.uuidString.lowercased()] != nil else { throw LedgerError.invalid("departmentAlias") }
            }
        }
        for (branch,names) in storeAisles {
            guard !branch.isEmpty,branch.count <= 512 else { throw LedgerError.invalid("storeOrder") }
            try validateAisles(names)
        }
        for (id,layout) in shopLayouts {
            guard let shop = shops.first(where: { $0.id.uuidString.lowercased() == id }),
                  layout.branch.count <= 512, Set(layout.lineOrder).count == layout.lineOrder.count,
                  Set(layout.lineOrder).isSubset(of: Set(shop.lines.map(\.id))) else { throw LedgerError.invalid("shopOrder") }
            let lineIDs = Set(shop.lines.map { $0.id.uuidString.lowercased() })
            if let rows = layout.rowDepartments {
                guard rows.allSatisfy({ lineIDs.contains($0.key) && ($0.value.isEmpty || validLabel($0.value)) }) else {
                    throw LedgerError.invalid("rowDepartments")
                }
            }
            if let saved = layout.departmentStore {
                guard validLabel(saved.branch), departmentDirectory?.stores[saved.storeID.uuidString.lowercased()] != nil,
                      saved.rows.allSatisfy({ lineIDs.contains($0.key) && ($0.value.isEmpty || validLabel($0.value)) }) else {
                    throw LedgerError.invalid("shopDepartments")
                }
                try validateAisles(saved.order)
            }
            try validateAisles(layout.aisleOverride ?? [])
        }
    }
}
