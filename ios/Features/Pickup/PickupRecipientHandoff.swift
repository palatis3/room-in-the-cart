import SwiftUI
import UIKit
import CoreDomain

struct HandoffPiece: Codable, Equatable {
    let key: String
    let text: String
    let unresolved: String?
}

struct CookHandoffReview: Codable, Equatable {
    let pieces: [HandoffPiece]
    let timeZoneID: String
    let includesBudget: Bool
    let customWording: Bool
    let budget: String?
}

enum HandoffChannel: String, Codable { case cook, retailer }

struct RecipientSend: Codable, Equatable {
    let channel: HandoffChannel
    let versionID: UUID
    let recipient: String
    let language: String
    let sentAt: Date
    var acknowledgedAt: Date?

    func matches(_ copy: HandoffCopy, recipient: String) -> Bool {
        channel == copy.channel && versionID == copy.versionID && language == copy.language && self.recipient == recipient
    }
}

struct HandoffCopy: Equatable, Identifiable {
    let shopID: UUID
    let channel: HandoffChannel
    let versionID: UUID
    let revision: Int64
    let language: String
    let fullText: String
    let pieces: [HandoffPiece]?
    let needsPrivateReview: Bool
    var id: UUID { versionID }
    var heading: String { "\(pCook("Revision", language: language)) \(revision)" }

    static func retailer(_ snapshot: HandoffSnapshot, language: String) -> Self {
        let pieces = snapshot.revision.lines.map { line in
            let text = "\(line.name) — \(pQuantity(line.quantity, language: language))"
            let unresolved: String?
            switch line.expectedCost {
            case .exact: unresolved = nil
            case .bounded, .unknown: unresolved = "\(line.name) · \(pCook("Confirm the price", language: language))"
            }
            return HandoffPiece(key: line.id.uuidString, text: text, unresolved: unresolved)
        }
        let date = snapshot.createdAt.formatted(Date.FormatStyle(date: .complete, time: .shortened, locale: Locale(identifier: language)))
        let title = "\(pCook("Reviewed pickup", language: language)) · \(date)"
        let revision = "\(pCook("Revision", language: language)) \(snapshot.revision.number)"
        let text = ([title, revision] + pieces.map(\.text)).joined(separator: "\n")
        return Self(shopID: snapshot.basketID, channel: .retailer, versionID: snapshot.id, revision: snapshot.revision.number,
                    language: language, fullText: text, pieces: pieces, needsPrivateReview: false)
    }

    static func cook(_ note: PickupCookNote, shopID: UUID) -> Self {
        let review = note.reviewedHandoff
        let privateReview = review == nil || review?.customWording == true || review?.includesBudget == true
        return Self(shopID: shopID, channel: .cook, versionID: note.id, revision: note.revision, language: note.language,
                    fullText: note.text, pieces: privateReview ? nil : review?.pieces, needsPrivateReview: privateReview)
    }
}

enum HandoffCorrection: Equatable {
    case full(String)
    case changes(added: [String], removed: [String], unresolved: [String])

    static func review(current: HandoffCopy, prior: HandoffCopy?, paid: Bool, destinationConfirmed: Bool,
                       privateWordingConfirmed: Bool) -> Self? {
        guard !current.needsPrivateReview || privateWordingConfirmed else { return nil }
        guard paid, destinationConfirmed, !current.needsPrivateReview, let prior, !prior.needsPrivateReview, prior.shopID == current.shopID, prior.channel == current.channel,
              prior.language == current.language, let old = prior.pieces, let new = current.pieces else { return .full(current.fullText) }
        let before = Dictionary(old.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
        let after = Dictionary(new.map { ($0.key, $0.text) }, uniquingKeysWith: { first, _ in first })
        return .changes(added: new.filter { before[$0.key] != $0.text }.map(\.text),
                        removed: old.filter { after[$0.key] != $0.text }.map(\.text),
                        unresolved: new.compactMap(\.unresolved))
    }

    func text(current: HandoffCopy) -> String {
        switch self {
        case .full(let full): return full
        case let .changes(added, removed, unresolved):
            let language = current.language
            var lines = [pCook("Changes to the handoff", language: language),current.heading]
            for (label, values) in [("Add",added),("Remove",removed),("Still to confirm",unresolved)] {
                lines.append(pCook(label, language: language))
                lines += values.isEmpty ? [pCook("None", language: language)] : values
            }
            return lines.joined(separator: "\n\n")
        }
    }
}

extension PickupJourney {
    func lastSend(_ channel: HandoffChannel, recipient: String) -> RecipientSend? {
        (recipientSends ?? []).last { $0.channel == channel && $0.recipient == recipient }
    }

