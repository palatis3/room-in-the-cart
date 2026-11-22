import Foundation

/// A timing question derived from comparable, explicitly received food. It never
/// projects a remaining quantity or creates a new shopping-list obligation.
public struct StaplePrompt: Equatable, Sendable, Identifiable {
    public enum Reason: Equatable, Sendable { case usualInterval, confirmedEmpty }
    public let reason: Reason
    public let id: UUID // reviewed food identity
    public let name: String
    public let latestAcquisitionID: UUID
    public let comparablePurchaseDays: Int
    public let intervalDays: Int
    public let dueDay: Date

    public static func due(purchases: [ReceiptAcquisition], lots: [InventoryLot],
                           openFoodIDs: Set<UUID>, openLineNames: [String],
                           on date: Date, calendar: Calendar) throws -> [Self] {
        let today = calendar.startOfDay(for: date)
        let lotsByFood = Dictionary(grouping: lots, by: \.foodID)
        let plenty = Set(lots.filter { $0.count.suppressesStaplePrompt }.map(\.foodID))
        let listed = Set(openLineNames.map(normalizedProduct))
        // A price correction and repeated delivery of the identical receipt line
        // cannot introduce another physical purchase.
        var lines: [UUID: ReceiptAcquisition] = [:]
        for fact in purchases where fact.revision == 1 && fact.usable.amount > .zero && fact.purchaseDate <= date {
            if let prior = lines.updateValue(fact, forKey: fact.lineID), prior != fact {
                throw InventoryError.invalid("conflictingStaplePurchase")
            }
        }
        let groups = Dictionary(grouping: lines.values, by: \.foodID)
        var prompts: [Self] = []
        for (foodID, facts) in groups where !plenty.contains(foodID) && !openFoodIDs.contains(foodID) {
            if facts.contains(where: { listed.contains(normalizedProduct($0.name)) }) { continue }
            let byDay = Dictionary(grouping: facts) { fact in
                // Compare local shopping days in the planning calendar; legacy facts
                // retain the previous timestamp-based estimate.
                let selected = fact.purchaseDay.flatMap { MealDay(iso8601: $0.iso8601, timeZoneIdentifier: calendar.timeZone.identifier)?.date }
                return calendar.startOfDay(for: selected ?? fact.purchaseDate)
            }
            let days = byDay.keys.sorted(by: >)
            guard days.count >= 3, let lastDay = days.first,
                  let latest = byDay[lastDay]?.min(by: { $0.id.uuidString < $1.id.uuidString }) else { continue }
            var comparable: [Date] = []
            var latestAmount: Rational?
            for day in days {
                var total = Rational.zero
                var known = true
                for fact in byDay[day] ?? [] {
                    guard let amount = try fact.usable.converted(to: latest.usable.unit) else { known = false; break }
                    total = try total.adding(amount)
                }
                // A changed pack size starts a new series; skip no intervening trip.
                guard known, latestAmount == nil || latestAmount == total else { break }
                latestAmount = total
                comparable.append(day)
            }
            guard comparable.count >= 3 else { continue }
            let gaps = zip(comparable, comparable.dropFirst()).compactMap { later, earlier in
                calendar.dateComponents([.day], from: earlier, to: later).day
            }.sorted()
            guard gaps.count == comparable.count - 1, gaps.first ?? 0 > 0 else { continue }
            let lower = gaps[(gaps.count - 1) / 2], upper = gaps[gaps.count / 2]
            let interval = lower + (upper - lower + 1) / 2
            guard let dueDay = calendar.date(byAdding: .day, value: interval, to: lastDay) else { continue }
            let physical = lotsByFood[foodID] ?? []
            let confirmedEmpty = !physical.isEmpty && physical.allSatisfy { $0.count.quantity?.amount == .zero && $0.confirmedAt <= date }
                && physical.contains { $0.confirmedAt > latest.purchaseDate }
            guard confirmedEmpty || today >= dueDay else { continue }
            prompts.append(Self(reason: confirmedEmpty ? .confirmedEmpty : .usualInterval, id: foodID, name: latest.name, latestAcquisitionID: latest.id,
                                comparablePurchaseDays: comparable.count, intervalDays: interval, dueDay: dueDay))
        }
        return prompts.sorted {
            if $0.dueDay != $1.dueDay { return $0.dueDay < $1.dueDay }
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id.uuidString < $1.id.uuidString : order == .orderedAscending
        }
    }
}
