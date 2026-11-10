import Foundation

public enum SharedTrackingAdoptionComponent: Decodable, Equatable, Sendable {
    case none
    case meal(occurrenceId: SharedDemandID, componentDigest: SharedTrackingQuoteDigest)
    case requestAcceptance(requestId: SharedDemandID, componentDigest: SharedTrackingQuoteDigest)
    private enum K: String, CodingKey { case kind, occurrenceId, requestId, componentDigest }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: K.self)
        switch try c.decode(String.self, forKey: .kind) {
        case "none": try demandExactKeys(decoder, ["kind"]); self = .none
        case "meal":
            try demandExactKeys(decoder, ["kind", "occurrenceId", "componentDigest"])
            self = .meal(occurrenceId: try c.decode(SharedDemandID.self, forKey: .occurrenceId), componentDigest: try c.decode(SharedTrackingQuoteDigest.self, forKey: .componentDigest))
        case "requestAcceptance":
            try demandExactKeys(decoder, ["kind", "requestId", "componentDigest"])
            self = .requestAcceptance(requestId: try c.decode(SharedDemandID.self, forKey: .requestId), componentDigest: try c.decode(SharedTrackingQuoteDigest.self, forKey: .componentDigest))
        default: throw ClientError.invalidResponse
        }
    }
    func includes(_ source: SharedDemandSource) -> Bool {
        switch (self, source) {
        case (.meal(let id, _), .meal(let occurrence, _, _, _)): id == occurrence
        case (.meal(let id, _), .reservation(_, _, let occurrence, _, _, _)): id == occurrence
        case (.requestAcceptance(let id, _), .request(let request, _)): id == request
        default: false
        }
    }
}
public struct SharedTrackingUndoQuotes: Decodable, Equatable, Sendable {
    public let before, after: ShopperQuote
    private enum K: String, CodingKey { case before, after }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["before", "after"]); let c = try decoder.container(keyedBy: K.self)
        try requestUndoQuoteShape(c.superDecoder(forKey: .before)); try requestUndoQuoteShape(c.superDecoder(forKey: .after))
        before = try c.decode(ShopperQuote.self, forKey: .before); after = try c.decode(ShopperQuote.self, forKey: .after)
        _ = try SharedTrackingAction(.patch(.init(quote: before, lines: [])))
        _ = try SharedTrackingAction(.patch(.init(quote: after, lines: [])))
    }
}
/// Version-2 compound certificate disclosure. The target operation remains the
/// explicit candidate intent and immutable command binding; this response does
/// not contain or invent a second target-operation identity.
public struct SharedTrackingCompoundUndoDisclosure: Decodable, Equatable, Sendable {
    public let component: SharedTrackingAdoptionComponent
    public let reversedAssertions: SharedTrackingReversedAssertions
    public let touchedBasket: [SharedOperationUndoTouchedLine]
    public let quote: SharedTrackingUndoQuotes
    public let beforeCoverage, afterCoverage: SharedTrackingCoverage
    public let mealUndo: SharedOperationUndoMeal?
    private enum K: String, CodingKey { case component, reversedAssertions, touchedBasket, quote, beforeCoverage, afterCoverage, mealUndo }
    public init(from decoder: Decoder) throws {
        try demandExactKeys(decoder, ["component", "reversedAssertions", "touchedBasket", "quote", "beforeCoverage", "afterCoverage", "mealUndo"])
        let c = try decoder.container(keyedBy: K.self)
        component = try c.decode(SharedTrackingAdoptionComponent.self, forKey: .component)
        reversedAssertions = try c.decode(SharedTrackingReversedAssertions.self, forKey: .reversedAssertions)
        touchedBasket = try c.decode([SharedOperationUndoTouchedLine].self, forKey: .touchedBasket)
        quote = try c.decode(SharedTrackingUndoQuotes.self, forKey: .quote)
        beforeCoverage = try c.decode(SharedTrackingCoverage.self, forKey: .beforeCoverage); afterCoverage = try c.decode(SharedTrackingCoverage.self, forKey: .afterCoverage)
        mealUndo = try c.decode(SharedOperationUndoMeal?.self, forKey: .mealUndo)
        try demandRequire(touchedBasket.count <= 200 && demandUnique(touchedBasket.map(\.lineId)))
    }
    func validate(page: SharedTrackingPage, candidate: SharedTrackingCandidate) throws {
        guard let before = page.state, case .patch(let body) = candidate.action.command else { throw ClientError.invalidResponse }
        let after = candidate.after, assertions = reversedAssertions
        try demandRequire(beforeCoverage == page.coverage && afterCoverage == candidate.disclosure.pickup.coverage && quote.after == body.quote)
        try demandRequire(assertions.lines.count <= 200 && assertions.contributions.count <= 2000 && assertions.edges.count <= 4000 && assertions.packReviews.count <= 200)
        try demandRequire(demandUnique(assertions.lines.map(\.id)) && demandUnique(assertions.contributions.map(\.id)) && demandUnique(assertions.edges.map(\.id)) && demandUnique(assertions.packReviews.map(\.lineId)))
        for line in assertions.lines { try demandRequire(before.graph.lines.contains(line)) }
        for row in assertions.contributions { try demandRequire(before.graph.contributions.contains(row)) }
        for edge in assertions.edges { try demandRequire(before.graph.edges.contains(edge)) }
        for pack in assertions.packReviews { try demandRequire(before.packReviews.contains(pack)) }
        switch component {
        case .none: try demandRequire(mealUndo == nil && body.mealEdit == nil && before.catalog == after.catalog)
        case .meal(let occurrence, _):
            guard let mealUndo, let edit = body.mealEdit else { throw ClientError.invalidResponse }
            try demandRequire(mealUndo.occurrenceId == occurrence); try mealUndo.validateCompound(edit: edit, shopRevision: page.shopRevision)
            let oldUnrelated = before.catalog.filter { !component.includes($0.source) }, newUnrelated = after.catalog.filter { !component.includes($0.source) }
            try demandRequire(oldUnrelated == newUnrelated)
        case .requestAcceptance: throw ClientError.invalidResponse // Dedicated request-family Undo is mandatory.
        }
        let ids = Set(before.basket.map(\.id)).union(after.basket.map(\.id))
        var changed = Set<SharedDemandID>()
        for id in ids {
            let old = before.basket.first { $0.id == id }, next = after.basket.first { $0.id == id }
            guard old != next else { continue }; changed.insert(id)
            guard let touched = touchedBasket.first(where: { $0.lineId == id }) else { throw ClientError.invalidResponse }
            var fields: [SharedOperationUndoTouchedLine.Field] = []
            if let old, let next {
                if old.name != next.name { fields.append(.originalItem) }; if old.packs != next.packs { fields.append(.packs) }
                if old.priceMinor != next.priceMinor { fields.append(.unitPriceMinor) }; if old.feeEligible != next.feeEligible { fields.append(.feeEligible) }
            } else { fields = [.membership] }
            try demandRequire(touched.fields == fields)
        }
        try demandRequire(Set(touchedBasket.map(\.lineId)) == changed)
    }
}
