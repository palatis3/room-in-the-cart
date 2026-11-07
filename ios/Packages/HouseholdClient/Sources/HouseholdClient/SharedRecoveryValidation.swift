import Foundation

private func distinct<T: Hashable>(_ list: [T]) -> Bool { Set(list).count == list.count }
private func digestSyntax(_ digest: String) -> Bool {
    digest.utf8.count == 64 && digest.utf8.allSatisfy { (48...57).contains($0) || (97...102).contains($0) }
}

extension SharedRecoveryPage {
    func validate(delivery: SharedDeliveryPage, pantry: SharedPantryPage) throws {
        try pantry.validate(delivery: delivery)
        guard shopId == delivery.shopId, placedRevision == delivery.placedRevision, base.shopRevision == delivery.shopRevision,
              base.recoveryRevision == delivery.recoveryRevision, base.authorityEpoch == delivery.authorityEpoch, base.supplyRevision == delivery.supplyRevision, base.pantryRevision == pantry.pantryRevision else {
            throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
        }
        let ids = meals.map(\.id)
        guard base.recoveryRevision >= 0, base.contextRevision >= 0, validHelperTimestamp(asOf),
              distinct(ids), distinct(meals.map(\.revisionId)), distinct(meals.flatMap { $0.needs.map(\.id) }),
              distinct(targetDigests.map(\.occurrenceId)), distinct(mealSources.map(\.occurrenceId)),
              Set(targetDigests.map(\.occurrenceId)) == Set(ids), Set(mealSources.map(\.occurrenceId)) == Set(ids),
              distinct(sourceOptions.map(\.id)), distinct(unplannedOccurrenceIds),
              Set(unplannedOccurrenceIds) == Set(meals.filter { $0.needs.isEmpty }.map(\.id)),
              commitmentInventoryComplete == unplannedOccurrenceIds.isEmpty else { throw ClientError.invalidResponse }
        // A delivery stored and selected in this shop is the same physical option.
        var stock: [UUID: (String, [String], String, SharedMealQuantity?)] = [:]
        for source in delivery.sources { stock[source.id] = (source.foodName, source.exclusionTags, "delivery", source.confirmed?.quantity) }
        for lot in pantry.lots where lot.selected { stock[lot.id] = (lot.foodName, lot.exclusionTags, lot.location, lot.observation?.quantity) }
        guard stock.count == sourceOptions.count else { throw ClientError.invalidResponse }
        for option in sourceOptions {
            guard let (name, exclusions, kind, quantity) = stock[option.id], name == option.name, exclusions == option.exclusionTags,
                  kind == option.kind, quantity == option.quantity, option.quantity?.validStockQuantity != false else { throw ClientError.invalidResponse }
        }
        let options = Set(sourceOptions.map(\.id))
        for meal in meals {
            guard let sealed = delivery.meals?.first(where: { $0.id == meal.id }),
                  meal.sourceMealRevision == sealed.revision, meal.day == sealed.meal.day, meal.portions == sealed.meal.portions,
                  let provenance = mealSources.first(where: { $0.occurrenceId == meal.id }), provenance.sourceMealRevision == sealed.revision,
                  (base.recoveryRevision > 0 || provenance.sealedRevisionId == meal.revisionId),
                  provenance.completedSteps == (sealed.meal.planning?.completedSteps ?? []),
                  provenance.sourceOccurrenceId.map({ $0 != meal.id && ids.contains($0) && $0 == sealed.meal.planning?.sourceOccurrenceId }) ?? true,
                  provenance.approvedIdea.map({ $0.revision > 0 }) ?? true,
                  try targetDigests.first(where: { $0.occurrenceId == meal.id })?.digest == meal.targetDigest() else { throw ClientError.invalidResponse }
            try meal.validate(options: options)
        }
    }
}

