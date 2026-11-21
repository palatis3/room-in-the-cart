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
    public var suggestedServings: Rational? {
        var tokens = yieldText.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)[...]
        guard !ListQuantityParser.takeRange(from: &tokens) else { return nil }
        let prefix = tokens.first
        let explicitlyServes = prefix == "serves"
        if explicitlyServes || prefix == "para" { tokens = tokens.dropFirst() }
        guard let amount = try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true, allowingDecimalComma: true),
              amount > .zero else { return nil }
        let units = ["serving", "servings", "people", "person", "porción", "porciones", "ración", "raciones", "persona", "personas"]
        return (explicitlyServes && tokens.isEmpty) || (tokens.count == 1 && units.contains(tokens.first ?? "")) ? amount : nil
    }

    /// Seed editable facts only where the source names a supported measure or an individual piece.
    public static func ingredientDraft(_ original: String) -> MealIngredient {
        var tokens = ListQuantityParser.itemTokens(original)
        let unresolved = MealIngredient(name: original, quantity: nil, originalWording: original)
        guard original.utf8.count <= StagedListImport.maximumOriginalLineBytes,
              !ListQuantityParser.takeRange(from: &tokens),
              let number = try? ListQuantityParser.takeAmount(from: &tokens, allowingWords: true, allowingDecimalComma: true),
              number > .zero else { return unresolved }
        let quantity: Quantity
        if let pack = ListQuantityParser.takePackLabel(count: number, from: &tokens, original: original, allowingDecimalComma: true) {
            guard let total = pack.total else { return unresolved }
            quantity = total
        } else {
            let measure = ListQuantityParser.takeMeasure(number, from: &tokens)
            let pieces: Set<String> = ["egg", "eggs", "huevo", "huevos", "onion", "onions", "cebolla", "cebollas",
                                       "carrot", "carrots", "zanahoria", "zanahorias", "tomato", "tomatoes", "tomate", "tomates",
                                       "lemon", "lemons", "limón", "limones", "tortilla", "tortillas", "pita", "pitas",
                                       "potato", "potatoes", "papa", "papas", "camote", "camotes"]
            guard let amount = measure.amount, let first = tokens.first,
                  measure.unit != nil || pieces.contains(first.lowercased().trimmingCharacters(in: .punctuationCharacters))
                    || ["sweet potato", "sweet potatoes", "pan pita", "panes pita"].contains(tokens.joined(separator: " ").lowercased())
            else { return unresolved }
            quantity = Quantity(amount: amount, unit: measure.unit ?? .count, originalLiteral: original)
        }
        guard !tokens.isEmpty, quantity.amount > .zero else { return unresolved }
        return MealIngredient(name: tokens.joined(separator: " "), quantity: quantity, originalWording: original)
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

/// A portable pending review uses the existing checked archive format. Only the
/// reviewed recipe sources travel, and opening the file never commits a record.
public enum RecipeDraftFile {
    private static let namespace = "recipe-review-v1"

    public static func encode(_ records: [ArchiveRecord]) throws -> Data {
        _ = try contents(records)
        return try ArchiveCodec.encode(ArchiveCodec.make(records: records, kind: .personalRecovery,
            origin: namespace, revision: namespace))
    }

    public static func readIfPresent(_ data: Data) throws -> (RecipeImportReport, [ArchiveRecord])? {
        try ArchiveCodec.preflight(data)
        guard let header = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              header["originNamespace"] as? String == namespace else { return nil }
        let document = try ArchiveCodec.decode(data)
        guard document.documentKind == .personalRecovery, document.mediaManifest == nil else { throw ArchiveError.invalidRecipe }
        let records = document.payload.records
        let recipes = try contents(records)
        guard document.sourceRevisionID == namespace else { throw ArchiveError.unsupportedVersion }
        return (RecipeImportReport(recipes: recipes, duplicateCount: 0, skippedRows: 0, unsupportedFields: []), records)
    }

    private static func contents(_ records: [ArchiveRecord]) throws -> [ImportedRecipe] {
        guard !records.isEmpty, records.count <= ArchiveCodec.maximumRecords else { throw ArchiveError.invalidRecipe }
        return try records.map { record in
            guard record.kind == .recipe, record.media == nil, let bytes = record.nativePayload else { throw ArchiveError.invalidRecipe }
            let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: bytes).validated()
            var expected = try recipe.archiveRecord(origin: record.origin, savedAt: Date(timeIntervalSince1970: 0))
            expected.id = record.id
            expected.parentRevision = record.parentRevision
            guard expected == record else { throw ArchiveError.invalidRecipe }
            return recipe
        }
    }
}
