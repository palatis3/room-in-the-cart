import XCTest
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
    @MainActor private func comparison() throws -> ArchiveRecord {
        var draft = ComparisonDraft()
        draft.item = "Arroz"; draft.needed = "2"; draft.unit = .count
        draft.aLabel = "Original A"; draft.aQuantity = "1"; draft.aPrice = "3.49"
        draft.bLabel = "Original B"; draft.bQuantity = "2"; draft.bPrice = "5.00"
        let request = try ComparisonModel(draft: draft).request()
        let payload = SavedPayload(draft: draft, calculationVersion: SavedPayload.currentCalculationVersion,
            normalizedRequest: request, answer: try PackComparison.evaluate(request), roundingPolicy: SavedPayload.currentRoundingPolicy)
        let data = try RecordsNativeCodec.canonical(payload)
        return ArchiveRecord(id: draft.id.uuidString, origin: "comparisons/fixture", revision: ArchiveCodec.digest(data),
            kind: .comparison, title: draft.item, savedAtMilliseconds: 1_800_000_000_000,
            helperLines: [HelperLine(label: draft.item, originalAmount: draft.needed, originalUnit: "count")], nativePayload: data)
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
        let preview = shop.stageImport(text: original, source: .paste)
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
        let model = RecordsToolsModel(registry: registry, snapshot: { [record] }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
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
    @MainActor func testSourceErasureBetweenSelectionAndExportCannotExportCachedPrivateData() async throws {
        let record = try comparison(), registry = try RecoveryRegistry(url: temporaryDirectory().appendingPathComponent("manifest.json"))
        var sources = [record]
        let model = RecordsToolsModel(registry: registry, snapshot: { sources }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh(); model.selectAll()
        sources = []
        await model.prepareExport(.ownerText)
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(model.error, .unavailable)
        XCTAssertTrue(model.currentRecords.isEmpty)
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
        let model = RecordsToolsModel(registry: registry, snapshot: { [record] }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
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
        let model = RecordsToolsModel(registry: registry, snapshot: { [] },
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

    @MainActor func testRecipeImportWithOnlyDuplicatesAndSkippedRowsPublishesANewOutcome() async throws {
        let directory = try temporaryDirectory()
        let registryURL = directory.appendingPathComponent("manifest.json")
        let registry = try RecoveryRegistry(url: registryURL)
        let model = RecordsToolsModel(registry: registry, snapshot: { [] }, validateNativePayload: { _ in }, openRecovered: { _ in })
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
        let tools = RecordsToolsModel(registry: registry, snapshot: { [] }, validateNativePayload: { _ in
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
