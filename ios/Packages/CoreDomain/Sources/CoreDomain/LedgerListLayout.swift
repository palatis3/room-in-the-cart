import Foundation

public enum LedgerListOrder: String, Codable, CaseIterable, Sendable { case entered, manual, aisle }

public struct ShopListLayout: Codable, Equatable, Sendable {
    public var mode: LedgerListOrder = .entered
    public var lineOrder: [UUID] = []
    public var aisleOverride: [String]?
    public var branch = ""
    public var departmentStore: ShopDepartmentSnapshot?
    public var rowDepartments: [String: String]?
    fileprivate var aislePicks: [String: StoreAislePick]?
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

private struct StoreAislePick: Codable, Equatable, Sendable {
    let storeID: UUID
    let stopID: UUID
    let aisle: String
    let checkedAt: Date
}

public struct DepartmentStore: Codable, Equatable, Sendable, Identifiable {
    public let id: UUID
    public let name: String
    public var products: [String: String]
    public fileprivate(set) var learnsAisles: Bool? = nil
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
        shop.currentStop.name.trimmingCharacters(in: .whitespacesAndNewlines)
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

    public func departmentStore(in shop: ShoppingLedger) -> DepartmentStore? {
        guard let id = matchedStore(in: shop) else { return nil }
        return departmentDirectory?.stores[id.uuidString.lowercased()]
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
            if previous.branch == Self.branch(shop) {
                layout.aislePicks = layout.aislePicks?.filter { $0.value.stopID != shop.currentStop.id }
            }
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

    public mutating func followStoreOrder(in shop: ShoppingLedger) throws {
        guard let store = departmentStore(in: shop) else { return }
        _ = try confirmedStore(in: shop)
        shopLayouts[shop.id.uuidString.lowercased()]?.departmentStore?.order = store.order
    }

    public mutating func resetStoreOrder(in shop: ShoppingLedger) throws {
        let id = try confirmedStore(in: shop)
        for (alias, storeID) in departmentDirectory?.aliases ?? [:] where storeID == id {
            storeAisles.removeValue(forKey: alias)
        }
        try setStoreOrder([], in: shop)
        shopLayouts[shop.id.uuidString.lowercased()]?.aisleOverride = nil
    }

    public mutating func setAisleLearning(_ enabled: Bool, in shop: ShoppingLedger) throws {
        let id = try confirmedStore(in: shop)
        departmentDirectory?.stores[id.uuidString.lowercased()]?.learnsAisles = enabled ? true : nil
        if !enabled {
            for key in shopLayouts.keys {
                guard let picks = shopLayouts[key]?.aislePicks, picks.values.contains(where: { $0.storeID == id }) else { continue }
                let retained = picks.filter { $0.value.storeID != id }
                shopLayouts[key]?.aislePicks = retained.isEmpty ? nil : retained
            }
        }
    }

    /// Called in the same local transaction as the shopper’s in-store checkbox.
    public mutating func recordAislePick(for rowID: UUID, in shop: ShoppingLedger) {
        guard let store = departmentStore(in: shop), store.learnsAisles == true,
              let line = shop.lines.first(where: { $0.id == rowID }), let checkedAt = line.checkedAt else { return }
        let aisle = department(for: line, in: shop).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !aisle.isEmpty, aisle.utf8.count <= 512 else { return }
        let key = shop.id.uuidString.lowercased()
        var layout = layout(for: shop)
        var picks = layout.aislePicks ?? [:]
        picks[rowID.uuidString.lowercased()] = StoreAislePick(storeID: store.id, stopID: shop.currentStop.id, aisle: aisle, checkedAt: checkedAt)
        layout.aislePicks = picks
        shopLayouts[key] = layout
    }

    /// Two distinct prior lists must agree. Do not combine purchases from different
    /// stops within a list, undone checks, or two visits on the same list.
    public func suggestedStoreOrder(storeID: UUID, for shop: ShoppingLedger, aisles: [String], history: [ShoppingLedger]) -> [String]? {
        guard departmentDirectory?.stores[storeID.uuidString.lowercased()]?.learnsAisles == true else { return nil }
        let allowed = Set(aisles)
        var evidence: [(date: Date, order: [String])] = []
        var seenLists: Set<UUID> = [shop.id]
        for prior in history where seenLists.insert(prior.id).inserted {
            guard let observations = layout(for: prior).aislePicks else { continue }
            let valid = prior.lines.compactMap { row -> StoreAislePick? in
                guard !row.isTrashed, let pick = observations[row.id.uuidString.lowercased()], pick.storeID == storeID,
                      pick.checkedAt == row.checkedAt else { return nil }
                let aisle = Self.displayAisle(pick.aisle, among: allowed)
                guard allowed.contains(aisle) else { return nil }
                return StoreAislePick(storeID: storeID, stopID: pick.stopID, aisle: aisle, checkedAt: pick.checkedAt)
            }
            let visits = Dictionary(grouping: valid, by: \.stopID)
            let routes = visits.values.compactMap { visit -> (date: Date, order: [String])? in
                let sorted = visit.sorted { $0.checkedAt < $1.checkedAt }
                var seen = Set<String>()
                let order = sorted.map(\.aisle).filter { seen.insert($0).inserted }
                guard order.count >= 2, Set(sorted.map(\.checkedAt)).count == sorted.count, let last = sorted.last else { return nil }
                return (last.checkedAt, order)
            }
            if let latest = routes.max(by: { $0.date < $1.date }) { evidence.append(latest) }
        }
        let latest = evidence.sorted { $0.date > $1.date }.prefix(2)
        guard latest.count == 2, let first = latest.first, let second = latest.last, first.order == second.order else { return nil }
        let seen = Set(first.order)
        var route = first.order.makeIterator()
        let proposed = aisles.map { seen.contains($0) ? (route.next() ?? $0) : $0 }
        return proposed == aisles ? nil : proposed
    }

    public mutating func applyDepartmentMemory(to shops: [ShoppingLedger], previous: [ShoppingLedger]) {
        guard let directory = departmentDirectory else { return }
        let previousByID = Dictionary(uniqueKeysWithValues: previous.map { ($0.id, $0) })
        for shop in shops {
            let prior = previousByID[shop.id]
            guard prior?.revisionID != shop.revisionID else { continue }
            let branch = Self.branch(shop), shopKey = shop.id.uuidString.lowercased()
            if let picks = shopLayouts[shopKey]?.aislePicks {
                let checked = Dictionary(uniqueKeysWithValues: shop.lines.compactMap { row in
                    row.checkedAt.map { (row.id.uuidString.lowercased(), $0) }
                })
                let retained = picks.filter { checked[$0.key] == $0.value.checkedAt }
                shopLayouts[shopKey]?.aislePicks = retained.isEmpty ? nil : retained
            }
            if prior == nil || prior.map(Self.branch) != branch {
                if let id = directory.aliases[branch], let store = directory.stores[id.uuidString.lowercased()] {
                    let useStoreDefault = shopLayouts[shopKey] == nil
                    attach(store, to: shop)
                    if useStoreDefault { shopLayouts[shopKey]?.mode = .aisle }
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

    /// Built-in department suggestions follow the display language. Preserve a
    /// literal customer label whenever it is present in the current list.
    private static let alternateLabels: [String: String] = Dictionary(uniqueKeysWithValues:
        GroceryDepartment.allCases.flatMap { department in
            let en = department.label(spanish: false), es = department.label(spanish: true)
            return [(en, es), (es, en)]
        })

    private static func displayAisle(_ aisle: String, among labels: Set<String>) -> String {
        guard !labels.contains(aisle), let alternate = alternateLabels[aisle], labels.contains(alternate) else { return aisle }
        return alternate
    }

    public func aisleNames(in shop: ShoppingLedger) -> [String] {
        let layout = layout(for: shop)
        let branch = shop.currentStop.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let saved = layout.departmentStore.flatMap { $0.branch == branch ? $0.order : nil }
        let store = departmentStore(in: shop)
        let preferred = (layout.branch == branch ? layout.aisleOverride : nil) ?? saved ?? store?.order ?? storeAisles[branch] ?? []
        let rowAisles = shop.lines.filter { !$0.isTrashed }.sorted { $0.originalOrder < $1.originalOrder }
            .map { department(for: $0, in: shop).trimmingCharacters(in: .whitespacesAndNewlines) }
        let available = Set(rowAisles)
        var seen = Set<String>()
        return (preferred.map { Self.displayAisle($0, among: available) } + rowAisles)
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
        func visibleOrder(_ order: [String]) -> [String] {
            var seen = Set<String>()
            return order.map { Self.displayAisle($0, among: visible) }.filter { visible.contains($0) && seen.insert($0).inserted }
        }
        var result = LedgerListLayout()
        if var layout = shopLayouts[key] {
            layout.aislePicks = nil
            layout.aisleOverride = layout.aisleOverride.map(visibleOrder)
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
                store.order = visibleOrder(store.order)
                // A separate pickup’s name or previously matched alias is outside this export.
                store = DepartmentStore(id: store.id, name: branch, products: store.products, order: store.order)
                saved.order = visibleOrder(saved.order)
                saved.rows = saved.rows.filter { visibleRows[$0.key] == $0.value }
                layout.departmentStore = saved
                var directory = DepartmentDirectory()
                directory.stores[store.id.uuidString.lowercased()] = store
                directory.aliases[branch] = store.id
                result.departmentDirectory = directory
            } else { layout.departmentStore = nil }
            result.shopLayouts[key] = layout
        }
        if let order = storeAisles[branch].map(visibleOrder), !order.isEmpty {
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
            if let picks = layout.aislePicks {
                guard picks.allSatisfy({ key, pick in
                    lineIDs.contains(key) && validLabel(pick.aisle) && pick.checkedAt.timeIntervalSinceReferenceDate.isFinite &&
                        departmentDirectory?.stores[pick.storeID.uuidString.lowercased()]?.learnsAisles == true
                }) else { throw LedgerError.invalid("aislePicks") }
            }
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
