import Foundation

/// An untyped UTF-8 grocery export. Conversion belongs to each destination's review.
public struct GroceryCSVTable: Equatable, Sendable {
    public let headers: [String]
    public let rows: [[String]]
    public static let maximumBytes = 2 * 1_024 * 1_024
    public static let maximumRows = 5_000
    public static let maximumColumns = 64

    public enum ReadError: Error, Equatable {
        case invalidEncoding, malformed, tooLarge, emptyHeader, ambiguousSeparator
    }

    public init(data: Data, delimiter: Character? = nil) throws {
        guard data.count <= Self.maximumBytes else { throw ReadError.tooLarge }
        guard var text = String(data: data, encoding: .utf8), !text.contains("\0") else { throw ReadError.invalidEncoding }
        if text.first == "\u{feff}" { text.removeFirst() }
        let separator = try delimiter ?? Self.separator(in: text)
        guard [",", ";", "\t"].contains(separator) else { throw ReadError.malformed }

        enum State { case unquoted, quoted, closed }
        var state = State.unquoted
        var records: [[String]] = [], record: [String] = [], field = ""
        var started = false
        func endField() throws {
            guard record.count < Self.maximumColumns else { throw ReadError.tooLarge }
            record.append(field)
            field = ""
            state = .unquoted
        }
        func endRecord() throws {
            try endField()
            guard records.count <= Self.maximumRows else { throw ReadError.tooLarge }
            records.append(record)
            record = []
            started = false
        }
        for char in text {
            started = true
            if state == .quoted {
                if char == "\"" { state = .closed } else { field.append(char) }
            } else if char == separator {
                try endField()
            } else if char == "\n" || char == "\r" || char == "\r\n" {
                try endRecord()
            } else if char == "\"" {
                if state == .closed { field.append(char) }
                else if !field.isEmpty { throw ReadError.malformed }
                state = .quoted
            } else {
                guard state != .closed else { throw ReadError.malformed }
                field.append(char)
            }
        }
        guard state != .quoted else { throw ReadError.malformed }
        if started { try endRecord() }
        guard let first = records.first, first.contains(where: { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            throw ReadError.emptyHeader
        }
        headers = first
        rows = Array(records.dropFirst())
    }

    private static func separator(in text: String) throws -> Character {
        var counts: [Character: Int] = [",": 0, ";": 0, "\t": 0]
        var quoted = false
        for char in text {
            if char == "\"" { quoted.toggle() }
            else if !quoted {
                if char == "\n" || char == "\r" || char == "\r\n" { break }
                if counts[char] != nil { counts[char, default: 0] += 1 }
            }
        }
        guard let maximum = counts.values.max(), maximum > 0 else { return "," }
        let candidates = counts.filter { $0.value == maximum }
        guard candidates.count == 1, let separator = candidates.first?.key else { throw ReadError.ambiguousSeparator }
        return separator
    }
}
