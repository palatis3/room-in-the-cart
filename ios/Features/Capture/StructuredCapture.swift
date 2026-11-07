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
        var tokens = text.split(whereSeparator: \.isWhitespace).map(String.init)[...]
        guard let number = try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true), tokens.isEmpty else {
            throw StructuredCaptureFailure.invalidAmount
        }
        return number
    }
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
        var tokens = ListQuantityParser.itemTokens(body)
        var amount = "", packCount = "", perPack = ""
        var unit = UnitOfMeasure.count, packUnit = UnitOfMeasure.count
        var warnings: [CaptureInterpretationWarning] = []
        let originalTokens = tokens
        if let number = try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true), number > .zero {
            if let label = ListQuantityParser.takePackLabel(count: number, from: &tokens, original: original) {
                if let count = label.count { packCount = String(count) }
                if let contents = label.amountPerPack, contents.amount > .zero {
                    perPack = contents.amount.description
                    packUnit = contents.unit
                }
                if label.count == nil || perPack.isEmpty { warnings.append(.packUnknown) }
            } else {
                amount = number.description
                if let known = ListQuantityParser.takeUnit(from: &tokens) { unit = known }
                else if ListQuantityParser.needsUnitReview(tokens.first) { amount = ""; warnings.append(.ambiguous) }
            }
        } else { tokens = originalTokens; warnings.append(.quantityUnknown) }
        if tokens.contains(where: ListQuantityParser.isPackMarker) {
            if !warnings.contains(.packUnknown) { warnings.append(.packUnknown) }
            amount = ""; perPack = ""
        }
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
    private static func suffix(_ text: String, pattern: String) -> (String, String)? {
        guard let expression = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive),
              let match = expression.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return (String(text[..<range.lowerBound]), String(text[range.upperBound...]))
    }
}