private extension SharedRecoveryMeal {
    func validate(options: Set<UUID>) throws {
        let groupIDs = groups.map(\.id)
        guard sharedMealText(title, 240), notes.utf8.count <= 8192, (sourceURL?.utf8.count ?? 0) <= 2048,
              day.utf8.count == 10, (1...1000).contains(portions), sourceMealRevision > 0, template == nil,
              zone.map({ TimeZone(identifier: $0) != nil }) ?? true, due.map(validHelperTimestamp) ?? true,
              (0...1_000_000).contains(remainingElapsedMinutes ?? 0), (0...1_000_000).contains(requiredLeadMinutes ?? 0),
              exclusions.count <= 20, exclusions.allSatisfy({ sharedMealText($0, 240) }),
              groups.count <= 30, distinct(groupIDs), needs.count <= 260, distinct(needs.map(\.id)) else { throw ClientError.invalidResponse }
        for group in groups {
            guard sharedMealText(group.name, 240), (try? group.servings.validate()) != nil, group.exclusions.count <= 20,
                  group.exclusions.allSatisfy({ sharedMealText($0, 240) }) else { throw ClientError.invalidResponse }
        }
        for need in needs {
            let selected = groups.filter { need.groups.contains($0.id) }
            guard sharedMealText(need.name, 240), need.notes.utf8.count <= 8192,
                  need.groupIds == nil || (need.groupId == nil && need.groups.count != 1), distinct(need.groups),
                  selected.count == need.groups.count, ["protected","required"].contains(need.priority), need.due == due,
                  need.groups.isEmpty || selected.contains(where: \.protected) == (need.priority == "protected"),
                  need.quantity.map({ $0.validStockQuantity && $0.amount.numerator > 0 }) ?? true,
                  need.exclusions.count <= 60, need.exclusions.allSatisfy({ sharedMealText($0, 240) }),
                  Set(need.exclusions).isSuperset(of: exclusions + selected.flatMap(\.exclusions)),
                  distinct(need.matchedSourceIds ?? []), options.isSuperset(of: need.sources),
                  need.foodId.map(options.contains) ?? true else { throw ClientError.invalidResponse }
        }
    }
}

extension SharedRecoveryIntent {
    func validate(page: SharedRecoveryPage) throws {
        let next = replacement
        guard validHelperTimestamp(reviewedAt), let old = page.meals.first(where: { $0.id == occurrenceId }),
              targetDigest == page.targetDigests.first(where: { $0.occurrenceId == occurrenceId })?.digest,
              next.id == old.id, next.sourceMealRevision == old.sourceMealRevision,
              !page.meals.contains(where: { $0.revisionId == next.revisionId }), next.portions == old.portions, next.day == old.day,
              next.zone == old.zone, next.due == old.due, next.groups == old.groups,
              Set(next.exclusions).isSuperset(of: old.exclusions),
              next.needs.filter({ $0.priority == "protected" }) == old.needs.filter({ $0.priority == "protected" }),
              repeatOfOccurrenceId.map({ id in page.meals.contains { $0.id == id } }) ?? true else { throw ClientError.configuration }
        let newRows = next.needs.filter { $0.priority == "required" }, removed = old.needs.filter { $0.priority == "required" }
        guard !removed.isEmpty, !newRows.isEmpty, Set(newRows.map(\.id)).isDisjoint(with: page.meals.flatMap { $0.needs.map(\.id) }) else {
            throw ClientError.configuration
        }
        try next.validate(options: Set(page.sourceOptions.map(\.id)))
    }

    public func commandBody(reviewed page: SharedRecoveryPage, preview: SharedRecoveryPreview? = nil) throws -> [String: JSONValue] {
        try validate(page: page)
        var body: [String: JSONValue] = ["v": .integer(1), "base": try JSONDecoder().decode(JSONValue.self, from: encoded(page.base)),
                                         "intent": try JSONDecoder().decode(JSONValue.self, from: encoded(self))]
        if let preview {
            try preview.validate(page: page, intent: self)
            guard preview.consentSatisfied else { throw ClientError.configuration }
            body["previewId"] = .string(preview.previewId.uuidString.lowercased()); body["previewDigest"] = .string(preview.previewDigest)
        }
        return body
    }
}

