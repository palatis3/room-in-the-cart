import CoreDomain
import Foundation
import LocalStore

extension PrivateDeliveryRevision.Disposition {
    var storage: InventoryLocation? {
        switch self {
        case .leftovers, .fridge: return .fridge
        case .freezer: return .freezer
        case .cupboard: return .cupboard
        default: return nil
        }
    }
    var title: String {
        switch self {
        case .unresolved: return pantryText("Unresolved item")
        case .dining: return pantryText("Dining out")
        case .readyToEat: return pantryText("Ready to eat")
        case .leftovers: return pantryText("Save leftovers")
        case .fridge: return pantryText("Put away in fridge")
        case .freezer: return pantryText("Put away in freezer")
        case .cupboard: return pantryText("Put away in cupboard")
        case .tax: return pantryText("Sales tax")
        case .tip: return pantryText("Delivery tip")
        case .fee: return pantryText("Delivery or service fee")
        case .discount: return pantryText("Discount")
        case .refund: return pantryText("Refund")
        }
    }
    var financial: Bool { [.tax, .tip, .fee, .discount, .refund].contains(self) }
}

extension PrivateDeliveryRevision.Kind {
    var title: String {
        switch self {
        case .finalReceipt: return pantryText("Final delivery receipt")
        case .adjustment: return pantryText("Corrected receipt")
        case .refund: return pantryText("Refund")
        }
    }
}

struct DeliveryPDFReview {
    enum MerchantType: CaseIterable { case unknown, restaurant, grocery
        var title: String {
            switch self {
            case .unknown: return pantryText("Unknown")
            case .restaurant: return pantryText("Restaurant")
            case .grocery: return pantryText("Grocery store")
            }
        }
    }

    struct Row: Identifiable {
        var id: Int { evidence.id }
        var evidence: PrivateDeliveryRevision.Line
        var included: Bool
        var amount: String
    }
    let digest: Data
    let layoutID: UUID
    var order = ""
    var merchant = ""
    var merchantType = MerchantType.unknown
    var total = ""
    var kind: PrivateDeliveryRevision.Kind = .finalReceipt
    var rows: [Row] = []
    var purchaseDate: Date?
    var deliveryDate: Date?
    var incomplete = false
    var possibleConfirmation = false

