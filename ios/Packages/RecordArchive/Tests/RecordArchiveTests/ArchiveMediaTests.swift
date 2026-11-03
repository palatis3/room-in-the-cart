import XCTest
@testable import RecordArchive

final class ArchiveMediaTests: XCTestCase {
    private func record(media: [ArchiveMediaAttachment]? = nil, revision: String = "revision") -> ArchiveRecord {
        ArchiveRecord(id: "shop", origin: "owner", revision: revision, kind: .ledger, title: "Tuesday", savedAtMilliseconds: 100,
            nativePayload: Data(#"{"record":"private"}"#.utf8), media: media)
    }
    private func media(_ id: String = "photo", data: Data = Data(#"{"formatMajor":1,"source":"private evidence"}"#.utf8)) -> ArchiveMediaAttachment {
        .init(id: id, kind: .packageReference, data: data)
    }
    private func envelope(_ records: [ArchiveRecord], kind: ArchiveKind = .personalRecovery) throws -> ArchiveEnvelope {
        try ArchiveCodec.make(records: records, kind: kind, origin: "owner", revision: "export")
    }
    private func url() throws -> URL {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: folder) }
        return folder.appendingPathComponent("registry.json")
    }
    func testMediaManifestAndEncryptionRoundTripKeepsLegacyProjectionAndSchema() throws {
        let old = try envelope([record()])
        XCTAssertEqual(old.formatMinor, 0); XCTAssertNil(old.mediaManifest)
        let oldJSON = String(decoding: try ArchiveCodec.encode(old), as: UTF8.self)
        XCTAssertFalse(oldJSON.contains("mediaManifest")); XCTAssertFalse(oldJSON.contains("\"media\""))
        let attachment = media(), value = try envelope([record(media: [attachment])])
        XCTAssertEqual(value.formatMinor, 1)
        XCTAssertEqual(value.projectionID, old.projectionID)
        XCTAssertEqual(value.mediaManifest?.entries.first?.byteCount, attachment.data.count)
        XCTAssertEqual(value.mediaManifest?.entries.first?.digest, ArchiveCodec.digest(attachment.data))
        let key = EncryptedArchive.generateKey(), bytes = try EncryptedArchive.seal(value, key: key)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("private evidence"))
        XCTAssertEqual(try EncryptedArchive.open(bytes, key: key), value)
    }
    func testVersionOnePointOneMediaFixtureRemainsDecodable() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let fixture = try ArchiveCodec.decode(Data(contentsOf: directory.appendingPathComponent("archive-v1.1-media.json")))
        XCTAssertEqual(fixture.formatMinor, 1)
        XCTAssertEqual(fixture.mediaManifest?.entries.first?.kind, .packageReference)
        XCTAssertEqual(fixture.payload.records.first?.media?.count, 1)
        XCTAssertEqual(try ArchiveCodec.decode(ArchiveCodec.encode(fixture)), fixture)
    }
    func testMappedCaptureNamespaceUsesVersionTwelveAndPreservesLegacyBytesAndSubsetIdentity() throws {
        var source = record(media: [media()])
        source.origin = "legacy-owner-namespace"
        let legacy = try envelope([source])
        let attachment = try XCTUnwrap(source.media?.first)
        let declaration = ArchiveCaptureNamespace(archiveOrigin: source.origin, storeKind: .ledger, physicalWorkspaceID: UUID())
        source.media = [ArchiveMediaAttachment(id: attachment.id, kind: attachment.kind, data: attachment.data, captureNamespace: declaration)]
        let mapped = try envelope([source])
        XCTAssertEqual(legacy.formatMinor, 1); XCTAssertEqual(mapped.formatMinor, 2)
        XCTAssertEqual(mapped.mediaManifest?.entries.first?.captureNamespace, declaration)
        XCTAssertEqual(mapped.payload.records[0].media?[0].data, attachment.data)
        XCTAssertFalse(String(decoding: try ArchiveCodec.encode(legacy), as: UTF8.self).contains("captureNamespace"))
        let key = EncryptedArchive.generateKey()
        XCTAssertEqual(try EncryptedArchive.open(EncryptedArchive.seal(mapped, key: key), key: key), mapped)
        let before = try ArchiveCodec.receipt(legacy.payload.records[0], projection: legacy.projectionID, localCopyID: "same-copy")
        let after = try ArchiveCodec.receipt(mapped.payload.records[0], projection: mapped.projectionID, localCopyID: "same-copy")
        XCTAssertEqual(before.identity, after.identity, "Namespace content cannot silently alter the selected-media projection identity")
        XCTAssertNotEqual(before.digest, after.digest)
        let helper = try envelope([source], kind: .helperShop)
        XCTAssertEqual(helper.formatMinor, 0); XCTAssertNil(helper.payload.records[0].media)
    }
    func testMappedCaptureNamespaceRejectsWrongOwnerKindFutureVersionAndUnknownFields() throws {
        var source = record(media: [media()])
        let attachment = try XCTUnwrap(source.media?.first)
        source.media = [.init(id: attachment.id, kind: attachment.kind, data: attachment.data,
            captureNamespace: .init(archiveOrigin: source.origin, storeKind: .ledger, physicalWorkspaceID: UUID()))]
        let bytes = try ArchiveCodec.encode(envelope([source]))
        let original = try JSONSerialization.jsonObject(with: bytes) as! [String: Any]
        for (field, value) in [("archiveOrigin", "another-owner" as Any), ("storeKind", "pickup"), ("formatMajor", 99), ("credentials", "forbidden")] {
            var object = original, payload = original["payload"] as! [String: Any]
            var records = payload["records"] as! [[String: Any]], attachments = records[0]["media"] as! [[String: Any]]
            var namespace = attachments[0]["captureNamespace"] as! [String: Any]
            namespace[field] = value; attachments[0]["captureNamespace"] = namespace
            records[0]["media"] = attachments; payload["records"] = records; object["payload"] = payload
            XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: object)))
        }
    }
    func testExactSelectedSubsetRetryDedupsAfterRestartAndOtherSubsetIsSibling() async throws {
        let location = try url(), registry = try RecoveryRegistry(url: location)
        let value = try envelope([record(media: [media()])])
        let first = try await registry.apply(registry.review(value))
        let reopened = try RecoveryRegistry(url: location)
        let retry = try await reopened.apply(reopened.review(value))
        XCTAssertEqual(retry.records.map(\.id), first.records.map(\.id)); XCTAssertTrue(retry.insertedCopyIDs.isEmpty)
        let other = try envelope([record(media: [media("other-photo")])])
        let review = try await reopened.review(other)
        XCTAssertEqual(review.rows.first?.disposition, .sibling)
        _ = try await reopened.apply(review)
        let textOnly = try await reopened.review(envelope([record()]))
        XCTAssertEqual(textOnly.rows.first?.disposition, .sibling)
        _ = try await reopened.apply(textOnly)
        let records = try await reopened.refreshList(); XCTAssertEqual(records.count, 3)
    }
    func testChangedMediaUnderSameSubsetQuarantinesWholeBatch() async throws {
        let location = try url(), registry = try RecoveryRegistry(url: location)
        _ = try await registry.apply(registry.review(envelope([record(media: [media()])])))
        let before = try Data(contentsOf: location)
        let changed = record(media: [media(data: Data("changed".utf8))])
        var unrelated = record(); unrelated.id = "another-shop"
        let review = try await registry.review(envelope([changed, unrelated]))
        XCTAssertEqual(review.rows.first { $0.record.id == "shop" }?.disposition, .quarantined)
        do { _ = try await registry.apply(review); XCTFail("Conflict must be atomic") }
        catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
        XCTAssertEqual(try Data(contentsOf: location), before)
    }
    func testCorruptManifestSizeDigestOwnerAndMediaTypeAreRejectedBeforeMutation() async throws {
        let location = try url(), registry = try RecoveryRegistry(url: location)
        _ = try await registry.apply(registry.review(envelope([record(revision: "newer")])))
        let before = try Data(contentsOf: location)
        let encoded = try ArchiveCodec.encode(envelope([record(media: [media()])]))
        let original = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for (field, value) in [("byteCount", -1 as Any), ("digest", String(repeating: "0", count: 64)), ("recordID", "other-shop"), ("contentType", "text/html")] {
            var object = original
            var manifest = object["mediaManifest"] as! [String: Any]
            var entries = manifest["entries"] as! [[String: Any]]
            entries[0][field] = value; manifest["entries"] = entries; object["mediaManifest"] = manifest
            XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: object)))
        }
        var missing = original; missing.removeValue(forKey: "mediaManifest")
        XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: missing)))
        XCTAssertEqual(try Data(contentsOf: location), before)
    }
    func testMediaBoundsDuplicateIDsAndFutureManifestVersionFail() throws {
        XCTAssertThrowsError(try envelope([record(media: [media(data: Data(count: ArchiveCodec.maximumMediaBytes + 1))])])) { XCTAssertEqual($0 as? ArchiveError, .tooLarge) }
        XCTAssertThrowsError(try envelope([record(media: (0...ArchiveCodec.maximumMediaAttachments).map { media("photo-\($0)") })])) { XCTAssertEqual($0 as? ArchiveError, .tooLarge) }
        XCTAssertThrowsError(try envelope([record(media: [media(), media()])])) { XCTAssertEqual($0 as? ArchiveError, .invalidIdentity) }
        var object = try JSONSerialization.jsonObject(with: ArchiveCodec.encode(envelope([record(media: [media()])]))) as! [String: Any]
        var manifest = object["mediaManifest"] as! [String: Any]; manifest["formatMajor"] = 99; object["mediaManifest"] = manifest
        XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: object))) { XCTAssertEqual($0 as? ArchiveError, .unsupportedVersion) }
    }
    func testHelperExcludesEveryAttachmentAndManifestEvenWhenOwnerMediaIsOversized() throws {
        let value = try envelope([record(media: [media(data: Data(count: ArchiveCodec.maximumMediaBytes + 1))])], kind: .helperShop)
        XCTAssertEqual(value.formatMinor, 0); XCTAssertNil(value.mediaManifest); XCTAssertNil(value.payload.records[0].media)
        let text = String(decoding: try ArchiveCodec.encode(value), as: UTF8.self)
        XCTAssertFalse(text.contains("media")); XCTAssertFalse(text.contains("nativePayload"))
    }
    func testCancelledReviewUndoAndErasureKeepMediaTransactional() async throws {
        let location = try url(), registry = try RecoveryRegistry(url: location)
        let selected = try envelope([record(media: [media()])])
        _ = try await registry.review(selected)
        XCTAssertFalse(FileManager.default.fileExists(atPath: location.path))
        let committed = try await registry.apply(registry.review(selected))
        try await registry.undoImport(insertedCopyIDs: committed.insertedCopyIDs)
        let afterUndo = try await registry.refreshList(); XCTAssertTrue(afterUndo.isEmpty)
        _ = try await registry.apply(registry.review(selected))
        try await registry.registerErasedOrigins(["owner"])
        let bytes = String(decoding: try Data(contentsOf: location), as: UTF8.self)
        XCTAssertFalse(bytes.contains("private evidence")); XCTAssertFalse(bytes.contains("mediaManifest"))
        let reopened = try RecoveryRegistry(url: location), review = try await reopened.review(selected)
        XCTAssertEqual(review.rows.first?.disposition, .erased)
    }
    func testRemovingSourceMediaScrubsEarlierCopiesAndUndoWithoutLosingRecordOrCopyID() async throws {
        let location = try url(), registry = try RecoveryRegistry(url: location)
        let original = record(media: [media(), media("second")])
        var unrelated = record(media: [media("other-shop-photo")]); unrelated.id = "other-shop"
        let commit = try await registry.apply(registry.review(envelope([original, unrelated])))
        let originalCopy = try XCTUnwrap(commit.records.first { $0.record.id == "shop" })
        let token = try await registry.delete(.copy(commit.records.first { $0.record.id == "other-shop" }!.id))
        try await registry.registerErasedMedia([
            ArchiveMediaSourceIdentity(origin: "owner", mediaID: "photo"),
            ArchiveMediaSourceIdentity(origin: "owner", mediaID: "other-shop-photo")
        ])
        let loaded = await registry.load(id: originalCopy.id)
        let sanitized = try XCTUnwrap(loaded)
        XCTAssertEqual(sanitized.id, originalCopy.id)
        XCTAssertEqual(sanitized.record.nativePayload, original.nativePayload)
        XCTAssertEqual(sanitized.record.media?.map(\.id), ["second"])
        XCTAssertEqual(sanitized.record.parentRevision, original.revision)
        XCTAssertNotEqual(sanitized.record.revision, original.revision)
        try await registry.undoDelete(token)
        let afterUndo = await registry.list()
        let restored = try XCTUnwrap(afterUndo.first { $0.record.id == "other-shop" })
        XCTAssertNil(restored.record.media)
        let reopened = try RecoveryRegistry(url: location)
        let saved = try await reopened.refreshList(); XCTAssertEqual(saved.count, 2)
        let rejected = try await reopened.review(envelope([original]))
        XCTAssertEqual(rejected.rows.first?.disposition, .erased)
        let clean = try envelope([sanitized.record])
        let review = try await reopened.review(clean)
        XCTAssertEqual(review.rows.first?.disposition, .identical)
        let retried = try await reopened.apply(review); XCTAssertTrue(retried.insertedCopyIDs.isEmpty)
    }
}
