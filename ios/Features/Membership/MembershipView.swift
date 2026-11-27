import SwiftUI
import StoreKit
import UIKit
import CoreDomain

func mtr(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "Membership") }

struct MembershipPage<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) { content }
                .frame(maxWidth: 560, alignment: .leading)
                .padding(20)
                .frame(maxWidth: .infinity)
        }
        .workingSurface()
        .tint(Theme.action)
    }
}

struct MembershipHeading: View {
    let title: String
    let symbol: String
    var body: some View {
        Label {
            Text(title)
                .marketJournalTitle()
                .fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: symbol)
                .font(.headline).foregroundStyle(Theme.action)
                .accessibilityHidden(true)
        }
        .foregroundStyle(Theme.ink)
        .accessibilityAddTraits(.isHeader)
    }
}

struct MembershipFreeTools: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mtr("Included with Free")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(mtr("Make a private shopping list, plan dinners by hand, save one dinner to use again and compare two store quotes you enter."))
            Text(mtr("You can keep and export your own records."))
                .foregroundStyle(Theme.secondary)
        }
    }
}

struct MembershipBenefits: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(mtr("What Household adds")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(mtr("Save dinner rotations and compare what two plans put on your shopping list. Household includes up to two named adult planners."))
        }
    }
}

struct MembershipSampleLink: View {
    var offer: MembershipOffer? = nil
    var body: some View {
        NavigationLink {
            MembershipDinnerSampleView(presentedOffer: offer)
        } label: {
            Label(mtr("Compare two sample dinners"), systemImage: "basket")
                .frame(minHeight: 44)
        }
        .accessibilityIdentifier("membership.sample")
    }
}

private struct MembershipDinnerSampleView: View {
    let presentedOffer: MembershipOffer?
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var catalogOffer: MembershipOffer?
    @State private var soup = false
    @State private var currency = Currency.groceryDefault()
    var body: some View {
        WorkingForm {
            Section {
                Text(mtr("Sample basket for two. Four tortillas are on hand. Keep one for each of tomorrow’s two lunches."))
                    .fixedSize(horizontal: false, vertical: true)
                Picker(mtr("Sample grocery currency"), selection: $currency) {
                    ForEach(Currency.allCases, id: \.self) { Text(verbatim: $0.rawValue).tag($0) }
                }
            }
            Section {
                if typeSize.isAccessibilitySize { dinnerPicker.pickerStyle(.menu) }
                else { dinnerPicker.pickerStyle(.segmented) }
                if let options = try? DinnerBasketSample.compare(currency: currency) {
                    let basket = soup ? options.soup : options.tacos
                    VStack(alignment: .leading, spacing: 5) {
                        resultLine(mtr("Known grocery subtotal"), value: moneyText(basket.result.checkout.total.lowerBound))
                            .font(.headline).accessibilityIdentifier("membership.sample.subtotal")
                        resultLine(mtr("Beans"), value: mtr("Price missing"))
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                            .accessibilityIdentifier("membership.sample.unpriced")
                    }
                    Text(soup ? mtr("Soup uses four tortillas and a carton of broth.") : mtr("Tacos use eight tortillas."))
                    LabeledContent(mtr("Tortilla packs of four"),
                        value: String(format: mtr("%lld × %@"), basket.tortillaPacks, moneyText(basket.tortillaPackPrice)))
                    if let price = basket.brothPrice { LabeledContent(mtr("One carton of broth"), value: moneyText(price)) }
                    if let difference = try? options.tacos.result.checkout.total.lowerBound.subtracting(options.soup.result.checkout.total.lowerBound) {
                        Text(String(format: mtr("The soup basket costs %@ less for the priced items. Both baskets still need a price for beans."), moneyText(difference)))
                    }
                } else {
                    Text(mtr("The sample could not be calculated."))
                }
            }
            Section {
                NavigationLink {
                    MembershipWeekSample(currency: currency)
                } label: {
                    Label(mtr("Change a sample week"), systemImage: "calendar")
                }
                .accessibilityIdentifier("membership.sample.changeWeek")
                NavigationLink(dinnerText("First shop with a whole bottle")) { WholePackTripExample(currency: currency) }
                    .accessibilityIdentifier("membership.sample.firstTrip")
                NavigationLink(dinnerText("Compare a chosen two-store split")) {
                    WorkingForm {
                        Text(dinnerText("Fictional sample prices"))
                        GrocerySplitPreview(sample: currency).id(currency)
                    }.navigationTitle(dinnerText("Compare a chosen two-store split"))
                }
            }
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Group {
                if let offer = catalogOffer ?? presentedOffer {
                    Text(String(format: mtr("Household · %@ per year for up to two named adult planners"), offer.displayPrice))
                } else {
                    Text(mtr("Household Annual includes up to two named adult planners."))
                }
            }
            .font(.footnote).frame(maxWidth: .infinity).padding().background(.bar)
            .accessibilityIdentifier("membership.sample.annualTerms")
        }
        .task {
            guard let productID = MembershipConfiguration.fromBundle().productID else { return }
            catalogOffer = try? await StoreKitMembershipStorefront().load(productID: productID)
        }
        .navigationTitle(mtr("Dinner comparison example"))
        .navigationBarTitleDisplayMode(.inline)
    }