    init(document: ExtractedReceiptDocument, origin: UUID) {
        digest = document.digest
        var coordinates = ["receipt-file-layout-v1", origin.uuidString]
        var candidates: Set<String> = []
        var totals: Set<Int> = []
        let allText = document.pages.flatMap(\.lines).map(\.text).joined(separator: "\n")
        let chipotle = allText.range(of: #"(?im)^\s*chipotle(?: mexican grill)?\s*$"#, options: .regularExpression) != nil
        if chipotle { merchant = "Chipotle"; merchantType = .restaurant }
        possibleConfirmation = allText.range(of: #"(?i)order confirmation|estimated total|confirmación de pedido|total estimado"#, options: .regularExpression) != nil
        for page in document.pages {
            coordinates += [String(page.id), page.method.rawValue, String(page.lines.count)]
            if page.skipped != nil || page.lines.isEmpty { incomplete = true }
            for line in page.lines {
                let text = line.text
                coordinates += [String(line.id), text]
                if let ref = text.firstMatch(of: #/(?i)^\s*(?:order|pedido|orden)\s*(?:number|número|referencia|reference|no\.|id|#|:)\s*[:#]?\s*([a-z0-9_-]{1,100})\s*$/#) {
                    if !line.uncertain { candidates.insert(String(ref.1)) }
                    continue
                }
                let endAmount = Self.usdSuffix(text)
                if text.contains(#/(?i)^\s*(?:grand total|order total|total paid|total pagado|total del pedido|total)\s*(?::|US[D$]|[$\d])/#) {
                    if let endAmount, !line.uncertain { totals.insert(endAmount) }
                    continue
                }
                guard text.utf8.count <= 2048, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    incomplete = true
                    continue
                }
                let suggested = Self.suggest(text, restaurant: chipotle)
                let metadata = text.contains(#/(?i)^\s*(?:sub\s*total|paid with|pagado con|pago|visa|mastercard|card|tarjeta|cash|efectivo|balance|amount paid|you paid|total|uber eats|chipotle|order|pedido|direcci[oó]n|address)\b/#)
                let include = !metadata && (suggested != .unresolved || (endAmount != nil && text.contains(where: \.isLetter)))
                let evidence = PrivateDeliveryRevision.Line(page: page.id, line: line.id, scanned: page.method == .pdfOCR,
                    uncertain: line.uncertain, wording: text, disposition: line.uncertain && !suggested.financial ? .unresolved : suggested,
                    cents: endAmount)
                rows.append(.init(evidence: evidence, included: include, amount: endAmount.map(Self.moneyText) ?? ""))
            }
        }
        layoutID = ReceiptAcquisition.identity(coordinates)
        if candidates.count == 1 { order = candidates.first ?? "" }
        if totals.count == 1, let cents = totals.first { total = Self.moneyText(cents) }
    }

    mutating func changeMerchantType(_ type: MerchantType) {
        for index in rows.indices where rows[index].included && !rows[index].evidence.uncertain {
            let row = rows[index].evidence
            if row.disposition == Self.suggest(row.wording, restaurant: merchantType == .restaurant) {
                rows[index].evidence.disposition = Self.suggest(row.wording, restaurant: type == .restaurant)
            }
        }
        merchantType = type
    }

    static func moneyText(_ cents: Int) -> String {
        String(format: "%@%d.%02d", cents < 0 ? "-" : "", abs(cents) / 100, abs(cents) % 100)
    }

    static func cents(_ text: String) -> Int? {
        let amount = text.trimmingCharacters(in: .whitespaces)
        guard let match = amount.wholeMatch(of: #/(-?)([0-9]{1,6})(?:[.,]([0-9]{1,2}))?/#),
              let whole = Int(match.2) else { return nil }
        let fraction = match.3.map(String.init) ?? ""
        let pennies = Int(fraction.count == 1 ? fraction + "0" : fraction) ?? 0
        return (whole * 100 + pennies) * (match.1.isEmpty ? 1 : -1)
    }

    static func usdSuffix(_ text: String) -> Int? {
        guard !text.contains(#/(?i)\b(CAD|MXN|EUR|GBP|AUD)\b|[€£]/#),
              let price = text.firstMatch(of: #/(?:^|\s)([-−]?)\s*(?:USD\s*\$?|US\$|\$)\s*(-?[0-9]{1,6}[.,][0-9]{2})(?:\s*USD)?\s*$/#),
              let amount = cents(String(price.2)) else { return nil }
        return price.1.isEmpty ? amount : -abs(amount)
    }

    static func suggest(_ text: String, restaurant: Bool) -> PrivateDeliveryRevision.Disposition {
        if text.contains(#/(?i)^\s*(?:tax|sales tax|impuestos?|iva)\b/#) { return .tax }
        if text.contains(#/(?i)^\s*(?:tip|propina)\b/#) { return .tip }
        if text.contains(#/(?i)^\s*(?:service fee|delivery fee|fees?|cargo por|tarifa)\b/#) { return .fee }
        if text.contains(#/(?i)^\s*(?:discount|promotion|coupon|descuento|promoci[oó]n|cup[oó]n)\b/#) { return .discount }
        if text.contains(#/(?i)^\s*(?:refund|reembolso)\b/#) { return .refund }
        if text.contains(#/(?i)\b(?:not frozen|previously frozen|thawed|descongelad[ao]s?|no congelar)\b/#) { return .unresolved }
        if text.contains(#/(?i)\b(?:frozen|congelad[oa]s?)\b/#) { return .freezer }
        if text.contains(#/(?i)\b(?:hot hamburger|hot burger|hamburguesa caliente|ready to eat|list[oa] para comer)\b/#) { return .readyToEat }
        if restaurant, text.contains(#/(?i)\b(?:burrito|bowl|tacos?|quesadilla|taz[oó]n)\b/#) { return .dining }
        if text.contains(#/(?i)^\s*(?:\d+\s*(?:[x×]\s*)?)?(?:milk|eggs?|leche|huevos?)(?:\s*(?:[$(]|\d|$))/#)
            || text.contains(#/(?i)\b(?:keep refrigerated|mantener refrigerad[oa])\b/#) { return .fridge }
        return .unresolved
    }

    func record(at now: Date) -> PrivateDeliveryRevision {
        .init(digest: digest, layoutID: layoutID, order: order.trimmingCharacters(in: .whitespacesAndNewlines),
              merchant: merchant.trimmingCharacters(in: .whitespacesAndNewlines), kind: kind,
              purchaseDate: purchaseDate, deliveryDate: deliveryDate, importedAt: now,
              finalCents: Self.cents(total), lines: rows.filter(\.included).map { row in
                  var evidence = row.evidence
                  evidence.cents = Self.cents(row.amount)
                  return evidence
              })
    }
}

extension PrivateDeliveryRevision {
    func putaway(target: CaptureTarget, selected: Set<Int>) throws -> SourceMediaRecord {
        let documentID = ReceiptAcquisition.identity(["document", digest.base64EncodedString()])
        let eligible = lines.filter { selected.contains($0.id) && !$0.disposition.financial && $0.disposition != .unresolved }
        guard kind == .finalReceipt, !eligible.isEmpty, eligible.count == selected.count else { throw ReceiptDocumentFailure.selection }
        let rows = eligible.map { line in
            let place = ReceiptAcquisition.DocumentLine(method: line.scanned ? .pdfOCR : .pdfText, stage: .finalInvoice, page: line.page, line: line.line)
            var row = ScanReceiptLine(id: ReceiptAcquisition.lineID(receiptID: documentID, ordinal: place.ordinal), originalText: line.wording)
            row.uncertainOCR = line.uncertain
            row.documentLine = place
            return row
        }
        var source = SourceMediaRecord(id: documentID, target: target, originalText: rows.map(\.originalText).joined(separator: "\n"),
            reviewedLabel: merchant, imageJPEG: nil, barcode: nil, receiptLines: rows, capturedAt: importedAt)
        source.documentLayoutID = layoutID
        source.documentDigest = digest
        try source.validate()
        return source
    }
}
