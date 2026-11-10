import Foundation
import HouseholdClient
import RecordArchive

/// Independent read-only recovery only. This adapter does not accept a service,
/// account, session, household binding, replay queue or local mutable shop store.
enum SharedRecordArchiveAdapter {
    static func make(_ snapshot: SharedRecordSnapshot) throws -> ArchiveRecord {
        let value = snapshot.record
        return ArchiveRecord(id: value.origin.shopId.string, origin: origin(value), revision: revision(value),
            kind: .sharedShop, title: "Shared pickup", savedAtMilliseconds: 0, nativePayload: try value.independentData())
        // asOf is observation time. Never invent a source save time or ancestry.
        // Repeated export uses the same source/revision and canonical bytes.
    }
    static func validate(_ record: ArchiveRecord) throws -> SharedIndependentRecord {
        guard record.kind == .sharedShop, let bytes = record.nativePayload,
              record.media == nil, record.helperLines.isEmpty, record.parentRevision == nil,
              record.savedAtMilliseconds == 0 else { throw ArchiveError.unsupportedRecord }
        let value: SharedIndependentRecord
        do { value = try SharedRecordWire.independentRecord(from: bytes) }
        catch { throw ArchiveError.unsupportedRecord }
        guard record.id == value.origin.shopId.string, record.origin == origin(value), record.revision == revision(value) else { throw ArchiveError.invalidIdentity }
        guard try value.independentData() == bytes else { throw ArchiveError.unsupportedRecord }
        return value
    }
    private static func origin(_ value: SharedIndependentRecord) -> String {
        "shared-shop/" + value.origin.householdId.string + "/" + value.projection
    }
    private static func revision(_ value: SharedIndependentRecord) -> String {
        "shop-\(value.shopRevision)-privacy-\(value.privacyRevision)"
    }
}