    func validateRecipientSends() throws {
        let sends = recipientSends ?? []
        var unique = Set<[String]>()
        for send in sends {
            let sourceExists = send.channel == .cook ? notes.contains { $0.id == send.versionID } : basket?.snapshots.contains { $0.id == send.versionID } == true
            guard sourceExists, !send.recipient.isEmpty, send.recipient == send.recipient.trimmingCharacters(in: .whitespacesAndNewlines),
                  send.recipient.utf8.count <= 160, send.sentAt.timeIntervalSinceReferenceDate.isFinite,
                  send.acknowledgedAt?.timeIntervalSinceReferenceDate.isFinite != false,
                  unique.insert([send.channel.rawValue,send.versionID.uuidString,send.recipient,send.language]).inserted else { throw HandoffError.invalid }
        }
        for review in notes.compactMap(\.reviewedHandoff) {
            guard TimeZone(identifier: review.timeZoneID) != nil,
                  Set(review.pieces.map(\.key)).count == review.pieces.count else { throw HandoffError.invalid }
        }
    }
}

private enum HandoffError: Error { case invalid }

extension PickupModel {
    func handoffCopy(channel: HandoffChannel, versionID: UUID, language: String) -> HandoffCopy? {
        guard let value = journey else { return nil }
        if channel == .cook {
            return value.notes.first { $0.id == versionID && $0.language == language }.map { .cook($0, shopID: value.id) }
        }
        guard let snapshot = value.basket?.snapshots.first(where: { $0.id == versionID }) else { return nil }
        return .retailer(snapshot, language: language)
    }

    func isCurrent(_ copy: HandoffCopy) -> Bool {
        guard let value = journey, value.id == copy.shopID, !saving, !hasPendingSave,
              handoffCopy(channel: copy.channel, versionID: copy.versionID, language: copy.language) == copy else { return false }
        if copy.channel == .retailer { return hasCurrentBasketStockBasis && frozenSnapshot?.id == copy.versionID }
        guard let current = cookJourney, let note = value.notes.last, note.id == copy.versionID, let review = note.reviewedHandoff,
              let zone = TimeZone(identifier: review.timeZoneID) else { return false }
        let pieces = PickupCookProjection.pieces(journey: current, allocation: allocation, language: note.language, timeZone: zone)
        return pieces == review.pieces && (!review.includesBudget || review.budget == result.map { PickupCookProjection.budgetText($0, language: note.language) })
    }

    func reviewedCorrection(_ copy: HandoffCopy, recipient: String, destinationConfirmed: Bool, privateWordingConfirmed: Bool,
                            paid: Bool, reviewedRevision: Int64?) -> HandoffCorrection? {
        guard let value = journey, value.revision == reviewedRevision, isCurrent(copy) else { return nil }
        let certain = !recipient.isEmpty && destinationConfirmed
        let last = paid && certain ? value.lastSend(copy.channel, recipient: recipient) : nil
        let prior = last.flatMap { handoffCopy(channel: copy.channel, versionID: $0.versionID, language: $0.language) }
        return .review(current: copy, prior: prior, paid: paid, destinationConfirmed: certain, privateWordingConfirmed: privateWordingConfirmed)
    }

