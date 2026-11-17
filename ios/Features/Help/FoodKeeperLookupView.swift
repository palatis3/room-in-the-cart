import CoreDomain
import SwiftUI

/// Pantry callers supply the current storage location and an explicitly recorded opening day.
/// A recount, receipt timestamp or move between locations is never an opening date.
struct FoodKeeperLookupContext {
    let foodName: String
    let storage: FoodKeeperStorage
    let openedDay: MealDay?
}

struct FoodKeeperLookupView: View {
    var context: FoodKeeperLookupContext?
    @Environment(\.locale) private var locale
    private struct Query: Equatable, Sendable {
        let text: String
        let language: FoodKeeperLanguage
    }
    private struct SearchResult: Sendable {
        let query: Query
        let reference: FoodKeeperReference
        let products: [FoodKeeperProduct]
        let suggestedTerms: [String]
    }
    @State private var result: SearchResult?
    @State private var failed = false
    @State private var search = ""

    init(context: FoodKeeperLookupContext? = nil) {
        self.context = context
        _search = State(initialValue: context?.foodName ?? "")
    }

    private var language: FoodKeeperLanguage { locale.language.languageCode?.identifier == "es" ? .spanish : .english }

    var body: some View {
        let query = Query(text: search, language: language)
        List {
            if let result, result.query == query {
                if result.products.isEmpty {
                    Text(helpText("No matching FoodKeeper entry. Try another food name or category."))
                    if !result.suggestedTerms.isEmpty {
                        Section(helpText("Search using one word")) {
                            ForEach(result.suggestedTerms, id: \.self) { term in
                                Button(term) { search = term }
                            }
                        }
                    }
                }
                ForEach(result.products) { item in
                    NavigationLink {
                        FoodKeeperDetail(product: item, language: language, context: context)
                    } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Text(verbatim: item.name(language)).font(.headline)
                            Text(verbatim: item.categoryName(language)).font(.subheadline)
                        }
                    }.accessibilityIdentifier("foodKeeper.product." + String(item.id))
                }
            } else if failed { Text(helpText("The offline storage reference could not be opened.")) }
            else { ProgressView(helpText("Opening storage reference…")) }
        }
        .searchable(text: $search, prompt: Text(helpText("Search foods or categories")))
        .navigationTitle(helpText("Food storage guide"))
        .task(id: query) {
            guard result?.query != query else { return }
            let loaded = result?.reference
            do {
                let found = try await Task.detached(priority: .userInitiated) {
                    let reference = try loaded ?? FoodKeeperReference.bundled()
                    let products = reference.search(query.text, language: query.language)
                    let terms = products.isEmpty ? reference.suggestedTerms(for: query.text) : []
                    return SearchResult(query: query, reference: reference, products: products, suggestedTerms: terms)
                }.value
                try Task.checkCancellation()
                result = found
                failed = false
            } catch {
                if !Task.isCancelled { failed = true }
            }
        }
    }
}

private struct FoodKeeperDetail: View {
    let product: FoodKeeperProduct
    let language: FoodKeeperLanguage
    let context: FoodKeeperLookupContext?
    @State private var storage: FoodKeeperStorage

    init(product: FoodKeeperProduct, language: FoodKeeperLanguage, context: FoodKeeperLookupContext?) {
        self.product = product; self.language = language; self.context = context
        _storage = State(initialValue: context?.storage ?? .refrigerator)
    }

    var body: some View {
        List {
            Section {
                Text(verbatim: product.categoryName(language))
                if context != nil { LabeledContent(helpText("Batch storage"), value: storage.title) }
                else {
                    Picker(helpText("Storage location"), selection: $storage) {
                        ForEach(FoodKeeperStorage.allCases, id: \.self) { Text($0.title).tag($0) }
                    }
                }
            }
            ForEach(FoodKeeperCondition.allCases.filter { $0.storage == storage }, id: \.self) { condition in
                Section(condition.title) {
                    if let rule = product.rule(for: condition) {
                        if let guidance = rule.guidance(language) { Text(verbatim: guidance) }
                        if let note = rule.note(language) { Text(verbatim: note) }
                        if product.supportsDateWindow(for: condition) {
                            NavigationLink(helpText("Review a date range")) {
                                FoodKeeperDates(product: product, language: language, condition: condition,
                                    recordedDay: condition.startingEvent == .opened ? context?.openedDay : nil)
                            }
                        }
                    } else { Text(helpText("No matching guidance for this storage condition.")) }
                }
            }
            Section(helpText("Source")) {
                Text(verbatim: "USDA FSIS · FoodKeeper v128 · #" + String(product.id))
                Text(helpText("These ranges describe storage quality under the stated conditions. Follow the package directions."))
            }
        }
        .navigationTitle(product.name(language))
    }
}

