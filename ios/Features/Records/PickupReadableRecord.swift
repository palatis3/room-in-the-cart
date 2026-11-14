import Foundation
import CoreDomain

/// A personal, read-only projection of one saved journey. Event dates come from
/// their own records. An offer deadline is not the date the shopper decided.
struct PickupReadableRecord {
    private let locale: Locale
    private var language: String { locale.identifier }
    private func pickupLabel(_ key: String) -> String { pCook(key, language: language) }
    private func date(_ value: Date, zone: TimeZone = .current) -> String {
        value.formatted(Date.FormatStyle(date: .abbreviated, time: .standard, locale: locale, timeZone: zone))
    }
    private func money(_ value: Money) -> String {
        (Decimal(value.minorUnits) / 100).formatted(.currency(code: value.currency.rawValue).locale(locale))
    }
    private func quantity(_ value: Quantity) -> String {
        let normalized = pQuantity(value, language: language)
        var text = normalized
        if !value.originalLiteral.isEmpty && value.originalLiteral != value.amount.description && value.originalLiteral != normalized {
            text += " (" + value.originalLiteral + ")"
        }
        if let basis = value.confirmedConversion {
            text += " · " + pQuantity(.one, unit: basis.sourceUnit, language: language) + " = "
                + pQuantity(basis.targetAmountPerSourceUnit, unit: basis.targetUnit, language: language)
            if !basis.sourceNote.isEmpty { text += " (" + basis.sourceNote + ")" }
        }
        return text
    }
    private func price(_ evidence: CostEvidence) -> String {
        switch evidence {
        case .exact(let amount): return money(amount)
        case let .bounded(low, high, reason): return money(low) + " – " + money(high) + " · " + reason
        case .unknown(let reason): return pickupLabel("Unknown price") + " · " + reason
        }
    }
    private func field(_ key: String, _ value: String) -> String { pickupLabel(key) + ": " + value }
    private func line(_ value: BasketLine) -> String {
        var facts = [value.name, quantity(value.quantity), price(value.expectedCost)]
        if let exclusions = value.itemExclusions {
            facts.append(field("Keep these exclusions", exclusions.joined(separator: ", ")))
        }
        return facts.joined(separator: " · ")
    }
    private func scope(_ value: CheckoutScope) -> String {
        switch value {
        case .wholeCheckout: return pickupLabel("Whole checkout")
        case .dinner: return pickupLabel("Dinners only")
        case .item: return pickupLabel("Selected items only")
        }
    }
    private func quote(_ value: CheckoutQuote, cap: CheckoutCap?) throws -> [String] {
        let context = value.context
        let mode: String
        switch context.mode {
        case .pickup: mode = pickupLabel("Pickup")
        case .delivery: mode = pickupLabel("Delivery")
        case .inStore: mode = pickupLabel("In store")
        }
        var rows = [[context.storeID, context.branchID, mode, context.slot].joined(separator: " · "),
                    field("Source of these prices", context.source), field("Scope", scope(value.scope))]
        if let cap { rows.append(field("Spending cap", money(cap.amount) + " · " + scope(cap.scope))) }
        else { rows.append(pickupLabel("No spending cap recorded with this quote")) }
        switch value.pricing {
        case .inclusiveTotal(let cost):
            rows.append(field("Retailer total already includes all charges", price(cost)))
        case let .components(lines, complete, fees, discounts, tax, deposits):
            rows.append(pickupLabel(complete ? "All original items are represented" : "Original items are not fully represented"))
            for item in lines {
                rows.append([item.name, price(item.cost), pickupLabel(item.thresholdEligible ? "Included in fee threshold" : "Excluded from fee threshold")].joined(separator: " · "))
            }
            for fee in fees {
                switch fee.rule {
                case .fixed(let cost): rows.append(field("Retailer fee", fee.id + " · " + price(cost)))
                case let .waivedAt(threshold, below, basis):
                    rows.append([field("Retailer fee", fee.id), field("Fee below threshold or fixed fee", price(below)),
                                 field("Fee waiver threshold", money(threshold)),
                                 pickupLabel(basis == .eligibleItemsBeforeDiscounts ? "Fee threshold uses eligible items before discounts" : "Fee threshold uses eligible items after eligible discounts")].joined(separator: " · "))
                }
            }
            for discount in discounts {
                rows.append([field("Discount", discount.id + " · " + price(discount.amount)),
                             pickupLabel(discount.reducesEligibleSubtotal ? "Discount reduces fee threshold subtotal" : "Discount does not reduce fee threshold subtotal")].joined(separator: " · "))
            }
            rows += [field("Tax", price(tax)), field("Deposits and other charges", price(deposits))]
        }
        let result = try CheckoutEngine.evaluate(value, cap: cap)
        let total = result.total
        let amount = total.exact.map(money) ?? total.upperBound.map { money(total.lowerBound) + " – " + money($0) }
            ?? (pickupLabel("At least") + " " + money(total.lowerBound) + " · " + pickupLabel("total unresolved"))
        rows.append(field("Saved checkout result", amount))
        switch result.cap {
        case .notProvided: break // Missing source cap is already labeled above.
        case .scopeMismatch: rows.append(pickupLabel("Cap and checkout cover different commitments"))
        case .unresolved: rows.append(pickupLabel("Whether this fits the cap is unresolved"))
        case .within(_, let remaining): rows.append(field("Within this scope’s cap · room remaining", money(remaining)))
        case .over(_, let overage): rows.append(field("Over this scope’s cap by", money(overage)))
        }
        return rows
    }