    @discardableResult func markRecipient(_ copy: HandoffCopy, recipient: String, acknowledge: Bool, reviewedRevision: Int64) async -> Bool {
        guard let value = journey, value.id == copy.shopID, !saving, !hasPendingSave,
              handoffCopy(channel: copy.channel, versionID: copy.versionID, language: copy.language) == copy,
              !recipient.isEmpty, recipient.utf8.count <= 160, recipient == recipient.trimmingCharacters(in: .whitespacesAndNewlines) else { return false }
        let match: (RecipientSend) -> Bool = { $0.matches(copy, recipient: recipient) }
        let old = value.recipientSends?.first(where: match)
        if let old, !acknowledge || old.acknowledgedAt != nil { return true }
        guard value.revision == reviewedRevision, acknowledge ? old != nil : isCurrent(copy) else { return false }
        return await change { journey in
            var sends = journey.recipientSends ?? []
            if let index = sends.firstIndex(where: match) {
                sends[index].acknowledgedAt = Date()
            } else {
                sends.append(.init(channel: copy.channel, versionID: copy.versionID, recipient: recipient, language: copy.language, sentAt: Date()))
            }
            journey.recipientSends = sends
        }
    }
}

struct PickupRecipientSection: View {
    @ObservedObject var model: PickupModel
    let channel: HandoffChannel
    let versionID: UUID
    let language: String
    @EnvironmentObject private var membership: MembershipCoordinator
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var recipient = ""
    @State private var destinationConfirmed = false
    @State private var privateWordingConfirmed = false
    @State private var reviewRevision: Int64?
    @State private var copied = false

    private var name: String { recipient.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var allowed: Bool {
        access.unlocked && !household.locked && scenePhase == .active &&
            (household.projection.map { ["organizer","shopper"].contains($0.role) } ?? true)
    }
    private func correction(_ copy: HandoffCopy) -> HandoffCorrection? {
        guard allowed else { return nil }
        return model.reviewedCorrection(copy, recipient: name, destinationConfirmed: destinationConfirmed,
                                        privateWordingConfirmed: privateWordingConfirmed, paid: membership.model?.hasPaidAccess == true,
                                        reviewedRevision: reviewRevision)
    }
    var body: some View {
        if allowed, let journey = model.journey, let copy = model.handoffCopy(channel: channel, versionID: versionID, language: language) {
            Section(pTr("Recipient and version")) {
                TextField(pTr("Recipient (for explicit sent history)"), text: $recipient)
                    .accessibilityIdentifier("handoffRecipient")
                    .textInputAutocapitalization(.words).autocorrectionDisabled().submitLabel(.done)
                let savedRecipients = Set((journey.recipientSends ?? []).filter { $0.channel == channel }.map(\.recipient)).sorted()
                if !savedRecipients.isEmpty {
                    Menu(pTr("Choose a saved recipient")) {
                        ForEach(savedRecipients, id: \.self) { saved in Button(saved) { recipient = saved } }
                    }
                }
                let current = model.isCurrent(copy)
                let last = journey.lastSend(channel, recipient: name)
                let sent = journey.recipientSends?.first { $0.matches(copy, recipient: name) }
                Text(copy.heading)
                if let last, let previous = model.handoffCopy(channel: channel, versionID: last.versionID, language: last.language) {
                    let languageName = pTr(last.language.hasPrefix("es") ? "Español (EE. UU.)" : "English (US)")
                    Text("\(pTr("Last marked sent")) · \(last.recipient) · \(previous.heading) · \(languageName) · \(last.sentAt.formatted())")
                }
                if let sent {
                    Text("\(pTr("This version was marked sent")) · \(sent.sentAt.formatted())")
                    if let date = sent.acknowledgedAt { Text("\(pTr("Recipient acknowledgment reported")) · \(date.formatted())") }
                    else {
                        Text(pTr("Acknowledgment unknown"))
                        Button(pTr("The recipient acknowledged this version")) {
                            Task { if allowed { await model.markRecipient(copy, recipient: name, acknowledge: true, reviewedRevision: journey.revision) } }
                        }
                    }
                } else if current {
                    Button(pTr("I sent this version to this recipient")) {
                        Task { if allowed { await model.markRecipient(copy, recipient: name, acknowledge: false, reviewedRevision: journey.revision) } }
                    }.disabled(name.isEmpty || name.utf8.count > 160)
                }
                Text(pTr("A sent version does not prove receipt or acknowledgment. Cancelling share does not mark it sent."))
                if current {
                    Toggle(pTr("I know the previous copy went to this recipient"), isOn: $destinationConfirmed)
                        .disabled(name.isEmpty || last == nil)
                    if copy.needsPrivateReview {
                        Toggle(pTr("Include the saved custom or private wording in this correction"), isOn: $privateWordingConfirmed)
                    }
                    Button(pTr("Review correction")) { reviewRevision = journey.revision; copied = false }
                        .disabled(copy.needsPrivateReview && !privateWordingConfirmed)
                    if reviewRevision != nil {
                        TimelineView(.periodic(from: .now, by: 1)) { _ in
                            if let result = correction(copy) {
                                if case .full = result { Text(pTr("Complete current instruction")) }
                                Text(result.text(current: copy))
                                Button(pTr("Copy reviewed correction")) {
                                    guard let fresh = correction(copy), fresh == result else {
                                        resetReview(); return
                                    }
                                    UIPasteboard.general.string = fresh.text(current: copy)
                                    privateWordingConfirmed = false
                                    reviewRevision = nil; copied = true
                                }
                            } else { Text(pTr("The source changed. Review this version again.")) }
                        }
                    }
                    if copied { Text(pTr("Copied. Mark the version sent only after sending it.")) }
                } else { Text(pTr("The source changed. Prepare and review the current instruction.")) }
            }
            .onChange(of: language) { _, _ in destinationConfirmed = false; resetReview() }
            .onChange(of: recipient) { _, _ in destinationConfirmed = false; privateWordingConfirmed = false; resetReview() }
            .onChange(of: destinationConfirmed) { _, _ in resetReview() }
            .onChange(of: privateWordingConfirmed) { _, _ in reviewRevision = nil }
            .onChange(of: scenePhase) { _, value in if value != .active { privateWordingConfirmed = false; resetReview() } }
            .onReceive(model.cookLedgerRevisions) { _ in if channel == .cook { resetReview() } }
        }
    }
    private func resetReview() { reviewRevision = nil; copied = false }
}

struct HandoffPrintButton: View {
    let copy: HandoffCopy
    let allowed: Bool
    @Environment(\.scenePhase) private var scenePhase
    @State private var reviewingPrivateText = false
    @State private var printError = false
    @State private var activeRenderer: PickupPrintPageRenderer?