extension SharedRecordArchiveAdapter {
    /// A readable owner copy preserves uncertainty and source wording. It never
    /// claims complete food coverage, a verified checkout or restored access.
    static func readable(_ record: ArchiveRecord, locale: Locale = .current) throws -> String {
        let value = try validate(record), es = locale.language.languageCode?.identifier == "es"
        func word(_ en: String, _ spanish: String) -> String { es ? spanish : en }
        let unknown = word("Unknown", "Sin determinar")
        func quantity(_ q: SharedDemandQuantity?) -> String {
            guard let q else { return unknown }
            var result = "\(q.originalLiteral) (\(q.amount.numerator)/\(q.amount.denominator) \(q.unit.rawValue))"
            if let conversion = q.confirmedConversion {
                result += " · \(conversion.sourceNote) · \(conversion.targetAmountPerSourceUnit.numerator)/\(conversion.targetAmountPerSourceUnit.denominator) \(conversion.targetUnit.rawValue)/\(conversion.sourceUnit.rawValue) · \(conversion.confirmedAt)"
            }
            return result
        }
        func restriction(_ item: SharedDemandSourceExclusion) -> String {
            switch item.resolution {
            case .unresolved: return item.label + " · " + word("unresolved restriction", "restricción sin resolver")
            case let .mapped(tags, at): return item.label + " · " + tags.joined(separator: ", ") + " · " + at
            }
        }
        func money(_ n: Int?) -> String { n.map { "USD \($0 / 100)." + String(format: "%02d", $0 % 100) } ?? unknown }
        var lines = [word("Independent shared pickup record", "Registro independiente de compra compartida"),
            word("Read-only copy. Household access and checkout authority are not restored.", "Copia de solo lectura. No restablece acceso al hogar ni permisos de compra."),
            word("Source household: ", "Hogar de origen: ") + value.origin.householdId.string,
            word("Source shop: ", "Compra de origen: ") + value.origin.shopId.string,
            word("Source revision: ", "Revisión de origen: ") + String(value.shopRevision),
            word("Saved date not supplied", "Fecha de guardado no indicada"),
            word("Tracked subtotals only; this record does not establish complete food coverage or free unbound supply.", "Solo subtotales registrados; este registro no confirma cobertura completa ni disponibilidad de alimentos sin vincular.")]
        if value.food.status == .reviewRequired { lines.append(word("Source data changed. Previous pack reviews were erased; review is required.", "Los datos de origen cambiaron. Se borraron las revisiones de paquetes anteriores; se necesita una nueva revisión.")) }
        lines.append(word("Basket packages and prices", "Paquetes y precios de la cesta"))
        for row in value.food.basket { lines.append("\(row.name) · \(row.packs) " + word("packs", "paquetes") + " · " + word("price per pack: ", "precio por paquete: ") + money(row.priceMinor)) }
        lines.append(word("Pack yield review", "Revisión del rendimiento por paquete"))
        for pack in value.food.packReview.values ?? [] {
            let name = value.food.basket.first { $0.id == pack.lineId }?.name ?? pack.lineId.string
            lines.append(name + " · " + quantity(pack.usablePerPack) + (pack.acceptUnresolved ? " · " + word("unresolved yield explicitly accepted", "rendimiento sin determinar aceptado expresamente") : ""))
        }
        lines.append(word("Meal and request sources", "Fuentes de comidas y solicitudes"))
        for fact in value.food.catalog {
            let unbound = value.food.unbound.first { $0.factId == fact.id }
            lines.append(fact.sourceLabel + " · " + fact.originalText + " · " + quantity(fact.quantity))
            if let original = fact.originalQuantityText { lines.append(original) }
            if case .reservation = fact.source { lines.append(word("Protected reservation", "Reserva protegida")) }
            if unbound != nil { lines.append(word("Unbound; not available as free supply", "Sin vincular; no disponible como existencias libres")) }
            if let transfer = unbound?.transferred { lines.append(word("Retained reviewed quantity: ", "Cantidad revisada conservada: ") + quantity(transfer.quantity)) }
            lines += fact.sourceExclusions.map { word("Original restriction: ", "Restricción original: ") + restriction($0) }
        }
        for total in value.food.coverage?.trackedSubtotals ?? [] {
            let name = value.food.basket.first { $0.id == total.lineId }?.name ?? total.lineId.string
            let amount = total.quantity.map { "\($0.numerator)/\($0.denominator)" } ?? unknown
            lines.append(word("Tracked subtotal: ", "Subtotal registrado: ") + name + " · " + amount + " " + total.unit.rawValue)
        }
        lines.append(word("Tracked food commitments", "Compromisos de alimentos registrados"))
        for row in value.food.graph.contributions where row.removedAt == nil {
            lines.append(row.originalText + " · " + quantity(row.quantity))
            lines += (row.sourceExclusions ?? []).map { word("Restriction: ", "Restricción: ") + restriction($0) }
        }
        for edge in value.food.graph.edges {
            let demand = value.food.graph.contributions.first { $0.id == edge.demandId }?.originalText ?? edge.demandId.string
            let supply = value.food.graph.contributions.first { $0.id == edge.supplyId }?.originalText ?? edge.supplyId.string
            let relationship = edge.kind == .withinExisting ? word("within existing quantity", "dentro de la cantidad existente") : word("duplicate", "duplicado")
            lines.append(demand + " → " + supply + " · " + relationship + " · " + quantity(edge.quantity) + " · " + edge.confirmation.evidence)
        }
        for meal in value.mealOccurrences { lines.append(meal.meal.title + " · " + (meal.meal.day ?? word("Unscheduled", "Sin fecha")) + " · \(meal.meal.portions) " + word("portions", "porciones") + (meal.meal.protected ? " · " + word("protected", "reservadas") : "")) }
        lines.append(word("Entered quote, not posted spending", "Cotización ingresada, no gasto contabilizado"))
        if !value.quote.complete { lines.append(word("The quote is incomplete; remaining items or charges may be missing.", "La cotización está incompleta; pueden faltar artículos o cargos.")) }
        if value.storeReviewRequired { lines.append(word("Review prices for the selected store before relying on this quote.", "Revise los precios de la tienda seleccionada antes de usar esta cotización.")) }
        let quoteScope = value.quote.scope == "wholeCheckout" ? word("whole checkout", "compra completa") : value.quote.scope == "item" ? word("one item", "un artículo") : word("one dinner", "una cena")
        let capScope = value.quote.capScope == "wholeCheckout" ? word("whole checkout", "compra completa") : value.quote.capScope == "item" ? word("one item", "un artículo") : value.quote.capScope == "dinner" ? word("one dinner", "una cena") : unknown
        lines.append(word("Scope: ", "Alcance: ") + quoteScope + " · " + word("cap: ", "límite: ") + money(value.quote.capMinor) + " · " + capScope)
        lines.append(word("Observed: ", "Observada: ") + value.quote.observedAt + " · " + word("expires: ", "vence: ") + value.quote.expiresAt)
        if value.quote.fee.kind == "fixed" { lines.append(word("Fee: ", "Cargo: ") + money(value.quote.fee.amountMinor)) }
        else { lines.append(word("Fee threshold: ", "Umbral del cargo: ") + money(value.quote.fee.thresholdMinor) + " · " + money(value.quote.fee.belowMinor) + " / " + money(value.quote.fee.aboveMinor)) }
        lines.append(word("Taxes / deposits / discounts: ", "Impuestos / depósitos / descuentos: ") + [value.quote.taxesMinor, value.quote.depositsMinor, value.quote.discountsMinor].map(money).joined(separator: " / "))
        return lines.joined(separator: "\n")
    }
}


