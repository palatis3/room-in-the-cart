import XCTest
@testable import RecordArchive

final class EncryptedBackupTests: XCTestCase {
    private let owner = ArchiveCodec.projection(for: .personalRecovery)
    private func record(_ id: String = "shop", _ revision: String = "first", origin: String = "local") -> ArchiveRecord {
        ArchiveRecord(id: id, origin: origin, revision: revision, kind: .ledger, title: "Private grocery",
                      savedAtMilliseconds: 1, nativePayload: Data("Private payload".utf8))
    }
    private func source(_ record: ArchiveRecord) -> ArchiveSourceIdentity { .init(origin: record.origin, recordID: record.id) }
    private func identity(_ record: ArchiveRecord) -> ArchiveIdentity { ArchiveCodec.identity(record, projection: owner) }
    private func location() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("records")
    }
    private func restore(_ record: ArchiveRecord, registry: RecoveryRegistry, kind: ArchiveKind = .personalRecovery) async throws -> String {
        let file = try ArchiveCodec.make(records: [record], kind: kind, origin: "hand-carried", revision: "export")
        let result = try await registry.apply(registry.review(file))
        return try XCTUnwrap(result.records.first?.id)
    }

    func testLegacyManifestRecordsOnlyFilesSuccessAndScopesStatusToVisibleOwnerRevisions() async throws {
        let url = try location()
        let legacy = Data(#"{"formatMajor":1,"generation":"00000000-0000-0000-0000-000000000001","records":[],"erasedIdentities":[]}"#.utf8)
        try legacy.write(to: url)
        let a = try RecoveryRegistry(url: url), b = try RecoveryRegistry(url: url)
        let old = record(), newer = record("shop", "second"), other = record("shop", origin: "another owner")
        var helper = old; helper.nativePayload = nil
        let intent = try await a.prepareEncryptedBackup([old, newer, other])
        XCTAssertEqual(try Data(contentsOf: url), legacy)
        let before = try await b.lastEncryptedBackups(for: [old, other]); XCTAssertTrue(before.isEmpty)
        let review = try await b.review(ArchiveCodec.make(records: [old], kind: .personalRecovery, origin: "copy", revision: "export"))
        try await b.recordSuccessfulBackup(intent, savedAtMilliseconds: 10)
        let bytes = try Data(contentsOf: url)
        let disk = String(decoding: bytes, as: UTF8.self)
        for privateValue in ["Private grocery", "Private payload", old.nativePayload!.base64EncodedString(), url.path] {
            XCTAssertFalse(disk.contains(privateValue))
        }
        let selected = try await a.refreshList(includingBackupsFor: [newer, helper])
        XCTAssertTrue(selected.recovered.isEmpty)
        XCTAssertEqual(selected.backups, [identity(newer): .init(savedAtMilliseconds: 10, revisions: ["second"])])
        let both = try await a.lastEncryptedBackups(for: [old, newer])
        XCTAssertEqual(both[identity(old)]?.revisions, ["first"])
        XCTAssertEqual(both[identity(newer)]?.revisions, ["second"])
        let helperIntent = try await a.prepareEncryptedBackup([helper])
        try await a.recordSuccessfulBackup(helperIntent, savedAtMilliseconds: 20)
        let redacted = try await b.lastEncryptedBackups(for: [helper]); XCTAssertTrue(redacted.isEmpty)
        try await a.recordSuccessfulBackup(intent, savedAtMilliseconds: 10)
        XCTAssertEqual(try Data(contentsOf: url), bytes)
        // Recording a backup date cannot invalidate a reviewed recovery import.
        _ = try await b.apply(review)
        let nextSave = try await b.prepareEncryptedBackup([old])
        try await b.recordSuccessfulBackup(nextSave, savedAtMilliseconds: 30)
        try await a.recordSuccessfulBackup(intent, savedAtMilliseconds: 10)
        let restarted = try RecoveryRegistry(url: url)
        let after = try await restarted.lastEncryptedBackups(for: [newer, other])
        XCTAssertEqual(after[identity(newer)], .init(savedAtMilliseconds: 30, revisions: []))
        XCTAssertEqual(after[identity(other)], .init(savedAtMilliseconds: 10, revisions: [other.revision]))
    }

    func testDeletingOneRecoveredBranchPurgesOnlyItsDependentRevisionsAndRejectsLateSuccessAfterUndo() async throws {
        let url = try location(), registry = try RecoveryRegistry(url: url), writer = try RecoveryRegistry(url: url)
        let first = try await restore(record("original", "v1"), registry: registry)
        let second = try await restore(record("original", "v2"), registry: registry)
        let left = record("edited-child", "one"), shared = record("edited-child", "both"), live = record("independent")
        let dependencies: [ArchiveIdentity: Set<String>] = [
            ArchiveCodec.identity(left, projection: owner): [first],
            ArchiveCodec.identity(shared, projection: owner): [first, second]
        ]
        let intent = try await registry.prepareEncryptedBackup([left, shared, live], recoveredCopyIDs: dependencies)
        try await writer.recordSuccessfulBackup(intent, savedAtMilliseconds: 10)
        let token = try await registry.delete(.copy(first))
        let remaining = try await writer.lastEncryptedBackups(for: [left, shared, live], recoveredCopyIDs: dependencies)
        XCTAssertNil(remaining[identity(left)])
        XCTAssertEqual(remaining[identity(shared)]?.revisions, [shared.revision])
        XCTAssertEqual(remaining[identity(live)]?.revisions, [live.revision])
        try await registry.undoDelete(token)
        try await writer.recordSuccessfulBackup(intent, savedAtMilliseconds: 20)
        let replay = try await writer.lastEncryptedBackups(for: [left, shared], recoveredCopyIDs: dependencies)
        XCTAssertNil(replay[identity(left)])
        XCTAssertEqual(replay[identity(shared)], .init(savedAtMilliseconds: 20, revisions: [shared.revision]))
        let fresh = try await registry.prepareEncryptedBackup([left], recoveredCopyIDs: [ArchiveCodec.identity(left, projection: owner): [first]])
        try await registry.recordSuccessfulBackup(fresh, savedAtMilliseconds: 30)
        try await writer.undoImport(insertedCopyIDs: [first])
        try await registry.recordSuccessfulBackup(fresh, savedAtMilliseconds: 40)
        let undone = try await writer.lastEncryptedBackups(for: [left, live], recoveredCopyIDs: dependencies)
        XCTAssertNil(undone[identity(left)])
        XCTAssertEqual(undone[identity(live)]?.savedAtMilliseconds, 20)
    }

    func testRetirementPurgesEditedChildrenAndOriginAndCannotResurrectThroughAnotherRegistry() async throws {
        let url = try location(), writer = try RecoveryRegistry(url: url), eraser = try RecoveryRegistry(url: url)
        let parent = record("original"), copyID = try await restore(parent, registry: writer)
        let child = record("new-shop"), sameOrigin = record("another"), other = record("unrelated", origin: "separate")
        let intent = try await writer.prepareEncryptedBackup([parent, child, sameOrigin, other],
            recoveredCopyIDs: [ArchiveCodec.identity(child, projection: owner): [copyID]])
        try await writer.recordSuccessfulBackup(intent, savedAtMilliseconds: 100)
        try await eraser.registerErasedSources([source(parent)])
        try await writer.recordSuccessfulBackup(intent, savedAtMilliseconds: 200)
        let partial = try await writer.lastEncryptedBackups(for: [parent, child, sameOrigin, other])
        XCTAssertEqual(Set(partial.keys), [identity(sameOrigin), identity(other)])
        do { _ = try await writer.prepareEncryptedBackup([parent]); XCTFail("A retired source cannot start another receipt") }
        catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
        try await eraser.registerErasedOrigins([sameOrigin.origin])
        try await writer.recordSuccessfulBackup(intent, savedAtMilliseconds: 300)
        let restarted = try RecoveryRegistry(url: url)
        let final = try await restarted.lastEncryptedBackups(for: [parent, child, sameOrigin, other])
        XCTAssertEqual(final, [identity(other): .init(savedAtMilliseconds: 300, revisions: [other.revision])])
    }

    func testRevokedLiveSourceAndOtherRecoveredCopyDatesStayPrivateEvenWhenRevisionsCollide() async throws {
        let registry = try RecoveryRegistry(url: location())
        let old = record(), edited = record("shop", "edited")
        let copyA = try await restore(old, registry: registry)
        let copyB = try await restore(record("shop", "another-import"), registry: registry)
        let visibleCopies = [identity(old): Set([copyA]), identity(edited): Set([copyB])]
        try await registry.recordSuccessfulBackup(registry.prepareEncryptedBackup([old]), savedAtMilliseconds: 10)
        let revoked = try await registry.refreshList(includingBackupsFor: [old, edited], recoveredCopyIDs: visibleCopies)
        XCTAssertTrue(revoked.backups.isEmpty)
        let first = try await registry.prepareEncryptedBackup([old], recoveredCopyIDs: [identity(old): [copyA]])
        try await registry.recordSuccessfulBackup(first, savedAtMilliseconds: 20)
        let separate = try await registry.lastEncryptedBackups(for: [old, edited], recoveredCopyIDs: visibleCopies)
        XCTAssertEqual(separate, [identity(old): .init(savedAtMilliseconds: 20, revisions: [old.revision])])
        let sameBacking = try await registry.lastEncryptedBackups(for: [edited], recoveredCopyIDs: [identity(edited): [copyA]])
        XCTAssertEqual(sameBacking[identity(edited)], .init(savedAtMilliseconds: 20, revisions: []))
        let sameRevisionOtherCopy = try await registry.lastEncryptedBackups(for: [old], recoveredCopyIDs: [identity(old): [copyB]])
        XCTAssertTrue(sameRevisionOtherCopy.isEmpty)
        let liveOnly = try await registry.lastEncryptedBackups(for: [old, edited])
        XCTAssertTrue(liveOnly.isEmpty)
    }

    func testHelperCannotSupplyOwnerProvenanceAndOtherRegistryCannotAcceptIntent() async throws {
        let first = try RecoveryRegistry(url: location()), second = try RecoveryRegistry(url: location())
        let privateRecord = record(), id = try await restore(privateRecord, registry: first, kind: .helperShop)
        let identity = ArchiveCodec.identity(privateRecord, projection: owner)
        do { _ = try await first.prepareEncryptedBackup([privateRecord], recoveredCopyIDs: [identity: [id]]); XCTFail("Helper cannot supply owner receipt") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let intent = try await first.prepareEncryptedBackup([privateRecord])
        do { try await second.recordSuccessfulBackup(intent, savedAtMilliseconds: 1); XCTFail("Wrong registry") }
        catch { XCTAssertEqual(error as? ArchiveError, .invalidIdentity) }
        let after = try await second.lastEncryptedBackups(for: [privateRecord]); XCTAssertTrue(after.isEmpty)
    }
}
