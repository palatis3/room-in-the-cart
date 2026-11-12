import XCTest
import CoreDomain
import LocalStore
import RecordArchive
import UIKit
@testable import RoomInTheCart

@MainActor final class RecordsMediaTests: XCTestCase {
    private struct LedgerDocument: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
    private func location() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func package() throws -> (ArchiveRecord, SourceMediaRecord) {
        let workspaceID = UUID()
        var shop = ShoppingLedger(title: "Tuesday")
        let preview = try shop.stageImport(text: "2 rice", source: .typed)
        _ = try shop.commitImport(preview, decisions: [preview.lines[0].id: .addNew], at: Date(timeIntervalSince1970: 100))
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        let bytes = try RecordsNativeCodec.canonical(LedgerDocument(workspace: workspace))
        let source = SourceMediaRecord(id: UUID(), target: .init(workspaceID: workspaceID, containerID: shop.id,
            objectID: shop.lines[0].id, revision: Int64(shop.revision), kind: .packageReference),
            originalText: "Private package wording", reviewedLabel: "Rice reference", imageJPEG: nil,
            barcode: CapturedBarcode(symbology: "manual", value: "12345"), receiptLines: [], capturedAt: Date(timeIntervalSince1970: 100))
        let record = ArchiveRecord(id: shop.id.uuidString, origin: "ledger/" + workspaceID.uuidString,
            revision: ArchiveCodec.digest(bytes), kind: .ledger, title: shop.title, savedAtMilliseconds: 100_000,
            helperLines: [HelperLine(label: "Rice")], nativePayload: bytes, media: [try RecordsMediaCodec.attachment(source)])
        return (record, source)
    }
    private func model(_ record: ArchiveRecord, registry: RecoveryRegistry) -> RecordsToolsModel {
        RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
    }
    func testBackupRequiresEverySelectedRevisionAndTheReviewedAttachment() async throws {
        let (first, _) = try package()
        let (second, _) = try package()
        let root = try location()
        let registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        var records = [first, second]
        let tools = RecordsToolsModel(registry: registry, snapshot: { .init(records: records) },
            validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await tools.refresh()
        tools.selectAll()
        tools.generateRecoveryKey()

        // The other document can still be read, but that alone is not the requested backup.
        records[1].revision = "edited"
        await tools.prepareExport(.encryptedRecovery)
        XCTAssertEqual(tools.error, .exportSelectionChanged)
        XCTAssertNil(tools.preparedDocument)
        XCTAssertNil(tools.beginFileSave())
        XCTAssertEqual(tools.selectedIDs, [RecordsToolsModel.selectionID(first)])

        let attachment = try XCTUnwrap(first.media?.first)
        let mediaID = RecordsToolsModel.mediaSelectionID(attachment, record: first)
        tools.selectAll()
        tools.selectedMediaIDs.insert(mediaID)
        // A replacement with the same capture ID must receive its own disclosure.
        records[0].media = [ArchiveMediaAttachment(id: attachment.id, kind: attachment.kind, data: Data([0]))]
        await tools.prepareExport(.encryptedRecovery)
        XCTAssertEqual(tools.error, .exportSelectionChanged)
        XCTAssertNil(tools.preparedDocument)
        XCTAssertFalse(tools.selectedMediaIDs.contains(mediaID))

        records[0].media = first.media
        await tools.refresh()
        tools.selectedMediaIDs.insert(mediaID)
        records[0].media = nil
        await tools.prepareExport(.encryptedRecovery)
        XCTAssertEqual(tools.error, .exportSelectionChanged)
        XCTAssertNil(tools.preparedDocument)
        XCTAssertFalse(tools.selectedMediaIDs.contains(mediaID))
        // After reviewing the updated choices, both healthy records can be backed up.
        await tools.prepareExport(.encryptedRecovery)
        let data = try XCTUnwrap(tools.preparedDocument).data
        let result = try EncryptedArchive.open(data, key: tools.recoveryKey)
        XCTAssertEqual(Set(result.payload.records.map(\.revision)), Set(records.map(\.revision)))
        XCTAssertNil(result.mediaManifest)
    }

    func testSelectionDefaultsOffHelperExcludesEvidenceAndSelectedEncryptedRecoveryWorksBesideNewer() async throws {
        let (record, source) = try package(), root = try location()
        let sourceRegistry = try RecoveryRegistry(url: root.appendingPathComponent("source.json"))
        let exporter = model(record, registry: sourceRegistry)
        await exporter.refresh(); exporter.selectAll(); exporter.generateRecoveryKey()
        await exporter.prepareExport(.encryptedRecovery)
        let unselected = try EncryptedArchive.open(XCTUnwrap(exporter.preparedDocument).data, key: exporter.recoveryKey)
        XCTAssertNil(unselected.payload.records[0].media)
        let attachment = try XCTUnwrap(record.media?.first)
        exporter.selectedMediaIDs.insert(RecordsToolsModel.mediaSelectionID(attachment, record: record))
        XCTAssertEqual(exporter.selectedMediaCount, 1); XCTAssertEqual(exporter.selectedMediaBytes, attachment.data.count)
        await exporter.prepareExport(.helperJSON)
        let helper = try ArchiveCodec.decode(XCTUnwrap(exporter.preparedDocument).data)
        XCTAssertNil(helper.payload.records[0].media); XCTAssertNil(helper.mediaManifest)
        await exporter.prepareExport(.ownerText)
        XCTAssertFalse(String(decoding: try XCTUnwrap(exporter.preparedDocument).data, as: UTF8.self).contains(source.originalText))
        await exporter.prepareExport(.encryptedRecovery)
        let encrypted = try XCTUnwrap(exporter.preparedDocument).data
        let recoveredEnvelope = try EncryptedArchive.open(encrypted, key: exporter.recoveryKey)
        XCTAssertEqual(try RecordsMediaCodec.decode(XCTUnwrap(recoveredEnvelope.payload.records[0].media?.first)), source)
        let file = root.appendingPathComponent("selected.roomrecovery"); try encrypted.write(to: file)
        let destinationURL = root.appendingPathComponent("destination.json"), destination = try RecoveryRegistry(url: destinationURL)
        var newer = record; newer.revision = "newer-native-revision"; newer.media = nil
        let current = try await destination.apply(destination.review(ArchiveCodec.make(records: [newer], kind: .personalRecovery, origin: "current", revision: "newer")))
        let importer = model(newer, registry: destination); importer.recoveryKey = exporter.recoveryKey
        let before = try Data(contentsOf: destinationURL)
        await importer.importFile(file, recipes: false)
        XCTAssertEqual(importer.review?.rows.first?.disposition, .sibling)
        importer.cancelReview(); XCTAssertEqual(try Data(contentsOf: destinationURL), before)
        await importer.importFile(file, recipes: false); await importer.applyReviewedImport()
        XCTAssertNil(importer.error); XCTAssertEqual(importer.lastImportIDs.count, 1)
        let copies = try await destination.refreshList(); XCTAssertEqual(copies.count, 2)
        XCTAssertEqual(copies.first { $0.id == current.records[0].id }?.record, newer)
        await importer.importFile(file, recipes: false); await importer.applyReviewedImport()
        XCTAssertNil(importer.error); XCTAssertTrue(importer.lastImportIDs.isEmpty)
        let restarted = try RecoveryRegistry(url: destinationURL)
        let saved = try await restarted.refreshList().first { $0.record.media != nil }
        XCTAssertEqual(try RecordsMediaCodec.decode(XCTUnwrap(saved?.record.media?.first)), source)
    }
    func testReceiptAndRecipeEvidenceStayBoundToTheirOwnedRecord() throws {
        let workspaceID = UUID()
        var journey = PickupJourney(id: UUID(), savedAt: Date(timeIntervalSince1970: 100))
        journey.basket = try BasketPlan(id: journey.id, revisionID: UUID(), lines: [BasketLine(id: UUID(), name: "Rice",
            quantity: Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2 packs"), expectedCost: .unknown(reason: "Not quoted"))], createdAt: journey.savedAt)
        let receipt = SourceMediaRecord(id: UUID(), target: .init(workspaceID: workspaceID, containerID: journey.id, objectID: journey.id,
            revision: journey.revision, kind: .receiptEvidence), originalText: "TOTAL $?.00", reviewedLabel: "Receipt", imageJPEG: nil, barcode: nil,
            receiptLines: [.init(originalText: "2 rice $?.00", quantityNote: "Unreadable", priceNote: "Unknown")], capturedAt: Date(timeIntervalSince1970: 100))
        let bytes = try RecordsNativeCodec.canonical(journey)
        let record = ArchiveRecord(id: journey.id.uuidString, origin: "pickups/" + workspaceID.uuidString,
            revision: ArchiveCodec.digest(bytes), kind: .pickup, title: "Pickup", savedAtMilliseconds: 100_000,
            nativePayload: bytes, media: [try RecordsMediaCodec.attachment(receipt)])
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        let captureID = UUID(), templateID = UUID()
        let evidence = try RecipeSourceEvidence(captureID: captureID, originalText: "Recipe wording", kind: .photoOCR,
            localMedia: .init(workspaceID: workspaceID, mediaID: captureID))
        let template = MealTemplate(id: templateID, title: "Rice", ingredients: [], sourceEvidence: evidence)
        let source = SourceMediaRecord(id: captureID, target: .init(workspaceID: workspaceID, containerID: workspaceID, objectID: templateID,
            revision: 0, kind: .recipeSource), originalText: evidence.originalText, reviewedLabel: "Rice source", imageJPEG: nil,
            barcode: nil, receiptLines: [], capturedAt: Date(timeIntervalSince1970: 100))
        let recipeBytes = try RecordsNativeCodec.canonical(LedgerDocument(workspace: LedgerWorkspace(mealTemplates: [template])))
        var library = ArchiveRecord(id: "meal-library", origin: "ledger/" + workspaceID.uuidString,
            revision: ArchiveCodec.digest(recipeBytes), kind: .ledger, title: "Reusable dinners", savedAtMilliseconds: 100_000,
            nativePayload: recipeBytes, media: [try RecordsMediaCodec.attachment(source)])
        XCTAssertNoThrow(try RecordsNativeCodec.validate(library))
        library.media = record.media
        XCTAssertThrowsError(try RecordsNativeCodec.validate(library)) { XCTAssertEqual($0 as? ArchiveError, .invalidIdentity) }
    }
    func testUntrustedNestedAuthorityWrongOwnerUnsupportedImageAndVersionFailWithoutRegistryMutation() async throws {
        let (record, source) = try package(), root = try location(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        var base = record; base.media = nil
        _ = try await registry.apply(registry.review(ArchiveCodec.make(records: [base], kind: .personalRecovery, origin: "local", revision: "existing")))
        let before = try Data(contentsOf: root.appendingPathComponent("registry.json"))
        let attachment = try XCTUnwrap(record.media?.first)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: attachment.data) as? [String: Any])
        var evidence = json["source"] as! [String: Any]; evidence["consent"] = true; json["source"] = evidence
        let extra = ArchiveMediaAttachment(id: attachment.id, kind: attachment.kind, data: try JSONSerialization.data(withJSONObject: json, options: [.sortedKeys, .withoutEscapingSlashes]))
        XCTAssertThrowsError(try RecordsMediaCodec.decode(extra)) { XCTAssertEqual($0 as? ArchiveError, .unsupportedRecord) }
        json["formatMajor"] = 99
        XCTAssertThrowsError(try RecordsMediaCodec.decode(.init(id: attachment.id, kind: attachment.kind, data: JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]))))
        let damaged = SourceMediaRecord(id: source.id, target: source.target, originalText: source.originalText, reviewedLabel: source.reviewedLabel,
            imageJPEG: Data("not a JPEG".utf8), barcode: nil, receiptLines: [], capturedAt: source.capturedAt)
        XCTAssertThrowsError(try RecordsMediaCodec.attachment(damaged))
        var foreign = record; foreign.origin = "ledger/" + UUID().uuidString
        XCTAssertThrowsError(try RecordsMediaCodec.validate(foreign))
        var invalid = record; invalid.media = [extra]
        let invalidEnvelope = try ArchiveCodec.make(records: [invalid], kind: .personalRecovery, origin: "file", revision: "bad")
        let file = root.appendingPathComponent("bad.json"); try ArchiveCodec.encode(invalidEnvelope).write(to: file)
        let importer = model(base, registry: registry)
        await importer.importFile(file, recipes: false)
        XCTAssertNil(importer.review); XCTAssertNotNil(importer.error)
        XCTAssertEqual(try Data(contentsOf: root.appendingPathComponent("registry.json")), before)
    }
    func testLiveScopeChangeDuringValidationClearsPrivateExportAndStagedImport() async throws {
        let (record, _) = try package(), root = try location(), registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        var generation = UUID(), invalidate = false
        let tools = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) }, validateNativePayload: { value in
            try RecordsNativeCodec.validate(value)
            if invalidate { generation = UUID() }
        }, openRecovered: { _ in }, beginAuthorization: {
            let captured = generation
            return { generation == captured }
        })
        await tools.refresh(); tools.selectAll(); tools.generateRecoveryKey()
        invalidate = true; await tools.prepareExport(.encryptedRecovery)
        XCTAssertNil(tools.preparedDocument); XCTAssertTrue(tools.currentRecords.isEmpty)
        invalidate = false
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "file", revision: "source")
        let file = root.appendingPathComponent("recovery.json"); try ArchiveCodec.encode(envelope).write(to: file)
        await tools.importFile(file, recipes: false); XCTAssertNotNil(tools.review)
        generation = UUID(); await tools.applyReviewedImport()
        XCTAssertNil(tools.review)
        let records = try await registry.refreshList(); XCTAssertTrue(records.isEmpty)
    }
    func testCaptureArchiveListingCannotEscapeLiveNamespaceAndHonorsRemovalMarkers() async throws {
        let (_, source) = try package(), root = try location(), store = CaptureMediaStore(directory: root)
        _ = try await store.save(source, authorize: { true })
        let listed = try await store.archiveListing(workspaceID: source.target.workspaceID, authorize: { true })
        XCTAssertEqual(listed.records, [source]); XCTAssertEqual(listed.unavailableCount, 0)
        let foreign = try await store.archiveListing(workspaceID: UUID(), authorize: { true }); XCTAssertTrue(foreign.records.isEmpty)
        do { _ = try await store.archiveListing(workspaceID: source.target.workspaceID, authorize: { false }); XCTFail("Denied") } catch {}
        try await store.remove(source.reference, target: source.target, authorize: { true })
        let erased = try await store.archiveListing(workspaceID: source.target.workspaceID, authorize: { true }); XCTAssertTrue(erased.records.isEmpty)
        let retired = try await store.isRetired(source); XCTAssertTrue(retired)
    }
    func testCorruptOptionalSidecarIsReportedWithoutBlockingHealthyRecordBackupOrReplacingBytes() async throws {
        let (base, source) = try package(), root = try location(), mediaRoot = root.appendingPathComponent("media")
        let store = CaptureMediaStore(directory: mediaRoot)
        _ = try await store.save(source, authorize: { true })
        let folder = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: mediaRoot, includingPropertiesForKeys: [.isDirectoryKey]).first {
            (try? $0.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
        })
        let file = folder.appendingPathComponent(source.id.uuidString.lowercased() + ".json"), corrupt = Data("corrupt optional evidence".utf8)
        try corrupt.write(to: file)
        let registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        let tools = RecordsToolsModel(registry: registry, snapshot: {
            let listing = try await store.archiveListing(workspaceID: source.target.workspaceID, authorize: { true })
            let warnings = (0..<listing.unavailableCount).map { RecordsUnavailableRecord(origin: "media", recordID: String($0), title: "Source reference", reason: .unreadableStorage) }
            var native = base; native.media = nil
            return .init(records: [try RecordsMediaCodec.attaching(listing.records, to: native)], unavailable: warnings)
        }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await tools.refresh(); tools.selectAll(); tools.generateRecoveryKey()
        XCTAssertEqual(tools.currentRecords.count, 1); XCTAssertEqual(tools.unavailableRecords.count, 1)
        await tools.prepareExport(.encryptedRecovery)
        XCTAssertNil(tools.error)
        let envelope = try EncryptedArchive.open(XCTUnwrap(tools.preparedDocument).data, key: tools.recoveryKey)
        XCTAssertEqual(envelope.payload.records.count, 1); XCTAssertNil(envelope.payload.records[0].media)
        XCTAssertEqual(tools.unavailableRecords.count, 1); XCTAssertEqual(try Data(contentsOf: file), corrupt)
    }
    func testSelectedReducedJPEGRoundTripAndCorruptImageRejectsWholeBatch() async throws {
        let (base, textSource) = try package(), root = try location()
        let rendered = UIGraphicsImageRenderer(size: CGSize(width: 32, height: 32)).image { context in
            UIColor.white.setFill(); context.fill(CGRect(x: 0, y: 0, width: 32, height: 32))
        }
        let jpeg = try ScanImageNormalizer.normalize(XCTUnwrap(rendered.jpegData(compressionQuality: 0.8)))
        let photoSource = SourceMediaRecord(id: textSource.id, target: textSource.target, originalText: textSource.originalText,
            reviewedLabel: textSource.reviewedLabel, imageJPEG: jpeg, barcode: nil, receiptLines: [], capturedAt: textSource.capturedAt)
        var record = base; record.media = [try RecordsMediaCodec.attachment(photoSource)]
        let registryURL = root.appendingPathComponent("registry.json"), registry = try RecoveryRegistry(url: registryURL)
        let exporter = model(record, registry: registry)
        await exporter.refresh(); exporter.selectAll(); exporter.generateRecoveryKey()
        exporter.selectedMediaIDs.insert(RecordsToolsModel.mediaSelectionID(record.media![0], record: record))
        await exporter.prepareExport(.encryptedRecovery)
        let envelope = try EncryptedArchive.open(XCTUnwrap(exporter.preparedDocument).data, key: exporter.recoveryKey)
        let imported = try await registry.apply(registry.review(envelope))
        XCTAssertEqual(try RecordsMediaCodec.decode(XCTUnwrap(imported.records[0].record.media?.first)).imageJPEG, jpeg)
        let before = try Data(contentsOf: registryURL)
        var object = try JSONSerialization.jsonObject(with: record.media![0].data) as! [String: Any]
        var sourceObject = object["source"] as! [String: Any]
        sourceObject["imageJPEG"] = Data("invalid image".utf8).base64EncodedString(); object["source"] = sourceObject
        record.media = [.init(id: photoSource.id.uuidString, kind: .packageReference,
            data: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes]))]
        var (unrelated, _) = try package(); unrelated.media = nil
        let corrupt = try ArchiveCodec.make(records: [record, unrelated], kind: .personalRecovery, origin: "file", revision: "corrupt")
        let file = root.appendingPathComponent("corrupt.json"); try ArchiveCodec.encode(corrupt).write(to: file)
        let importer = model(base, registry: registry)
        await importer.importFile(file, recipes: false)
        XCTAssertNil(importer.review); XCTAssertEqual(importer.error, .integrity)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }
    func testRecoveredEditProjectionFiltersMediaForRemovedTargetsNewShopsAndMealLibrary() async throws {
        let (original, _) = try package(), root = try location()
        let registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        let initial = try ArchiveCodec.make(records: [original], kind: .personalRecovery, origin: "source", revision: "source")
        let committed = try await registry.apply(registry.review(initial))
        let sourceCopy = try XCTUnwrap(committed.records.first)
        let originalBytes = try XCTUnwrap(original.nativePayload)
        let unchanged = try RecordsNativeCodec.revised(sourceCopy.record, nativePayload: originalBytes, id: original.id,
            title: original.title, date: Date(timeIntervalSince1970: 200), lines: original.helperLines)
        XCTAssertEqual(unchanged, original)

        let sourceWorkspace = try RecordsNativeCodec.ledger(originalBytes)
        let originalShop = try XCTUnwrap(sourceWorkspace.shops.first)
        // A typed emitted shop no longer containing the reference's target must not
        // inherit that target's photo from its historical source snapshot.
        let withoutTarget = ShoppingLedger(id: originalShop.id, title: originalShop.title, basis: originalShop.basis)
        let anotherShop = ShoppingLedger(title: "Another shop")
        let edited = LedgerWorkspace(shops: [withoutTarget, anotherShop],
            mealTemplates: [MealTemplate(title: "New reusable dinner", ingredients: [])], selectedShopID: withoutTarget.id)
        try edited.validate()
        var projections: [ArchiveRecord] = []
        for shop in edited.shops {
            let scope = try RecordsNativeCodec.ledgerScope(edited, shop: shop)
            let payload = try RecordsNativeCodec.canonical(LedgerDocument(workspace: scope))
            projections.append(try RecordsNativeCodec.revised(sourceCopy.record, nativePayload: payload, id: shop.id.uuidString,
                title: shop.title, date: Date(timeIntervalSince1970: 200), lines: []))
        }
        let library = try XCTUnwrap(RecordsNativeCodec.ledgerLibrary(edited))
        projections.append(try RecordsNativeCodec.revised(sourceCopy.record,
            nativePayload: RecordsNativeCodec.canonical(LedgerDocument(workspace: library)), id: "meal-library",
            title: "Reusable dinners", date: Date(timeIntervalSince1970: 200), lines: []))
        for projection in projections {
            XCTAssertNil(projection.media)
            XCTAssertEqual(projection.parentRevision, original.revision)
            XCTAssertNoThrow(try RecordsNativeCodec.validate(projection))
        }
        let exporter = RecordsToolsModel(registry: registry, snapshot: { .init(records: projections) },
            validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await exporter.refresh(); exporter.selectAll(); exporter.generateRecoveryKey()
        // A prior selection cannot cause the discarded photo to travel with a new owner.
        exporter.selectedMediaIDs = [RecordsToolsModel.mediaSelectionID(original.media![0], record: original)]
        await exporter.prepareExport(.encryptedRecovery)
        XCTAssertNil(exporter.error)
        let exported = try EncryptedArchive.open(XCTUnwrap(exporter.preparedDocument).data, key: exporter.recoveryKey)
        XCTAssertEqual(exported.payload.records.count, 3); XCTAssertNil(exported.mediaManifest)
        XCTAssertTrue(exported.payload.records.allSatisfy { $0.media == nil })
        let historical = await registry.load(id: sourceCopy.id)
        XCTAssertEqual(historical?.record, original)
    }
    func testActionOutcomeAnchorChangesOnlyAfterCompletedDeletionAndClearsOnFailure() async throws {
        let (record, _) = try package(), root = try location()
        let registry = try RecoveryRegistry(url: root.appendingPathComponent("registry.json"))
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "source", revision: "source")
        let committed = try await registry.apply(registry.review(envelope))
        let copyID = try XCTUnwrap(committed.records.first?.id)
        let tools = model(record, registry: registry)
        await tools.refresh(); XCTAssertNil(tools.actionOutcomeID)
        await tools.deleteRecovered(.copy(copyID))
        let deletedOutcome = try XCTUnwrap(tools.actionOutcomeID)
        XCTAssertNil(tools.error); XCTAssertNotNil(tools.status)
        await tools.deleteRecovered(.copy(copyID))
        XCTAssertNotNil(tools.error); XCTAssertNil(tools.actionOutcomeID)
        await tools.undoRecoveredDeletion()
        XCTAssertNotNil(tools.actionOutcomeID); XCTAssertNotEqual(tools.actionOutcomeID, deletedOutcome)
        XCTAssertNil(tools.error)
        tools.invalidateForSourceErasure()
        XCTAssertNil(tools.actionOutcomeID); XCTAssertNil(tools.status)
    }
}
