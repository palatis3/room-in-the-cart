import HouseholdClient
import SwiftUI

struct SharedGroceryTarget: Identifiable {
    struct Reply {
        let id: UUID
        let pairRevision: Int
        let answeredAt: String
    }
    var id: UUID { rowID }
    let shopID, rowID: UUID
    let revision, authorityEpoch: Int
    let reply: Reply?

    func confirmedReply(in page: AdultCheckPage, row: ShopperBasketLine) throws -> AdultCheckPage.Check {
        guard let reply, page.shopper, page.shopId == shopID, page.shopRevision == revision,
              page.authorityEpoch == authorityEpoch, page.pairRevision == reply.pairRevision,
              page.deadline.map({ $0 > Date() }) == true,
              let check = page.checks.first(where: { $0.id == reply.id }), check.kind == .cupboard,
              check.sourceId == rowID, UUID(uuidString: row.id) == rowID, check.shoppingPacks == row.packs,
              check.answer != nil, check.answeredAt == reply.answeredAt, check.deadline.map({ $0 > Date() }) == true
        else { throw ClientError.invalidResponse }
        return check
    }
}

struct SharedGroceryLineView: View {
    @ObservedObject var household: HouseholdModel
    let target: SharedGroceryTarget
    var onKeep: (() -> Void)? = nil
    let onPrepared: () -> Void

    var body: some View {
        PrivateAdultRequestSurface(household: household, shopID: target.shopID,
                                  capability: target.reply == nil ? "shopper_commands" : "adult_checks") { scope in
            if let model = household.sharedShop, model.canManage {
                GroceryLineDetail(household: household, model: model, scope: scope, target: target, onKeep: onKeep, onPrepared: onPrepared)
            } else { Text(checkText("Refresh the shared shop to review this grocery.")) }
        }
    }
}

private struct GroceryLineDetail: View {
    @ObservedObject var household: HouseholdModel
    @ObservedObject var model: HouseholdShopModel
    let scope: AdultRequestViewScope
    let target: SharedGroceryTarget
    let onKeep: (() -> Void)?
    let onPrepared: () -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var row: ShopperBasketLine?
    @State private var reply: AdultCheckPage.Check?
    @State private var deadline: Date?
    @State private var count = 1
    @State private var working = false
    @State private var life = UUID()

    var body: some View {
        WorkingForm {
            if let current = row, model.shop?.shopRevision == target.revision,
               model.shop?.authorityEpoch == target.authorityEpoch, deadline.map({ $0 > Date() }) ?? true {
                Text(verbatim: current.originalItem).font(.headline).accessibilityIdentifier("sharedGrocery.name")
                if let answer = reply?.answer {
                    LabeledContent(checkText("Reply"), value: answer.label)
                    if let q = reply?.quantity {
                        let value = Decimal(string: q.value, locale: Locale(identifier: "en_US_POSIX"))?.formatted(.number.locale(locale)) ?? q.value
                        LabeledContent(checkText("Amount at home"), value: q.unit == "count" ? value : value + " " + checkText(q.unit))
                    }
                    Text(checkText(answer.reviewPrompt))
                }
                LabeledContent(checkText("Packs on the shopping list"), value: current.packs.formatted())
                    .accessibilityElement(children: .combine)
                    .accessibilityIdentifier("sharedGrocery.currentPacks")
                if model.shop?.phase == "draft", !model.editing, model.pending == nil {
                    Stepper(value: $count, in: 1...10_000) {
                        LabeledContent(checkText("Planned packs"), value: count.formatted())
                    }
                    if count != current.packs {
                        Button(checkText("Review pack change")) { Task { await load(edit: count) } }
                            .accessibilityIdentifier("sharedGrocery.review")
                    }
                }
                Button(checkText("Keep current packs")) {
                    onKeep?()
                    dismiss()
                }.accessibilityIdentifier("sharedGrocery.keep")
            } else if working { ProgressView() }
            else {
                Text(checkText("Refresh the shared shop to review this grocery."))
                Button(checkText("Try again")) { Task { await load() } }
            }
        }
        .disabled(working)
        .navigationTitle(checkText("Review this grocery"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(checkText("Cancel")) { dismiss() } } }
        .task { await load() }
        .task(id: deadline) {
            guard let expiry = deadline else { return }
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
            row = nil
            reply = nil
        }
        .onDisappear { life = UUID(); row = nil; reply = nil; deadline = nil }
    }

    @MainActor private func load(edit: Int? = nil) async {
        guard !working else { return }
        let started = life
        working = true
        defer { if life == started { working = false } }
        do {
            let exact = try await model.currentGrocery(shopID: target.shopID, rowID: target.rowID,
                                                       revision: target.revision, authority: target.authorityEpoch)
            var checked: AdultCheckPage.Check?
            var until: Date?
            let capability = target.reply == nil ? "shopper_commands" : "adult_checks"
            if target.reply != nil {
                guard let projection = household.projection, let service = household.service else { throw ClientError.accessEnded }
                let session = try await service.adultShopRequestSession(projection, shopID: target.shopID)
                let page = try await service.fetchAdultChecks(in: session)
                checked = try target.confirmedReply(in: page, row: exact)
                until = [page.deadline, checked?.deadline].compactMap { $0 }.min()
            }
            guard life == started, !Task.isCancelled, UIApplication.shared.isProtectedDataAvailable,
                  UIApplication.shared.applicationState == .active, household.sharedShop === model,
                  household.adultRequestScope(shop: target.shopID, capability: capability) == scope,
                  model.canManage, model.shop?.shopRevision == target.revision, model.shop?.authorityEpoch == target.authorityEpoch
            else { throw ClientError.cancelled }
            if let edit {
                guard exact == row, model.preparePackEdit(rowID: target.rowID, original: exact, count: edit,
                                                         revision: target.revision, authority: target.authorityEpoch)
                else { throw ClientError.invalidResponse }
                onPrepared()
            } else {
                row = exact
                reply = checked
                deadline = until
                count = exact.packs
            }
        } catch {
            guard life == started else { return }
            row = nil
            reply = nil
            deadline = nil
        }
    }
}
