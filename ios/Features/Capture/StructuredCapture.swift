import Foundation
import CoreDomain

enum StructuredCaptureFailure: Error, Equatable { case invalidAmount, invalidPackCount, reviewRequired, destinationMismatch, guestReviewRequired }
enum CaptureInterpretationWarning: String, Equatable, Sendable { case quantityUnknown, packUnknown, negation, destination, ambiguous }

struct CaptureLineDraft: Identifiable, Equatable, Sendable {
    let id: UUID
    let proposedLineID: UUID
    let originalText: String
    let originalName: String
    var name: String { didSet { confirmed = false } }
    var amount = "" { didSet { confirmed = false } }
    var unit = UnitOfMeasure.count { didSet { confirmed = false } }
    var packCount = "" { didSet { confirmed = false } }
    var amountPerPack = "" { didSet { confirmed = false } }
    var packUnit = UnitOfMeasure.count { didSet { confirmed = false } }
    var purpose = "" { didSet { confirmed = false } }
    var destination = "" { didSet { confirmed = false } }
    var exclusions = "" { didSet { confirmed = false } }
    var warnings: [CaptureInterpretationWarning] = [] { didSet { confirmed = false } }
    var confirmed = false
    var skip = false { didSet { confirmed = false } }

    func reviewed(expectedDestination: String) throws -> CaptureImportLine? {
        if skip { return nil }
        guard confirmed, !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw StructuredCaptureFailure.reviewRequired }
        guard CaptureCorrectionStore.key(destination) == CaptureCorrectionStore.key(expectedDestination) else { throw StructuredCaptureFailure.destinationMismatch }
        let quantity = try Self.quantity(amount, unit: unit)
        let perPack = try Self.quantity(amountPerPack, unit: packUnit)
        let count: Int?
        if packCount.trimmingCharacters(in: .whitespaces).isEmpty { count = nil }
        else {
            guard let value = Int(packCount), (1...1_000_000).contains(value) else { throw StructuredCaptureFailure.invalidPackCount }
            count = value
        }
        var unresolved: [CaptureImportField] = []
        if quantity == nil && (count == nil || perPack == nil) { unresolved.append(.quantity) }
        if count != nil && perPack == nil { unresolved.append(.amountPerPack) }
        if count == nil && perPack != nil { unresolved.append(.packCount) }
        if purpose.trimmingCharacters(in: .whitespaces).isEmpty { unresolved.append(.purpose) }
        let reviewed = CaptureImportLine(id: id, proposedLineID: proposedLineID, originalText: originalText, name: name,
            quantity: quantity, packCount: count, amountPerPack: perPack, purpose: purpose, destination: destination,
            exclusions: exclusions.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty },
            unresolvedFields: unresolved)
        try reviewed.validate()
        _ = try CaptureImportMetadata(declaredQuantity: quantity, packCount: count, amountPerPack: perPack,
            purpose: purpose, destination: destination, unresolvedFields: unresolved).resolvedQuantity()
        return reviewed
    }
    static func quantity(_ text: String, unit: UnitOfMeasure) throws -> Quantity? {
        let literal = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !literal.isEmpty else { return nil }
        let value = try CaptureNumber.parse(literal)
        guard value > .zero else { throw StructuredCaptureFailure.invalidAmount }
        return Quantity(amount: value, unit: unit, originalLiteral: literal)
    }
}

enum CaptureNumber {
    static func parse(_ text: String) throws -> Rational {
        let value = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if let number = words[value] { return try Rational(number) }
        if ["half", "medio", "media", "½"].contains(value) { return try Rational(1, 2) }
        let parts = value.split(separator: "/", omittingEmptySubsequences: false)
        if parts.count == 2, let top = Int64(parts[0]), let bottom = Int64(parts[1]), bottom > 0 { return try Rational(top, bottom) }
        guard !value.contains(",") else { throw StructuredCaptureFailure.invalidAmount }
        do { return try Rational(decimal: value) } catch { throw StructuredCaptureFailure.invalidAmount }
    }
    static let words: [String: Int64] = ["one":1,"two":2,"three":3,"four":4,"five":5,"six":6,"seven":7,"eight":8,"nine":9,"ten":10,"eleven":11,"twelve":12,"thirteen":13,"fourteen":14,"fifteen":15,"sixteen":16,"seventeen":17,"eighteen":18,"nineteen":19,"twenty":20,"a":1,"an":1,"un":1,"una":1,"uno":1,"dos":2,"tres":3,"cuatro":4,"cinco":5,"seis":6,"siete":7,"ocho":8,"nueve":9,"diez":10,"once":11,"doce":12,"trece":13,"catorce":14,"quince":15,"dieciséis":16,"dieciseis":16,"diecisiete":17,"dieciocho":18,"diecinueve":19,"veinte":20]
}

