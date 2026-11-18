import Foundation
import HouseholdClient

/// A reading aid over an already authorized shopper inbox, never a combined request.
/// Keep the original requests intact: quantities, exclusions and intended uses are
/// free text and cannot safely be summed or inferred from an item name.
struct RequestDuplicateGroup: Identifiable, Equatable {
    let id: String
    let requests: [OwnRequest]
    var hasPossibleDuplicates: Bool { requests.count > 1 }
}

struct RequestMealCandidate: Identifiable, Equatable {
    let fact: SharedTrackingFact
    let line: ShopperBasketLine?
    var id: SharedDemandID { fact.id }
}

enum RequestDuplicateGrouping {
    /// Group only the current shop's supplied projection. No additional request
    /// fetch, contributor projection, basket lookup or command is involved.
    static func groups(requests: [OwnRequest], shopID: String, authorized: Bool) -> [RequestDuplicateGroup] {
        guard authorized, !shopID.isEmpty else { return [] }
        var current: [OwnRequest] = []
        var positions: [String: Int] = [:]
        for request in requests where request.shopId == shopID {
            if let position = positions[request.id] {
                // Cursor overlap must not make one author look like two requests.
                if request.revision > current[position].revision { current[position] = request }
            } else {
                positions[request.id] = current.count
                current.append(request)
            }
        }

        var keys: [String] = []
        var grouped: [String: [OwnRequest]] = [:]
        for request in current {
            let name = comparisonName(request.originalItem)
            // Malformed empty names are kept separate, never treated as a match.
            let key = name.isEmpty ? "request:" + request.id : "name:" + name
            if grouped[key] == nil { keys.append(key) }
            grouped[key, default: []].append(request)
        }
        return keys.map { RequestDuplicateGroup(id: shopID + ":" + $0, requests: grouped[$0] ?? []) }
    }

    static func basketCandidates(for group: RequestDuplicateGroup, lines: [ShopperBasketLine]) -> [ShopperBasketLine] {
        guard let request = group.requests.first else { return [] }
        let name = comparisonName(request.originalItem)
        let reviewedLinks = Set(group.requests.compactMap(\.draftBasketLineId))
        return lines.filter { line in
            if let id = UUID(uuidString: line.id), reviewedLinks.contains(id) { return true }
            return !name.isEmpty && comparisonName(line.originalItem) == name
        }
    }

    static func mealCandidates(for group: RequestDuplicateGroup, state: SharedTrackingState,
                               lines: [ShopperBasketLine]) -> [RequestMealCandidate] {
        guard let request = group.requests.first else { return [] }
        let name = comparisonName(request.originalItem)
        let matchingLines = Set(basketCandidates(for: group, lines: lines).map(\.id))
        let basket = Dictionary(uniqueKeysWithValues: lines.map { ($0.id, $0) })
        let contributions = Dictionary(uniqueKeysWithValues: state.graph.contributions.filter { $0.removedAt == nil }.map { ($0.id, $0) })
        let bindings = Dictionary(uniqueKeysWithValues: state.bindings.map { ($0.factId, $0.contributionId) })
        return state.catalog.compactMap { fact in
            switch fact.source {
            case .meal: break
            case .reservation(_, _, let occurrence, _, _, _) where occurrence != nil: break
            default: return nil
            }
            let contribution = bindings[fact.id].flatMap { contributions[$0] }
            let line = contribution.flatMap { basket[$0.lineId.string] }
            let matchesWording = !name.isEmpty && comparisonName(fact.originalText) == name
            guard matchesWording || line.map({ matchingLines.contains($0.id) }) == true else { return nil }
            return RequestMealCandidate(fact: fact, line: line)
        }
    }

    static func comparisonName(_ original: String) -> String {
        original.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased(with: Locale(identifier: "en_US_POSIX"))
    }
}

@MainActor extension HouseholdInboxModel {
    var duplicateRequestGroups: [RequestDuplicateGroup] {
        guard shop?.shopId == shopID else { return [] }
        return RequestDuplicateGrouping.groups(requests: requests, shopID: shopID, authorized: authorized)
    }

    func duplicateRequestGroup(containing requestID: String) -> RequestDuplicateGroup? {
        duplicateRequestGroups.first { group in group.requests.contains { $0.id == requestID } }
    }

    /// Recheck the selection and the displayed line before prefilling the ordinary decision preview.
    func selectDuplicateLine(_ line: ShopperBasketLine, for request: OwnRequest, shopRevision: Int) {
        guard authorized, !busy, pending == nil, selected == request, availableChoices.contains(.link),
              let shop, shop.shopRevision == shopRevision,
              let group = duplicateRequestGroup(containing: request.id),
              shop.lines.contains(line),
              RequestDuplicateGrouping.basketCandidates(for: group, lines: shop.lines).contains(line)
                || matchingMealNeeds?.contains(where: { $0.line == line }) == true else { return }
        choice = .link
        linkedLineID = line.id
    }
}
