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
    public let paidUSDMinor: Int?
    public let location: HouseholdPantryLocation
    public let delivery: Delivery?
    public let printed: Printed?

    public init(ordinal: Int, original: String, foodName: String, received: SharedMealQuantity, usable: SharedMealQuantity,
                paidUSDMinor: Int?, location: HouseholdPantryLocation, delivery: Delivery? = nil, printed: Printed? = nil) {
        self.ordinal = ordinal; self.original = original; self.foodName = foodName
        self.received = received; self.usable = usable; self.paidUSDMinor = paidUSDMinor
        self.location = location; self.delivery = delivery; self.printed = printed
    }
    func validate() throws {
        guard householdReceiptText(original, 2048), householdReceiptText(foodName, 240),
              received.validStockQuantity, usable.validStockQuantity, received.unit == usable.unit,
              received.amount.numerator > 0,
              Int64(usable.amount.numerator) * Int64(received.amount.denominator) <= Int64(received.amount.numerator) * Int64(usable.amount.denominator),
              paidUSDMinor.map({ (0...Int(Int32.max)).contains($0) }) != false else { throw ClientError.configuration }
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
    public let merchant: String
    public let purchaseDay: String
    public let zone: String
    public let reference: String?
    public let lines: [HouseholdReceiptLine]

    public init(receiptId: UUID, imageId: UUID?, merchant: String, purchaseDay: String, zone: String,
                reference: String?, lines: [HouseholdReceiptLine], layoutId: UUID? = nil) {
        self.receiptId = receiptId; self.imageId = imageId; self.merchant = merchant; self.purchaseDay = purchaseDay
        self.zone = zone; self.reference = reference; self.lines = lines; self.layoutId = layoutId
    }
    public func validate() throws {
        guard householdReceiptText(merchant, 256), householdReceiptDay(purchaseDay), TimeZone(identifier: zone) != nil,
              reference.map({ householdReceiptText($0, 256) }) != false, (1...50).contains(lines.count),
              Set(lines.map(\.ordinal)).count == lines.count else { throw ClientError.configuration }
        let links = lines.compactMap { $0.delivery?.lotId }
        guard Set(links).count == links.count else { throw ClientError.configuration }
        for line in lines { try line.validate() }
    }
}

public struct HouseholdReceiptEvidence: Decodable, Equatable, Sendable {
    public let merchant: String
    public let purchaseDay: String
    public let reference: String?
    public let line: HouseholdReceiptLine
}
