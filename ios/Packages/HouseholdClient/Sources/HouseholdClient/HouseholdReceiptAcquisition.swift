import Foundation

func householdReceiptDay(_ value: String) -> Bool {
    let format = DateFormatter()
    format.locale = Locale(identifier: "en_US_POSIX")
    format.timeZone = TimeZone(secondsFromGMT: 0)
    format.dateFormat = "yyyy-MM-dd"
    format.isLenient = false
    guard value.utf8.count == 10, let date = format.date(from: value) else { return false }
    return format.string(from: date) == value
}

func householdReceiptText(_ text: String, _ limit: Int) -> Bool {
    sharedMealText(text, limit) && text.utf8.count <= limit && !text.utf8.contains(0)
}

public struct HouseholdReceiptLine: Codable, Equatable, Sendable {
    public struct Delivery: Codable, Equatable, Sendable {
        public let lotId: UUID
        public let observationId: UUID
        public init(lotId: UUID, observationId: UUID) { self.lotId = lotId; self.observationId = observationId }
    }
    public struct Printed: Codable, Equatable, Sendable {
        public let page: Int, line: Int
        public let method: String, stage: String
        public init(page: Int, line: Int, method: String, stage: String) {
            self.page = page; self.line = line; self.method = method; self.stage = stage
        }
    }
    public let ordinal: Int
    public let original: String
    public let foodName: String
    public let received: SharedMealQuantity
    public let usable: SharedMealQuantity
    private let enteredPaidMinor: Int?
    private let paidUSDMinor: Int?
    public var paidMinor: Int? { enteredPaidMinor ?? paidUSDMinor }
    private enum CodingKeys: String, CodingKey {
        case ordinal, original, foodName, received, usable, enteredPaidMinor = "paidMinor", paidUSDMinor, location, delivery, printed
    }
    public let location: HouseholdPantryLocation
    public let delivery: Delivery?
    public let printed: Printed?

    public init(ordinal: Int, original: String, foodName: String, received: SharedMealQuantity, usable: SharedMealQuantity,
                paidMinor: Int?, location: HouseholdPantryLocation, delivery: Delivery? = nil, printed: Printed? = nil) {
        self.init(ordinal: ordinal, original: original, foodName: foodName, received: received, usable: usable,
                  paidMinor: paidMinor, legacyPaidUSDMinor: nil, location: location, delivery: delivery, printed: printed)
    }

    public init(ordinal: Int, original: String, foodName: String, received: SharedMealQuantity, usable: SharedMealQuantity,
                paidUSDMinor: Int?, location: HouseholdPantryLocation, delivery: Delivery? = nil, printed: Printed? = nil) {
        self.init(ordinal: ordinal, original: original, foodName: foodName, received: received, usable: usable,
                  paidMinor: nil, legacyPaidUSDMinor: paidUSDMinor, location: location, delivery: delivery, printed: printed)
    }

    private init(ordinal: Int, original: String, foodName: String, received: SharedMealQuantity, usable: SharedMealQuantity,
                 paidMinor: Int?, legacyPaidUSDMinor: Int?, location: HouseholdPantryLocation, delivery: Delivery?, printed: Printed?) {
        self.ordinal = ordinal; self.original = original; self.foodName = foodName
        self.received = received; self.usable = usable; enteredPaidMinor = paidMinor; paidUSDMinor = legacyPaidUSDMinor
        self.location = location; self.delivery = delivery; self.printed = printed
    }
    func validate(explicitCurrency: Bool) throws {
        guard (explicitCurrency ? paidUSDMinor == nil : enteredPaidMinor == nil), householdReceiptText(original, 2048), householdReceiptText(foodName, 240),
              received.validStockQuantity, usable.validStockQuantity, received.unit == usable.unit,
              received.amount.numerator > 0,
              Int64(usable.amount.numerator) * Int64(received.amount.denominator) <= Int64(received.amount.numerator) * Int64(usable.amount.denominator),
              paidMinor.map({ (0...Int(Int32.max)).contains($0) }) != false else { throw ClientError.configuration }
        if let printed {
            guard (1...20).contains(printed.page), (1...200).contains(printed.line),
                  ordinal == (printed.page - 1) * 200 + printed.line - 1,
                  ["textFile", "pdfText", "pdfOCR", "imageOCR"].contains(printed.method),
                  ["order", "receipt", "finalInvoice"].contains(printed.stage) else { throw ClientError.configuration }
        } else if !(0..<200).contains(ordinal) { throw ClientError.configuration }
    }
}

public struct HouseholdReceiptAcquisition: Codable, Equatable, Sendable {
    public let receiptId: UUID
    public let imageId: UUID?
    public let layoutId: UUID?
    public let segmentedPhotos: Bool?
    public let merchant: String
    public let purchaseDay: String
    public let zone: String
    public let reference: String?
    public let lines: [HouseholdReceiptLine]
    private let currencyCode: String?
    public var currency: String { currencyCode ?? "USD" }

    private enum CodingKeys: String, CodingKey {
        case receiptId, imageId, layoutId, segmentedPhotos, merchant, purchaseDay, zone, reference, lines, currencyCode = "currency"
    }

    public init(receiptId: UUID, imageId: UUID?, merchant: String, purchaseDay: String, zone: String,
                reference: String?, lines: [HouseholdReceiptLine], layoutId: UUID? = nil, segmentedPhotos: Bool? = nil, currency: String? = nil) {
        self.receiptId = receiptId; self.imageId = imageId; self.merchant = merchant; self.purchaseDay = purchaseDay
        self.zone = zone; self.reference = reference; self.lines = lines; self.layoutId = layoutId; self.segmentedPhotos = segmentedPhotos; currencyCode = currency
    }
    public func validate() throws {
        guard GroceryWireCurrency.supports(currency), householdReceiptText(merchant, 256), householdReceiptDay(purchaseDay), TimeZone(identifier: zone) != nil,
              reference.map({ householdReceiptText($0, 256) }) != false, (1...50).contains(lines.count),
              Set(lines.map(\.ordinal)).count == lines.count else { throw ClientError.configuration }
        let laterImagePage = lines.contains { $0.printed?.method == "imageOCR" && ($0.printed?.page ?? 0) > 1 }
        guard !laterImagePage || segmentedPhotos == true else { throw ClientError.configuration }
        if let segmentedPhotos {
            guard segmentedPhotos, reference != nil, imageId != nil, layoutId != nil, receiptId != imageId,
                  lines.allSatisfy({ $0.printed?.method == "imageOCR" }) else { throw ClientError.configuration }
        }
        let links = lines.compactMap { $0.delivery?.lotId }
        guard Set(links).count == links.count else { throw ClientError.configuration }
        for line in lines { try line.validate(explicitCurrency: currencyCode != nil) }
    }
}

public struct HouseholdReceiptEvidence: Decodable, Equatable, Sendable {
    public let merchant: String
    public let purchaseDay: String
    public let reference: String?
    public let line: HouseholdReceiptLine
    private let currencyCode: GroceryWireCurrency?
    public var currency: String { (currencyCode ?? .usd).rawValue }

    private enum CodingKeys: String, CodingKey { case merchant, purchaseDay, reference, line, currencyCode = "currency" }
    func validate() throws { try line.validate(explicitCurrency: currencyCode != nil) }
}
