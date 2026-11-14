import Foundation
import CoreDomain

@MainActor enum LedgerReadableRecord {
    static func text(_ data: Data) throws -> String {
        let workspace = try RecordsNativeCodec.ledger(data)
        var sections = try workspace.shops.map { try shoppingList($0, in: workspace) }
        // A shop projection can contain supporting versions of its chosen dinners.
        // The separate library selection is where templates, drafts and rotations belong.
        if workspace.shops.isEmpty {
            let library = workspace.dinnerPlanning
            for meal in workspace.mealTemplates {
                sections.append([ledgerText("Usual dinner")] + template(meal))
            }
            for dinner in library.acceptedDinners {
                var lines = [dinnerText("Accepted dinner") + " · " + stamp(dinner.acceptedAt)]
                if dinner.acceptedFallback { lines.append(dinnerText("Accepted fallback")) }
                if dinner.id == library.freeReusableDinnerID { lines.append(ledgerText("Your reusable dinner")) }
                sections.append(lines + template(dinner.template))
            }
            let accepted = Dictionary(uniqueKeysWithValues: library.acceptedDinners.map { ($0.id, $0.template) })
            for rotation in library.rotations {
                var lines = [dinnerText("Rotations") + " · " + rotation.title]
                for entry in rotation.entries {
                    let meal = accepted[entry.acceptedDinnerID]
                    let day = entry.dayOffset.map { dinnerFormat("Day %d", $0 + 1) } ?? dinnerText("Unscheduled")
                    lines.append(joined([day, meal?.title ?? dinnerText("Unavailable dinner"),
                                         meal.map { revision($0.revision) } ?? "", entry.pinned ? dinnerText("Pinned") : ""]))
                }
                sections.append(lines)
            }
            for idea in library.ideas {
                var lines = [dinnerText("Saved idea drafts") + " · " + stamp(idea.createdAt)] + template(idea.template)
                if !idea.assumptions.isEmpty { lines += [dinnerText("Review assumptions")] + idea.assumptions }
                if !idea.hardExclusions.isEmpty { lines.append(exclusions(idea.hardExclusions)) }
                lines += [dinnerText(idea.yieldConfirmed ? "Usable yield reviewed" : "Usable yield is unconfirmed"),
                          dinnerText(idea.availabilityConfirmed ? "Availability reviewed" : "Availability is unconfirmed")]
                // The library contains original observations, but not the current shop's lots or balances.
                for row in idea.supplyEvidence ?? [] {
                    lines += [joined([dinnerText("Stock and whole packs"), row.ingredientName]),
                              row.foodID == nil ? dinnerText("No confirmed match") : ledgerText("Food match saved. Available quantity in this record is unknown.")]
                    if let pack = row.pack {
                        lines += [pack.label, dinnerFormat("Usable in one pack: %@", quantity(pack.usableQuantity)),
                                  field(dinnerText("Price per pack in USD"), dinnerMoney(pack.price))]
                        if let basis = pack.confirmedConversion { lines.append(conversion(basis)) }
                    }
                    if let source = row.source { lines.append(field(dinnerText("Evidence source"), source)) }
                    if let date = row.observedAt { lines.append(field(dinnerText("Observed at"), stamp(date))) }
                }
                sections.append(lines)
            }
        }
        return sections.map { $0.joined(separator: "\n") }.joined(separator: "\n\n")
    }

