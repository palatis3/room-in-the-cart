import Foundation

public struct CookingStepNote: Codable, Equatable, Identifiable, Sendable {
    public let id: UUID
    public let revision: String
    public let step: Int
    public let instruction: String
    public let text: String
    public let hidden: Bool

    public init(id: UUID = UUID(), revision: String, step: Int, instruction: String, text: String, hidden: Bool = false) {
        self.id = id
        self.revision = revision
        self.step = step
        self.instruction = instruction
        self.text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        self.hidden = hidden
    }

    public func belongs(to key: CookingSessionKey, step index: Int, instruction current: String) -> Bool {
        revision == key.revision && step == index && instruction == current
    }

    fileprivate var valid: Bool {
        !revision.isEmpty && revision.utf8.count <= 256 && (0..<1000).contains(step) &&
        instruction.utf8.count <= 32768 && !instruction.contains("\0") &&
        !text.isEmpty && text.utf8.count <= 2048 && !text.contains("\0")
    }
}

extension CookingSessionStore {
    private func notesFile(_ key: CookingSessionKey) -> URL {
        file(key).deletingLastPathComponent().appendingPathComponent(key.privateAudienceFilename + ".stepnotes")
    }

    public func stepNotes(for key: CookingSessionKey) throws -> [CookingStepNote] {
        let path = notesFile(key)
        guard FileManager.default.fileExists(atPath: path.path) else { return [] }
        let facts = try path.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey])
        guard facts.isRegularFile == true, facts.isSymbolicLink != true, let size = facts.fileSize, size <= 2_097_152
        else { throw CookingSessionError.invalid }
        let notes = try JSONDecoder().decode([CookingStepNote].self, from: Data(contentsOf: path))
        guard notes.count <= 1000, Set(notes.map(\.id)).count == notes.count, notes.allSatisfy(\.valid)
        else { throw CookingSessionError.invalid }
        return notes
    }

    /// Keep other steps' edits. A stale editor cannot replace, move or resurrect a changed note.
    public func replaceStepNote(_ previous: CookingStepNote?, with next: CookingStepNote?, for key: CookingSessionKey) throws {
        guard let id = previous?.id ?? next?.id else { throw CookingSessionError.invalid }
        var notes = try stepNotes(for: key)
        let index = notes.firstIndex { $0.id == id }
        guard index.map({ notes[$0] }) == previous else { throw CookingSessionError.stale }
        if let next {
            guard !notes.contains(where: { $0.id != id && $0.revision == next.revision && $0.step == next.step }) else { throw CookingSessionError.stale }
            guard next.id == id, next.valid else { throw CookingSessionError.invalid }
            guard next.revision == key.revision || (previous?.revision == next.revision &&
                  previous?.step == next.step && previous?.instruction == next.instruction) else { throw CookingSessionError.stale }
            if let index { notes[index] = next } else { notes.append(next) }
        } else if let index { notes.remove(at: index) }
        let path = notesFile(key)
        if notes.isEmpty { try FileManager.default.removeItem(at: path); return }
        let bytes = try JSONEncoder().encode(notes)
        guard notes.count <= 1000, bytes.count <= 2_097_152 else { throw CookingSessionError.capacity }
        var folder = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var availability = URLResourceValues()
        availability.isExcludedFromBackup = true
        try folder.setResourceValues(availability)
        #if os(iOS)
        try bytes.write(to: path, options: [.atomic, .completeFileProtection])
        #else
        try bytes.write(to: path, options: .atomic)
        #endif
    }
}
