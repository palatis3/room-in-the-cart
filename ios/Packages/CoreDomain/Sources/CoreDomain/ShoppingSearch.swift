import Foundation

/// The exact saved fields that explain a result. None of these fields certifies package contents.
public struct ShoppingSearchEvidence: Hashable, Sendable {
    public enum Field: Hashable, Sendable {
        case name, lineNote, department, originalEntry, contributionNote
    }

    public let field: Field
    public let text: String

    init(_ field: Field, _ text: String) {
        self.field = field
        self.text = text
    }

    /// Preserve literal strings for display, including punctuation and qualifications.
    /// The existing phrase search also accepts text spanning adjacent fields.
    fileprivate static func matching(_ fields: [Self], term: String) -> [Self] {
        let components = fields.compactMap { field -> (Self, String)? in
            let value = normalizedProduct(field.text)
            return value.isEmpty ? nil : (field, value)
        }
        if components.count == 1, let (field, value) = components.first {
            return value.contains(term) ? [field] : []
        }
        let direct = components.filter { $0.1.contains(term) }.map(\.0)
        if !direct.isEmpty { return direct }
        let joined = components.map(\.1).joined(separator: " ")
        guard let range = joined.range(of: term) else { return [] }
        let start = joined.utf8.distance(from: joined.startIndex, to: range.lowerBound)
        let end = joined.utf8.distance(from: joined.startIndex, to: range.upperBound)
        var offset = 0
        return components.compactMap { field, value in
            let next = offset + value.utf8.count
            defer { offset = next + 1 }
            return offset < end && next > start ? field : nil
        }
    }
}

public struct ShoppingSearchResult: Sendable {
    public let line: ShoppingLine
    public let evidence: [ShoppingSearchEvidence]
    public let spansFields: Bool
}

extension ShoppingLedger {
    public func searchResults(_ query: String, department: ((ShoppingLine) -> String)? = nil) -> [ShoppingSearchResult] {
        let term = normalizedProduct(query)
        var sources: [UUID: [ShoppingSearchEvidence]] = [:]
        if !term.isEmpty {
            for contribution in contributions where contribution.removedAt == nil {
                let matched = ShoppingSearchEvidence.matching([
                    .init(.originalEntry, contribution.originalText), .init(.contributionNote, contribution.notes)
                ], term: term)
                if !matched.isEmpty { sources[contribution.lineID, default: []].append(contentsOf: matched) }
            }
        }
        return lines.compactMap { source -> ShoppingSearchResult? in
            guard !source.isTrashed else { return nil }
            var line = source
            if let department { line.aisle = department(source) }
            if term.isEmpty { return ShoppingSearchResult(line: line, evidence: [], spansFields: false) }
            let fields = ShoppingSearchEvidence.matching([
                .init(.name, line.name), .init(.lineNote, line.notes), .init(.department, line.aisle)
            ], term: term)
            let historical = sources[line.id] ?? []
            guard !fields.isEmpty || !historical.isEmpty else { return nil }
            // Manual entries commonly duplicate the current name and note in their underlying contribution.
            var seen = Set(fields)
            let extra = historical.filter { item in
                if item.field == .originalEntry && seen.contains(.init(.name, item.text)) { return false }
                if item.field == .contributionNote && seen.contains(.init(.lineNote, item.text)) { return false }
                return seen.insert(item).inserted
            }
            let evidence = fields + extra
            let spansFields = evidence.count > 1 && !evidence.contains { normalizedProduct($0.text).contains(term) }
            return ShoppingSearchResult(line: line, evidence: evidence, spansFields: spansFields)
        }.sorted { $0.line.originalOrder < $1.line.originalOrder }
    }
}