    private var dinnerPicker: some View {
        Picker(mtr("Dinner"), selection: $soup) {
            Text(mtr("Tacos")).tag(false)
            Text(mtr("Tortilla soup")).tag(true)
        }
        .accessibilityIdentifier("membership.sample.dinners")
    }

    private func resultLine(_ label: String, value: String) -> some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .firstTextBaseline) {
                Text(label).fixedSize()
                Spacer(minLength: 12)
                Text(value).fixedSize()
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text(value)
            }.fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(label)
        .accessibilityValue(value)
    }
}

struct MembershipLegalLinks: View {
    let configuration: MembershipConfiguration
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if let terms = configuration.termsURL {
                Link(mtr("Terms of Use"), destination: terms).frame(minHeight: 44)
            }
            if let privacy = configuration.privacyURL {
                Link(mtr("Privacy Policy"), destination: privacy).frame(minHeight: 44)
            }
            if configuration.termsURL == nil || configuration.privacyURL == nil {
                NavigationLink {
                    HelpPrivacyView()
                } label: {
                    Label(helpText("Privacy on this iPhone"), systemImage: "lock")
                        .fixedSize(horizontal: false, vertical: true).frame(minHeight: 44)
                }.accessibilityIdentifier("membership.offlinePrivacy")
            }
        }
    }
}

struct MembershipView: View {
    @ObservedObject var model: MembershipModel
    @ObservedObject var household: HouseholdModel
    let returnsToDinnerComparison: Bool
    let onContinuePlanning: () -> Void
    @Environment(\.dynamicTypeSize) private var typeSize
    @State private var showingManage = false
    @State private var retryingDelivery = false
    @State private var review: SeatChange?

    private var isPurchaserContext: Bool { model.showsPurchaserControls }

