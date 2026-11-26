import HouseholdClient
import SwiftUI

func checkText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "AdultChecks")
}

extension AdultCheckAnswer {
    var reviewPrompt: String {
        switch self {
        case .home: "Include this adult when you review dinner portions."
        case .latePlate: "Set aside a dinner portion for later. Check which portions are already reserved for lunch."
        case .out: "Review how many people are eating. Keep any portions already promised for lunch."
        case .enough: "Check the amount you plan to buy against what’s at home."
        case .low: "Review whether the planned packs will cover what you need."
        case .cannotCheck: "The amount at home is still unknown. You can leave the grocery on your list."
        }
    }
    var label: String {
        switch self {
        case .home: checkText("Eating with you")
        case .latePlate: checkText("Save me a plate")
        case .out: checkText("Eating elsewhere")
        case .enough: checkText("Enough")
        case .low: checkText("Running low")
        case .cannotCheck: checkText("Can’t check")
        }
    }
}

struct HouseholdCheckLink: View {
    @ObservedObject var household: HouseholdModel

    var body: some View {
        if let shop = household.selectedRequestPickupID ?? household.projection?.shopId.flatMap(UUID.init(uuidString:)),
           household.adultRequestScope(shop: shop, capability: "adult_checks") != nil {
            NavigationLink {
                PrivateAdultRequestSurface(household: household, shopID: shop, capability: "adult_checks") { scope in
                    HouseholdCheckView(household: household, scope: scope)
                }
            } label: {
                Label(checkText("Dinner and cupboard questions"), systemImage: "bubble.left.and.bubble.right")
            }.accessibilityIdentifier("household.adultChecks")
        }
        CookingStepHandoffLink(household: household)
    }
}

private struct HouseholdCheckView: View {
    @ObservedObject var household: HouseholdModel
    let scope: AdultRequestViewScope
    @State private var page: AdultCheckPage?
    @State private var loading = false
    @State private var message: String?
    @State private var lifetime = UUID()
    @State private var kind = AdultCheckKind.attendance
    @State private var selected: UUID?
    @State private var pendingAsk: Ask?
    @State private var pendingReply: Reply?
    @State private var grocery: SharedGroceryTarget?
    @State private var dinnerReview: AdultCheckPage.Check?
    @State private var preparedShopReview = false
    @State private var showingShopReview = false
    @State private var reviewPacks = false
    @State private var amount = ""
    @State private var unit = "count"
    private let units = ["count", "gram", "kilogram", "milliliter", "liter"]
    private var quantity: AdultCheckPage.Quantity? {
        let text = amount.trimmingCharacters(in: .whitespacesAndNewlines)
        let normalized = text.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: ".")
        guard normalized.range(of: #"^[0-9]{1,6}(\.[0-9]{1,3})?$"#, options: .regularExpression) != nil,
              let number = Decimal(string: normalized, locale: Locale(identifier: "en_US_POSIX")), number > 0 else { return nil }
        return .init(value: NSDecimalNumber(decimal: number).stringValue, unit: unit)
    }
    private func quantityText(_ quantity: AdultCheckPage.Quantity) -> String {
        let number = Decimal(string: quantity.value, locale: Locale(identifier: "en_US_POSIX"))
        let value = number?.formatted(.number.locale(locale)) ?? quantity.value
        if quantity.unit == "count" { return value }
        return value + " " + checkText(quantity.unit)
    }

    private struct Reply: Identifiable {
        let check: AdultCheckPage.Check
        let answer: AdultCheckAnswer
        var id: UUID { check.id }
    }
    @Environment(\.locale) private var locale

    private struct Ask {
        let id, source, recipient: UUID
        let kind: AdultCheckKind
        let shopRevision, authorityEpoch, pairRevision: Int
        let expires: Date
    }

