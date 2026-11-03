import Foundation
import CoreDomain
import HouseholdClient

struct PickupDecisionEvidence: Identifiable {
    let id: String
    let draft: FamilyDecisionInput
    let exclusions: [String]
    let retailerResponse: String?
    let arrivals: [ReceiptFragment]

    static func records(in journey: PickupJourney) -> [Self] {
        let order = journey.pickup?.orderLines ?? []
        let receipts = journey.pickup?.receipts ?? []
        let occasion = journey.context?.slot
        func details(for lineID: UUID) -> [PickupNeedDetail] {
            let ids = Set(journey.needs.filter { $0.orderLineID == lineID }.map(\.id))
            return journey.needDetails.filter { ids.contains($0.id) }
        }
        var list: [Self] = []
        for offer in journey.offers where !offer.householdPreference.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let details = details(for: offer.lineID)
            let dishes = details.map(\.mealName).filter { !$0.isEmpty }.joined(separator: ", ")
            let product = offer.replacement.isEmpty ? order.first { $0.id == offer.lineID }?.name : offer.replacement
            list.append(.init(id: "\(journey.id)/offer/\(offer.id)",
                draft: .init(kind: .preference, dish: dishes.isEmpty ? nil : dishes, product: product,
                    occasion: occasion, decision: offer.householdPreference, outcome: nil),
                exclusions: Array(Set(details.flatMap(\.exclusions))).sorted(), retailerResponse: offer.retailerResponse.isEmpty ? nil : offer.retailerResponse, arrivals: receipts.filter { $0.key.orderLineID == offer.lineID }))
        }
        for repair in journey.repairs {
            let need = journey.needs.first { $0.id == repair.needID }
            let urgent = journey.urgent.first { $0.id == repair.needID }
            let detail = journey.needDetails.first { $0.id == repair.needID }
            let product = need.flatMap { need in order.first { $0.id == need.orderLineID }?.name } ?? urgent?.food
            list.append(.init(id: "\(journey.id)/repair/\(repair.id)",
                draft: .init(kind: .approval, dish: detail?.mealName ?? need?.name ?? urgent?.meal, product: product,
                    occasion: occasion, decision: repair.instruction, outcome: nil),
                exclusions: detail?.exclusions ?? [], retailerResponse: nil, arrivals: receipts.filter { $0.key.orderLineID == need?.orderLineID }))
        }
        return list
    }
}
