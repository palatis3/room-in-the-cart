import SwiftUI
import Combine
import HouseholdClient

private struct MembershipSettingsReturnKey: EnvironmentKey {
    static let defaultValue: (@MainActor () -> Void)? = nil
}

extension EnvironmentValues {
    var returnFromMembershipSettings: (@MainActor () -> Void)? {
        get { self[MembershipSettingsReturnKey.self] }
        set { self[MembershipSettingsReturnKey.self] = newValue }
    }
}

enum HouseholdSettingsDestination: Hashable { case membership, adultSetup }

/// The app owns the coordinator; navigating away leaves transaction observation running.
struct MembershipEntryView: View {
    @ObservedObject var household: HouseholdModel
    var usesSettingsPath = false
    var returnsToDinnerComparison = false
    @Environment(\.returnFromMembershipSettings) private var returnFromSettings
    @EnvironmentObject private var membership: MembershipCoordinator
    @Environment(\.dismiss) private var dismiss

    @Environment(\.guardianChildCoordinator) private var child

    var body: some View {
        Group {
            if !household.canOpenMembership || child?.presented == true {
                Text(mtr("This view is unavailable.")).navigationTitle("")
            } else if let model = membership.model(for: household.membershipSession) {
                MembershipView(model: model, household: household, returnsToDinnerComparison: returnsToDinnerComparison,
                               onContinuePlanning: continuePlanning)
                    .onChange(of: model.hasPaidAccess) { before, after in
                        if returnsToDinnerComparison, !before, after,
                           membership.model(for: household.membershipSession) === model { dismiss() }
                    }
                    .id(ObjectIdentifier(model))
            } else {
                MembershipPage {
                    if household.membershipSession == nil {
                        householdEntry
                    } else if membership.failure {
                        MembershipHeading(title: mtr("Membership needs verification"), symbol: "arrow.clockwise")
                        Text(tr("Membership could not be verified. Your Free work is still available."))
                        Button(mtr("Check membership again")) { Task { await membership.retry() } }
                            .buttonStyle(PrimaryAction()).disabled(household.busy)
                        freeButton.buttonStyle(MembershipReturnButtonStyle())
                    } else {
                        MembershipHeading(title: mtr("Your planning access"), symbol: "person.crop.circle")
                        ProgressView(mtr("Checking your household access…"))
                        freeButton.buttonStyle(MembershipReturnButtonStyle())
                    }
                    Divider()
                    MembershipFreeTools()
                    MembershipBenefits()
                    MembershipSampleLink()
                    if household.membershipSession == nil {
                        Divider()
                        PrivateListSharingGuide()
                        FamilyPermissionGuideLink()
                    }
                    MembershipLegalLinks(configuration: .fromBundle())
                }
                .navigationTitle(tr("Household membership"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .workingSurface()
        .task { membership.bind(to: household) }
    }

    @ViewBuilder private var householdEntry: some View {
        switch household.membershipEntryRoute {
        case .signIn, .chooseHousehold:
            MembershipHeading(title: household.identity == nil ? ht("Adult sign-in") : tr("Choose your household first"), symbol: "house")
            householdSetup(mtr("Open adult household setup")).buttonStyle(PrimaryAction())
            freeButton.buttonStyle(MembershipReturnButtonStyle())
        case .savedAccountOnly, .unavailable:
            MembershipHeading(title: mtr("Free planning"), symbol: "list.bullet")
            freeButton.buttonStyle(PrimaryAction())
            if household.membershipEntryRoute == .savedAccountOnly {
                householdSetup(mtr("Saved adult account options")).buttonStyle(MembershipReturnButtonStyle())
            }
        }
        Text(household.membershipEntryRoute.priceGuidance)
            .accessibilityIdentifier("membership.priceGuidance")
    }

    private func householdSetup(_ title: String) -> some View {
        Group {
            if usesSettingsPath {
                NavigationLink(title, value: HouseholdSettingsDestination.adultSetup)
            } else {
                NavigationLink(title) { HouseholdSettingsView(model: household, continuesAfterWorkspaceLock: true) }
            }
        }.accessibilityIdentifier("membership.accountOptions")
    }

    private var freeButton: some View {
        Button(returnsToDinnerComparison ? mtr("Return to dinner comparison") : mtr("Continue planning for free"), action: continuePlanning)
            .accessibilityIdentifier("membership.free")
    }

    private func continuePlanning() {
        if returnsToDinnerComparison { dismiss() }
        else if let returnFromSettings { returnFromSettings() } else { dismiss() }
    }
}

enum MembershipEntryRoute {
    case unavailable, savedAccountOnly, signIn, chooseHousehold

    init(configured: Bool, signedIn: Bool, emailSignInEnabled: Bool) {
        if !configured { self = .unavailable }
        else if signedIn { self = .chooseHousehold }
        else if emailSignInEnabled { self = .signIn }
        else { self = .savedAccountOnly }
    }

    var priceGuidance: String {
        switch self {
        case .unavailable:
            helpText("Household is an annual subscription. Household sign-in and the App Store price are unavailable on this iPhone. You can keep planning for free.")
        case .savedAccountOnly:
            helpText("Household is an annual subscription. Email sign-in is unavailable. If you have an adult account saved on this iPhone, resume it in Saved adult account options to check for an App Store offer. Without a saved account, the price is unavailable here.")
        case .signIn:
            helpText("Household is an annual subscription. Open adult household setup to sign in. Once you open your household, you can see the App Store price if an offer is available.")
        case .chooseHousehold:
            helpText("Household is an annual subscription. Open adult household setup to review your household options. You can see the App Store price if an offer is available for your household.")
        }
    }
}

extension HouseholdModel: MembershipSessionSource {
    var membershipEntryRoute: MembershipEntryRoute {
        MembershipEntryRoute(configured: configured, signedIn: identity != nil, emailSignInEnabled: emailOTPEnabled)
    }

    var canOpenMembership: Bool {
        guard !guardianChildOnly, !locked else { return false }
        guard let projection else { return true }
        return projection.grantId == nil && ["organizer", "shopper", "contributor"].contains(projection.role)
    }

    var membershipSession: MembershipSession? {
        guard canOpenMembership, let identity, let projection, projection.enrolled, let serviceURL else { return nil }
        return MembershipSession(subjectID: identity.subject, memberID: projection.memberId,
            accountName: identity.email ?? projection.memberId, householdID: projection.household.id,
            householdName: projection.household.label, serviceURL: serviceURL)
    }

    func refreshMembershipAuthorization() async { await refresh() }

    func membershipAccessToken() async throws -> String {
        try await membershipCredential { try await adultAccessToken() }
    }

    func membershipDeviceToken() async throws -> String {
        try await membershipCredential { try await deviceAccessToken() }
    }

    private func membershipCredential(_ read: () async throws -> String) async throws -> String {
        do { return try await read() }
        catch let error as ClientError {
            switch error {
            case .sessionNeeded, .accessEnded: throw MembershipFailure.signInRequired
            default: throw error
            }
        }
    }

    var membershipSessionChanges: AnyPublisher<MembershipSessionEvent, Never> {
        Publishers.Merge3($projection.map { _ in MembershipSessionEvent.projection },
            $identity.map { _ in MembershipSessionEvent.identity },
            $locked.map { _ in MembershipSessionEvent.lock }).eraseToAnyPublisher()
    }
}