    private static func shoppingList(_ shop: ShoppingLedger, in workspace: LedgerWorkspace) throws -> [String] {
        let basis = shop.basis
        var lines = [joined([shop.title, revision(shop.revision)]),
                     joined([basis.mode.ledgerLabel, basis.branch, basis.slot.map { ledgerDate($0, zone: basis.timeZoneIdentifier) } ?? ledgerText("Date not set")])]
        if let cap = basis.cap {
            lines.append(joined([ledgerText("Spending cap"), dinnerMoney(cap), basis.capScope.ledgerLabel,
                                 ledgerText(basis.capFirmness == .firm ? "Firm limit" : "Flexible limit")]))
        }
        if let reserve = basis.fixedReserve { lines.append(ledgerFormat("Fixed reserve: %@", dinnerMoney(reserve))) }
        if let fees = basis.knownFees { lines.append(ledgerFormat("Fees: %@", dinnerMoney(fees))) }
        if let preview = basis.retailerPreview {
            lines.append(joined([ledgerFormat("Retailer preview: %@", dinnerMoney(preview.total)), preview.source,
                                 ledgerDate(preview.capturedAt, zone: basis.timeZoneIdentifier)]))
            if !preview.includedCharges.isEmpty { lines.append(ledgerFormat("Included charges: %@", preview.includedCharges.joined(separator: ", "))) }
        }

        let contributions = Dictionary(grouping: shop.contributions, by: \.lineID)
        let allocations = Dictionary(grouping: shop.allocations, by: \.demandContributionID)
        let active = workspace.listLayout.groups(shop: shop).flatMap(\.lines)
        lines += ["", ledgerText("Active items")]
        if active.isEmpty { lines.append(ledgerText("Nothing here yet.")) }
        let history = shop.lines.filter { $0.isChecked || $0.isHandled || $0.isTrashed }.sorted { $0.originalOrder < $1.originalOrder }
        for (heading, entries) in [("", active), (ledgerText("List history"), history)] {
            if !entries.isEmpty && !heading.isEmpty { lines += ["", heading] }
            for line in entries {
                let total = try shop.quantity(forLineID: line.id)
                lines.append(joined(["• " + line.name, total.map { pQuantity($0) } ?? ledgerText("Quantity unresolved"), line.aisle]))
                if let date = line.checkedAt { lines.append(joined([ledgerText("Checked at"), stamp(date)])) }
                if let date = line.handledAt {
                    lines.append(joined([line.handledBy.map { ledgerFormat("Handled by %@", $0) } ?? ledgerText("Handled"), stamp(date)]))
                }
                if let date = line.trashedAt { lines.append(joined([ledgerText("Trash"), stamp(date)])) }
                if !line.notes.isEmpty { lines.append(line.notes) }
                for entry in contributions[line.id] ?? [] {
                    var details = [ledgerSourceLabel(entry, shop: shop), entry.productName, quantity(entry.quantity)]
                    if let removed = entry.removedAt { details.append(joined([ledgerText("Removed"), stamp(removed)])) }
                    lines.append("  " + joined(details))
                    if !entry.originalText.isEmpty && entry.originalText != entry.quantity?.originalLiteral && entry.originalText != entry.productName {
                        lines.append(field(ledgerText("Original wording"), entry.originalText))
                    }
                    if let pack = entry.originalPack {
                        if let count = pack.count { lines.append(ledgerFormat("Packs on the original label: %lld", Int64(count))) }
                        lines.append(ledgerFormat("Amount per pack on the original label: %@", quantity(pack.amountPerPack)))
                    }
                    if !entry.notes.isEmpty && entry.notes != line.notes { lines.append(ledgerContributionNote(entry.notes)) }
                    if !entry.exclusions.isEmpty { lines.append(exclusions(entry.exclusions)) }
                    if let capture = entry.capture {
                        if !capture.purpose.isEmpty { lines.append(field(ledgerText("Purpose"), capture.purpose)) }
                        if !capture.destination.isEmpty { lines.append(field(ledgerText("Destination"), capture.destination)) }
                    }
                    for link in allocations[entry.id] ?? [] where link.kind == .withinExisting {
                        lines.append(ledgerFormat("Linked within existing quantity: %@", pQuantity(link.quantity)))
                    }
                }
            }
        }
        let names = Dictionary(uniqueKeysWithValues: shop.lines.map { ($0.id, $0.name) })
        for batch in shop.importBatches {
            lines += ["", joined([ledgerText("Imported list"), stamp(batch.createdAt)])]
            if let undone = batch.undoneAt { lines.append(joined([ledgerText("Import undone"), stamp(undone)])) }
            if let original = batch.originalSelection {
                lines.append(field(ledgerText("Original wording"), original))
            }
            for entry in batch.preview.lines {
                let decision: String
                switch batch.decisions[entry.id] ?? .addNew {
                case .addNew: decision = ledgerText("Added as a separate line")
                case .addToLine(let id): decision = ledgerFormat("Added to %@", names[id] ?? entry.name)
                case .mergeDuplicate(let id): decision = ledgerFormat("Merged as the same need: %@", names[id] ?? entry.name)
                case .skip: decision = ledgerText("Skipped")
                }
                lines.append(joined([entry.originalText, decision]))
            }
        }
        let ingredientNames = Dictionary(uniqueKeysWithValues: shop.contributions.map { ($0.id, $0.productName) })
        let bindings = Dictionary(grouping: workspace.dinnerPlanning.portionBindings, by: \.occurrenceID)
        for meal in shop.mealOccurrences {
            lines += ["", joined([ledgerText("Dinner for this pickup"), meal.title]),
                      meal.scheduledDay.map(ledgerMealDay) ?? ledgerText("Unscheduled")]
            if let removed = meal.removedAt { lines.append(joined([ledgerText("Removed"), stamp(removed)])) }
            if meal.isHidden { lines.append(ledgerText("Hidden from the ordinary view")) }
            lines += mealFacts(servings: meal.servings, groups: meal.servingGroups, notes: meal.notes, exclusions: meal.exclusions,
                               leadTime: meal.leadTimeMinutes, steps: meal.completedSteps, source: meal.sourceURL, evidence: meal.sourceEvidence)
            let groups = Dictionary(uniqueKeysWithValues: meal.servingGroups.map { ($0.id, $0) })
            for binding in bindings[meal.id] ?? [] {
                if let group = groups[binding.groupID], let name = ingredientNames[binding.contributionID] {
                    lines.append(joined([name, group.name, quantity(binding.quantity)]))
                }
            }
        }
        for protected in workspace.dinnerPlanning.protectedDays where protected.shopID == shop.id {
            if let name = ingredientNames[protected.contributionID], let day = protected.day {
                lines.append(joined([ledgerText("Protected"), name, ledgerMealDay(day)]))
            }
        }
        for note in workspace.dinnerPlanning.weekNotes where note.shopID == shop.id {
            lines.append(joined([ledgerMealDay(note.day), dinnerNoteKind(note.kind), note.text]))
        }
        for selection in workspace.packSelections where selection.shopID == shop.id {
            let offer = selection.selectedOfferID == selection.request.offerA.id ? selection.request.offerA : selection.request.offerB
            lines += ["", joined([selection.request.itemName, ledgerFormat("Reviewed pack choice: %@", offer.label)]),
                      joined([selection.source, stamp(selection.reviewedAt)])]
            if selection.isNoPurchase { lines.append(ledgerText("Use confirmed food at home · no purchase needed")) }
            if !selection.isNoPurchase, let basis = offer.confirmedConversion {
                lines.append(ComparisonConversion.readableText(for: basis))
            }
            if let packs = selection.selectedResult.packsToBuy { lines.append(field(ledgerText("Whole packs to buy"), String(packs))) }
            if let price = selection.selectedResult.totalCost { lines.append(ledgerFormat("Item cost: %@", dinnerMoney(price))) }
        }
        let planning = workspace.dinnerPlanning
        for pair in planning.quotePairs where pair.shopID == shop.id {
            let result = try TwoStoreQuoteEngine.evaluateEnteredQuotes(pair)
            lines += ["", dinnerText("Reviewed trip comparison"), dinnerText("These are entered observations, not live prices or stock.")]
            if pair.baseRevisionID != shop.revisionID || pair.basisRevision != shop.basisRevision {
                lines.append(dinnerText("This saved comparison uses an earlier pickup revision. Review the store options again to change the current pickup."))
            }
            lines += try quoteOption(pair.first, result: result.first)
            lines += try quoteOption(pair.second, result: result.second)
            lines += [dinnerFormat("Items before fees and discounts, second minus first: %@", dinnerMoney(result.itemSubtotalChange)),
                      dinnerFormat("Checkout change, second minus first: %@", dinnerMoney(result.checkoutChange)),
                      dinnerFormat("Checkout plus trip cash, second minus first: %@", dinnerMoney(result.tripCashChange))]
            if let minutes = result.extraMinutesChange { lines.append(dinnerFormat("Extra minutes change: %d", minutes)) }
            if let amount = result.secondTripCashBreakEven { lines.append(dinnerFormat("Second trip cash break-even: %@", dinnerMoney(amount))) }
            lines += result.issues.map(dinnerIssue)
        }
        let receipts = planning.applyReceipts.filter { $0.proposal.shopID == shop.id }
        let applied = Set(receipts.map(\.id))
        let proposals = planning.proposals.filter { $0.shopID == shop.id && !applied.contains($0.id) }
        let meals = Dictionary(uniqueKeysWithValues: shop.mealOccurrences.map { ($0.id, $0.title) })
        for proposal in proposals { lines += proposalFacts(proposal, meals: meals, quotes: planning.quotePairs) }
        for receipt in receipts {
            lines += proposalFacts(receipt.proposal, meals: meals, quotes: planning.quotePairs)
            lines.append(joined([ledgerText("Applied by"), receipt.appliedBy, stamp(receipt.appliedAt)]))
        }
        return lines
    }

