import HouseholdClient
import SwiftUI

private func stepText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "AdultChecks")
}

private struct CookingHandoffHouseholdKey: EnvironmentKey {
    static let defaultValue: HouseholdModel? = nil
}
extension EnvironmentValues {
    var cookingHandoffHousehold: HouseholdModel? {
        get { self[CookingHandoffHouseholdKey.self] }
        set { self[CookingHandoffHouseholdKey.self] = newValue }
    }
}

struct CookingStepHandoffLink: View {
    @ObservedObject var household: HouseholdModel
    var instruction: String?
    var currentSource: () -> Bool = { true }

    var body: some View {
        if let shop = household.selectedRequestPickupID ?? household.projection?.shopId.flatMap(UUID.init(uuidString:)),
           household.adultRequestScope(shop: shop, capability: "cook_step_handoff") != nil {
            NavigationLink {
                PrivateAdultRequestSurface(household: household, shopID: shop, capability: "cook_step_handoff") { scope in
                    CookingStepHandoffView(household: household, scope: scope, instruction: instruction, currentSource: currentSource)
                }
            } label: {
                Label(stepText(instruction == nil ? "Cooking step handoffs" : "Hand off this step"), systemImage: "person.2")
            }
            .accessibilityIdentifier(instruction == nil ? "cookHandoff.inbox" : "cookHandoff.currentStep")
        }
    }
}

private struct CookingStepHandoffView: View {
    @ObservedObject var household: HouseholdModel
    let scope: AdultRequestViewScope
    let instruction: String?
    let currentSource: () -> Bool
    @State private var page: CookingStepHandoff?
    @State private var wording: String
    @State private var expiry = Date().addingTimeInterval(2 * 3600)
    @State private var working = false
    @State private var message: String?
    @State private var observedExpiry = false
    @State private var lifetime = UUID()
    @State private var requestID = UUID()

    init(household: HouseholdModel, scope: AdultRequestViewScope, instruction: String?, currentSource: @escaping () -> Bool) {
        self.household = household
        self.scope = scope
        self.instruction = instruction
        self.currentSource = currentSource
        _wording = State(initialValue: instruction ?? "")
    }

    var body: some View {
        WorkingForm {
            if let page, let deadline = page.deadline, deadline > Date() {
                if let peer = page.otherAdult {
                    if instruction != nil, currentSource(), !page.offers.contains(where: \.mine) {
                        Section(stepText("Review one step to share")) {
                            LabeledContent(stepText("Only shared with"), value: peer.label)
                            TextField(stepText("Instruction"), text: $wording, axis: .vertical)
                                .accessibilityIdentifier("cookHandoff.wording")
                            DatePicker(stepText("Expires"), selection: $expiry,
                                       displayedComponents: [.date, .hourAndMinute])
                            Text(stepText("Share up to 240 characters for up to 24 hours."))
                            Button(stepText("Offer this step")) {
                                let words = wording.trimmingCharacters(in: .whitespacesAndNewlines)
                                Task {
                                    guard currentSource() else { return }
                                    await perform { try await $0.offerCookingStep(in: $1, page: page, id: requestID, instruction: words, expires: expiry) }
                                }
                            }
                            .disabled(working || wording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                                      wording.utf16.count > 240 || expiry <= Date() || expiry.timeIntervalSinceNow > 86400)
                            .accessibilityIdentifier("cookHandoff.offer")
                        }
                    }
                    Section(stepText("Current handoffs")) {
                        if page.offers.isEmpty { Text(stepText("No current cooking step handoffs.")) }
                        ForEach(page.offers) { offer in
                            if let until = offer.expiry, until > Date() { row(offer, peer: peer, until: until) }
                        }
                    }
                } else {
                    Text(stepText("A second named adult with access to this shop is needed."))
                }
            }
            if observedExpiry { Text(stepText("A cooking step handoff expired.")) }
            if let message { Text(message).accessibilityIdentifier("cookHandoff.status") }
            if working { ProgressView(stepText("Checking household…")) }
            else { Button(stepText("Refresh handoffs")) { Task { await reload() } } }
        }
        .navigationTitle(stepText("Cooking step handoffs"))
        .task {
            await reload()
            while !Task.isCancelled {
                let seconds = page?.deadline?.timeIntervalSinceNow ?? 30
                do { try await Task.sleep(for: .seconds(max(0.1, seconds))) } catch { return }
                if page?.offers.contains(where: { ($0.expiry ?? .distantFuture) <= Date() }) == true { observedExpiry = true }
                if page?.deadline.map({ $0 <= Date() }) == true { page = nil }
                await reload()
            }
        }
        .onChange(of: wording) { _, _ in requestID = UUID() }
        .onChange(of: expiry) { _, _ in requestID = UUID() }
        .onDisappear { lifetime = UUID(); page = nil; message = nil; working = false }
    }

