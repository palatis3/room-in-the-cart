import XCTest
import CoreDomain
import LocalStore
import RecordArchive
import UIKit
@testable import RoomInTheCart

@MainActor final class RecordsRecoveryCaptureTests: XCTestCase {
    private struct LedgerDocument: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
    private func root() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func original() throws -> ArchiveRecord {
        var shop = ShoppingLedger(title: "Recovered Tuesday")
        let staged = try shop.stageImport(text: "2 rice", source: .typed)
        _ = try shop.commitImport(staged, decisions: [staged.lines[0].id: .addNew], at: Date(timeIntervalSince1970: 100))
        let payload = try RecordsNativeCodec.canonical(LedgerDocument(workspace: .init(shops: [shop], selectedShopID: shop.id)))
        return ArchiveRecord(id: shop.id.uuidString, origin: "legacy-local-ledger", revision: ArchiveCodec.digest(payload), kind: .ledger,
            title: shop.title, savedAtMilliseconds: 100_000, nativePayload: payload)
    }
    private func commit(_ record: ArchiveRecord, registry: RecoveryRegistry) async throws -> RecoveredRecord {
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "portable-file", revision: record.revision)
        let result = try await registry.apply(registry.review(envelope))
        return try XCTUnwrap(result.records.first)
    }
    private func jpeg() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 48, height: 32)).image { context in
            UIColor.systemGreen.setFill(); context.fill(CGRect(x: 0, y: 0, width: 48, height: 32))
        }
        return try ScanImageNormalizer.normalize(XCTUnwrap(image.jpegData(compressionQuality: 0.8)))
    }
    private func source(workspaceID: UUID, record: ArchiveRecord, kind: CaptureTarget.Kind = .packageReference) throws -> SourceMediaRecord {
        let shop = try XCTUnwrap(RecordsNativeCodec.ledger(XCTUnwrap(record.nativePayload)).shops.first)
        return SourceMediaRecord(id: UUID(), target: .init(workspaceID: workspaceID, containerID: shop.id,
            objectID: shop.lines[0].id, revision: Int64(shop.revision), kind: kind), originalText: "New recovered package photo wording",
            reviewedLabel: "New recovered rice reference", imageJPEG: try jpeg(), barcode: nil, receiptLines: [], capturedAt: Date(timeIntervalSince1970: 200))
    }
    private func assertFails(_ body: () async throws -> Void, file: StaticString = #filePath, line: UInt = #line) async {
        do { try await body(); XCTFail("Expected rejection", file: file, line: line) } catch {}
    }
    func testActualRecoveredLedgerNewPhotoReexportSiblingAndCleanupPreservePhysicalIdentity() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        var original = try original()
        let originalPhysicalID = UUID(), historical = try source(workspaceID: originalPhysicalID, record: original)
        let historicalAttachment = try RecordsMediaCodec.attachment(historical)
        original.media = [.init(id: historicalAttachment.id, kind: historicalAttachment.kind, data: historicalAttachment.data,
            captureNamespace: .init(archiveOrigin: original.origin, storeKind: .ledger, physicalWorkspaceID: originalPhysicalID))]
        let saved = try await commit(original, registry: registry), folder = root.appendingPathComponent(saved.id)
        let lifetime = RecordsRecoveryLifetime(), lease = try await lifetime.begin(copy: saved, registry: registry, authorize: { true })
        let opened = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: lease.authorize)
        let initial = try await opened.store.save(payload: XCTUnwrap(original.nativePayload), expectedRevision: 0, operationID: UUID(), savedAt: Date(timeIntervalSince1970: 100))
        let media = CaptureMediaStore(directory: root.appendingPathComponent("media")), corrections = CaptureCorrectionStore(directory: root.appendingPathComponent("corrections"))
        _ = try await media.save(historical, authorize: { true })
        let captured = try source(workspaceID: opened.scope.workspaceID, record: original)
        _ = try await media.save(captured, authorize: lease.authorize)
        let scope = CaptureCorrectionScope(profileID: "local:" + opened.scope.workspaceID.uuidString, localeIdentifier: "es-US")
        try await corrections.setEnabled(true, scope: scope)
        try await corrections.remember(original: "aroz", replacement: "arroz", scope: scope)
        var workspace = try RecordsNativeCodec.ledger(initial.payload)
        workspace.shops[0].title = "Edited recovered Tuesday"
        let current = try await opened.store.save(payload: RecordsNativeCodec.canonical(LedgerDocument(workspace: workspace)), expectedRevision: initial.revision,
            operationID: UUID(), savedAt: Date(timeIntervalSince1970: 200))
        let listed = try await media.archiveListing(workspaceID: opened.scope.workspaceID, authorize: lease.authorize)
        let projected = try RecordsNativeCodec.recoveredLedger(saved, current: current, scope: opened.scope, sources: opened.scope.filtering(listed).records)
        let record = try XCTUnwrap(projected.first), attachment = try XCTUnwrap(record.media?.first { $0.id == captured.id.uuidString })
        XCTAssertEqual(record.media?.count, 2)
        XCTAssertEqual(record.origin, original.origin); XCTAssertEqual(record.parentRevision, original.revision)
        XCTAssertEqual(try RecordsMediaCodec.decode(attachment), captured)
        XCTAssertEqual(attachment.captureNamespace?.physicalWorkspaceID, captured.target.workspaceID)
        XCTAssertEqual(attachment.captureNamespace?.archiveOrigin, original.origin)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        let exporter = RecordsToolsModel(registry: registry, snapshot: { projected }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await exporter.refresh(); exporter.selectAll(); exporter.generateRecoveryKey()
        await exporter.prepareExport(.encryptedRecovery)
        XCTAssertNil(try EncryptedArchive.open(XCTUnwrap(exporter.preparedDocument).data, key: exporter.recoveryKey).mediaManifest)
        exporter.selectedMediaIDs.insert(RecordsToolsModel.mediaSelectionID(attachment, record: record))
        await exporter.prepareExport(.encryptedRecovery)
        let envelope = try EncryptedArchive.open(XCTUnwrap(exporter.preparedDocument).data, key: exporter.recoveryKey)
        XCTAssertEqual(envelope.formatMinor, 2)
        XCTAssertEqual(try RecordsMediaCodec.decode(XCTUnwrap(envelope.payload.records[0].media?.first)).target.workspaceID, captured.target.workspaceID)
        let siblingRegistry = try RecoveryRegistry(url: root.appendingPathComponent("sibling.json"))
        var newer = original; newer.revision = "newer-current"; newer.title = "Newer untouched work"
        let newerCopy = try await commit(newer, registry: siblingRegistry)
        let review = try await siblingRegistry.review(envelope)
        XCTAssertEqual(review.rows[0].disposition, .sibling)
        let siblingCommit = try await siblingRegistry.apply(review)
        let recovered = try XCTUnwrap(siblingCommit.records.first)
        let siblingFolder = root.appendingPathComponent(recovered.id)
        let sibling = try await RecordsRecoveryCapture.openLedger(copy: recovered, directory: siblingFolder, authorize: { true })
        _ = try await sibling.store.save(payload: XCTUnwrap(recovered.record.nativePayload), expectedRevision: 0, operationID: UUID(), savedAt: Date())
        XCTAssertNotEqual(sibling.scope.workspaceID, captured.target.workspaceID)
        // Portable mappings do not authorize listing or erasing the named physical source.
        let siblingListing = try await media.archiveListing(workspaceID: sibling.scope.workspaceID, authorize: { true })
        XCTAssertTrue(siblingListing.records.isEmpty)
        try await sibling.store.close()
        _ = try await siblingRegistry.delete(.copy(recovered.id))
        try await RecordsRecoveryCapture.erase(directory: siblingFolder, protectedWorkspaceIDs: [], media: media, corrections: corrections)
        let awaitedValue1 = try await media.read(captured.reference, target: captured.target, authorize: { true })
        XCTAssertEqual(awaitedValue1, captured)
        let awaitedValue2 = try await siblingRegistry.refreshList().first?.id
        XCTAssertEqual(awaitedValue2, newerCopy.id)
        let unrelatedID = UUID(), unrelated = try source(workspaceID: unrelatedID, record: original)
        _ = try await media.save(unrelated, authorize: { true })
        lifetime.invalidate()
        _ = try await registry.delete(.copy(saved.id))
        try await opened.store.close(); lifetime.finish(lease); await lifetime.drain()
        try await RecordsRecoveryCapture.erase(directory: folder, protectedWorkspaceIDs: [unrelatedID], media: media, corrections: corrections)
        try FileManager.default.removeItem(at: folder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let awaitedValue3 = try await media.isRetired(captured)
        XCTAssertTrue(awaitedValue3)
        let awaitedValue4 = try await corrections.load(scope).entries.isEmpty
        XCTAssertTrue(awaitedValue4)
        await assertFails { _ = try await media.save(captured, authorize: { true }) }
        await assertFails { try await corrections.setEnabled(true, scope: scope) }
        await assertFails { _ = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: lease.authorize) }
        await assertFails { _ = try await lifetime.begin(copy: saved, registry: registry, authorize: { true }) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let awaitedValue5 = try await media.read(unrelated.reference, target: unrelated.target, authorize: { true })
        XCTAssertEqual(awaitedValue5, unrelated)
        let awaitedValue6 = try await registry.refreshList().count
        XCTAssertEqual(awaitedValue6, 0)
        let retainedHistorical = try await media.read(historical.reference, target: historical.target, authorize: { true })
        XCTAssertEqual(retainedHistorical, historical, "Deleting a recovered physical store never erases its imported source namespace")
    }
    func testRecoveredPickupReceiptAndRecipeSourceUseActualStoreAndRetainNativeBinding() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        var journey = PickupJourney(id: UUID(), savedAt: Date(timeIntervalSince1970: 100))
        journey.basket = try BasketPlan(id: journey.id, revisionID: UUID(), lines: [BasketLine(id: UUID(), name: "Rice",
            quantity: Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2 packs"), expectedCost: .unknown(reason: "Not quoted"))], createdAt: journey.savedAt)
        let bytes = try RecordsNativeCodec.canonical(journey)
        let original = ArchiveRecord(id: journey.id.uuidString, origin: "legacy-pickup", revision: ArchiveCodec.digest(bytes), kind: .pickup, title: "Pickup", savedAtMilliseconds: 100_000, nativePayload: bytes)
        let saved = try await commit(original, registry: registry)
        let opened = try await RecordsRecoveryCapture.openPickup(copy: saved, directory: root.appendingPathComponent(saved.id), authorize: { true })
        try await opened.store.save(id: journey.id, title: "Pickup", payload: bytes, savedAt: journey.savedAt)
        let receipt = SourceMediaRecord(id: UUID(), target: .init(workspaceID: opened.scope.workspaceID, containerID: journey.id, objectID: journey.id,
            revision: journey.revision, kind: .receiptEvidence), originalText: "Receipt words", reviewedLabel: "Receipt", imageJPEG: try jpeg(), barcode: nil,
            receiptLines: [.init(originalText: "Rice unknown price")], capturedAt: Date())
        let media = CaptureMediaStore(directory: root.appendingPathComponent("media")); _ = try await media.save(receipt, authorize: { true })
        let record = try RecordsMediaCodec.attaching([receipt], to: original, liveScope: opened.scope)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        XCTAssertEqual(try RecordsMediaCodec.decode(XCTUnwrap(record.media?.first)).target.workspaceID, opened.store.workspaceID)
        var foreign = record; foreign.id = UUID().uuidString
        XCTAssertThrowsError(try RecordsNativeCodec.validate(foreign))
        try await opened.store.close()
        let ledger = try await commit(try self.original(), registry: registry)
        let recoveredLedger = try await RecordsRecoveryCapture.openLedger(copy: ledger, directory: root.appendingPathComponent(ledger.id), authorize: { true })
        let captureID = UUID(), templateID = UUID(), physicalID = recoveredLedger.scope.workspaceID
        let evidence = try RecipeSourceEvidence(captureID: captureID, originalText: "Recipe wording", kind: .photoOCR, localMedia: .init(workspaceID: physicalID, mediaID: captureID))
        let template = MealTemplate(id: templateID, title: "Rice", ingredients: [], sourceEvidence: evidence)
        let recipe = SourceMediaRecord(id: captureID, target: .init(workspaceID: physicalID, containerID: physicalID, objectID: templateID, revision: 0, kind: .recipeSource),
            originalText: evidence.originalText, reviewedLabel: "Recipe", imageJPEG: try jpeg(), barcode: nil, receiptLines: [], capturedAt: Date())
        let current = try await recoveredLedger.store.save(payload: RecordsNativeCodec.canonical(LedgerDocument(workspace: .init(mealTemplates: [template]))), expectedRevision: 0, operationID: UUID(), savedAt: Date())
        let projected = try RecordsNativeCodec.recoveredLedger(ledger, current: current, scope: recoveredLedger.scope, sources: [recipe])
        XCTAssertEqual(projected.count, 1); XCTAssertEqual(projected[0].id, "meal-library")
        XCTAssertNoThrow(try RecordsNativeCodec.validate(projected[0]))
        XCTAssertEqual(projected[0].media?.first?.captureNamespace?.physicalWorkspaceID, physicalID)
        let removed = try await recoveredLedger.store.save(payload: RecordsNativeCodec.canonical(LedgerDocument(workspace: .init(mealTemplates: [MealTemplate(id: templateID, title: "Rice", ingredients: [])]))), expectedRevision: current.revision, operationID: UUID(), savedAt: Date())
        XCTAssertNil(try RecordsNativeCodec.recoveredLedger(ledger, current: removed, scope: recoveredLedger.scope, sources: [recipe])[0].media)
        try await recoveredLedger.store.close()
    }
    func testWrongPhysicalMappingRejectedAndImportedUnrelatedMappingNeverMintsLiveScope() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json")), original = try original()
        let foreignID = UUID(), captured = try source(workspaceID: foreignID, record: original), media = CaptureMediaStore(directory: root.appendingPathComponent("media"))
        _ = try await media.save(captured, authorize: { true })
        let attachment = try RecordsMediaCodec.attachment(captured)
        var mapped = original
        mapped.media = [.init(id: attachment.id, kind: attachment.kind, data: attachment.data, captureNamespace: .init(archiveOrigin: original.origin, storeKind: .ledger, physicalWorkspaceID: foreignID))]
        XCTAssertNoThrow(try RecordsNativeCodec.validate(mapped))
        var invalid = mapped; invalid.media = [.init(id: attachment.id, kind: attachment.kind, data: attachment.data,
            captureNamespace: .init(archiveOrigin: original.origin, storeKind: .ledger, physicalWorkspaceID: UUID()))]
        XCTAssertThrowsError(try RecordsNativeCodec.validate(invalid))
        let saved = try await commit(mapped, registry: registry), folder = root.appendingPathComponent(saved.id)
        let opened = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: { true })
        XCTAssertNotEqual(opened.scope.workspaceID, foreignID)
        XCTAssertTrue(opened.scope.filtering(.init(records: [captured])).records.isEmpty)
        try await opened.store.close()
        try await RecordsRecoveryCapture.erase(directory: folder, protectedWorkspaceIDs: [], media: media, corrections: CaptureCorrectionStore(directory: root.appendingPathComponent("corrections")))
        let awaitedValue7 = try await media.read(captured.reference, target: captured.target, authorize: { true })
        XCTAssertEqual(awaitedValue7, captured)
    }
    func testJournalIsBoundToActualDatabaseAndCopyAndUnknownFieldsFailClosed() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json")), original = try original()
        let saved = try await commit(original, registry: registry), folder = root.appendingPathComponent(saved.id)
        let opened = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: { true }); try await opened.store.close()
        let journal = folder.appendingPathComponent("capture-scope-v1.json"), originalBytes = try Data(contentsOf: journal)
        let originalObject = try XCTUnwrap(JSONSerialization.jsonObject(with: originalBytes) as? [String: Any])
        let media = CaptureMediaStore(directory: root.appendingPathComponent("media")), corrections = CaptureCorrectionStore(directory: root.appendingPathComponent("corrections"))
        for (key, value) in [("physicalWorkspaceID", UUID().uuidString as Any), ("recoveryCopyID", UUID().uuidString), ("storeKind", "pickup"), ("formatMajor", 99), ("credentials", "forbidden")] {
            var object = originalObject, scope = object["scope"] as! [String: Any]
            scope[key] = value; object["scope"] = scope
            // Recompute the claimed digest: a self-consistent journal still cannot name a different actual store.
            let scopeBytes = try JSONSerialization.data(withJSONObject: scope, options: [.sortedKeys, .withoutEscapingSlashes])
            object["digest"] = ArchiveCodec.digest(scopeBytes)
            try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]).write(to: journal)
            await assertFails { try await RecordsRecoveryCapture.erase(directory: folder, protectedWorkspaceIDs: [], media: media, corrections: corrections) }
        }
        try Data("broken".utf8).write(to: journal)
        await assertFails { _ = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: { true }) }
        try originalBytes.write(to: journal)
        await assertFails { try await RecordsRecoveryCapture.erase(directory: folder, protectedWorkspaceIDs: [opened.scope.workspaceID], media: media, corrections: corrections) }
        let captured = try source(workspaceID: opened.scope.workspaceID, record: original); _ = try await media.save(captured, authorize: { true })
        let awaitedValue8 = try await media.read(captured.reference, target: captured.target, authorize: { true })
        XCTAssertEqual(awaitedValue8, captured)
        try FileManager.default.removeItem(at: journal)
        try await RecordsRecoveryCapture.erase(directory: folder, protectedWorkspaceIDs: [], media: media, corrections: corrections)
        XCTAssertEqual(try Data(contentsOf: journal), originalBytes, "Legacy cleanup derives the journal from actual SQLite identity")
        let awaitedValue9 = try await media.isRetired(captured)
        XCTAssertTrue(awaitedValue9)
    }
    func testSymlinksAndDeniedAuthorizationCannotCreateRecoveryStores() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json")), saved = try await commit(try original(), registry: registry)
        let folder = root.appendingPathComponent(saved.id), destination = root.appendingPathComponent("elsewhere")
        await assertFails { _ = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: { false }) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: folder, withDestinationURL: destination)
        await assertFails { _ = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: { true }) }
        try FileManager.default.removeItem(at: folder); try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let external = destination.appendingPathComponent("payload"); try Data("preserved".utf8).write(to: external)
        for name in ["ledger.sqlite", "ledger.sqlite-wal", "capture-scope-v1.json"] {
            let link = folder.appendingPathComponent(name); try FileManager.default.createSymbolicLink(at: link, withDestinationURL: external)
            await assertFails { _ = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: { true }) }
            try FileManager.default.removeItem(at: link)
        }
        XCTAssertEqual(try Data(contentsOf: external), Data("preserved".utf8))
    }
    func testDeletionCancelsInFlightLeaseAndDrainPreventsLateFolderRecreation() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json")), saved = try await commit(try original(), registry: registry)
        let lifetime = RecordsRecoveryLifetime(), lease = try await lifetime.begin(copy: saved, registry: registry, authorize: { true }), folder = root.appendingPathComponent(saved.id)
        let opened = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: lease.authorize)
        let tools = RecordsToolsModel(registry: registry, snapshot: { [] }, validateNativePayload: { _ in }, openRecovered: { _ in }, cleanupRecoveredWorkspaces: {
            XCTAssertFalse(lease.authorize())
            try await opened.store.close(); lifetime.finish(lease); await lifetime.drain()
            try FileManager.default.removeItem(at: folder)
        }, willRemoveRecovered: { lifetime.invalidate() })
        await tools.deleteRecovered(.copy(saved.id))
        XCTAssertNil(tools.error); XCTAssertFalse(lease.authorize())
        await assertFails { try await lifetime.revalidate(lease, copy: saved, registry: registry) }
        await assertFails { _ = try await lifetime.begin(copy: saved, registry: registry, authorize: { true }) }
        await assertFails { _ = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: lease.authorize) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
    }
    func testMediaScrubRetainsCopyDirectoryAndReopensUsingFreshReceipt() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        var original = try original(); let physicalID = UUID(), captured = try source(workspaceID: physicalID, record: original)
        let attachment = try RecordsMediaCodec.attachment(captured)
        original.media = [.init(id: attachment.id, kind: attachment.kind, data: attachment.data,
            captureNamespace: .init(archiveOrigin: original.origin, storeKind: .ledger, physicalWorkspaceID: physicalID))]
        let saved = try await commit(original, registry: registry), folder = root.appendingPathComponent(saved.id), lifetime = RecordsRecoveryLifetime()
        let opened = try await RecordsRecoveryCapture.openLedger(copy: saved, directory: folder, authorize: { true }); try await opened.store.close()
        try await registry.registerErasedMedia([.init(origin: original.origin, mediaID: captured.id.uuidString)])
        let refreshed = try await registry.refreshList()
        let sanitized = try XCTUnwrap(refreshed.first)
        XCTAssertEqual(sanitized.id, saved.id); XCTAssertNil(sanitized.record.media)
        await assertFails { _ = try await lifetime.begin(copy: saved, registry: registry, authorize: { true }) }
        let lease = try await lifetime.begin(copy: sanitized, registry: registry, authorize: { true })
        let reopened = try await RecordsRecoveryCapture.openLedger(copy: sanitized, directory: folder, authorize: lease.authorize)
        XCTAssertEqual(reopened.scope.workspaceID, opened.scope.workspaceID)
        try await reopened.store.close(); lifetime.finish(lease)
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))
    }
    func testDrainWaitsForCancelledInFlightUser() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json")), saved = try await commit(try original(), registry: registry)
        let lifetime = RecordsRecoveryLifetime(), lease = try await lifetime.begin(copy: saved, registry: registry, authorize: { true })
        let waiting = expectation(description: "Cleanup started waiting"), finished = expectation(description: "Cleanup drained")
        var didDrain = false
        lifetime.invalidate()
        let draining = Task { @MainActor in
            waiting.fulfill(); await lifetime.drain(); didDrain = true; finished.fulfill()
        }
        await fulfillment(of: [waiting], timeout: 2)
        XCTAssertFalse(didDrain); XCTAssertFalse(lease.authorize())
        lifetime.finish(lease)
        await fulfillment(of: [finished], timeout: 2)
        await draining.value
        XCTAssertTrue(didDrain)
    }
    func testCancelledOpenCannotReplaceCompletedDeletionOutcomeAndDeniedDeletionCannotMutateRegistry() async throws {
        let root = try root(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json")), saved = try await commit(try original(), registry: registry)
        let started = expectation(description: "Open awaits store"), deletion = expectation(description: "Deletion completed")
        var resume: CheckedContinuation<Void, Never>?
        let tools = RecordsToolsModel(registry: registry, snapshot: { [] }, validateNativePayload: { _ in }, openRecovered: { _ in
            await withCheckedContinuation { resume = $0; started.fulfill() }
            throw ArchiveError.unavailable
        }, cleanupRecoveredWorkspaces: {})
        let opening = Task { await tools.openRecovered(saved) }
        await fulfillment(of: [started], timeout: 2)
        await tools.deleteRecovered(.copy(saved.id)); deletion.fulfill()
        let outcome = tools.actionOutcomeID
        XCTAssertNotNil(outcome); XCTAssertNil(tools.error)
        resume?.resume(); await opening.value
        XCTAssertEqual(tools.actionOutcomeID, outcome); XCTAssertNil(tools.error)
        let second = try await commit(try original(), registry: registry)
        let denied = RecordsToolsModel(registry: registry, snapshot: { [] }, validateNativePayload: { _ in }, openRecovered: { _ in }, beginAuthorization: { nil })
        await denied.deleteRecovered(.copy(second.id))
        XCTAssertEqual(denied.error, .unavailable)
        let retained = try await registry.refreshList()
        XCTAssertEqual(retained.map(\.id), [second.id])
        await fulfillment(of: [deletion], timeout: 2)
    }
}
