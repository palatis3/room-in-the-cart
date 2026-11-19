import SwiftUI
import Combine
import HouseholdClient

/// The app owns the coordinator; navigating away leaves transaction observation running.
struct MembershipEntryView: View {
    @ObservedObject var household: HouseholdModel
    @EnvironmentObject private var membership: MembershipCoordinator
    @Environment(\.dismiss) private var dismiss

    @Environment(\.guardianChildCoordinator) private var child

    var body: some View {
        Group {
            if !household.canOpenMembership || child?.presented == true {
                Text(mtr("This view is unavailable.")).navigationTitle("")
            } else if let session = household.membershipSession, let model = membership.model,
                      session.householdID == model.context?.householdID,
                      session.memberID == model.context?.purchaserID, !model.isStopped {
                MembershipView(model: model, household: household).id(ObjectIdentifier(model))
            } else {
                MembershipPage {
                    if !household.configured {
                        MembershipHeading(title: mtr("Household subscription"), symbol: "person.2")
                        Text(mtr("Plan repeat weeks and compare dinner combinations using your own prices. Up to two named adults can plan."))
                        Text(mtr("Subscribing requires an adult account and a selected household. Household sign-in is unavailable on this iPhone."))
                    } else if household.membershipSession == nil {
                        MembershipHeading(title: tr("Choose your household first"), symbol: "house")
                        Text(tr("To subscribe or restore a purchase, sign in with your adult account and select your household. You can use the free planning tools without signing in."))
                        NavigationLink(mtr("Open adult household setup")) {
                            HouseholdSettingsView(model: household, continuesAfterWorkspaceLock: true)
                        }.buttonStyle(PrimaryAction())
                    } else if membership.failure {
                        MembershipHeading(title: mtr("Membership needs verification"), symbol: "arrow.clockwise")
                        Text(tr("Membership could not be verified. Your Free work is still available."))
                        Button(mtr("Check membership again")) { Task { await membership.retry() } }
                            .buttonStyle(PrimaryAction()).disabled(household.busy)
                    } else {
                        MembershipHeading(title: mtr("Your planning access"), symbol: "person.crop.circle")
                        ProgressView(mtr("Checking your household access…"))
                    }
                    if !household.configured {
                        Button(mtr("Continue planning for free")) { dismiss() }
                            .buttonStyle(PrimaryAction()).accessibilityIdentifier("membership.free")
                    } else {
                        Button(mtr("Continue planning for free")) { dismiss() }
                            .frame(minHeight: 44).accessibilityIdentifier("membership.free")
                    }
                    Divider()
                    MembershipFreeTools()
                    MembershipLegalLinks(configuration: .fromBundle())
                }
                .navigationTitle(tr("Household membership"))
                .navigationBarTitleDisplayMode(.inline)
            }
        }
        .workingSurface()
        .task { membership.bind(to: household) }
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