    @ViewBuilder private func row(_ offer: CookingStepHandoff.Offer, peer: CookingStepHandoff.Adult, until: Date) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            LabeledContent(stepText(offer.mine ? "Offered to" : "Offered by"), value: peer.label)
            Text(verbatim: offer.instruction).font(.headline)
            LabeledContent(stepText("Expires"), value: until.formatted(date: .abbreviated, time: .shortened))
            switch offer.answer {
            case .accepted:
                LabeledContent(stepText("Taking this step"), value: offer.mine ? peer.label : stepText("You"))
                Text(stepText("Mark cooking progress separately."))
            case .declined: Text(stepText(offer.mine ? "This step is back with you." : "You passed this step back."))
            case nil:
                Text(stepText("Waiting for a reply"))
                if !offer.mine {
                    Button(stepText("Accept this step")) { respond(offer, .accepted) }.accessibilityIdentifier("cookHandoff.accept")
                    Button(stepText("Decline this step")) { respond(offer, .declined) }.accessibilityIdentifier("cookHandoff.decline")
                }
            }
            if offer.mine || offer.answer == .accepted {
                Button(stepText(offer.mine ? "Withdraw this offer" : "Release this step")) {
                    Task {
                        await perform { service, session in
                            if offer.mine { return try await service.withdrawCookingStep(in: session, id: offer.id) }
                            return try await service.releaseCookingStep(in: session, offer: offer)
                        }
                        if page?.offers.contains(where: { $0.id == offer.id }) == false { requestID = UUID() }
                    }
                }
            }
            if !offer.mine, let field = SharedMessageField(.cookStep, offer.id.uuidString, 1, .text, offer.instruction) {
                SharedSafetyButton(channel: household.sharedSafetyChannel(afterBlock: { page = nil; await reload() }), fields: [field])
            }
        }.disabled(working)
    }
    private func respond(_ offer: CookingStepHandoff.Offer, _ answer: CookingStepHandoff.Answer) {
        Task { await perform { try await $0.answerCookingStep(in: $1, offer: offer, answer: answer) } }
    }
    private func reload() async { await perform { try await $0.fetchCookingStep(in: $1) } }

    @MainActor private func perform(_ work: (HouseholdService, AdultShopRequestSession) async throws -> CookingStepHandoff) async {
        guard !working, let service = household.service, let projection = household.projection,
              household.adultRequestScope(shop: scope.shop, capability: "cook_step_handoff") == scope else { return }
        let start = lifetime
        working = true; message = nil
        defer { if lifetime == start { working = false } }
        do {
            let session = try await service.adultShopRequestSession(projection, shopID: scope.shop)
            let fresh = try await work(service, session)
            guard start == lifetime, UIApplication.shared.isProtectedDataAvailable, UIApplication.shared.applicationState == .active,
                  household.adultRequestScope(shop: scope.shop, capability: "cook_step_handoff") == scope,
                  let end = fresh.deadline, end > Date() else { return }
            if !fresh.offers.isEmpty { observedExpiry = false }
            page = fresh
        } catch {
            guard start == lifetime else { return }
            page = nil
            message = stepText("Couldn’t confirm the handoff. Refresh to see the current answer.")
        }
    }
}
