import SwiftUI
import Combine
import HouseholdClient

/// The app owns the coordinator; navigating away leaves transaction observation running.
struct MembershipEntryView: View {
    @ObservedObject var household: HouseholdModel
    @EnvironmentObject private var membership: MembershipCoordinator

    var body: some View {
        Group {
            if household.projection == nil || household.locked {
                VStack(alignment: .leading, spacing: 20) {
                    Text(tr("Choose your household first")).font(.title2.bold())
                    Text(tr("A membership belongs to an authenticated household. Your Free records and manual tools remain available."))
                    NavigationLink(tr("Household requests")) { HouseholdSettingsView(model: household) }
                }.padding(20)
            } else if let model = membership.model { MembershipView(model: model) }
            else if membership.failure {
                VStack(spacing: 20) {
                    Text(tr("Membership could not be verified. Your Free work is still available."))
                    Button(tr("Try again")) { membership.retry() }.frame(minHeight: 44)
                }.padding(20)
            } else { ProgressView() }
        }.workingSurface().navigationTitle(tr("Household membership"))
            .task { membership.bind(to: household) }
    }
}

extension HouseholdModel: MembershipSessionSource {
    var membershipSession: MembershipSession? {
        guard !locked, let identity, let projection, projection.enrolled, let serviceURL else { return nil }
        return MembershipSession(subjectID: identity.subject, memberID: projection.memberId,
            accountName: identity.email ?? projection.memberId, householdID: projection.household.id,
            householdName: projection.household.label, serviceURL: serviceURL)
    }

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