/// A personal historical copy is never a command, grant or live household cache.
enum SharedHistoryArchiveAdapter {
    static func make(_ snapshot: SharedRecordHistorySnapshot) throws -> ArchiveRecord {
        let value = snapshot.record, bytes = try value.independentData()
        return ArchiveRecord(id: value.origin.shopId.string + "/history", origin: origin(value),
            revision: ArchiveCodec.digest(bytes), kind: .sharedHistory, title: "Shared pickup history",
            savedAtMilliseconds: 0, nativePayload: bytes)
    }
    static func validate(_ record: ArchiveRecord) throws -> SharedRecordHistory {
        guard record.kind == .sharedHistory, let bytes = record.nativePayload,
              record.media == nil, record.helperLines.isEmpty, record.parentRevision == nil,
              record.savedAtMilliseconds == 0 else { throw ArchiveError.unsupportedRecord }
        let value: SharedRecordHistory
        do { value = try SharedRecordHistoryWire.independentRecord(from: bytes) }
        catch { throw ArchiveError.unsupportedRecord }
        guard record.id == value.origin.shopId.string + "/history", record.origin == origin(value),
              record.revision == ArchiveCodec.digest(bytes), try value.independentData() == bytes
        else { throw ArchiveError.invalidIdentity }
        return value
    }
    private static func origin(_ value: SharedRecordHistory) -> String {
        "shared-history/" + value.origin.householdId.string + "/" + value.projection
    }
}

extension SharedHistoryArchiveAdapter {
    static func coverageKeys(_ record: ArchiveRecord) -> [String] {
        guard let value = try? validate(record) else { return [] }
        return [
            "Includes saved basket and meal revisions, cook notes, deliveries, decisions and financial records. Live household access is not restored.",
            value.foodHistory == nil ? "Food allocation history was not captured in this copy." : "Food allocation history is included.",
            value.stockHistory == nil ? "Stock-lot history was not captured in this copy." : "Stock-lot history is included."
        ]
    }

