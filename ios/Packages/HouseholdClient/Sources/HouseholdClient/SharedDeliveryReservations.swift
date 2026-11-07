import Foundation

private typealias Fraction = SharedDeliveryCoverage.Fraction

struct DeliveryReservationTarget: Hashable {
    let ingredient: SharedDeliveryPage.IngredientMatch
    let group: UUID
}

extension SharedDeliveryPage.Reservation {
    var target: DeliveryReservationTarget {
        .init(ingredient: .init(occurrenceId: occurrenceId, mealRevision: mealRevision, ingredientId: ingredientId), group: groupId)
    }
}

extension SharedDeliveryPage {
    /// A legacy total shared by several unnamed portions cannot be reserved for one of them.
    public func reservableQuantity(for target: IngredientMatch, group: UUID) -> SharedMealQuantity? {
        guard let plan = meals?.first(where: { $0.id == target.occurrenceId && $0.revision == target.mealRevision })?.meal.planning,
              plan.groups.contains(where: { $0.id == group }),
              let ingredient = plan.ingredients.first(where: { $0.id == target.ingredientId }),
              ingredient.groupIds.contains(group) else { return nil }
        let bindings = (plan.bindings ?? []).filter { $0.ingredientId == ingredient.id }
        if !bindings.isEmpty {
            guard bindings.count == ingredient.groupIds.count,
                  Set(bindings.map(\.groupId)) == Set(ingredient.groupIds) else { return nil }
            return bindings.first { $0.groupId == group }?.quantity
        }
        return ingredient.groupIds.count == 1 ? ingredient.quantity : nil
    }

    func validateReservations() throws {
        var ids = Set<UUID>()
        for source in sources {
            guard reservationsAvailable == true else {
                guard source.reservations?.isEmpty != false else { throw ClientError.invalidResponse }
                continue
            }
            guard let heads = source.reservations else { throw ClientError.invalidResponse }
            var seen = Set<DeliveryReservationTarget>()
            for head in heads {
                let target = head.target
                guard ids.insert(head.reservationId).inserted, seen.insert(target).inserted,
                      let required = reservableQuantity(for: target.ingredient, group: target.group) else { throw ClientError.invalidResponse }
                if let quantity = head.quantity {
                    guard source.matches?.contains(target.ingredient) == true,
                          (1...1_000_000_000).contains(quantity.amount.numerator),
                          (1...1_000_000_000).contains(quantity.amount.denominator),
                          sharedMealText(quantity.originalLiteral, 240),
                          DeliveryUnit.compatible(quantity.unit, required.unit) else { throw ClientError.invalidResponse }
                }
            }
        }
    }
}

enum DeliveryUnit {
    // Exact factors agreed with service/src/physical-quantity.ts; both factors fit in 32 bits.
    private static func scale(_ unit: HistoryUnit) -> (dimension: String, n: Int, d: Int) {
        switch unit {
        case .count: return ("count", 1, 1)
        case .gram: return ("mass", 1, 1)
        case .kilogram: return ("mass", 1000, 1)
        case .ounce: return ("mass", 45_359_237, 1_600_000)
        case .pound: return ("mass", 45_359_237, 100_000)
        case .milliliter: return ("volume", 1, 1)
        case .liter: return ("volume", 1000, 1)
        case .fluidOunce: return ("volume", 473_176_473, 16_000_000)
        case .cup: return ("volume", 473_176_473, 2_000_000)
        }
    }

    static func compatible(_ from: String, _ to: String) -> Bool {
        guard let a = HistoryUnit(rawValue: from), let b = HistoryUnit(rawValue: to) else { return false }
        return scale(a).dimension == scale(b).dimension
    }

    static func isReduction(_ quantity: SharedMealQuantity, from existing: SharedMealQuantity?) -> Bool {
        guard let existing, let converted = convert(quantity, to: existing.unit) else { return false }
        let saved = Fraction(numerator: String(existing.amount.numerator), denominator: String(existing.amount.denominator))
        return saved.valid && converted.compare(saved) == .orderedAscending
    }

