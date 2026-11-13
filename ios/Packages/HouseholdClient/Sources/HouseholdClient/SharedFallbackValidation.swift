import Foundation

private func unique<T: Hashable>(_ values: [T]) -> Bool { Set(values).count == values.count }
private func validTags(_ values: [String], limit: Int = 60) -> Bool {
    values.count <= limit && values.allSatisfy { sharedMealText($0, 240) && !$0.utf8.contains(0) }
}
private func measured(_ q: SharedMealQuantity) -> Bool { q.validStockQuantity && q.amount.numerator > 0 && !q.originalLiteral.utf8.contains(0) }

extension SharedFallbackSource {
    func validate() throws {
        switch self {
        case .disclosed: return
        case let .meal(_, revision, _), let .idea(_, revision):
            guard (1...Int(Int32.max)).contains(revision) else { throw ClientError.configuration }
        }
    }
}

extension SharedFallbackRecipe {
    public func validateForDisclosure() throws {
        try validate()
        guard try encoded(self).count <= 512 * 1024 else { throw ClientError.configuration }
    }

    func validate() throws {
        let groups = groups ?? []
        guard sharedMealText(title, 240), !title.utf8.contains(0), (1...1000).contains(portions),
              !notes.utf8.contains(0), notes.utf8.count <= 8192, sourceURL?.utf8.contains(0) != true, (sourceURL?.utf8.count ?? 0) <= 2048,
              validTags(exclusions), (0...1_000_000).contains(requiredLeadMinutes ?? 0), (0...1_000_000).contains(elapsedMinutes ?? 0),
              (1...260).contains(ingredients.count), unique(ingredients.map(\.id)), groups.count <= 30, unique(groups.map(\.id))
        else { throw ClientError.configuration }
        var servings = SharedDeliveryCoverage.Fraction.zero
        for group in groups {
            guard sharedMealText(group.name, 240), !group.name.utf8.contains(0), validTags(group.exclusions) else { throw ClientError.configuration }
            try group.servings.validate()
            servings = servings.adding(.init(numerator: String(group.servings.numerator), denominator: String(group.servings.denominator)))
        }
        guard servings.compare(.init(numerator: String(portions), denominator: "1")) != .orderedDescending else { throw ClientError.configuration }
        let groupIDs = Set(groups.map(\.id))
        for ingredient in ingredients {
            let ids = ingredient.groupIds ?? [], parts = ingredient.bindings ?? []
            guard sharedMealText(ingredient.name, 240), !ingredient.name.utf8.contains(0), ingredient.notes.utf8.count <= 8192,
                  !ingredient.notes.utf8.contains(0), validTags(ingredient.exclusions),
                  ingredient.quantity.map(measured) ?? true, unique(ids), groupIDs.isSuperset(of: ids), unique(parts.map(\.groupId)),
                  Set(ids).isSuperset(of: parts.map(\.groupId)) else { throw ClientError.configuration }
            if parts.isEmpty { continue }
            guard let q = ingredient.quantity, let total = DeliveryUnit.convert(q, to: q.unit) else { throw ClientError.configuration }
            var sum = SharedDeliveryCoverage.Fraction.zero
            for part in parts {
                guard measured(part.quantity), let fraction = DeliveryUnit.convert(part.quantity, to: q.unit) else { throw ClientError.configuration }
                sum = sum.adding(fraction)
            }
            guard sum.compare(total) != .orderedDescending, parts.count != ids.count || sum.compare(total) == .orderedSame else {
                throw ClientError.configuration
            }
        }
    }
}

extension SharedFallbackLibrary {
    func validate() throws {
        guard (1...Int(Int32.max)).contains(shopRevision), (1...Int(Int32.max)).contains(authorityEpoch),
              (0...Int(Int32.max)).contains(registryRevision), candidates.count <= 100, unique(candidates.map(\.id))
        else { throw ClientError.invalidResponse }
        guard candidates.map(\.id.uuidString) == candidates.map(\.id.uuidString).sorted() else { throw ClientError.invalidResponse }
        for candidate in candidates {
            guard candidate.revision >= 1, candidate.revision <= registryRevision else { throw ClientError.invalidResponse }
            try candidate.recipe.validate()
        }
    }
}

extension SharedFallbackTrip {
    func validate() throws {
        guard (0...1_000_000).contains(minutes), (0...1_000_000_000).contains(budgetMinor), (0...1_000_000_000).contains(chargesMinor),
              currency.utf8.count == 3, currency.utf8.allSatisfy({ (65...90).contains($0) }) else { throw ClientError.configuration }
    }
}

