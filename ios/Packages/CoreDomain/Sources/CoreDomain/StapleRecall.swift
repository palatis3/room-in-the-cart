import Foundation

public struct StapleApproval: Codable, Equatable, Sendable {
    public let purpose: String
    public let branch: String
    public let approvedAt: Date
}

public struct StapleSource: Codable, Hashable, Sendable {
    public let shopID: UUID
    public let lineID: UUID
}

public enum StapleChoice: String, Codable, Sendable { case needed, alreadyHandled, skip }

public struct StapleRecallReceipt: Codable, Equatable, Sendable {
    public let source: StapleSource
    public let choice: StapleChoice
    public let newLineID: UUID?
    public let quantity: Quantity?
}

public struct ReviewedStaple: Identifiable, Equatable, Sendable {
    public var id: StapleSource { source }
    public let source: StapleSource
    public let sourceRevision: UUID
    public let targetID: UUID
    public let targetRevision: UUID
    public let approval: StapleApproval
    public let line: ShoppingLine
}

extension LedgerWorkspace {
    public func priorStaples(for targetID: UUID) -> [ReviewedStaple] {
        guard let target = shops.first(where: { $0.id == targetID }) else { return [] }
        let completed = Set((target.stapleReviews ?? []).map(\.source))
        var rows: [ReviewedStaple] = []
        for source in shops where source.id != targetID {
            for line in source.lines where !line.isTrashed {
                guard let approval = line.stapleApproval else { continue }
                let key = StapleSource(shopID: source.id, lineID: line.id)
                rows.append(.init(source:key, sourceRevision:source.revisionID, targetID:targetID,
                    targetRevision:target.revisionID, approval:approval, line:line))
            }
        }
        // Show the most recently approved instance of each purpose at the entered store.
        struct GroupKey: Hashable { let name: String; let purpose: String; let store: String }
        var seen = Set<GroupKey>()
        return rows.sorted {
            if $0.approval.approvedAt != $1.approval.approvedAt { return $0.approval.approvedAt > $1.approval.approvedAt }
            return ($0.source.shopID.uuidString,$0.line.id.uuidString) < ($1.source.shopID.uuidString,$1.line.id.uuidString)
        }.filter { row in
            seen.insert(GroupKey(name:row.line.name,purpose:row.approval.purpose,store:row.approval.branch)).inserted && !completed.contains(row.source)
        }
    }
    public mutating func applyStaple(_ review: ReviewedStaple, choice: StapleChoice, quantity: Quantity?, at date: Date) throws {
        guard (choice == .needed || quantity == nil), quantity.map({ $0.amount > .zero }) ?? true else { throw LedgerError.invalid("stapleQuantity") }
        guard selectedShopID == review.targetID, let index = shops.firstIndex(where: { $0.id == review.targetID }),
              let source = shops.first(where: { $0.id == review.source.shopID }), source.id != review.targetID else { throw LedgerError.stalePreview }
        if let original = shops[index].stapleReviews?.first(where: { $0.source == review.source }) {
            guard original.choice == choice, original.quantity == quantity else { throw LedgerError.stalePreview }
            return
        }
        guard shops[index].revisionID == review.targetRevision, source.revisionID == review.sourceRevision,
              source.lines.contains(review.line), !review.line.isTrashed, review.line.stapleApproval == review.approval else { throw LedgerError.stalePreview }
        let exclusions = Array(Set(source.contributions(forLineID: review.line.id).flatMap(\.exclusions))).sorted()
        try shops[index].recordStaple(review, choice:choice, quantity:quantity, exclusions:exclusions, at:date)
    }
}
