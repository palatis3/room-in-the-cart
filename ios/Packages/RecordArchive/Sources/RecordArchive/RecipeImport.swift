import CoreFoundation
import CoreDomain
import Foundation

public struct ImportedRecipe: Codable, Equatable, Sendable, Identifiable {
    public var id: String { (try? ArchiveCodec.digest(ArchiveCodec.canonical(self))) ?? title }
    public var title: String
    public var yieldText: String
    public var ingredients: [String]
    public var steps: [String]
    public var reviewedSteps: [RecipeStep]?
    public var cookingSteps: [RecipeStep] { reviewedSteps ?? steps.map { RecipeStep($0) } }
    public var sourceURL: String?
    public var notes: String
    public init(title: String, yieldText: String = "", ingredients: [String] = [], steps: [String] = [], sourceURL: String? = nil, notes: String = "", reviewedSteps: [RecipeStep]? = nil) {
        self.title = title; self.yieldText = yieldText; self.ingredients = ingredients
        self.reviewedSteps = reviewedSteps?.contains(where: \.hasReviewedDetails) == true ? reviewedSteps : nil
        self.steps = steps; self.sourceURL = sourceURL; self.notes = notes
    }
    public enum MissingField: Hashable, Sendable { case servings, ingredients, instructions }
    public var missingFields: [MissingField] {
        func blank(_ value: String) -> Bool { value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var result: [MissingField] = []
        if blank(yieldText) { result.append(.servings) }
        if ingredients.allSatisfy(blank) { result.append(.ingredients) }
        if steps.allSatisfy(blank) { result.append(.instructions) }
        return result
    }

    public func validated() throws -> ImportedRecipe {
        guard !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              title.utf8.count <= 4096, yieldText.utf8.count <= 4096, notes.utf8.count <= 32768,
              [title, yieldText, notes].allSatisfy({ !$0.contains("\0") }),
              ingredients.count <= 1000, steps.count <= 1000,
              (ingredients + steps).allSatisfy({ $0.utf8.count <= 32768 && !$0.contains("\0") }) else { throw ArchiveError.invalidRecipe }
        if let reviewedSteps {
            guard reviewedSteps.map(\.instruction) == steps,
                  (try? RecipeStep.validate(reviewedSteps, ingredientCount: ingredients.count)) != nil else {
                throw ArchiveError.invalidRecipe
            }
        }
        if let sourceURL, !sourceURL.isEmpty {
            guard sourceURL.utf8.count <= 4096, let components = URLComponents(string: sourceURL),
                  ["http", "https"].contains(components.scheme?.lowercased() ?? ""), let host = components.host, !host.isEmpty,
                  components.user == nil, components.password == nil else { throw ArchiveError.invalidRecipe }
        }
        return self
    }
    public func archiveRecord(origin: String, savedAt: Date = Date()) throws -> ArchiveRecord {
        let recipe = try validated()
        return ArchiveRecord(id: recipe.id, origin: origin, revision: recipe.id, kind: .recipe, title: title,
                             savedAtMilliseconds: ArchiveCodec.milliseconds(savedAt),
                             helperLines: ingredients.map { HelperLine(label: $0) }, nativePayload: try ArchiveCodec.canonical(recipe))
    }
}
public struct RecipeImportReport: Sendable {
    public var recipes: [ImportedRecipe]
    public let duplicateCount: Int
    public var skippedRows: Int
    public let unsupportedFields: [String]

    public static func manual(_ recipe: ImportedRecipe) -> Self {
        Self(recipes: [recipe], duplicateCount: 0, skippedRows: 0, unsupportedFields: [])
    }
}

/// Documented Recipe JSON-LD profile. Context URLs are inert text, never fetched.
public enum RecipeImporter {
    private static func validateVersion(_ version: Any?) throws {
        guard let version else { return }
        // JSONSerialization bridges true and 1 to NSNumber.
        guard let number = version as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
              number == NSNumber(value: 1) else { throw ArchiveError.unsupportedVersion }
    }