    static func quoteLines(_ value: CheckoutQuote, cap: CheckoutCap?, locale: Locale) throws -> [String] {
        try Self(locale: locale).quote(value, cap: cap)
    }

    static func text(_ journey: PickupJourney, locale: Locale) throws -> String {
        try Self(locale: locale).render(journey)
    }

    private func render(_ j: PickupJourney) throws -> String {
        var events: [(Date, String)] = []
        var current: [String] = []
        func reporter(_ actor: UUID?) -> String {
            field("Reported by", actor.map { pickupLabel("Original local shopper") + " · " + $0.uuidString }
                  ?? pickupLabel("Shopper not recorded"))
        }
        func event(_ at: Date, _ title: String, _ rows: [String] = []) {
            events.append((at, ([date(at) + " · " + title] + rows).joined(separator: "\n")))
        }
        func quoteEvidence(_ title: String, _ saved: CheckoutQuote, cap: CheckoutCap?) throws {
            let observed = saved.context.observedAt
            let header = [pickupLabel(title), field("Checkout evidence recorded at", date(observed))]
            events.append((observed, (header + (try quote(saved, cap: cap))).joined(separator: "\n")))
        }
        for prior in j.earlierQuotes {
            try quoteEvidence("Earlier checkout quote", prior.quote, cap: prior.cap)
        }
        if let saved = j.quote {
            try quoteEvidence("Saved checkout quote", saved, cap: j.cap)
        } else if j.basket != nil {
            var rows = [field("Current checkout", pickupLabel("Not confirmed"))]
            if let cap = j.cap { rows.append(field("Spending cap", money(cap.amount) + " · " + scope(cap.scope))) }
            current.append(rows.joined(separator: "\n"))
        }
        if let basket = j.basket {
            let revisions = Dictionary(basket.snapshots.map { ($0.id, $0.revision.number) }, uniquingKeysWith: { first, _ in first })
            for revision in basket.revisions {
                event(revision.createdAt, field("Basket revision", String(revision.number)), revision.lines.map(line))
            }
            for snapshot in basket.snapshots {
                var rows = [field("Revision", String(snapshot.revision.number))]
                if let frozen = j.frozenQuotes[snapshot.id] {
                    rows.append(field("Checkout evidence recorded at", date(frozen.context.observedAt)))
                    if let cap = j.frozenCaps?[snapshot.id.uuidString] {
                        rows += try quote(frozen, cap: cap)
                    } else if frozen != j.quote { rows += try quote(frozen, cap: nil) }
                    else { rows.append(pickupLabel("No spending cap recorded with this frozen copy")) }
                }
                event(snapshot.createdAt, pickupLabel("Frozen · placement unconfirmed"), rows)
            }
            for action in basket.handoffActions {
                var rows = [pickupLabel(action.kind.rawValue)]
                if let revision = revisions[action.snapshotID] { rows.append(field("Revision", String(revision))) }
                if let destination = action.destination { rows.append(destination) }
                event(action.occurredAt, pickupLabel("Retailer handoff"), rows)
            }
            for placed in basket.placements {
                event(placed.reportedAt, pickupLabel("Original placed order"),
                      [reporter(placed.reportedByLocalActorID)] + (basket.reportedOrderLines ?? []).map(line))
            }
            var previous = basket.reportedOrderLines ?? []
            for change in basket.amendments {
                var rows = [change.retailerReference, reporter(change.recordedByLocalActorID)]
                for delta in PickupAmendmentDelta.differences(from: previous, to: change.lines) {
                    if let before = delta.before { rows.append(field("Previously ordered", line(before))) }
                    if let after = delta.after { rows.append(field("Confirmed order line", line(after))) }
                    else { rows.append(pickupLabel("Removed from this order")) }
                }
                rows.append(pickupLabel("Recheck the amended checkout total with the retailer."))
                event(change.confirmedAt, pickupLabel("Confirmed by the retailer"), rows)
                previous = change.lines
            }
        }
        let orderNames = Dictionary((j.pickup?.orderLines ?? []).map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        if let pickup = j.pickup {
            let observations = Dictionary(grouping: pickup.usableObservations, by: \.receipt)
            for receipt in pickup.receipts {
                let segment = [receipt.key.branchID, receipt.key.sourceEventID, receipt.key.segmentID].joined(separator: " / ")
                var rows = [field("Original order line", orderNames[receipt.key.orderLineID] ?? pickupLabel("Unresolved")),
                            receipt.itemName + " · " + pickupLabel(receipt.disposition.rawValue),
                            field("Received", quantity(receipt.received)), segment]
                let saved = observations[receipt.key] ?? []
                if saved.isEmpty { rows.append(pickupLabel("Usable amount unverified")) }
                event(receipt.receivedAt, pickupLabel("Actual arrival"), rows)
                for fact in saved {
                    let title = fact.supersedesID == nil ? "Saved usable amount" : "Corrected usable amount"
                    var rows = [receipt.itemName, field("Original order line", orderNames[receipt.key.orderLineID] ?? pickupLabel("Unresolved")),
                                segment, field("Usable", quantity(fact.usable))]
                    if !fact.confirmedMatchToOrderLine { rows.append(pickupLabel("identityMatchUnconfirmed")) }
                    event(fact.confirmedAt, pickupLabel(title), rows)
                }
            }
        }
        for lot in j.stockLots {
            event(lot.confirmedAt, pickupLabel("Confirmed available"), [lot.name + " · " + quantity(lot.usable)])
        }
        for repair in j.repairs { event(repair.createdAt, pickupLabel("Saved meal repair"), [repair.instruction]) }
        for change in j.mealRecovery?.domain.events ?? [] {
            let request = change.request
            var rows = [request.target.title + " → " + request.replacement.title]
            rows += request.replacement.ingredients.map { $0.foodName + " · " + $0.need.name + " · " + quantity($0.need.amount) }
            if request.agreesToRepeat { rows.append(pickupLabel("I agree to repeat a meal for this repair")) }
            if request.agreesToExtraTrip { rows.append(pickupLabel("I agree to an extra top-up trip for this repair")) }
            if request.acceptsUnresolved { rows.append(pickupLabel("Unresolved effects accepted for this repair")) }
            event(change.appliedAt, pickupLabel("Saved meal repair"), rows)
        }
        for note in j.notes {
            let revision = field("Revision", String(note.revision))
            event(note.createdAt, pickupLabel("Saved cook note"), [revision, note.language, note.text])
            if let at = note.sentAt {
                event(at, pickupLabel("Cook instruction"), [field("Revision", String(note.revision)),
                    field("Reported sent to", note.sentTo ?? pickupLabel("Not confirmed"))])
            } else if let recipient = note.sentTo {
                current.append([pickupLabel("Cook instruction"), revision, field("Reported sent to", recipient),
                                pickupLabel("Send time not recorded")].joined(separator: " · "))
            }
        }
        let notes = Dictionary(j.notes.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        for action in j.cookShareEvents {
            var rows = [pickupLabel(action.action.rawValue)]
            if let note = notes[action.noteID] { rows.append(field("Revision", String(note.revision))) }
            if let destination = action.destination { rows.append(destination) }
            event(action.occurredAt, pickupLabel("Cook instruction"), rows)
        }
        for send in j.recipientSends ?? [] {
            let title = pickupLabel(send.channel == .cook ? "Cook instruction" : "Retailer handoff")
            var rows = [field("Reported sent to", send.recipient), send.language]
            if let note = notes[send.versionID], send.channel == .cook { rows.append(field("Revision", String(note.revision))) }
            event(send.sentAt, title, rows)
            if let at = send.acknowledgedAt { event(at, title, [pickupLabel("Recipient acknowledgment reported"), send.recipient]) }
        }
        let actions = Dictionary(grouping: j.offerActions, by: \.offerID)
        let meals = Dictionary(j.needs.map { ($0.id, $0.name) }, uniquingKeysWith: { first, _ in first })
        for offer in j.offers {
            let zone = TimeZone(identifier: offer.deadline.timeZoneID) ?? .gmt
            var rows = [field("Replacement and offered pack", offer.replacement),
                        field("Original order line", orderNames[offer.lineID] ?? pickupLabel("Unresolved")),
                        field("Required usable amount", quantity(offer.required)),
                        field("Original amount still expected", quantity(offer.remainingOriginal)),
                        field("Offered price", price(offer.price))]
            if let ceiling = offer.ceiling { rows.append(field("Maximum price", money(ceiling))) }
            rows += [field("Retailer cutoff", date(offer.deadline.cutoff, zone: zone) + " · " + offer.deadline.timeZoneID),
                     field("Household preference", offer.householdPreference.isEmpty ? pickupLabel("Unresolved") : offer.householdPreference),
                     field("Retailer response", offer.retailerResponse.isEmpty ? pickupLabel("Pending") : offer.retailerResponse)]
            if !offer.fallback.isEmpty { rows.append(field("If short", offer.fallback)) }
            current.append(rows.joined(separator: "\n"))
            if let review = offer.evaluation {
                let inputs = review.inputs
                var facts = [field("Replacement and offered pack", offer.replacement),
                             field("Evidence source", inputs.checkoutSource),
                             field("Checkout evidence recorded at", date(inputs.checkoutObservedAt)),
                             field("Retained original charge", price(inputs.retainedOriginalCharge)),
                             field("Net unaffected checkout cost", price(inputs.otherCheckoutCost))]
                if let amount = inputs.offeredUsable { facts.append(field("Expected offered usable yield", quantity(amount))) }
                for rule in inputs.dishRules {
                    let decision: String
                    switch rule.decision {
                    case .accepted: decision = "Approved for this dish"
                    case .declined: decision = "Excluded from this dish"
                    case .unreviewed: decision = "Not reviewed"
                    }
                    let dish = meals[rule.needID] ?? pickupLabel("Meal or purpose")
                    facts.append(dish + " · " + pickupLabel(decision))
                    if rule.exclusionsConfirmed { facts.append(pickupLabel("I checked this replacement against all saved exclusions for this dish.")) }
                }
                event(review.reviewedAt, pickupLabel("Meal and checkout forecast"), facts)
            }
            for action in actions[offer.id] ?? [] {
                event(action.occurredAt, field("Replacement and offered pack", offer.replacement), [pickupLabel(action.kind.rawValue)])
            }
        }
        for entry in j.settlement.entries {
            var rows = [money(entry.amount), entry.evidenceKey]
            if entry.occurredAt > j.savedAt { rows.append(pickupLabel("This entry is dated later and is excluded from these totals.")) }
            if let charge = entry.chargeEvidenceKey { rows.append(field("Original posted charge", charge)) }
            if let credit = entry.creditID { rows.append(field("Credit reference", credit)) }
            if let hold = entry.holdEvidenceKey { rows.append(field("Original payment hold", hold)) }
            event(entry.occurredAt, pickupLabel(entry.kind.rawValue), rows)
        }
        if let closed = j.closedAt { event(closed, pickupLabel("Pickup closed")) }
        if !j.settlement.entries.isEmpty {
            let summary = try j.settlement.summary(asOf: j.savedAt)
            current.append([field("Paid so far", money(summary.paidSoFar)), field("Pending credits · not deducted", money(summary.pendingCredits)),
                            field("Credits already included in charges", money(summary.includedCredits)),
                            field("Payment holds · not spending", money(summary.paymentHolds))].joined(separator: "\n"))
        }
        if !j.physicalStockNeeds.isEmpty || !j.recoveryCurrentUrgent.isEmpty {
            let allocation = try j.carryoverAllocation(at: j.savedAt)
            let pieces = PickupCookProjection.pieces(journey: j, allocation: allocation, language: language)
            current.append(([field("Meal needs and protected portions", date(j.savedAt)),
                             pickupLabel("Currently allocated from confirmed food")] + pieces.map(\.text)).joined(separator: "\n"))
        }
        if !j.deferred.isEmpty || !j.carriedMeals.isEmpty || j.nextShopReview != nil {
            var rows = [pickupLabel("Next shop")]
            for need in j.deferred {
                let status: String
                switch need.status {
                case "review", NextShopDisposition.keep.rawValue: status = pickupLabel("Deferred for review")
                case NextShopDisposition.handled.rawValue: status = pickupLabel("Already handled · no new purchase")
                case NextShopDisposition.dismissed.rawValue: status = pickupLabel("Dismissed")
                default: status = need.status
                }
                rows.append(status + " · " + line(need.line))
            }
            // Accepted source IDs belong to the earlier trip. The resulting
            // draft retains its own initial basket, independent of later edits.
            if let review = j.nextShopReview, review.choices.values.contains(.accept),
               let initial = j.basket?.revisions.first {
                rows.append(pickupLabel("Initial next-shop draft"))
                rows += initial.lines.map(line)
            }
            for need in j.carriedMeals {
                rows.append([pickupLabel("Carried meal need · review before accepting"), need.name, quantity(need.amount),
                             need.priority == .protected ? pickupLabel("Protected") : nil].compactMap { $0 }.joined(separator: " · "))
            }
            if !j.carriedMeals.isEmpty { rows.append(pickupLabel("No current stock or purchase is assumed for this carried need.")) }
            current.append(rows.joined(separator: "\n"))
        }
        // Stable sorting keeps source order when several facts share a timestamp.
        return (events.sorted { $0.0 < $1.0 }.map(\.1) + current).joined(separator: "\n\n")
    }
}
