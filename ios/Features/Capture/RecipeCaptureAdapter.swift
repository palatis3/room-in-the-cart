import Foundation
import CoreDomain

struct RecipeCaptureDraft: Equatable, Sendable {
    var title = "" { didSet { confirmed = false } }
    var servings = "" { didSet { confirmed = false } }
    var sourceURL = "" { didSet { confirmed = false } }
    var notes = "" { didSet { confirmed = false } }
    var ingredientText = "" { didSet { confirmed = false } }
    var unclassifiedText = ""
    var confirmed = false

    func template(captureID: UUID, target: CaptureTarget, originalText: String, kind: RecipeSourceKind,
                  hasImage: Bool, reviewedIngredients: [CaptureImportLine]) throws -> MealTemplate {
        guard confirmed, target.kind == .recipeSource, !reviewedIngredients.isEmpty else { throw ScanFailure.needsReview }
        let servings = try CaptureNumber.parse(servings)
        guard servings > .zero else { throw ScanFailure.needsReview }
        let source = sourceURL.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            guard source.utf8.count <= 2048, let components = URLComponents(string: source),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""),
                  let host = components.host, !host.isEmpty, components.user == nil, components.password == nil else { throw ScanFailure.invalidText }
        }
        let ingredients = try reviewedIngredients.map { line in
            try line.validate()
            let metadata = CaptureImportMetadata(declaredQuantity: line.quantity, packCount: line.packCount,
                amountPerPack: line.amountPerPack, purpose: line.purpose, destination: line.destination,
                unresolvedFields: line.unresolvedFields)
            guard metadata.blockingFields.isEmpty else { throw ScanFailure.needsReview }
            return MealIngredient(id: line.proposedLineID, name: line.name, quantity: try metadata.resolvedQuantity(),
                notes: line.originalText, exclusions: line.exclusions)
        }
        let evidence = try RecipeSourceEvidence(captureID: captureID, originalText: originalText, kind: kind,
            localMedia: hasImage ? .init(workspaceID: target.workspaceID, mediaID: captureID) : nil)
        let template = MealTemplate(id: target.objectID, title: title, servings: servings, ingredients: ingredients,
            notes: notes, sourceURL: source.isEmpty ? nil : source, sourceEvidence: evidence)
        try template.validate()
        return template
    }
}

/// A bounded suggestion parser, not a recipe generator. Unclassified lines stay visible for manual selection.
enum RecipeOCRParser {
    static func draft(_ original: String) throws -> RecipeCaptureDraft {
        try ScanLimits.text(original)
        let lines = original.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        var value = RecipeCaptureDraft()
        var section = 0
        var ingredients: [String] = [], instructions: [String] = []
        var unclassified: [(text: String, yield: Bool)] = []
        var yields: [(literal: String, amount: Rational)] = []
        for (index, line) in lines.enumerated() {
            let key = line.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ": "))
            if ["ingredients", "ingredientes"].contains(key) { section = 1; continue }
            if ["instructions", "directions", "method", "preparation", "preparación", "preparacion", "elaboración", "elaboracion", "instrucciones"].contains(key) { section = 2; continue }
            if section == 0, let match = yieldHeading.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
               let range = Range(match.range(at: 1), in: line) {
                let literal = String(line[range])
                if let count = try? CaptureNumber.parse(literal), count > .zero {
                    yields.append((literal, count))
                    unclassified.append((line, true))
                    continue
                }
                if index != 0 {
                    unclassified.append((line, true))
                    continue
                }
            }
            if index == 0 { value.title = line; continue }
            if section == 1 { ingredients.append(line) }
            else if section == 2 { instructions.append(line) }
            else { unclassified.append((line, false)) }
        }
        value.ingredientText = ingredients.joined(separator: "\n")
        value.notes = instructions.joined(separator: "\n")
        if let first = yields.first, yields.count == unclassified.filter(\.yield).count,
           yields.allSatisfy({ $0.amount == first.amount }) {
            value.servings = first.literal
            unclassified.removeAll(where: \.yield)
        }
        value.unclassifiedText = unclassified.map(\.text).joined(separator: "\n")
        value.confirmed = false
        return value
    }
    private static let yieldHeading = try! NSRegularExpression(
        pattern: #"^(?:serves|servings|yield|rinde|porciones|raciones)(?:\s*:\s*|\s+)(.+?)(?:\s+(?:servings?|porci[oó]n|porciones|raci[oó]n|raciones))?$"#,
        options: .caseInsensitive
    )
}

enum ReviewedScan {
    case evidence(SourceMediaRecord)
    case recipe(MealTemplate, SourceMediaRecord)
}