    var body: some View {
        WorkingForm {
            if let page, let deadline = page.deadline, deadline > Date() {
                if page.shopper { compose(page) }
                Section(checkText("Questions for this trip")) {
                    if page.checks.isEmpty { Text(checkText("No questions for this trip yet.")) }
                    ForEach(page.checks) { check in
                        if let expiry = check.deadline, expiry > Date() {
                            checkRow(check, page: page)
                        }
                    }
                }
            }
            if let message { Text(message).accessibilityIdentifier("adultChecks.notice") }
            if loading { ProgressView(checkText("Checking household…")) }
            else { Button(checkText("Refresh questions")) { Task { await reload() } } }
        }
        .navigationTitle(checkText("Dinner and cupboard questions"))
        .task {
            await reload()
            while !Task.isCancelled {
                let now = Date()
                let earliestExpiry = page?.checks.compactMap(\.deadline).filter { $0 > now }.min()
                let deadline = [earliestExpiry, page?.deadline].compactMap { $0 }.min()
                // Renew the short access lease before it interrupts someone typing a reply.
                if let deadline, deadline.timeIntervalSince(now) <= 10, deadline > now, !loading {
                    Task { await reload() }
                }
                let wait = deadline.map { max(0.1, $0.timeIntervalSince(now)) } ?? 10
                do { try await Task.sleep(for: .seconds(min(10, wait))) } catch { return }
                if let current = page?.deadline, current <= Date() {
                    self.page = nil
                    pendingReply = nil
                    await reload()
                }
            }
        }
        .navigationDestination(isPresented: $showingShopReview) { HouseholdShopView(model: household, reviewPreparedPacks: reviewPacks) }
        .sheet(item: $grocery, onDismiss: {
            if preparedShopReview {
                preparedShopReview = false
                showingShopReview = true
            }
        }) { target in
            NavigationStack {
                SharedGroceryLineView(household: household, target: target) {
                    reviewPacks = true
                    preparedShopReview = true
                    grocery = nil
                }
            }
        }
        .sheet(item: $dinnerReview, onDismiss: {
            if preparedShopReview {
                preparedShopReview = false
                showingShopReview = true
            }
        }) { dinner in
            NavigationStack {
                SharedMealChangesView(household: household, selectedDinner: .attendance(dinner.sourceId)) {
                    reviewPacks = false
                    preparedShopReview = true
                    dinnerReview = nil
                }.toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(checkText("Cancel")) { dinnerReview = nil }
                    }
                }
            }.task {
                if let shop = household.sharedShop, shop.shop == nil { await shop.load() }
            }
        }
        .sheet(item: $pendingReply) { reply in
            NavigationStack {
                WorkingForm {
                    Text(verbatim: title(reply.check.label, day: reply.check.day))
                    LabeledContent(checkText("Reply"), value: reply.answer.label)
                    Text(checkText("Only your answer is shared. The shopper decides whether to change the plan."))
                    if reply.answer == .enough || reply.answer == .low {
                        TextField(checkText("Amount on hand (optional)"), text: $amount)
                            .keyboardType(.decimalPad)
                        if !amount.isEmpty {
                            Picker(checkText("Unit"), selection: $unit) {
                                ForEach(units, id: \.self) { Text(checkText($0)).tag($0) }
                            }
                            if quantity == nil { Text(checkText("Enter a positive amount or leave it blank.")) }
                        }
                    }
                    Button(checkText("Send reply")) {
                        let observed = quantity
                        pendingReply = nil
                        Task { await perform { try await $0.answerAdultCheck(in: $1, check: reply.check, answer: reply.answer, quantity: observed) } }
                    }.buttonStyle(PrimaryAction()).disabled(loading || (!amount.isEmpty && quantity == nil))
                    Button(checkText("Cancel")) { pendingReply = nil }
                }.navigationTitle(checkText("Review reply"))
            }.privacySensitive()
        }
        .onDisappear { lifetime = UUID(); page = nil; selected = nil; pendingAsk = nil; pendingReply = nil; loading = false }
    }

    @ViewBuilder private func compose(_ page: AdultCheckPage) -> some View {
        Section(checkText("Ask the other adult")) {
            if let recipient = page.recipient {
                LabeledContent(checkText("Only shared with"), value: recipient.label)
                Picker(checkText("Question"), selection: $kind) {
                    Text(checkText("Who’s eating?")).tag(AdultCheckKind.attendance)
                    Text(checkText("Check one ingredient")).tag(AdultCheckKind.cupboard)
                }.onChange(of: kind) { _, _ in selected = nil; pendingAsk = nil }
                let choices = kind == .attendance ? page.dinners : page.items
                if choices.isEmpty {
                    Text(checkText(kind == .attendance ? "Add a dinner to the shared shop first." : "Add an item to the shared shop first."))
                } else {
                    Picker(checkText(kind == .attendance ? "Dinner" : "Grocery"), selection: $selected) {
                        Text(checkText("Choose one")).tag(UUID?.none)
                        ForEach(choices) { choice in
                            Text(verbatim: title(choice.label, day: choice.day)).tag(Optional(choice.id))
                        }
                    }
                    if let item = choices.first(where: { $0.id == selected }) {
                        if let packs = item.shoppingPacks { LabeledContent(checkText("Packs on the shopping list"), value: packs.formatted()) }
                        Text(checkText(kind == .attendance ? "Ask whether to count one dinner portion. The question expires in 24 hours." : "Ask about this ingredient only. The question expires in two hours."))
                        if page.checks.contains(where: { $0.kind == kind && $0.sourceId == item.id }) {
                            Text(checkText("You’ve already asked about this. See the question below."))
                        } else {
                            Button(checkText("Send question")) { ask(page, item: item, recipient: recipient.id) }
                                .disabled(loading).accessibilityIdentifier("adultChecks.send")
                        }
                    }
                }
            } else { Text(checkText("A second named adult with active Household access is needed to ask a question.")) }
        }
    }

    private func title(_ label: String, day: String?) -> String {
        guard let day else { return label }
        return label + " · " + sharedMealScheduleText(day, locale: locale)
    }

    @ViewBuilder private func checkRow(_ check: AdultCheckPage.Check, page: AdultCheckPage) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(verbatim: title(check.label, day: check.day)).font(.headline)
            Text(checkText(check.kind == .attendance ? "Will you be eating this dinner?" : "Is there enough of this ingredient at home?"))
            if let packs = check.shoppingPacks { LabeledContent(checkText("Packs on the shopping list"), value: packs.formatted()) }
            if let expiry = check.deadline { LabeledContent(checkText("Expires"), value: expiry.formatted(date: .abbreviated, time: .shortened)) }
            if let answer = check.answer {
                LabeledContent(checkText("Reply"), value: answer.label)
                if let q = check.quantity { LabeledContent(checkText("Amount at home"), value: quantityText(q)) }
                if page.shopper {
                    Text(checkText(answer.reviewPrompt))
                    if check.kind == .attendance, household.sharedMealChangeScope != nil {
                        Button(checkText("Review this dinner")) { dinnerReview = check }
                            .buttonStyle(.bordered)
                    } else if check.kind == .cupboard, household.sharedShop?.canManage == true, let answered = check.answeredAt {
                        Button(checkText("Review this grocery")) {
                            grocery = SharedGroceryTarget(shopID: page.shopId, rowID: check.sourceId,
                                revision: page.shopRevision, authorityEpoch: page.authorityEpoch,
                                reply: .init(id: check.id, pairRevision: page.pairRevision, answeredAt: answered))
                        }.buttonStyle(.bordered).accessibilityIdentifier("adultChecks.openGrocery")
                    } else if check.kind == .attendance, household.sharedShop?.canManage == true {
                        NavigationLink(checkText("Review shared groceries")) { HouseholdShopView(model: household) }
                    }
                    if check.reviewed { Label(checkText("Reply reviewed"), systemImage: "checkmark.circle") }
                    else { Button(checkText("Mark reply reviewed")) { Task { await perform { try await $0.reviewAdultCheck(in: $1, check: check) } } } }
                }
            } else if check.canAnswer {
                let answers: [AdultCheckAnswer] = check.kind == .attendance ? [.home, .latePlate, .out] : [.enough, .low, .cannotCheck]
                ForEach(answers, id: \.rawValue) { answer in
                    Button(answer.label) { amount = ""; unit = "count"; pendingReply = Reply(check: check, answer: answer) }
                        .buttonStyle(.bordered)
                }
            } else { Text(checkText("Waiting for a reply")) }
            Button(checkText("Withdraw question"), role: .destructive) { Task { await perform { try await $0.withdrawAdultCheck(in: $1, id: check.id) } } }
                .buttonStyle(.borderless)
        }.disabled(loading)
    }

    private func ask(_ page: AdultCheckPage, item: AdultCheckPage.Choice, recipient: UUID) {
        let request: Ask
        if let old = pendingAsk, old.source == item.id, old.recipient == recipient, old.kind == kind,
           old.shopRevision == page.shopRevision, old.pairRevision == page.pairRevision,
           old.authorityEpoch == page.authorityEpoch, old.expires > Date() { request = old }
        else {
            request = Ask(id: UUID(), source: item.id, recipient: recipient, kind: kind,
                          shopRevision: page.shopRevision, authorityEpoch: page.authorityEpoch, pairRevision: page.pairRevision,
                          expires: Date().addingTimeInterval(kind == .attendance ? 86400 : 7200))
            pendingAsk = request
        }
        Task {
            await perform { service, session in
                try await service.askAdultCheck(in: session, page: page, id: request.id, kind: request.kind, source: request.source, expires: request.expires)
            }
            if self.page?.checks.contains(where: { $0.id == request.id }) == true { pendingAsk = nil; selected = nil }
        }
    }

    private func reload() async { await perform { try await $0.fetchAdultChecks(in: $1) } }

    @MainActor private func perform(_ action: (HouseholdService, AdultShopRequestSession) async throws -> AdultCheckPage) async {
        guard !loading, let service = household.service, let projection = household.projection,
              household.adultRequestScope(shop: scope.shop, capability: "adult_checks") == scope else { return }
        let started = lifetime
        loading = true; message = nil
        defer { if lifetime == started { loading = false } }
        do {
            let session = try await service.adultShopRequestSession(projection, shopID: scope.shop)
            let result = try await action(service, session)
            guard lifetime == started, UIApplication.shared.isProtectedDataAvailable, UIApplication.shared.applicationState == .active,
                  household.adultRequestScope(shop: scope.shop, capability: "adult_checks") == scope else { return }
            guard let valid = result.deadline, valid > Date() else { throw ClientError.accessEnded }
            page = result
            if let reply = pendingReply, !result.checks.contains(where: { $0.id == reply.id && $0.canAnswer }) {
                pendingReply = nil
            }
        } catch {
            guard lifetime == started else { return }
            page = nil
            pendingReply = nil
            if case ClientError.service(let code, _, _, _) = error, code == 403 {
                message = checkText("This trip needs an active Household seat and access to the selected shop.")
            } else {
                message = checkText("Couldn’t confirm the latest questions. Refresh before trying again.")
            }
        }
    }
}
