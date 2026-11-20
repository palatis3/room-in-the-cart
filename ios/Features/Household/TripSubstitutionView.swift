import HouseholdClient
import SwiftUI

private extension TripSubstitutionChoice {
    var title: String {
        switch self {
        case .undecided: householdTripText("No answer yet")
        case .exact: householdTripText("This exact pack")
        case .alternative: householdTripText("This named alternative is OK")
        case .skip: householdTripText("Skip if unavailable")
        }
    }
}

struct TripSubstitutionLink: View {
    @ObservedObject var household: HouseholdModel
    let request: OwnRequest
    var body: some View {
        if request.route == "current", request.carriedForward != true, request.fromPreviousShop != true, ["pending", "clarified", "added"].contains(request.status),
           let shop = UUID(uuidString: request.shopId), let id = UUID(uuidString: request.id),
           household.adultRequestScope(shop: shop, capability: "trip_substitutions") != nil {
            NavigationLink {
                PrivateAdultRequestSurface(household: household, shopID: shop, capability: "trip_substitutions") { scope in
                    TripSubstitutionView(household: household, scope: scope, requestID: id, request: request)
                }
            } label: {
                Label(householdTripText("If this pack is unavailable"), systemImage: "arrow.triangle.2.circlepath")
                    .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading).contentShape(Rectangle())
            }.accessibilityIdentifier("household.substitution." + request.id)
        }
    }
}

private struct TripSubstitutionView: View {
    @ObservedObject var household: HouseholdModel
    let scope: AdultRequestViewScope
    let requestID: UUID
    let request: OwnRequest
    @State private var page: TripSubstitution?
    @State private var selection = TripSubstitutionChoice.undecided
    @State private var name = ""
    @State private var busy = false
    @State private var notice: String?
    @State private var life = UUID()
    @State private var retryKey = UUID()
    private var current: Bool { household.adultRequestScope(shop: scope.shop, capability: "trip_substitutions") == scope }
    private var alternative: String? { selection == .alternative ? name.trimmingCharacters(in: .whitespacesAndNewlines) : nil }

    var body: some View {
        WorkingForm {
            if let page {
                Section(ht("Request")) {
                    Text(verbatim: page.originalItem).font(.headline)
                    let amount = request.revision == page.requestRevision && request.originalItem == page.originalItem
                        ? request.ownQuantity : nil
                    if let amount { LabeledContent(ht("Quantity"), value: amount) }
                    LabeledContent(ht("Pickup"), value: String(scope.shop.uuidString.prefix(8)))
                    LabeledContent(householdTripText("Requester’s choice"), value: page.choice.title)
                    if let approved = page.alternative { Text(verbatim: approved) }
                    if !page.own {
                        SharedSafetyButton(channel: household.sharedSafetyChannel(afterBlock: {
                            self.page = nil
                            await load()
                            await household.refresh()
                        }), fields: [
                            SharedMessageField(.request, requestID.uuidString, page.requestRevision, .item, page.originalItem),
                            SharedMessageField(.request, requestID.uuidString, page.requestRevision, .amount, amount),
                            SharedMessageField(.substitution, requestID.uuidString, page.revision, .alternative, page.alternative)
                        ].compactMap { $0 })
                    }
                }
                if page.own {
                    Section(householdTripText("Tell the shopper for this trip")) {
                        Picker(householdTripText("Requester’s choice"), selection: $selection) {
                            ForEach(TripSubstitutionChoice.allCases, id: \.self) { option in
                                Text(option.title).tag(option)
                            }
                        }
                        if selection == .alternative {
                            TextField(householdTripText("Name the alternative pack"), text: $name, axis: .vertical)
                                .accessibilityIdentifier("household.substitution.alternative")
                        }
                        Button(householdTripText("Share my choice with the shopper")) { Task { await save(page) } }
                            .buttonStyle(PrimaryAction())
                            .disabled(selection == .undecided || (selection == .alternative && (alternative?.isEmpty != false || name.utf16.count > 240))
                                      || (page.choice == selection && page.alternative == alternative))
                            .accessibilityIdentifier("household.substitution.save")
                    }
                }
            }
            if let notice { Text(notice) }
            Button(ht("Refresh requests")) { Task { await load() } }
            if busy { ProgressView() }
        }
        .navigationTitle(householdTripText("Requester’s choice"))
        .disabled(busy)
        .onChange(of: selection) { _, _ in retryKey = UUID() }
        .onChange(of: name) { _, _ in retryKey = UUID() }
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await load()
            }
        }
        .onDisappear { life = UUID(); page = nil; name = ""; busy = false }
    }

    private func load() async { await perform { try await $0.substitution(for: requestID, in: $1) } }
    private func save(_ reviewed: TripSubstitution) async {
        let choice = selection, label = alternative, key = retryKey
        await perform { try await $0.saveSubstitution(choice, alternative: label, reviewed: reviewed, in: $1, key: key) }
    }
    private func perform(_ action: (HouseholdService, AdultShopRequestSession) async throws -> TripSubstitution) async {
        guard current, !busy, let service = household.service, let projection = household.projection else { return }
        let token = life
        busy = true
        defer { if life == token { busy = false } }
        do {
            let session = try await service.adultShopRequestSession(projection, shopID: scope.shop)
            guard life == token, current else { return }
            let fresh = try await action(service, session)
            guard life == token, current else { return }
            if fresh != page {
                selection = fresh.choice
                name = fresh.alternative ?? ""
                retryKey = UUID()
            }
            page = fresh
            notice = nil
        } catch {
            guard life == token, current else { return }
            if let message = sharedPublicationNotice(error) {
                notice = message
                return
            }
            // An unavailable response or a newer request invalidates the wording under review.
            page = nil; name = ""; selection = .undecided
            if let failure = error as? ClientError, failure == .sessionNeeded || failure == .accessEnded {
                await household.endTripDeviceAccess(failure, reviewed: scope)
                return
            }
            notice = householdTripText("Refresh to review the current request and its permissions.")
        }
    }
}