    private static func quoteOption(_ option: StoreQuoteOption, result: StoreQuoteResult) throws -> [String] {
        var lines = ["", option.label, field(dinnerText("Observed at"), stamp(option.quote.context.observedAt))]
        lines += try PickupReadableRecord.quoteLines(option.quote, cap: option.cap, locale: recordsInterfaceLocale)
        for item in option.commitments.commitments {
            let kind: String
            switch item.kind {
            case .dinner: kind = dinnerText("Dinner")
            case .lunch: kind = dinnerText("Lunch")
            case .side: kind = dinnerText("Side")
            case .staple: kind = dinnerText("Staple")
            }
            lines.append(joined([kind, item.name, ledgerFormat("Servings: %@", item.portions.description),
                                 item.protected ? ledgerText("Protected") : "", item.day.map(ledgerMealDay) ?? ""]))
        }
        if let terms = option.eligibilityTerms { lines.append(dinnerFormat("Price conditions: %@", terms)) }
        if let entered = option.unreviewedInclusiveTotal {
            lines.append(field(ledgerText("Entered total before reviewing included charges"), dinnerMoney(entered)))
        }
        lines.append(dinnerFormat("Items before fees and discounts: %@", dinnerMoney(try TwoStoreQuoteEngine.itemSubtotal(option))))
        lines.append(dinnerCap(result.checkout.cap))
        lines.append(field(dinnerText("Required product availability"), option.available.map { dinnerText($0 ? "Reviewed available" : "Unavailable") } ?? dinnerText("Unknown")))
        lines.append(field(dinnerText("All required quantities match the commitments"), ledgerText(option.quantitiesMatched ? "Yes" : "No")))
        lines.append(field(dinnerText("This is one complete store plan"), ledgerText(option.singleStore ? "Yes" : "No")))
        switch option.trip.incrementalCash {
        case .exact(let amount): lines.append(dinnerFormat("Incremental trip cash: %@", dinnerMoney(amount)))
        case let .bounded(lower, upper, reason):
            lines.append(joined([dinnerFormat("Incremental trip cash range: %@ to %@", dinnerMoney(lower), dinnerMoney(upper)), reason]))
        case .unknown(let reason):
            lines.append(joined([dinnerFormat("Incremental trip cash: %@", dinnerMoney(nil)), reason]))
        }
        lines.append(dinnerFormat("Checkout plus incremental trip cash: %@", dinnerMoney(result.tripInclusive.total.exact)))
        lines.append(result.extraMinutes.map { dinnerFormat("Extra minutes: %d", $0) } ?? field(ledgerText("Extra minutes"), dinnerText("Unknown")))
        lines.append(dinnerText(option.trip.tripAlreadyPlanned ? "Trip already planned" : "Additional trip"))
        return lines
    }