extension SharedFallbackReview {
    func validate(_ candidate: SharedFallbackLibrary.Candidate, page: SharedRecoveryPage) throws {
        guard remainingTimeUnknown == nil || (remainingTimeUnknown == true && remainingElapsedMinutes == nil),
              candidate.id == candidateId, candidate.revision == revision, (0...1_000_000).contains(remainingElapsedMinutes ?? 0),
              ingredients.count <= 260, unique(ingredients.map(\.ingredientId)),
              Set(ingredients.map(\.ingredientId)) == Set(candidate.recipe.ingredients.map(\.id)) else { throw ClientError.configuration }
        let sources = Set(page.sourceOptions.map(\.id))
        var packs = [UUID: SharedFallbackOffer]()
        for row in ingredients {
            guard row.sourceIds.count <= 100, unique(row.sourceIds), sources.isSuperset(of: row.sourceIds) else { throw ClientError.configuration }
            guard let offer = row.offer else { continue }
            guard sharedMealText(offer.label, 240), validTags(offer.exclusionTags, limit: 20), measured(offer.usablePerPack),
                  (0...1_000_000_000).contains(offer.priceMinor), (0...1_000_000).contains(offer.availablePacks) else { throw ClientError.configuration }
            let key = offer.packId ?? row.ingredientId
            if let previous = packs.updateValue(offer, forKey: key), previous != offer { throw ClientError.configuration }
        }
    }
}

extension SharedFallbackOptions {
    func validate(page: SharedRecoveryPage, library: SharedFallbackLibrary, occurrence: UUID, reviews: [SharedFallbackReview], trip: SharedFallbackTrip?) throws {
        guard shopId == page.shopId, base == page.base, target.id == occurrence, let original = page.meals.first(where: { $0.id == occurrence }),
              try target.targetDigest() == original.targetDigest(), let now = householdTimestamp(asOf), let deskTime = householdTimestamp(page.asOf), now >= deskTime,
              unique(options.map(\.id)), options.count <= reviews.count else { throw ClientError.invalidResponse }
        let returned = options.map(\.id) + conditional.map(\.id)
        guard unique(returned), Set(returned) == Set(reviews.map(\.candidateId)) else { throw ClientError.invalidResponse }
        for row in conditional {
            guard reviews.contains(where: { $0.candidateId == row.id && $0.revision == row.revision }),
                  ["timingUnknown","topUpUnreviewed","deadlineExceeded","leadStepUnconfirmed","exclusionConflict",
                   "insufficientPacks","overBudget","foodUnconfirmed","protectedCommitment"].contains(row.reason),
                  [row.minutes, row.availableMinutes, row.requiredPacks, row.availablePacks, row.extraCashMinor, row.budgetMinor]
                    .compactMap({ $0 }).allSatisfy({ (0...9_007_199_254_740_991).contains($0) }),
                  row.currency.map({ $0 == trip?.currency }) ?? true, row.budgetMinor.map({ $0 == trip?.budgetMinor }) ?? true
            else { throw ClientError.invalidResponse }
            if row.reason == "overBudget" {
                guard let budget = row.budgetMinor, row.extraCashMinor.map({ $0 > budget }) ?? true, row.currency == trip?.currency else {
                    throw ClientError.invalidResponse
                }
            }
            if row.reason == "insufficientPacks", let needed = row.requiredPacks {
                guard let available = row.availablePacks, needed > available else { throw ClientError.invalidResponse }
            }
            if row.reason == "deadlineExceeded" {
                guard let minutes = row.minutes, let available = row.availableMinutes, minutes >= available else { throw ClientError.invalidResponse }
            }
        }
        var previous: (Int, Int, Int, String)?
        var usual = [Int]()
        for option in options {
            guard let candidate = library.candidates.first(where: { $0.id == option.id }), let review = reviews.first(where: { $0.candidateId == option.id }),
                  option.revision == candidate.revision, review.revision == candidate.revision, option.title == candidate.recipe.title,
                  option.intent.fallback?.review == review, option.intent.fallback?.trip == trip,
                  option.intent.occurrenceId == occurrence, option.intent.reviewedAt == asOf, option.intent.repeatOfOccurrenceId == nil,
                  !option.intent.agreesToRepeat, !option.intent.agreesToExtraTrip, !option.intent.acceptsUnresolved,
                  page.commitmentInventoryComplete else { throw ClientError.invalidResponse }
            try option.intent.validate(page: page)
            try option.validateRecipe(candidate.recipe, review: review, target: target, page: page)
            try option.validateEstimate(page: page, now: now, trip: trip)
            let key = (option.packCount, option.extraCashMinor, option.minutes, option.id.uuidString)
            guard previous.map({ $0 < key }) ?? true else { throw ClientError.invalidResponse }
            previous = key
            if candidate.usual { usual.append(option.minutes) }
        }
        guard usualMinutes == usual.min() else { throw ClientError.invalidResponse }
    }
}