    // Carry each section heading with its first actual instruction. Existing saved
    // recipes, exports and dinner adoption all use the same ordered string steps.
    private static func collectInstructions(_ node: Any, steps: inout [String], unsupported: inout Set<String>) -> Bool {
        if let children = node as? [Any] {
            for child in children {
                guard collectInstructions(child, steps: &steps, unsupported: &unsupported) else { return false }
            }
            return true
        }
        if let text = node as? String {
            guard steps.count < 1000 else { return false }
            steps.append(text)
            return true
        }
        guard let object = node as? [String: Any] else { return false }
        let types = object["@type"] as? [String] ?? (object["@type"] as? String).map { [$0] } ?? []
        func hasType(_ name: String) -> Bool {
            types.contains(name) || types.contains("https://schema.org/" + name) || types.contains("http://schema.org/" + name)
        }
        let allowed: Set<String>
        if hasType("HowToSection") {
            allowed = ["@type", "name", "itemListElement"]
            guard object["name"] == nil || object["name"] is String,
                  object["itemListElement"] == nil || object["itemListElement"] is [Any] else { return false }
            let first = steps.count
            if let children = object["itemListElement"] {
                guard collectInstructions(children, steps: &steps, unsupported: &unsupported) else { return false }
            }
            if let name = object["name"] as? String, !name.isEmpty {
                if let i = steps[first...].firstIndex(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) {
                    guard name.utf8.count + steps[i].utf8.count + 1 <= 32768 else { return false }
                    steps[i] = name + "\n" + steps[i]
                } else {
                    unsupported.insert("recipeInstructions.itemListElement")
                }
            }
        } else {
            allowed = ["@type", "text"]
            guard hasType("HowToStep"), let text = object["text"] as? String, steps.count < 1000 else { return false }
            steps.append(text)
        }
        for key in object.keys where !allowed.contains(key) { unsupported.insert("recipeInstructions." + key.prefix(80)) }
        return true
    }

    public static func stage(_ data: Data, existing: [ImportedRecipe] = [],
                             existingSourceIDs: Set<String> = []) throws -> RecipeImportReport {
        try ArchiveCodec.preflight(data)
        let root: Any
        do { root = try JSONSerialization.jsonObject(with: data) } catch { throw ArchiveError.malformed }
        let nodes: [Any]
        if let dictionary = root as? [String: Any] {
            try validateVersion(dictionary["formatVersion"])
            if let graph = dictionary["@graph"] as? [Any] { nodes = graph } else { nodes = [dictionary] }
        } else if let array = root as? [Any] { nodes = array }
        else { throw ArchiveError.invalidRecipe }
        guard nodes.count <= ArchiveCodec.maximumRecords else { throw ArchiveError.tooLarge }
        var recipes: [ImportedRecipe] = [], duplicates = 0, skipped = 0, unsupported = Set<String>()
        var known = existingSourceIDs.union(existing.map(\.id))
        let allowed: Set<String> = ["@context", "@type", "@id", "formatVersion", "name", "recipeYield", "recipeIngredient", "recipeInstructions", "url", "notes", "description"]
        for node in nodes {
            guard let object = node as? [String: Any] else { skipped += 1; continue }
            let types = (object["@type"] as? [String]) ?? (object["@type"] as? String).map { [$0] } ?? []
            guard types.contains(where: { $0 == "Recipe" || $0 == "https://schema.org/Recipe" || $0 == "http://schema.org/Recipe" }) else { skipped += 1; continue }
            try validateVersion(object["formatVersion"])
            unsupported.formUnion(object.keys.filter { !allowed.contains($0) }.map { String($0.prefix(80)) })
            guard let title = object["name"] as? String else { skipped += 1; continue }
            guard object["recipeIngredient"] == nil || object["recipeIngredient"] is [String],
                  object["recipeYield"] == nil || object["recipeYield"] is String,
                  object["url"] == nil || object["url"] is String,
                  object["notes"] == nil || object["notes"] is String,
                  object["notes"] != nil || object["description"] == nil || object["description"] is String else { skipped += 1; continue }
            var steps: [String] = []
            if let instructions = object["recipeInstructions"] {
                guard collectInstructions(instructions, steps: &steps, unsupported: &unsupported) else {
                    skipped += 1
                    continue
                }
            }
            let recipe = ImportedRecipe(title: title, yieldText: object["recipeYield"] as? String ?? "", ingredients: object["recipeIngredient"] as? [String] ?? [], steps: steps, sourceURL: object["url"] as? String, notes: object["notes"] as? String ?? object["description"] as? String ?? "")
            guard (try? recipe.validated()) != nil else { skipped += 1; continue }
            let payload = try ArchiveCodec.canonical(recipe)
            let id = ArchiveCodec.digest(payload)
            if known.contains(id) { duplicates += 1; continue }
            // Every staged recipe must fit both its native record and ingredient projection.
            guard payload.count <= ArchiveCodec.maximumNativeBytes,
                  recipe.ingredients.allSatisfy({ $0.utf8.count <= ArchiveCodec.maximumHelperFieldBytes }) else {
                skipped += 1
                continue
            }
            known.insert(id)
            recipes.append(recipe)
        }
        guard !recipes.isEmpty || duplicates > 0 else { throw ArchiveError.invalidRecipe }
        return RecipeImportReport(recipes: recipes, duplicateCount: duplicates, skippedRows: skipped, unsupportedFields: unsupported.sorted())
    }
}
