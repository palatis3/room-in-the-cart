import HouseholdClient
import SwiftUI

struct SharedCookHistoryView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedDeliveryPage
    let occurrence: SharedMealOccurrence
    @State private var copies: [SharedCookCopy]?
    @State private var failed = false

    private var allowed: Bool {
        !household.locked && household.sharedShop === model && model.canReadCookCopies &&
        model.deliveryRecord == page && page.meals?.contains(occurrence) == true
    }

    var body: some View {
        List {
            if allowed {
                Section(occurrence.meal.title) {
                    if failed {
                        Text(ht("Couldn’t load the saved cook instructions."))
                        Button(ht("Refresh")) { Task { await load() } }
                    } else if let copies {
                        if copies.isEmpty { Text(ht("No dated copies saved for this meal.")) }
                        ForEach(copies) { copy in
                            NavigationLink {
                                SharedCookSavedView(model: model, household: household, page: page, occurrence: occurrence, copy: copy)
                            } label: {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(ht("Copy version") + " " + copy.version.formatted())
                                    if let date = serviceDate(copy.createdAt) { Text(date.formatted()).font(.subheadline) }
                                    Text(copy.language == "es" ? pTr("Español (EE. UU.)") : pTr("English (US)"))
                                        .font(.subheadline)
                                }
                            }.accessibilityIdentifier("delivery.cook.saved." + String(copy.version))
                        }
                    } else { ProgressView() }
                }
            } else {
                Text(ht("Refresh deliveries and review the current record."))
            }
        }
        .navigationTitle(pTr("Saved cook notes"))
        .task(id: page) { await load() }
        .refreshable { await load() }
        .onChange(of: allowed) { _, active in if !active { copies = nil } }
    }

    private func load() async {
        guard allowed else { return }
        do {
            let result = try await model.cookCopies(occurrence: occurrence, reviewed: page)
            guard allowed, !Task.isCancelled else { return }
            copies = result
            failed = false
        } catch {
            guard allowed, !Task.isCancelled else { return }
            copies = nil
            failed = true
        }
    }
}

private struct SharedCookSavedView: View {
    @ObservedObject var model: HouseholdShopModel
    @ObservedObject var household: HouseholdModel
    let page: SharedDeliveryPage
    let occurrence: SharedMealOccurrence
    let copy: SharedCookCopy
    @Environment(\.scenePhase) private var scenePhase
    @State private var recipient = ""
    @State private var reviewed: RecipientReview?
    @State private var requestID: UUID?
    @State private var failure = false
    @State private var sharing = false
    @FocusState private var enteringName: Bool

    private struct RecipientReview {
        let name: String
        let baseline: SharedCookCopyBaseline?
    }

    private var name: String { (try? SharedCookCopyEdit.recipientLabel(recipient)) ?? "" }
    private var allowed: Bool {
        !household.locked && household.sharedShop === model && model.canReadCookCopies &&
        model.deliveryRecord == page && page.shopId == copy.shopId && occurrence.id == copy.occurrenceId
    }
    private var canCheck: Bool { allowed && scenePhase == .active && !model.busy && requestID == nil }
    private var canMark: Bool { canCheck && model.pending == nil }

    var body: some View {
        Form {
            if allowed {
                Section(occurrence.meal.title) {
                    LabeledContent(ht("Copy version"), value: copy.version.formatted())
                    Text(verbatim: copy.text).textSelection(.enabled).accessibilityIdentifier("delivery.cook.savedText")
                    Button {
                        guard allowed, scenePhase == .active else { return }
                        enteringName = false
                        sharing = true
                    } label: {
                        Label(ht("Share dated copy"), systemImage: "square.and.arrow.up")
                    }.accessibilityIdentifier("delivery.cook.savedShare")
                }
                Section {
                    TextField(pTr("Recipient (for explicit sent history)"), text: $recipient)
                        .focused($enteringName).autocorrectionDisabled().submitLabel(.done)
                        .accessibilityIdentifier("delivery.cook.recipient")
                    Button(ht("Check previous send")) { Task { await checkRecipient() } }
                        .disabled(!canCheck || name.isEmpty)
                        .accessibilityIdentifier("delivery.cook.checkRecipient")
                    if let reviewed, reviewed.name.utf8.elementsEqual(name.utf8) {
                        if let prior = reviewed.baseline {
                            LabeledContent(ht("Last version marked sent"), value: prior.copy.version.formatted())
                                .accessibilityIdentifier("delivery.cook.lastSent")
                            if let date = serviceDate(prior.send.sentAt) { Text(date.formatted()) }
                        } else { Text(ht("No previous send recorded for this recipient.")) }
                        if reviewed.baseline?.copy.copyId != copy.copyId {
                            Button(pTr("I sent this version to this recipient")) { Task { await markSent(reviewed) } }
                                .disabled(!canMark)
                                .accessibilityIdentifier("delivery.cook.markSent")
                        }
                    }
                    if requestID != nil { ProgressView() }
                    if failure { Text(ht("Check the current recipient record and try again.")) }
                    if let notice = model.notice { Text(notice) }
                } header: {
                    Text(pTr("Recipient and version"))
                } footer: {
                    Text(pTr("A sent version does not prove receipt or acknowledgment. Cancelling share does not mark it sent."))
                }
            } else { Text(ht("Refresh deliveries and review the current record.")) }
        }
        .navigationTitle(ht("Dated copy"))
        .onAppear {
            if recipient.isEmpty, allowed, let pending = model.pendingCookRecipient(for: occurrence) {
                recipient = pending
            }
        }
        .onChange(of: recipient) { _, _ in invalidate() }
        .onChange(of: allowed) { _, active in if !active { recipient = ""; sharing = false; invalidate() } }
        .onChange(of: scenePhase) { _, phase in if phase != .active { invalidate() } }
        .onDisappear { invalidate() }
        .sheet(isPresented: $sharing) {
            if allowed {
                PickupActivitySheet(text: copy.text) { _, _ in sharing = false }
            }
        }
    }

    private func invalidate() { requestID = nil; reviewed = nil; failure = false }

    private func checkRecipient() async {
        guard canCheck, !name.isEmpty else { return }
        let selected = name, id = UUID()
        enteringName = false
        reviewed = nil
        failure = false
        requestID = id
        defer { if requestID == id { requestID = nil } }
        do {
            let baseline = try await model.cookCopyBaseline(recipient: selected, occurrence: occurrence, reviewed: page)
            guard requestID == id, allowed, selected.utf8.elementsEqual(name.utf8) else { return }
            reviewed = .init(name: selected, baseline: baseline)
        } catch {
            if requestID == id { failure = true }
        }
    }

    private func markSent(_ review: RecipientReview) async {
        guard canMark, review.name.utf8.elementsEqual(name.utf8),
              reviewed?.name.utf8.elementsEqual(name.utf8) == true,
              reviewed?.baseline?.send.sendId == review.baseline?.send.sendId else { return }
        let id = UUID()
        enteringName = false
        requestID = id
        reviewed = nil
        failure = false
        let saved = await model.markCookCopySent(copy, recipient: review.name,
                                                 previousSendId: review.baseline?.send.sendId, reviewed: page)
        guard requestID == id, allowed, review.name.utf8.elementsEqual(name.utf8) else { return }
        requestID = nil
        if saved { await checkRecipient() } else { failure = true }
    }
}