    var body: some View {
        MembershipPage {
            if let context = model.context {
                BrandScopeLabel(context.householdName, systemImage: "house")
                    .accessibilityLabel(String(format: mtr("Selected household: %@"), context.householdName))
                    .privacySensitive()
            }
            TimelineView(.periodic(from: .now, by: 15)) { _ in
                VStack(alignment: .leading, spacing: 20) {
                    if model.presentsAnnualOffer && model.state.snapshot?.status == .free {
                        Text(mtr("Free planning")).font(.headline)
                            .accessibilityAddTraits(.isHeader)
                        operationUpdates
                        annualOffer
                        returnButton
                    } else {
                        currentAccess
                        operationUpdates
                        if model.presentsAnnualOffer { Divider(); annualOffer }
                        returnButton
                    }
                    Divider()
                    if isPurchaserContext {
                        Button(mtr("Restore Purchases")) { Task { await model.restore() } }
                            .disabled(model.isBusy).accessibilityIdentifier("membership.restore")
                        Button(mtr("Manage Subscription")) { showingManage = true }
                            .accessibilityIdentifier("membership.manage")
                        if model.canManageSeats, let snapshot = model.state.snapshot {
                            Divider()
                            seatRoster(snapshot)
                        }
                    } else {
                        Button(mtr("Refresh my planning access")) { Task { await model.restore() } }
                            .disabled(model.isBusy || model.isVerifyingMembership)
                            .accessibilityIdentifier("membership.seat.refresh")
                    }
                    Divider()
                    MembershipFreeTools()
                    householdRoles
                    Divider()
                    MembershipLegalLinks(configuration: model.configuration)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .buttonStyle(MembershipTextButton())
        .navigationTitle(mtr("Membership"))
        .navigationBarTitleDisplayMode(.inline)
        .manageSubscriptionsSheet(isPresented: $showingManage)
        .onChange(of: isPurchaserContext) { _, purchaser in
            if !purchaser { showingManage = false; review = nil }
        }
        .onChange(of: showingManage) { _, showing in
            if !showing { Task { await model.refresh() } }
        }
        .onChange(of: model.statusMessages) { before, after in
            if !model.isStopped, let message = after.first(where: { !before.contains($0) }) {
                UIAccessibility.post(notification: .announcement, argument: messageText(message))
            }
        }
        .sheet(item: $review) { change in
            NavigationStack { seatReview(change) }.presentationDetents([.large])
        }
        .task { await model.start() }
    }

    @ViewBuilder private var annualOffer: some View {
        let offer = model.displayedAnnualOffer
        MembershipHeading(title: offer?.displayName ?? mtr("Household subscription"), symbol: "person.2")
        if let offer {
            VStack(alignment: .leading, spacing: 4) {
                let price = Text(verbatim: offer.displayPrice).font(.largeTitle.bold()).monospacedDigit()
                // The storefront admits only a one-year period. Use the localized annual
                // idiom and include the actual StoreKit period in the spoken offer.
                let period = Text(mtr("per year")).font(.title3.weight(.medium)).foregroundStyle(Theme.secondary)
                if typeSize.isAccessibilitySize { price; period }
                else {
                    ViewThatFits(in: .horizontal) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) { price; period }.fixedSize()
                        VStack(alignment: .leading, spacing: 4) { price; period }
                    }
                }
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(String(format: mtr("%@ every %@"), offer.displayPrice, offer.localizedPeriod))
            .accessibilityIdentifier("membership.annualPrice")
            Text(mtr("Save dinner rotations and compare what two plans put on your shopping list. Household includes up to two named adult planners."))
            VStack(alignment: .leading, spacing: 9) {
                Text(String(format: mtr("%@ due when you confirm with Apple."), offer.displayPrice)).font(.headline)
                Text(String(format: mtr("Renews at %@ each year. Apple may charge you in the 24 hours before renewal. Manage or cancel in Apple subscriptions. Apple shows the final charge."), offer.displayPrice))
                    .foregroundStyle(Theme.secondary)
                if let context = model.context {
                    Text(String(format: mtr("Purchasing account: %@"), context.purchaserName))
                        .font(.subheadline).foregroundStyle(Theme.secondary).privacySensitive()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.divider)
                    .accessibilityHidden(true)
            }
            MembershipSampleLink(offer: offer)
            Button(mtr("Subscribe to Household")) {
                guard model.presentsAnnualOffer else { return }
                Task { await model.purchase(fromPresentedOffer: true) }
            }
            .buttonStyle(PrimaryAction()).disabled(!model.canPurchase)
            .accessibilityIdentifier("membership.subscribe")
        } else if model.isLoadingOffer {
            ProgressView(mtr("Loading the subscription offer…"))
        } else if model.configuration.isReady {
            Text(mtr("The subscription offer is unavailable. Your Free access is ready to use."))
            Button(mtr("Retry offer")) { Task { await model.loadOffer() } }
                .disabled(model.isBusy)
        } else {
            Text(mtr("Household subscription purchases are unavailable. You can keep using the free planning tools."))
        }
        if offer == nil { MembershipSampleLink() }
    }

    private var returnButton: some View {
        let title = model.hasPaidAccess ? mtr("Continue planning") : mtr("Continue planning for free")
        return Button(returnsToDinnerComparison ? mtr("Return to dinner comparison") : title, action: onContinuePlanning)
            .buttonStyle(MembershipReturnButtonStyle())
            .accessibilityIdentifier(model.hasPaidAccess ? "membership.continue" : "membership.free")
    }

    @ViewBuilder private var currentAccess: some View {
        let snapshot = model.state.snapshot
        if model.verificationIsStale || (model.verificationFailed && snapshot == nil) {
            MembershipHeading(title: mtr("Membership needs verification"), symbol: "arrow.clockwise")
            Text(mtr("Free tools are available while you check your membership."))
        } else if let snapshot {
            if model.hasPaidAccess {
                MembershipHeading(title: mtr("Your planning access is ready"), symbol: "person.crop.circle.badge.checkmark")
                Text(isPurchaserContext ? mtr("Your account holds a named adult planning seat.") : mtr("You have a named adult seat. The purchasing adult manages billing and seats."))
            } else if model.canManageSeats && isPurchaserContext {
                MembershipHeading(title: mtr("Your Household subscription is active"), symbol: "person.2")
                Text(mtr("You manage the subscription. Your account has no assigned planning seat."))
            } else {
                MembershipHeading(title: mtr("Free planning"), symbol: "list.bullet")
                if !isPurchaserContext {
                    Text(mtr("You can keep making your own authorized requests and planning manually."))
                }
            }
            if isPurchaserContext {
                Text(status(snapshot.status))
                if snapshot.status == .grace, let date = snapshot.graceExpiresAt {
                    termDate(mtr("Billing grace through"), date)
                } else if snapshot.status == .active, let date = snapshot.expiresAt {
                    termDate(mtr("Current paid term ends"), date)
                }
            }
        } else {
            MembershipHeading(title: mtr("Your planning access"), symbol: "person.crop.circle")
            ProgressView(mtr("Checking your household access…"))
        }
        if model.verificationFailed { Text(mtr("Your membership details could not be refreshed.")) }
        if model.verificationIsStale || model.verificationFailed {
            Button(mtr("Check membership again")) { Task { await model.verifyMembership() } }
                .disabled(model.isVerifyingMembership || model.isBusy)
                .accessibilityIdentifier("membership.verify")
        }
    }

    private func termDate(_ title: String, _ date: Date) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).foregroundStyle(Theme.secondary)
            Text(date.formatted(date: .long, time: .omitted)).font(.headline).monospacedDigit()
        }.accessibilityElement(children: .combine)
    }

    @ViewBuilder private var operationUpdates: some View {
        if model.isBusy {
            ProgressView(isPurchaserContext ? mtr("Checking with Apple and your household…") : mtr("Checking your household access…"))
        }
        ForEach(model.statusMessages) { message in
            Text(messageText(message)).accessibilityIdentifier(message.id)
        }
        if isPurchaserContext, model.deliveryOutcomes.values.contains(where: {
            if case .failed = $0 { return true }
            return false
        }) {
            Button(mtr("Retry purchase delivery")) {
                retryingDelivery = true
                Task {
                    await model.refresh()
                    retryingDelivery = false
                }
            }
            .disabled(retryingDelivery || model.isBusy)
            .accessibilityIdentifier("membership.delivery.retry")
        }
        if model.verificationFailed || model.state.issue != nil {
            NavigationLink(mtr("Get membership help")) { HelpSupportView() }
        }
    }

    private func messageText(_ message: MembershipModel.StatusMessage) -> String {
        if !isPurchaserContext {
            switch message {
            case .otherNotice(.restored): return mtr("Your named planning seat was refreshed.")
            case .otherNotice(.restoredFree): return mtr("Access checked. You have Free planning.")
            case .otherNotice(.failed), .otherNotice(.restoreUnavailable): return mtr("Your membership details could not be refreshed.")
            default: break
            }
        }
        return membershipStatusMessageText(message)
    }

    @ViewBuilder private var householdRoles: some View {
        if let session = household.membershipSession, let scope = household.projection,
           session.memberID == model.context?.purchaserID, session.householdID == model.context?.householdID,
           let roles = session.householdRoleNames(role: scope.role, canAdminister: scope.capabilities.contains("household_admin"),
                                                  hasShop: scope.shopId != nil,
                                                  snapshot: model.verificationIsStale || model.verificationFailed ? nil : model.state.snapshot) {
            Divider()
            Text(mtr("Household and pickup roles")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            if let organizer = roles.organizer {
                LabeledContent(mtr("Household organizer"), value: organizer)
                if let lifecycle = household.lifecycle, lifecycle.canAdminister {
                    NavigationLink(ht("People and invitations")) { HouseholdPeopleView(model: lifecycle) }
                }
            }
            if let shopper = roles.shopper {
                LabeledContent(ht("Current shopper"), value: shopper)
                    .accessibilityIdentifier("household.currentShopper")
            } else if let shop = household.sharedShop, shop.scope == scope, scope.shopId != nil {
                NavigationLink(ht("Current shopper")) { SharedShopAssignmentView(household: household, model: shop, allowsTransfer: false) }
                    .accessibilityIdentifier("membership.shopperAssignment")
            } else if scope.canSelectShop == true {
                NavigationLink(ht("Choose shared shop")) { HouseholdShopSelector(household: household) }
            }
        }
    }

    private func status(_ status: MembershipStatus) -> String {
        switch status {
        case .free: return mtr("No verified Household subscription")
        case .active: return mtr("Subscription verified")
        case .grace: return mtr("Apple has allowed a billing grace period. Check your payment method in Manage Subscription.")
        case .expired: return mtr("Subscription expired. Your Free work is preserved.")
        case .revoked: return mtr("Paid access ended after a refund or revocation. Your Free work is preserved.")
        case .billingRetry: return mtr("Apple is retrying payment. Free access remains available.")
        }
    }

    private struct SeatChange: Identifiable {
        let id = UUID()
        let from: MembershipSeat?
        let to: MembershipSeat?
        let revision: Int
    }

    private func seatRoster(_ snapshot: MembershipSnapshot) -> some View {
        let seats = snapshot.seats
        let candidates = model.eligibleAdults.filter { adult in !seats.contains(where: { $0.id == adult.id }) }
        return VStack(alignment: .leading, spacing: 12) {
            Text(mtr("Named adult seats")).font(.title2.bold()).accessibilityAddTraits(.isHeader)
            Text(String(format: mtr("%lld of 2 planning seats assigned"), Int64(seats.count)))
                .monospacedDigit().font(.headline)
            Text(mtr("A seat does not give access to a shop, its budget or the shopper’s approval role.")).foregroundStyle(Theme.secondary)
            ForEach(seats) { seat in
                Menu {
                    ForEach(candidates) { adult in
                        Button(String(format: mtr("Transfer to %@"), adult.displayName)) {
                            review = SeatChange(from: seat, to: adult, revision: snapshot.revision)
                        }
                    }
                    Button(mtr("Revoke seat"), role: .destructive) {
                        review = SeatChange(from: seat, to: nil, revision: snapshot.revision)
                    }
                } label: {
                    HStack {
                        Label(seat.displayName, systemImage: "person.crop.circle")
                        Spacer()
                        Image(systemName: "ellipsis.circle")
                    }.frame(minHeight: 44)
                }
                .accessibilityLabel(String(format: mtr("Manage planning seat for %@"), seat.displayName))
                .disabled(model.isBusy || model.verificationFailed)
            }
            if seats.count < 2, !candidates.isEmpty {
                Menu(mtr("Assign a planning seat")) {
                    ForEach(candidates) { adult in
                        Button(adult.displayName) {
                            review = SeatChange(from: nil, to: adult, revision: snapshot.revision)
                        }
                    }
                }.disabled(model.isBusy || model.verificationFailed)
            } else if seats.count < 2, !model.verificationFailed {
                Text(mtr("No other eligible adults are available to assign.")).foregroundStyle(Theme.secondary)
            }
        }
    }

    private func seatReview(_ change: SeatChange) -> some View {
        MembershipPage {
            if isPurchaserContext, model.canManageSeats, !model.verificationFailed,
               let context = model.context, let snapshot = model.state.snapshot,
               change.revision == snapshot.revision,
               change.to.map(model.eligibleAdults.contains) ?? true,
               change.from.map(snapshot.seats.contains) ?? true {
                MembershipHeading(title: mtr("Review planning seat change"), symbol: "person.2")
                Label(context.householdName, systemImage: "house").font(.headline)
                if let from = change.from {
                    Text(String(format: mtr("%@ will lose access to Household planning tools."), from.displayName))
                }
                if let to = change.to {
                    Text(String(format: mtr("%@ will gain access to Household planning tools."), to.displayName))
                }
                Text(mtr("This changes planning access only. Household records, billing and pickup roles stay the same."))
                    .foregroundStyle(Theme.secondary)
                Button(mtr("Confirm seat change")) {
                    review = nil
                    Task {
                        await model.replaceSeat(userID: change.to?.userID, replacingUserID: change.from?.userID,
                                                reviewedRevision: change.revision)
                    }
                }
                .buttonStyle(PrimaryAction()).disabled(model.isBusy)
                .accessibilityIdentifier("membership.seats.confirm")
            } else {
                Text(mtr("Membership changed. Review the current seats before making another change."))
            }
            Button(tr("Cancel")) { review = nil }.frame(minHeight: 44)
        }
    }
}

