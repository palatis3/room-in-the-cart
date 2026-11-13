import Foundation
import HouseholdClient

enum HistoryDraftError: Error { case invalid }
enum HistoryDate {
    static func string(_ date: Date) -> String { let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return formatter.string(from: date) }
    static func date(_ string: String) -> Date? {
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: string) { return date }; formatter.formatOptions = [.withInternetDateTime]; return formatter.date(from: string)
    }
}
enum HistoryMoney {
    static func minor(_ value: String, optional: Bool = false) throws -> Int? {
        let value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.isEmpty && optional { return nil }
        guard value.range(of: "^[0-9]+([.,][0-9]{1,2})?$", options: .regularExpression) != nil else { throw HistoryDraftError.invalid }
        let parts = value.replacingOccurrences(of: ",", with: ".").split(separator: ".", omittingEmptySubsequences: false)
        guard let whole = Int(parts[0]), whole <= 10_000_000_000 else { throw HistoryDraftError.invalid }
        let fraction = parts.count == 2 ? String(parts[1]) : ""
        let cents = whole * 100 + (Int(fraction.padding(toLength: 2, withPad: "0", startingAt: 0)) ?? 0)
        guard cents <= 1_000_000_000_000 else { throw HistoryDraftError.invalid }; return cents
    }
    static func text(_ minor: Int?) -> String {
        guard let minor else { return "" }; return "\(minor / 100)." + String(format: "%02d", minor % 100)
    }
}

struct HistoryObservationDraft: Equatable {
    var id = UUID().uuidString.lowercased()
    var shopID = ""
    var itemName = "", packLabel = "", store = "", branch = "", eligibility = "", sourceText = ""
    var sourceLocale = Locale.current.identifier
    var channel: HistoryPriceChannel = .storeShelf
    var mode: HistoryFulfillmentMode = .inStore
    var observedAt = Date()
    var priceKind = "exact", exactPrice = "", lowerPrice = "", upperPrice = "", priceReason = ""
    var hasUsablePack = false
    var packNumerator = "", packDenominator = "1", originalPackLiteral = ""
    var packUnit: HistoryUnit = .count
    func dto() throws -> HistoryPriceObservation {
        let price: HistoryCostEvidence
        switch priceKind {
        case "exact": price = .exact(minor: try HistoryMoney.minor(exactPrice)!)
        case "bounded": price = .bounded(lowerMinor: try HistoryMoney.minor(lowerPrice)!, upperMinor: try HistoryMoney.minor(upperPrice)!, reason: priceReason)
        case "unknown": price = .unknown(reason: priceReason)
        default: throw HistoryDraftError.invalid
        }
        var pack: HistoryUsablePack?
        if hasUsablePack {
            guard let numerator = Int(packNumerator), let denominator = Int(packDenominator) else { throw HistoryDraftError.invalid }
            pack = try .init(amount: .init(numerator: numerator, denominator: denominator), unit: packUnit, originalLiteral: originalPackLiteral)
        }
        return try .init(id: id, shopId: shopID, itemName: itemName, packLabel: packLabel, usablePack: pack, price: price,
                         store: store, branch: branch, channel: channel, mode: mode, eligibility: eligibility,
                         observedAt: HistoryDate.string(observedAt), sourceText: sourceText, sourceLocale: sourceLocale)
    }
}
struct HistoryReservationDraft: Equatable, Identifiable {
    var id = UUID().uuidString.lowercased()
    var originalText = "", amount = ""
    var plannedAt = Date()
    var state = "reserved", shopID = ""
    var isFinal = false
    init() {}
    init(_ value: HistoryFutureReservation) {
        id = value.id; originalText = value.originalText; amount = HistoryMoney.text(value.amountMinor)
        plannedAt = HistoryDate.date(value.plannedAt) ?? .distantPast
        switch value.state { case .reserved: state = "reserved"; case .released: state = "released"; case .applied(let id): state = "applied"; shopID = id }
        isFinal = state != "reserved"
    }
    func dto() throws -> HistoryFutureReservation {
        let disposition: HistoryReservationState
        switch state { case "reserved": disposition = .reserved; case "released": disposition = .released
        case "applied": disposition = .applied(shopID: shopID); default: throw HistoryDraftError.invalid }
        return try .init(id: id, originalText: originalText, amountMinor: HistoryMoney.minor(amount)!, plannedAt: HistoryDate.string(plannedAt), state: disposition)
    }
}
struct HistoryPeriodDraft: Equatable {
    var id = UUID().uuidString.lowercased()
    var baseRevision = 0
    var title = "", timeZoneID: String
    var startsAt: Date, endsAt: Date
    var budget = "", excludedReserve = ""
    var shopIDs: [String] = []
    var reservations: [HistoryReservationDraft] = []
    var reviewedComplete = false
    var reviewedCompleteAt = Date()
    private var terminalReservations: [HistoryFutureReservation] = []
    init(start: Date = Date(), calendar: Calendar = .current) {
        timeZoneID = calendar.timeZone.identifier
        startsAt = start
        endsAt = calendar.date(byAdding: .day, value: 14, to: start) ?? start
    }
    init(_ value: HistorySavedBudgetPeriod) {
        let period = value.period
        id = period.id; baseRevision = value.revision; title = period.title; timeZoneID = period.timeZoneId
        startsAt = HistoryDate.date(period.startsAt) ?? .distantPast; endsAt = HistoryDate.date(period.endsAt) ?? .distantPast
        budget = HistoryMoney.text(period.shopBudgetMinor); excludedReserve = HistoryMoney.text(period.alreadyExcludedReserveMinor)
        shopIDs = period.shopIds; reservations = period.reservations.map(HistoryReservationDraft.init)
        terminalReservations = period.reservations.filter { $0.state != .reserved }
        reviewedComplete = period.reviewedCompleteAt != nil
        reviewedCompleteAt = period.reviewedCompleteAt.flatMap(HistoryDate.date) ?? Date()
    }
    func dto() throws -> HistoryBudgetPeriod {
        let values = try reservations.map { draft -> HistoryFutureReservation in
            if let original = terminalReservations.first(where: { $0.id == draft.id }) {
                guard draft == HistoryReservationDraft(original) else { throw HistoryDraftError.invalid }
                return original
            }
            return try draft.dto()
        }
        guard terminalReservations.allSatisfy({ original in values.contains(original) }) else { throw HistoryDraftError.invalid }
        return try .init(id: id, title: title, startsAt: HistoryDate.string(startsAt), endsAt: HistoryDate.string(endsAt), timeZoneId: timeZoneID,
                         shopBudgetMinor: HistoryMoney.minor(budget)!, alreadyExcludedReserveMinor: HistoryMoney.minor(excludedReserve, optional: true),
                         shopIds: shopIDs, reservations: values, reviewedCompleteAt: reviewedComplete ? HistoryDate.string(reviewedCompleteAt) : nil)
    }
}
struct HistoryPriceFilter: Equatable {
    var store = "", branch = "", channel = "", mode = ""
    var from: Date?, through: Date?
    func matches(_ value: HistoryPriceObservation) -> Bool {
        guard store.isEmpty || value.store.localizedCaseInsensitiveContains(store),
              branch.isEmpty || value.branch.localizedCaseInsensitiveContains(branch),
              channel.isEmpty || value.channel.rawValue == channel,
              mode.isEmpty || value.mode.rawValue == mode,
              let date = HistoryDate.date(value.observedAt) else { return false }
        return (from == nil || date >= from!) && (through == nil || date <= through!)
    }
}
