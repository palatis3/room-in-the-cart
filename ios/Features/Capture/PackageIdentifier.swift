import Foundation
import CoreDomain

/// Original scanner evidence is retained separately from its comparable trade-item identity.
extension CapturedBarcode {
    static func checksGTIN(_ digits: String) -> Bool {
        guard [8, 12, 13, 14].contains(digits.utf8.count), digits.utf8.allSatisfy({ (48...57).contains($0) }),
              digits.contains(where: { $0 != "0" }) else { return false }
        let numbers = digits.utf8.map { Int($0 - 48) }
        let sum = numbers.dropLast().reversed().enumerated().reduce(0) { $0 + $1.element * ($1.offset.isMultiple(of: 2) ? 3 : 1) }
        return (10 - sum % 10) % 10 == numbers.last
    }

    private var kind: String { symbology.lowercased().replacingOccurrences(of: "-", with: "") }
    var packageGTIN: String? {
        if let gs1 { return gs1.gtin }
        if kind.contains("upce") {
            let bytes = Array(value.utf8)
            guard bytes.count == 8, bytes.allSatisfy({ (48...57).contains($0) }), bytes[0] <= 49 else { return nil }
            func part(_ range: Range<Int>) -> String { String(decoding: bytes[range], as: UTF8.self) }
            let body: String
            switch bytes[6] {
            case 48...50: body = part(0..<3) + part(6..<7) + "0000" + part(3..<6)
            case 51 where bytes[3] >= 51: body = part(0..<4) + "00000" + part(4..<6)
            case 52 where bytes[4] != 48: body = part(0..<5) + "00000" + part(5..<6)
            case 53...57 where bytes[5] != 48: body = part(0..<6) + "0000" + part(6..<7)
            default: return nil
            }
            let expanded = body + part(7..<8)
            return Self.checksGTIN(expanded) ? expanded : nil
        }
        let manual = ["typed", "manual", "catalog"].contains(kind)
        guard (manual || kind.contains("ean") || (kind.contains("upca") || kind == "upc") || kind.contains("gs1databar")),
              Self.checksGTIN(value) else { return nil }
        // Eight typed digits can be UPC-E or EAN-8. Require a specified symbology.
        if value.count == 8 && manual && kind != "catalog" { return nil }
        return value
    }

    var canonicalGTIN: String? { packageGTIN.map { String(repeating: "0", count: 14 - $0.count) + $0 } }

    private enum Circulation { case global, retailer, nonProduct }
    private func circulation(_ padded: String) -> Circulation {
        // A GTIN-8 may also arrive left-padded in AI 01. RCN-8 starts with 0 or 2.
        if padded.hasPrefix("000000"), let first = padded.dropFirst(6).first {
            return first == "0" || first == "2" ? .retailer : .global
        }
        let prefix = Int(padded.dropFirst().prefix(3)) ?? -1
        switch prefix {
        case 20...29, 40...49, 200...299: return .retailer
        // Coupon, special-purpose/demo, publication, refund and voucher prefixes.
        case 50...59, 951, 952, 977...999: return .nonProduct
        default: return .global
        }
    }

    var catalogGTIN: String? {
        guard let gtin = packageGTIN, let padded = canonicalGTIN, circulation(padded) == .global else { return nil }
        return gtin
    }
    var displayValue: String { value.replacingOccurrences(of: "\u{1d}", with: "␝") }

    enum LookupScope { case global, retailer, checkDigitsOrFormat, unsupported }

    var lookupScope: LookupScope {
        if let gtin = canonicalGTIN {
            switch circulation(gtin) {
            case .global: return .global
            case .nonProduct: return .unsupported
            case .retailer: return .retailer
            }
        }
        if value.allSatisfy(\.isNumber), [8, 12, 13, 14].contains(value.count) { return .checkDigitsOrFormat }
        guard (try? validate()) != nil, !value.contains("://"), !value.contains("\u{1d}"),
              !value.hasPrefix("("), !value.hasPrefix("]"), !kind.contains("qr"), !kind.contains("matrix") else { return .unsupported }
        return .retailer
    }

