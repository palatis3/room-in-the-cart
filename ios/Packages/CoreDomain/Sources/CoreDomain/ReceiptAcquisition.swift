import CryptoKit
import Foundation

/// A shopper's confirmation of one physical line. The printed line and reviewed
/// product are distinct. A nil paid total means the price was not established.
public struct ReceiptAcquisition: Codable, Equatable, Sendable, Identifiable {
    public enum Stock: Codable, Equatable, Sendable {
        case added(location: InventoryLocation)
        case linked(fragment: ReceiptKey)
    }

    public struct SavedPickup: Codable, Equatable, Sendable {
        public let originID: UUID
        public let id: UUID
        public init(originID: UUID, id: UUID) { self.originID = originID; self.id = id }
    }
    public struct DocumentLine: Codable, Equatable, Sendable {
        public enum Method: String, Codable, Sendable { case textFile, pdfText, pdfOCR, imageOCR }
        public enum Stage: String, Codable, CaseIterable, Sendable { case receipt, order, finalInvoice }
        public let method: Method
        public let stage: Stage
        public let page: Int
        public let line: Int

        public init(method: Method, stage: Stage, page: Int, line: Int) {
            self.method = method; self.stage = stage; self.page = page; self.line = line
        }
        public var ordinal: Int { (page - 1) * 200 + line - 1 }
        func validate(ordinal: Int, digest: Data?) throws {
            guard (1...20).contains(page), (1...200).contains(line), digest?.count == 32,
                  method == .pdfText || method == .pdfOCR || page == 1,
                  self.ordinal == ordinal else { throw InventoryError.invalid("receiptPage") }
        }
    }
    public let documentLine: DocumentLine?
    public let savedPickup: SavedPickup?
    public let id: UUID
    public let receiptID: UUID
    public let lineID: UUID
    public let lotID: UUID
    public let foodID: UUID
    public let revision: Int64
    public let supersedesID: UUID?
    public let merchant: String
    public let purchaseDate: Date
    public let transactionReference: String?
    public let imageDigest: Data?
    public let ordinal: Int
    public let originalLine: String
    public let name: String
    public let received: Quantity
    public let usable: Quantity
    public let paidLineTotal: Money?
    public let stock: Stock

    public init(receiptID: UUID, ordinal: Int, lotID: UUID, foodID: UUID, merchant: String, purchaseDate: Date,
                transactionReference: String?, imageDigest: Data?, originalLine: String, name: String,
                received: Quantity, usable: Quantity, paidLineTotal: Money?, stock: Stock,
                revision: Int64 = 1, supersedesID: UUID? = nil, savedPickup: SavedPickup? = nil, documentLine: DocumentLine? = nil) {
        self.documentLine = documentLine
        self.savedPickup = savedPickup
        self.receiptID = receiptID
        self.ordinal = ordinal
        lineID = Self.lineID(receiptID: receiptID, ordinal: ordinal)
        id = Self.identity(["observation", lineID.uuidString, String(revision)])
        self.lotID = lotID
        self.foodID = foodID
        self.merchant = merchant
        self.purchaseDate = purchaseDate
        self.transactionReference = transactionReference
        self.imageDigest = imageDigest
        self.originalLine = originalLine
        self.name = name
        self.received = received
        self.usable = usable
        self.paidLineTotal = paidLineTotal
        self.stock = stock
        self.revision = revision
        self.supersedesID = supersedesID
    }

    /// Merchant transaction references must be explicitly confirmed. Filename,
    /// wording, date and total are never identities for a physical purchase.
    public static func receiptID(merchant: String, transactionReference: String?, imageDigest: Data?, draftID: UUID) -> UUID {
        if let transactionReference {
            return identity(["transaction", merchant.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
                             transactionReference.trimmingCharacters(in: .whitespacesAndNewlines)])
        }
        if let imageDigest { return identity(["image", imageDigest.base64EncodedString()]) }
        return draftID
    }

    public static func lineID(receiptID: UUID, ordinal: Int) -> UUID {
        identity(["line", receiptID.uuidString, String(ordinal)])
    }

    public static func identity(_ fields: [String]) -> UUID {
        var bytes = Data("room-in-the-cart/receipt-acquisition/v1".utf8)
        for field in fields {
            var size = UInt64(field.utf8.count).bigEndian
            withUnsafeBytes(of: &size) { bytes.append(contentsOf: $0) }
            bytes.append(contentsOf: field.utf8)
        }
        var digest = Array(SHA256.hash(data: bytes).prefix(16))
        digest[6] = (digest[6] & 0x0f) | 0x80
        digest[8] = (digest[8] & 0x3f) | 0x80
        return UUID(uuid: (digest[0], digest[1], digest[2], digest[3], digest[4], digest[5], digest[6], digest[7],
                           digest[8], digest[9], digest[10], digest[11], digest[12], digest[13], digest[14], digest[15]))
    }

    public func correctingPaidTotal(_ total: Money?) throws -> Self {
        guard revision < Int64.max, total != paidLineTotal else { throw InventoryError.invalid("receiptCorrection") }
        let corrected = Self(receiptID: receiptID, ordinal: ordinal, lotID: lotID, foodID: foodID, merchant: merchant,
            purchaseDate: purchaseDate, transactionReference: transactionReference, imageDigest: imageDigest, originalLine: originalLine,
            name: name, received: received, usable: usable, paidLineTotal: total, stock: stock,
            revision: revision + 1, supersedesID: id, savedPickup: savedPickup, documentLine: documentLine)
        try corrected.validate()
        return corrected
    }

    public func validate() throws {
        for (text, limit) in [(merchant, 256), (originalLine, 2_048), (name, 512)] {
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty, text.utf8.count <= limit,
                  !text.contains("\0") else { throw InventoryError.invalid("receiptText") }
        }
        if let documentLine { try documentLine.validate(ordinal: ordinal, digest: imageDigest) }
        else if !(0..<200).contains(ordinal) { throw InventoryError.invalid("receiptLine") }
        guard revision >= 1,
              lineID == Self.lineID(receiptID: receiptID, ordinal: ordinal),
              id == Self.identity(["observation", lineID.uuidString, String(revision)]),
              supersedesID == (revision == 1 ? nil : Self.identity(["observation", lineID.uuidString, String(revision - 1)])),
              imageDigest.map({ $0.count == 32 }) ?? true,
              transactionReference.map({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && $0.utf8.count <= 256 && !$0.contains("\0") }) ?? true,
              purchaseDate.timeIntervalSinceReferenceDate.isFinite,
              paidLineTotal.map({ $0 >= .zero }) ?? true else { throw InventoryError.invalid("receiptLine") }
        try received.validate(); try usable.validate()
        guard received.amount > .zero, received.unit == usable.unit, usable.amount >= .zero, usable.amount <= received.amount else {
            throw InventoryError.invalid("receiptAmounts")
        }
        if case .linked(let key) = stock { try InventorySource.receipt(originID: lotID, key: key).validate() }
    }
}
