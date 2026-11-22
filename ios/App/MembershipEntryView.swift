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

/// The app owns the coordinator; navigating away leaves transaction observation running.
struct MembershipEntryView: View {
    @ObservedObject var household: HouseholdModel
    @Environment(\.returnFromMembershipSettings) private var returnFromSettings
    @EnvironmentObject private var membership: MembershipCoordinator
    @Environment(\.dismiss) private var dismiss

    @Environment(\.guardianChildCoordinator) private var child

    var body: some View {
        Group {
            if !household.canOpenMembership || child?.presented == true {
                Text(mtr("This view is unavailable.")).navigationTitle("")
            } else if let model = membership.model(for: household.membershipSession) {
                MembershipView(model: model, household: household, onContinuePlanning: continuePlanning)
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
        if household.configured && (household.identity != nil || household.emailOTPEnabled) {
            MembershipHeading(title: tr("Choose your household first"), symbol: "house")
            householdSetup(mtr("Open adult household setup")).buttonStyle(PrimaryAction())
            freeButton.buttonStyle(MembershipReturnButtonStyle())
        } else {
            MembershipHeading(title: mtr("Free planning"), symbol: "list.bullet")
            freeButton.buttonStyle(PrimaryAction())
            if household.configured {
                householdSetup(mtr("Saved adult account options")).buttonStyle(MembershipReturnButtonStyle())
                Text(mtr("You can use an adult account already saved on this iPhone. Email sign-in is unavailable."))
            } else {
                Text(mtr("Your private lists and dinners work without an account. Household sign-in is unavailable on this iPhone."))
                Text(helpText("Household is a paid subscription. The App Store price is unavailable on this iPhone."))
                    .foregroundStyle(Theme.secondary)
            }
        }
        if household.configured {
            Text(helpText("Household is a paid subscription. Choose your household to check planning access and see the App Store price if an offer is available."))
        }
    }

    private func householdSetup(_ title: String) -> some View {
        NavigationLink(title) {
            HouseholdSettingsView(model: household, continuesAfterWorkspaceLock: true)
        }.accessibilityIdentifier("membership.accountOptions")
    }

    private var freeButton: some View {
        Button(mtr("Continue planning for free"), action: continuePlanning)
            .accessibilityIdentifier("membership.free")
    }

    private func continuePlanning() {
        if let returnFromSettings { returnFromSettings() } else { dismiss() }
    }
}

extension HouseholdModel: MembershipSessionSource {
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
