import CoreDomain
import SwiftUI

func currentStopSourceText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "CurrentStopSearch")
}

struct CurrentStopSearchHit {
    var fields: [ShoppingSearchEvidence] = []
    var photoCue = false

    func contains(_ field: ShoppingSearchEvidence.Field) -> Bool {
        fields.contains { $0.field == field }
    }

    static let rowEntryLimit = 2

    var originalFields: [ShoppingSearchEvidence] {
        fields.filter { $0.field == .originalEntry || $0.field == .contributionNote }
    }
}

enum CurrentStopSourceCaption: Equatable {
    case name, note, matchedNote, department, photo, matchedPhoto, earlierPhoto, matchedEarlierPhoto, entry, entryNote

    var title: String {
        switch self {
        case .name: currentStopSourceText("Matching item name")
        case .note: currentStopSourceText("List note")
        case .matchedNote: currentStopSourceText("Matching list note")
        case .department: currentStopSourceText("Matching department")
        case .photo: currentStopSourceText("Photo cue")
        case .matchedPhoto: currentStopSourceText("Matching photo cue")
        case .earlierPhoto: currentStopSourceText("Photo cue from an earlier trip")
        case .matchedEarlierPhoto: currentStopSourceText("Matching photo cue from an earlier trip")
        case .entry: currentStopSourceText("Original list entry")
        case .entryNote: currentStopSourceText("Note on original entry")
        }
    }

    var journalKind: JournalSourceKind? {
        switch self {
        case .name, .note, .matchedNote, .entry, .entryNote: .shoppingList
        case .department, .photo, .matchedPhoto, .earlierPhoto, .matchedEarlierPhoto: nil
        }
    }

    static func photoCue(for photo: PackageRowPhoto, matched: Bool) -> Self {
        if let original = photo.originalTarget, photo.association != nil,
           original.containerID != photo.target.containerID {
            return matched ? .matchedEarlierPhoto : .earlierPhoto
        }
        return matched ? .matchedPhoto : .photo
    }

    // An arbitrary prefix could omit the qualification that changes the meaning of a note.
    func rowLiteral(_ text: String) -> String {
        text.count > 195 ? currentStopSourceText("Read the full text in Item details.") : text
    }

    func spoken(_ text: String) -> String { title + ", " + rowLiteral(text) }
}

/// Keep the source outside the literal so language changes never rewrite a shopper's words.
struct CurrentStopSourceText: View {
    let caption: CurrentStopSourceCaption
    let literal: String
    var fullText = false

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            JournalSourceLabel(kind: caption.journalKind, title: caption.title).font(.caption).foregroundStyle(Theme.secondary)
            Text(verbatim: fullText ? literal : caption.rowLiteral(literal))
        }
        .multilineTextAlignment(.leading)
        .fixedSize(horizontal: false, vertical: true)
        .accessibilityElement(children: .combine)
    }
}