    func associationKey(retailer: String) -> String? {
        switch lookupScope {
        case .global: return canonicalGTIN.map { "gtin/" + $0 }
        case .retailer:
            let store = retailer.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !store.isEmpty, store.utf8.count <= 256 else { return nil }
            if let gtin = canonicalGTIN { return "store/\(store.utf8.count)/\(store)/\(gtin)" }
            return "local/\(store.utf8.count)/\(store)/\(value)"
        case .checkDigitsOrFormat, .unsupported: return nil
        }
    }

    var gs1: PackageGS1? {
        PackageGS1(value, scannerIdentifiedGS1: isGS1 == true || kind.contains("gs1"))
    }
}

/// Every known physical identifier must agree before presenting a newly read date.
enum PackageDateBinding {
    static func accepts(_ incoming: CapturedBarcode, for known: [CapturedBarcode]) -> Bool {
        guard let decoded = incoming.gs1, let gtin = incoming.canonicalGTIN else { return false }
        return known.allSatisfy { source in
            guard source.canonicalGTIN == gtin else { return false }
            if let lot = source.gs1?.lot { return lot == decoded.lot }
            return true
        }
    }
}

struct PackageGS1: Equatable, Sendable {
    struct DateField: Equatable, Codable, Sendable {
        let ai: String
        let literal: String
        func day(zone: String, now: Date = Date()) -> MealDay? {
            guard literal.count == 6, let yy = Int(literal.prefix(2)), let month = Int(literal.dropFirst(2).prefix(2)),
                  let day = Int(literal.suffix(2)), (1...12).contains(month) else { return nil }
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = TimeZone(identifier: zone) ?? .gmt
            let current = cal.component(.year, from: now)
            let lower = current - 49
            let year = lower + (yy - lower % 100 + 100) % 100
            if day == 0, let start = cal.date(from: DateComponents(year: year, month: month, day: 1)),
               let days = cal.range(of: .day, in: .month, for: start) {
                return try? MealDay(year: year, month: month, day: days.count, timeZoneIdentifier: zone)
            }
            return try? MealDay(year: year, month: month, day: day, timeZoneIdentifier: zone)
        }
    }
    let gtin: String
    let lot: String?
    let dates: [DateField]

    init?(_ raw: String, scannerIdentifiedGS1: Bool) {
        guard raw.utf8.count <= 256, !raw.contains("://") else { return nil }
        var input = raw[...]
        let human = input.hasPrefix("(")
        let aim = ["]C1", "]d2", "]Q3", "]e0"].contains(String(input.prefix(3)))
        guard human || aim || scannerIdentifiedGS1 || input.contains("\u{1d}") else { return nil }
        if aim { input = input.dropFirst(3) }
        var fields: [String: String] = [:]
        while !input.isEmpty {
            if human {
                guard input.first == "(", input.dropFirst(3).first == ")" else { return nil }
                input = input.dropFirst()
            }
            let ai = String(input.prefix(2))
            guard ["01","10","15","17"].contains(ai), fields[ai] == nil else { return nil }
            input = input.dropFirst(human ? 3 : 2)
            let field: Substring
            if ai == "10" {
                field = input.prefix { human ? $0 != "(" : $0 != "\u{1d}" }
                guard (1...20).contains(field.utf8.count), field.utf8.allSatisfy({ (33...126).contains($0) }) else { return nil }
            } else {
                let length = ai == "01" ? 14 : 6
                field = input.prefix(length)
                guard field.utf8.count == length, field.utf8.allSatisfy({ (48...57).contains($0) }) else { return nil }
            }
            fields[ai] = String(field)
            input = input.dropFirst(field.count)
            if !human, input.first == "\u{1d}" { input = input.dropFirst() }
        }
        guard let gtin = fields["01"], CapturedBarcode.checksGTIN(gtin) else { return nil }
        self.gtin = gtin
        lot = fields["10"]
        dates = ["15","17"].compactMap { key in fields[key].map { DateField(ai: key, literal: $0) } }
        guard dates.allSatisfy({ $0.day(zone: "UTC") != nil }) else { return nil }
    }
}
