import XCTest
@testable import RecordArchive

final class PantryRecoveryRegistryTests: XCTestCase {
    private func fixture() throws -> (URL, RecoveryRegistry) {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("registry.json")
        return (url, try RecoveryRegistry(url: url))
    }
    private func reference(origin: UUID = UUID(), bundle: UUID = UUID(), byte: UInt8 = 7) -> PantryRecoveryReference {
        .init(bundleID: bundle, manifestDigest: Data(repeating: byte, count: 32), originID: origin, inventoryRevision: 3)
    }
    private func insert(_ reference: PantryRecoveryReference, into registry: RecoveryRegistry) async throws -> RecoveredPantryCopy {
        let review = try await registry.reviewPantry(reference)
        return try await registry.applyPantry(review)
    }
    func testCleanupRetainsBothCopyKindsAndRefreshesAcrossRegistryInstances() async throws {
        let (url, registry) = try fixture(), other = try RecoveryRegistry(url: url)
        let pantry = try await insert(reference(), into: registry)
        let record = ArchiveRecord(id: "shop", origin: "owner", revision: "one", kind: .ledger,
            title: "Tuesday", savedAtMilliseconds: 100, nativePayload: Data("{}".utf8))
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "owner", revision: "one")
        let imported = try await other.apply(other.review(envelope))
        let ordinary = try XCTUnwrap(imported.records.first)
        let retained = try await registry.retainedRecoveryCopyIDs()
        XCTAssertEqual(retained, [pantry.id.uuidString, ordinary.id])
        _ = try await other.delete(.copy(pantry.id.uuidString))
        let remaining = try await registry.retainedRecoveryCopyIDs()
        XCTAssertEqual(remaining, [ordinary.id])
        _ = try await registry.delete(.copy(ordinary.id))
        let empty = try await other.retainedRecoveryCopyIDs()
        XCTAssertTrue(empty.isEmpty)
    }
    func testLegacyManifestAndExternalReferencesReopenWithoutGraphBytes() async throws {
        let (url, _) = try fixture()
        let legacy = "{\"formatMajor\":1,\"generation\":\"00000000-0000-0000-0000-000000000000\",\"records\":[],\"erasedIdentities\":[]}"
        try Data(legacy.utf8).write(to: url)
        let registry = try RecoveryRegistry(url: url), ref = reference()
        let empty = try await registry.listPantry(); XCTAssertTrue(empty.isEmpty)
        let saved = try await insert(ref, into: registry)
        let reopened = try RecoveryRegistry(url: url)
        let actual = try await reopened.listPantry()
        XCTAssertEqual(actual, [saved]); XCTAssertEqual(actual.first?.reference, ref)
        let ordinary = try await reopened.refreshList(); XCTAssertTrue(ordinary.isEmpty)
    }
    func testExactImportRetryWinsButUnrelatedStaleReviewCannotCreateCopy() async throws {
        let (_, registry) = try fixture(), first = reference(), second = reference(), third = reference()
        let a = try await registry.reviewPantry(first), stale = try await registry.reviewPantry(third)
        let saved = try await registry.applyPantry(a)
        _ = try await insert(second, into: registry)
        let retry = try await registry.applyPantry(a); XCTAssertEqual(retry, saved)
        do { _ = try await registry.applyPantry(stale); XCTFail("Stale insertion") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let conflict = try await registry.reviewPantry(reference(origin: first.originID, bundle: first.bundleID, byte: 8))
        XCTAssertEqual(conflict.disposition, .quarantined)
        do { _ = try await registry.applyPantry(conflict); XCTFail("Changed same bundle") }
        catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
    }
    func testFirstMaterializationPermissionIsNeverReissuedAfterRestart() async throws {
        let (url, registry) = try fixture(), copy = try await insert(reference(), into: registry)
        let first = try await registry.beginPantryMaterialization(copy)
        XCTAssertTrue(first.permitsCreation)
        let reopened = try RecoveryRegistry(url: url)
        let retry = try await reopened.beginPantryMaterialization(copy)
        XCTAssertFalse(retry.permitsCreation); XCTAssertEqual(retry.copy, first.copy)
        let origin = UUID(), ready = try await reopened.finishPantryMaterialization(first.copy, workspaceID: origin)
        XCTAssertEqual(ready.materialization, .ready(workspaceID: origin))
        let repeated = try await reopened.finishPantryMaterialization(first.copy, workspaceID: origin)
        XCTAssertEqual(repeated, ready)
        do { _ = try await reopened.finishPantryMaterialization(first.copy, workspaceID: UUID()); XCTFail("Retargeted database") }
        catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
    }
    func testDeletionRechecksMaterializationAndRetiresOnlyThatPackage() async throws {
        let (url, registry) = try fixture(), ref = reference(), copy = try await insert(ref, into: registry)
        let oldReview = try await registry.reviewPantryDeletion(copyIDs: [copy.id])
        _ = try await registry.beginPantryMaterialization(copy)
        do { try await registry.deletePantry(oldReview); XCTFail("Changed selection") }
        catch { XCTAssertEqual(error as? ArchiveError, .deletionSelectionChanged) }
        let current = try await registry.reviewPantryDeletion(copyIDs: [copy.id])
        try await registry.deletePantry(current)
        let reopened = try RecoveryRegistry(url: url)
        let retired = try await reopened.permanentlyRetiredPantryBundleIDs()
        XCTAssertEqual(retired, [ref.bundleID])
        let erased = try await reopened.reviewPantry(ref); XCTAssertEqual(erased.disposition, .erased)
        let later = try await reopened.reviewPantry(reference(origin: ref.originID)); XCTAssertTrue(later.canApply)
        do { _ = try await reopened.currentPantryCopy(copy); XCTFail("Deleted lease") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
    }
    func testLocalBundleAndWholeOriginErasurePurgeReferencesAndBlockOldImports() async throws {
        let (_, registry) = try fixture(), origin = UUID()
        let a = reference(origin: origin), b = reference(origin: origin), c = reference()
        _ = try await insert(a, into: registry); _ = try await insert(b, into: registry)
        let surviving = try await insert(c, into: registry)
        try await registry.registerErasedPantryBundles([a.bundleID])
        let erased = try await registry.reviewPantry(a); XCTAssertFalse(erased.canApply)
        try await registry.registerErasedOrigins([origin.uuidString])
        let current = try await registry.listPantry(); XCTAssertEqual(current, [surviving])
        let blocked = try await registry.reviewPantry(reference(origin: origin)); XCTAssertEqual(blocked.disposition, .erased)
    }
    func testAllRecoveredDeletionIncludesPantryAndUndoRetiresOldLease() async throws {
        let (_, registry) = try fixture(), copy = try await insert(reference(), into: registry)
        let ordinaryOnlyReview = RecoveryDeletionReview(scope: .allRecovered, displayedCopies: [])
        do { _ = try await registry.delete(ordinaryOnlyReview); XCTFail("Undisplayed pantry cannot be deleted") }
        catch { XCTAssertEqual(error as? ArchiveError, .deletionSelectionChanged) }
        let completeReview = RecoveryDeletionReview(scope: .allRecovered, displayedCopies: [], displayedPantryCopies: [copy])
        XCTAssertEqual(completeReview.count, 1); XCTAssertEqual(completeReview.copyIDs, [copy.id.uuidString])
        let token = try await registry.delete(completeReview)
        let heldForUndo = try await registry.permanentlyRetiredPantryBundleIDs()
        XCTAssertTrue(heldForUndo.isEmpty)
        let empty = try await registry.listPantry(); XCTAssertTrue(empty.isEmpty)
        try await registry.undoDelete(token)
        let reopenedCopies = try await registry.listPantry()
        let restored = try XCTUnwrap(reopenedCopies.first)
        XCTAssertEqual(restored.id, copy.id); XCTAssertEqual(restored.reference, copy.reference)
        XCTAssertNotEqual(restored.lifetime, copy.lifetime)
        do { _ = try await registry.currentPantryCopy(copy); XCTFail("Old lifetime") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let erased = try await registry.delete(.copy(restored.id.uuidString))
        try await registry.registerErasedPantryBundles([copy.reference.bundleID])
        do { try await registry.undoDelete(erased); XCTFail("Local erasure overrides deletion undo") }
        catch { XCTAssertEqual(error as? ArchiveError, .unavailable) }
    }
    func testUndoImportRemovesPantryWithoutBlockingAReviewedReimport() async throws {
        let (_, registry) = try fixture(), ref = reference(), copy = try await insert(ref, into: registry)
        try await registry.undoImport(insertedCopyIDs: [copy.id.uuidString])
        let after = try await registry.listPantry(); XCTAssertTrue(after.isEmpty)
        let review = try await registry.reviewPantry(ref); XCTAssertEqual(review.disposition, .absent)
        let fresh = try await registry.applyPantry(review); XCTAssertNotEqual(fresh.id, copy.id)
    }

    func testErasureFromAnotherRegistryInstanceOverridesRetainedDeletionUndo() async throws {
        let (url, registry) = try fixture(), ref = reference(), copy = try await insert(ref, into: registry)
        let token = try await registry.delete(.copy(copy.id.uuidString))
        let erasingRegistry = try RecoveryRegistry(url: url)
        try await erasingRegistry.registerErasedPantryBundles([ref.bundleID])
        do { try await registry.undoDelete(token); XCTFail("A stale editor cannot undo authoritative erasure") }
        catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
        let remaining = try await registry.listPantry(); XCTAssertTrue(remaining.isEmpty)
        let review = try await erasingRegistry.reviewPantry(ref); XCTAssertEqual(review.disposition, .erased)
    }

    func testReceiptExpiresAnotherInstancesOrdinaryUndoWithoutDisablingUnrelatedCopies() async throws {
        let (url, first) = try fixture(), second = try RecoveryRegistry(url: url)
        func record(_ id: String, kind: ArchiveRecordKind) -> ArchiveRecord {
            .init(id: id, origin: "foreign-owner", revision: "one", kind: kind,
                title: id, savedAtMilliseconds: 100, nativePayload: Data("{}".utf8))
        }
        let hidden = record("hidden-pickup", kind: .pickup), independent = record("retained", kind: .comparison)
        let envelope = try ArchiveCodec.make(records: [hidden, independent], kind: .personalRecovery, origin: "foreign-owner", revision: "one")
        let saved = try await first.apply(first.review(envelope))
        let removed = try XCTUnwrap(saved.records.first { $0.record == hidden })
        let retained = try XCTUnwrap(saved.records.first { $0.record == independent })
        let token = try await first.delete(.copy(removed.id))
        let reviewed = try await second.pantryErasureBasis(), operation = UUID()
        try await second.beginPantryErasure(operationID: operation, expectedGeneration: reviewed.generation) {}
        do { try await first.undoDelete(token); XCTFail("Undo crossed the SQLite commit reservation") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let restarted = try RecoveryRegistry(url: url)
        try await restarted.cancelPantryErasure(operationID: UUID())
        do { try await first.undoDelete(token); XCTFail("Another operation released the reservation") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        try await restarted.cancelPantryErasure(operationID: operation)
        try await first.undoDelete(token)
        let restored = try await first.refreshList()
        XCTAssertEqual(Set(restored.map(\.id)), [removed.id, retained.id])

        let erased = try await first.delete(.copy(removed.id))
        let next = try await second.pantryErasureBasis()
        try await second.beginPantryErasure(operationID: operation, expectedGeneration: next.generation) {}
        try await second.registerErasedPantryBundles([], operationID: operation)
        do { try await first.undoDelete(erased); XCTFail("Restored private native bytes after source erasure") }
        catch { XCTAssertEqual(error as? ArchiveError, .unavailable) }
        let surviving = try await first.refreshList()
        XCTAssertEqual(surviving, [retained])
        let check = try await first.review(envelope)
        XCTAssertEqual(check.rows.first { $0.record.id == hidden.id }?.disposition, .erased)
        XCTAssertEqual(check.rows.first { $0.record.id == independent.id }?.disposition, .identical)
        let laterOperation = UUID()
        let laterBasis = try await second.pantryErasureBasis()
        try await second.beginPantryErasure(operationID: laterOperation, expectedGeneration: laterBasis.generation) {}
        try await second.registerErasedPantryBundles([], operationID: laterOperation)
        let freshToken = try await first.delete(.copy(retained.id))
        try await restarted.registerErasedPantryBundles([], operationID: operation)
        try await first.undoDelete(freshToken)
        let afterRetry = try await restarted.refreshList()
        XCTAssertEqual(afterRetry.map(\.id), [retained.id])
    }

    func testInvalidReferenceNeverCreatesManifest() async throws {
        let (url, registry) = try fixture()
        let invalid = PantryRecoveryReference(bundleID: UUID(), manifestDigest: Data([0]), originID: UUID(), inventoryRevision: -1)
        do { _ = try await registry.reviewPantry(invalid); XCTFail("Invalid metadata") }
        catch { XCTAssertEqual(error as? ArchiveError, .integrity) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path))
    }

    func testPantryBackupStatusRequiresSuccessfulSaveAndTracksExactExportedRevision() async throws {
        let (url, registry) = try fixture(), ref = reference()
        let intent = try await registry.preparePantryBackup(ref)
        let before = try await registry.lastPantryBackup(originID: ref.originID)
        XCTAssertNil(before, "Preparing or cancelling Files does not create a backup receipt")
        try await registry.recordSuccessfulPantryBackup(intent, savedAtMilliseconds: 100)
        try await registry.recordSuccessfulPantryBackup(intent, savedAtMilliseconds: 100)
        let reopened = try RecoveryRegistry(url: url)
        let status = try await reopened.lastPantryBackup(originID: ref.originID)
        XCTAssertEqual(status?.reference, ref); XCTAssertEqual(status?.savedAtMilliseconds, 100)
        try await reopened.registerErasedPantryBundles([ref.bundleID])
        let erased = try await registry.lastPantryBackup(originID: ref.originID); XCTAssertNil(erased)
        do { try await registry.recordSuccessfulPantryBackup(intent, savedAtMilliseconds: 200); XCTFail("Retired callback") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let clean = reference(origin: ref.originID)
        let cleanIntent = try await registry.preparePantryBackup(clean)
        try await registry.recordSuccessfulPantryBackup(cleanIntent, savedAtMilliseconds: 300)
        let latest = try await registry.lastPantryBackup(originID: ref.originID)
        XCTAssertEqual(latest?.reference, clean, "One erased package does not retire a stable live origin")
    }

    func testRecoveredPantryBackupCallbackCannotOutliveDeletedCopyOrUndoLifetime() async throws {
        let (_, registry) = try fixture(), original = reference()
        let copy = try await insert(original, into: registry)
        let started = try await registry.beginPantryMaterialization(copy), physicalOrigin = UUID()
        let ready = try await registry.finishPantryMaterialization(started.copy, workspaceID: physicalOrigin)
        let exported = reference(origin: physicalOrigin), intent = try await registry.preparePantryBackup(exported, recoveredCopy: ready)
        try await registry.recordSuccessfulPantryBackup(intent, savedAtMilliseconds: 100)
        let hiddenFromLive = try await registry.lastPantryBackup(originID: physicalOrigin); XCTAssertNil(hiddenFromLive)
        let token = try await registry.delete(.copy(copy.id.uuidString))
        try await registry.undoDelete(token)
        do { try await registry.recordSuccessfulPantryBackup(intent, savedAtMilliseconds: 200); XCTFail("Deleted copy callback") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let copies = try await registry.listPantry(), restored = try XCTUnwrap(copies.first)
        let cleared = try await registry.lastPantryBackup(originID: physicalOrigin, recoveredCopy: restored); XCTAssertNil(cleared)
        let fresh = try await registry.preparePantryBackup(exported, recoveredCopy: restored)
        try await registry.recordSuccessfulPantryBackup(fresh, savedAtMilliseconds: 300)
        let saved = try await registry.lastPantryBackup(originID: physicalOrigin, recoveredCopy: restored)
        XCTAssertEqual(saved?.savedAtMilliseconds, 300)
    }
}
