import CryptoKit
import DeviceSurfaces
import HouseholdClient
import XCTest
import CoreDomain
import LocalStore
import RecordArchive
@testable import RoomInTheCart

@MainActor final class PantryArchiveWorkerTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let directory: URL
        let cleanup: SQLiteFixtureDirectory
        let store: ComparisonStore
        let ledger: LedgerStore
        let pending: PantryPickupPendingStore
        let gate: PantryMutationGate
        let worker: PantryArchiveWorker
        let capture: PantryArchiveCapture
    }
    private func fixture(count: Int = 1) async throws -> Fixture {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pickup.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: directory.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(store, ledger)
        let pending = try PantryPickupPendingStore(directory: directory.appendingPathComponent("pending"),
            inventoryWorkspaceID: store.workspaceID, ledgerWorkspaceID: ledger.workspaceID)
        var revision: Int64 = 0
        for start in stride(from: 0, to: count, by: 60) {
            let operation = UUID()
            var writes: [InventoryWrite] = []
            for index in start..<min(start + 60, count) {
                let command = InventoryCommand(id: operation, originID: store.workspaceID, lotID: UUID(), eventID: UUID(),
                    expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: UUID(), name: "Food \(index)",
                        source: .manual(originID: store.workspaceID, sourceID: UUID()), location: .freezer, unit: .count,
                        count: .exact(.init(amount: try Rational(8), unit: .count, originalLiteral: "8"))), observationID: UUID()))
                writes += try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
            }
            let token = revision == 0 ? try await store.inventorySourceToken() : nil
            _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: operation,
                expectedRevision: revision, request: Data(operation.uuidString.utf8), mode: revision == 0 ? .activate : .mutate,
                sourceToken: token, writes: writes), at: now)
            revision += 1
        }
        let gate = PantryMutationGate(), worker = try PantryArchiveWorker(root: directory.appendingPathComponent("archives"))
        return Fixture(directory: directory, cleanup: cleanup, store: store, ledger: ledger, pending: pending, gate: gate, worker: worker,
            capture: .init(inventory: store, ledger: ledger, pending: pending, gate: gate, authorize: { _, _ in true }))
    }
    private func firstLot(_ store: ComparisonStore) async throws -> InventoryLot {
        let rows = try await store.inventoryRecords(kind: .lot, limit: 1)
        return try PantryPersistenceCodec.lot(XCTUnwrap(rows.first))
    }
    private func append(_ command: InventoryCommand, current: InventoryLot, to store: ComparisonStore) async throws {
        let state = try await store.inventoryState()
        let prepared = try InventoryEngine.prepare(command, current: current, at: command.occurredAt)
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: command.id,
            expectedRevision: state.revision, request: PantryPersistenceCodec.request(command, inventoryRevision: state.revision),
            writes: PantryPersistenceCodec.writes(prepared)), at: command.occurredAt)
    }

    private func receiptDraft(_ store: ComparisonStore, document: Bool = false) throws -> ReceiptImportDraft {
        let source = SourceMediaRecord(id: UUID(), target: .init(workspaceID: store.workspaceID, containerID: UUID(),
            objectID: UUID(), revision: 1, kind: .receiptEvidence), originalText: "RICE\nBEANS\nFEE",
            reviewedLabel: "East market", imageJPEG: nil, barcode: nil,
            receiptLines: [.init(originalText: "RICE", reviewedText: "Rice"), .init(originalText: "BEANS", reviewedText: "Beans"),
                           .init(originalText: "FEE")], capturedAt: now)
        let evidence: SourceMediaRecord
        if document {
            let raw = Data(source.originalText.utf8)
            let extracted = ExtractedReceiptDocument(digest: Data(SHA256.hash(data: raw)), pages: [
                .init(id: 1, method: .textFile, lines: source.receiptLines.enumerated().map { .init(id: $0.offset + 1, text: $0.element.originalText) })
            ])
            evidence = try extracted.source(target: source.target, merchant: source.reviewedLabel, stage: .finalInvoice,
                selection: [.init(page: 1, line: 1), .init(page: 1, line: 2), .init(page: 1, line: 3)], at: now)
        } else { evidence = source }
        var draft = try ReceiptImportDraft(source: evidence)
        draft.reference = "transaction-14"
        draft.dateConfirmed = true
        draft.purchaseDate = now
        draft.lines[0].treatment = .add
        draft.lines[0].received = "3"
        draft.lines[0].usable = "2"
        return draft
    }

    func testReviewedLocalWeightedReceiptReopensWithPaidPriceAndActualUsableStockOnlyOnce() async throws {
        let f = try await fixture()
        let repo = PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true })
        f.cleanup.track(repo)
        let raw = "Fecha de compra: 17/11/2024\nPERAS 0,75 kg @ USD 4,00/kg USD 3,00\nDEPÓSITO USD 1,00"
        let extracted = try await ReceiptDocumentReader().extract(.init(data: Data(raw.utf8), kind: .text))
        let target = CaptureTarget(workspaceID: f.store.workspaceID, containerID: UUID(), objectID: UUID(), revision: 0, kind: .receiptEvidence)
        let source = try extracted.source(target: target, merchant: "Mercado", stage: .receipt, selection: Set((1...3).map { .init(page: 1, line: $0) }), at: now)
        var draft = try ReceiptImportDraft(source: source, now: now)
        let state = try await f.store.inventoryState()
        XCTAssertFalse(draft.dateConfirmed); XCTAssertTrue(draft.selectedLines.isEmpty)
        draft.dateConfirmed = true
        draft.lines[1].treatment = .add
        draft.lines[1].usePrintedQuantity()
        XCTAssertTrue(draft.lines[1].usable.isEmpty)
        draft.lines[1].usable = "0.50"; draft.lines[1].location = .fridge
        draft.lines[1].paid = try XCTUnwrap(draft.lines[1].printed?.amount)
        let review = try await repo.reviewReceipt(draft, expected: state, at: now)
        XCTAssertEqual(review.facts.count, 1)
        try await repo.applyReceipt(review, at: now)
        let snapshot = try await repo.load(at: now)
        let saved = try XCTUnwrap(snapshot.lots.first(where: { $0.name == "PERAS" }))
        XCTAssertEqual(saved.location, .fridge)
        XCTAssertEqual(saved.count.quantity?.amount, try Rational(1,2))
        let history = try await repo.acquisitionHistory(receiptID: draft.receiptID)
        let evidence = try XCTUnwrap(history.first)
        XCTAssertEqual(evidence.received.amount, try Rational(3,4))
        XCTAssertEqual(evidence.paidLineTotal?.minorUnits, 300)
        XCTAssertEqual(evidence.originalLine, draft.lines[1].original)
        XCTAssertEqual(evidence.documentLine?.line, 2)
        let replay = try await repo.reviewReceipt(draft, expected: snapshot.state, at: now)
        XCTAssertNil(replay.batch)
    }

    func testConsentedExcerptSuggestionNeedsExplicitReceiptReviewBeforeAcquisitionAndReplay() async throws {
        let f = try await fixture()
        let repo = PantryRepository(store: f.store, aliasPersonaID: UUID(), authorize: { true })
        f.cleanup.track(repo)
        let doc = try await ReceiptDocumentReader().extract(.init(data: Data("Private account 999\nAVENA 2 kg #private-loyalty".utf8), kind: .text))
        let source = try doc.source(target: .init(workspaceID: f.store.workspaceID, containerID: UUID(), objectID: UUID(),
            revision: 1, kind: .receiptEvidence), merchant: "Private Market", stage: .finalInvoice, selection: [.init(page: 1, line: 2)], at: now)
        var draft = try ReceiptImportDraft(source: source)
        let original = try XCTUnwrap(draft.lines.first)
        let input = try ReceiptLineAssistanceRequest(consentingTo: "AVENA 2 kg", page: 1, line: 2)
        let server = S24FixtureServer()
        defer { server.close() }
        let transport = HTTPTransport(session: server.makeSession())
        let auth = AdultAuth(configuration: try .init(projectURL: server.baseURL, publishableKey: "sb_publishable_fixture_only"),
                             vault: S24FixtureVault(), transport: transport)
        let client = HouseholdService(configuration: try .init(baseURL: server.baseURL), auth: auth, deviceVault: S24FixtureVault(), transport: transport)
        _ = try await auth.verifyEmailCode(email: "person@example.invalid", code: "123456")
        _ = try await client.enroll(householdID: S24FixtureServer.household)
        server.intercept = { call in
            guard call.request.url?.path.hasSuffix("/receipt-assistance") == true else { return false }
            do {
                let response: [String: Any]
                if call.request.httpMethod == "GET" {
                    XCTAssertNil(call.request.httpBody)
                    response = ["version": 1, "available": true]
                } else {
                    XCTAssertEqual(call.request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-access")
                    var bytes = call.request.httpBody ?? Data()
                    if bytes.isEmpty, let stream = call.request.httpBodyStream {
                        stream.open()
                        defer { stream.close() }
                        var buffer = [UInt8](repeating: 0, count: 2048)
                        while stream.hasBytesAvailable {
                            let count = stream.read(&buffer, maxLength: buffer.count)
                            guard count > 0 else { break }
                            bytes.append(buffer, count: count)
                        }
                    }
                    let submitted = try JSONDecoder().decode(ReceiptLineAssistanceRequest.self, from: bytes)
                    XCTAssertEqual(submitted, input)
                    let keys = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any]).keys
                    XCTAssertEqual(Set(keys), Set(["version","requestID","issuedAt","consent","text","page","line"]))
                    response = ["version": 1, "requestID": input.requestID.uuidString, "page": 1, "line": 2,
                                "foodName": "Oats", "quantity": "2", "unit": "kilogram"]
                }
                let message = try XCTUnwrap(HTTPURLResponse(url: XCTUnwrap(call.request.url), statusCode: 200, httpVersion: nil, headerFields: nil))
                call.client?.urlProtocol(call, didReceive: message, cacheStoragePolicy: .notAllowed)
                call.client?.urlProtocol(call, didLoad: try JSONSerialization.data(withJSONObject: response))
                call.client?.urlProtocolDidFinishLoading(call)
            } catch { call.client?.urlProtocol(call, didFailWithError: error) }
            return true
        }
        let scope = ReceiptAssistanceScope(subject: "fixture-adult", householdID: S24FixtureServer.household,
            memberID: S24FixtureServer.member, shopID: S24FixtureServer.shop)
        let available = try await client.receiptAssistanceAvailability(scope: scope)
        XCTAssertTrue(available.available)
        let changed = ReceiptAssistanceScope(subject: "another adult", householdID: scope.householdID, memberID: scope.memberID, shopID: scope.shopID)
        do {
            _ = try await client.receiptLineSuggestion(input, scope: changed)
            XCTFail("The excerpt belongs to the reviewed adult")
        } catch { XCTAssertEqual(error as? ClientError, .accessEnded) }
        let proposed = try await client.receiptLineSuggestion(input, scope: scope)
        XCTAssertEqual(draft.lines.first, original)
        let state = try await f.store.inventoryState()
        try draft.lines[0].applyAssisted(proposed, request: input, reviewedLine: original, useReceived: false)
        XCTAssertEqual(draft.lines[0].name, "Oats")
        XCTAssertEqual(draft.lines[0].received, "")
        XCTAssertEqual(draft.lines[0].treatment, .skip)
        XCTAssertEqual(draft.lines[0].original, "AVENA 2 kg #private-loyalty")
        XCTAssertThrowsError(try draft.lines[0].applyAssisted(proposed, request: input, reviewedLine: original, useReceived: true))
        let edited = draft.lines[0]
        try draft.lines[0].applyAssisted(proposed, request: input, reviewedLine: edited, useReceived: true)
        XCTAssertEqual(draft.lines[0].usable, "")
        XCTAssertEqual(draft.lines[0].paid, "")
        XCTAssertFalse(draft.dateConfirmed)
        let uncommitted = try await f.store.inventoryState()
        XCTAssertEqual(uncommitted, state)
        draft.dateConfirmed = true; draft.purchaseDate = now; draft.lines[0].treatment = .add; draft.lines[0].usable = "1"
        let review = try await repo.reviewReceipt(draft, expected: state, at: now)
        XCTAssertEqual(review.facts.first?.documentLine, original.documentLine)
        XCTAssertNil(review.facts.first?.paidLineTotal)
        try await repo.applyReceipt(review, at: now)
        try await repo.applyReceipt(review, at: now)
        let committed = try await repo.load(at: now)
        XCTAssertEqual(committed.lots.count, 2)
        XCTAssertEqual(committed.lots.first(where: { $0.name == "Oats" })?.count.quantity?.amount, .one)
    }

    func testRepeatedReviewedShelfImageKeepsOneSourceAndNoPaidPurchase() async throws {
        let f = try await fixture()
        let repository = PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true })
        f.cleanup.track(repository)
        let wording = "Members only 2 for $5"
        let printed = try PriceImageLine(digest: Data(repeating: 7, count: 32), ordinal: 3, wording: wording, uncertain: true)
        let shelf = PrivatePriceEvidence(id: printed.shelfID, source: .shelf, name: "Cashews", store: "South",
            mode: .inStore, date: now, currencyCode: "CAD", amountMinor: 500, pack: nil, eligibility: wording,
            sourceText: wording, shelfImage: .init(printed: printed, basis: .bundle))
        let initial = try await f.store.inventoryState()
        let lotsBefore = try await f.store.inventoryRecords(kind: .lot)
        try await repository.savePrice(shelf, expected: initial, at: now)
        let page = try await repository.pricePage()
        XCTAssertEqual(page.standalone, [shelf])
        XCTAssertFalse(shelf.isPaidPrice)
        XCTAssertNil(try shelf.unitPrice(in: .gram))
        do {
            try await repository.savePrice(shelf, expected: page.state, at: now)
            XCTFail("The shopper should see that the selected image line is already saved")
        } catch PantryPriceError.imageAlreadySaved {}
        let reopened = try await repository.pricePage()
        let lotsAfter = try await f.store.inventoryRecords(kind: .lot)
        let ledger = try await f.ledger.load()
        XCTAssertEqual(reopened.state, page.state)
        XCTAssertEqual(reopened.standalone, [shelf])
        XCTAssertEqual(lotsBefore, lotsAfter)
        XCTAssertNil(ledger)
    }

    func testReviewedPrivatePriceCorrectionsRestoreAndErasureFencesEarlierExports() async throws {
        let f = try await fixture()
        let repository = PantryRepository(store: f.store, mutationGate: f.gate, authorize: { true })
        f.cleanup.track(repository)
        let id = UUID()
        let unit = Quantity(amount: try Rational(500), unit: .gram, originalLiteral: "500 g")
        func manual(_ revision: Int64, _ minor: Int64) -> PrivatePriceEvidence {
            .init(id: id, revision: revision, source: .paidManual, name: "Rice", variant: "Brown", store: "East market",
                branch: "South", mode: .inStore, date: now, currencyCode: "USD", amountMinor: minor, pack: .init(count: 2, perPackage: unit),
                sourceText: "Reviewed at the till")
        }
        let original = manual(1, 500), corrected = manual(2, 460)
        try await repository.savePrice(original, expected: f.store.inventoryState(), at: now)
        try await repository.savePrice(corrected, expected: f.store.inventoryState(), at: now)
        let credit = PrivatePriceEvidence(id: UUID(), source: .adjustment(target: id, revision: 2, kind: .refund),
            name: "Rice", store: "East market", date: now, currencyCode: "USD", amountMinor: 40, pack: nil, sourceText: "Damaged bag")
        try await repository.savePrice(credit, expected: f.store.inventoryState(), at: now)
        let page = try await repository.pricePage()
        XCTAssertEqual(Set(page.standalone.map(\.id)), [id, credit.id])
        let firstRecorded = try await repository.recordedPriceRevision(corrected, revision: 1, expected: page.state)
        XCTAssertEqual(firstRecorded, original)
        XCTAssertEqual(firstRecorded.mode, .inStore)
        let adjustments = try await repository.priceAdjustments(for: id, expected: page.state)
        XCTAssertEqual(try corrected.unitPrice(in: .kilogram, adjustments: adjustments), try Rational(420))
        let lots = try await f.store.inventoryRecords(kind: .lot)
        let ledger = try await f.ledger.load()
        XCTAssertEqual(lots.count, 1)
        XCTAssertNil(ledger)
        let handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = Data(repeating: 0x41, count: 32).base64EncodedString()
        let bundle = try await f.worker.encryptedExport(handle, key: key)
        let reader = try PantryArchiveWorker(root: f.directory.appendingPathComponent("price-reader"))
        let imported = try await reader.prepareImport(url: bundle.url, key: key)
        let target = try ComparisonStore(url: f.directory.appendingPathComponent("other-price.sqlite"), inventoryEnabled: true)
        f.cleanup.track(target)
        let restored = try await reader.prepareRestoration(source: imported.handle, context: .init(version: 1,
            copyID: UUID(), reference: imported.handle.reference, workspaceID: target.workspaceID,
            restorationID: UUID(), preparedAt: now), sourceToken: target.inventorySourceToken())
        _ = try await target.beginInventoryMigration(restored.plan)
        for index in 0..<restored.plan.expectedChunkCount {
            let chunk = try await reader.restorationChunk(restored, index: index)
            _ = try await target.stageInventoryMigration(id: restored.plan.migrationID, chunk: chunk)
        }
        _ = try await target.finishInventoryMigration(id: restored.plan.migrationID, at: now)
        let priceHistory = try await target.priceRows(id: id, latestOnly: false)
        XCTAssertEqual(try priceHistory.map(PantryPriceCodec.evidence), [original, corrected])
        let credits = try await target.priceRows(adjustmentsFor: id)
        XCTAssertEqual(try credits.map(PantryPriceCodec.evidence), [credit])
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("price-registry.json"))
        let coordinator = eraser(f, registry, cleanup: { _, _ in })
        let reviewed = try await coordinator.prepare(.price(id, revision: 2))
        XCTAssertTrue(reviewed.canCommit)
        XCTAssertEqual(reviewed.priceRevisionCount, 3)
        _ = try await coordinator.commit(reviewed)
        let after = try await repository.pricePage()
        XCTAssertTrue(after.standalone.isEmpty)
        do {
            try await PantryArchivePrivacyValidator.validate(imported.handle, worker: reader, inventory: f.store,
                ledger: f.ledger, gate: f.gate, authorize: { true })
            XCTFail("Reimport must honor a price and its credits erased at the original store")
        } catch PantryArchivePrivacyValidator.Failure.retired {}
        let quote = PrivatePriceEvidence(id: UUID(), source: .currentQuote, name: "Rice", store: "East market",
            mode: .pickup, date: now, currencyCode: "USD", amountMinor: 440, pack: nil, sourceText: "Entered from checkout")
        try await repository.savePrice(quote, expected: after.state, at: now)
        let quoted = try await repository.pricePage()
        XCTAssertEqual(quoted.standalone, [quote])
        XCTAssertFalse(quote.isPaidPrice)
        try await reader.discardRestoration(restored)
        try await reader.discardImport(imported, registry: registry)
        try await f.worker.discardExport(bundle)
    }

    func testReceiptPartialReviewRetryPriceCorrectionRecoveryAndErasure() async throws {
        let f = try await fixture()
        let repository = PantryRepository(store: f.store, aliasPersonaID: UUID(), authorize: { true })
        f.cleanup.track(repository)
        var draft = try receiptDraft(f.store, document: true)
        let state = try await f.store.inventoryState()
        let review = try await repository.reviewReceipt(draft, expected: state, at: now)
        XCTAssertEqual(review.facts.count, 1)
        let first = try XCTUnwrap(review.facts.first)
        XCTAssertNil(first.paidLineTotal)
        XCTAssertEqual(first.documentLine, .init(method: .textFile, stage: .finalInvoice, page: 1, line: 1))
        XCTAssertEqual(first.originalLine, "RICE")
        try await repository.applyReceipt(review, at: now)
        try await repository.applyReceipt(review, at: now)
        let snapshot = try await repository.load(at: now)
        XCTAssertEqual(snapshot.lots.count, 2)
        XCTAssertTrue(snapshot.receiptAcquiredLots.contains(first.lotID))
        let limited = PantryRepository(store: f.store, limits: .init(payloadBytes: snapshot.loadedPayloadBytes - 1, observations: 20),
                                      authorize: { true })
        do { _ = try await limited.load(at: now); XCTFail("Receipt evidence must fit the reviewed read budget") }
        catch InventoryError.capacity {}
        let mapping = try PantryLegacyMigration.map(originID: f.store.workspaceID, heads: [], ledger: .unavailable, at: now)
        let projection = try PantryLiveStockProjection.buildGlobal(snapshot: snapshot, mapping: mapping, at: now)
        XCTAssertEqual(projection.lot(canonicalID: first.lotID)?.free?.amount, try Rational(2))
        let same = try await repository.reviewReceipt(try receiptDraft(f.store, document: true), expected: snapshot.state, at: now)
        XCTAssertNil(same.batch)
        draft.lines[1].treatment = .add
        draft.lines[1].received = "1"
        draft.lines[1].usable = "1"
        draft.lines[1].paid = "4.10"
        let partial = try await repository.reviewReceipt(draft, expected: snapshot.state, at: now)
        XCTAssertEqual(partial.existing, [first.lineID])
        try await repository.applyReceipt(partial, at: now)
        let after = try await repository.load(at: now)
        XCTAssertEqual(after.lots.count, 3)
        let paid = try Money(decimal: "2.14")
        try await repository.correctPaidTotal(first, total: paid, state: after.state, at: now)
        let rows = try await repository.acquisitionHistory(receiptID: draft.receiptID, after: nil, limit: 20)
        XCTAssertEqual(rows.count, 3)
        let corrected = try XCTUnwrap(rows.first(where: { $0.supersedesID == first.id }))
        XCTAssertEqual(corrected.paidLineTotal, paid)
        let receiptPrice = try PrivatePriceEvidence(receipt: corrected)
        let originalPrice = try await repository.recordedPriceRevision(receiptPrice, revision: 1, expected: f.store.inventoryState())
        XCTAssertEqual(originalPrice, try PrivatePriceEvidence(receipt: first))
        try await repository.rememberReceiptAlias(corrected, wording: "RICE", language: "en",
            expected: f.store.inventoryState(), at: now)
        let handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = Data(repeating: 0x37, count: 32).base64EncodedString()
        let package = try await f.worker.encryptedExport(handle, key: key)
        let reader = try PantryArchiveWorker(root: f.directory.appendingPathComponent("receipt-reader"))
        let imported = try await reader.prepareImport(url: package.url, key: key)
        let target = try ComparisonStore(url: f.directory.appendingPathComponent("independent.sqlite"), inventoryEnabled: true)
        f.cleanup.track(target)
        let restore = try await reader.prepareRestoration(source: imported.handle,
            context: .init(version: 1, copyID: UUID(), reference: imported.handle.reference, workspaceID: target.workspaceID, restorationID: UUID(), preparedAt: now),
            sourceToken: target.inventorySourceToken())
        _ = try await target.beginInventoryMigration(restore.plan)
        for index in 0..<restore.plan.expectedChunkCount {
            let chunk = try await reader.restorationChunk(restore, index: index)
            _ = try await target.stageInventoryMigration(id: restore.plan.migrationID, chunk: chunk)
        }
        _ = try await target.finishInventoryMigration(id: restore.plan.migrationID, at: now)
        let restoredAliasCount = try await target.receiptAliasCount()
        XCTAssertEqual(restoredAliasCount, 0)
        let restored = try await target.acquisitionRows(receiptID: draft.receiptID)
        XCTAssertEqual(try restored.map(PantryAcquisitionCodec.record), rows)
        try await reader.discardRestoration(restore)
        let importRegistry = try RecoveryRegistry(url: f.directory.appendingPathComponent("receipt-reader-registry.json"))
        try await reader.discardImport(imported, registry: importRegistry)
        try await f.worker.discardExport(package)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let coordinator = eraser(f, registry, cleanup: { _, _ in })
        let erase = try await coordinator.prepare(.lot(first.lotID, revision: 1))
        XCTAssertTrue(erase.canCommit)
        XCTAssertEqual(erase.aliasCount, 1)
        XCTAssertEqual(erase.receiptRevisionCount, 2)
        _ = try await coordinator.commit(erase)
        let survivingAliases = try await repository.receiptAliases()
        XCTAssertTrue(survivingAliases.isEmpty)
        let remaining = try await f.store.acquisitionRows(receiptID: draft.receiptID)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertNotEqual(remaining.first?.lotID, first.lotID)
        do { try await repository.applyReceipt(review, at: now); XCTFail("An erased receipt cannot be replayed") } catch {}
    }

    func testReceiptBatchProtectsLunchBeforePricingDinnerWithCurrentPackOffer() async throws {
        let f = try await fixture()
        let repository = PantryRepository(store: f.store, authorize: { true })
        f.cleanup.track(repository)
        var draft = try receiptDraft(f.store)
        draft.lines[0].received = "6"
        draft.lines[0].usable = "5"
        draft.lines[0].paid = "9.50"
        let initial = try await f.store.inventoryState()
        let review = try await repository.reviewReceipt(draft, expected: initial, at: now)
        try await repository.applyReceipt(review, at: now)
        let acquired = try XCTUnwrap(review.facts.first)
        let saved = try await repository.load(at: now)
        let lot = try XCTUnwrap(saved.lots.first { $0.id == acquired.lotID })

        func count(_ amount: Int64) throws -> Quantity {
            Quantity(amount: try Rational(amount), unit: .count, originalLiteral: String(amount))
        }
        let lunchID = UUID()
        let hold = InventoryCommand(id: UUID(), originID: f.store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: lot.revision, occurredAt: now, change: .reservation(.reserve(id: lunchID,
                purpose: "Tomorrow's lunch", amount: try count(2), day: nil)))
        let held = try await repository.apply(hold, reviewedInventoryRevision: saved.state.revision, at: now)
        try await repository.applyReceipt(review, at: now)
        let current = try await repository.load(at: now)
        XCTAssertEqual(current.state, held.current.state)
        let mapping = try PantryLegacyMigration.map(originID: f.store.workspaceID, heads: [], ledger: .unavailable, at: now)
        let supply = try DinnerPantrySupply.build(context: .init(snapshot: current, mapping: mapping, asOf: now), shopID: UUID())
        XCTAssertEqual(supply.reservations[lot.foodID]?.filter(\.protected).map(\.id), [lunchID])
        let stock = DinnerLibraryPairings.unreservedLots(canonical: supply).filter { $0.foodID == lot.foodID }
        XCTAssertEqual(stock.map(\.id), [lot.id])
        XCTAssertEqual(stock.first?.usable.amount, try Rational(3))

        let ingredient = MealIngredient(name: "Rice", quantity: try count(5))
        let dinner = AcceptedDinner(id: UUID(), template: .init(title: "Rice bowls", servings: .one,
            ingredients: [ingredient]), acceptedAt: now)
        let meal = DinnerCommitment(name: dinner.template.title, kind: .dinner, portions: .one)
        let commitments = DinnerCommitmentSet(commitments: [meal])
        let demand = DinnerDemand(commitmentID: meal.id, foodID: lot.foodID, name: ingredient.name,
            quantity: ingredient.quantity, acceptedDinnerID: dinner.id, ingredientID: ingredient.id)
        let pack = PackOffer(id: "rice-pair", label: "Two rice portions", usableQuantity: try count(2),
            price: try Money(decimal: "4.00"))
        let context = CheckoutContext(storeID: "East market", branchID: "Main", mode: .pickup, slot: "today",
            commitmentsID: commitments.id, observedAt: now, source: "Current reviewed shelf offer")
        let scenario = DinnerScenario(commitments: commitments, acceptedDinnerIDs: [dinner.id], demands: [demand],
            stock: stock, packs: [.init(foodID: lot.foodID, offer: pack, availability: .confirmed(maximumPacks: 1))],
            baselineComplete: true, fees: [], tax: .exact(.zero), deposits: .exact(.zero), context: context,
            preparation: .init(handsOnMinutes: 5, remainingLeadMinutes: 10, availableMinutes: 20))
        let priced = try DinnerScenarioEngine.evaluate(scenario, acceptedDinners: [dinner])
        let topUp = try XCTUnwrap(priced.packs.first?.result)
        XCTAssertEqual(topUp.amountToBuy, try Rational(2))
        XCTAssertEqual(topUp.packsToBuy, 1)
        XCTAssertEqual(priced.checkout.total.exact?.minorUnits, 400)
        XCTAssertEqual(priced.ingredientValues[meal.id]?.total.minorUnits, 1_000)
        let historical = try await repository.acquisitionHistory(receiptID: acquired.receiptID)
        XCTAssertEqual(historical.map(\.paidLineTotal), [try Money(decimal: "9.50")])
        let afterPricing = try await repository.load(at: now)
        XCTAssertEqual(afterPricing.reservations, current.reservations)
        XCTAssertEqual(afterPricing.state, current.state)
    }

    func testStapleRemindersReadThreeReviewedPurchasesAndRespectPrivateResponses() async throws {
        let f = try await fixture(), persona = UUID()
        let repository = PantryRepository(store: f.store, aliasPersonaID: persona, authorize: { true })
        f.cleanup.track(repository)
        let model = PantryModel(repository: repository, clock: { self.now })
        let calendar = Calendar(identifier: .gregorian)
        var alias: InventoryReceiptAlias?
        for weeks in [3, 2, 1] {
            var draft = try receiptDraft(f.store)
            draft.reference = "rice-week-\(weeks)"
            draft.language = "en"
            draft.purchaseDate = try XCTUnwrap(calendar.date(byAdding: .day, value: -7 * weeks, to: now))
            if let alias { draft.lines[0].use(alias) }
            let state = try await f.store.inventoryState()
            let receipt = try await repository.reviewReceipt(draft, expected: state, at: now)
            try await repository.applyReceipt(receipt, at: now)
            if alias == nil {
                let fact = try XCTUnwrap(receipt.facts.first)
                try await repository.rememberReceiptAlias(fact, wording: "rice", language: "en", expected: f.store.inventoryState(), at: now)
                let aliases = try await repository.receiptAliases(merchant: draft.merchant, language: "en")
                alias = try XCTUnwrap(aliases.first)
            }
        }
        await model.load()
        let start = try await model.reviewStaples(openFoodIDs: [], openLineNames: [], calendar: calendar)
        XCTAssertFalse(start.preferences.enabled)
        XCTAssertTrue(start.prompts.isEmpty)
        try await model.setStaplePrompts(true, review: start)
        let suppressed = try await model.reviewStaples(openFoodIDs: [], openLineNames: ["Rice"], calendar: calendar)
        XCTAssertTrue(suppressed.prompts.isEmpty)
        let current = try await model.reviewStaples(openFoodIDs: [], openLineNames: [], calendar: calendar)
        let question = try XCTUnwrap(current.prompts.first)
        XCTAssertEqual(question.id, alias?.foodID)
        XCTAssertEqual(question.comparablePurchaseDays, 3)
        try await model.answerStaple(.stillHave, prompt: question, review: current)
        let fresh = try await model.reviewStaples(openFoodIDs: [], openLineNames: [], calendar: calendar)
        XCTAssertTrue(fresh.prompts.isEmpty)
        XCTAssertEqual(fresh.state, current.state)
        let purchases = try await repository.acquisitionHistory()
        let anchor = try XCTUnwrap(purchases.first { $0.id == question.latestAcquisitionID })
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("staple-registry.json"))
        let coordinator = eraser(f, registry, cleanup: { _, _ in })
        let erase = try await coordinator.prepare(.lot(anchor.lotID, revision: 1))
        XCTAssertTrue(erase.canCommit)
        _ = try await coordinator.commit(erase)
        let afterErase = try await f.store.staplePreferences(persona: persona)
        XCTAssertTrue(afterErase.enabled)
        XCTAssertTrue(afterErase.answers.isEmpty, "Removing this receipt also removes its reminder answer")
        model.accessLost()
        do { _ = try await model.reviewStaples(openFoodIDs: [], openLineNames: [], calendar: calendar); XCTFail("Revoked read") }
        catch PantryReceiptError.stale {}
    }

    func testReceiptAliasRequiresConsentScopedAcceptanceAndCurrentReview() async throws {
        let f = try await fixture(), persona = UUID()
        let repository = PantryRepository(store: f.store, aliasPersonaID: persona, authorize: { true })
        let other = PantryRepository(store: f.store, aliasPersonaID: UUID(), authorize: { true })
        var draft = try receiptDraft(f.store)
        draft.language = "en"
        let first = try await repository.reviewReceipt(draft, expected: f.store.inventoryState(), at: now)
        try await repository.applyReceipt(first, at: now)
        let confirmed = try XCTUnwrap(first.facts.first)
        let initial = try await repository.receiptAliases()
        XCTAssertTrue(initial.isEmpty)
        let originalState = try await f.store.inventoryState()
        do {
            try await repository.rememberReceiptAlias(confirmed, wording: "IC", language: "en", expected: originalState, at: now)
            XCTFail("A substring inside a different product word must not be learned")
        } catch PantryReceiptError.invalid {}
        try await repository.rememberReceiptAlias(confirmed, wording: "rice", language: "en", expected: originalState, at: now)
        let aliases = try await repository.receiptAliases(merchant: " EAST  market ", language: "en")
        let alias = try XCTUnwrap(aliases.first)
        let unrelated = try await other.receiptAliases(), spanish = try await repository.receiptAliases(merchant: "East market", language: "es")
        let anotherStore = try await repository.receiptAliases(merchant: "West market", language: "en")
        XCTAssertTrue(unrelated.isEmpty && spanish.isEmpty && anotherStore.isEmpty)
        draft.reference = "transaction-15"
        draft.lines[0].use(alias)
        XCTAssertEqual(draft.lines[0].received, "3")
        XCTAssertEqual(draft.lines[0].usable, "2")
        XCTAssertEqual(draft.lines[0].paid, "")
        let basis = try await f.store.inventoryState()
        let next = try await repository.reviewReceipt(draft, expected: basis, at: now)
        XCTAssertEqual(next.facts.first?.foodID, confirmed.foodID)
        XCTAssertNotEqual(next.facts.first?.lotID, confirmed.lotID)
        try await repository.forgetReceiptAliases(aliases, expected: basis, at: now)
        do { try await repository.applyReceipt(next, at: now); XCTFail("A removed spelling invalidates a pending review") }
        catch {}
        let latest = try await f.store.inventoryState()
        do { _ = try await repository.reviewReceipt(draft, expected: latest, at: now); XCTFail("An old match must be reviewed again") }
        catch PantryReceiptError.stale {}
        draft.clearAliases()
        let separate = try await repository.reviewReceipt(draft, expected: latest, at: now)
        XCTAssertNotEqual(separate.facts.first?.foodID, confirmed.foodID)
        let history = try await repository.acquisitionHistory()
        XCTAssertEqual(history, [confirmed])
    }

    func testDuplicateReceiptRejectsDifferentExplicitAliasAndRetainsSavedFoodWhenAliasIsAbsent() async throws {
        let f = try await fixture()
        let repository = PantryRepository(store: f.store, aliasPersonaID: UUID(), authorize: { true })
        f.cleanup.track(repository)
        var first = try receiptDraft(f.store)
        first.language = "en"
        first.lines[0].name = "Long grain rice"

        func save(_ draft: ReceiptImportDraft) async throws -> PantryReceiptReview {
            let state = try await f.store.inventoryState()
            let review = try await repository.reviewReceipt(draft, expected: state, at: now)
            try await repository.applyReceipt(review, at: now)
            return review
        }
        let original = try await save(first)
        var second = first
        second.reference = "transaction-15"
        let secondReview = try await save(second)
        let aliasSource = try XCTUnwrap(secondReview.facts.first)
        XCTAssertNotEqual(original.facts.first?.foodID, aliasSource.foodID)
        let beforeAlias = try await f.store.inventoryState()
        try await repository.rememberReceiptAlias(aliasSource, wording: "RICE", language: "en", expected: beforeAlias, at: now)
        let aliases = try await repository.receiptAliases(merchant: first.merchant, language: first.language)
        let alias = try XCTUnwrap(aliases.first)

        var mixed = first
        mixed.lines[0].use(alias)
        mixed.lines[1].treatment = .add
        mixed.lines[1].received = "1"
        mixed.lines[1].usable = "1"
        mixed.lines.swapAt(0, 1) // The new food is prepared before the conflicting duplicate.
        let beforeConflict = try await f.store.inventoryState()
        do {
            _ = try await repository.reviewReceipt(mixed, expected: beforeConflict, at: now)
            XCTFail("A previously saved line cannot be reassigned to a different same-name food")
        } catch PantryReceiptError.changedEvidence {}
        let afterConflict = try await f.store.inventoryState()
        let firstHistory = try await repository.acquisitionHistory(receiptID: first.receiptID)
        XCTAssertEqual(afterConflict, beforeConflict)
        XCTAssertEqual(firstHistory, original.facts)

        var third = try receiptDraft(f.store)
        third.language = "en"
        third.reference = "transaction-16"
        third.lines[0].use(alias)
        let aliasedReview = try await save(third)
        XCTAssertEqual(aliasedReview.facts.first?.foodID, aliasSource.foodID)
        let beforeForget = try await f.store.inventoryState()
        try await repository.forgetReceiptAliases([alias], expected: beforeForget, at: now)
        third.clearAliases()
        XCTAssertEqual(third.lines[0].name, "Rice")
        let beforeReplay = try await f.store.inventoryState()
        let replay = try await save(third)
        XCTAssertNil(replay.batch)
        XCTAssertEqual(replay.facts, aliasedReview.facts)
        XCTAssertEqual(replay.existing, Set(aliasedReview.facts.map(\.lineID)))
        try await repository.applyReceipt(aliasedReview, at: now)
        let afterReplay = try await f.store.inventoryState()
        XCTAssertEqual(afterReplay, beforeReplay)
        third.lines[0].name = "Jasmine rice"
        do {
            _ = try await repository.reviewReceipt(third, expected: afterReplay, at: now)
            XCTFail("An edited food name must still match the original evidence")
        } catch PantryReceiptError.changedEvidence {}
    }

    func testClaimedDocumentSurvivesRestartUntilExactRecordsErasureAndOtherSourcesStayPending() async throws {
        let f = try await fixture()
        let repo = PantryRepository(store: f.store, authorize: { true })
        let origin = f.store.workspaceID, scope = SharedReceiptScope(origin: f.store.workspaceID, persona: UUID())
        let url = f.directory.appendingPathComponent("staging/inbox.sqlite")
        let writer = try SharedCaptureInbox(url: url), first = UUID(), other = UUID()
        let bytes = Data("BEANS\nFEE".utf8)
        _ = try await writer.stageReceipt(bytes, kind: .text, id: first, now: now)
        _ = try await writer.stageReceipt(Data("MILK".utf8), kind: .text, id: other, now: now)
        _ = try await writer.stageReceipt(bytes, kind: .text, id: UUID(), now: now)
        let independent = UUID(), otherScope = SharedReceiptScope(origin: UUID(), persona: UUID())
        _ = try await writer.stageReceipt(bytes, kind: .text, id: independent, now: now)
        let inbox = try SharedCaptureInbox(url: url)
        let initial = try await inbox.pendingReceiptFiles(scope: otherScope, now: now)
        let otherItem = try XCTUnwrap(initial.first(where: { $0.id == independent }))
        _ = try await inbox.openReceipt(otherItem, scope: otherScope, now: now)
        let pending = try await inbox.pendingReceiptFiles(scope: scope, now: now)
        let selected = try XCTUnwrap(pending.first(where: { $0.id == first }))
        let raw = try await inbox.openReceipt(selected, scope: scope, now: now)
        let document = try await ReceiptDocumentReader().extract(.init(data: raw, kind: .text))
        let source = try document.source(target: .init(workspaceID: origin, containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence),
            merchant: "Market", stage: .finalInvoice, selection: [.init(page: 1, line: 1)], at: now)
        var draft = try ReceiptImportDraft(source: source)
        draft.dateConfirmed = true; draft.purchaseDate = now
        draft.lines[0].treatment = .add; draft.lines[0].received = "2"; draft.lines[0].usable = "1"
        let review = try await repo.reviewReceipt(draft, expected: f.store.inventoryState(), at: now)
        try await repo.applyReceipt(review, at: now)
        let fact = try XCTUnwrap(review.facts.first)
        let corrected = try fact.correctingPaidTotal(Money(decimal: "1.15"))
        XCTAssertEqual(corrected.documentLine, fact.documentLine)
        XCTAssertEqual(fact.documentLine?.method, .textFile)
        try await repo.correctPaidTotal(fact, total: Money(decimal: "1.15"), state: f.store.inventoryState(), at: now)
        let price = try PrivatePriceEvidence(receipt: corrected)
        let refund = PrivatePriceEvidence(id: UUID(), source: .adjustment(target: price.id, revision: price.revision, kind: .refund),
            foodID: price.foodID, linkedLotID: price.linkedLotID, name: price.name, store: price.store, date: now,
            currencyCode: price.currencyCode, amountMinor: 15, pack: nil, sourceText: "Reviewed damaged package refund")
        try await repo.savePrice(refund, expected: f.store.inventoryState(), at: now)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let coordinator = PantryErasureCoordinator(inventory: f.store, ledger: f.ledger, gate: f.gate,
            pendingDirectory: f.pending.fileURL.deletingLastPathComponent(), registry: registry, worker: f.worker,
            journalDirectory: f.directory.appendingPathComponent("erasure"), receiptFilesForErasure: { origin, date in
                try await inbox.receiptErasureCandidates(origin: origin, now: date)
            }, cleanup: { impact, _ in
                try await inbox.retireReceipts(impact.sharedReceipts ?? [], origin: impact.originID, now: self.now)
            }, authorize: { true }, clock: { self.now })
        let erase = try await coordinator.prepare(.lot(fact.lotID, revision: 1))
        XCTAssertEqual(erase.sharedReceiptCount, 2)
        XCTAssertEqual(erase.receiptRevisionCount, 2)
        XCTAssertEqual(erase.priceRevisionCount, 1)
        _ = try await coordinator.commit(erase)
        let removed = try await f.store.priceRows(id: refund.id, latestOnly: false)
        XCTAssertTrue(removed.isEmpty)
        let retired = try await f.store.priceWasErased(refund.id)
        XCTAssertTrue(retired)
        let surviving = try await inbox.pendingReceiptFiles(scope: scope, now: now)
        XCTAssertEqual(surviving.map(\.id), [other])
        let unaffected = try await inbox.openReceipt(otherItem, scope: otherScope, now: now)
        XCTAssertEqual(unaffected, bytes)
        do { _ = try await inbox.openReceipt(selected, scope: scope, now: now); XCTFail("Erased attachment must be gone") }
        catch SurfaceError.stale {}
    }

    func testReceiptLinkedEvidenceKeepsDeliveredStockAndRejectsChangedDuplicate() async throws {
        let f = try await fixture()
        let repository = PantryRepository(store: f.store, authorize: { true })
        let base = try await repository.load(at: now)
        let lotID = UUID()
        let key = ReceiptKey(sourceEventID: "partial-delivery", orderLineID: UUID(), branchID: "East", segmentID: "2")
        let amount = Quantity(amount: try Rational(3), unit: .count, originalLiteral: "3")
        let command = InventoryCommand(id: UUID(), originID: f.store.workspaceID, lotID: lotID, eventID: UUID(), expectedRevision: nil, occurredAt: now,
            change: .create(.init(foodID: UUID(), name: "Rice", source: .receipt(originID: f.store.workspaceID, key: key),
                                  location: .cupboard, unit: .count, count: .exact(amount), observedAt: now), observationID: UUID()))
        let writes = try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: base.state.revision, request: Data([1]), writes: writes), at: now)
        var draft = try receiptDraft(f.store)
        draft.lines[0].treatment = .link(lotID)
        let before = try await repository.load(at: now)
        let review = try await repository.reviewReceipt(draft, expected: before.state, at: now)
        XCTAssertEqual(review.batch?.writes.count, 0)
        try await repository.applyReceipt(review, at: now)
        let after = try await repository.load(at: now)
        XCTAssertEqual(before.lots, after.lots)
        draft.lines[0].received = "5"
        do { _ = try await repository.reviewReceipt(draft, expected: after.state, at: now); XCTFail("Changed evidence") }
        catch PantryReceiptError.changedEvidence {}
        draft.lines[0].treatment = .skip
        do { _ = try await repository.reviewReceipt(draft, expected: after.state, at: now); XCTFail("Skipped all receipt lines") }
        catch PantryReceiptError.selection {}
    }

    func testPagedCaptureReopensAllFactsWithoutMaterializedSnapshot() async throws {
        let f = try await fixture(count: 205)
        let handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        XCTAssertEqual(handle.lotCount, 205); XCTAssertGreaterThan(handle.fileCount, 3)
        let restarted = try PantryArchiveWorker(root: f.directory.appendingPathComponent("archives"))
        let reopened = try await restarted.open(reference: handle.reference)
        XCTAssertEqual(reopened.reference, handle.reference); XCTAssertEqual(reopened.lotCount, 205)
        var cursor: PantryArchiveWorker.DependencyCursor?, lots: Set<UUID> = []
        repeat {
            let page = try await restarted.dependencies(reopened, after: cursor, limit: 200)
            XCTAssertLessThanOrEqual(page.values.count, 200)
            for dependency in page.values where dependency.kind == .lot { lots.insert(dependency.id) }
            cursor = page.next
        } while cursor != nil
        XCTAssertEqual(lots.count, 205)
        #if !targetEnvironment(simulator)
        let attributes = try FileManager.default.attributesOfItem(atPath: handle.directory.path)
        XCTAssertEqual(attributes[.protectionKey] as? FileProtectionType, .complete)
        #endif
    }

    func testLegacyPackageAndRestorationChunksMatchExistingPureConversion() async throws {
        let f = try await fixture(count: 90)
        let captured = try await f.capture.capture(at: now)
        let storage = try PantryArchiveStorage(root: f.directory.appendingPathComponent("archives"))
        let bundle = try storage.publish(captured)
        let handle = try await f.worker.open(reference: bundle.reference)
        let target = try ComparisonStore(url: f.directory.appendingPathComponent("restore.sqlite"), inventoryEnabled: true)
        f.cleanup.track(target)
        let context = PantryArchiveWorker.RestorationContext(version: 1, copyID: UUID(), reference: handle.reference,
            workspaceID: target.workspaceID, restorationID: UUID(), preparedAt: now)
        let token = try await target.inventorySourceToken()
        let prepared = try await f.worker.prepareRestoration(source: handle, context: context, sourceToken: token)
        XCTAssertGreaterThan(prepared.plan.expectedChunkCount, 1)
        _ = try await target.beginInventoryMigration(prepared.plan)
        for index in 0..<prepared.plan.expectedChunkCount {
            let chunk = try await f.worker.restorationChunk(prepared, index: index)
            _ = try await target.stageInventoryMigration(id: prepared.plan.migrationID, chunk: chunk)
        }
        _ = try await target.finishInventoryMigration(id: prepared.plan.migrationID, at: now)
        let expected = try PantryArchiveRestore.prepare(captured.snapshot, newOriginID: target.workspaceID,
            restorationID: context.restorationID, at: now)
        let rows = try await target.inventoryRecords(kind: .lot, limit: 200)
        XCTAssertEqual(Set(try rows.map { try PantryPersistenceCodec.lot($0).id }), Set(expected.lots.map(\.id)))
        let actual = try rows.map(PantryPersistenceCodec.lot).sorted { $0.id.uuidString < $1.id.uuidString }
        XCTAssertEqual(actual, expected.lots.sorted { $0.id.uuidString < $1.id.uuidString })
        try await f.worker.discardRestoration(prepared)
        try await f.worker.discardRestoration(prepared)
    }

    func testIndependentEditReexportIsSelfContainedAndOldPendingStaysInert() async throws {
        let f = try await fixture(), originalLot = try await firstLot(f.store)
        let foodJournal = try f.pending.makeFoodPendingStore()
        _ = try foodJournal.save(command: .init(id: UUID(), originID: f.store.workspaceID, lotID: originalLot.id,
            eventID: UUID(), expectedRevision: 1, occurredAt: now, change: .count(.someLeft, observationID: UUID())), reviewedInventoryRevision: 1)
        let source = try await f.capture.captureHandle(worker: f.worker, at: now)
        let gate = PantryMutationGate()
        let coordinator = try PantryRecoveryCoordinator(root: f.directory.appendingPathComponent("copies"), worker: f.worker,
            gate: gate, protectedWorkspaceIDs: { [f.store.workspaceID, f.ledger.workspaceID] }, authorize: { _, _ in true })
        let opened = try await coordinator.create(copyID: UUID(), reference: source.reference, at: now)
        f.cleanup.track(opened.store)
        let baseline = try await firstLot(opened.store), later = now.addingTimeInterval(1)
        try await append(.init(id: UUID(), originID: opened.store.workspaceID, lotID: baseline.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: later, change: .count(.someLeft, observationID: UUID())), current: baseline, to: opened.store)
        let changed = try await firstLot(opened.store)
        let exported = try await PantryArchiveCapture.captureIndependent(worker: f.worker, inventory: opened.store,
            original: source, identity: opened.identity, journalDirectory: f.directory.appendingPathComponent("copy-journal"),
            gate: gate, at: later, authorize: {})
        guard case .independent(let scope) = exported.scope else { return XCTFail("Independent scope required") }
        XCTAssertEqual(scope.originID, opened.store.workspaceID); XCTAssertNil(scope.foodPendingDigest)
        let key = Data(repeating: 7, count: 32).base64EncodedString()
        let package = try await f.worker.encryptedExport(exported, key: key)
        XCTAssertEqual(package.url.pathExtension, "ritcpantry")
        let independentWorker = try PantryArchiveWorker(root: f.directory.appendingPathComponent("portable"))
        let prepared = try await independentWorker.prepareImport(url: package.url, key: key)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("portable-registry.json"))
        let review = try await registry.reviewPantry(prepared.reference)
        _ = try await independentWorker.applyImport(prepared, review: review, registry: registry, now: later)
        try await independentWorker.discardImport(prepared, registry: registry)
        let imported = try await independentWorker.open(reference: exported.reference)
        XCTAssertEqual(imported.reference, exported.reference)
        // The second worker has no original package or original databases.
        let secondCoordinator = try PantryRecoveryCoordinator(root: f.directory.appendingPathComponent("portable-copies"), worker: independentWorker,
            gate: PantryMutationGate(), protectedWorkspaceIDs: { [] }, authorize: { _, _ in true })
        let second = try await secondCoordinator.create(copyID: UUID(), reference: imported.reference, at: later)
        f.cleanup.track(second.store)
        let result = try await firstLot(second.store)
        XCTAssertEqual(result.count, changed.count); XCTAssertEqual(result.revision, 1)
        XCTAssertNotEqual(result.source.originID, opened.store.workspaceID)
        let oldIntents = try await second.store.inventoryRecords(kind: .intent)
        XCTAssertTrue(oldIntents.isEmpty)
        let sourcePending = try foodJournal.read()
        XCTAssertNotNil(sourcePending)
        try await f.worker.discardExport(package)
        try await f.worker.discardExport(package)
    }

    func testUnknownJournalAndRevocationFailWithoutPublishingPackage() async throws {
        let f = try await fixture()
        let directory = f.pending.fileURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let unknown = directory.appendingPathComponent("\(f.store.workspaceID.uuidString).\(UUID().uuidString).pack.json")
        try Data("{}".utf8).write(to: unknown)
        do { _ = try await f.capture.captureHandle(worker: f.worker, at: now); XCTFail("Unknown journal omitted") } catch { }
        try FileManager.default.removeItem(at: unknown)
        var accesses = 0
        let revoked = PantryArchiveCapture(inventory: f.store, ledger: f.ledger, pending: f.pending, gate: f.gate,
            authorize: { _, _ in accesses += 1; return accesses < 15 })
        do { _ = try await revoked.captureHandle(worker: f.worker, at: now); XCTFail("Revoked capture returned") }
        catch { XCTAssertEqual(error as? PantryArchiveCapture.Failure, .unauthorized) }
        let files = try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("archives").path)
        XCTAssertTrue(files.isEmpty)
        let lease = try f.gate.beginExclusiveWrite(); f.gate.endExclusiveWrite(lease)
    }

    func testEncryptedImportRejectsWrongKeyMissingPartAndChangedVerifiedBytes() async throws {
        let f = try await fixture(), handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = Data(repeating: 8, count: 32).base64EncodedString()
        let package = try await f.worker.encryptedExport(handle, key: key)
        let readerRoot = f.directory.appendingPathComponent("reader")
        let reader = try PantryArchiveWorker(root: readerRoot)
        do { _ = try await reader.prepareImport(url: package.url, key: Data(repeating: 9, count: 32).base64EncodedString()); XCTFail("Wrong key accepted") } catch { }
        let part = package.url.appendingPathComponent("pantry-0.json")
        let saved = try Data(contentsOf: part)
        try FileManager.default.removeItem(at: part)
        do { _ = try await reader.prepareImport(url: package.url, key: key); XCTFail("Partial package accepted") } catch { }
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: readerRoot.path).isEmpty)
        try saved.write(to: part)
        let prepared = try await reader.prepareImport(url: package.url, key: key)
        let imported = prepared.handle
        let localPart = imported.directory.appendingPathComponent("pantry-0.json")
        var corrupt = try Data(contentsOf: localPart); corrupt[corrupt.count / 2] ^= 1
        try corrupt.write(to: localPart)
        do { _ = try await reader.dependencies(imported); XCTFail("Changed handle bytes trusted") } catch { }
        do { _ = try await reader.encryptedExport(imported, key: key); XCTFail("Changed handle exported") } catch { }
        try await f.worker.discardExport(package)
    }

    func testConcurrentImportReviewsOwnSeparatePlaintextUntilExplicitRegistration() async throws {
        let f = try await fixture(), source = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = EncryptedArchive.generateKey()
        let package = try await f.worker.encryptedExport(source, key: key)
        let root = f.directory.appendingPathComponent("shared")
        let first = try PantryArchiveWorker(root: root), second = try PantryArchiveWorker(root: root)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let a = try await first.prepareImport(url: package.url, key: key)
        let b = try await second.prepareImport(url: package.url, key: key)
        let destination = root.appendingPathComponent(source.reference.bundleID.uuidString)
        XCTAssertNotEqual(a.handle.directory, b.handle.directory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: destination.path))
        try await second.reconcilePreparedImports(registry: registry)
        do {
            try await second.reconcilePreparedImports(registry: registry, requireIdle: true)
            XCTFail("An active review cannot acknowledge a completed erasure drain")
        } catch { XCTAssertEqual(error as? PantryArchiveWorker.Failure, .conflict) }
        try await first.discardImport(a, registry: registry)
        XCTAssertFalse(FileManager.default.fileExists(atPath: a.handle.directory.path))
        _ = try await second.revalidateImport(b)
        let reviewed = try await registry.reviewPantry(b.reference)
        let copy = try await second.applyImport(b, review: reviewed, registry: registry, now: now)
        try await second.discardImport(b, registry: registry)
        let reopened = try await first.open(reference: b.handle.reference)
        XCTAssertEqual(reopened.reference.manifestDigest, copy.reference.manifestDigest)
        let duplicate = try await first.prepareImport(url: package.url, key: key)
        try await first.discardImport(duplicate, registry: registry)
        _ = try await second.open(reference: source.reference)
        let registered = try await registry.listPantry()
        XCTAssertEqual(registered, [copy])
        try await second.reconcilePreparedImports(registry: registry, requireIdle: true)
    }

    func testRestartDropsAbandonedReviewsAndOnlyRepairsDurablyRegisteredPromotion() async throws {
        let f = try await fixture(), source = try await f.capture.captureHandle(worker: f.worker, at: now)
        let key = EncryptedArchive.generateKey()
        let package = try await f.worker.encryptedExport(source, key: key)
        let root = f.directory.appendingPathComponent("shared")
        let worker = try PantryArchiveWorker(root: root)
        let registryURL = f.directory.appendingPathComponent("registry.json")
        let registry = try RecoveryRegistry(url: registryURL)
        let destination = root.appendingPathComponent(source.reference.bundleID.uuidString)
        for phase in 0..<4 {
            var pending: PantryPreparedImport? = try await worker.prepareImport(url: package.url, key: key)
            let stage = try XCTUnwrap(pending?.handle.directory.deletingLastPathComponent())
            if phase > 0 {
                let prepared = try XCTUnwrap(pending)
                let review = try await registry.reviewPantry(prepared.reference)
                if phase == 3 {
                    _ = try await worker.applyImport(prepared, review: review, registry: registry, now: now)
                } else {
                    // Interrupt after the confirmation marker is durable, before
                    // the registry write. Phase 2 then persists only the registry
                    // side, as if the process exited before its rename callback.
                    do {
                        _ = try await worker.applyImport(prepared, review: review, registry: registry, now: now,
                            authorize: { false })
                        XCTFail("Revoked import applied")
                    } catch { XCTAssertEqual(error as? ArchiveError, .unavailable) }
                    if phase == 2 { _ = try await registry.applyPantry(review, now: now) }
                }
            }
            pending = nil // Simulates release of the process's directory lock.
            let restarted = try PantryArchiveWorker(root: root)
            let reopened = try RecoveryRegistry(url: registryURL)
            try await restarted.reconcilePreparedImports(registry: reopened, requireIdle: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: stage.path))
            XCTAssertEqual(FileManager.default.fileExists(atPath: destination.path), phase >= 2)
            if phase >= 2 { _ = try await restarted.open(reference: source.reference) }
        }
    }

    func testIncompleteGraphNeverProducesHandleAndCancelledJobIsRemoved() async throws {
        let f = try await fixture(), captured = try await f.capture.capture(at: now)
        let job = try await f.worker.begin(descriptor: captured.snapshot.descriptor)
        let rows = try await f.store.inventoryRecords(kind: .lot)
        try await f.worker.appendRecords(rows, to: job)
        do { _ = try await f.worker.finish(job, scope: .paired(captured.scope)); XCTFail("Orphan graph accepted") } catch { }
        let cancelled = try await f.worker.begin(descriptor: captured.snapshot.descriptor)
        try await f.worker.cancel(cancelled); try await f.worker.cancel(cancelled)
        XCTAssertTrue(try FileManager.default.contentsOfDirectory(atPath: f.directory.appendingPathComponent("archives").path).isEmpty)
    }
    func testHistoryBeyondFormerMaterializationCapIsCompleteOnReopen() async throws {
        let f = try await fixture(), captured = try await f.capture.capture(at: now)
        let job = try await f.worker.begin(descriptor: captured.snapshot.descriptor)
        for kind in [InventoryRecordKind.lot, .observation, .event, .sourceLink] {
            let rows = try await f.store.inventoryRecords(kind: kind)
            try await f.worker.appendRecords(rows, to: job)
        }
        // Legal source bytes retain original whitespace. One bounded source is
        // repeated at distinct historical revisions, exceeding 128 MiB in total.
        var journey = PickupJourney(id: UUID(), savedAt: now)
        journey.urgent = [.init(id: UUID(), food: "Wraps", meal: "Dinner",
            required: .init(amount: try Rational(2), unit: .count, originalLiteral: "2"),
            available: .init(amount: try Rational(0), unit: .count, originalLiteral: "0"), due: nil, confirmedAt: now)]
        var payload = try ArchiveCodec.canonical(journey)
        payload.append(Data(repeating: 32, count: ComparisonStore.maximumPayloadBytes - payload.count))
        struct Head: Encodable { let id: UUID; let revision: Int64; let payload: Data; let savedAt: Date }
        for revision in 1...100 {
            let head = try JSONDecoder().decode(PantryLegacyMigration.SourceHead.self,
                from: ArchiveCodec.canonical(Head(id: journey.id, revision: Int64(revision), payload: payload, savedAt: now)))
            try await f.worker.append(ArchiveCodec.canonical(PantryArchiveCodec.Item.historical(.sourceHead(originID: f.store.workspaceID, head))), to: job)
        }
        let handle = try await f.worker.finish(job, scope: .paired(captured.scope))
        var size: Int64 = 0
        for file in try FileManager.default.contentsOfDirectory(at: handle.directory, includingPropertiesForKeys: nil) {
            size += (try FileManager.default.attributesOfItem(atPath: file.path)[.size] as? NSNumber)?.int64Value ?? 0
        }
        XCTAssertGreaterThan(size, 128 * 1_024 * 1_024)
        let reopened = try await f.worker.open(reference: handle.reference)
        XCTAssertEqual(reopened.reference, handle.reference); XCTAssertEqual(reopened.lotCount, 1)
        XCTAssertEqual(reopened.fileCount, handle.fileCount)
    }

    func testRedactionFloorRejectsOldHistoricalClaimButKeepsSanitizedHead() async throws {
        let f = try await fixture(), captured = try await f.capture.capture(at: now)
        let lot = try XCTUnwrap(captured.snapshot.lots.first), claimID = UUID()
        let claim = InventoryReservation(id: claimID, originID: f.store.workspaceID, revision: 2,
            foodID: lot.foodID, lotID: nil, name: "Unresolved", amount: nil, state: .unresolved)
        let marker = InventoryReservationRedaction(workspaceID: f.store.workspaceID, reservationID: claimID,
            throughRevision: 1, operationID: UUID(), previousLotID: lot.id)
        func stage(includeOld: Bool) async throws -> UUID {
            let job = try await f.worker.begin(descriptor: .init(originID: f.store.workspaceID, inventoryRevision: 2, capturedAt: now))
            for kind in [InventoryRecordKind.lot, .observation, .event, .sourceLink] {
                let rows = try await f.store.inventoryRecords(kind: kind)
                try await f.worker.appendRecords(rows, to: job)
            }
            try await f.worker.append(ArchiveCodec.canonical(PantryArchiveCodec.Item.reservation(claim)), to: job)
            try await f.worker.appendEvidence(.current(.reservationRedacted(marker)), to: job)
            if includeOld {
                let old = InventoryReservation(id: claimID, originID: f.store.workspaceID, revision: 1,
                    foodID: lot.foodID, lotID: lot.id, name: "Private former claim", amount: nil, state: .unresolved)
                try await f.worker.append(ArchiveCodec.canonical(PantryArchiveCodec.Item.historical(.originalReservation(old))), to: job)
            }
            return job
        }
        let old = captured.scope
        let scope = PantryArchiveCapture.Scope(version: 1, inventoryOriginID: old.inventoryOriginID, inventoryRevision: 2,
            sourceToken: old.sourceToken, ledgerOriginID: old.ledgerOriginID, ledgerRevision: old.ledgerRevision,
            ledgerOperationID: old.ledgerOperationID, ledgerPayloadDigest: old.ledgerPayloadDigest,
            pendingDigest: nil, foodPendingDigest: nil, packPendingDigest: old.packPendingDigest, capturedAt: now)
        let invalid = try await stage(includeOld: true)
        do { _ = try await f.worker.finish(invalid, scope: .paired(scope)); XCTFail("Redacted historical claim restored") } catch { }
        let valid = try await stage(includeOld: false)
        let handle = try await f.worker.finish(valid, scope: .paired(scope))
        XCTAssertEqual(handle.reservationCount, 1)
        let reopened = try await f.worker.open(reference: handle.reference)
        XCTAssertEqual(reopened.reservationCount, 1)
    }

    func testAuthenticatedContentPagesIncludeRetainedSQLClaimAndLotHistory() async throws {
        let f = try await fixture(), lot = try await firstLot(f.store)
        try await append(.init(id: UUID(), originID: f.store.workspaceID, lotID: lot.id, eventID: UUID(),
            expectedRevision: 1, occurredAt: now, change: .count(.someLeft, observationID: UUID())), current: lot, to: f.store)
        let claimID = UUID()
        for revision in 1...2 {
            let claim = InventoryReservation(id: claimID, originID: f.store.workspaceID, revision: Int64(revision),
                foodID: lot.foodID, lotID: revision == 1 ? lot.id : nil, name: "Dinner", amount: nil, state: .unresolved)
            let state = try await f.store.inventoryState()
            _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
                expectedRevision: state.revision, request: Data("claim-\(revision)".utf8),
                writes: [.init(record: .init(key: .init(.reservation, claimID), revision: Int64(revision),
                    payload: ArchiveCodec.canonical(claim), lotID: claim.lotID), expectedRevision: Int64(revision - 1))]), at: now)
        }
        let handle = try await f.capture.captureHandle(worker: f.worker, at: now)
        var cursor: PantryArchiveWorker.ContentCursor?, oldLot = false, oldClaim = false, currentClaim = false
        repeat {
            let page = try await f.worker.contentPage(handle, after: cursor, limit: 2)
            XCTAssertLessThanOrEqual(page.values.count, 2)
            var byteCount = 0
            for value in page.values {
                switch value {
                case .item(let bytes):
                    byteCount += bytes.count
                    let item = try JSONDecoder().decode(PantryArchiveCodec.Item.self, from: bytes)
                    if case .historical(.originalLot(let value)) = item, value.id == lot.id, value.revision == 1 { oldLot = true }
                    if case .historical(.originalReservation(let value)) = item, value.id == claimID, value.revision == 1 { oldClaim = true }
                    if case .reservation(let value) = item, value.id == claimID, value.revision == 2 { currentClaim = true }
                case .evidence(let bytes):
                    byteCount += bytes.count
                    _ = try JSONDecoder().decode(PantryArchiveWorker.Evidence.self, from: bytes)
                }
            }
            XCTAssertLessThanOrEqual(byteCount, PantryArchiveCodec.maximumChunkBytes)
            cursor = page.next
        } while cursor != nil
        XCTAssertTrue(oldLot); XCTAssertTrue(oldClaim); XCTAssertTrue(currentClaim)
    }

}