struct MembershipReturnButtonStyle: ButtonStyle {
    @Environment(\.isFocused) private var isFocused
    @Environment(\.colorSchemeContrast) private var contrast

    func makeBody(configuration: Configuration) -> some View {
        let outline = RoundedRectangle(cornerRadius: 14, style: .continuous)
        configuration.label
            .font(.headline)
            .multilineTextAlignment(.center)
            .fixedSize(horizontal: false, vertical: true)
            .foregroundStyle(configuration.isPressed ? Theme.onAction : Theme.action)
            .frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12)
            .padding(.vertical, 4)
            .background(configuration.isPressed ? Theme.action : Theme.surface, in: outline)
            .overlay {
                outline.strokeBorder(Theme.action, lineWidth: contrast == .increased ? 2 : 1.5)
                    .accessibilityHidden(true)
                if isFocused {
                    outline.inset(by: -3).strokeBorder(Theme.surface, lineWidth: 3)
                        .accessibilityHidden(true)
                    outline.inset(by: -6).strokeBorder(Theme.focus, lineWidth: 3)
                        .accessibilityHidden(true)
                }
            }
            .contentShape(outline)
    }
}

private struct MembershipTextButton: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).foregroundStyle(Theme.action)
            .frame(minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
            .opacity(configuration.isPressed ? 0.7 : 1)
    }
}

