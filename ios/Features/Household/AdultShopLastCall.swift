import Foundation
import HouseholdClient
import SwiftUI
import UIKit

struct AdultRequestViewScope: Hashable {
    let generation: UUID
    let enrollment: UUID
    let subject: String
    let household: String
    let member: String
    let role: String
    let shop: UUID
    let media: Bool
}

extension HouseholdModel {
    func adultRequestScope(shop: UUID, capability: String) -> AdultRequestViewScope? {
        guard !guardianChildOnly, !locked, let identity, let projection, projection.enrolled, projection.grantId == nil,
              ["organizer", "shopper", "contributor"].contains(projection.role), projection.capabilities.contains(capability),
              UUID(uuidString: projection.shopId ?? "") == shop || selectedRequestPickupID == shop else { return nil }
        return .init(generation: generation, enrollment: contributorEnrollmentRevision, subject: identity.subject, household: projection.household.id,
                     member: projection.memberId, role: projection.role, shop: shop, media: projection.capabilities.contains("adult_product_reference_media"))
    }
}

/// Remove the entire transient destination when the adult, device, permission or foreground changes.
struct PrivateAdultRequestSurface<Content: View>: View {
    @ObservedObject var household: HouseholdModel
    let shopID: UUID
    let capability: String
    @ViewBuilder var content: (AdultRequestViewScope) -> Content
    @Environment(\.scenePhase) private var phase
    @Environment(\.guardianChildCoordinator) private var child
    @State private var protectedData = UIApplication.shared.isProtectedDataAvailable

    var body: some View {
        Group {
            if phase == .active, protectedData, child?.presented != true, let scope = household.adultRequestScope(shop: shopID, capability: capability) {
                content(scope).id(scope).privacySensitive()
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataWillBecomeUnavailableNotification)) { _ in protectedData = false }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.protectedDataDidBecomeAvailableNotification)) { _ in protectedData = true }
    }
}

struct AdultShopLastCall: View {
    @ObservedObject var household: HouseholdModel
    let shopID: UUID
    var authorityEpoch: Int?
    var openRequest: ((Bool) -> Void)?

    var body: some View {
        PrivateAdultRequestSurface(household: household, shopID: shopID, capability: "adult_last_call") { scope in
            LastCallControls(household: household, scope: scope, authorityEpoch: authorityEpoch, openRequest: openRequest)
        }
    }
}

private struct LastCallControls: View {
    @ObservedObject var household: HouseholdModel
    let scope: AdultRequestViewScope
    let authorityEpoch: Int?
    let openRequest: ((Bool) -> Void)?
    @State private var state: ShopLastCall?
    @State private var draft: Date?
    @State private var busy = false
    @State private var failed = false
    @State private var life = UUID()
    @State private var reviewCutoff: Date?

    var body: some View {
        Group {
            if let state {
                if state.managed, let authorityEpoch {
                    Section(ht("Last call before checkout")) {
                        cutoff(state)
                        if let editing = draft {
                            DatePicker(ht("Request cutoff"), selection: Binding(get: { draft ?? editing }, set: { draft = $0 }),
                                       in: Date()...Date().addingTimeInterval(7 * 86_400))
                            Text(ht("Eligible adults see one in-app invitation for this pickup. Changing the cutoff updates that invitation."))
                            Button(ht("Review last call")) { reviewCutoff = draft }
                                .disabled(busy || editing <= Date())
                            Button(ht("Cancel")) { draft = nil }
                        } else {
                            Button(state.cutoff == nil ? ht("Set a last call") : ht("Change cutoff")) {
                                draft = max(Date().addingTimeInterval(3600), state.cutoff ?? Date())
                            }
                        }
                    }
                    .alert(ht("Publish this cutoff?"), isPresented: Binding(get: { reviewCutoff != nil }, set: { if !$0 { reviewCutoff = nil } }),
                           presenting: reviewCutoff) { value in
                        Button(ht("Publish last call")) { Task { await perform { service, session in
                            try await service.publishLastCall(in: session, reviewed: state, authorityEpoch: authorityEpoch, cutoffAt: value)
                        } } }
                        Button(ht("Cancel"), role: .cancel) { }
                    } message: { value in Text(value.formatted(date: .complete, time: .shortened) + " · " + TimeZone.current.identifier) }
                } else if !state.managed, state.cutoff != nil || state.muted {
                    Section(ht("Last call before checkout")) {
                        if !state.muted { cutoff(state) }
                        if state.muted {
                            Button(ht("Show the last call for this pickup again")) { respond(.unmute, state) }
                        } else {
                            if state.responded { Text(ht("Your response was received.")) }
                            else if let openRequest {
                                TimelineView(.periodic(from: .now, by: 15)) { clock in
                                    let late = state.nextShopOnly || (state.cutoff.map { $0 <= clock.date } ?? false)
                                    Button(late ? ht("Open my next-trip request") : ht("Open my request form")) { openRequest(late) }
                                    if !late { Button(ht("Pass this time")) { respond(.pass, state) } }
                                }
                            }
                            Button(ht("Mute the last call for this pickup")) { respond(.mute, state) }
                        }
                        Button(ht("Refresh last call")) { Task { await load() } }
                    }.disabled(busy)
                }
            }
            if failed {
                Text(ht("The last call could not be confirmed. Refresh to check the current cutoff."))
                Button(ht("Refresh last call")) { Task { await load() } }.disabled(busy)
            }
        }
        .task(id: household.requests.map(\.id)) {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(45)) } catch { return }
                await perform(preserveDraft: true) { try await $0.lastCall(in: $1) }
            }
        }
        .onDisappear { life = UUID(); state = nil; draft = nil; reviewCutoff = nil; busy = false; failed = false }
    }

    @ViewBuilder private func cutoff(_ value: ShopLastCall) -> some View {
        if let cutoff = value.cutoff {
            LabeledContent(ht("Request cutoff"), value: cutoff.formatted(date: .complete, time: .shortened) + " · " + TimeZone.current.identifier)
            Text(ht("Requests after the cutoff go to the next trip."))
        }
    }

    private func respond(_ action: LastCallResponse, _ reviewed: ShopLastCall) {
        Task { await perform { try await $0.respondToLastCall(action, in: $1, reviewed: reviewed) } }
    }

    private func load() async { await perform { try await $0.lastCall(in: $1) } }

    private func perform(preserveDraft: Bool = false, _ action: (HouseholdService, AdultShopRequestSession) async throws -> ShopLastCall) async {
        guard !busy, let service = household.service, let projection = household.projection,
              household.adultRequestScope(shop: scope.shop, capability: "adult_last_call") == scope else { return }
        let started = life
        busy = true
        defer { if started == life { busy = false } }
        do {
            let session = try await service.adultShopRequestSession(projection, shopID: scope.shop)
            guard started == life, UIApplication.shared.isProtectedDataAvailable, UIApplication.shared.applicationState == .active, household.adultRequestScope(shop: scope.shop, capability: "adult_last_call") == scope else { return }
            let result = try await action(service, session)
            guard started == life, UIApplication.shared.isProtectedDataAvailable, UIApplication.shared.applicationState == .active, household.adultRequestScope(shop: scope.shop, capability: "adult_last_call") == scope else { return }
            if !preserveDraft || state != result { draft = nil; reviewCutoff = nil }
            state = result; failed = false
        } catch {
            guard started == life else { return }
            state = nil; failed = true; draft = nil
        }
    }
}
