import CoreDomain
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

private struct SharedRecordText {
    let language: String
    let bundle: Bundle

    init(_ locale: Locale) {
        language = locale.language.languageCode?.identifier == "es" ? "es" : "en"
        bundle = Bundle.main.url(forResource: language, withExtension: "lproj").flatMap(Bundle.init(url:)) ?? .main
    }

    func word(_ english: String, _ spanish: String) -> String { language == "es" ? spanish : english }
    var unknown: String { word("Unknown", "Sin determinar") }

    func amount(_ text: String, unit: String, singular: Bool) -> String {
        guard let measure = UnitOfMeasure(rawValue: unit) else { return text + " " + unit }
        return pQuantity(text, unit: measure, singular: singular, language: language)
    }

    func fraction<N: BinaryInteger>(_ numerator: N, _ denominator: N, unit: String) -> String {
        amount("\(numerator)/\(denominator)", unit: unit, singular: numerator == denominator)
    }

    func demandQuantity(_ quantity: SharedDemandQuantity?) -> String {
        guard let quantity else { return unknown }
        let normalized = fraction(quantity.amount.numerator, quantity.amount.denominator, unit: quantity.unit.rawValue)
        var text = quantity.originalLiteral + " (" + normalized + ")"
        if let conversion = quantity.confirmedConversion {
            let rate = conversion.targetAmountPerSourceUnit
            let target = fraction(rate.numerator, rate.denominator, unit: conversion.targetUnit.rawValue)
            let source = amount("1", unit: conversion.sourceUnit.rawValue, singular: true)
            text += " · " + conversion.sourceNote + " · " + target + " / " + source + " · " + conversion.confirmedAt
        }
        return text
    }

    func quoteScope(_ scope: String) -> String {
        switch scope {
        case "wholeCheckout": word("whole checkout", "compra completa")
        case "item": word("one item", "un artículo")
        case "dinner": word("one dinner", "una cena")
        default: unknown
        }
    }

    func basketPurpose(_ purpose: String) -> String {
        switch purpose {
        case "create": word("Basket created", "Cesta creada")
        case "patch": word("Basket updated", "Cesta actualizada")
        case "decision": word("Request decision", "Decisión sobre una solicitud")
        case "freeze": word("Basket frozen", "Cesta fijada")
        case "reopen": word("Basket reopened", "Cesta reabierta")
        case "placed": word("Order placed", "Pedido realizado")
        default: unknown
        }
    }
}

