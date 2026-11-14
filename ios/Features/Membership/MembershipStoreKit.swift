import Foundation
import StoreKit

struct MembershipOffer: Equatable, Sendable {
    let productID: String
    let displayName: String
    let displayPrice: String
    let periodValue: Int
    let periodUnit: PeriodUnit
    enum PeriodUnit: String, Sendable { case day, week, month, year }

    var localizedPeriod: String {
        var components = DateComponents()
        switch periodUnit {
        case .day: components.day = periodValue
        case .week: components.weekOfMonth = periodValue
        case .month: components.month = periodValue
        case .year: components.year = periodValue
        }
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.maximumUnitCount = 1
        return formatter.string(from: components) ?? String(periodValue)
    }
}

enum MembershipPurchaseOutcome: Sendable {
    case verified(SignedMembershipTransaction), pending, cancelled, unverified
}

@MainActor protocol MembershipStorefront {
    func load(productID: String) async throws -> MembershipOffer
    func purchase(appAccountToken: UUID) async throws -> MembershipPurchaseOutcome
    func currentTransactions() async -> [MembershipPurchaseOutcome]
    func unfinishedTransactions() async -> [MembershipPurchaseOutcome]
    func updates(for productID: String) -> AsyncStream<MembershipPurchaseOutcome>
    func finish(transactionID: String) async
    func sync() async throws
}

/// StoreKit verifies on-device first. Shared access is still only granted by the server.
@MainActor final class StoreKitMembershipStorefront: MembershipStorefront {
    private var product: Product?
    private var transactions: [String: StoreKit.Transaction] = [:]
    private var productID: String?

    func load(productID: String) async throws -> MembershipOffer {
        self.productID = productID
        product = nil
        guard let loaded = try await Product.products(for: [productID]).first(where: { $0.id == productID }),
              loaded.type == .autoRenewable, let subscription = loaded.subscription,
              subscription.subscriptionPeriod.unit == .year, subscription.subscriptionPeriod.value == 1 else {
            throw MembershipFailure.unavailable
        }
        product = loaded
        return MembershipOffer(productID: loaded.id, displayName: loaded.displayName,
                               displayPrice: loaded.displayPrice, periodValue: subscription.subscriptionPeriod.value,
                               periodUnit: .year)
    }

    func purchase(appAccountToken: UUID) async throws -> MembershipPurchaseOutcome {
        guard let product else { throw MembershipFailure.unavailable }
        switch try await product.purchase(options: [.appAccountToken(appAccountToken)]) {
        case .success(let result): return convert(result) ?? .unverified
        case .pending: return .pending
        case .userCancelled: return .cancelled
        @unknown default: return .unverified
        }
    }

    func currentTransactions() async -> [MembershipPurchaseOutcome] {
        var outcomes: [MembershipPurchaseOutcome] = []
        for await result in StoreKit.Transaction.currentEntitlements {
            if let value = convert(result) { outcomes.append(value) }
        }
        return outcomes
    }

    func unfinishedTransactions() async -> [MembershipPurchaseOutcome] {
        var outcomes: [MembershipPurchaseOutcome] = []
        for await result in StoreKit.Transaction.unfinished {
            if let value = convert(result) { outcomes.append(value) }
        }
        return outcomes
    }

    func updates(for productID: String) -> AsyncStream<MembershipPurchaseOutcome> {
        self.productID = productID
        return AsyncStream { continuation in
            let task = Task { @MainActor [weak self] in
                for await result in StoreKit.Transaction.updates {
                    guard !Task.isCancelled, let self else { break }
                    guard let value = self.convert(result) else { continue }
                    continuation.yield(value)
                    if case .unverified = value,
                       let recovered = await self.verifiedCurrentTransaction(after: result) {
                        continuation.yield(recovered)
                    }
                }
                continuation.finish()
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    func verifiedCurrentTransaction(after update: VerificationResult<StoreKit.Transaction>) async -> MembershipPurchaseOutcome? {
        guard case .unverified(let rejected, .invalidCertificateChain) = update,
              rejected.productID == productID else { return nil }
        // The rejected update only identifies what to look up. Submit a signed
        // transaction only if StoreKit separately verifies that exact purchase.
        for await result in StoreKit.Transaction.currentEntitlements {
            guard !Task.isCancelled else { break }
            if case .verified(let current) = result,
               current.id == rejected.id, current.productID == productID,
               current.environment == rejected.environment, current.appAccountToken == rejected.appAccountToken,
               current.revocationDate == nil, !current.isUpgraded,
               let expiry = current.expirationDate, expiry > Date() {
                return convert(result)
            }
        }
        return nil
    }

    func finish(transactionID: String) async {
        guard let transaction = transactions[transactionID] else { return }
        await transaction.finish()
        transactions.removeValue(forKey: transactionID)
    }

    func sync() async throws { try await AppStore.sync() }

    private func convert(_ result: VerificationResult<StoreKit.Transaction>) -> MembershipPurchaseOutcome? {
        switch result {
        case .verified(let transaction):
            guard transaction.productID == productID else { return nil }
            transactions[String(transaction.id)] = transaction
            return .verified(SignedMembershipTransaction(transactionID: String(transaction.id),
                originalTransactionID: String(transaction.originalID), productID: transaction.productID,
                signedTransactionInfo: result.jwsRepresentation, appAccountToken: transaction.appAccountToken))
        case .unverified(let transaction, _):
            return transaction.productID == productID ? .unverified : nil
        }
    }
}
