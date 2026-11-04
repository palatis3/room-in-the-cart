import SwiftUI
import StoreKit

func mtr(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Membership") }

struct MembershipView: View {
    @ObservedObject var model: MembershipModel
    @Environment(\.dismiss) private var dismiss
    @State private var showingManage = false

    var body: some View {
        List {
            Section {
                Text(mtr("Planning for your household")).font(.title2.bold())
                Text(mtr("Rotations, pack pairings, guest scenarios and planning history for up to two named adults."))
                Text(mtr("A seat does not give access to a shop, its budget or the shopper’s approval role."))
                    .font(.subheadline).foregroundStyle(.secondary)
            }
            Section(mtr("Your membership")) {
                TimelineView(.periodic(from: .now, by: 30)) { _ in
                    Label(model.hasPaidAccess ? mtr("Household access is active") : mtr("Free access"),
                          systemImage: model.hasPaidAccess ? "person.2.fill" : "person.fill")
                }
                if let snapshot = model.state.snapshot {
                    Text(status(snapshot.status))
                    if let until = snapshot.status == .grace ? snapshot.graceExpiresAt : snapshot.expiresAt {
                        LabeledContent(mtr("Access through"), value: until.formatted(date: .abbreviated, time: .omitted))
                    }
                }
                Text(mtr("Your saved records, exports, manual planning and one reusable dinner remain available on Free."))
            }
            if let context = model.context {
                Section(mtr(context.appAccountToken == nil ? "Household account" : "Purchase for")) {
                    LabeledContent(mtr("Account"), value: context.purchaserName)
                    LabeledContent(mtr("Household"), value: context.householdName)
                    if context.appAccountToken == nil {
                        Text(mtr("Your named seat uses this household’s membership. Only its purchaser can subscribe or change seats.")).font(.footnote)
                    } else {
                        Text(mtr("This purchase is linked to this account and household. Restoring does not transfer it to another household.")).font(.footnote)
                    }
                }
            } else {
                Section { Text(mtr("An adult account and a selected household are needed before subscribing. You can continue using Free.")) }
            }
            Section(mtr("Household subscription")) {
                if let offer = model.offer {
                    Text(offer.displayName).font(.headline)
                    Text(String(format: mtr("%@ every %@"), offer.displayPrice, offer.localizedPeriod))
                        .font(.title3).monospacedDigit()
                    Text(mtr("Payment is charged to your Apple Account. The subscription renews automatically unless canceled at least 24 hours before the current period ends. Manage or cancel in your Apple subscriptions."))
                        .font(.footnote)
                    Button(mtr("Subscribe to Household")) { Task { await model.purchase() } }
                        .buttonStyle(PrimaryAction()).disabled(!model.canPurchase)
                        .accessibilityIdentifier("membership.subscribe")
                } else {
                    Text(mtr("The subscription offer is unavailable. Your Free access is ready to use."))
                    Button(mtr("Retry offer")) { Task { await model.loadOffer() } }.disabled(model.isBusy)
                }
                if !model.configuration.isReady {
                    Text(mtr("Purchases are not available in this build."))
                }
                if model.isBusy { ProgressView(mtr("Checking with Apple and your household…")) }
                if let notice = model.notice {
                    Text(noticeText(notice)).accessibilityIdentifier("membership.notice")
                }
            }
            if let seats = model.state.snapshot?.seats {
                Section(mtr("Named adult seats")) {
                    ForEach(seats) { seat in
                        VStack(alignment: .leading, spacing: 8) {
                            Label(seat.displayName, systemImage: "person.crop.circle")
                            if model.canManageSeats {
                                Menu(mtr("Manage seat")) {
                                    Button(mtr("Revoke seat"), role: .destructive) {
                                        Task { await model.replaceSeat(userID: nil, replacingUserID: seat.userID) }
                                    }
                                    ForEach(model.eligibleAdults.filter { candidate in !seats.contains(where: { $0.userID == candidate.userID }) }) { adult in
                                        Button(String(format: mtr("Transfer to %@"), adult.displayName)) {
                                            Task { await model.replaceSeat(userID: adult.userID, replacingUserID: seat.userID) }
                                        }
                                    }
                                }.disabled(model.isBusy)
                            }
                        }
                    }
                    if model.canManageSeats && seats.count < 2 {
                        ForEach(model.eligibleAdults.filter { candidate in !seats.contains(where: { $0.userID == candidate.userID }) }) { adult in
                            Button(String(format: mtr("Assign seat to %@"), adult.displayName)) {
                                Task { await model.replaceSeat(userID: adult.userID, replacingUserID: nil) }
                            }.disabled(model.isBusy)
                        }
                    }
                    Text(mtr("Seat changes require an authorized household account. Subscription restoration never adds an extra seat."))
                        .font(.footnote)
                }
            }
            Section {
                Button(mtr("Restore Purchases")) { Task { await model.restore() } }
                    .disabled(model.isBusy).accessibilityIdentifier("membership.restore")
                Button(mtr("Manage Subscription")) { showingManage = true }
                    .accessibilityIdentifier("membership.manage")
                if let privacy = model.configuration.privacyURL { Link(mtr("Privacy Policy"), destination: privacy) }
                if let terms = model.configuration.termsURL { Link(mtr("Terms of Use"), destination: terms) }
                Button(mtr("Continue with Free")) { dismiss() }
                    .accessibilityIdentifier("membership.free")
            } footer: { Text(mtr("Groceries are purchased from your retailer. Household pays for planning tools.")) }
        }
        .workingSurface()
        .navigationTitle(mtr("Membership"))
        .manageSubscriptionsSheet(isPresented: $showingManage)
        .onChange(of: showingManage) { _, showing in if !showing { Task { await model.refresh() } } }
        .task { await model.start() }
    }

    private func status(_ value: MembershipStatus) -> String {
        switch value {
        case .free: return mtr("No verified Household subscription")
        case .active: return mtr("Subscription verified")
        case .grace: return mtr("Apple has allowed a billing grace period. Check your payment method in Manage Subscription.")
        case .expired: return mtr("Subscription expired. Your Free work is preserved.")
        case .revoked: return mtr("Paid access ended after a refund or revocation. Your Free work is preserved.")
        case .billingRetry: return mtr("Apple is retrying payment. Free access remains available.")
        }
    }

    private func noticeText(_ notice: MembershipModel.Notice) -> String {
        switch notice {
        case .pending: return mtr("Purchase pending Apple approval. Paid access has not been added.")
        case .cancelled: return mtr("Purchase canceled. No paid access was added.")
        case .restored: return mtr("Your verified Household membership was restored.")
        case .delivered: return mtr("Apple’s transaction was saved by your household service. Your membership status is shown above.")
        case .failed(let failure):
            switch failure {
            case .signInRequired: return mtr("Sign in to an adult account and select its household to restore or subscribe.")
            case .wrongHousehold, .accountMismatch: return mtr("This purchase belongs to another account or household. Use the original purchasing account to restore it.")
            case .unverified, .invalidReceipt, .invalidSnapshot, .serverRejected: return mtr("The purchase could not be verified. Paid access has not been added. Try Restore Purchases or contact support.")
            case .notConfigured: return mtr("Purchases are not available in this build.")
            case .unavailable: return mtr("No active membership was found, or Apple’s offer is unavailable. Try again. Free access remains available.")
            case .membershipInactive: return mtr("Household access is inactive. Your Free work remains available.")
            case .notPurchaser: return mtr("Your named seat uses this household’s membership. Only its purchaser can subscribe or change seats.")
            case .refreshRequired: return mtr("Membership changed. Refresh its status and review the seat change again.")
            case .deliveryPending: return mtr("Purchase delivery is pending. Use Restore Purchases when connected. You can use Free while waiting.")
            }
        }
    }
}