extension SharedRecoveryPreview {
    func validate(page: SharedRecoveryPage, intent: SharedRecoveryIntent) throws {
        guard shopId == page.shopId, placedRevision == page.placedRevision, base == page.base,
              let now = householdTimestamp(asOf), let expires = householdTimestamp(expiresAt), expires > now,
              let reviewed = householdTimestamp(intent.reviewedAt), reviewed <= now, digestSyntax(previewDigest) else { throw ClientError.invalidResponse }
        let expected = page.meals.map { $0.id == intent.occurrenceId ? intent.replacement : $0 }
        // Compare digests to preserve the exact Unicode wording the shopper reviewed.
        guard try before.meals.map({ try $0.targetDigest() }) == page.meals.map({ try $0.targetDigest() }),
              try after.meals.map({ try $0.targetDigest() }) == expected.map({ try $0.targetDigest() }) else { throw ClientError.invalidResponse }
        try before.validate(options: page.sourceOptions, asOf: now)
        try after.validate(options: page.sourceOptions, asOf: now)
        let targetNeeds = Set(intent.replacement.needs.map(\.id))
        let complete = page.commitmentInventoryComplete && after.demands.filter { targetNeeds.contains($0.id) }.allSatisfy {
            $0.shortfall?.numerator == "0" && $0.issues.isEmpty
        }
        let meal = intent.replacement
        var timely = false
        if let due = householdTimestamp(meal.due), let minutes = meal.remainingElapsedMinutes {
            timely = now.addingTimeInterval(Double(minutes) * 60) <= due &&
                (meal.requiredLeadMinutes == nil || minutes >= (meal.requiredLeadMinutes ?? 0) || meal.advanceStepsCompleted)
        }
        func titleKey(_ title: String) -> String {
            title.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ").lowercased()
        }
        let repeated = intent.repeatOfOccurrenceId != nil || page.meals.contains { $0.id != meal.id && titleKey($0.title) == titleKey(meal.title) }
        guard foodConfirmed == complete, timingConfirmed == timely, repeatRequired == repeated,
              feasible == (complete && timely), consentSatisfied == ((!repeatRequired || intent.agreesToRepeat) &&
                (!intent.proposesExtraTrip || intent.agreesToExtraTrip) && (feasible || intent.acceptsUnresolved)) else { throw ClientError.invalidResponse }
    }
}

extension SharedRecoveryPreview.Projection {
    func validate(options: [SharedRecoveryPage.SourceOption], asOf: Date) throws {
        let needs = meals.flatMap(\.needs), grouped = Dictionary(grouping: allocations, by: \.needId)
        let sources = Dictionary(options.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let ids = Set(needs.map(\.id))
        guard distinct(demands.map(\.id)), Set(demands.map(\.id)) == ids, ids.isSuperset(of: grouped.keys) else { throw ClientError.invalidResponse }
        var used = [UUID: SharedDeliveryCoverage.Fraction]()
        for demand in demands {
            guard let need = needs.first(where: { $0.id == demand.id }), demand.due == need.due, demand.unit == need.quantity?.unit,
                  demand.deadlineStatus == (householdTimestamp(need.due).map { $0 < asOf ? "pastDue" : "notPastDue" } ?? "unknown"),
                  distinct(demand.sourceIssues.map(\.sourceId)), demand.sourceIssues.allSatisfy({ need.sources.contains($0.sourceId) }),
                  distinct(demand.reservations.map(\.sourceId)), distinct(demand.reservations.map(\.reservationId)) else { throw ClientError.invalidResponse }
            let rows = grouped[demand.id] ?? []
            guard let required = need.quantity else {
                guard demand.allocated == nil, demand.shortfall == nil, rows.isEmpty, demand.reservations.isEmpty else { throw ClientError.invalidResponse }
                continue
            }
            guard let allocated = demand.allocated, allocated.valid, let missing = demand.shortfall, missing.valid,
                  let exact = DeliveryUnit.convert(required, to: required.unit), allocated.adding(missing).compare(exact) == .orderedSame,
                  distinct(rows.map(\.sourceId)) else { throw ClientError.invalidResponse }
            var total = SharedDeliveryCoverage.Fraction.zero
            for row in rows {
                guard row.unit == required.unit, row.amount.valid, row.amount.numerator != "0", need.sources.contains(row.sourceId),
                      !demand.sourceIssues.contains(where: { $0.sourceId == row.sourceId }), let quantity = sources[row.sourceId]?.quantity,
                      let factor = DeliveryUnit.convert(.init(amount: .init(numerator: 1), unit: row.unit, originalLiteral: "1"), to: quantity.unit) else {
                    throw ClientError.invalidResponse
                }
                total = total.adding(row.amount)
                used[row.sourceId] = (used[row.sourceId] ?? .zero).adding(row.amount.multiplied(by: factor))
            }
            guard total.compare(allocated) == .orderedSame else { throw ClientError.invalidResponse }
            for pin in demand.reservations {
                guard need.sources.contains(pin.sourceId), pin.requested.valid, pin.backed.valid,
                      pin.backed.compare(pin.requested) != .orderedDescending,
                      pin.backed.compare(rows.first(where: { $0.sourceId == pin.sourceId })?.amount ?? .zero) != .orderedDescending else { throw ClientError.invalidResponse }
            }
        }
        for (id, amount) in used {
            guard let stock = sources[id]?.quantity, let exact = DeliveryUnit.convert(stock, to: stock.unit),
                  amount.compare(exact) != .orderedDescending else { throw ClientError.invalidResponse }
        }
    }
}