extension PantryArchiveWorkerTests {
    private func eraser(_ f: Fixture, _ registry: RecoveryRegistry, authorize: @escaping () -> Bool = { true },
                        cleanup: @escaping PantryErasureCoordinator.CleanupHandler = { _, _ in }) -> PantryErasureCoordinator {
        let instant = now
        return PantryErasureCoordinator(inventory: f.store, ledger: f.ledger, gate: f.gate,
            pendingDirectory: f.pending.fileURL.deletingLastPathComponent(), registry: registry, worker: f.worker,
            journalDirectory: f.directory.appendingPathComponent("erasure-journal"), cleanup: cleanup,
            authorize: authorize, clock: { instant })
    }

    func testReviewedFoodErasureRecoversCleanupFromReceiptAndKeepsIndependentPin() async throws {
        let f = try await fixture(count: 2)
        let registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let repository = PantryRepository(store: f.store, authorize: { true }); f.cleanup.track(repository)
        let base = try await repository.load(at: now), selected = base.lots[0], kept = base.lots[1]
        let lost = InventoryReservation(id: UUID(), originID: f.store.workspaceID, revision: 1, foodID: selected.foodID,
            lotID: selected.id, name: "First meal", amount: selected.count.quantity)
        let pin = InventoryReservation(id: UUID(), originID: f.store.workspaceID, revision: 1, foodID: kept.foodID,
            lotID: kept.id, name: "Other meal", amount: kept.count.quantity)
        let writes = try [lost, pin].map { claim in
            InventoryWrite(record: .init(key: .init(.reservation, claim.id), revision: 1,
                payload: try ArchiveCodec.canonical(claim), lotID: claim.lotID), expectedRevision: 0)
        }
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: base.state.revision, request: Data("save two pins".utf8), writes: writes), at: now)
        let captured = try await f.capture.captureHandle(worker: f.worker, at: now)
        let reference = PantryRecoveryReference(bundleID: captured.reference.bundleID, manifestDigest: captured.reference.manifestDigest,
            originID: captured.descriptor.originID, inventoryRevision: captured.descriptor.inventoryRevision)
        let copy = try await registry.applyPantry(registry.reviewPantry(reference), now: now)
        let foodPending = try f.pending.makeFoodPendingStore()
        _ = try foodPending.save(command: .init(id: UUID(), originID: f.store.workspaceID, lotID: selected.id,
            eventID: UUID(), expectedRevision: selected.revision, occurredAt: now, change: .usedUp(observationID: UUID())),
            reviewedInventoryRevision: captured.descriptor.inventoryRevision)
        let coordinator = eraser(f, registry, cleanup: { cleanup, receipt in
            XCTAssertEqual(cleanup.copyIDs, [copy.id]); XCTAssertEqual(receipt.scope, .sourceGraph)
            throw ArchiveError.unavailable
        })
        let review = try await coordinator.prepare(.lot(selected.id, revision: selected.revision))
        XCTAssertTrue(review.canCommit); XCTAssertEqual(review.copyIDs, [copy.id])
        XCTAssertEqual(review.pendingFileCount, 1); XCTAssertEqual(review.affectedReservationNames, [lost.name])
        let result = try await coordinator.commit(review); XCTAssertEqual(result, .cleanupPending)
        let current = try await repository.load(at: now)
        XCTAssertEqual(current.lots, [kept])
        XCTAssertEqual(current.reservations.first { $0.id == pin.id }, pin)
        let uncertain = try XCTUnwrap(current.reservations.first { $0.id == lost.id })
        XCTAssertEqual(uncertain.state, .unresolved); XCTAssertNil(uncertain.amount); XCTAssertNil(uncertain.lotID)
        let copies = try await registry.listPantry(), retired = try await registry.permanentlyRetiredPantryBundleIDs()
        XCTAssertTrue(copies.isEmpty); XCTAssertEqual(retired, [reference.bundleID])
        XCTAssertNotNil(try foodPending.read())
        let restarted = eraser(f, registry, authorize: { false }, cleanup: { _, _ in
            try await f.worker.removePermanentlyRetiredBundles(retired)
        })
        let recovered = try await restarted.recoverCleanup(); XCTAssertEqual(recovered, .deleted)
        XCTAssertNil(try foodPending.read())
        let again = try await restarted.recoverCleanup(); XCTAssertNil(again)
        let after = try await repository.load(at: now); XCTAssertEqual(after.state, current.state)
    }

    func testErasureReviewsAnotherInstancesDeletedPackageAndExpiresItsUndo() async throws {
        let f = try await fixture(), url = f.directory.appendingPathComponent("registry.json")
        let owner = try RecoveryRegistry(url: url), planner = try RecoveryRegistry(url: url)
        let selected = try await firstLot(f.store)
        let captured = try await f.capture.captureHandle(worker: f.worker, at: now)
        let reference = PantryRecoveryReference(bundleID: captured.reference.bundleID, manifestDigest: captured.reference.manifestDigest,
            originID: captured.descriptor.originID, inventoryRevision: captured.descriptor.inventoryRevision)
        let copy = try await owner.applyPantry(owner.reviewPantry(reference), now: now)
        let token = try await owner.delete(.copy(copy.id.uuidString))
        let other = ArchiveRecord(id: "retained", origin: "unrelated", revision: "one", kind: .comparison,
            title: "Independent prices", savedAtMilliseconds: 100, nativePayload: Data("{}".utf8))
        let envelope = try ArchiveCodec.make(records: [other], kind: .personalRecovery, origin: other.origin, revision: "one")
        let inserted = try await planner.apply(planner.review(envelope))
        let coordinator = eraser(f, planner, cleanup: { effects, _ in
            XCTAssertEqual(effects.bundleIDs, [reference.bundleID])
            let retired = try await planner.permanentlyRetiredPantryBundleIDs()
            try await f.worker.removePermanentlyRetiredBundles(retired)
        })
        let review = try await coordinator.prepare(.lot(selected.id, revision: selected.revision))
        XCTAssertTrue(review.canCommit)
        XCTAssertEqual(review.copyIDs, [reference.bundleID])
        let result = try await coordinator.commit(review)
        XCTAssertEqual(result, .deleted)
        do { try await owner.undoDelete(token); XCTFail("Restored a deleted package with an erased source") }
        catch { XCTAssertEqual(error as? ArchiveError, .unavailable) }
        XCTAssertFalse(FileManager.default.fileExists(atPath: captured.directory.path))
        let remaining = try await owner.refreshList()
        XCTAssertEqual(remaining, inserted.records)
    }

    func testAbortedSQLReleasesRegistryReservationAndRelaunchRecoversInterruptedJournal() async throws {
        let f = try await fixture(), url = f.directory.appendingPathComponent("registry.json")
        let first = try RecoveryRegistry(url: url), second = try RecoveryRegistry(url: url)
        let selected = try await firstLot(f.store)
        let journalDirectory = f.directory.appendingPathComponent("erasure-journal")
        var crashImage: (manifest: Data, journal: Data, file: URL)?
        let coordinator = eraser(f, first, authorize: {
            guard let bytes = try? Data(contentsOf: url),
                  let manifest = try? JSONSerialization.jsonObject(with: bytes) as? [String: Any],
                  manifest["pendingPantryErasure"] != nil else { return true }
            if let file = try? FileManager.default.contentsOfDirectory(at: journalDirectory, includingPropertiesForKeys: nil).first,
               let journal = try? Data(contentsOf: file) { crashImage = (bytes, journal, file) }
            return false
        })
        let review = try await coordinator.prepare(.lot(selected.id, revision: selected.revision))
        do { _ = try await coordinator.commit(review); XCTFail("Authorization expired before SQL") }
        catch PantryErasureCoordinator.Failure.unauthorized { }
        let image = try XCTUnwrap(crashImage)
        let afterAbort = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNil(afterAbort?["pendingPantryErasure"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.file.path))

        // Restore the exact pre-SQL crash image. A new instance must release only
        // this journal's reservation without performing the abandoned deletion.
        try image.manifest.write(to: url, options: .atomic)
        try image.journal.write(to: image.file, options: .atomic)
        let restarted = eraser(f, second, authorize: { false })
        let outcome = try await restarted.recoverCleanup(); XCTAssertNil(outcome)
        let afterRecovery = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        XCTAssertNil(afterRecovery?["pendingPantryErasure"])
        XCTAssertFalse(FileManager.default.fileExists(atPath: image.file.path))
        let stillPresent = try await firstLot(f.store); XCTAssertEqual(stillPresent, selected)
    }

    func testHistoricalPinsRedactOldBodiesAndKeepPersonalDetailsAndIndependentReleasedHistory() async throws {
        let f = try await fixture(), registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let repository = PantryRepository(store: f.store, authorize: { true }); f.cleanup.track(repository)
        let snapshot = try await repository.load(at: now), first = try XCTUnwrap(snapshot.lots.first)
        let second = try InventoryEngine.prepare(.init(id: UUID(), originID: f.store.workspaceID, lotID: UUID(), eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: first.foodID, name: "Independent batch",
                source: .manual(originID: f.store.workspaceID, sourceID: UUID()), location: .freezer, unit: first.unit, count: first.count),
                observationID: UUID())), current: nil, at: now)
        let amount = Quantity(amount: .one, unit: first.unit, originalLiteral: "1"), day = try MealDay(date: now, timeZoneIdentifier: "America/New_York")
        let personal = InventoryPersonalReservation(day: day)
        func claim(_ id: UUID, revision: Int64, lot: UUID?, name: String, state: InventoryReservationState,
                   personal: InventoryPersonalReservation? = nil) -> InventoryReservation {
            .init(id: id, originID: f.store.workspaceID, revision: revision, foodID: first.foodID, lotID: lot,
                name: name, amount: amount, priority: .protected, state: state, personal: personal)
        }
        let initial = claim(UUID(), revision: 1, lot: first.id, name: "School lunch", state: .active, personal: personal)
        let releasedWithHistory = claim(UUID(), revision: 1, lot: first.id, name: "Earlier held meal", state: .active)
        let independent = claim(UUID(), revision: 1, lot: nil, name: "Independent release", state: .released)
        var writes = try PantryPersistenceCodec.writes(second)
        func write(_ claim: InventoryReservation) throws -> InventoryWrite {
            .init(record: .init(key: .init(.reservation, claim.id), revision: claim.revision,
                payload: try ArchiveCodec.canonical(claim), lotID: claim.lotID), expectedRevision: claim.revision - 1)
        }
        writes += try [initial, releasedWithHistory, independent].map(write)
        let one = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: snapshot.state.revision, request: Data("set historical pins".utf8), writes: writes), at: now)
        let repinned = claim(initial.id, revision: 2, lot: second.lot.id, name: initial.name, state: .active, personal: personal)
        let released = claim(releasedWithHistory.id, revision: 2, lot: nil, name: releasedWithHistory.name, state: .released)
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(),
            expectedRevision: one.revision, request: Data("save independent pins".utf8), writes: [write(repinned), write(released)]), at: now)

        let coordinator = eraser(f, registry)
        let review = try await coordinator.prepare(.lot(first.id, revision: first.revision))
        XCTAssertEqual(Set(review.affectedReservationNames), [repinned.name, released.name])
        let result = try await coordinator.commit(review); XCTAssertEqual(result, .deleted)
        let after = try await repository.load(at: now)
        XCTAssertEqual(after.lots, [second.lot])
        XCTAssertEqual(after.reservations.first { $0.id == initial.id },
            claim(initial.id, revision: 3, lot: second.lot.id, name: initial.name, state: .active, personal: personal))
        XCTAssertEqual(after.reservations.first { $0.id == released.id },
            claim(released.id, revision: 3, lot: nil, name: released.name, state: .released))
        XCTAssertEqual(after.reservations.first { $0.id == independent.id }, independent)
        let floors = try await f.store.inventoryReservationRedactions(expectedInventoryRevision: after.state.revision)
        XCTAssertEqual(Set(floors.map(\.reservationID)), [initial.id, released.id])
        XCTAssertTrue(floors.allSatisfy { $0.throughRevision == 2 })
        let history = try await f.store.inventoryRevisionPage(expectedRevision: after.state.revision, sourceToken: f.store.inventorySourceToken())
        XCTAssertEqual(history.filter { $0.key.kind == .reservation && $0.key.id == initial.id }.map(\.revision), [3])
        XCTAssertEqual(history.filter { $0.key.kind == .reservation && $0.key.id == released.id }.map(\.revision), [3])
        XCTAssertEqual(history.filter { $0.key.kind == .reservation && $0.key.id == independent.id }.map(\.revision), [1])
    }

    func testReviewedOriginRetirementRequiresCurrentLedgerBasisAndFencesUnseenPackages() async throws {
        let f = try await fixture(), registry = try RecoveryRegistry(url: f.directory.appendingPathComponent("registry.json"))
        let coordinator = eraser(f, registry)
        let futurePickup = UUID(), before = try await f.store.inventoryState()
        _ = try await f.store.commitInventory(.init(workspaceID: f.store.workspaceID, operationID: UUID(), expectedRevision: before.revision,
            request: Data("retain newer-format pickup".utf8), comparisons: [.init(action: .save, id: futurePickup, expectedRevision: 0,
                title: "Future-format pickup", payload: Data(#"{"version":12,"future":true}"#.utf8))]), at: now)
        let review = try await coordinator.prepare(.wholeOrigin)
        XCTAssertEqual(review.pickupIDs, [futurePickup]); XCTAssertEqual(review.pickupTitles, ["Future-format pickup"])
        let original = try await f.store.inventoryState()
        struct Document: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
        _ = try await f.ledger.save(payload: ArchiveCodec.canonical(Document(workspace: .init())), expectedRevision: 0,
            operationID: UUID(), savedAt: now)
        do { _ = try await coordinator.commit(review); XCTFail("Changed ledger requires a new review") }
        catch PantryErasureCoordinator.Failure.stale { }
        let retained = try await f.store.inventoryState(); XCTAssertEqual(retained, original)
        let revised = try await coordinator.prepare(.wholeOrigin)
        XCTAssertTrue(revised.canCommit)
        let result = try await coordinator.commit(revised); XCTAssertEqual(result, .deleted)
        let retirement = try await f.store.inventoryOriginRetirement(); XCTAssertEqual(retirement?.scope, .origin)
        let future = PantryRecoveryReference(bundleID: UUID(), manifestDigest: Data(repeating: 7, count: 32),
            originID: f.store.workspaceID, inventoryRevision: 123)
        let old = try await registry.reviewPantry(future); XCTAssertFalse(old.canApply)
        let ledger = try await f.ledger.load(); XCTAssertEqual(ledger?.revision, 1)
    }
}