func membershipStatusMessageText(_ message: MembershipModel.StatusMessage) -> String {
    switch message {
    case .pendingReport: return membershipNoticeText(.pending)
    case .cancelledReport: return membershipNoticeText(.cancelled)
    case .unverifiedReport: return membershipNoticeText(.failed(.unverified))
    case .purchaseFailure(let issue):
        return mtr("Apple’s purchase response needs review.") + " " + membershipNoticeText(.failed(issue))
    case .deliveryInFlight:
        return mtr("Apple’s transaction was received. Your household is confirming access.")
    case .deliverySaved: return membershipNoticeText(.delivered)
    case .deliveryFailure(let issue):
        return mtr("A verified App Store transaction needs delivery review.") + " " + membershipNoticeText(.failed(issue))
    case .callbackRejection(let issue):
        switch issue {
        case .accountMismatch, .wrongHousehold:
            return mtr("An earlier App Store update did not match this account or household. Use its purchasing account to restore it. Current membership access is shown above.")
        case .unverified:
            return mtr("An earlier App Store update could not be verified. Use Restore Purchases or contact support. Current membership access is shown above.")
        default:
            return mtr("An earlier App Store update could not be used.") + " " + membershipNoticeText(.failed(issue))
        }
    case .otherNotice(let notice): return membershipNoticeText(notice)
    }
}