    var body: some View {
        let title = pTr(copy.channel == .cook ? "Print saved cook instruction" : "Print dated list")
        Button(title) {
            if copy.needsPrivateReview {
                reviewingPrivateText = true
            } else {
                presentPrint()
            }
        }
        .disabled(!allowed || activeRenderer != nil)
        .alert(pTr("Include the saved private or edited wording in this printout?"), isPresented: $reviewingPrivateText) {
            Button(pTr("Print this private copy")) { presentPrint() }
            Button(pTr("Cancel"), role: .cancel) {}
        }
        .alert(ledgerText("Printing is unavailable"), isPresented: $printError) {
            Button(ledgerText("Done")) {}
        }
        .onChange(of: allowed) { _, allowed in if !allowed { dismissPrint() } }
        .onChange(of: copy) { _, _ in dismissPrint() }
        .onChange(of: scenePhase) { _, phase in if phase == .background { dismissPrint() } }
        .onDisappear { dismissPrint() }
    }

    private func presentPrint() {
        guard allowed, scenePhase == .active, activeRenderer == nil else { return }
        guard UIPrintInteractionController.isPrintingAvailable else { printError = true; return }
        let text = NSAttributedString(string: copy.fullText, attributes: [
            .font: UIFont.systemFont(ofSize: 20), .foregroundColor: UIColor.black
        ])
        let renderer = PickupPrintPageRenderer(text: text)
        let controller = UIPrintInteractionController.shared
        let info = UIPrintInfo(dictionary: nil)
        info.jobName = "Room in the Cart"
        info.outputType = .grayscale
        controller.printInfo = info
        controller.printPageRenderer = renderer
        activeRenderer = renderer
        if !controller.present(animated: true, completionHandler: { controller, _, error in
            if controller.printPageRenderer === renderer { controller.printPageRenderer = nil }
            guard activeRenderer === renderer else { return }
            activeRenderer = nil
            printError = error != nil
        }) {
            if controller.printPageRenderer === renderer { controller.printPageRenderer = nil }
            activeRenderer = nil
            printError = true
        }
    }

    private func dismissPrint() {
        reviewingPrivateText = false
        guard let renderer = activeRenderer else { return }
        activeRenderer = nil
        let controller = UIPrintInteractionController.shared
        if controller.printPageRenderer === renderer {
            controller.dismiss(animated: false)
            controller.printPageRenderer = nil
        }
    }
}
