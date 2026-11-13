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

    func testSelectedMediaUsesSameOwnerBackingForBackupDatesAndKeepsRecoveryProjectionDistinct() async throws {
        let registry = try RecoveryRegistry(url: location())
        let plain = record(), copyID = try await restore(plain, registry: registry)
        var withMedia = plain
        withMedia.media = [.init(id: "pack-photo", kind: .packageReference, data: Data("saved label".utf8))]
        let baseID = identity(plain), selectedID = identity(withMedia)
        XCTAssertNotEqual(baseID, selectedID)
        let file = try ArchiveCodec.make(records: [withMedia], kind: .personalRecovery, origin: "owner", revision: "file")
        let key = EncryptedArchive.generateKey()
        let opened = try EncryptedArchive.open(EncryptedArchive.seal(file, key: key), key: key)
        XCTAssertEqual(opened.payload.records[0].media, withMedia.media)
        let scope = [baseID: Set([copyID])]
        let intent = try await registry.prepareEncryptedBackup(opened.payload.records, recoveredCopyIDs: scope)
        try await registry.recordSuccessfulBackup(intent, savedAtMilliseconds: 30)
        let local = try await registry.lastEncryptedBackups(for: [withMedia])
        XCTAssertTrue(local.isEmpty, "The independent source must not inherit a recovered copy's successful export.")
        let recovered = try await registry.lastEncryptedBackups(for: [withMedia], recoveredCopyIDs: scope)
        XCTAssertEqual(recovered, [baseID: .init(savedAtMilliseconds: 30, revisions: [plain.revision])])
        let withoutMedia = try await registry.lastEncryptedBackups(for: [plain], recoveredCopyIDs: scope)
        XCTAssertEqual(withoutMedia, recovered)
        try await registry.registerErasedMedia([.init(origin: plain.origin, mediaID: "pack-photo")])
        try await registry.recordSuccessfulBackup(intent, savedAtMilliseconds: 40)
        let delayed = try await registry.lastEncryptedBackups(for: [plain], recoveredCopyIDs: scope)
        XCTAssertEqual(delayed[baseID]?.savedAtMilliseconds, 30)
        _ = try await registry.delete(.copy(copyID))
        let erased = try await registry.lastEncryptedBackups(for: [withMedia], recoveredCopyIDs: scope)
        XCTAssertTrue(erased.isEmpty)
    }

    func testDistinctMediaSelectionsInOneFileRecordOneDateAndCheckEachSelectionsErasure() async throws {
        let url = try location(), registry = try RecoveryRegistry(url: url)
        let plain = record(), id = try await restore(plain, registry: registry)
        var first = plain, second = plain
        first.media = [.init(id: "one", kind: .packageReference, data: Data("one".utf8))]
        second.media = [.init(id: "two", kind: .packageReference, data: Data("two".utf8))]
        let file = try ArchiveCodec.make(records: [first, second], kind: .personalRecovery, origin: "owner", revision: "file")
        let key = EncryptedArchive.generateKey()
        let rows = try EncryptedArchive.open(EncryptedArchive.seal(file, key: key), key: key).payload.records
        let scope = [identity(plain): Set([id])]
        do { _ = try await registry.prepareEncryptedBackup([first, first], recoveredCopyIDs: scope); XCTFail("An exact duplicate is invalid") }
        catch { XCTAssertEqual(error as? ArchiveError, .invalidIdentity) }
        let intent = try await registry.prepareEncryptedBackup(rows, recoveredCopyIDs: scope)
        try await registry.recordSuccessfulBackup(intent, savedAtMilliseconds: 10)
        let reopened = try RecoveryRegistry(url: url)
        let saved = try await reopened.lastEncryptedBackups(for: rows, recoveredCopyIDs: scope)
        XCTAssertEqual(saved, [identity(plain): .init(savedAtMilliseconds: 10, revisions: [plain.revision])])
        try await registry.registerErasedMedia([.init(origin: plain.origin, mediaID: "one")])
        try await reopened.recordSuccessfulBackup(intent, savedAtMilliseconds: 20)
        let surviving = try await registry.lastEncryptedBackups(for: rows, recoveredCopyIDs: scope)
        XCTAssertEqual(surviving[identity(plain)]?.savedAtMilliseconds, 20)
        try await registry.registerErasedMedia([.init(origin: plain.origin, mediaID: "two")])
        try await reopened.recordSuccessfulBackup(intent, savedAtMilliseconds: 30)
        let blocked = try await registry.lastEncryptedBackups(for: rows, recoveredCopyIDs: scope)
        XCTAssertEqual(blocked, surviving)
    }

    func testUnversionedBackupDatesRetainProvenSourcesAndSuppressAmbiguousMediaProvenanceAfterRecovery() async throws {
        func writeLegacyMarkFormat(_ url: URL) throws {
            var file = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any])
            var marks = try XCTUnwrap(file["encryptedBackups"] as? [[String: Any]])
            for index in marks.indices { marks[index].removeValue(forKey: "usesBaseOwnerIdentity") }
            file["encryptedBackups"] = marks
            try JSONSerialization.data(withJSONObject: file).write(to: url, options: .atomic)
        }
        let url = try location(), original = try RecoveryRegistry(url: url)
        let shop = record(UUID().uuidString)
        try await original.recordSuccessfulBackup(original.prepareEncryptedBackup([shop]), savedAtMilliseconds: 10)
        try writeLegacyMarkFormat(url)
        let migrated = try RecoveryRegistry(url: url)
        let knownIndependent = try await migrated.lastEncryptedBackups(for: [shop])
        XCTAssertEqual(knownIndependent[identity(shop)]?.savedAtMilliseconds, 10)
        let id = try await restore(shop, registry: migrated)
        let afterImport = try await migrated.lastEncryptedBackups(for: [shop])
        XCTAssertEqual(afterImport, knownIndependent)

        let edited = record(shop.id, "copy edit"), library = record("meal-library")
        var recipe = record("recipe-digest")
        recipe.kind = .recipe
        let scope = [identity(edited): Set([id])]
        let intent = try await migrated.prepareEncryptedBackup([shop, edited, library, recipe], recoveredCopyIDs: scope)
        try await migrated.recordSuccessfulBackup(intent, savedAtMilliseconds: 20)
        try writeLegacyMarkFormat(url)
        let restarted = try RecoveryRegistry(url: url)
        let independent = try await restarted.lastEncryptedBackups(for: [shop, library, recipe])
        XCTAssertEqual(independent, [identity(recipe): .init(savedAtMilliseconds: 20, revisions: [recipe.revision])])
        let recovered = try await restarted.lastEncryptedBackups(for: [edited], recoveredCopyIDs: scope)
        XCTAssertEqual(recovered, [identity(edited): .init(savedAtMilliseconds: 20, revisions: [edited.revision])])
        try await restarted.recordSuccessfulBackup(restarted.prepareEncryptedBackup([library]), savedAtMilliseconds: 30)
        let newSave = try await migrated.lastEncryptedBackups(for: [shop, library, recipe])
        XCTAssertNil(newSave[identity(shop)])
        XCTAssertEqual(newSave[identity(library)]?.savedAtMilliseconds, 30)
        XCTAssertEqual(newSave[identity(recipe)]?.savedAtMilliseconds, 20)
    }

    func testOriginalDevelopmentDuplicateMediaReceiptOpensOnlyWithCorroboratingCopies() async throws {
        // Produced by the 17af86ec writer from the package's archive-v1.1-media fixture.
        let fixture = try XCTUnwrap(Bundle.module.url(forResource: "registry-development-selected-media", withExtension: "json", subdirectory: "Fixtures"))
        let original = try Data(contentsOf: fixture), url = try location()
        try original.write(to: url)
        let registry = try RecoveryRegistry(url: url)
        let copies = await registry.list()
        let plain = try XCTUnwrap(copies.first { $0.record.media == nil }?.record)
        let selected = try XCTUnwrap(copies.first { $0.record.media != nil }?.record)
        let scope = [identity(plain): Set(copies.map(\.id))]
        let localDate = try await registry.lastEncryptedBackups(for: [plain])
        XCTAssertTrue(localDate.isEmpty)
        let proven = try await registry.lastEncryptedBackups(for: [selected], recoveredCopyIDs: scope)
        XCTAssertEqual(proven, [identity(plain): .init(savedAtMilliseconds: 200_000, revisions: [plain.revision])])
        XCTAssertEqual(try Data(contentsOf: url), original)
        let intent = try await registry.prepareEncryptedBackup([selected], recoveredCopyIDs: scope)
        try await registry.recordSuccessfulBackup(intent, savedAtMilliseconds: 300_000)
        let reopened = try RecoveryRegistry(url: url)
        let newDate = try await reopened.lastEncryptedBackups(for: [plain], recoveredCopyIDs: scope)
        XCTAssertEqual(newDate[identity(plain)]?.savedAtMilliseconds, 300_000)

        let manifest = try XCTUnwrap(JSONSerialization.jsonObject(with: original) as? [String: Any])
        let marks = try XCTUnwrap(manifest["encryptedBackups"] as? [[String: Any]])
        let originalMark = try XCTUnwrap(marks.first)
        let revisions = try XCTUnwrap(originalMark["revisions"] as? [[String: Any]])
        let scoped = try XCTUnwrap(revisions.first { !(($0["dependentCopyIDs"] as? [String]) ?? []).isEmpty })
        let empty = try XCTUnwrap(revisions.first { ($0["dependentCopyIDs"] as? [String])?.isEmpty == true })
        let unsupportedMarks: [[String: Any]] = [
            originalMark.merging(["usesBaseOwnerIdentity": true]) { _, new in new },
            originalMark.merging(["revisions": [empty, empty]]) { _, new in new },
            originalMark.merging(["revisions": [scoped, scoped]]) { _, new in new },
            originalMark.merging(["revisions": [scoped, empty, empty]]) { _, new in new }
        ]
        for unsupportedMark in unsupportedMarks {
            let invalid = manifest.merging(["encryptedBackups": [unsupportedMark]]) { _, new in new }
            let bytes = try JSONSerialization.data(withJSONObject: invalid)
            try bytes.write(to: url, options: .atomic)
            XCTAssertThrowsError(try RecoveryRegistry(url: url)) { XCTAssertEqual($0 as? ArchiveError, .integrity) }
            XCTAssertEqual(try Data(contentsOf: url), bytes)
        }
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
