import Foundation
import HouseholdClient

/// A device-local observation. Row labels and other household fields stay in the live projection.
struct ShopPackScope: Codable, Equatable, Sendable {
    let subject: String
    let device: HouseholdDeviceSession
    let shop: UUID
    let authorityEpoch: Int
    let capabilities: [String]
}

struct ShopPackObservation: Codable, Equatable, Sendable {
    let scope: ShopPackScope
    let revision: Int
    let hasEarlierVisit: Bool
    let counts: [UUID: Int]
    var previous: [UUID: Int]

    init(scope: ShopPackScope, revision: Int, lines: [ShopperBasketLine], after last: Self?) throws {
        var packs: [UUID: Int] = [:]
        for line in lines {
            guard let id = UUID(uuidString: line.id), (1...10_000).contains(line.packs),
                  packs.updateValue(line.packs, forKey: id) == nil else { throw ClientError.invalidResponse }
        }
        self.scope = scope
        self.revision = revision
        self.hasEarlierVisit = last?.scope == scope
        self.counts = packs
        self.previous = [:]
        guard let last, last.scope == scope else { return }
        guard revision >= last.revision, revision != last.revision || packs == last.counts else {
            throw ClientError.invalidResponse
        }
        for (id, value) in packs {
            if let origin = last.previous[id] ?? last.counts[id], value != origin { previous[id] = origin }
        }
    }
}