extension SharedRecordArchiveAdapter {
    /// A readable owner copy preserves uncertainty and source wording. It never
    /// claims complete food coverage, a verified checkout or restored access.
    static func readable(_ record: ArchiveRecord, locale: Locale = recordsInterfaceLocale) throws -> String {
        let value = try validate(record), copy = SharedRecordText(locale)
        let word = copy.word, unknown = copy.unknown, quantity = copy.demandQuantity
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
            let amount = total.quantity.map { copy.fraction($0.numerator, $0.denominator, unit: total.unit.rawValue) }
                ?? copy.amount(unknown, unit: total.unit.rawValue, singular: false)
            lines.append(word("Tracked subtotal: ", "Subtotal registrado: ") + name + " · " + amount)
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
        lines.append(word("Scope: ", "Alcance: ") + copy.quoteScope(value.quote.scope) + " · " + word("cap: ", "límite: ") + money(value.quote.capMinor) + " · " + copy.quoteScope(value.quote.capScope))
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
        let identity = source(householdID: value.origin.householdId.string, shopID: value.origin.shopId.uuid)
        return ArchiveRecord(id: identity.recordID, origin: identity.origin,
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
        let identity = source(householdID: value.origin.householdId.string, shopID: value.origin.shopId.uuid)
        guard record.id == identity.recordID, record.origin == identity.origin,
              record.revision == ArchiveCodec.digest(bytes), try value.independentData() == bytes
        else { throw ArchiveError.invalidIdentity }
        return value
    }
    static func source(householdID: String, shopID: UUID) -> ArchiveSourceIdentity {
        ArchiveSourceIdentity(origin: "shared-history/" + householdID.lowercased() + "/assigned-shopper-history-v1",
                              recordID: shopID.uuidString.lowercased() + "/history")
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

    static func readable(_ record: ArchiveRecord, locale: Locale = recordsInterfaceLocale) throws -> String {
        let value = try validate(record), copy = SharedRecordText(locale)
        let w = copy.word, unknown = copy.unknown
        func id(_ value: UUID) -> String { value.uuidString.lowercased() }
        func money(_ amount: Int?) -> String { amount.map { "USD \($0 / 100)." + String(format: "%02d", $0 % 100) } ?? unknown }
        func quantity(_ q: SharedMealQuantity?) -> String {
            guard let q else { return unknown }
            return q.originalLiteral + " (" + copy.fraction(q.amount.numerator, q.amount.denominator, unit: q.unit) + ")"
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
            lines.append("#\(basket.revision) · \(basket.recordedAt) · \(HistoryCopy.phase(basket.phase, bundle: copy.bundle)) · \(copy.basketPurpose(basket.purpose))")
            for item in basket.basketLines {
                lines.append(item.originalItem + " · \(item.packs) " + w("packs", "paquetes") + " · " + money(item.unitPriceMinor))
            }
            let q = basket.quote
            lines.append(w("Entered quote; not posted spending", "Cotización ingresada; no gasto contabilizado"))
            lines.append(w("Scope / cap: ", "Alcance / límite: ") + copy.quoteScope(q.scope) + " / " + money(q.capMinor) + " · " + copy.quoteScope(q.capScope))
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
        let demandQuantity = copy.demandQuantity
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
            if let carried = history.carriedDeliveries {
                section("Delivery history from earlier pickups", "Historial de entregas de compras anteriores", carried.count)
                for delivery in carried {
                    let source = delivery.source
                    lines.append(source.foodName + " · " + id(source.sourceId))
                    lines.append(w("Source pickup: ", "Compra de origen: ") + id(delivery.originShopId) + " · #\(source.placedRevision)")
                    lines.append(w("Original line / delivery segment: ", "Línea original / parte de la entrega: ") + id(source.lineId) + " / " + id(source.segmentKey))
                    lines += source.exclusionTags
                    for observation in delivery.observations {
                        lines.append(observation.recordedAt)
                        switch observation.body {
                        case let .arrival(body):
                            lines.append(w("Arrival: ", "Llegada: ") + (body.arrivedAt ?? unknown) + " · " + quantity(body.received))
                            if let prior = body.predecessorId { lines.append(w("Corrects observation: ", "Corrige la observación: ") + id(prior)) }
                        case let .usable(body):
                            lines.append(w("Usable: ", "Utilizable: ") + body.confirmedAt + " · " + quantity(body.usable))
                            if let prior = body.predecessorId { lines.append(w("Corrects observation: ", "Corrige la observación: ") + id(prior)) }
                        }
                    }
                }
            } else {
                lines.append(w("Delivery history from earlier pickups was not captured in this copy.", "Esta copia no incluye el historial de entregas de compras anteriores."))
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
            let channel = HistoryCopy.channel(price.channel.rawValue, bundle: copy.bundle)
            let mode = HistoryCopy.mode(price.mode.rawValue, bundle: copy.bundle)
            lines.append([price.store, price.branch, channel, mode, price.eligibility].joined(separator: " · "))
            if let pack = price.usablePack { lines.append(pack.originalLiteral + " · " + copy.fraction(pack.amount.numerator, pack.amount.denominator, unit: pack.unit.rawValue)) }
            lines.append(price.sourceText + " · " + price.sourceLocale)
        }
        return lines.joined(separator: "\n")
    }
}
