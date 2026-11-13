import XCTest
import Combine
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

final class RecordsAdapterTests: XCTestCase {
    private struct CollectionFixture: Codable { let flexible: Set<UUID>; let frozenQuotes: [UUID: CheckoutQuote] }
    private struct LedgerFixture: Codable { let formatVersion: Int; let workspace: LedgerWorkspace }
    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    @MainActor private func comparison(legacy: Bool = false, edit: (inout ComparisonDraft) -> Void = { _ in }) throws -> ArchiveRecord {
        var draft = ComparisonDraft()
        draft.item = "Arroz"; draft.needed = "2"; draft.unit = .count
        draft.aLabel = "Original A"; draft.aQuantity = "1"; draft.aPrice = "3.49"
        draft.bLabel = "Original B"; draft.bQuantity = "2"; draft.bPrice = "5.00"
        edit(&draft)
        let request = try ComparisonModel(draft: draft).request()
        let payload = legacy ? SavedPayload(draft: draft) : SavedPayload(draft: draft, calculationVersion: SavedPayload.currentCalculationVersion,
            normalizedRequest: request, answer: try PackComparison.evaluate(request), roundingPolicy: SavedPayload.currentRoundingPolicy)
        let data = try RecordsNativeCodec.canonical(payload)
        return ArchiveRecord(id: draft.id.uuidString, origin: "comparisons/fixture", revision: ArchiveCodec.digest(data),
            kind: .comparison, title: draft.item, savedAtMilliseconds: 1_800_000_000_000,
            helperLines: [HelperLine(label: draft.item, originalAmount: draft.needed, originalUnit: "count")], nativePayload: data)
    }
    @MainActor func testPickerCompletionAndManualRecipeStayWithTheirPresentingScope() async throws {
        let directory = try temporaryDirectory()
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("registry.json"))
        var scope = UUID()
        let tools = RecordsToolsModel(registry: registry, snapshot: { RecordsSnapshotBatch() },
                                     validateNativePayload: { _ in }, openRecovered: { _ in },
                                     beginAuthorization: {
            let captured = scope
            return { captured == scope }
        })
        let file = directory.appendingPathComponent("recipe.json")
        try Data(#"{"@type":"Recipe","name":"Selected soup","recipeIngredient":["Beans"]}"#.utf8).write(to: file)
        let first = try XCTUnwrap(tools.beginImport(.recipeFile))
        scope = UUID()
        await tools.finishFileImport(.success(file), from: first)
        XCTAssertNil(tools.review)
        XCTAssertNil(tools.importPresentation)

        let oldManual = try XCTUnwrap(tools.beginImport(.manualRecipe))
        tools.invalidateForSourceErasure()
        XCTAssertNil(tools.importPresentation)
        let next = try XCTUnwrap(tools.beginImport(.recipeFile))
        let staleStaged = await tools.stageManualRecipe(ImportedRecipe(title: "Earlier handwritten recipe"), from: oldManual)
        XCTAssertFalse(staleStaged)
        await tools.finishFileImport(.failure(ArchiveError.malformed), from: first)
        tools.dismissImport(oldManual)
        XCTAssertEqual(tools.importPresentation?.id, next.id)
        XCTAssertNil(tools.error)
        XCTAssertNil(tools.review)
        await tools.finishFileImport(.success(file), from: next)
        XCTAssertEqual(tools.review?.rows.map(\.record.title), ["Selected soup"])
        await tools.finishFileImport(.success(file), from: first)
        XCTAssertEqual(tools.review?.rows.map(\.record.title), ["Selected soup"])
        tools.cancelReview()

        let manual = try XCTUnwrap(tools.beginImport(.manualRecipe))
        let staged = await tools.stageManualRecipe(ImportedRecipe(title: "Current handwritten recipe"), from: manual)
        XCTAssertTrue(staged)
        XCTAssertEqual(tools.review?.rows.map(\.record.title), ["Current handwritten recipe"])
        let saved = try await registry.refreshList()
        XCTAssertTrue(saved.isEmpty)
    }

