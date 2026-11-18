import SwiftUI
import Combine
import HouseholdClient

/// The app owns the coordinator; navigating away leaves transaction observation running.
struct MembershipEntryView: View {
    @ObservedObject var household: HouseholdModel
    @EnvironmentObject private var membership: MembershipCoordinator
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        Group {
            if !household.configured {
                VStack(alignment: .leading, spacing: 20) {
                    Text(mtr("Household subscription purchases are unavailable. You can keep using the free planning tools."))
                    Button(mtr("Continue with Free")) { dismiss() }
                        .frame(minHeight: 44).accessibilityIdentifier("membership.free")
                }.padding(20)
            } else if household.membershipSession == nil {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("Choose your household first")).font(.title2.bold())
                    Text(tr("To subscribe or restore a purchase, sign in with your adult account and select your household. You can use the free planning tools without signing in."))
                    NavigationLink(tr("Household requests")) { HouseholdSettingsView(model: household, continuesAfterWorkspaceLock: true) }
                }.padding(20)
            } else if let model = membership.model { MembershipView(model: model, household: household) }
            else if membership.failure {
                VStack(spacing: 20) {
                    Text(tr("Membership could not be verified. Your Free work is still available."))
                    Button(tr("Try again")) { Task { await membership.retry() } }
                        .frame(minHeight: 44).disabled(household.busy)
                    Button(mtr("Continue with Free")) { dismiss() }
                        .frame(minHeight: 44).accessibilityIdentifier("membership.free")
                }.padding(20)
            } else { ProgressView() }
        }.workingSurface().navigationTitle(tr("Household membership"))
            .task { membership.bind(to: household) }
    }
}

extension HouseholdModel: MembershipSessionSource {
    var membershipSession: MembershipSession? {
        guard !guardianChildOnly, !locked, let identity, let projection, projection.enrolled,
              projection.grantId == nil, ["organizer", "shopper", "contributor"].contains(projection.role),
              let serviceURL else { return nil }
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
