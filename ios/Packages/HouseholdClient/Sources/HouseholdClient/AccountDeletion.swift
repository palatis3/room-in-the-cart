import Foundation
import Security

public struct DeletionPreview: Decodable, Sendable {
    public struct Adult: Decodable, Sendable { public let memberId, alias: String; public let organizer: Bool }
    public struct Child: Decodable, Sendable { public let memberId, alias: String }
    public struct Shop: Decodable, Sendable { public let shopId, phase: String; public let revision, authorityEpoch: Int }
    public struct Household: Decodable, Sendable {
        public let householdId, memberId, label, state: String
        public let organizer: Bool
        public let otherAdults: [Adult]
        public let activeShops: [Shop]
        public let soleGuardianChildren: [Child]
        public var needsOrganizer: Bool { organizer && !otherAdults.contains(where: \.organizer) }
    }
    public let adult, deletionAvailable, reauthenticationRequired: Bool
    public let verifiedBackupRetentionDays: Int?
    public let households: [Household]
}

public struct DeletionChoices {
    // Shop and member identifiers are unique within a household in the service schema.
    public struct Target: Hashable {
        let household, id: String
        public init(household: String, id: String) { self.household = household; self.id = id }
    }
    public enum Responsibility: Hashable { case archiveOrClose, transfer(String) }
    public var organizers: [String: Responsibility] = [:]
    public var shops: [Target: Responsibility] = [:]
    public var children: Set<Target> = []
    public init() {}

    public func dispositions(for preview: DeletionPreview) throws -> [HouseholdDisposition] {
        guard preview.adult, preview.deletionAvailable, !preview.reauthenticationRequired else { throw ClientError.accessEnded }
        return try preview.households.map(disposition)
    }

    public func exit(_ household: DeletionPreview.Household, in preview: DeletionPreview) throws -> HouseholdDisposition {
        guard preview.adult, !preview.reauthenticationRequired, household.state == "active",
              let reviewed = preview.households.first(where: { $0.householdId == household.householdId }),
              reviewed.state == "active", reviewed.soleGuardianChildren.isEmpty else { throw ClientError.accessEnded }
        return try disposition(reviewed)
    }

    private func disposition(_ household: DeletionPreview.Household) throws -> HouseholdDisposition {
        func successor(_ choice: Responsibility?) throws -> String? {
            switch choice {
            case .archiveOrClose: return nil
            case let .transfer(id) where household.otherAdults.contains(where: { $0.memberId == id }): return id
            default: throw ClientError.configuration
            }
        }
        let next = household.needsOrganizer ? try successor(organizers[household.householdId]) : nil
        let shopChoices = try household.activeShops.map { shop in
            let next = try successor(shops[Target(household: household.householdId, id: shop.shopId)])
            return HouseholdDisposition.Shop(shopId: shop.shopId, revision: shop.revision, authorityEpoch: shop.authorityEpoch,
                                             action: next == nil ? "close" : "transfer", memberId: next)
        }
        let childIDs = household.soleGuardianChildren.map(\.memberId)
        guard childIDs.allSatisfy({ children.contains(Target(household: household.householdId, id: $0)) }) else { throw ClientError.configuration }
        return HouseholdDisposition(householdId: household.householdId,
                                    organizer: household.needsOrganizer ? (next == nil ? "archive" : "transfer") : "none",
                                    organizerMemberId: next, shops: shopChoices, eraseChildProfiles: childIDs)
    }
}

public struct HouseholdDisposition: Encodable, Sendable {
    struct Shop: Encodable, Sendable { let shopId: String; let revision, authorityEpoch: Int; let action: String; let memberId: String? }
    let householdId, organizer: String
    let organizerMemberId: String?
    let shops: [Shop]
    let eraseChildProfiles: [String]
}

public struct DeletionStatus: Decodable, Sendable {
    public enum State: String, Decodable, Sendable { case pending, complete }
    public let jobId: UUID
    public let status: State
    public let appDataErased, providerAccountDeleted: Bool
    public let completedAt: String?
    public let receiptExpiresAt: String
    func checked(for receipt: DeletionReceipt) throws -> Self {
        guard jobId == receipt.id, status != .complete || (appDataErased && providerAccountDeleted && completedAt != nil)
        else { throw ClientError.invalidResponse }
        return self
    }
}

/// A device-only capability. Do not log it, put it in a URL or attach it to authenticated requests.
public struct DeletionReceipt: Codable, Identifiable, Sendable {
    public let id: UUID
    public let subject: String
    public let created: Date
    let statusToken: String
}

@MainActor public struct DeletionReceipts {
    private let vault: any RefreshTokenVault
    public init(vault: any RefreshTokenVault) { self.vault = vault }
    public func saved() throws -> [DeletionReceipt] {
        guard let value = try vault.read() else { return [] }
        return try JSONDecoder().decode([DeletionReceipt].self, from: Data(value.utf8))
    }
    public func prepare(subject: String) throws -> DeletionReceipt {
        var saved = try saved()
        if let existing = saved.first(where: { $0.subject == subject }) { return existing }
        var bytes = [UInt8](repeating: 0, count: 32)
        guard SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) == errSecSuccess else { throw ClientError.configuration }
        let token = Data(bytes).base64EncodedString().replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        let receipt = DeletionReceipt(id: UUID(), subject: subject, created: Date(), statusToken: token)
        saved.append(receipt)
        try vault.write(String(decoding: encoded(saved), as: UTF8.self))
        return receipt
    }
    public func remove(_ id: UUID) throws {
        let remaining = try saved().filter { $0.id != id }
        if remaining.isEmpty { try vault.clear() }
        else { try vault.write(String(decoding: encoded(remaining), as: UTF8.self)) }
    }
}