    private static func proposalFacts(_ proposal: DinnerProposal, meals: [UUID: String], quotes: [TwoStoreQuotePair]) -> [String] {
        var lines = ["", joined([ledgerText("Proposed by"), proposal.authorID, stamp(proposal.createdAt)])]
        if let choice = proposal.quoteSelection,
           let pair = quotes.first(where: { $0.id == choice.pairID && $0.shopID == proposal.shopID }),
           let option = [pair.first, pair.second].first(where: { $0.id == choice.optionID }) {
            lines.append(joined([dinnerText("Reviewed trip comparison"), option.label]))
        }
        for change in proposal.changes {
            switch change {
            case .choose(let chosen):
                lines.append(joined([chosen.template.title, chosen.day.map(ledgerMealDay) ?? ledgerText("Unscheduled")]))
            case .move(let id, let day):
                lines.append(joined([meals[id] ?? ledgerText("Dinner"), day.map(ledgerMealDay) ?? ledgerText("Unscheduled")]))
            case .adjust(let adjustment):
                lines.append(joined([meals[adjustment.occurrenceID] ?? ledgerText("Dinner"), ledgerFormat("Servings: %@", adjustment.servings.description)]))
            case .remove(let id): lines.append(joined([ledgerText("Remove dinner"), meals[id] ?? ledgerText("Dinner")]))
            case .reserve(let need):
                lines.append(joined([ledgerFormat("Protected: %@", need.purpose), need.name, quantity(need.quantity),
                                     need.day.map(ledgerMealDay) ?? ledgerText("Unscheduled")]))
            case .adoptBasis(let basis):
                lines.append(joined([ledgerText("Proposed pickup details"), basis.mode.ledgerLabel, basis.branch,
                                     basis.slot.map { ledgerDate($0, zone: basis.timeZoneIdentifier) } ?? ledgerText("Date not set")]))
            }
        }
        return lines
    }