    @MainActor func testImportComparesIndependentRevisionsBySourceAndClearsErasedReview() async throws {
        let directory = try temporaryDirectory(), registry = try RecoveryRegistry(url: directory.appendingPathComponent("registry.json"))
        let incoming = try comparison(), id = try XCTUnwrap(UUID(uuidString: incoming.id))
        var edited = try comparison { $0.id = id; $0.aPrice = "4.25" }
        edited.savedAtMilliseconds += 10_000
        var recoveredOnly = try comparison { $0.id = id; $0.aPrice = "4.75" }
        recoveredOnly.savedAtMilliseconds += 20_000
        var otherSource = incoming; otherSource.origin = "other-workspace"
        let selected = RecordsToolsModel.selectionID(recoveredOnly)
        var batch = RecordsSnapshotBatch(records: [incoming, edited, recoveredOnly, otherSource], recoveredCopyIDsByRecord: [selected: ["separate-copy"]])
        let model = RecordsToolsModel(registry: registry, snapshot: { batch },
                                     validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh()
        let owner = try ArchiveCodec.make(records: [incoming], kind: .personalRecovery, origin: "file", revision: "export")
        let file = directory.appendingPathComponent("records.json")
        try ArchiveCodec.encode(owner).write(to: file)
        await model.importFile(file, recipes: false)
        let rowID = try XCTUnwrap(model.review?.rows.first).id
        XCTAssertEqual(model.currentImportVersions[rowID], [
            .init(revision: incoming.revision, savedAtMilliseconds: incoming.savedAtMilliseconds),
            .init(revision: edited.revision, savedAtMilliseconds: edited.savedAtMilliseconds)
        ])
        batch.records = [edited, recoveredOnly, otherSource]
        await model.refresh()
        XCTAssertEqual(model.currentImportVersions[rowID]?.map(\.revision), [edited.revision])

        let helper = try ArchiveCodec.make(records: [incoming], kind: .helperShop, origin: "file", revision: "export")
        for redacted in [helper, try ArchiveCodec.make(records: helper.payload.records, kind: .personalRecovery, origin: "file", revision: "wrapped")] {
            try ArchiveCodec.encode(redacted).write(to: file)
            await model.importFile(file, recipes: false)
            XCTAssertNotNil(model.review)
            XCTAssertTrue(model.currentImportVersions.isEmpty)
        }

        let committed = try await registry.apply(registry.review(owner))
        let copyID = try XCTUnwrap(committed.insertedCopyIDs.first)
        try ArchiveCodec.encode(owner).write(to: file)
        await model.importFile(file, recipes: false)
        XCTAssertEqual(model.review?.rows.first?.disposition, .identical)
        await model.refresh()
        await model.confirmDeletion(try XCTUnwrap(model.reviewRecoveredDeletion(.copy(copyID), title: "Recovered copy")))
        XCTAssertNil(model.review)
        await model.importFile(file, recipes: false)
        XCTAssertEqual(model.review?.rows.first?.disposition, .erased)
        XCTAssertTrue(model.currentImportVersions.isEmpty)
        await model.undoRecoveredDeletion()
        XCTAssertNil(model.review)
        await model.importFile(file, recipes: false)
        XCTAssertEqual(model.review?.rows.first?.disposition, .identical)
        XCTAssertEqual(model.currentImportVersions[rowID]?.map(\.revision), [edited.revision])
    }

    @MainActor func testSourceDeletionRechecksDisplayedCopiesAndPresentingWorkspace() async throws {
        let url = try temporaryDirectory().appendingPathComponent("registry.json")
        let registry = try RecoveryRegistry(url: url)
        let otherWriter = try RecoveryRegistry(url: url)
        let first = try comparison()
        let added = try comparison()
        var elsewhere = try comparison()
        elsewhere.origin = "separate-source"
        func save(_ record: ArchiveRecord) async throws {
            let file = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "file", revision: "export")
            _ = try await otherWriter.apply(otherWriter.review(file))
        }
        try await save(first)
        var workspace = UUID()
        var deletedSources: [String] = []
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [elsewhere]) }, validateNativePayload: { _ in },
            openRecovered: { _ in }, deleteSource: { record, authorize in
                XCTAssertTrue(authorize())
                deletedSources.append(record.id)
            }, beginAuthorization: {
                let original = workspace
                return { original == workspace }
            })
        await model.refresh()
        let deletion = try XCTUnwrap(model.reviewRecoveredDeletion(.origin(first.origin), title: first.origin))
        XCTAssertEqual(deletion.copyCount, 1)
        try await save(added)
        await model.confirmDeletion(deletion)
        XCTAssertEqual(model.error, .deletionSelectionChanged)
        XCTAssertEqual(Set(model.recoveredRecords.map(\.record.id)), [first.id, added.id])

        let secondReview = try XCTUnwrap(model.reviewRecoveredDeletion(.origin(first.origin), title: first.origin))
        let sourceDeletion = try XCTUnwrap(model.reviewSourceDeletion(elsewhere))
        workspace = UUID()
        await model.confirmDeletion(secondReview)
        XCTAssertEqual(model.error, .unavailable)
        await model.confirmDeletion(sourceDeletion)
        XCTAssertEqual(model.error, .unavailable)
        XCTAssertTrue(deletedSources.isEmpty)
        await model.refresh()
        let confirmed = try XCTUnwrap(model.reviewRecoveredDeletion(.origin(first.origin), title: first.origin))
        XCTAssertEqual(confirmed.copyCount, 2)
        try await save(elsewhere)
        await model.confirmDeletion(confirmed)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.recoveredRecords.map(\.record.id), [elsewhere.id])
        await model.undoRecoveredDeletion()
        XCTAssertEqual(Set(model.recoveredRecords.map(\.record.id)), [first.id, added.id, elsewhere.id])
        await model.confirmDeletion(confirmed)
        XCTAssertEqual(model.error, .deletionSelectionChanged)
        XCTAssertEqual(Set(model.recoveredRecords.map(\.record.id)), [first.id, added.id, elsewhere.id])
        await model.confirmDeletion(try XCTUnwrap(model.reviewSourceDeletion(elsewhere)))
        XCTAssertNil(model.error)
        XCTAssertEqual(deletedSources, [elsewhere.id])
    }

    @MainActor func testChangingRecoveryKeyRetiresTheFileEncryptedWithThePreviousKey() async throws {
        let record = try comparison()
        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("registry.json"))
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) },
                                     validateNativePayload: { _ in }, openRecovered: { _ in })
        await model.refresh()
        model.selectAll()
        model.generateRecoveryKey()
        let firstKey = model.recoveryKey
        await model.prepareExport(.encryptedRecovery)
        let originalBytes = try XCTUnwrap(model.preparedDocument).data
        XCTAssertEqual(try EncryptedArchive.open(originalBytes, key: firstKey).payload.records, [record])
        model.recoveryKey = firstKey
        XCTAssertEqual(model.preparedDocument?.data, originalBytes)

        model.generateRecoveryKey()
        XCTAssertNotEqual(model.recoveryKey, firstKey)
        XCTAssertNil(model.preparedDocument)
        XCTAssertNil(model.status)
        await model.prepareExport(.encryptedRecovery)
        let newBytes = try XCTUnwrap(model.preparedDocument).data
        XCTAssertEqual(try EncryptedArchive.open(newBytes, key: model.recoveryKey).payload.records, [record])
        XCTAssertThrowsError(try EncryptedArchive.open(newBytes, key: firstKey))
        await model.prepareExport(.helperText)
        let helperBytes = try XCTUnwrap(model.preparedDocument).data
        model.recoveryKey = ""
        XCTAssertEqual(model.preparedDocument?.data, helperBytes)
    }

    @MainActor func testRecoveryKeyChangeDuringPreparationRequiresAReviewedRetry() async throws {
        let record = try comparison()
        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("registry.json"))
        var rotateDuringValidation: (() -> Void)?
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) },
            validateNativePayload: { _ in rotateDuringValidation?() }, openRecovered: { _ in })
        await model.refresh()
        model.selectAll()
        model.generateRecoveryKey()
        rotateDuringValidation = { [weak model] in model?.generateRecoveryKey() }
        await model.prepareExport(.encryptedRecovery)
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(model.error, .exportSelectionChanged)

        rotateDuringValidation = nil
        await model.prepareExport(.encryptedRecovery)
        let data = try XCTUnwrap(model.preparedDocument).data
        XCTAssertEqual(try EncryptedArchive.open(data, key: model.recoveryKey).payload.records, [record])
    }
    @MainActor func testOnlyCompletedEncryptedSaveMarksTheExportedRevisionAfterRelaunch() async throws {
        let record = try comparison()
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        let path = try temporaryDirectory().appendingPathComponent("registry.json")
        var visible = [record]
        func open() throws -> RecordsToolsModel {
            RecordsToolsModel(registry: try RecoveryRegistry(url: path), snapshot: { .init(records: visible) },
                              validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        }
        let model = try open()
        await model.refresh()
        model.selectAll()
        await model.prepareExport(.ownerText)
        let textSave = try XCTUnwrap(model.beginFileSave())
        await model.finishFileSave(textSave, result: .success(()), at: date)
        XCTAssertNil(model.backupDateText(for: record))
        model.generateRecoveryKey()
        await model.prepareExport(.encryptedRecovery)
        let cancelled = try XCTUnwrap(model.beginFileSave())
        await model.finishFileSave(cancelled, result: .failure(CancellationError()), at: date)
        XCTAssertNil(model.error)
        XCTAssertNil(model.backupDateText(for: record))
        let failed = try XCTUnwrap(model.beginFileSave())
        await model.finishFileSave(failed, result: .failure(ArchiveError.unavailable), at: date)
        XCTAssertEqual(model.error, .unavailable)
        XCTAssertNil(model.backupDateText(for: record))
        let saved = try XCTUnwrap(model.beginFileSave())
        await model.finishFileSave(cancelled, result: .success(()), at: date)
        XCTAssertNil(model.backupDateText(for: record))
        await model.finishFileSave(saved, result: .success(()), at: date)
        let timestamp = ArchiveCodec.milliseconds(date)
        let current = RecordsDatePresentation.encryptedBackupSavedAt(timestamp, currentRevision: true)
        XCTAssertEqual(model.backupDateText(for: record), current)
        let reopened = try open()
        await reopened.refresh()
        XCTAssertEqual(reopened.backupDateText(for: record), current)

        let changed = try comparison { draft in draft.id = UUID(uuidString: record.id)!; draft.aPrice = "4.19" }
        visible = [changed]
        await reopened.refresh()
        XCTAssertEqual(reopened.backupDateText(for: changed),
                       RecordsDatePresentation.encryptedBackupSavedAt(timestamp, currentRevision: false))
        var helper = changed
        helper.nativePayload = nil
        visible = [helper]
        await reopened.refresh()
        XCTAssertNil(reopened.backupDateText(for: helper))
    }

    @MainActor func testInvalidatedFilePickerCannotPublishAnotherOwnersBackupDate() async throws {
        let record = try comparison()
        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("registry.json"))
        let session = CurrentValueSubject<UUID, Never>(UUID())
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) },
                                     validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in },
                                     beginAuthorization: {
            let owner = session.value
            return { owner == session.value }
        })
        await model.refresh()
        model.selectAll()
        model.generateRecoveryKey()
        await model.prepareExport(.encryptedRecovery)
        let oldSelection = try XCTUnwrap(model.beginFileSave())
        model.dismissPreparedFile()
        await model.finishFileSave(oldSelection, result: .success(()))
        XCTAssertNil(model.backupDateText(for: record))
        await model.prepareExport(.encryptedRecovery)
        let oldSession = try XCTUnwrap(model.beginFileSave())
        session.send(UUID())
        await model.finishFileSave(oldSession, result: .success(()))
        XCTAssertTrue(model.currentRecords.isEmpty)
        let persisted = try await registry.lastEncryptedBackups(for: [record])
        XCTAssertTrue(persisted.isEmpty)
    }

    @MainActor func testRevokedReadNeverPublishesPrivateListingOrRecoveredCopies() async throws {
        let record = try comparison()
        let omitted = RecordsUnavailableRecord(origin: record.origin, recordID: "unreadable", title: "Private omitted title", reason: .invalidNative)
        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("registry.json"))
        let archive = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "backup", revision: "saved")
        _ = try await registry.apply(registry.review(archive))
        for export in [false, true] {
            // Refresh must remain authorized through its registry read. Export must
            // still be authorized when its source snapshot comes back.
            var remainingChecks: Int?
            let model = RecordsToolsModel(registry: registry, snapshot: {
                remainingChecks = export ? 0 : 1
                return .init(records: [record], unavailable: [omitted])
            }, validateNativePayload: { _ in XCTFail("A revoked snapshot cannot be exported") },
               openRecovered: { _ in }, beginAuthorization: {
                {
                    guard let remaining = remainingChecks else { return true }
                    remainingChecks = remaining - 1
                    return remaining > 0
                }
            })
            var published = Set<AnyCancellable>()
            defer { published.forEach { $0.cancel() } }
            model.$sourceListing.sink { batch in
                XCTAssertTrue(batch.records.isEmpty)
                XCTAssertTrue(batch.unavailable.isEmpty)
            }.store(in: &published)
            model.$recoveredRecords.sink { XCTAssertTrue($0.isEmpty) }.store(in: &published)
            if export { await model.prepareExport(.ownerText) } else { await model.refresh() }
            XCTAssertEqual(model.error, .unavailable)
            XCTAssertNil(model.preparedDocument)
        }
    }

    @MainActor func testOverlappingSourceReadsPublishTheirOwnUnavailableTitles() async throws {
        let first = try comparison(), second = try comparison()
        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("registry.json"))
        let started = expectation(description: "First read suspended")
        var resume: CheckedContinuation<Void, Never>?
        var readCount = 0
        let model = RecordsToolsModel(registry: registry, snapshot: {
            readCount += 1
            let record = readCount == 1 ? first : second
            let omitted = RecordsUnavailableRecord(origin: record.origin, recordID: "omitted", title: record.id, reason: .invalidNative)
            if readCount == 1 {
                await withCheckedContinuation { continuation in resume = continuation; started.fulfill() }
            }
            return .init(records: [record], unavailable: [omitted])
        }, validateNativePayload: { _ in }, openRecovered: { _ in })
        var seen = Set<String>()
        let observation = model.$sourceListing.sink { batch in
            guard let source = batch.records.first else { return }
            XCTAssertEqual(batch.unavailable.compactMap(\.title), [source.id])
            seen.insert(source.id)
        }
        defer { observation.cancel() }
        let initial = Task { await model.refresh() }
        await fulfillment(of: [started], timeout: 2)
        await model.refresh()
        resume?.resume()
        await initial.value
        XCTAssertEqual(readCount, 2)
        XCTAssertTrue(seen.contains(second.id))
    }

    @MainActor func testEncryptedBackupRetainsOwnerComparisonWhenRedactedCopyIsImported() async throws {
        let record = try comparison()
        let owner = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "backup", revision: "saved")
        let helper = try ArchiveCodec.make(records: [record], kind: .helperShop, origin: "share", revision: "saved", shopID: record.id)
        for order in [[owner, helper], [helper, owner]] {
            let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("manifest.json"))
            for (index, envelope) in order.enumerated() {
                _ = try await registry.apply(registry.review(envelope), now: Date(timeIntervalSince1970: Double(index + 1)))
            }
            let model = RecordsToolsModel(registry: registry, snapshot: {
                RecordsSnapshotBatch(records: try await RecordsSnapshotProjection.mergeForExport(registry.refreshList().map(\.record)))
            }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
            await model.refresh()
            XCTAssertEqual(model.recoveredRecords.count, 2)
            XCTAssertEqual(model.currentRecords.count, 1)
            model.selectAll()
            model.generateRecoveryKey()
            await model.prepareExport(.encryptedRecovery)
            let backup = try EncryptedArchive.open(XCTUnwrap(model.preparedDocument).data, key: model.recoveryKey)
            XCTAssertEqual(backup.payload.records, [record])
            await model.prepareExport(.helperJSON)
            let redacted = try ArchiveCodec.decode(XCTUnwrap(model.preparedDocument).data)
            XCTAssertEqual(redacted.payload.records, helper.payload.records)
        }
    }

    @MainActor func testExportSelectionDistinguishesSlashesInOriginAndRevision() async throws {
        var first = try comparison()
        var second = try comparison()
        first.origin = "family"
        first.revision = second.id + "/archived"
        second.origin = "family/" + first.id
        second.revision = "archived"
        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("manifest.json"))
        let file = try ArchiveCodec.make(records: [first, second], kind: .personalRecovery,
                                         origin: "backup", revision: "saved")
        _ = try await registry.apply(registry.review(ArchiveCodec.decode(ArchiveCodec.encode(file))))
        let model = RecordsToolsModel(registry: registry, snapshot: {
            RecordsSnapshotBatch(records: try await RecordsSnapshotProjection.mergeForExport(registry.refreshList().map(\.record)))
        }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh()

        model.selectedIDs = [RecordsToolsModel.selectionID(second)]
        XCTAssertEqual(model.selectedCount, 1)
        await model.prepareExport(.helperJSON)
        let helper = try ArchiveCodec.decode(XCTUnwrap(model.preparedDocument?.data))
        XCTAssertEqual(helper.payload.records.map(\.id), [second.id])
        XCTAssertEqual(helper.payload.records.first?.origin, second.origin)
    }

    @MainActor func testComparisonNativeRoundTripAndNestedAuthorityFieldRejection() throws {
        let record = try comparison()
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        let payload = try RecordsNativeCodec.comparison(XCTUnwrap(record.nativePayload))
        XCTAssertEqual(payload.draft.aPrice, "3.49")
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(record.nativePayload)) as? [String: Any])
        var draft = try XCTUnwrap(object["draft"] as? [String: Any])
        draft["membershipToken"] = "never accepted"
        object["draft"] = draft
        var altered = record
        altered.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try RecordsNativeCodec.validate(altered)) { XCTAssertEqual($0 as? ArchiveError, .unsupportedRecord) }
    }
    @MainActor func testLedgerCanonicalRoundTripPreservesOriginalImportAndUUIDDecisionMap() throws {
        var shop = ShoppingLedger(title: "Tuesday")
        let original = "2 rice\nsalt to taste"
        let preview = try shop.stageImport(text: original, source: .paste)
        let decisions = Dictionary(uniqueKeysWithValues: preview.lines.map { ($0.id, ImportResolution.addNew) })
        _ = try shop.commitImport(preview, decisions: decisions, at: Date(timeIntervalSince1970: 100))
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        let bytes = try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: workspace))
        let decoded = try RecordsNativeCodec.ledger(bytes)
        XCTAssertEqual(decoded.shops.first?.importBatches.first?.originalText, original)
        XCTAssertEqual(decoded.shops.first?.importBatches.first?.decisions, decisions)
        XCTAssertEqual(try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: decoded)), bytes)
        let record = ArchiveRecord(id: shop.id.uuidString, origin: "ledger/fixture", revision: ArchiveCodec.digest(bytes), kind: .ledger,
            title: shop.title, savedAtMilliseconds: 100_000, nativePayload: bytes)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
    }
    @MainActor func testPickupCanonicalRoundTripOrdersSetAndUUIDQuoteMapWithoutChangingValues() throws {
        let id = UUID(), lineID = UUID(), date = Date(timeIntervalSince1970: 100)
        let quantity = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2 paquetes")
        let line = BasketLine(id: lineID, name: "Arroz", quantity: quantity, expectedCost: .unknown(reason: "Not quoted"))
        let basket = try BasketPlan(id: id, revisionID: UUID(), lines: [line], createdAt: date)
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "5 PM", commitmentsID: id, observedAt: date, source: "Manual")
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(Money(minorUnits: 500))))
        var value = PickupJourney(id: id, savedAt: date)
        value.basket = basket; value.context = context; value.quote = quote; value.quotedRevisionID = basket.current.id
        value.frozenQuotes = [basket.current.id: quote]; value.flexible = [lineID]
        let bytes = try RecordsNativeCodec.canonical(value)
        let decoded = try RecordsNativeCodec.pickup(bytes)
        XCTAssertEqual(decoded, value)
        XCTAssertEqual(try RecordsNativeCodec.canonical(decoded), bytes)
        XCTAssertEqual(decoded.basket?.current.lines.first?.quantity.originalLiteral, "2 paquetes")
        let record = ArchiveRecord(id: id.uuidString, origin: "pickups/fixture", revision: ArchiveCodec.digest(bytes), kind: .pickup,
            title: "Arroz", savedAtMilliseconds: 100_000, nativePayload: bytes)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        let other = UUID()
        let left = CollectionFixture(flexible: [id, other], frozenQuotes: [id: quote, other: quote])
        let right = CollectionFixture(flexible: [other, id], frozenQuotes: [other: quote, id: quote])
        XCTAssertEqual(try RecordsNativeCodec.canonical(left), try RecordsNativeCodec.canonical(right))
        let collectionBytes = try RecordsNativeCodec.canonical(left)
        let reloaded = try JSONDecoder().decode(CollectionFixture.self, from: collectionBytes)
        XCTAssertEqual(try RecordsNativeCodec.canonical(reloaded), collectionBytes)
    }
    @MainActor func testHelperExportDropsNativeFinanceAndPersonalExportRequiresWorkingKey() async throws {
        let record = try comparison(), registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("manifest.json"))
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh(); model.selectAll()
        await model.prepareExport(.helperJSON)
        let helper = try ArchiveCodec.decode(XCTUnwrap(model.preparedDocument).data)
        XCTAssertNil(helper.payload.records.first?.nativePayload)
        XCTAssertEqual(helper.payload.records.first?.helperLines.first?.label, "Arroz")
        XCTAssertFalse(String(decoding: try ArchiveCodec.encode(helper), as: UTF8.self).contains("3.49"))
        await model.prepareExport(.encryptedRecovery)
        XCTAssertNil(model.preparedDocument); XCTAssertEqual(model.error, .invalidKey)
        model.generateRecoveryKey()
        await model.prepareExport(.encryptedRecovery)
        let encrypted = try XCTUnwrap(model.preparedDocument).data
        XCTAssertEqual(try EncryptedArchive.open(encrypted, key: model.recoveryKey).payload.records, [record])
    }
    @MainActor func testOwnerComparisonTextRetainsBothOffersAndStoredOutcomeWhileHelperOmitsPrices() async throws {
        let record = try comparison { $0.cap = "6.00"; $0.aQuantity = "1.00" }
        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("registry.json"))
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) },
                                     validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh()
        model.selectAll()
        await model.prepareExport(.ownerText)
        let owner = String(decoding: try XCTUnwrap(model.preparedDocument).data, as: UTF8.self)
        for label in [record.revision, record.origin, "Arroz", tr("Item-only comparison"),
                      tr("Pack A") + " · Original A", tr("Pack B") + " · Original B",
                      "1.00", "3.49", "5.00", "6.00",
                      message("Item cost to buy enough: %@", moneyText(Money(minorUnits: 698))),
                      message("Whole packs to buy: %@", "2"),
                      message("Over the item limit: %@", moneyText(Money(minorUnits: 98))),
                      message("Room within the item limit: %@", moneyText(Money(minorUnits: 100)))] {
            XCTAssertTrue(owner.contains(label), label)
        }
        let offers = owner.components(separatedBy: tr("Pack B") + " · Original B")
        XCTAssertEqual(offers.count, 2)
        XCTAssertFalse(offers.first?.contains(tr("Lower cost to buy enough for this item")) == true)
        XCTAssertTrue(offers.last?.contains(tr("Lower cost to buy enough for this item")) == true)
        XCTAssertFalse(owner.contains("normalizedRequest"))
        await model.prepareExport(.helperText)
        let helper = String(decoding: try XCTUnwrap(model.preparedDocument).data, as: UTF8.self)
        XCTAssertTrue(helper.contains("Arroz · " + pQuantity("2", unit: .count, singular: false, language: recordsInterfaceLocale.language.languageCode?.identifier)))
        for privateValue in ["Original A", "Original B", "6.00", "5.00", "3.49", "6.98"] {
            XCTAssertFalse(helper.contains(privateValue), privateValue)
        }
        model.generateRecoveryKey()
        await model.prepareExport(.encryptedRecovery)
        let restored = try EncryptedArchive.open(XCTUnwrap(model.preparedDocument).data, key: model.recoveryKey)
        XCTAssertEqual(restored.payload.records, [record])
    }

    @MainActor func testCookCopyKeepsOriginalFractionsAndSpelledUnitsInBothLanguages() throws {
        let lines = [
            HelperLine(label: "Caldo", originalAmount: "1.00", originalUnit: "fluidOunce"),
            HelperLine(label: "Rice", originalAmount: "1 1/2", originalUnit: "cup", purpose: "Lunch"),
            HelperLine(label: "Arroz", originalAmount: "1½ tazas de arroz", originalUnit: "cup"),
            HelperLine(label: "Wraps", originalAmount: "2 tortillas", originalUnit: "count"),
            HelperLine(label: "Hierbas", originalAmount: "2", originalUnit: "manojos"),
            HelperLine(label: "Nota", action: "Reservar para el jueves")
        ]
        let record = ArchiveRecord(id: "copy", origin: "family", revision: "1", kind: .pickup,
                                   title: "Lista", savedAtMilliseconds: 0, helperLines: lines)
        for (language, fluid, cups) in [("en", "fl oz", "cups"), ("es", "onza líquida", "tazas")] {
            let readable = recordsReadableText(record, owner: false, locale: Locale(identifier: language))
            let rows = readable.components(separatedBy: "\n")
            XCTAssertTrue(rows.contains("Caldo · 1.00 " + fluid))
            XCTAssertTrue(rows.contains("Rice · 1 1/2 " + cups + " · Lunch"))
            XCTAssertTrue(rows.contains("Arroz · 1½ tazas de arroz"))
            XCTAssertTrue(rows.contains("Wraps · 2 tortillas"))
            XCTAssertTrue(rows.contains("Hierbas · 2 manojos"))
            XCTAssertTrue(rows.contains("Nota · Reservar para el jueves"))
        }
        let archive = try ArchiveCodec.make(records: [record], kind: .helperShop, origin: "family", revision: "1", shopID: "copy")
        XCTAssertEqual(try ArchiveCodec.decode(ArchiveCodec.encode(archive)).payload.records.first?.helperLines, lines)
    }

    @MainActor func testPersonalTextExportsSavedPickupAndShoppingListTogether() async throws {
        let date = Date(timeIntervalSince1970: 1_790_000_000)
        var shop = ShoppingLedger(title: "Saturday list")
        let original = "1½ tazas de arroz"
        let preview = try shop.stageImport(text: original, source: .paste)
        let resolution = Dictionary(uniqueKeysWithValues: preview.lines.map { ($0.id, ImportResolution.addNew) })
        _ = try shop.commitImport(preview, decisions: resolution, at: date)
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        let shopBytes = try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: workspace))
        let shopRecord = ArchiveRecord(id: shop.id.uuidString, origin: "original-list", revision: ArchiveCodec.digest(shopBytes),
            kind: .ledger, title: shop.title, savedAtMilliseconds: ArchiveCodec.milliseconds(date), nativePayload: shopBytes)

        let quantity = Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2 bolsas")
        let beans = BasketLine(id: UUID(), name: "Frijoles", quantity: quantity, expectedCost: .unknown(reason: "Waiting for shelf price"))
        var journey = PickupJourney(id: UUID(), savedAt: date)
        journey.basket = try BasketPlan(id: journey.id, revisionID: UUID(), lines: [beans], createdAt: date)
        let pickupBytes = try RecordsNativeCodec.canonical(journey)
        let pickupRecord = ArchiveRecord(id: journey.id.uuidString, origin: "original-pickup", revision: ArchiveCodec.digest(pickupBytes),
            kind: .pickup, title: "Saturday pickup", savedAtMilliseconds: ArchiveCodec.milliseconds(date), nativePayload: pickupBytes)

        let registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("registry.json"))
        let records = [pickupRecord, shopRecord]
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: records) },
            validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh()
        model.selectAll()
        await model.prepareExport(.ownerText)
        let text = String(decoding: try XCTUnwrap(model.preparedDocument).data, as: UTF8.self)
        for expected in [pickupRecord.origin, shopRecord.origin, pickupRecord.revision, shopRecord.revision,
                         "Frijoles", "2 bolsas", "Waiting for shelf price", shop.title, original] {
            XCTAssertTrue(text.contains(expected), expected)
        }
        XCTAssertFalse(text.contains("\"nativePayload\""))
        XCTAssertFalse(text.contains("\"selectedShopID\""))
        XCTAssertFalse(text.contains("\"expectedCost\""))
    }

    @MainActor func testComparisonTextDistinguishesMissingPriceNoPurchaseAndLegacyDraft() throws {
        func rendered(_ record: ArchiveRecord) throws -> String {
            try RecordsNativeCodec.comparison(XCTUnwrap(record.nativePayload)).readableText()
        }
        let unknown = try rendered(comparison { $0.bPrice = "" })
        XCTAssertTrue(unknown.contains(tr("Cost unresolved")))
        XCTAssertTrue(unknown.contains(ComparisonIssue.priceUnknown.explanation))
        XCTAssertFalse(unknown.contains(tr("Lower cost to buy enough for this item")))
        let noPurchase = try rendered(comparison { $0.stock = "2"; $0.bPrice = "" })
        XCTAssertTrue(noPurchase.contains(message("Whole packs to buy: %@", "0")))
        XCTAssertTrue(noPurchase.contains(message("Item cost to buy enough: %@", moneyText(.zero))))
        XCTAssertTrue(noPurchase.contains(tr("Both options cost the same for this need.")))
        XCTAssertFalse(noPurchase.contains(tr("Cost unresolved")))
        let old = try rendered(comparison(legacy: true))
        XCTAssertTrue(old.contains(recordsText("No result was saved with this draft.")))
        XCTAssertTrue(old.contains("Original B"))
        XCTAssertFalse(old.contains(message("Whole packs to buy: %@", "2")))
        XCTAssertFalse(old.contains(tr("Lower cost to buy enough for this item")))
    }
    @MainActor func testSourceErasureBetweenSelectionAndExportCannotExportCachedPrivateData() async throws {
        let record = try comparison(), registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("manifest.json"))
        var sources = [record]
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: sources) }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh(); model.selectAll()
        sources = []
        await model.prepareExport(.ownerText)
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(model.error, .exportSelectionChanged)
        XCTAssertTrue(model.currentRecords.isEmpty)
    }
    @MainActor func testDamagedBackupReportsMalformedAndPreservesLiveAndRecoveredRecords() async throws {
        let directory = try temporaryDirectory()
        let manifest = directory.appendingPathComponent("manifest.json")
        let registry = try RecoveryRegistry(url: manifest)
        let live = try comparison()
        let earlier = try ImportedRecipe(title: "Earlier rice").archiveRecord(origin: "prior-kitchen")
        let old = try ArchiveCodec.make(records: [earlier], kind: .personalRecovery, origin: earlier.origin, revision: earlier.revision)
        _ = try await registry.apply(registry.review(old))
        let before = try Data(contentsOf: manifest)
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [live]) },
                                     validateNativePayload: { _ in XCTFail("A damaged file must not reach record validation") },
                                     openRecovered: { _ in XCTFail("A damaged file must not open a workspace") })
        await model.refresh()
        let recovered = model.recoveredRecords
        let file = directory.appendingPathComponent("damaged.roomrecovery")
        // Balanced braces pass the bounded structural preflight. The algorithm value is missing.
        try Data(#"{"algorithm":,"formatMajor":1}"#.utf8).write(to: file)
        await model.importFile(file, recipes: false)
        XCTAssertEqual(model.error, .malformed)
        XCTAssertNotNil(model.actionOutcomeID)
        XCTAssertNil(model.review)
        XCTAssertEqual(model.currentRecords, [live])
        XCTAssertEqual(model.recoveredRecords, recovered)
        XCTAssertEqual(try Data(contentsOf: manifest), before)
    }
    @MainActor func testUnsupportedNativeImportStagesNothingAndPreservesRegistryBytes() async throws {
        let directory = try temporaryDirectory(), registry = try RecoveryRegistry(url: directory.appendingPathComponent("manifest.json"))
        let record = try comparison()
        let initial = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "fixture", revision: "first")
        _ = try await registry.apply(registry.review(initial))
        let before = try Data(contentsOf: directory.appendingPathComponent("manifest.json"))
        var corrupt = record
        corrupt.id = UUID().uuidString
        let archive = try ArchiveCodec.make(records: [corrupt], kind: .personalRecovery, origin: "fixture", revision: "bad")
        let file = directory.appendingPathComponent("bad.json")
        try ArchiveCodec.encode(archive).write(to: file)
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.importFile(file, recipes: false)
        XCTAssertNil(model.review)
        XCTAssertNotNil(model.error)
        XCTAssertEqual(try Data(contentsOf: directory.appendingPathComponent("manifest.json")), before)
    }
    @MainActor func testFileImportRechecksAccessBeforeValidatingExternalContents() async throws {
        let directory = try temporaryDirectory()
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("manifest.json"))
        let archive = try ArchiveCodec.make(records: [comparison()], kind: .personalRecovery,
            origin: "fixture", revision: "external")
        let file = directory.appendingPathComponent("external.json")
        try ArchiveCodec.encode(archive).write(to: file)

        var checks = 0
        var validations = 0
        let model = RecordsToolsModel(registry: registry, snapshot: { .init() },
            validateNativePayload: { _ in validations += 1 }, openRecovered: { _ in }, beginAuthorization: {
                { checks += 1; return checks == 1 }
            })
        await model.importFile(file, recipes: false)

        XCTAssertEqual(validations, 0)
        XCTAssertNil(model.review)
        XCTAssertEqual(model.error, .unavailable)
        let saved = try await registry.refreshList()
        XCTAssertTrue(saved.isEmpty)
    }

    @MainActor func testIdenticalBatchReopensOnlyItsExistingCopyIDsAmongMatchingTitles() async throws {
        let directory = try temporaryDirectory()
        let registryURL = directory.appendingPathComponent("registry.json")
        let registry = try RecoveryRegistry(url: registryURL)
        let first = try comparison(), second = try comparison(), unrelated = try comparison()
        XCTAssertEqual(first.title, second.title)
        XCTAssertEqual(first.title, unrelated.title)
        let existing = try ArchiveCodec.make(records: [first, unrelated], kind: .helperShop, origin: "fixture", revision: "initial")
        _ = try await registry.apply(registry.review(existing))
        let file = directory.appendingPathComponent("batch.json")
        let batch = try ArchiveCodec.make(records: [first, second], kind: .helperShop, origin: "fixture", revision: "batch")
        try ArchiveCodec.encode(batch).write(to: file)
        let model = RecordsToolsModel(registry: registry, snapshot: { .init() }, validateNativePayload: { _ in },
                                    openRecovered: { _ in XCTFail("Helper copies open in the disclosure") })

        await model.importFile(file, recipes: false)
        await model.applyReviewedImport()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.lastImportIDs.count, 1)
        XCTAssertTrue(model.reopenedCopyIDs.isEmpty)
        let saved = try await registry.refreshList()
        let expected = Set(saved.filter { $0.record.id == first.id || $0.record.id == second.id }.map(\.id))
        XCTAssertEqual(saved.count, 3)
        XCTAssertEqual(expected.count, 2)
        let before = try Data(contentsOf: registryURL)

        await model.importFile(file, recipes: false)
        await model.applyReviewedImport()
        XCTAssertNil(model.error)
        XCTAssertEqual(model.reopenedCopyIDs, expected)
        XCTAssertTrue(model.lastImportIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
        model.invalidateForSourceErasure()
        XCTAssertTrue(model.reopenedCopyIDs.isEmpty)
        XCTAssertTrue(model.recoveredRecords.isEmpty)

        let empty = try ArchiveCodec.make(records: [], kind: .helperShop, origin: "fixture", revision: "empty")
        try ArchiveCodec.encode(empty).write(to: file)
        await model.importFile(file, recipes: false)
        await model.applyReviewedImport()
        XCTAssertEqual(model.status, recordsText("This file contains no records to recover."))
        XCTAssertTrue(model.reopenedCopyIDs.isEmpty)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }

    @MainActor func testRecipeImportWithOnlyDuplicatesAndSkippedRowsPublishesANewOutcome() async throws {
        let directory = try temporaryDirectory()
        let registryURL = directory.appendingPathComponent("manifest.json")
        let registry = try RecoveryRegistry(url: registryURL)
        let model = RecordsToolsModel(registry: registry, snapshot: { .init() }, validateNativePayload: { _ in }, openRecovered: { _ in })
        let file = directory.appendingPathComponent("recipes.json")
        try Data(#"""
        {"@graph":[
            {"@type":"Recipe","name":"Fictional rice","recipeIngredient":["2 cups rice"]},
            {"@type":"Recipe","nutrition":{"calories":"not imported"}}
        ]}
        """#.utf8).write(to: file)

        await model.importFile(file, recipes: true)
        XCTAssertNotNil(model.review)
        await model.applyReviewedImport()
        let previousOutcome = try XCTUnwrap(model.actionOutcomeID)
        let before = try Data(contentsOf: registryURL)

        await model.importFile(file, recipes: true)

        XCTAssertNil(model.review)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.recipeReport?.duplicateCount, 1)
        XCTAssertEqual(model.recipeReport?.skippedRows, 1)
        XCTAssertEqual(model.recipeReport?.unsupportedFields, ["nutrition"])
        XCTAssertEqual(model.status, [
            recordsText("No new recipes were saved."),
            "0 " + recordsText("recipes ready") + " · 1 " + recordsText("duplicate") + " · 1 " + recordsText("row skipped"),
            recordsText("Unsupported fields: ") + "nutrition"
        ].joined(separator: "\n"))
        XCTAssertNotNil(model.actionOutcomeID)
        XCTAssertNotEqual(model.actionOutcomeID, previousOutcome)
        XCTAssertEqual(try Data(contentsOf: registryURL), before)
    }
    @MainActor private final class RecipeLedgerLifetime {
        weak var owner: LedgerModel?
        func released() async -> Bool {
            let deadline = ContinuousClock.now + .seconds(2)
            while owner != nil && ContinuousClock.now < deadline { await Task.yield() }
            return owner == nil
        }
    }

    @MainActor func testFailedRecipeImportPreservesEditableDinnerAndWeeklyAllocationsAcrossRestart() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let lifetime = RecipeLedgerLifetime()
        addTeardownBlock {
            guard await lifetime.released() else { return XCTFail("The reopened ledger still owns its SQLite files") }
            try FileManager.default.removeItem(at: directory)
        }
        let ledgerURL = directory.appendingPathComponent("ledger.sqlite")
        let registryURL = directory.appendingPathComponent("recipes.json")
        let file = directory.appendingPathComponent("picked-recipe.json")
        let now = Date(timeIntervalSince1970: 1_793_664_000)
        let weekStart = try MealDay(year: 2026, month: 11, day: 2, timeZoneIdentifier: "UTC")
        let dinnerDay = try MealDay(year: 2026, month: 11, day: 4, timeZoneIdentifier: "UTC")
        let dinner = ServingGroup(name: "Dinner", servings: try Rational(2))
        let lunch = ServingGroup(name: "Protected lunch", servings: .one, isProtected: true)
        let recipe = MealTemplate(title: "Our lentil wraps", servings: try Rational(3),
            ingredients: [MealIngredient(name: "Wraps", quantity: Quantity(amount: try Rational(6), unit: .count, originalLiteral: "6"))],
            notes: "Warm the wraps and set aside lunch before serving.", sourceURL: "https://vanished-recipe.invalid/lentil-wraps",
            servingGroups: [dinner, lunch])
        let planned = PlannedDinner(template: recipe, day: dinnerDay)
        let sourceID = try XCTUnwrap(planned.contributionIDs.first)
        let bindings = [
            DinnerPortionBinding(occurrenceID: planned.occurrenceID, contributionID: sourceID, groupID: dinner.id,
                quantity: Quantity(amount: try Rational(4), unit: .count, originalLiteral: "4"), servings: dinner.servings),
            DinnerPortionBinding(occurrenceID: planned.occurrenceID, contributionID: sourceID, groupID: lunch.id,
                quantity: Quantity(amount: try Rational(2), unit: .count, originalLiteral: "2"), servings: lunch.servings)
        ]
        let valid = #"{"@type":"Recipe","name":"Fictional lentil soup","recipeIngredient":["2 cups lentils"]}"#
        // Balanced delimiters let the malformed second node reach the JSON parser.
        try Data(#"{"@graph":[\#(valid),not_json]}"#.utf8).write(to: file)

        func planningModel(_ ledger: LedgerModel, workspaceID: UUID) -> DinnerFeatureModel {
            DinnerFeatureModel(store: ledger, access: { shopID in
                DinnerAccessContext(scope: .local(workspaceID: workspaceID), actorID: "local", shopID: shopID,
                    assignedShopperID: "local", canPlan: true, canReadBudget: true, hasPaidTools: false,
                    roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(60))
            }, phase: { _ in .draft }, clock: { now })
        }
        func recordsModel(_ ledger: LedgerModel, registry: RecoveryRegistry) -> RecordsToolsModel {
            RecordsToolsModel(registry: registry, snapshot: { .init() }, validateNativePayload: { try RecordsNativeCodec.validate($0) },
                openRecovered: { _ in XCTFail("Recipe preview must not open a recovered record") },
                beginAuthorization: { [weak ledger] in { [weak ledger] in ledger?.ready == true } })
        }

        let workspaceID: UUID, revision: Int64
        let workspace: LedgerWorkspace, savedWeek: DinnerMealWeek
        let ledgerBytes: Data, registryBytes: Data
        do {
            let ledger = LedgerModel(databaseURL: ledgerURL, clock: { now })
            lifetime.owner = ledger
            await ledger.open()
            let started = await ledger.startShop(title: "Wednesday pickup")
            XCTAssertTrue(started)
            workspaceID = try XCTUnwrap(ledger.sourceWorkspaceID)
            let savedTemplate = await ledger.change(key: "template-\(recipe.id)") { $0.mealTemplates.append(recipe) }
            XCTAssertTrue(savedTemplate)
            let planning = planningModel(ledger, workspaceID: workspaceID)
            XCTAssertTrue(planning.prepare([.choose(planned)]))
            let chosen = await planning.applyPreview()
            XCTAssertTrue(chosen)
            let bound = await planning.saveBindings(bindings, occurrenceID: planned.occurrenceID)
            XCTAssertTrue(bound)

            workspace = ledger.workspace
            revision = ledger.revision
            ledgerBytes = try ledger.exportPayload()
            savedWeek = try planning.week(start: weekStart)
            let dated = try XCTUnwrap(savedWeek.days.first { $0.day == dinnerDay })
            XCTAssertEqual(dated.meals.map(\.id), [planned.occurrenceID])
            XCTAssertEqual(dated.meals.first?.templateID, recipe.id)
            XCTAssertEqual(dated.meals.first?.ingredientContributionIDs, [sourceID])
            XCTAssertEqual(dated.meals.first?.sourceURL, recipe.sourceURL)
            XCTAssertEqual(workspace.dinnerPlanning.portionBindings, bindings)

            let registry = try RecoveryRegistry(url: registryURL)
            let existing = try ImportedRecipe(title: "Existing saved recipe").archiveRecord(origin: "recipe-library-v1", savedAt: now)
            let envelope = try ArchiveCodec.make(records: [existing], kind: .personalRecovery,
                origin: existing.origin, revision: existing.revision)
            _ = try await registry.apply(registry.review(envelope), now: now)
            registryBytes = try Data(contentsOf: registryURL)
            let records = recordsModel(ledger, registry: registry)
            await records.importFile(file, recipes: true)

            XCTAssertEqual(records.error, .malformed)
            XCTAssertNil(records.review)
            XCTAssertNil(records.recipeReport)
            XCTAssertTrue(records.lastImportIDs.isEmpty)
            XCTAssertEqual(try Data(contentsOf: registryURL), registryBytes)
            XCTAssertEqual(ledger.workspace, workspace)
            XCTAssertEqual(ledger.revision, revision)
            XCTAssertEqual(try ledger.exportPayload(), ledgerBytes)
        }

        guard await lifetime.released() else { return XCTFail("The original ledger must release its SQLite store before reopening") }
        let reopened = LedgerModel(databaseURL: ledgerURL, clock: { now })
        lifetime.owner = reopened
        await reopened.open()
        XCTAssertEqual(reopened.sourceWorkspaceID, workspaceID)
        XCTAssertEqual(reopened.workspace, workspace)
        XCTAssertEqual(reopened.revision, revision)
        XCTAssertEqual(try reopened.exportPayload(), ledgerBytes)
        let planning = planningModel(reopened, workspaceID: workspaceID)
        XCTAssertEqual(try planning.week(start: weekStart), savedWeek)
        XCTAssertEqual(planning.state.portionBindings, bindings)

        let registry = try RecoveryRegistry(url: registryURL)
        let records = recordsModel(reopened, registry: registry)
        try Data(valid.utf8).write(to: file)
        await records.importFile(file, recipes: true)
        XCTAssertNil(records.error)
        XCTAssertEqual(records.review?.rows.map(\.disposition), [.absent])
        XCTAssertEqual(records.recipeReport?.recipes.map(\.title), ["Fictional lentil soup"])
        records.cancelReview()
        XCTAssertNil(records.review)
        XCTAssertNil(records.recipeReport)
        XCTAssertEqual(try Data(contentsOf: registryURL), registryBytes)
        XCTAssertEqual(try reopened.exportPayload(), ledgerBytes)

        let reopenedRecipe = try XCTUnwrap(reopened.workspace.mealTemplates.first)
        XCTAssertEqual(reopenedRecipe, recipe)
        var draft = DinnerTemplateDraft(reopenedRecipe)
        draft.notes = "Warm the wraps, then pack the protected lunch."
        let edited = try draft.template()
        let savedEdit = await reopened.change(key: "template-\(edited.id)") { candidate in
            let index = try XCTUnwrap(candidate.mealTemplates.firstIndex { $0.id == edited.id })
            candidate.mealTemplates[index] = edited
        }
        XCTAssertTrue(savedEdit)
        XCTAssertEqual(reopened.workspace.mealTemplates, [edited])
        XCTAssertEqual(edited.sourceURL, recipe.sourceURL)
        XCTAssertEqual(edited.revision, recipe.revision + 1)
        XCTAssertEqual(reopened.revision, revision + 1)
        XCTAssertEqual(try planning.week(start: weekStart), savedWeek)
        XCTAssertEqual(planning.state.portionBindings, bindings)
    }
    @MainActor func testWholeLedgerErasurePurgesAllReviewedHistoryAndRecoveryOriginOnly() async throws {
        let directory = try temporaryDirectory(), url = directory.appendingPathComponent("ledger.sqlite")
        let model = LedgerModel(databaseURL: url)
        await model.open()
        let first = await model.startShop(title: "Tuesday"); XCTAssertTrue(first)
        let second = await model.startShop(title: "Friday"); XCTAssertTrue(second)
        let template = MealTemplate(title: "Rice", ingredients: [], notes: "Private usual dinner")
        let added = await model.change(key: "template") { $0.mealTemplates.append(template) }; XCTAssertTrue(added)
        let review = try await model.reviewWholeLedgerDeletion()
        XCTAssertEqual(review.shopCount, 2); XCTAssertEqual(review.reusableDinnerCount, 1)
        let source = "ledger/" + review.workspaceID.uuidString
        let old = ArchiveRecord(id: model.workspace.shops[0].id.uuidString, origin: source, revision: "old", kind: .ledger,
            title: "Tuesday", savedAtMilliseconds: 100, helperLines: [HelperLine(label: "private rice")])
        let envelope = try ArchiveCodec.make(records: [old], kind: .helperShop, origin: source, revision: "old")
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("recovery.json"))
        _ = try await registry.apply(registry.review(envelope))
        let comparisonStore = try ComparisonStore(url: directory.appendingPathComponent("comparisons.sqlite"))
        let comparisonID = UUID()
        try await comparisonStore.save(id: comparisonID, title: "Keep", payload: Data("retained".utf8), savedAt: Date())
        let deleted = try await model.eraseWholeLedger(review)
        XCTAssertFalse(model.ready); XCTAssertTrue(model.hasPendingLedgerDeletion)
        XCTAssertTrue(model.workspace.shops.isEmpty); XCTAssertTrue(model.workspace.mealTemplates.isEmpty)
        let retired = try await model.retiredLedgerWorkspaceIDs()
        try await registry.registerErasedOrigins(retired.map { "ledger/" + $0.uuidString })
        try await model.finishWholeLedgerDeletion()
        XCTAssertTrue(model.ready); XCTAssertFalse(model.hasPendingLedgerDeletion)
        XCTAssertEqual(model.sourceWorkspaceID, deleted.replacementWorkspaceID)
        XCTAssertNotEqual(model.sourceWorkspaceID, review.workspaceID)
        let recovered = try await registry.refreshList(); XCTAssertTrue(recovered.isEmpty)
        let blocked = try await registry.review(envelope); XCTAssertEqual(blocked.rows.first?.disposition, .erased)
        let comparison = try await comparisonStore.load(id: comparisonID); XCTAssertEqual(comparison?.payload, Data("retained".utf8))
        XCTAssertFalse(FileManager.default.fileExists(atPath: url.appendingPathExtension("erase-intent.json").path))
    }
    @MainActor func testConfirmedLedgerDeletionSurvivesRestartAndRetriesOriginalReceiptUntilCleanup() async throws {
        let url = try temporaryDirectory().appendingPathComponent("ledger.sqlite")
        let first = LedgerModel(databaseURL: url, clock: { Date(timeIntervalSince1970: 123) })
        await first.open(); _ = await first.startShop(title: "Original")
        let review = try await first.reviewWholeLedgerDeletion()
        let receipt = try await first.eraseWholeLedger(review)
        let restarted = LedgerModel(databaseURL: url, clock: { Date(timeIntervalSince1970: 999) })
        await restarted.open()
        XCTAssertFalse(restarted.ready); XCTAssertTrue(restarted.hasPendingLedgerDeletion)
        XCTAssertEqual(restarted.pendingLedgerDeletionReview, review)
        let retry = try await restarted.retryWholeLedgerDeletion()
        XCTAssertEqual(retry.operationID, receipt.operationID)
        XCTAssertEqual(retry.erasedAt, receipt.erasedAt)
        XCTAssertEqual(retry.replacementWorkspaceID, receipt.replacementWorkspaceID)
        let prevented = await restarted.startShop(title: "Cannot enter before cleanup"); XCTAssertFalse(prevented)
        try await restarted.finishWholeLedgerDeletion()
        let created = await restarted.startShop(title: "New work"); XCTAssertTrue(created)
        let currentID = restarted.sourceWorkspaceID
        // An old model retries the original intent; this cannot erase the new work.
        let late = try await first.retryWholeLedgerDeletion()
        XCTAssertEqual(late.operationID, receipt.operationID)
        try await first.finishWholeLedgerDeletion()
        XCTAssertEqual(first.sourceWorkspaceID, currentID)
        XCTAssertEqual(first.workspace.shops.map(\.title), ["New work"])
    }
    @MainActor func testStaleEntireLedgerReviewDeletesNothingAndAllowsFreshReview() async throws {
        let url = try temporaryDirectory().appendingPathComponent("ledger.sqlite")
        let actual = LedgerModel(databaseURL: url)
        await actual.open(); _ = await actual.startShop(title: "Earlier")
        let review = try await actual.reviewWholeLedgerDeletion()
        _ = await actual.startShop(title: "Newer")
        do { _ = try await actual.eraseWholeLedger(review); XCTFail("Stale review cannot erase newer work") }
        catch LedgerDeletionError.staleReview {}
        XCTAssertTrue(actual.ready); XCTAssertFalse(actual.hasPendingLedgerDeletion)
        XCTAssertEqual(actual.workspace.shops.map(\.title), ["Earlier", "Newer"])
        let retired = try await actual.retiredLedgerWorkspaceIDs(); XCTAssertTrue(retired.isEmpty)
        let fresh = try await actual.reviewWholeLedgerDeletion(); XCTAssertGreaterThan(fresh.revision, review.revision)
    }
    @MainActor func testFailedDeletionIntentWriteNeverCallsDestructiveStoreOperation() async throws {
        let url = try temporaryDirectory().appendingPathComponent("ledger.sqlite")
        let actual = LedgerModel(databaseURL: url)
        await actual.open(); _ = await actual.startShop(title: "Keep me")
        let review = try await actual.reviewWholeLedgerDeletion()
        let bytes = try actual.exportPayload()
        try FileManager.default.createDirectory(at: url.appendingPathExtension("erase-intent.json"), withIntermediateDirectories: false)
        do { _ = try await actual.eraseWholeLedger(review); XCTFail("An intent must be durable before deletion") } catch {}
        XCTAssertTrue(actual.ready); XCTAssertFalse(actual.hasPendingLedgerDeletion)
        XCTAssertEqual(try actual.exportPayload(), bytes)
        let retired = try await actual.retiredLedgerWorkspaceIDs(); XCTAssertTrue(retired.isEmpty)
    }
    @MainActor func testRetiredModelCannotSaveOldWorkspaceIntoReplacement() async throws {
        let url = try temporaryDirectory().appendingPathComponent("ledger.sqlite")
        let stale = LedgerModel(databaseURL: url)
        await stale.open(); _ = await stale.startShop(title: "Old private shop")
        let review = try await stale.reviewWholeLedgerDeletion()
        let other = try LedgerStore(url: url)
        _ = try await other.eraseWorkspace(workspaceID: review.workspaceID, expectedRevision: review.revision, operationID: UUID(), at: Date())
        let replacement = try LedgerStore(url: url)
        let freshShop = ShoppingLedger(title: "New source")
        let payload = try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: LedgerWorkspace(shops: [freshShop], selectedShopID: freshShop.id)))
        try await replacement.save(payload: payload, expectedRevision: 0, operationID: UUID(), savedAt: Date())
        let attempted = await stale.startShop(title: "Unsaved old edit")
        XCTAssertFalse(attempted); XCTAssertFalse(stale.hasPendingSave)
        XCTAssertTrue(stale.ready)
        XCTAssertEqual(stale.sourceWorkspaceID, replacement.workspaceID)
        XCTAssertEqual(stale.workspace.shops.map(\.title), ["New source"])
        let current = try await replacement.load(); XCTAssertEqual(current?.payload, payload)
    }
    @MainActor func testHelperOnlyImportReconcilesRetiredOriginBeforeReview() async throws {
        let directory = try temporaryDirectory(), registry = try RecoveryRegistry(url: directory.appendingPathComponent("recovery.json"))
        let record = ArchiveRecord(id: "old-shop", origin: "ledger/retired", revision: "old", kind: .recipe,
            title: "Erased source", savedAtMilliseconds: 100, helperLines: [HelperLine(label: "Erased rice")])
        let envelope = try ArchiveCodec.make(records: [record], kind: .helperShop, origin: record.origin, revision: "old")
        let file = directory.appendingPathComponent("helper.json"); try ArchiveCodec.encode(envelope).write(to: file)
        var validated = 0
        let tools = RecordsToolsModel(registry: registry, snapshot: { .init() }, validateNativePayload: { _ in
            validated += 1
            try await registry.registerErasedOrigins(["ledger/retired"])
        }, openRecovered: { _ in })
        await tools.importFile(file, recipes: false)
        XCTAssertEqual(validated, 1)
        XCTAssertEqual(tools.review?.rows.first?.disposition, .erased)
        XCTAssertFalse(tools.review?.canApply ?? true)
        let all = try await registry.refreshList(); XCTAssertTrue(all.isEmpty)
    }

    @MainActor func testScopedDinnerPlanningRecoveryRetainsSourceReferencesWithoutAuthority() throws {
        let now = Date(timeIntervalSince1970: 100), origin = UUID()
        var selected = ShoppingLedger(title: "Selected pickup")
        let other = ShoppingLedger(title: "Other pickup")
        func access(_ shop: UUID, workspace: UUID? = nil) -> DinnerAccessContext {
            DinnerAccessContext(scope: .local(workspaceID: workspace ?? origin), actorID: "owner", shopID: shop,
                assignedShopperID: "owner", canPlan: true, canReadBudget: true, hasPaidTools: true,
                roleRevision: 0, verifiedAt: now, validUntil: now.addingTimeInterval(3600))
        }
        let first = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Rice", sourceURL: "https://example.invalid/original"), acceptedAt: now)
        let second = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Beans"), acceptedAt: now)
        let unrelated = AcceptedDinner(id: UUID(), template: MealTemplate(title: "Unselected private dinner"), acceptedAt: now)
        var planning = DinnerPlanningState()
        for dinner in [first, second, unrelated] { try planning.accept(dinner, access: access(selected.id), at: now) }
        let rotation = DinnerRotation(title: "Usual week", entries: [DinnerRotationEntry(acceptedDinnerID: unrelated.id, dayOffset: 2)])
        try planning.saveRotation(rotation, access: access(selected.id), at: now)
        let chosen = PlannedDinner(acceptedDinnerID: first.id, template: first.template)
        let preview = try DinnerPlanningEngine.preview(changes: [.choose(chosen)], tool: .reusableDinner,
            ledger: selected, state: planning, access: access(selected.id), phase: .draft, at: now)
        _ = try DinnerPlanningEngine.apply(preview.proposal, ledger: &selected, state: &planning, access: access(selected.id), phase: .draft, at: now)
        let day = try MealDay(year: 2026, month: 11, day: 3, timeZoneIdentifier: "America/New_York")
        let selectedNote = DinnerWeekNote(shopID: selected.id, day: day, kind: .guests, text: "Two guests")
        let hiddenNote = DinnerWeekNote(shopID: other.id, day: day, kind: .away, text: "Other private plan")
        try planning.recordWeekNote(selectedNote, access: access(selected.id), at: now)
        try planning.recordWeekNote(hiddenNote, access: access(other.id), at: now)
        let commitments = DinnerCommitmentSet(commitments: [DinnerCommitment(name: "Dinner", kind: .dinner, portions: .one)])
        let context = CheckoutContext(storeID: "Store", branchID: "Branch", mode: .pickup, slot: "5 PM", commitmentsID: commitments.id, observedAt: now, source: "Manual quote")
        let quote = CheckoutQuote(scope: .wholeCheckout, context: context, pricing: .inclusiveTotal(.exact(.zero)))
        let trip = StoreTripEvidence(incrementalCash: .exact(.zero), extraMinutes: 0, tripAlreadyPlanned: true)
        let pair = TwoStoreQuotePair(shopID: selected.id, baseRevisionID: selected.revisionID, basisRevision: selected.basisRevision,
            first: StoreQuoteOption(label: "A", commitments: commitments, quote: quote, available: true, quantitiesMatched: true, trip: trip),
            second: StoreQuoteOption(label: "B", commitments: commitments, quote: quote, available: true, quantitiesMatched: true, trip: trip))
        try planning.saveQuotePair(pair, access: access(selected.id), at: now)
        let pending = try DinnerPlanningEngine.preview(changes: [.choose(PlannedDinner(acceptedDinnerID: second.id, template: second.template))], tool: .manual,
            ledger: selected, state: planning, access: access(selected.id), phase: .draft, at: now)
        try planning.saveProposal(pending.proposal, access: access(selected.id), at: now)
        let workspace = LedgerWorkspace(shops: [selected, other], selectedShopID: selected.id, dinnerPlanning: planning)
        try workspace.validate()
        let scoped = try RecordsNativeCodec.ledgerScope(workspace, shop: selected)
        XCTAssertEqual(scoped.dinnerPlanning.acceptedDinners.map(\.id), [first.id, second.id])
        XCTAssertEqual(scoped.dinnerPlanning.weekNotes, [selectedNote])
        XCTAssertEqual(scoped.dinnerPlanning.quotePairs, [pair])
        XCTAssertEqual(scoped.dinnerPlanning.proposals, [pending.proposal])
        XCTAssertEqual(scoped.dinnerPlanning.applyReceipts.first?.proposal.id, preview.proposal.id)
        XCTAssertEqual(scoped.dinnerPlanning.acceptedDinners.first?.template.sourceURL, first.template.sourceURL)
        XCTAssertTrue(scoped.dinnerPlanning.rotations.isEmpty)
        let library = try XCTUnwrap(RecordsNativeCodec.ledgerLibrary(workspace))
        XCTAssertEqual(library.dinnerPlanning.acceptedDinners, planning.acceptedDinners)
        XCTAssertEqual(library.dinnerPlanning.rotations, [rotation])
        XCTAssertTrue(library.shops.isEmpty); XCTAssertTrue(library.dinnerPlanning.proposals.isEmpty)
        let bytes = try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: scoped))
        let record = ArchiveRecord(id: selected.id.uuidString, origin: "ledger/" + origin.uuidString, revision: ArchiveCodec.digest(bytes), kind: .ledger,
            title: selected.title, savedAtMilliseconds: 100_000, nativePayload: bytes)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        let restored = try RecordsNativeCodec.ledger(bytes)
        var restoredShop = restored.shops[0], restoredPlanning = restored.dinnerPlanning
        XCTAssertThrowsError(try DinnerPlanningEngine.apply(pending.proposal, ledger: &restoredShop, state: &restoredPlanning,
            access: access(selected.id, workspace: UUID()), phase: .draft, at: now)) { XCTAssertEqual($0 as? DinnerPlanningError, .forbidden) }
        XCTAssertEqual(restoredShop, restored.shops[0]); XCTAssertEqual(restoredPlanning, restored.dinnerPlanning)
    }
    @MainActor func testEarlierLedgerV1DefaultsPlanningButRejectsInjectedAccessFlags() throws {
        let shop = ShoppingLedger(title: "Earlier v1")
        let workspace = LedgerWorkspace(shops: [shop], selectedShopID: shop.id)
        let current = try RecordsNativeCodec.canonical(LedgerFixture(formatVersion: 1, workspace: workspace))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        var body = try XCTUnwrap(object["workspace"] as? [String: Any])
        body.removeValue(forKey: "dinnerPlanning"); object["workspace"] = body
        let earlier = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        var record = ArchiveRecord(id: shop.id.uuidString, origin: "ledger/old", revision: ArchiveCodec.digest(earlier), kind: .ledger,
            title: shop.title, savedAtMilliseconds: 100, nativePayload: earlier)
        XCTAssertNoThrow(try RecordsNativeCodec.validate(record))
        XCTAssertEqual(try RecordsNativeCodec.ledger(earlier).dinnerPlanning, DinnerPlanningState())
        object = try XCTUnwrap(JSONSerialization.jsonObject(with: current) as? [String: Any])
        body = try XCTUnwrap(object["workspace"] as? [String: Any])
        var planning = try XCTUnwrap(body["dinnerPlanning"] as? [String: Any])
        planning["hasPaidTools"] = true; planning["sharedCommitAuthorized"] = true
        body["dinnerPlanning"] = planning; object["workspace"] = body
        record.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try RecordsNativeCodec.validate(record)) { XCTAssertEqual($0 as? ArchiveError, .unsupportedRecord) }
    }

}
