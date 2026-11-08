import HouseholdClient
import SwiftUI

extension SharedCookCopy {
    func handoff(pieces: [(section: SharedCookFactIndex.Section, wording: String)]) -> HandoffCopy {
        HandoffCopy(shopID: shopId, channel: .cook, versionID: copyId, revision: Int64(version), language: language,
                    fullText: text, pieces: pieces.map { HandoffPiece(key: $0.section.key, text: $0.wording, unresolved: $0.section.unresolved ? $0.wording : nil) },
                    needsPrivateReview: false)
    }
}

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
                                SharedCookSavedView(model: model, household: household, page: page, occurrence: occurrence, copy: copy, latest: copies.first?.id == copy.id)
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
    let latest: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var recipient = ""
    @State private var reviewed: RecipientReview?
    @State private var requestID: UUID?
    @State private var failure = false
    @EnvironmentObject private var membership: MembershipCoordinator
    @State private var sharing: Message?
    @State private var destinationConfirmed = false
    #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
    // Diagnostic identity is unrelated to any household, recipient, copy or request.
    @State private var destinationTraceID = UUID()
    #endif
    @State private var correction: HandoffCorrection?
    @State private var fullWording = ""
    @State private var wordingConfirmed = false

    private struct Message: Identifiable {
        let id = UUID()
        let text: String
        let assisted: Bool
    }
    private var paid: Bool {
        guard let seat = membership.model, seat.context?.householdID == model.householdID,
              seat.context?.purchaserID == model.memberID else { return false }
        return seat.hasPaidAccess
    }
    private var seatDeadline: Date? {
        guard paid, let snapshot = membership.model?.state.snapshot,
              let end = snapshot.status == .grace ? snapshot.graceExpiresAt : snapshot.expiresAt else { return nil }
        return min(snapshot.validUntil, end)
    }
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
    private var canMark: Bool {
        if case .full = correction, !fullWording.utf8.elementsEqual(copy.text.utf8) { return false }
        return canCheck && model.pending == nil
    }

    var body: some View {
        Form {
            if allowed {
                Section(occurrence.meal.title) {
                    LabeledContent(ht("Copy version"), value: copy.version.formatted())
                    Text(verbatim: copy.text).textSelection(.enabled).accessibilityIdentifier("delivery.cook.savedText")
                    Button {
                        guard allowed, scenePhase == .active else { return }
                        enteringName = false
                        sharing = Message(text: copy.text, assisted: false)
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
                            DisclosureGroup(pTr("Last marked sent")) { Text(verbatim: prior.copy.text).textSelection(.enabled) }
                            if latest && paid && model.canReviewCookCorrection {
                                Toggle(pTr("I know the previous copy went to this recipient"), isOn: Binding(
                                    get: { destinationConfirmed },
                                    set: { value in
                                        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
                                        traceDestination("setter-enter", from: destinationConfirmed, to: value)
                                        #endif
                                        requestID = nil
                                        clearCorrection()
                                        destinationConfirmed = value
                                        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
                                        traceDestination("setter-return")
                                        #endif
                                    }))
                                    .accessibilityIdentifier("delivery.cook.confirmDestination")
                            }
                        } else { Text(ht("No previous send recorded for this recipient.")) }
                        if latest {
                            Button(pTr("Review correction")) {
                                Task { await reviewCorrection(reviewed) }
                            }.disabled(!canCheck)
                            .accessibilityIdentifier("delivery.cook.reviewCorrection")
                            if let correction {
                                switch correction {
                                case .full:
                                    TextField(ht("Full correction for this recipient"), text: $fullWording, axis: .vertical)
                                        .accessibilityIdentifier("delivery.cook.fullCorrection")
                                    Toggle(pTr("Include the saved custom or private wording in this correction"), isOn: $wordingConfirmed)
                                case .changes:
                                    Text(verbatim: correction.text(current: copy.handoff(pieces: [])))
                                        .accessibilityIdentifier("delivery.cook.correctionText")
                                }
                                Button(ht("Share reviewed correction")) { Task { await reviewCorrection(reviewed, sharingReviewed: true) } }
                                    .disabled(!canCheck || !canShareCorrection)
                                    .accessibilityIdentifier("delivery.cook.shareCorrection")
                            }
                        }
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
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("appear")
            #endif
            if recipient.isEmpty, allowed, let pending = model.pendingCookRecipient(for: occurrence) {
                recipient = pending
            }
        }
        .onChange(of: recipient) { _, _ in
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("recipient-changed")
            #endif
            invalidate()
        }
        .onChange(of: allowed) { _, active in
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("allowed-changed")
            #endif
            if !active { recipient = ""; sharing = nil; invalidate() }
        }
        .onChange(of: scenePhase) { _, phase in
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("scene-changed")
            #endif
            if phase != .active { invalidate() }
        }
        .onChange(of: fullWording) { _, _ in wordingConfirmed = false }
        .onChange(of: paid) { _, _ in
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("paid-changed")
            #endif
            requestID = nil
            if sharing?.assisted == true { sharing = nil }
            clearCorrection()
        }
        .task(id: seatDeadline) {
            guard let end = seatDeadline else { return }
            do { try await Task.sleep(for: .seconds(max(0, end.timeIntervalSinceNow))) } catch { return }
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("seat-deadline-fired")
            #endif
            if sharing?.assisted == true { sharing = nil }
            clearCorrection()
        }
        .onDisappear {
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("disappear")
            #endif
            invalidate()
        }
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        .onChange(of: destinationConfirmed) { old, new in
            traceDestination("state-change", from: old, to: new)
        }
        .onChange(of: copy.copyId) { _, _ in traceDestination("copy-identity-changed") }
        .onChange(of: page) { _, _ in traceDestination("page-changed") }
        .onChange(of: ObjectIdentifier(model)) { _, _ in traceDestination("model-identity-changed") }
        #endif
        .sheet(item: $sharing) { message in
            if allowed && (!message.assisted || paid) {
                PickupActivitySheet(text: message.text) { _, _ in sharing = nil }
            }
        }
    }

    #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
    private func traceDestination(_ event: String, from: Bool? = nil, to: Bool? = nil) {
        guard CookDestinationTrace.enabled else { return }
        CookDestinationTrace.emit(event, state: destinationTraceID, from: from, to: to,
            confirmed: destinationConfirmed, hasReview: reviewed != nil, hasRequest: requestID != nil,
            hasCorrection: correction != nil, allowed: allowed, paid: paid, active: scenePhase == .active)
    }
    #endif

    private var canShareCorrection: Bool {
        switch correction {
        case .full: return wordingConfirmed && !fullWording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && fullWording.utf16.count <= 16_000
        case .changes: return paid && destinationConfirmed
        case nil: return false
        }
    }

    private func clearCorrection() {
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        traceDestination("clear-correction")
        #endif
        correction = nil; fullWording = ""; wordingConfirmed = false
    }
    private func invalidate() {
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        traceDestination("invalidate-enter")
        #endif
        requestID = nil; reviewed = nil; failure = false; destinationConfirmed = false; clearCorrection()
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        traceDestination("invalidate-return")
        #endif
    }

    private func reviewCorrection(_ review: RecipientReview, sharingReviewed: Bool = false) async {
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        traceDestination("review-enter")
        defer { traceDestination("review-exit") }
        #endif
        guard latest, canCheck, review.name.utf8.elementsEqual(name.utf8) else { return }
        let previous = correction, id = UUID(), confirmed = destinationConfirmed
        let wording = fullWording
        requestID = id; failure = false; enteringName = false
        defer { if requestID == id { requestID = nil } }
        do {
            let result = try await model.reviewedCookCorrection(copy, recipient: review.name, baseline: review.baseline,
                destinationConfirmed: confirmed, paid: paid, occurrence: occurrence, reviewed: page)
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("review-result")
            #endif
            guard id == requestID, allowed, scenePhase == .active, review.name.utf8.elementsEqual(name.utf8),
                  reviewed?.baseline?.send.sendId == review.baseline?.send.sendId, destinationConfirmed == confirmed else { return }
            if case .changes = result, !paid { clearCorrection(); return }
            if !sharingReviewed || result != previous {
                correction = result; fullWording = copy.text; wordingConfirmed = false
            } else if canShareCorrection {
                switch result {
                case .full:
                    guard wording.utf8.elementsEqual(fullWording.utf8) else { return }
                    sharing = Message(text: wording, assisted: false)
                case .changes:
                    sharing = Message(text: result.text(current: copy.handoff(pieces: [])), assisted: true)
                }
            }
        } catch {
            guard id == requestID else { return }
            clearCorrection()
            failure = true
        }
    }

    private func checkRecipient() async {
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        traceDestination("check-recipient-enter")
        defer { traceDestination("check-recipient-exit") }
        #endif
        guard canCheck, !name.isEmpty else { return }
        let selected = name, id = UUID()
        enteringName = false
        invalidate()
        requestID = id
        defer { if requestID == id { requestID = nil } }
        do {
            let baseline = try await model.cookCopyBaseline(recipient: selected, occurrence: occurrence, reviewed: page)
            guard requestID == id, allowed, selected.utf8.elementsEqual(name.utf8) else { return }
            reviewed = .init(name: selected, baseline: baseline)
            #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
            traceDestination("baseline-accepted")
            #endif
        } catch {
            if requestID == id { failure = true }
        }
    }

    private func markSent(_ review: RecipientReview) async {
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        traceDestination("mark-sent-enter")
        defer { traceDestination("mark-sent-exit") }
        #endif
        guard canMark, review.name.utf8.elementsEqual(name.utf8),
              reviewed?.name.utf8.elementsEqual(name.utf8) == true,
              reviewed?.baseline?.send.sendId == review.baseline?.send.sendId else { return }
        let id = UUID()
        enteringName = false
        invalidate()
        requestID = id
        let saved = await model.markCookCopySent(copy, recipient: review.name,
                                                 previousSendId: review.baseline?.send.sendId, reviewed: page)
        guard requestID == id, allowed, review.name.utf8.elementsEqual(name.utf8) else { return }
        requestID = nil
        if saved { await checkRecipient() } else { failure = true }
    }
}

#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
// Temporary fixture-only diagnostics. Never include product IDs, wording, recipient text or errors.
private enum CookDestinationTrace {
    private static let scope = "SharedDeliveryUITests/testShopperSavesDatedCookCopyAndReopensRecipientSendRecord"
    static let enabled: Bool = {
        let process = ProcessInfo.processInfo
        return process.arguments.contains("--ui-testing") &&
            process.arguments.contains("--shared-delivery-fixture") &&
            process.arguments.contains("--shared-cook-copies-fixture") &&
            process.environment["S24_COOK_DESTINATION_TRACE_SCOPE"] == scope
    }()
    static func emit(_ event: String, state: UUID, from: Bool?, to: Bool?, confirmed: Bool,
                     hasReview: Bool, hasRequest: Bool, hasCorrection: Bool,
                     allowed: Bool, paid: Bool, active: Bool) {
        guard enabled else { return }
        let process = ProcessInfo.processInfo
        let old = from.map { String($0) } ?? "-", new = to.map { String($0) } ?? "-"
        print("S24_COOK_DESTINATION_TRACE uptime=\(process.systemUptime) pid=\(process.processIdentifier) scope=\(scope) event=\(event) state=\(state) from=\(old) to=\(new) confirmed=\(confirmed) review=\(hasReview) request=\(hasRequest) correction=\(hasCorrection) allowed=\(allowed) paid=\(paid) active=\(active)")
    }
}
#endif
