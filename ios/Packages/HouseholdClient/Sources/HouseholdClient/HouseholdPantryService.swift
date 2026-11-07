import Foundation

extension HouseholdService {
    public func pantryLots(reviewed delivery: SharedDeliveryPage) async throws -> SharedPantryPage {
        let shopID = delivery.shopId.uuidString.lowercased(), start = generation
        try await authorizeShopper(shopID: shopID, capability: "pantry_lots")
        var record: SharedPantryPage?
        var seen = Set<UUID>()
        repeat {
            guard start == generation else { throw ClientError.cancelled }
            let cursor = record?.nextCursor
            let page: SharedPantryPage = try await perform("shops/\(shopID)/pantry-lots", method: "GET",
                query: cursor.map { [URLQueryItem(name: "cursor", value: $0.uuidString.lowercased())] } ?? [])
            try page.validateScope(delivery: delivery)
            if let record, record.pantryRevision != page.pantryRevision {
                throw ClientError.service(status: 409, code: "stale_supply", correlationID: nil, retryAfter: nil)
            }
            guard page.lots.count <= 50, cursor == nil || !page.lots.isEmpty,
                  page.lots.allSatisfy({ seen.insert($0.id).inserted }),
                  page.nextCursor == nil || (page.lots.count == 50 && page.nextCursor == page.lots.last?.id) else { throw ClientError.invalidResponse }
            if record == nil { record = page }
            else { record?.lots.append(contentsOf: page.lots); record?.nextCursor = page.nextCursor }
        } while record?.nextCursor != nil
        guard let record else { throw ClientError.invalidResponse }
        try record.validate(delivery: delivery)
        return record
    }

    public func foodCoverage(reviewed pantry: SharedPantryPage, delivery: SharedDeliveryPage) async throws -> SharedFoodCoverage {
        try pantry.validate(delivery: delivery)
        let shopID = delivery.shopId.uuidString.lowercased(), start = generation
        try await authorizeShopper(shopID: shopID, capability: "pantry_lots")
        guard start == generation else { throw ClientError.cancelled }
        let coverage: SharedFoodCoverage = try await perform("shops/\(shopID)/pantry-lots/coverage", method: "GET")
        try coverage.validate(reviewed: pantry, delivery: delivery)
        return coverage
    }

    public func previewPantryObservation(_ edit: SharedPantryEdit, reviewed pantry: SharedPantryPage, delivery: SharedDeliveryPage) async throws -> SharedPantryObservationPreview {
        guard case let .observe(id, _, _, _) = edit, let lot = pantry.lots.first(where: { $0.id == id }) else { throw ClientError.configuration }
        let body = try edit.body(reviewed: pantry, delivery: delivery)
        let start = generation
        let coverage = try await foodCoverage(reviewed: pantry, delivery: delivery)
        guard start == generation else { throw ClientError.cancelled }
        let preview: SharedPantryObservationPreview = try await perform("shops/\(pantry.shopId.uuidString.lowercased())/pantry-lots/observation-preview",
            method: "POST", body: encoded(body))
        try preview.validate(lot: lot, coverage: coverage)
        return preview
    }
}

extension ShopperReceipt {
    func validatePantry(_ command: CommandEnvelope) throws {
        guard disposition == "recorded", kind == command.kind, shopId == command.shopId,
              shopRevision == command.base.shopRevision, authorityEpoch == command.base.authorityEpoch,
              let operation = UUID(uuidString: operationId), let lotId, let supplyRevision, let pantryRevision,
              command.body["supplyRevision"] == .integer(supplyRevision), supplyRevision >= 0, pantryRevision > 0,
              command.body["pantryRevision"] == .integer(pantryRevision - 1) else { throw ClientError.invalidResponse }
        switch kind {
        case "pantry.create": guard lotId == operation else { throw ClientError.invalidResponse }
        case "pantry.storeDelivery": guard command.body["sourceId"] == .string(lotId.uuidString.lowercased()) else { throw ClientError.invalidResponse }
        default:
            guard command.body["lotId"] == .string(lotId.uuidString.lowercased()), lotId != operation,
                  command.body["predecessorId"] != .string(operation.uuidString.lowercased()) else { throw ClientError.invalidResponse }
        }
    }
}
