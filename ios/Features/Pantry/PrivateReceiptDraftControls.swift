import CoreDomain
import SwiftUI

/// Private, editable text review. The document contains recognized text and geometry, never source media.
struct ReceiptLineDraft: Codable {
    typealias Position = ExtractedReceiptDocument.Selection
    let workspaceID: UUID
    let document: ExtractedReceiptDocument
    let merchant: String
    let stage: ReceiptAcquisition.DocumentLine.Stage
    let selection: Set<Position>
    let linkedAmountItems: Set<Position>
    let reviewedWording: [Position: String]
    let omittedLines: Set<Position>

    var receiptID: UUID { ReceiptAcquisition.identity(["document", document.digest.base64EncodedString()]) }

    func validate() throws {
        guard document.digest.count == 32, document.firstSectionDigest.map({ $0.count == 32 }) != false,
              (1...20).contains(document.pages.count), merchant.utf8.count <= 2048, !merchant.contains("\0"),
              selection.count <= 200, linkedAmountItems.isSubset(of: selection) else { throw PantryReceiptError.invalid }
        var positions = Set<Position>()
        var characters = 0
        for (index, page) in document.pages.enumerated() {
            guard page.id == index + 1, page.lines.count <= 200 else { throw PantryReceiptError.invalid }
            for line in page.lines {
                characters += line.text.count
                guard (1...200).contains(line.id), positions.insert(.init(page: page.id, line: line.id)).inserted,
                      !line.text.contains("\0"), characters <= 100_000,
                      validWordReadings(in: line) else { throw PantryReceiptError.invalid }
            }
        }
        let visible = positions.subtracting(omittedLines)
        guard omittedLines.isSubset(of: positions), selection.isSubset(of: visible),
              Set(reviewedWording.keys).isSubset(of: visible),
              reviewedWording.values.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
                  !$0.contains(where: \.isNewline) && $0.utf8.count <= 2048 }) else { throw PantryReceiptError.invalid }
        if !linkedAmountItems.isEmpty {
            let pairs = document.amountAssociations
            let all = pairs.merging(document.splitAmountAssociations(excluding: pairs)) { first, _ in first }
            let amounts = Set(linkedAmountItems.compactMap { all[$0] })
            guard stage != .order, amounts.count == linkedAmountItems.count, amounts.isSubset(of: visible),
                  selection.union(amounts).count <= 200, amounts.isDisjoint(with: reviewedWording.keys),
                  linkedAmountItems.isDisjoint(with: reviewedWording.keys) else { throw PantryReceiptError.invalid }
        }
    }
    private func validWordReadings(in line: ReceiptDocumentPage.Line) -> Bool {
        guard !line.wordReadings.isEmpty else { return true }
        // One observation offers two alternate readings; an assembled printed row can contain four observations.
        guard line.wordReadings.count <= 8 else { return false }
        let words = line.text.split(whereSeparator: \.isWhitespace)
        return line.wordReadings.allSatisfy { reading in
            guard words.indices.contains(reading.wordIndex), !reading.replacement.isEmpty,
                  reading.replacement.utf8.count <= 2048, reading.wording.utf8.count <= 4096,
                  !reading.replacement.contains(where: { $0.isWhitespace || $0 == "\0" }) else { return false }
            let original = words[reading.wordIndex]
            return reading.word == original && reading.replacement != original &&
                line.text.replacingCharacters(in: original.startIndex..<original.endIndex, with: reading.replacement) == reading.wording
        }
    }

}

@MainActor
final class PrivateReceiptDraftSession: ObservableObject {
    @Published private(set) var saved: SavedReceiptDraft?
    @Published private(set) var ready = false
    @Published private(set) var busy = false
    @Published private(set) var problem: String?
    private(set) var activeReceiptID: UUID?
    // The value shown at the last successful save. The protected representation
    // removes confirmations, so the editable view may contain additional transient choices.
    private var lastWritten: SavedReceiptDraft.Payload?
    private var epoch = UUID()

    func reset() {
        epoch = UUID()
        saved = nil
        activeReceiptID = nil
        lastWritten = nil
        ready = false
        busy = false
        problem = nil
    }

    func load(_ model: PantryModel) async {
        guard model.permitsPrivateReceiptDraft, !busy else { return }
        let token = epoch, generation = model.generation
        busy = true
        defer { if epoch == token { busy = false } }
        do {
            let current = try await model.savedReceiptDraft()
            guard token == epoch, generation == model.generation, model.permitsPrivateReceiptDraft else { return }
            if current?.revision != saved?.revision { activeReceiptID = nil; lastWritten = nil }
            saved = current
            ready = true
            problem = nil
        } catch {
            guard epoch == token, model.generation == generation else { return }
            ready = false
            problem = pantryText("The saved draft could not be opened. Try again.")
        }
    }

    func resume(revision: UUID, model: PantryModel) async -> SavedReceiptDraft? {
        guard ready, !busy, saved?.revision == revision, model.permitsPrivateReceiptDraft else { return nil }
        let token = epoch, generation = model.generation
        await load(model)
        guard token == epoch, generation == model.generation, model.permitsPrivateReceiptDraft, ready else { return nil }
        guard let saved, saved.revision == revision else {
            problem = pantryText(saved == nil
                ? "This saved draft is no longer available."
                : "The saved draft changed. Check the updated details and choose Resume again.")
            return nil
        }
        lastWritten = saved.payload
        switch saved.payload {
        case .lines(let value): activeReceiptID = value.receiptID
        case .putaway(let value): activeReceiptID = value.draftID
        }
        return saved
    }

