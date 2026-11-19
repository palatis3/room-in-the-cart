import Foundation

/// Quick entry accepts a bare product name. Quantities, list separators and
/// qualifications belong in the existing review, which retains the original wording.
public enum QuickGrocery {
    private static let reviewWords: Set<String> = [
        "half", "quarter", "one", "two", "three", "four", "five", "dozen", "few", "some",
        "medio", "media", "mitad", "una", "un", "dos", "tres", "cuatro", "cinco", "docena",
        "cups", "cup", "oz", "ounce", "ounces", "lb", "lbs", "pound", "pounds", "kg", "g",
        "ml", "l", "liter", "liters", "litro", "litros", "taza", "tazas", "libra", "libras",
        "kilo", "kilos", "box", "boxes", "pack", "packs", "caja", "cajas", "paquete", "paquetes",
        "carton", "cartons", "bag", "bags", "tin", "tins", "can", "cans", "jar", "jars", "bottle", "bottles",
        "bolsa", "bolsas", "lata", "latas", "frasco", "frascos", "botella", "botellas", "cartón", "cartones",
        "for", "para", "please", "quiero", "and", "or", "y", "o", "without", "except", "sin", "excepto"
    ]

    public static func plainName(_ text: String) -> String? {
        guard text.utf8.count <= 512, !text.contains(where: \.isNewline) else { return nil }
        let name = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = CharacterSet.letters.union(.nonBaseCharacters).union(CharacterSet(charactersIn: " -’'"))
        var amountTokens = ListQuantityParser.itemTokens(name.lowercased())
        guard (try? ListQuantityParser.takeAmount(from: &amountTokens, allowingWords: true)) == nil else { return nil }
        let words = name.lowercased().split { $0.isWhitespace || $0 == "-" }
        guard !words.isEmpty, words.count <= 8, name.first?.isLetter == true, name.last?.isLetter == true,
              name.unicodeScalars.allSatisfy(allowed.contains),
              words.allSatisfy({ word in
                  let token = String(word)
                  var unit = [token][...]
                  return !reviewWords.contains(token) && !ListQuantityParser.needsUnitReview(token) &&
                      ListQuantityParser.takeUnit(from: &unit) == nil
              }) else { return nil }
        return name
    }

    public static func recentNames(in workspace: LedgerWorkspace) -> [String] {
        let shops = workspace.shops.sorted {
            ($0.revisions.last?.createdAt ?? .distantPast) > ($1.revisions.last?.createdAt ?? .distantPast)
        }
        var seen = Set<String>(), names: [String] = []
        for shop in shops {
            for line in shop.lines.reversed() where !line.isTrashed {
                guard let name = plainName(line.name), seen.insert(name.lowercased()).inserted else { continue }
                names.append(name)
                if names.count == 12 { return names }
            }
        }
        return names
    }

    /// Commit through the ordinary import receipt. An omitted quantity stays unknown.
    public static func stage(_ text: String, in shop: ShoppingLedger) throws -> StagedListImport? {
        guard let name = plainName(text) else { return nil }
        var preview = try shop.stageImport(text: name, maximumLines: 1)
        guard preview.lines.count == 1, preview.lines[0].duplicateLineIDs.isEmpty else { return nil }
        preview.lines[0].unresolvedReason = nil
        return preview
    }
}

/// Exact product labels only. Each branch may have a different department for
/// a product. These labels are used only when the shopper has supplied none.
public enum GroceryDepartment: CaseIterable, Sendable {
    case produce, dairy, bakery, meat, frozen, pantry, household

    public func label(spanish: Bool) -> String {
        switch self {
        case .produce: spanish ? "Frutas y verduras" : "Produce"
        case .dairy: spanish ? "Lácteos" : "Dairy"
        case .bakery: spanish ? "Panadería" : "Bakery"
        case .meat: spanish ? "Carnes y pescados" : "Meat and seafood"
        case .frozen: spanish ? "Congelados" : "Frozen"
        case .pantry: spanish ? "Despensa" : "Pantry"
        case .household: spanish ? "Artículos del hogar" : "Household"
        }
    }

    private static let products: [String: Self] = {
        let names: [(Self, String)] = [
            (.produce, "apples|apple|manzana|manzanas|bananas|banana|plátanos|plátano|tomatoes|tomato|tomates|tomate|onions|onion|cebollas|cebolla|carrots|zanahorias|lettuce|lechuga|potatoes|papas|avocado|aguacate"),
            (.dairy, "milk|whole milk|leche|leche entera|butter|mantequilla|yogurt|yogur|cheese|queso|eggs|egg|huevos|huevo"),
            (.bakery, "bread|pan|bagels|rolls|baguette|pan integral|whole wheat bread"),
            (.meat, "ground beef|carne molida|chicken breast|pechuga de pollo|salmon|salmón"),
            (.frozen, "ice cream|helado|frozen peas|chícharos congelados|frozen pizza|pizza congelada"),
            (.pantry, "rice|arroz|pasta|rigatoni|spaghetti|espagueti|flour|harina|sugar|azúcar|olive oil|aceite de oliva"),
            (.household, "foil|aluminum foil|papel aluminio|papel de aluminio|paper towels|toallas de papel|toilet paper|papel higiénico|dish soap|jabón para platos")
        ]
        return Dictionary(uniqueKeysWithValues: names.flatMap { category, labels in
            labels.split(separator: "|").map { (String($0), category) }
        })
    }()

    public static func suggested(for name: String) -> Self? {
        let key = name.lowercased(with: Locale(identifier: "en_US_POSIX")).split(whereSeparator: \.isWhitespace).joined(separator: " ")
        return products[key]
    }

    public static let usesSpanish = Bundle.main.preferredLocalizations.first?.hasPrefix("es") == true
}

/// No fuzzy match supplies an amount. The shopper can explicitly identify a
/// product among whole-word candidates before seeing the batch evidence.
public struct GroceryPantryCandidates {
    public let exact: Set<UUID>
    public let possible: Set<UUID>
    public var unambiguous: UUID? { exact.count == 1 ? exact.first : nil }

    public init(name: String, products: [(id: UUID, name: String)], confirmedAliases: Set<UUID>) {
        func key(_ label: String) -> String {
            label.precomposedStringWithCanonicalMapping.lowercased(with: Locale(identifier: "en_US_POSIX"))
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let query = key(name)
        let words = Set(query.split(separator: " "))
        var matching = Set<UUID>(), offered = Set<UUID>()
        for product in products where !query.isEmpty {
            let label = key(product.name)
            if label == query || confirmedAliases.contains(product.id) {
                matching.insert(product.id)
                offered.insert(product.id)
            } else if query.count >= 3 && words.isSubset(of: Set(label.split(separator: " "))) {
                offered.insert(product.id)
            }
        }
        exact = matching
        possible = offered
    }
}