func membershipNoticeText(_ notice: MembershipModel.Notice) -> String {
    switch notice {
    case .pending: return mtr("The App Store reported this purchase as pending. You can keep planning.")
    case .cancelled: return mtr("Purchase canceled.")
    case .restored: return mtr("Your verified Household membership was restored.")
    case .restoredFree: return mtr("Restore finished. This account currently has Free access.")
    case .restoreCancelled: return mtr("Restore canceled.")
    case .restoreUnavailable: return mtr("Purchases could not be restored. Try Restore Purchases again when connected.")
    case .delivered: return mtr("Your household service received the verified Apple transaction.")
    case .failed(let failure):
        switch failure {
        case .signInRequired: return mtr("Sign in to an adult account and select its household to restore or subscribe.")
        case .wrongHousehold, .accountMismatch: return mtr("An App Store transaction or membership response does not match this account or household. Use the purchasing account to restore it.")
        case .unverified, .invalidReceipt, .invalidSnapshot, .serverRejected: return mtr("An App Store transaction could not be verified. Use Restore Purchases or contact support. Current membership access is shown above.")
        case .notConfigured: return mtr("Household subscription purchases are unavailable. You can keep using the free planning tools.")
        case .unavailable: return mtr("Your membership update could not be completed. Try again or restore purchases.")
        case .membershipInactive: return mtr("Household access is inactive. Your Free work remains available.")
        case .notPurchaser: return mtr("Only the adult who purchased this household’s membership can manage its subscription and assign seats.")
        case .refreshRequired: return mtr("Membership changed. Review the current seats before making another change.")
        case .deliveryPending: return mtr("Purchase delivery is pending. Use Restore Purchases when connected. You can use Free while waiting.")
        }
    }
}
