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
