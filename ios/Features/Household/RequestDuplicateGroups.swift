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

    private static func comparisonName(_ original: String) -> String {
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
}