enum StructuredCaptureParser {
    static func isGuestProposal(_ text: String) -> Bool {
        let words = Set(text.lowercased().split { !$0.isLetter }.map(String.init))
        return !words.isDisjoint(with: ["guest", "guests", "invitado", "invitada", "invitados", "invitadas", "comensal", "comensales"])
    }
    static func lines(_ text: String, destination: String, explicitlyTreatAsItems: Bool = false) throws -> [CaptureLineDraft] {
        try CaptureLimits.validate(text)
        guard explicitlyTreatAsItems || !isGuestProposal(text) else { throw StructuredCaptureFailure.guestReviewRequired }
        return text.components(separatedBy: .newlines).filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.map { parse($0, destination: destination) }
    }
    private static func parse(_ original: String, destination: String) -> CaptureLineDraft {
        var body = original.trimmingCharacters(in: .whitespacesAndNewlines)
        var purpose = "", requestedDestination = "", exclusions = ""
        // Split bounded suffix labels in their actual order, preserving every source word.
        let expression = try! NSRegularExpression(pattern: #"\s+(for|para|to|destination:?|destino:?|without|except|sin|excepto)\s+"#, options: .caseInsensitive)
        let matches = expression.matches(in: body, range: NSRange(body.startIndex..., in: body))
        let source = body
        if let first = matches.first, let range = Range(first.range, in: source) { body = String(source[..<range.lowerBound]) }
        for (index, match) in matches.enumerated() {
            guard let range = Range(match.range, in: source), let keyRange = Range(match.range(at: 1), in: source) else { continue }
            let end = index + 1 < matches.count ? Range(matches[index + 1].range, in: source)!.lowerBound : source.endIndex
            let value = String(source[range.upperBound..<end]).trimmingCharacters(in: .whitespaces)
            let key = source[keyRange].lowercased()
            if ["for", "para"].contains(key) { purpose += (purpose.isEmpty ? "" : "; ") + value }
            else if ["without", "except", "sin", "excepto"].contains(key) { exclusions += (exclusions.isEmpty ? "" : "\n") + value }
            else { requestedDestination += (requestedDestination.isEmpty ? "" : "; ") + value }
        }
        var tokens = body.split(whereSeparator: \.isWhitespace).map(String.init)
        var amount = "", packCount = "", perPack = ""
        var unit = UnitOfMeasure.count, packUnit = UnitOfMeasure.count
        var warnings: [CaptureInterpretationWarning] = []
        if let first = tokens.first, let number = try? CaptureNumber.parse(first), number > .zero {
            tokens.removeFirst()
            if let token = tokens.first, packs.contains(token.lowercased()) {
                tokens.removeFirst()
                if number.denominator == 1 { packCount = number.description } else { warnings.append(.packUnknown) }
                if tokens.first.map({ ["of", "de"].contains($0.lowercased()) }) == true { tokens.removeFirst() }
                if let next = tokens.first, let amount = try? CaptureNumber.parse(next), amount > .zero {
                    perPack = amount.description; tokens.removeFirst()
                    if let known = takeUnit(&tokens) { packUnit = known }
                } else { warnings.append(.packUnknown) }
            } else {
                amount = number.description
                if let known = takeUnit(&tokens) { unit = known }
                else if let token = tokens.first, unknownMeasures.contains(token.lowercased()) { amount = ""; warnings.append(.ambiguous) }
            }
        } else { warnings.append(.quantityUnknown) }
        if tokens.contains(where: { packs.contains($0.lowercased()) }) { warnings.append(.packUnknown); amount = "" }
        let name = tokens.joined(separator: " ")
        if CaptureLimits.containsExclusion(original) || !exclusions.isEmpty { warnings.append(.negation) }
        let knownDestinations = ["this list", "this pickup", "current list", "esta lista", "esta compra", "lista actual"]
        let requested = CaptureCorrectionStore.key(requestedDestination)
        let chosenDestination: String
        if requested.isEmpty || knownDestinations.contains(requested) || requested == CaptureCorrectionStore.key(destination) {
            chosenDestination = destination
        } else { chosenDestination = requestedDestination; warnings.append(.destination) }
        var draft = CaptureLineDraft(id: UUID(), proposedLineID: UUID(), originalText: original,
            originalName: name.isEmpty ? body : name, name: name.isEmpty ? body : name)
        draft.amount = amount; draft.unit = unit; draft.packCount = packCount; draft.amountPerPack = perPack; draft.packUnit = packUnit
        draft.purpose = purpose; draft.destination = chosenDestination; draft.exclusions = exclusions; draft.warnings = warnings
        return draft
    }
    private static func takeUnit(_ tokens: inout [String]) -> UnitOfMeasure? {
        let pair = tokens.prefix(2).joined(separator: " ").lowercased()
        if ["fl oz", "fluid ounce", "fluid ounces", "onza líquida", "onzas líquidas"].contains(pair) {
            tokens.removeFirst(2); return .fluidOunce
        }
        guard let first = tokens.first, let unit = units[first.lowercased()] else { return nil }
        tokens.removeFirst(); return unit
    }
    private static func suffix(_ text: String, pattern: String) -> (String, String)? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
    static let units: [String: UnitOfMeasure] = ["g":.gram,"gram":.gram,"grams":.gram,"gramo":.gram,"gramos":.gram,"kg":.kilogram,"kilogram":.kilogram,"kilograms":.kilogram,"kilo":.kilogram,"kilos":.kilogram,"kilogramos":.kilogram,"oz":.ounce,"ounce":.ounce,"ounces":.ounce,"onza":.ounce,"onzas":.ounce,"lb":.pound,"lbs":.pound,"pound":.pound,"pounds":.pound,"libra":.pound,"libras":.pound,"ml":.milliliter,"milliliters":.milliliter,"mililitros":.milliliter,"l":.liter,"liter":.liter,"liters":.liter,"litro":.liter,"litros":.liter,"cup":.cup,"cups":.cup,"taza":.cup,"tazas":.cup,"count":.count,"units":.count,"unidades":.count]
    private static let packs: Set<String> = ["pack", "packs", "package", "packages", "paquete", "paquetes", "caja", "cajas"]
    private static let unknownMeasures: Set<String> = ["handful", "handfuls", "bunch", "bunches", "pinch", "pinches", "scoop", "scoops", "puñado", "puñados", "manojo", "manojos", "pizca", "pizcas", "cucharada", "cucharadas", "fl", "fluid"]
}
