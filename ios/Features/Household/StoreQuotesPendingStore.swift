import Foundation
import HouseholdClient

/// Only exact retry bytes live on disk. The service rechecks all access before revealing them.
actor StoreQuotesPendingStore {
    private let url: URL
    private var generation = UUID()
    init(url: URL) { self.url = url }
    func epoch() -> UUID { generation }
    func read() throws -> [StoreQuoteIntent] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([StoreQuoteIntent].self, from: Data(contentsOf: url))
        guard values.count <= 100 else { throw ClientError.invalidResponse }
        for value in values { try value.validate() }; return values
    }
    func save(_ intent: StoreQuoteIntent, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        try intent.validate(); var values = try read()
        if let previous = values.first(where: { $0.context == intent.context && $0.shopID == intent.shopID }) {
            guard previous == intent else { throw ClientError.configuration }; return
        }
        guard values.count < 100 else { throw ClientError.configuration }
        values.append(intent); try write(values)
    }
    func complete(_ intent: StoreQuoteIntent, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var values = try read(); values.removeAll { $0 == intent }; try write(values)
    }
    func purge() throws { generation = UUID(); try write([]) }
    func purge(householdID: String, subject: String) throws {
        generation = UUID(); try write(try read().filter { $0.context.householdID != householdID || $0.context.subject != subject })
    }
    private func write(_ values: [StoreQuoteIntent]) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONEncoder().encode(values)
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: [.atomic])
        #endif
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        var protected = url; var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
        try protected.setResourceValues(attributes)
    }
}