func fallbackName(_ value: String) -> String {
    let spaces = CharacterSet.whitespacesAndNewlines.subtracting(CharacterSet(charactersIn: "\u{0085}\u{200B}"))
        .union(CharacterSet(charactersIn: "\u{FEFF}"))
    return value.components(separatedBy: spaces).filter { !$0.isEmpty }.joined(separator: " ").lowercased(with: Locale(identifier: "en_US"))
}

private func conflicts(_ need: SharedRecoveryNeed, with name: String, tags: [String]) -> Bool {
    func term(_ value: String) -> String {
        let decomposed = value.decomposedStringWithCompatibilityMapping.unicodeScalars.filter { !CharacterSet.nonBaseCharacters.contains($0) }
        return String(String.UnicodeScalarView(decomposed)).lowercased(with: Locale(identifier: "en"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    let labels = [need.name, name].map { " " + term($0) + " " }, tags = tags.map(term)
    return need.exclusions.contains { exclusion in
        let raw = term(exclusion)
        let prefix = ["no ", "sin ", "without "].first { raw.hasPrefix($0) }
        let prohibited = String(raw.dropFirst(prefix?.count ?? 0))
        return !prohibited.isEmpty && (tags.contains(raw) || tags.contains(prohibited) || labels.contains { $0.contains(" " + prohibited + " ") })
    }
}

private extension SharedFallbackOptions.Option {
    func validateRecipe(_ recipe: SharedFallbackRecipe, review: SharedFallbackReview, target: SharedRecoveryMeal, page: SharedRecoveryPage) throws {
        let next = intent.replacement
        let protected = target.needs.filter { $0.priority == "protected" }
        let added = recipe.exclusions.filter { e in protected.allSatisfy { $0.exclusions.contains(e) } }
        let mealExclusions = (target.exclusions + added).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
        guard next.title == recipe.title, next.notes == recipe.notes, next.sourceURL == recipe.sourceURL,
              review.remainingTimeUnknown != true, next.remainingElapsedMinutes == (review.remainingElapsedMinutes ?? recipe.elapsedMinutes), next.requiredLeadMinutes == recipe.requiredLeadMinutes,
              next.advanceStepsCompleted == review.advanceStepsCompleted, next.exclusions == mealExclusions,
              review.advanceStepsCompleted || (next.remainingElapsedMinutes ?? 0) >= (recipe.elapsedMinutes ?? 0),
              repeatRequired || !page.meals.contains(where: { fallbackName($0.title) == fallbackName(next.title) })
        else { throw ClientError.invalidResponse }
        var mapping = [UUID: SharedRecoveryMeal.Group]()
        for group in recipe.groups ?? [] {
            let matches = target.groups.filter { ($0.id == group.id || fallbackName($0.name) == fallbackName(group.name)) &&
                $0.protected == group.protected && fraction($0.servings).compare(fraction(group.servings)) == .orderedSame }
            guard matches.count == 1, !mapping.values.contains(where: { $0.id == matches[0].id }) else { throw ClientError.invalidResponse }
            mapping[group.id] = matches[0]
        }
        let prior = target.needs.filter { $0.priority == "required" }
        guard prior.allSatisfy({ $0.groups.count < 2 }) else { throw ClientError.invalidResponse }
        let scopes = Set(prior.map(\.groupId))
        guard !scopes.contains(nil) || (scopes.count == 1 && target.needs.allSatisfy({ $0.priority == "required" })) else {
            throw ClientError.invalidResponse
        }
        var accounted = Set<UUID>()
        for ingredient in recipe.ingredients {
            guard let input = ingredient.quantity, let row = review.ingredients.first(where: { $0.ingredientId == ingredient.id }) else {
                throw ClientError.invalidResponse
            }
            let groups = ingredient.groupIds ?? []
            let parts: [UUID?] = mapping.isEmpty ? Array(scopes) : (groups.isEmpty ? [nil] : groups.map(Optional.some))
            guard parts.count <= 1 || mapping.isEmpty || ingredient.bindings?.count == parts.count else { throw ClientError.invalidResponse }
            for part in parts {
                let group = part.flatMap { id in mapping.isEmpty ? target.groups.first(where: { $0.id == id }) : mapping[id] }
                let sourceGroup = recipe.groups?.first(where: { $0.id == part })
                let restrictions = recipe.exclusions + ingredient.exclusions + (sourceGroup?.exclusions ?? [])
                let binding = ingredient.bindings?.first(where: { $0.groupId == part })
                guard ingredient.bindings?.isEmpty != false || binding != nil else { throw ClientError.invalidResponse }
                let basis = binding?.quantity ?? input
                let servings = group?.servings ?? .init(numerator: target.portions)
                let expected = mapping.isEmpty ? fraction(input.amount).multiplied(by: fraction(servings)).multiplied(by: .init(numerator: "1", denominator: String(recipe.portions))) : fraction(basis.amount)
                let matches = next.needs.filter { need in
                    guard !accounted.contains(need.id), need.groupId == group?.id, need.name == ingredient.name, need.notes == ingredient.notes,
                          let quantity = need.quantity, quantity.unit == basis.unit,
                          fraction(quantity.amount).compare(expected) == .orderedSame, Set(need.exclusions).isSuperset(of: restrictions) else { return false }
                    let amount = quantity.amount
                    let literal = amount.denominator == 1 ? String(amount.numerator) : "\(amount.numerator)/\(amount.denominator)"
                    let unchanged = expected.compare(fraction(basis.amount)) == .orderedSame
                    guard quantity.originalLiteral == (unchanged ? basis.originalLiteral : literal + " " + basis.unit) else { return false }
                    return group?.protected == true ? need.priority == "protected" && need.sources == Set(row.sourceIds) :
                        need.priority == "required" && need.ingredientId == ingredient.id && need.matchedSourceIds == row.sourceIds && need.foodId == nil
                }
                guard let need = matches.first else { throw ClientError.invalidResponse }
                accounted.insert(need.id)
                if need.priority == "required" {
                    guard scopes.contains(group?.id), !conflicts(need, with: ingredient.name, tags: []) else { throw ClientError.invalidResponse }
                    for source in page.sourceOptions where row.sourceIds.contains(source.id) {
                        guard !conflicts(need, with: source.name, tags: source.exclusionTags) else { throw ClientError.invalidResponse }
                    }
                }
            }
        }
        guard accounted.isSuperset(of: next.needs.filter { $0.priority == "required" }.map(\.id)) else { throw ClientError.invalidResponse }
    }
    func fraction(_ value: SharedMealAmount) -> SharedDeliveryCoverage.Fraction {
        .init(numerator: String(value.numerator), denominator: String(value.denominator))
    }
}

private extension SharedFallbackOptions.Option {
    struct PackGap {
        let ingredientId: UUID
        let offer: SharedFallbackOffer
        var gap: SharedDeliveryCoverage.Fraction
    }

    func validateEstimate(page: SharedRecoveryPage, now: Date, trip: SharedFallbackTrip?) throws {
        let meal = intent.replacement
        let meals = page.meals.map { $0.id == meal.id ? meal : $0 }
        let projection = SharedRecoveryPreview.Projection(meals: meals, demands: after.demands, allocations: after.allocations)
        try projection.validate(page: page, asOf: now)
        guard let review = intent.fallback?.review, let elapsed = meal.remainingElapsedMinutes, let due = householdTimestamp(meal.due),
              elapsed >= (meal.requiredLeadMinutes ?? 0) || meal.advanceStepsCompleted else { throw ClientError.invalidResponse }
        let demands = Dictionary(uniqueKeysWithValues: after.demands.map { ($0.id, $0) })
        var packs = [UUID: PackGap](), sourcePacks = [UUID: UUID]()
        func addGap(_ need: SharedRecoveryNeed, gap: SharedDeliveryCoverage.Fraction, key: UUID, offer: SharedFallbackOffer) throws {
            guard let q = need.quantity, let factor = DeliveryUnit.convert(.init(amount: .init(numerator: 1), unit: q.unit, originalLiteral: "1"),
                                                                           to: offer.usablePerPack.unit) else { throw ClientError.invalidResponse }
            let part = gap.multiplied(by: factor)
            if var previous = packs[key] {
                guard previous.offer == offer else { throw ClientError.invalidResponse }
                previous.gap = previous.gap.adding(part)
                packs[key] = previous
            } else {
                packs[key] = .init(ingredientId: need.ingredientId, offer: offer, gap: part)
            }
        }
        for need in meal.needs {
            guard let demand = demands[need.id], let gap = demand.shortfall, demand.sourceIssues.isEmpty else { throw ClientError.invalidResponse }
            if need.priority == "protected" { continue }
            guard let row = review.ingredients.first(where: { $0.ingredientId == need.ingredientId }),
                  demand.issues.allSatisfy({ $0 == "unknown_food" && row.sourceIds.isEmpty }) else { throw ClientError.invalidResponse }
            if gap.numerator == "0" { continue }
            guard let offer = row.offer, trip != nil, !conflicts(need, with: offer.label, tags: offer.exclusionTags) else { throw ClientError.invalidResponse }
            let key = offer.packId ?? need.ingredientId
            try addGap(need, gap: gap, key: key, offer: offer)
            for source in row.sourceIds {
                if let other = sourcePacks.updateValue(key, forKey: source), other != key { throw ClientError.invalidResponse }
            }
        }
        let selected = Set(meal.needs.filter { $0.priority == "required" }.map(\.id))
        for need in meals.flatMap(\.needs) where !selected.contains(need.id) {
            let keys = Set(need.sources.compactMap { sourcePacks[$0] })
            if keys.isEmpty {
                if meal.needs.contains(where: { $0.id == need.id && $0.priority == "protected" }) {
                    guard let demand = demands[need.id], demand.issues.isEmpty, demand.shortfall?.numerator == "0" else { throw ClientError.invalidResponse }
                }
                continue
            }
            guard let demand = demands[need.id], demand.issues.isEmpty, let gap = demand.shortfall else { throw ClientError.invalidResponse }
            if gap.numerator == "0" { continue }
            guard keys.count == 1, let key = keys.first, let offer = packs[key]?.offer else { throw ClientError.invalidResponse }
            try addGap(need, gap: gap, key: key, offer: offer)
        }
        guard buys.count == packs.count, unique(buys.map(\.ingredientId)) else { throw ClientError.invalidResponse }
        var totalPacks = 0, totalPrice = 0
        for pack in packs.values {
            let offer = pack.offer
            guard let buy = buys.first(where: { $0.ingredientId == pack.ingredientId }), buy.label == offer.label,
                  buy.packs > 0, buy.packs <= offer.availablePacks, buy.subtotalMinor == buy.packs * offer.priceMinor else { throw ClientError.invalidResponse }
            let yield = fraction(offer.usablePerPack.amount)
            func purchased(_ count: Int) -> SharedDeliveryCoverage.Fraction {
                yield.multiplied(by: .init(numerator: String(count), denominator: "1"))
            }
            guard purchased(buy.packs).compare(pack.gap) != .orderedAscending,
                  purchased(buy.packs - 1).compare(pack.gap) == .orderedAscending else { throw ClientError.invalidResponse }
            totalPacks += buy.packs
            totalPrice += buy.subtotalMinor
        }
        let travel = totalPacks > 0
        guard packCount == totalPacks, merchandiseMinor == totalPrice, kind == (travel ? "topUp" : "onHand"),
              intent.proposesExtraTrip == travel, currency == (travel ? trip?.currency : nil),
              extraCashMinor == totalPrice + (travel ? trip?.chargesMinor ?? 0 : 0),
              !travel || extraCashMinor <= (trip?.budgetMinor ?? 0),
              minutes == elapsed + (travel ? trip?.minutes ?? 0 : 0),
              now.addingTimeInterval(Double(minutes) * 60) <= due else { throw ClientError.invalidResponse }
    }
}

extension SharedFallbackOptions.Option {
    func validateRetainedCoverage(_ coverage: SharedRecoveryCoverage) throws {
        let demands = Dictionary(uniqueKeysWithValues: after.demands.map { ($0.id, $0) })
        for row in coverage.needs {
            guard let new = demands[row.needId] else { continue }
            guard new.reservations == row.reservations,
                  row.covered.map({ prior in new.allocated.map { $0.compare(prior) != .orderedAscending } ?? false }) ?? (new.allocated == nil)
            else { throw ClientError.invalidResponse }
        }
    }
}