    fileprivate static func convert(_ quantity: SharedMealQuantity, to unit: String) -> Fraction? {
        guard let from = HistoryUnit(rawValue: quantity.unit), let to = HistoryUnit(rawValue: unit),
              scale(from).dimension == scale(to).dimension else { return nil }
        // Each product has at most 27 digits, within Decimal's 38 significant digits.
        let a = scale(from), b = scale(to)
        let n = Decimal(quantity.amount.numerator) * Decimal(a.n) * Decimal(b.d)
        let d = Decimal(quantity.amount.denominator) * Decimal(a.d) * Decimal(b.n)
        return .init(numerator: NSDecimalNumber(decimal: n).stringValue, denominator: NSDecimalNumber(decimal: d).stringValue)
    }
}

private extension SharedDeliveryCoverage.Fraction {
    // Summations over many sources can exceed Decimal's precision. Compare the wire
    // fractions by exact cross multiplication in base 10^9, including zero-backed heads.
    func compare(_ other: Self) -> ComparisonResult {
        func limbs(_ value: String) -> [UInt64] {
            var result = [UInt64](), bytes = value.utf8[...]
            while !bytes.isEmpty {
                let chunk = bytes.suffix(9)
                result.append(chunk.reduce(0) { $0 * 10 + UInt64($1 - 48) })
                bytes = bytes.dropLast(chunk.count)
            }
            return result
        }
        func product(_ a: String, _ b: String) -> [UInt64] {
            let left = limbs(a), right = limbs(b), base: UInt64 = 1_000_000_000
            var result = Array(repeating: UInt64(0), count: left.count + right.count)
            for (i, l) in left.enumerated() {
                var carry: UInt64 = 0
                for (j, r) in right.enumerated() {
                    let value = result[i + j] + l * r + carry
                    result[i + j] = value % base
                    carry = value / base
                }
                result[i + right.count] = carry
            }
            while result.last == 0 { result.removeLast() }
            return result
        }
        let left = product(numerator, other.denominator), right = product(other.numerator, denominator)
        if left.count != right.count { return left.count < right.count ? .orderedAscending : .orderedDescending }
        if left == right { return .orderedSame }
        return left.reversed().lexicographicallyPrecedes(right.reversed()) ? .orderedAscending : .orderedDescending
    }
}

extension SharedDeliveryCoverage.Need {
    func validateReservations(expected: [UUID: SharedDeliveryPage.Reservation], sources: [UUID: SharedDeliveryPage.Source]) throws {
        let rows = reservations ?? []
        guard rows.count == expected.count else { throw ClientError.invalidResponse }
        var seen = Set<UUID>()
        var shortfall = false
        for row in rows {
            guard seen.insert(row.sourceId).inserted,
                  let head = expected[row.sourceId], head.reservationId == row.reservationId,
                  let quantity = head.quantity, let required, let converted = DeliveryUnit.convert(quantity, to: required.unit),
                  row.requested.valid, row.backed.valid, row.requested.compare(converted) == .orderedSame,
                  row.backed.compare(row.requested) != .orderedDescending else { throw ClientError.invalidResponse }
            if row.backed.numerator != "0" {
                guard let allocation = allocations.first(where: { $0.sourceId == row.sourceId }), let covered,
                      let stock = sources[row.sourceId]?.confirmed?.quantity,
                      let available = DeliveryUnit.convert(stock, to: required.unit), available.valid,
                      row.backed.compare(allocation.amount) != .orderedDescending,
                      row.backed.compare(covered) != .orderedDescending,
                      row.backed.compare(available) != .orderedDescending else { throw ClientError.invalidResponse }
            }
            shortfall = shortfall || row.backed.compare(row.requested) == .orderedAscending
        }
        guard shortfall == issues.contains("reservationShortfall") else { throw ClientError.invalidResponse }
    }
}
