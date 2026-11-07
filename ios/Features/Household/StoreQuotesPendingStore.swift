import Foundation
import HouseholdClient

protocol PendingShopWrite: Codable, Equatable, Sendable {
    func validate() throws
    func sharesScope(with other: Self) -> Bool
    func belongs(to householdID: String, subject: String) -> Bool
}

extension StoreQuoteIntent: PendingShopWrite {
    func sharesScope(with other: Self) -> Bool { context == other.context && shopID == other.shopID }
    func belongs(to householdID: String, subject: String) -> Bool {
        context.householdID == householdID && context.subject == subject
    }
}

extension PendingFallbackWrite: PendingShopWrite {
    func sharesScope(with other: Self) -> Bool {
        householdID == other.householdID && memberID == other.memberID && deviceID == other.deviceID &&
        subject == other.subject && shopId == other.shopId
    }
    func belongs(to householdID: String, subject: String) -> Bool {
        self.householdID == householdID && self.subject == subject
    }
}

typealias StoreQuotesPendingStore = PendingShopWriteStore<StoreQuoteIntent>
typealias FallbackPendingStore = PendingShopWriteStore<PendingFallbackWrite>

/// Only exact retry bytes live on disk. The service rechecks all access before revealing them.
actor PendingShopWriteStore<Write: PendingShopWrite> {
    private let url: URL
    private var generation = UUID()
    init(url: URL) { self.url = url }
    func epoch() -> UUID { generation }
    func read() throws -> [Write] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        let values = try JSONDecoder().decode([Write].self, from: Data(contentsOf: url))
        guard values.count <= 100 else { throw ClientError.invalidResponse }
        for value in values { try value.validate() }; return values
    }
    func save(_ intent: Write, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        try intent.validate(); var values = try read()
        if let previous = values.first(where: { $0.sharesScope(with: intent) }) {
            guard previous == intent else { throw ClientError.configuration }; return
        }
        guard values.count < 100 else { throw ClientError.configuration }
        values.append(intent); try write(values)
    }
    func complete(_ intent: Write, expectedEpoch: UUID) throws {
        guard generation == expectedEpoch else { throw ClientError.cancelled }
        var values = try read(); values.removeAll { $0 == intent }; try write(values)
    }
    func purge() throws { generation = UUID(); try write([]) }
    func purge(householdID: String, subject: String) throws {
        generation = UUID(); try write(try read().filter { !$0.belongs(to: householdID, subject: subject) })
    }
    private func write(_ values: [Write]) throws {
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