    static func readable(_ record: ArchiveRecord, locale: Locale = .current) throws -> String {
        let value = try validate(record), es = locale.language.languageCode?.identifier == "es"
        func w(_ en: String, _ esText: String) -> String { es ? esText : en }
        let unknown = w("Unknown", "Sin determinar")
        func id(_ value: UUID) -> String { value.uuidString.lowercased() }
        func money(_ amount: Int?) -> String { amount.map { "USD \($0 / 100)." + String(format: "%02d", $0 % 100) } ?? unknown }
        func quantity(_ q: SharedMealQuantity?) -> String {
            guard let q else { return unknown }
            return "\(q.originalLiteral) (\(q.amount.numerator)/\(q.amount.denominator) \(q.unit))"
        }
        var lines = [w("Shared pickup history", "Historial de compra compartida"),
            w("Read-only copy. Household access and checkout authority are not restored.", "Copia de solo lectura. No restablece acceso al hogar ni permisos de compra."),
            w("Includes saved basket and meal revisions, cook notes, deliveries, decisions and financial records. Live household access is not restored.", "Incluye revisiones guardadas de cestas y comidas, notas de cocina, entregas, decisiones y registros financieros. No restablece el acceso al hogar."),
            w("Source household: ", "Hogar de origen: ") + value.origin.householdId.string,
            w("Source shop: ", "Compra de origen: ") + value.origin.shopId.string]
        func section(_ en: String, _ esText: String, _ count: Int) {
            lines.append("\n" + w(en, esText) + " (\(count))")
            if count == 0 { lines.append(w("No saved entries.", "No hay registros guardados.")) }
        }
        section("Basket revisions", "Revisiones de la cesta", value.basketRevisions.count)
        for basket in value.basketRevisions {
            lines.append("#\(basket.revision) · \(basket.recordedAt) · \(basket.phase) · \(basket.purpose)")
            for item in basket.basketLines {
                lines.append(item.originalItem + " · \(item.packs) " + w("packs", "paquetes") + " · " + money(item.unitPriceMinor))
            }
            let q = basket.quote
            lines.append(w("Entered quote; not posted spending", "Cotización ingresada; no gasto contabilizado"))
            lines.append(w("Scope / cap: ", "Alcance / límite: ") + q.scope + " / " + money(q.capMinor) + " · " + q.capScope)
            lines.append(w("Observed / expires: ", "Observada / vence: ") + q.observedAt + " / " + q.expiresAt)
            if !q.complete { lines.append(w("Quote incomplete.", "Cotización incompleta.")) }
            if q.fee.kind == "fixed" { lines.append(w("Fee: ", "Cargo: ") + money(q.fee.amountMinor)) }
            else { lines.append(w("Fee threshold / below / above: ", "Umbral del cargo / inferior / superior: ") + [q.fee.thresholdMinor, q.fee.belowMinor, q.fee.aboveMinor].map(money).joined(separator: " / ")) }
            lines.append(w("Taxes / deposits / discounts: ", "Impuestos / depósitos / descuentos: ") + [q.taxesMinor, q.depositsMinor, q.discountsMinor].map(money).joined(separator: " / "))
        }
        section("Meal revisions", "Revisiones de comidas", value.mealRevisions.count)
        for entry in value.mealRevisions {
            guard let meal = entry.meal else {
                lines.append(w("Removed meal", "Comida eliminada") + " · #\(entry.revision) · " + entry.occurrenceId.string)
                continue
            }
            lines.append(meal.title + " · #\(entry.revision) · " + entry.occurrenceId.string)
            lines.append((meal.day ?? w("Unscheduled", "Sin fecha")) + " · \(meal.portions) " + w("portions", "porciones") + (meal.protected ? " · " + w("protected", "reservadas") : ""))
            if let planning = meal.planning {
                lines += planning.exclusions ?? []
                if let deadline = planning.deadline { lines.append(w("Deadline: ", "Hora límite: ") + deadline.at + " · " + deadline.zone) }
                lines.append(w("Preparation minutes: ", "Minutos de preparación: ") + (planning.leadTimeMinutes.map(String.init) ?? unknown))
                for group in planning.groups {
                    lines.append(group.name + " · \(group.servings.numerator)/\(group.servings.denominator) " + w("servings", "porciones") + (group.protected ? " · " + w("protected", "reservadas") : ""))
                }
                for ingredient in planning.ingredients {
                    let groups = ingredient.groupIds.compactMap { key in planning.groups.first { $0.id == key }?.name }
                    lines.append(ingredient.name + " · " + quantity(ingredient.quantity) + (groups.isEmpty ? "" : " · " + groups.joined(separator: ", ")))
                    lines += ingredient.exclusions
                }
                for binding in planning.bindings ?? [] {
                    let ingredient = planning.ingredients.first { $0.id == binding.ingredientId }?.name ?? id(binding.ingredientId)
                    let group = planning.groups.first { $0.id == binding.groupId }?.name ?? id(binding.groupId)
                    lines.append(ingredient + " → " + group + " · " + quantity(binding.quantity))
                }
                lines += planning.completedSteps ?? []
            }
        }
        section("Saved cook instructions", "Instrucciones de cocina guardadas", value.cookCopies.count)
        for copy in value.cookCopies {
            lines.append("\(copy.createdAt) · \(copy.language) · #\(copy.version) · " + id(copy.copyId))
            lines.append(copy.text)
            for send in value.cookSends where send.copyId == copy.copyId {
                lines.append(w("Marked sent to: ", "Marcada como enviada a: ") + send.recipient + " · " + send.sentAt)
            }
        }
        section("Delivery sources", "Fuentes de entrega", value.deliveries.sources.count)
        for source in value.deliveries.sources {
            lines.append(source.foodName + " · " + id(source.sourceId) + " · " + id(source.segmentKey))
            lines += source.exclusionTags
        }
        section("Arrival and usable-food observations", "Observaciones de llegada y alimentos utilizables", value.deliveries.observations.count)
        for observation in value.deliveries.observations {
            lines.append(observation.recordedAt)
            switch observation.body {
            case let .arrival(body): lines.append(w("Arrival: ", "Llegada: ") + id(body.sourceId) + " · " + (body.arrivedAt ?? unknown) + " · " + quantity(body.received))
            case let .usable(body): lines.append(w("Usable: ", "Utilizable: ") + id(body.sourceId) + " · " + body.confirmedAt + " · " + quantity(body.usable))
            }
        }
        section("Food matches", "Vínculos de alimentos", value.deliveries.matches.count)
        for match in value.deliveries.matches {
            lines.append(id(match.sourceId) + " → " + id(match.occurrenceId) + " / " + id(match.ingredientId) + " · #\(match.supplyRevision) · " + (match.matched ? w("matched", "vinculado") : w("unlinked", "sin vincular")))
        }
        section("Reserved food", "Alimentos reservados", value.deliveries.reservations.count)
        for reservation in value.deliveries.reservations {
            lines.append(id(reservation.sourceId) + " → " + id(reservation.occurrenceId) + " / " + id(reservation.ingredientId) + " / " + id(reservation.groupId) + " · #\(reservation.supplyRevision) · " + (reservation.quantity.map { quantity($0) } ?? w("Reservation released", "Reserva liberada")))
        }
        func demandQuantity(_ q: SharedDemandQuantity?) -> String {
            guard let q else { return unknown }
            var result = "\(q.originalLiteral) (\(q.amount.numerator)/\(q.amount.denominator) \(q.unit.rawValue))"
            if let conversion = q.confirmedConversion {
                result += " · \(conversion.sourceNote) · \(conversion.targetAmountPerSourceUnit.numerator)/\(conversion.targetAmountPerSourceUnit.denominator) \(conversion.targetUnit.rawValue)/\(conversion.sourceUnit.rawValue) · \(conversion.confirmedAt)"
            }
            return result
        }
        func graphLines(_ graph: SharedDemandGraph, packs: [SharedDemandPackReview]) -> [String] {
            var result = [w("Food revision: ", "Revisión de alimentos: ") + String(graph.revision)]
            for contribution in graph.contributions {
                result.append(contribution.originalText + " · " + demandQuantity(contribution.quantity))
                if case .reservation = contribution.source { result.append(w("Protected reservation", "Reserva protegida")) }
                if let removed = contribution.removedAt { result.append(w("Removed: ", "Eliminado: ") + removed) }
                result += contribution.exclusions
                for restriction in contribution.sourceExclusions ?? [] { result.append(restriction.label) }
            }
            for edge in graph.edges {
                let demand = graph.contributions.first { $0.id == edge.demandId }?.originalText ?? edge.demandId.string
                let supply = graph.contributions.first { $0.id == edge.supplyId }?.originalText ?? edge.supplyId.string
                let kind = edge.kind == .withinExisting ? w("within existing quantity", "dentro de la cantidad existente") : w("duplicate", "duplicado")
                result.append(demand + " → " + supply + " · " + kind + " · " + demandQuantity(edge.quantity))
                result.append(edge.confirmation.evidence + " · " + edge.confirmation.confirmedAt)
            }
            for pack in packs {
                let name = graph.lines.first { $0.id == pack.lineId }?.name ?? pack.lineId.string
                result.append(name + " · " + w("usable per pack: ", "cantidad utilizable por paquete: ") + demandQuantity(pack.usablePerPack))
                if pack.acceptUnresolved { result.append(w("Unresolved yield explicitly accepted", "Rendimiento sin determinar aceptado expresamente")) }
            }
            return result
        }
        if let history = value.foodHistory {
            section("Food allocation history", "Historial de asignación de alimentos", history.demandRevisions.count + history.trackingRevisions.count)
            for revision in history.demandRevisions {
                lines.append(revision.recordedAt + " · " + w("Basket revision: ", "Revisión de la cesta: ") + String(revision.shopRevision))
                if let predecessor = revision.predecessorRevision { lines.append(w("Previous food revision: ", "Revisión anterior de alimentos: ") + String(predecessor)) }
                lines += graphLines(revision.graph, packs: revision.packReviews)
            }
            for revision in history.trackingRevisions {
                let food = revision.food
                lines.append(revision.recordedAt + " · " + w("Basket revision: ", "Revisión de la cesta: ") + String(revision.shopRevision))
                lines += graphLines(food.graph, packs: food.packReviews)
                for row in food.basket { lines.append(row.name + " · \(row.packs) " + w("packs", "paquetes") + " · " + money(row.priceMinor)) }
                for fact in food.catalog {
                    lines.append(fact.sourceLabel + " · " + fact.originalText + " · " + demandQuantity(fact.quantity))
                    if let original = fact.originalQuantityText { lines.append(original) }
                    lines += fact.sourceExclusions.map(\.label)
                }
                for unbound in food.unbound {
                    let name = food.catalog.first { $0.id == unbound.factId }?.originalText ?? unbound.factId.string
                    lines.append(name + " · " + w("Unbound; not available as free supply", "Sin vincular; no disponible como existencias libres"))
                    if let retained = unbound.transferred { lines.append(w("Retained reviewed quantity: ", "Cantidad revisada conservada: ") + demandQuantity(retained.quantity)) }
                }
            }
        } else { lines.append(w("Food allocation history was not captured in this copy.", "Esta copia no incluye el historial de asignación de alimentos.")) }
        if let history = value.stockHistory {
            section("Stock-lot history", "Historial de lotes", history.lots.count)
            for lot in history.lots {
                lines.append(lot.foodName + " · " + id(lot.lotId) + " · " + (lot.location == "freezer" ? w("Freezer", "Congelador") : w("Pantry", "Despensa")))
                lines += lot.exclusionTags
                lines.append(w("Stored: ", "Guardado: ") + (lot.storedAt ?? unknown) + " · " + w("Use first: ", "Usar primero: ") + (lot.useFirstAt ?? unknown))
                if let delivery = lot.deliverySourceId { lines.append(w("Delivery source: ", "Fuente de entrega: ") + id(delivery)) }
                for event in history.events where event.lotId == lot.lotId {
                    lines.append(event.recordedAt + " · #\(event.pantryRevision)")
                    switch event.details {
                    case let .observe(confirmedAt, amount):
                        lines.append(w("Confirmed usable quantity: ", "Cantidad utilizable confirmada: ") + quantity(amount) + " · " + confirmedAt)
                    case let .select(selected):
                        lines.append(selected ? w("Selected for this pickup", "Seleccionado para esta compra") : w("No longer selected for this pickup", "Ya no está seleccionado para esta compra"))
                    case let .match(occurrence, revision, ingredient, matched):
                        lines.append(id(occurrence) + " / " + id(ingredient) + " · #\(revision) · " + (matched ? w("matched", "vinculado") : w("unlinked", "sin vincular")))
                    case let .reserve(occurrence, revision, ingredient, group, amount):
                        lines.append(id(occurrence) + " / " + id(ingredient) + " / " + id(group) + " · #\(revision) · " + (amount.map { w("Reserved: ", "Reservado: ") + quantity($0) } ?? w("Reservation released", "Reserva liberada")))
                    }
                }
            }
        } else { lines.append(w("Stock-lot history was not captured in this copy.", "Esta copia no incluye el historial de lotes.")) }
        section("Decisions and outcomes", "Decisiones y resultados", value.decisions.count)
        for decision in value.decisions {
            lines.append(decision.recordedAt + " · " + [decision.dish, decision.product, decision.occasion].compactMap { $0 }.joined(separator: " · "))
            lines.append(decision.decision)
            lines.append(w("Outcome: ", "Resultado: ") + (decision.outcome ?? unknown))
            if let observed = decision.observedAt { lines.append(w("Observed: ", "Observado: ") + observed) }
            if let promoted = decision.promotedAt { lines.append(w("Saved as a lasting preference: ", "Guardada como preferencia permanente: ") + promoted) }
        }
        section("Financial evidence", "Comprobantes financieros", value.financialEntries.count)
        let financialLabels: [ShopperFinancialEntry.Kind: String] = [.postedCharge: w("Posted charge", "Cargo contabilizado"), .postedTopUp: w("Posted top-up", "Compra adicional contabilizada"), .pendingCredit: w("Pending credit", "Crédito pendiente"), .postedCredit: w("Posted credit", "Crédito contabilizado"), .includedCredit: w("Included credit", "Crédito incluido"), .paymentHold: w("Payment hold", "Retención de pago"), .holdRelease: w("Hold release", "Liberación de retención")]
        for entry in value.financialEntries {
            lines.append(entry.occurredAt + " · " + (financialLabels[entry.kind] ?? entry.kind.rawValue) + " · " + money(entry.amountMinor))
            lines.append(entry.sourceText)
        }
        section("Saved price observations", "Observaciones de precios guardadas", value.priceObservations.count)
        for price in value.priceObservations {
            lines.append(price.itemName + " · " + price.packLabel + " · " + price.observedAt)
            switch price.price {
            case let .exact(minor): lines.append(money(minor))
            case let .bounded(low, high, reason): lines.append(money(low) + " – " + money(high) + " · " + reason)
            case let .unknown(reason): lines.append(unknown + " · " + reason)
            }
            lines.append([price.store, price.branch, price.channel.rawValue, price.mode.rawValue, price.eligibility].joined(separator: " · "))
            if let pack = price.usablePack { lines.append(pack.originalLiteral + " · \(pack.amount.numerator)/\(pack.amount.denominator) \(pack.unit.rawValue)") }
            lines.append(price.sourceText + " · " + price.sourceLocale)
        }
        return lines.joined(separator: "\n")
    }
}