    func activeRevision(for id: UUID) -> UUID? { activeReceiptID == id ? saved?.revision : nil }

    func matchesLastSave(_ value: SavedReceiptDraft.Payload) -> Bool {
        switch (lastWritten, value) {
        case let (.lines(a)?, .lines(b)):
            return a.receiptID == b.receiptID && a.merchant == b.merchant && a.stage == b.stage &&
                a.selection == b.selection && a.reviewedWording == b.reviewedWording &&
                a.linkedAmountItems == b.linkedAmountItems && a.omittedLines == b.omittedLines
        case let (.putaway(a)?, .putaway(b)):
            return a.draftID == b.draftID && a.merchant == b.merchant && a.reference == b.reference &&
                a.language == b.language && a.currency == b.currency && a.receiptTotal == b.receiptTotal &&
                a.purchaseDate == b.purchaseDate && a.purchaseTimeZone == b.purchaseTimeZone && a.lines == b.lines
        default:
            return false
        }
    }

    func write(_ payload: SavedReceiptDraft.Payload, id: UUID, model: PantryModel) async {
        guard !busy, ready, model.permitsPrivateReceiptDraft, saved == nil || activeRevision(for: id) != nil else { return }
        let token = epoch, generation = model.generation
        busy = true
        defer { if epoch == token { busy = false } }
        do {
            let next = try await model.saveReceiptDraft(payload, replacing: activeRevision(for: id))
            guard token == epoch, generation == model.generation, model.permitsPrivateReceiptDraft else { return }
            saved = next
            activeReceiptID = id
            lastWritten = payload
            problem = nil
        } catch {
            guard epoch == token, generation == model.generation else { return }
            problem = pantryText("The draft could not be saved. Your review is still open. Try again or reopen the saved draft.")
        }
    }

    func discard(_ version: UUID, model: PantryModel) async {
        guard !busy, ready, saved?.revision == version, model.permitsPrivateReceiptDraft else { return }
        let token = epoch, generation = model.generation
        busy = true
        defer { if epoch == token { busy = false } }
        do {
            try await model.discardReceiptDraft(revision: version)
            guard token == epoch, generation == model.generation, model.permitsPrivateReceiptDraft else { return }
            saved = nil
            activeReceiptID = nil
            lastWritten = nil
            problem = nil
        } catch {
            guard epoch == token, generation == model.generation else { return }
            problem = pantryText("The saved draft could not be discarded. Reopen it and try again.")
        }
    }
}

struct PrivateReceiptDraftContext {
    let model: PantryModel
    let session: PrivateReceiptDraftSession
}
private struct PrivateReceiptDraftKey: EnvironmentKey {
    static let defaultValue: PrivateReceiptDraftContext? = nil
}
extension EnvironmentValues {
    var privateReceiptDraft: PrivateReceiptDraftContext? {
        get { self[PrivateReceiptDraftKey.self] }
        set { self[PrivateReceiptDraftKey.self] = newValue }
    }
}

struct PrivateReceiptDraftSave: View {
    @ObservedObject var session: PrivateReceiptDraftSession
    let model: PantryModel
    let id: UUID
    let isLineSelection: Bool
    var atConfirmation = false
    let payload: () -> SavedReceiptDraft.Payload

    var body: some View {
        if model.permitsPrivateReceiptDraft {
            let active = session.activeRevision(for: id) != nil
            if active {
                let changedMessage = atConfirmation
                    ? "Leaving keeps only the last saved draft. Update it to keep these changes."
                    : "There are changes since the last saved draft. Update it to keep them."
                Text(pantryText(session.matchesLastSave(payload()) ? "Draft saved on this iPhone." : changedMessage))
                    .accessibilityIdentifier("receipt.draft.saved")
            } else if atConfirmation && session.ready && session.saved == nil {
                Text(pantryText("Leaving the app clears this review unless you save a draft."))
                    .font(.subheadline).foregroundStyle(Theme.secondary)
                    .accessibilityIdentifier("receipt.unsavedReviewNotice")
            } else {
                UnsavedReceiptReviewNotice()
            }
            if session.saved == nil || active {
                if atConfirmation { saveButton(active: active) }
                Text(pantryText(draftContents))
                    .font(.footnote).foregroundStyle(Theme.secondary)
                if !atConfirmation { saveButton(active: active) }
            } else {
                Text(pantryText("Another receipt draft is saved. Resume or discard it from Review a receipt before saving a different one."))
                    .font(.footnote).foregroundStyle(Theme.secondary)
            }
            if let problem = session.problem {
                Text(verbatim: problem).foregroundStyle(Theme.warning)
                if !session.ready {
                    Button(pantryText("Try again")) { Task { await session.load(model) } }
                }
            }
        }
    }

    private var draftContents: String {
        if isLineSelection {
            return "The draft keeps all recognized text, the store, your wording and line choices. The photo or file is excluded."
        }
        if atConfirmation {
            return "The draft keeps every line in this review, including lines you skip, along with the store, date, amounts and storage choices. Resume opens the editable lines for a new confirmation. The photo or file is excluded."
        }
        return "The draft keeps every line in this review, including lines you skip, along with the store, date, amounts and storage choices. Recheck the date, package and any linked purchases when you return. The original image or file is excluded."
    }

    private func saveButton(active: Bool) -> some View {
        Button(pantryText(active ? "Update saved draft" : "Save draft on this iPhone")) {
            let value = payload()
            Task { await session.write(value, id: id, model: model) }
        }.disabled(!session.ready || session.busy)
            .accessibilityIdentifier("receipt.draft.save")
    }
}
