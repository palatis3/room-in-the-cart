import Combine
import CoreDomain
import Foundation

enum PrintedDateMeaning: String, Codable, CaseIterable {
    case bestBefore, useBy, sellBy, packedOn, expires, other

    var label: String {
        switch self {
        case .bestBefore: pantryText("Best before")
        case .useBy: pantryText("Use by")
        case .sellBy: pantryText("Sell by")
        case .packedOn: pantryText("Packed on")
        case .expires: pantryText("Expiration date")
        case .other: pantryText("Other or unclear")
        }
    }

    static func suggested(for text: String) -> Self {
        let wording = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let phrases: [(Self, [String])] = [
            (.bestBefore, ["best before", "best if used by", "best by", "consumo preferente", "preferentemente antes"]),
            (.useBy, ["use by", "use-by", "usar antes de"]),
            (.sellBy, ["sell by", "vender antes"]),
            (.packedOn, ["packed on", "packaged on", "envasado el", "fecha de envasado"]),
            (.expires, ["expiration", "expiry", "expires", "caducidad", "vencimiento"])
        ]
        let matches = phrases.filter { $0.1.contains(where: wording.contains) }
        return matches.count == 1 ? matches[0].0 : .other
    }
}

struct PrintedPackageDate: Equatable, Codable {
    let wording: String
    let meaning: PrintedDateMeaning
    let day: MealDay?
    /// Only the selected OCR wording is retained. The image and other text stay in the editor.
    let selectedPhotoText: String?
    let photoDigest: String?

    func validate() throws {
        guard !wording.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              wording.utf8.count <= 1024, !wording.contains("\0"),
              (selectedPhotoText == nil) == (photoDigest == nil),
              photoDigest.map({ $0.count == 64 && $0.allSatisfy(\.isHexDigit) }) ?? true,
              selectedPhotoText.map({ !$0.isEmpty && $0.utf8.count <= 1024 && !$0.contains("\0") }) ?? true else {
            throw PantryDigestFailure.invalid
        }
        try day?.validate()
    }

    static func reviewingPhoto(_ text: String, digest: String, zone: String) throws -> Self {
        let draft = Self(wording: text, meaning: .suggested(for: text), day: proposedDay(in: text, zone: zone),
                         selectedPhotoText: text, photoDigest: digest)
        try draft.validate()
        return draft
    }

    /// Numeric day/month labels and incomplete years stay as printed wording.
    static func proposedDay(in line: String, zone: String) -> MealDay? {
        let text = line.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX")).lowercased()
        let words = text.components(separatedBy: .alphanumerics.inverted).filter { !$0.isEmpty && $0 != "de" }
        let months = [
            ["jan", "january", "ene", "enero"], ["feb", "february", "febrero"], ["mar", "march", "marzo"],
            ["apr", "april", "abr", "abril"], ["may", "mayo"], ["jun", "june", "junio"],
            ["jul", "july", "julio"], ["aug", "august", "ago", "agosto"], ["sep", "sept", "september", "septiembre"],
            ["oct", "october", "octubre"], ["nov", "november", "noviembre"], ["dec", "december", "dic", "diciembre"]
        ]
        guard words.count >= 3 else { return nil }
        var candidates: [MealDay] = []
        for index in 0...(words.count - 3) {
            let a = words[index], b = words[index + 1], c = words[index + 2]
            let components: (Int, Int, Int)?
            if a.count == 4, b.count == 2, c.count == 2, let y = Int(a), let m = Int(b), let d = Int(c) {
                components = (y, m, d)
            } else if c.count == 4, let y = Int(c), let month = months.firstIndex(where: { $0.contains(b) }), let d = Int(a) {
                components = (y, month + 1, d)
            } else if c.count == 4, let y = Int(c), let month = months.firstIndex(where: { $0.contains(a) }), let d = Int(b) {
                components = (y, month + 1, d)
            } else { components = nil }
            if let (y, m, d) = components, let day = try? MealDay(year: y, month: m, day: d, timeZoneIdentifier: zone) {
                candidates.append(day)
            }
        }
        return candidates.count == 1 ? candidates.first : nil
    }
}

/// Each physical lot and authorized private owner has an independent, bounded record.
/// Edits use the value reviewed on screen, so two open windows cannot silently replace each other.
@MainActor final class PantryPackageDateStore: ObservableObject {
    @Published private(set) var generation = 0
    private let root: URL
    init(folder: URL) { root = folder }

    private struct Record: Codable {
        let version: Int
        let origin: UUID
        let owner: String
        let lotID: UUID
        let evidence: PrintedPackageDate
    }

    private func file(_ scope: PantryDigestScope, _ lot: UUID) -> URL {
        root.appendingPathComponent(scope.origin.uuidString, isDirectory: true)
            .appendingPathComponent(lot.uuidString, isDirectory: true).appendingPathComponent(scope.owner + ".json")
    }
    func load(_ scope: PantryDigestScope, lot: UUID) throws -> PrintedPackageDate? {
        let url = file(scope, lot)
        guard FileManager.default.fileExists(atPath: url.path) else { return nil }
        let saved = try JSONDecoder().decode(Record.self, from: PantryArchiveFiles.read(url, maximum: 16_384))
        guard saved.version == 1, saved.origin == scope.origin, saved.owner == scope.owner, saved.lotID == lot else {
            throw PantryDigestFailure.invalid
        }
        try saved.evidence.validate()
        return saved.evidence
    }
    func replace(_ previous: PrintedPackageDate?, with evidence: PrintedPackageDate?, scope: PantryDigestScope,
                 lot: UUID, authorized: () -> Bool) throws {
        guard authorized(), try load(scope, lot: lot) == previous else { throw PantryDigestFailure.changed }
        let url = file(scope, lot)
        if let evidence {
            try evidence.validate()
            let data = try JSONEncoder().encode(Record(version: 1, origin: scope.origin, owner: scope.owner, lotID: lot, evidence: evidence))
            try PantryArchiveFiles.directory(url.deletingLastPathComponent(), create: true)
            try data.write(to: url, options: [.atomic, .completeFileProtection])
            try PantryArchiveFiles.protect(url, permissions: 0o600)
        } else if previous != nil {
            try FileManager.default.removeItem(at: url)
        }
        generation += 1
    }
    func erase(origin: UUID, whole: Bool, stillHasLot: (UUID) async throws -> Bool) async throws {
        let folder = root.appendingPathComponent(origin.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: folder.path) else { return }
        if whole {
            try FileManager.default.removeItem(at: folder)
        } else {
            for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                if let lot = UUID(uuidString: url.lastPathComponent), try await !stillHasLot(lot) {
                    try FileManager.default.removeItem(at: url)
                }
            }
        }
        generation += 1
    }
}