    private static func template(_ meal: MealTemplate) -> [String] {
        var lines = [joined([meal.title, revision(meal.revision)])]
        lines += mealFacts(servings: meal.servings, groups: meal.servingGroups, notes: meal.notes, exclusions: meal.exclusions,
                           leadTime: meal.leadTimeMinutes, steps: meal.completedSteps, source: meal.sourceURL, evidence: meal.sourceEvidence)
        if !meal.ingredients.isEmpty { lines.append(ledgerText("Ingredients")) }
        for ingredient in meal.ingredients {
            lines.append(joined(["• " + ingredient.name, quantity(ingredient.quantity), ingredient.notes]))
            if !ingredient.exclusions.isEmpty { lines.append(exclusions(ingredient.exclusions)) }
        }
        return lines
    }

    private static func mealFacts(servings: Rational, groups: [ServingGroup], notes: String, exclusions excluded: [String],
                                  leadTime: Int?, steps: [String], source: String?, evidence: RecipeSourceEvidence?) -> [String] {
        var lines = [ledgerFormat("Servings: %@", servings.description)]
        for group in groups {
            lines.append(joined([group.name, ledgerFormat("Servings: %@", group.servings.description), group.isProtected ? ledgerText("Protected") : ""]))
        }
        if !notes.isEmpty { lines.append(notes) }
        if !excluded.isEmpty { lines.append(exclusions(excluded)) }
        if let leadTime { lines.append(field(ledgerText("Known elapsed lead time, minutes"), String(leadTime))) }
        if !steps.isEmpty { lines += [pTr("Steps already marked complete")] + steps }
        if let source, !source.isEmpty { lines.append(field(dinnerText("Evidence source"), source)) }
        if let evidence { lines.append(field(ledgerText("Original wording"), evidence.originalText)) }
        return lines
    }

    // Imported quantities may retain an entire label. Only append a unit directly to a numeric literal.
    private static func quantity(_ value: Quantity?) -> String {
        guard let value else { return ledgerText("Quantity unresolved") }
        let original = value.originalLiteral
        let amount: String
        if (try? ListQuantityParser.numericAmount(original)) == value.amount {
            amount = pQuantity(original, unit: value.unit, singular: value.amount == .one, language: nil)
        } else {
            amount = joined([pQuantity(value), original])
        }
        return joined([amount, value.confirmedConversion.map(conversion) ?? ""])
    }
    private static func conversion(_ basis: UnitBasis) -> String {
        joined([pQuantity(.one, unit: basis.sourceUnit) + " = " + pQuantity(basis.targetAmountPerSourceUnit, unit: basis.targetUnit), basis.sourceNote])
    }
    private static func exclusions(_ values: [String]) -> String { ledgerFormat("Exclusions: %@", values.joined(separator: ", ")) }
    private static func stamp(_ date: Date) -> String { dinnerStoreSlot(date, zoneID: TimeZone.current.identifier, locale: recordsInterfaceLocale) }
    private static func revision(_ value: Int) -> String { field(pTr("Revision"), String(value)) }
    private static func field(_ label: String, _ value: String) -> String { label + ": " + value }
    private static func joined(_ parts: [String]) -> String { parts.filter { !$0.isEmpty }.joined(separator: " · ") }
}
