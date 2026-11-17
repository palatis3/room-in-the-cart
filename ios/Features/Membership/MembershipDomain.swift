import Foundation

/// Comes from the authenticated adult session, never from editable purchase-form IDs.
struct MembershipContext: Equatable, Sendable {
    let purchaserID: String
    let purchaserName: String
    let householdID: String
    let householdName: String
    /// Nil for an authenticated non-purchaser reading a shared named seat.
    var appAccountToken: UUID?
}

struct MembershipSeat: Codable, Equatable, Identifiable, Sendable {
    let userID: String
    let displayName: String
    let isAdult: Bool
    var id: String { userID }
}

enum MembershipStatus: String, Codable, Sendable {
    case free, active, grace, expired, revoked, billingRetry
}

/// Only an authenticated entitlement service may supply this projection. It is deliberately
/// not persisted as an unsigned offline unlock. Shop/planning grants are separate server checks.
struct MembershipSnapshot: Codable, Equatable, Sendable {
    let householdID: String
    let purchaserID: String
    let revision: Int
    let status: MembershipStatus
    let expiresAt: Date?
    let graceExpiresAt: Date?
    let verifiedAt: Date
    let validUntil: Date
    let seats: [MembershipSeat]

    func hasPaidAccess(for userID: String, now: Date) -> Bool {
        guard now >= verifiedAt, now < validUntil,
              seats.contains(where: { $0.userID == userID && $0.isAdult }) else { return false }
        switch status {
        case .active: return expiresAt.map { now < $0 } ?? false
        case .grace: return graceExpiresAt.map { now < $0 } ?? false
        default: return false
        }
    }
}

struct SignedMembershipTransaction: Sendable {
    let transactionID: String
    let originalTransactionID: String
    let productID: String
    let signedTransactionInfo: String
    let appAccountToken: UUID?
}

struct MembershipDeliveryReceipt: Codable, Sendable {
    let acceptedTransactionID: String
    let durable: Bool
    let snapshot: MembershipSnapshot
}

enum MembershipFailure: Error, Equatable {
    case notConfigured, signInRequired, unavailable, unverified, wrongHousehold
    case invalidSnapshot, invalidReceipt, deliveryPending, serverRejected, accountMismatch, refreshRequired, notPurchaser, membershipInactive
}

/// Implementations must verify with Apple on the server and commit before returning durable=true.
/// The service must authenticate the caller and recheck household membership and seat authority.
@MainActor protocol MembershipEntitlementService {
    func purchaseContext(householdID: String) async throws -> UUID
    func submit(_ transaction: SignedMembershipTransaction, context: MembershipContext) async throws -> MembershipDeliveryReceipt
    func fetch(context: MembershipContext) async throws -> MembershipSnapshot
    func seatCandidates(context: MembershipContext) async throws -> [MembershipSeat]
    func replaceSeat(userID: String?, replacingUserID: String?, context: MembershipContext, revision: Int) async throws -> MembershipSnapshot
}

struct UnavailableMembershipService: MembershipEntitlementService {
    func purchaseContext(householdID: String) async throws -> UUID { throw MembershipFailure.notConfigured }
    func submit(_ transaction: SignedMembershipTransaction, context: MembershipContext) async throws -> MembershipDeliveryReceipt { throw MembershipFailure.notConfigured }
    func fetch(context: MembershipContext) async throws -> MembershipSnapshot { throw MembershipFailure.notConfigured }
    func seatCandidates(context: MembershipContext) async throws -> [MembershipSeat] { throw MembershipFailure.notConfigured }
    func replaceSeat(userID: String?, replacingUserID: String?, context: MembershipContext, revision: Int) async throws -> MembershipSnapshot { throw MembershipFailure.notConfigured }
}

/// No local-data repository is accepted here: billing cannot delete Free work or restore consent.
struct MembershipState: Equatable {
    private(set) var snapshot: MembershipSnapshot?
    private var lastRemovedSeatRevision: Int?
    private(set) var issue: MembershipFailure?
    var freeRecordsAndExportAvailable: Bool { true }
    var freeManualPlanningAvailable: Bool { true }
    var freeReusableDinnerCount: Int { 1 }
    var grantsShopperAuthority: Bool { false }
    var grantsBudgetAccess: Bool { false }
    var grantsHouseholdPlanningPermission: Bool { false }

    mutating func accept(_ incoming: MembershipSnapshot, context: MembershipContext, now: Date) throws {
        guard incoming.householdID == context.householdID else { throw MembershipFailure.wrongHousehold }
        guard incoming.revision >= 0, incoming.verifiedAt <= now,
              incoming.validUntil >= incoming.verifiedAt,
              incoming.seats.count <= 2, incoming.seats.allSatisfy({ $0.isAdult && !$0.userID.isEmpty && !$0.displayName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }),
              Set(incoming.seats.map(\.userID)).count == incoming.seats.count else { throw MembershipFailure.invalidSnapshot }
        // An unseated adult receives a private Free snapshot with revision zero.
        // Keep the old revision alone so an in-flight paid response cannot restore its roster.
        if context.appAccountToken == nil {
            if incoming.revision == 0 && incoming.status == .free && incoming.purchaserID == context.purchaserID
                && incoming.seats.isEmpty && incoming.expiresAt == nil && incoming.graceExpiresAt == nil {
                if let current = snapshot {
                    guard incoming.verifiedAt >= current.verifiedAt else { return }
                    if current.revision > 0 { lastRemovedSeatRevision = current.revision }
                }
                snapshot = incoming
                issue = nil
                return
            }
            if let lastRemovedSeatRevision, incoming.revision <= lastRemovedSeatRevision { return }
            if let current = snapshot, current.revision == 0, current.status == .free,
               incoming.verifiedAt < current.verifiedAt { return }
        }
        // A refund/revocation may have an earlier expiry than an old active receipt.
        if let current = snapshot {
            guard incoming.revision >= current.revision else { return }
            if incoming.revision == current.revision {
                guard incoming.householdID == current.householdID,
                      incoming.purchaserID == current.purchaserID, incoming.status == current.status,
                      incoming.expiresAt == current.expiresAt, incoming.graceExpiresAt == current.graceExpiresAt,
                      incoming.seats == current.seats else { throw MembershipFailure.invalidSnapshot }
                guard incoming.verifiedAt >= current.verifiedAt else { return }
            }
        }
        snapshot = incoming
        issue = nil
    }

    mutating func fail(_ error: MembershipFailure) {
        if error == .signInRequired || error == .membershipInactive { snapshot = nil }
        issue = error
    }
    mutating func clear() { snapshot = nil; lastRemovedSeatRevision = nil; issue = nil }
    func hasPaidAccess(context: MembershipContext?, now: Date) -> Bool {
        guard let context, let snapshot, snapshot.householdID == context.householdID else { return false }
        return snapshot.hasPaidAccess(for: context.purchaserID, now: now)
    }
}

struct MembershipConfiguration: Sendable {
    let productID: String?
    let privacyURL: URL?
    let termsURL: URL?

    static func fromBundle(_ bundle: Bundle = .main) -> Self {
        func value(_ key: String) -> String? {
            guard let value = bundle.object(forInfoDictionaryKey: key) as? String,
                  !value.isEmpty, !value.contains("$(") else { return nil }
            return value
        }
        let pages = HelpConfiguration.fromBundle(bundle)
        return Self(productID: value("HouseholdSubscriptionProductID"), privacyURL: pages.privacyURL, termsURL: pages.termsURL)
    }
    var isReady: Bool { productID != nil && privacyURL != nil && termsURL != nil }
}