private struct FoodKeeperDates: View {
    let product: FoodKeeperProduct
    let language: FoodKeeperLanguage
    let condition: FoodKeeperCondition
    let recordedDay: MealDay?
    @State private var date: Date
    @State private var confirmed = false

    init(product: FoodKeeperProduct, language: FoodKeeperLanguage, condition: FoodKeeperCondition, recordedDay: MealDay?) {
        self.product = product; self.language = language; self.condition = condition; self.recordedDay = recordedDay
        _date = State(initialValue: recordedDay?.date ?? Date())
    }

    private var zone: TimeZone {
        recordedDay.flatMap { TimeZone(identifier: $0.timeZoneIdentifier) } ?? .current
    }

    private var window: FoodKeeperProduct.Window? {
        guard let event = condition.startingEvent, let start = try? MealDay(date: date, timeZoneIdentifier: zone.identifier),
              let today = try? MealDay(date: Date(), timeZoneIdentifier: zone.identifier) else { return nil }
        return product.window(for: condition, storage: condition.storage, event: event, start: start, asOf: today, historyConfirmed: confirmed)
    }

    var body: some View {
        Form {
            Text(verbatim: product.name(language)).font(.headline)
            Text(condition.title)
            if let text = product.rule(for: condition)?.guidance(language) { Text(verbatim: text) }
            Section {
                DatePicker(condition.anchorTitle, selection: $date, in: ...Date(), displayedComponents: .date)
                    .environment(\.timeZone, zone)
                    .onChange(of: date) { _, _ in confirmed = false }
                Text(verbatim: zone.identifier).font(.footnote)
                Toggle(helpText("I confirmed the date, storage history and package directions."), isOn: $confirmed)
                    .accessibilityIdentifier("foodKeeper.confirmStorage")
            }
            if let window {
                Section(helpText("Estimated quality range")) {
                    if window.latest.hasSameCivilDate(as: window.earliest) {
                        LabeledContent(helpText("Quality check date"), value: formatted(window.earliest))
                    } else {
                        LabeledContent(helpText("Range starts"), value: formatted(window.earliest))
                            .accessibilityIdentifier("foodKeeper.rangeStart")
                        LabeledContent(helpText("Range ends"), value: formatted(window.latest))
                            .accessibilityIdentifier("foodKeeper.rangeEnd")
                    }
                    Text(helpText("Use this range to plan a quality check. Food safety also depends on how the food was handled."))
                }
            }
        }
        .navigationTitle(helpText("Review a date range"))
    }

    private func formatted(_ day: MealDay) -> String {
        guard let date = day.date else { return day.iso8601 }
        return date.formatted(Date.FormatStyle(date: .long, time: .omitted, timeZone: zone))
    }
}

private extension FoodKeeperStorage {
    var title: String {
        switch self {
        case .pantry: helpText("Pantry")
        case .refrigerator: helpText("Refrigerator")
        case .freezer: helpText("Freezer")
        }
    }
}

private extension FoodKeeperCondition {
    var title: String {
        switch self {
        case .pantry, .refrigerated, .frozen: helpText("General storage guidance")
        case .pantryPurchased, .refrigeratedPurchased, .frozenPurchased: helpText("From purchase")
        case .pantryOpened, .refrigeratedOpened: helpText("After opening")
        case .refrigeratedThawed: helpText("After thawing")
        }
    }
    var anchorTitle: String {
        switch startingEvent {
        case .purchased: helpText("Purchase date")
        case .opened: helpText("Date opened")
        case .thawed: helpText("Date thawed")
        case nil: helpText("Starting date")
        }
    }
}
