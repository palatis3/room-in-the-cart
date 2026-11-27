import CoreDomain
import LocalStore
import UIKit
import XCTest
@testable import RoomInTheCart

@MainActor final class MixedReceiptPutawayTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func receipt(store: ComparisonStore, lines: [String]) throws -> ReceiptImportDraft {
        let source = SourceMediaRecord(id: UUID(), target: .init(workspaceID: store.workspaceID,
            containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence),
            originalText: lines.joined(separator: "\n"), reviewedLabel: "Mercado", imageJPEG: nil, barcode: nil,
            receiptLines: lines.map { .init(originalText: $0) }, capturedAt: now)
        var result = try ReceiptImportDraft(source: source, now: now)
        result.tracksPutaway = true
        result.purchaseDate = now
        result.dateConfirmed = true
        result.reference = "TICKET-18"
        return result
    }

    func testProtectedReceiptDraftRequiresOptInAndMatchesActorOriginAndVersion() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(root, test: self)
        let store = try ComparisonStore(url: root.appendingPathComponent("shop.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let privateFolder = root.appendingPathComponent("ReceiptDrafts")
        let files = ProtectedReceiptDraftStore(directory: privateFolder)
        let owner = UUID(), other = UUID()
        let scope = ProtectedReceiptDraftStore.Scope(origin: store.workspaceID, owner: owner)
        let otherScope = ProtectedReceiptDraftStore.Scope(origin: store.workspaceID, owner: other)
        var allowed = true
        let gate = PantryMutationGate()
        let repo = PantryRepository(store: store, mutationGate: gate, aliasPersonaID: owner,
                                   receiptDraftStore: files, receiptDraftOwner: owner, authorize: { allowed })
        cleanup.track(repo)
        let empty = try await repo.savedReceiptDraft()
        XCTAssertNil(empty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: privateFolder.path))

        var draft = try receipt(store: store, lines: ["Frijoles 2 unidades MXN $40,50", "Del pedido"])
        draft.lines[0].received = "2"; draft.lines[0].usable = "1"; draft.lines[0].paid = "40,50"
        draft.lines[0].treatment = .keptSome; draft.lines[0].checkedPack = true
        draft.lines[0].confirmedPackID = UUID(); draft.lines[1].treatment = .link(UUID())
        draft.printedPaidTotal = .init(wording: "TOTAL PAGADO MXN $40,50", amount: "40,50")
        draft.printedDate = .init(day: now, wording: "Fecha 2026-11-26")
        let saved = try await repo.saveReceiptDraft(.putaway(draft), replacing: nil)
        let reopened = try XCTUnwrap(files.read(scope)?.draft)
        XCTAssertEqual(saved.revision, reopened.revision)
        guard case .putaway(let editable) = reopened.payload else { return XCTFail("Expected reviewed fields") }
        XCTAssertEqual(editable.lines[0].id, draft.lines[0].id)
        XCTAssertEqual(editable.lines[0].original, draft.lines[0].original)
        XCTAssertEqual(editable.lines[0].usable, "1")
        XCTAssertEqual(editable.lines[0].paid, "40,50")
        XCTAssertEqual(editable.printedPaidTotal, draft.printedPaidTotal)
        XCTAssertEqual(editable.printedDate, draft.printedDate)
        XCTAssertFalse(editable.dateConfirmed)
        XCTAssertFalse(editable.lines[0].checkedPack)
        XCTAssertNil(editable.lines[0].confirmedPackID)
        XCTAssertEqual(editable.lines[1].treatment, .skip)
        XCTAssertNil(try files.read(otherScope))
        XCTAssertNil(try files.read(.init(origin: UUID(), owner: owner)))
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: privateFolder, includingPropertiesForKeys: nil).first { $0.pathExtension == "draft" })
        XCTAssertEqual(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
        let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.intValue, 0o600)
        let directoryAttributes = try FileManager.default.attributesOfItem(atPath: privateFolder.path)
        XCTAssertEqual((directoryAttributes[.posixPermissions] as? NSNumber)?.intValue, 0o700)
        let protection = (attributes[.protectionKey] as? FileProtectionType)?.rawValue ?? attributes[.protectionKey] as? String
        #if targetEnvironment(simulator)
        // Some simulator runtimes omit Data Protection metadata even when the write requested complete protection.
        if let protection { XCTAssertEqual(protection, FileProtectionType.complete.rawValue) }
        #else
        XCTAssertEqual(protection, FileProtectionType.complete.rawValue)
        #endif
        let replacement = try await repo.saveReceiptDraft(.putaway(draft), replacing: saved.revision)
        XCTAssertNotEqual(replacement.revision, saved.revision)
        XCTAssertThrowsError(try files.replace(.putaway(draft), expected: nil, scope: scope))
        XCTAssertThrowsError(try files.remove(scope, revision: saved.revision))
        allowed = false
        do { _ = try await repo.savedReceiptDraft(); XCTFail("A locked or changed adult read a private receipt") } catch {}
        do { _ = try await repo.saveReceiptDraft(.putaway(draft), replacing: replacement.revision); XCTFail("A changed adult replaced the private receipt") } catch {}
        do { try await repo.discardReceiptDraft(revision: replacement.revision); XCTFail("A locked or changed adult discarded a receipt") } catch {}
        XCTAssertEqual(try files.read(scope)?.draft.revision, replacement.revision)
        _ = try files.replace(.putaway(draft), expected: nil, scope: otherScope)
        try files.erase(origin: store.workspaceID)
        XCTAssertNil(try files.read(scope))
        XCTAssertNil(try files.read(otherScope))
        XCTAssertThrowsError(try files.replace(.putaway(draft), expected: replacement.revision, scope: scope))
    }

    func testResumeOnlyOpensTheChosenCurrentReceiptDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(root, test: self)
        let inventory = try ComparisonStore(url: root.appendingPathComponent("shop.sqlite"), inventoryEnabled: true)
        cleanup.track(inventory)
        let token = try await inventory.inventorySourceToken()
        _ = try await inventory.commitInventory(.init(workspaceID: inventory.workspaceID, operationID: UUID(),
            expectedRevision: 0, request: Data([1]), mode: .activate, sourceToken: token), at: now)
        let owner = UUID()
        let repo = PantryRepository(store: inventory, mutationGate: PantryMutationGate(), aliasPersonaID: owner,
                                    receiptDraftStore: ProtectedReceiptDraftStore(directory: root.appendingPathComponent("Drafts")),
                                    receiptDraftOwner: owner, authorize: { true })
        cleanup.track(repo)
        let model = PantryModel(repository: repo)
        await model.load()
        XCTAssertTrue(model.permitsPrivateReceiptDraft)
        let session = PrivateReceiptDraftSession()
        let draft = try receipt(store: inventory, lines: ["Bread"])
        let first = try await repo.saveReceiptDraft(.putaway(draft), replacing: nil)
        await session.load(model)

        var changed = draft
        changed.merchant = "Second store"
        let second = try await repo.saveReceiptDraft(.putaway(changed), replacing: first.revision)
        let stale = await session.resume(revision: first.revision, model: model)
        XCTAssertNil(stale)
        XCTAssertNil(session.activeReceiptID)
        XCTAssertEqual(session.saved?.revision, second.revision)
        XCTAssertNotNil(session.problem)
        let current = await session.resume(revision: second.revision, model: model)
        guard case .putaway(let opened)? = current?.payload else { return XCTFail("Expected the explicitly reselected draft") }
        XCTAssertEqual(opened.merchant, "Second store")
        XCTAssertEqual(session.activeReceiptID, draft.draftID)

        try await repo.discardReceiptDraft(revision: second.revision)
        let removed = await session.resume(revision: second.revision, model: model)
        XCTAssertNil(removed)
        XCTAssertNil(session.saved)
        XCTAssertNil(session.activeReceiptID)
        XCTAssertNotNil(session.problem)
    }

    func testPutawayShowsReviewedRateLinesWithoutInferringStockOrMoney() throws {
        let position = ExtractedReceiptDocument.Selection(page: 1, line: 1)
        let other = ExtractedReceiptDocument.Selection(page: 1, line: 2)
        let original = "Tortillas de maíz"
        let correction = "Tortillas de maíz 2 x 20.00 40.00"
        let cheese = "Queso fresco 1 х 45.00 45.00"
        let doc = ExtractedReceiptDocument(digest: Data(repeating: 4, count: 32),
            pages: [.init(id: 1, method: .imageOCR, lines: [.init(id: 1, text: original, uncertain: true), .init(id: 2, text: cheese)])])
        let target = CaptureTarget(workspaceID: UUID(), containerID: UUID(), objectID: UUID(), revision: 1, kind: .receiptEvidence)
        let source = try doc.source(target: target, merchant: "Mercado Prueba", stage: .receipt,
            selection: [position, other], reviewedWording: [position: correction], at: now)
        let draft = try ReceiptImportDraft(source: source, now: now)
        XCTAssertEqual(draft.lines.map(\.original), [original, cheese])
        XCTAssertEqual(draft.lines.compactMap { $0.printed?.reviewedRateLine }, [correction, cheese])
        XCTAssertTrue(draft.lines.allSatisfy { $0.received.isEmpty && $0.usable.isEmpty && $0.paid.isEmpty && $0.treatment == .skip })
        XCTAssertTrue(draft.lines.allSatisfy { $0.printed?.quantity == nil && $0.printed?.amount == nil && $0.printed?.currencyEvidence == .unspecified })
        XCTAssertFalse(draft.dateConfirmed)
        XCTAssertTrue(draft.receiptTotal.isEmpty)
        let saved = try JSONEncoder().encode(SavedReceiptDraft(payload: .putaway(draft)))
        guard case .putaway(let decoded) = try JSONDecoder().decode(SavedReceiptDraft.self, from: saved).payload else {
            return XCTFail("Expected put-away draft")
        }
        XCTAssertEqual(decoded.lines.map(\.original), [original, cheese])
        XCTAssertEqual(decoded.lines.compactMap { $0.printed?.reviewedRateLine }, [correction, cheese])

        let printed = try XCTUnwrap(draft.lines.last?.printed)
        var old = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(printed)) as? [String: Any])
        old.removeValue(forKey: "reviewedRateLine")
        let legacy = try JSONDecoder().decode(ReceiptPrintedEvidence.self, from: JSONSerialization.data(withJSONObject: old))
        XCTAssertNil(legacy.reviewedRateLine)
        for text in ["Queso fresco", "Cupón 2 x 20.00 40.00", "Queso 2 x 20.00"] {
            var row = ScanReceiptLine(originalText: text)
            row.documentLine = source.receiptLines[0].documentLine
            XCTAssertNil(ReceiptPrintedEvidence(row, knownStorage: [:]).reviewedRateLine)
        }
    }

    func testProtectedReceiptDraftPreservesAlternativesFromFourPrintedColumns() throws {
        typealias Line = ReceiptDocumentPage.Line
        let observations = [("Oats", ["Oat", "Cats"]), ("2", ["1", "3"]),
                            ("× 20.00", ["× 20.08", "× 28.00"]), ("40.00", ["40.08", "48.00"])]
        let columns = observations.enumerated().map { index, observed in
            Line(id: index + 1, text: observed.0, bounds: CGRect(x: CGFloat(index) * 0.24, y: 0.6, width: 0.17, height: 0.03),
                 wordReadings: ReceiptWordReading.choices(original: observed.0, candidates: observed.1))
        }
        let grouped = ExtractedReceiptDocument.groupingQuantityPriceColumns(columns)
        XCTAssertEqual(grouped.count, 1)
        var row = try XCTUnwrap(grouped.first)
        XCTAssertEqual(row.wordReadings.count, 8)
        let origin = UUID()
        func archive(_ line: Line) throws -> Data {
            let document = ExtractedReceiptDocument(digest: Data(repeating: 1, count: 32),
                                                     pages: [.init(id: 1, method: .imageOCR, lines: [line])])
            let draft = ReceiptLineDraft(workspaceID: origin, document: document, merchant: "", stage: .receipt,
                                         selection: [], linkedAmountItems: [], reviewedWording: [:], omittedLines: [])
            return try JSONEncoder().encode(SavedReceiptDraft(payload: .lines(draft)))
        }
        let reopened = try JSONDecoder().decode(SavedReceiptDraft.self, from: archive(row))
        guard case .lines(let saved) = reopened.payload else { return XCTFail("Expected receipt line review") }
        XCTAssertEqual(saved.document.pages.first?.lines.first, row)
        XCTAssertTrue(saved.selection.isEmpty)
        XCTAssertTrue(saved.reviewedWording.isEmpty)
        let first = try XCTUnwrap(row.wordReadings.first)
        row.wordReadings.append(first)
        XCTAssertThrowsError(try archive(row))
        row.wordReadings = [.init(word: first.word, replacement: first.replacement, wording: first.wording, wordIndex: 12)]
        XCTAssertThrowsError(try archive(row))
        row.wordReadings = [.init(word: first.word, replacement: first.replacement, wording: "a different printed row", wordIndex: 0)]
        XCTAssertThrowsError(try archive(row))
    }

    func testSavedReceiptConfirmationRecoversBothSidesOfSQLiteCommitAndKeepsLaterDraft() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(root, test: self)
        let inventory = try ComparisonStore(url: root.appendingPathComponent("shop.sqlite"), inventoryEnabled: true)
        cleanup.track(inventory)
        let token = try await inventory.inventorySourceToken()
        _ = try await inventory.commitInventory(.init(workspaceID: inventory.workspaceID, operationID: UUID(), expectedRevision: 0,
                                                     request: Data([1]), mode: .activate, sourceToken: token), at: now)
        let files = ProtectedReceiptDraftStore(directory: root.appendingPathComponent("ReceiptDrafts"))
        let owner = UUID(), gate = PantryMutationGate()
        let scope = ProtectedReceiptDraftStore.Scope(origin: inventory.workspaceID, owner: owner)
        let repo = PantryRepository(store: inventory, mutationGate: gate, aliasPersonaID: owner,
                                   receiptDraftStore: files, receiptDraftOwner: owner, authorize: { true })
        cleanup.track(repo)
        let initial = try await repo.load(at: now)
        var draft = try receipt(store: inventory, lines: ["Dry beans"])
        draft.lines[0].treatment = .add; draft.lines[0].received = "2"; draft.lines[0].usable = "1"
        let saved = try await repo.saveReceiptDraft(.putaway(draft), replacing: nil)
        let preview = try await repo.reviewReceipt(draft, expected: initial.state, at: now)
        let batch = try XCTUnwrap(preview.batch)
        let marker = ProtectedReceiptDraftStore.Pending(operation: batch.operationID, request: batch.request)
        try files.mark(scope, revision: saved.revision, expected: nil, next: marker)
        let beforeCommit = try await repo.savedReceiptDraft()
        XCTAssertEqual(beforeCommit?.revision, saved.revision)
        XCTAssertNil(try files.read(scope)?.finishing)
        let stillEmpty = try await repo.load(at: now)
        XCTAssertTrue(stillEmpty.lots.isEmpty)
        // Simulate a process stop immediately after the durable stock write.
        try files.mark(scope, revision: saved.revision, expected: nil, next: marker)
        try await repo.applyReceipt(preview, at: now)
        let afterCommit = try await repo.savedReceiptDraft()
        XCTAssertNil(afterCommit)
        var another = try receipt(store: inventory, lines: ["Brown rice"])
        another.reference = "TICKET-19"
        let next = try await repo.saveReceiptDraft(.putaway(another), replacing: nil)
        try await repo.applyReceipt(preview, finishingDraft: saved.revision, at: now)
        XCTAssertEqual(try files.read(scope)?.draft.revision, next.revision)
        let final = try await repo.load(at: now)
        XCTAssertEqual(final.state.revision, initial.state.revision + 1)
        XCTAssertEqual(final.lots.map(\.name), ["Dry beans"])
        another.lines[0].treatment = .add; another.lines[0].received = "1"; another.lines[0].usable = "1"
        let reviewedAnother = try await repo.reviewReceipt(another, expected: final.state, at: now)
        do {
            try await repo.applyReceipt(reviewedAnother, finishingDraft: saved.revision, at: now)
            XCTFail("An editor with an obsolete revision finished a different receipt")
        } catch ProtectedReceiptDraftStore.Failure.changed {}
        try await repo.applyReceipt(reviewedAnother, finishingDraft: next.revision, at: now)
        try await repo.applyReceipt(reviewedAnother, finishingDraft: next.revision, at: now)
        let finalTwo = try await repo.load(at: now)
        XCTAssertEqual(finalTwo.state.revision, initial.state.revision + 2)
        XCTAssertEqual(Set(finalTwo.lots.map(\.name)), ["Dry beans", "Brown rice"])
        XCTAssertNil(try files.read(scope))
        let discard = try await repo.saveReceiptDraft(.putaway(another), replacing: nil)
        try await repo.discardReceiptDraft(revision: discard.revision)
        XCTAssertNil(try files.read(scope))
    }

    func testPesoPricesSaveWithReceiptAndPutawayQuantities() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token), at: now)
        let repo = PantryRepository(store: store, aliasPersonaID: UUID(), authorize: { true })
        cleanup.track(repo)
        let model = PantryModel(repository: repo, clock: { self.now })
        await model.load()
        var draft = try receipt(store: store, lines: ["Frijoles 2 unidades MXN $40,50", "IVA $6.48", "Total pagado MXN 46.98"])
        XCTAssertEqual(draft.currency, .mxn)
        draft.lines[0].selectIntact(deliveries: [])
        XCTAssertEqual(draft.lines[0].usable, "2")
        draft.lines[0].paid = try XCTUnwrap(draft.lines[0].printed?.amount)
        draft.lines[1].treatment = .chargeOrReturn
        draft.lines[1].paid = "6.48"
        draft.receiptTotal = "46.98"
        draft.changeCurrency(.usd)
        XCTAssertEqual(draft.currency, .mxn)
        XCTAssertEqual(draft.receiptTotal, "46.98")
        let review = try await model.reviewReceipt(draft)
        try await model.saveReceipt(review)
        XCTAssertEqual(review.facts.first?.paidLineTotal, Money(minorUnits: 4050, currency: .mxn))
        let headers = try await model.reviewedReceiptHeaders(after: nil)
        let saved = try XCTUnwrap(headers.first)
        XCTAssertEqual(saved.currencyCode, "MXN")
        XCTAssertEqual(saved.totalMinor, 4698)
        let rows = try await model.reviewedReceiptDecisions(saved.id, after: nil)
        var copy = ReviewedReceiptCopySelection()
        copy.total = true
        copy.amounts = Set(rows.map(\.id))
        XCTAssertTrue(copy.text(header: saved, purchaseDay: "", rows: rows).contains("MXN"))
    }

    func testExactImportedFileCanReopenOnlyItsOwnersSavedReceiptBeforeReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token), at: now)
        var allowed = true
        let owner = UUID()
        let repo = PantryRepository(store: store, aliasPersonaID: owner, authorize: { allowed })
        cleanup.track(repo)
        let model = PantryModel(repository: repo, clock: { self.now })
        await model.load()
        let bytes = Data("Soup 2.40\nFee 1.00".utf8)
        let document = try await ReceiptDocumentReader().extract(.init(data: bytes, kind: .text))
        let target = CaptureTarget(workspaceID: store.workspaceID, containerID: UUID(), objectID: UUID(),
                                   revision: 1, kind: .receiptEvidence)
        let source = try document.source(target: target, merchant: "Mercado", stage: .receipt,
                                         selection: [.init(page: 1, line: 1), .init(page: 1, line: 2)], at: now)
        var imported = try ReceiptImportDraft(source: source, now: now)
        imported.tracksPutaway = true
        imported.dateConfirmed = true
        imported.reference = "FILE-18"
        imported.lines[0].treatment = .eaten
        imported.lines[1].treatment = .chargeOrReturn

        var manual = try receipt(store: store, lines: ["Soup 2.40", "Fee 1.00"])
        manual.lines[0].treatment = .eaten
        let manualReview = try await model.reviewReceipt(manual)
        try await model.saveReceipt(manualReview)
        let beforeFile = try await model.savedReceipt(fileDigest: document.digest)
        XCTAssertNil(beforeFile)

        let review = try await model.reviewReceipt(imported)
        try await model.saveReceipt(review)
        let state = try await store.inventoryState()
        let reopened = try await model.savedReceipt(fileDigest: document.digest)
        XCTAssertEqual(reopened?.id, imported.receiptID)
        let savedDecisions = try await model.reviewedReceiptDecisions(imported.receiptID, after: nil)
        XCTAssertEqual(Set(savedDecisions.map(\.original)), Set(["Soup 2.40", "Fee 1.00"]))
        let alternate = try await ReceiptDocumentReader().extract(.init(data: bytes + Data([10]), kind: .text))
        XCTAssertNotEqual(alternate.digest, document.digest)
        let pdf = UIGraphicsPDFRenderer(bounds: CGRect(x: 0, y: 0, width: 320, height: 320)).pdfData { context in
            context.beginPage()
            ("Soup 2.40\nFee 1.00" as NSString).draw(at: CGPoint(x: 15, y: 15), withAttributes: nil)
        }
        let otherDocument = try await ReceiptDocumentReader().extract(.init(data: pdf, kind: .pdf))
        let otherMedium = try await model.savedReceipt(fileDigest: otherDocument.digest)
        XCTAssertNil(otherMedium)
        let otherBytes = try await model.savedReceipt(fileDigest: alternate.digest)
        let absent = try await model.savedReceipt(fileDigest: Data())
        XCTAssertNil(otherBytes)
        XCTAssertNil(absent)
        let outsider = PantryRepository(store: store, aliasPersonaID: UUID(), authorize: { true })
        let hidden = try await outsider.putawayReceipt(fileDigest: document.digest)
        XCTAssertNil(hidden)
        let afterLookup = try await store.inventoryState()
        XCTAssertEqual(afterLookup, state)
        let anotherReview = try await model.reviewReceipt(imported)
        XCTAssertNil(anotherReview.batch)
        allowed = false
        let revoked = try await model.savedReceipt(fileDigest: document.digest)
        XCTAssertNil(revoked)
    }

    func testReviewedReceiptCopyUsesOnlySelectedFieldsInTheLiveOwnerScope() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token), at: now)
        var allowed = true
        let owner = UUID()
        let repo = PantryRepository(store: store, aliasPersonaID: owner, authorize: { allowed })
        cleanup.track(repo)
        let model = PantryModel(repository: repo, clock: { self.now })
        await model.load()
        var draft = try receipt(store: store, lines: ["Soup 2.40", "Bread 1.10"])
        draft.lines[0].treatment = .eaten
        draft.lines[0].name = "Bean soup"
        draft.lines[0].paid = "2.40"
        draft.lines[1].treatment = .eaten
        draft.lines[1].paid = "1.10"
        draft.receiptTotal = "3.50"
        let review = try await model.reviewReceipt(draft)
        try await model.saveReceipt(review)
        let headers = try await model.reviewedReceiptHeaders(after: nil)
        let header = try XCTUnwrap(headers.first)
        let rows = try await model.reviewedReceiptDecisions(header.id, after: nil)
        let soup = try XCTUnwrap(rows.first { $0.name == "Bean soup" })
        XCTAssertTrue(model.permitsReceiptCopy(header))
        var selection = ReviewedReceiptCopySelection()
        func text() -> String { selection.text(header: header, purchaseDay: "Reviewed day", rows: rows) }
        XCTAssertEqual(text(), "")
        let linePrice = pantryFormat("Paid line total %@", receiptMoney(Money(minorUnits: 240)))
        selection.amounts.insert(soup.id)
        XCTAssertEqual(text(), linePrice)
        selection.names.insert(soup.id)
        XCTAssertEqual(text(), "Bean soup\n" + linePrice)
        selection.store = true
        selection.date = true
        selection.total = true
        selection.amounts.remove(soup.id)
        let total = putawayText("Paid receipt total") + " · " + receiptMoney(Money(minorUnits: 350))
        XCTAssertEqual(text(), [header.merchant, "Reviewed day", total, "Bean soup"].joined(separator: "\n"))

        for persona: UUID? in [UUID(), nil] {
            let scoped = PantryRepository(store: store, aliasPersonaID: persona, authorize: { true })
            cleanup.track(scoped)
            let other = PantryModel(repository: scoped)
            await other.load()
            XCTAssertFalse(other.permitsReceiptCopy(header))
        }
        allowed = false
        XCTAssertFalse(model.permitsReceiptCopy(header))
    }

    func testCurrentPurchaseAndSelectiveCopyFollowPriceCorrectionAndRemovalWithoutChangingHistoryOrTotal() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token), at: now)
        let owner = UUID()
        let repo = PantryRepository(store: store, aliasPersonaID: owner, authorize: { true })
        cleanup.track(repo)
        let model = PantryModel(repository: repo, clock: { self.now })
        await model.load()
        var draft = try receipt(store: store, lines: ["OAT MILK", "OAT MILK"])
        draft.currency = .usd
        draft.lines[0].treatment = .add
        draft.lines[0].received = "1"; draft.lines[0].usable = "1"
        draft.lines[1].treatment = .eaten
        let review = try await model.reviewReceipt(draft)
        try await model.saveReceipt(review)
        let headers = try await model.reviewedReceiptHeaders(after: nil)
        let header = try XCTUnwrap(headers.first)
        let original = try XCTUnwrap(review.facts.first)
        let firstState = try XCTUnwrap(model.snapshot?.state)
        let originalRows = try await model.currentPurchaseDecisions(header, after: nil, expected: firstState)
        XCTAssertEqual(originalRows.count, 2)
        XCTAssertTrue(originalRows.allSatisfy { $0.paidMinor == nil })
        try await model.correctReceiptPrice(original, total: Money(minorUnits: 329), reviewedState: firstState)
        let updated = try XCTUnwrap(model.snapshot?.state)
        let rows = try await model.currentPurchaseDecisions(header, after: nil, expected: updated)
        XCTAssertEqual(rows.first { $0.id == original.lineID }?.paidMinor, 329)
        XCTAssertNil(try XCTUnwrap(rows.first { $0.id != original.lineID }).paidMinor)
        XCTAssertNil(header.totalMinor)
        var selection = ReviewedReceiptCopySelection()
        selection.total = true
        XCTAssertEqual(selection.text(header: header, purchaseDay: "", rows: rows), "")
        selection.amounts.insert(original.lineID)
        XCTAssertEqual(selection.text(header: header, purchaseDay: "", rows: rows),
                       pantryFormat("Paid line total %@", receiptMoney(Money(minorUnits: 329))))
        let historical = try await model.reviewedReceiptDecisions(header.id, after: nil)
        XCTAssertEqual(historical, originalRows)
        let facts = try await model.receiptHistory(receiptID: header.id)
        XCTAssertEqual(facts.map(\.revision).sorted(), [1, 2])
        let latest = try XCTUnwrap(facts.first { $0.revision == 2 })
        let other = PantryRepository(store: store, aliasPersonaID: UUID(), authorize: { true })
        cleanup.track(other)
        do {
            _ = try await other.currentPurchaseDecisions(header, after: nil, expected: updated)
            XCTFail("Another adult could read the corrected amount")
        } catch PantryRepository.Failure.unauthorized {}
        try await model.correctReceiptPrice(latest, total: nil, reviewedState: updated)
        let afterRemoval = try XCTUnwrap(model.snapshot?.state)
        let cleared = try await model.currentPurchaseDecisions(header, after: nil, expected: afterRemoval)
        XCTAssertNil(try XCTUnwrap(cleared.first { $0.id == original.lineID }).paidMinor)
        XCTAssertEqual(selection.text(header: header, purchaseDay: "", rows: cleared), "")
        XCTAssertNil(header.totalMinor)
        let allFacts = try await model.receiptHistory(receiptID: header.id)
        XCTAssertEqual(allFacts.map(\.revision).sorted(), [1, 2, 3])
        XCTAssertEqual(allFacts.first { $0.revision == 2 }?.paidLineTotal?.minorUnits, 329)
    }

    func testPurchaseDayReopensAndExportsInBothLanguagesAndRescansAcrossTimeZones() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let url = directory.appendingPathComponent("pantry.sqlite")
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: 0, request: Data([1]), mode: .activate, sourceToken: token, writes: []))
        let owner = UUID()
        let repository = PantryRepository(store: store, aliasPersonaID: owner, authorize: { true })
        let source = SourceMediaRecord(id: UUID(), target: .init(workspaceID: store.workspaceID, containerID: UUID(), objectID: UUID(),
            revision: 1, kind: .receiptEvidence), originalText: "Beans", reviewedLabel: "Market", imageJPEG: nil, barcode: nil,
            receiptLines: [.init(originalText: "Beans")], capturedAt: now)
        func draft(zone: String, day: Int, reference: String) throws -> ReceiptImportDraft {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = try XCTUnwrap(TimeZone(identifier: zone))
            var receipt = try ReceiptImportDraft(source: source, now: now, timeZone: calendar.timeZone)
            receipt.selectedPurchaseDate = try XCTUnwrap(calendar.date(from: DateComponents(year: 2026, month: 11, day: day)))
            receipt.dateConfirmed = true
            receipt.tracksPutaway = true
            receipt.reference = reference
            receipt.lines[0].treatment = .add
            receipt.lines[0].received = "1"
            receipt.lines[0].usable = "1"
            return receipt
        }
        let eastern = try draft(zone: "America/New_York", day: 20, reference: "TICKET-18")
        let reviewed = try await repository.reviewReceipt(eastern, expected: store.inventoryState(), at: now)
        try await repository.applyReceipt(reviewed, at: now)
        try await store.close()
        let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
        cleanup.track(reopened)
        let reader = PantryRepository(store: reopened, aliasPersonaID: owner, authorize: { true })
        let headers = try await reader.putawayHeaders(after: nil)
        let header = try XCTUnwrap(headers.first)
        let facts = try await reader.acquisitionHistory(receiptID: header.id)
        XCTAssertEqual(header.purchaseDay, "2026-11-20")
        XCTAssertEqual(facts.first?.purchaseDay?.iso8601, header.purchaseDay)
        let western = try draft(zone: "America/Los_Angeles", day: 20, reference: "TICKET-18")
        XCTAssertNotEqual(eastern.purchaseDate, western.purchaseDate)
        let state = try await reopened.inventoryState()
        let replay = try await reader.reviewReceipt(western, expected: state, at: now)
        XCTAssertNil(replay.batch)
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try XCTUnwrap(western.purchaseTimeZone)
        var copy = ReviewedReceiptCopySelection()
        copy.date = true
        for (locale, expected) in [("en_US", "November 20, 2026"), ("es_US", "20 de noviembre de 2026")] {
            let wording = ReceiptDateDisplay.storedPurchaseDay(header.purchaseDay, recordedAt: header.date,
                locale: Locale(identifier: locale), calendar: calendar)
            XCTAssertEqual(copy.text(header: header, purchaseDay: wording, rows: []), expected)
            let legacy = ReceiptDateDisplay.storedPurchaseDay(nil, recordedAt: header.date, locale: Locale(identifier: locale), calendar: calendar)
            XCTAssertTrue(legacy.contains("UTC"))
            XCTAssertNotEqual(legacy, wording)
        }
        let differentDay = try draft(zone: "America/Los_Angeles", day: 19, reference: "TICKET-18")
        do {
            _ = try await reader.reviewReceipt(differentDay, expected: state, at: now)
            XCTFail("A conflicting day cannot extend the saved transaction.")
        } catch PantryReceiptError.changedEvidence {}
        let afterConflict = try await reopened.inventoryState()
        XCTAssertEqual(afterConflict, state)
    }

    func testKeptPortionCorrectionIdentifiesOriginalLineAndAcceptsFractions() {
        var row = ReceiptImportDraft.Line(id: UUID(), ordinal: 37, original: "Wrap 1.0 ct", name: "Wrap", treatment: .keptSome, received: "1")
        let issue = row.amountCorrection
        XCTAssertEqual(issue?.lineID, row.id)
        XCTAssertEqual(issue?.ordinal, 37)
        XCTAssertEqual(issue?.field, .usable)
        XCTAssertEqual(issue?.reason, .keptPortion)
        row.usable = "2"
        XCTAssertEqual(row.amountCorrection?.reason, .keptPortion)
        row.usable = "1/2"
        XCTAssertNil(row.amountCorrection)
        XCTAssertEqual(pantryPrintedQuantity("1.0", unit: .count), "1.0 " + pantryUnit(.count, singular: true))
        XCTAssertEqual(pantryPrintedQuantity("2/2", unit: .count), "2/2 " + pantryUnit(.count, singular: true))
        XCTAssertEqual(pantryPrintedQuantity("1/2", unit: .cup), "1/2 " + pantryUnit(.cup, singular: true))
        XCTAssertEqual(pantryPrintedQuantity("3/2", unit: .cup), "3/2 " + pantryUnit(.cup))
        XCTAssertEqual(pantryPrintedQuantity("2", unit: .count), "2 " + pantryUnit(.count))
    }

    func testMixedReceiptReopensAndReplaysOneTotalAndOnlyConfirmedFood() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let url = directory.appendingPathComponent("pantry.sqlite")
        let store = try ComparisonStore(url: url, inventoryEnabled: true)
        cleanup.track(store)
        let amount = Quantity(amount: .one, unit: .count, originalLiteral: "1")
        let delivery = UUID(), owner = UUID()
        let key = ReceiptKey(sourceEventID: "grocery-dropoff", orderLineID: UUID(), branchID: "Mercado", segmentID: "1")
        let command = InventoryCommand(id: UUID(), originID: store.workspaceID, lotID: delivery, eventID: UUID(),
            expectedRevision: nil, occurredAt: now, change: .create(.init(foodID: UUID(), name: "Milk", source: .receipt(originID: store.workspaceID, key: key),
                location: .fridge, unit: .count, count: .exact(amount), observedAt: now), observationID: UUID()))
        let writes = try PantryPersistenceCodec.writes(InventoryEngine.prepare(command, current: nil, at: now))
        let token = try await store.inventorySourceToken()
        try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token, writes: writes), at: now)
        let repo = PantryRepository(store: store, aliasPersonaID: owner, authorize: { true })
        cleanup.track(repo)
        let before = try await repo.load(at: now)
        let words = ["Jars 2 ct USD 4.00", "Cracked eggs 12 ct USD 2.75", "Missing bag 1 ct USD 2.00",
                     "Sandwich 1 ct USD 6.00", "Sandwich 1 ct USD 6.00", "Service fee USD 1.00", "Milk 1 ct USD 2.50"]
        var draft = try receipt(store: store, lines: words)
        XCTAssertTrue(draft.selectedLines.isEmpty)
        draft.receiptTotal = "24.25"
        draft.lines[0].selectIntact(deliveries: before.lots)
        XCTAssertEqual(draft.lines[0].usable, "2")
        for index in [1, 2, 5, 6] {
            XCTAssertFalse(draft.lines[index].permitsIntactSelection(deliveries: before.lots))
        }
        draft.lines[1].treatment = .add
        draft.lines[1].received = "12"
        draft.lines[1].usable = "9"
        draft.lines[2].treatment = .missing
        draft.lines[3].treatment = .eaten
        draft.lines[4].treatment = .keptSome
        draft.lines[4].received = "1"
        draft.lines[4].usable = "1/2"
        draft.lines[4].location = .fridge
        draft.lines[5].treatment = .chargeOrReturn
        draft.lines[5].paid = "1.00"
        draft.lines[6].treatment = .link(delivery)
        draft.lines[6].received = "1"
        draft.lines[6].usable = "1"
        let review = try await repo.reviewReceipt(draft, expected: before.state, at: now)
        XCTAssertEqual(review.newStockLineCount, 3)
        XCTAssertEqual(review.putaway?.decisions.map(\.original), words)
        XCTAssertEqual(review.facts.count, 4)
        try await repo.applyReceipt(review, at: now)
        let reopenedStore = try ComparisonStore(url: url, inventoryEnabled: true)
        cleanup.track(reopenedStore)
        let reopened = PantryRepository(store: reopenedStore, aliasPersonaID: owner, authorize: { true })
        cleanup.track(reopened)
        try await reopened.applyReceipt(review, at: now)
        let after = try await reopened.load(at: now)
        let byName = Dictionary(uniqueKeysWithValues: after.lots.map { ($0.name, $0) })
        XCTAssertEqual(byName.count, 4)
        XCTAssertEqual(byName["Jars"]?.count.quantity?.amount, try Rational(2))
        XCTAssertEqual(byName["Cracked eggs"]?.count.quantity?.amount, try Rational(9))
        XCTAssertEqual(byName["Sandwich"]?.count.quantity?.amount, try Rational(1, 2))
        XCTAssertEqual(byName["Milk"]?.id, delivery)
        XCTAssertEqual(byName["Milk"]?.count.quantity?.amount, .one)
        let headers = try await reopened.putawayHeaders(after: nil)
        XCTAssertEqual(headers.map(\.totalMinor), [2425])
        let saved = try await reopened.putawayDecisions(receiptID: draft.receiptID, after: nil).sorted { $0.ordinal < $1.ordinal }
        XCTAssertEqual(saved.map(\.original), words)
        XCTAssertEqual(saved.map(\.kind), [.stored, .stored, .missing, .eaten, .keptSome, .chargeOrReturn, .linked])
        XCTAssertEqual(saved.filter { $0.lotID == nil }.count, 3)
        XCTAssertEqual(saved.last?.lotID, delivery)
        let repeatReview = try await reopened.reviewReceipt(draft, expected: after.state, at: now)
        XCTAssertEqual(repeatReview.newStockLineCount, 0)
        XCTAssertNil(repeatReview.batch)
        let outsider = PantryRepository(store: reopenedStore, aliasPersonaID: UUID(), authorize: { true })
        let hidden = try await outsider.putawayHeaders(after: nil)
        XCTAssertTrue(hidden.isEmpty)
        draft.lines[3].treatment = .add
        draft.lines[3].received = "1"; draft.lines[3].usable = "1"
        do { _ = try await reopened.reviewReceipt(draft, expected: after.state, at: now); XCTFail("A consumed line must not add stock on replay") }
        catch PantryReceiptError.changedEvidence {}
    }

    func testCouponReviewReadsOnlyCommittedPurchasedAndPrintedDiscountRows() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token), at: now)
        let owner = UUID()
        let repo = PantryRepository(store: store, aliasPersonaID: owner, authorize: { true })
        cleanup.track(repo)
        let model = PantryModel(repository: repo, clock: { self.now })
        await model.load()
        var draft = try receipt(store: store, lines: [
            "Beans USD 2.00", "Tax USD 1.00", "Coupon -1.00", "Coffee USD 1.00", "Discount -0.50"
        ])
        draft.lines[0].treatment = .eaten
        for index in [1, 2, 3] { draft.lines[index].treatment = .chargeOrReturn }
        let review = try await model.reviewReceipt(draft)
        let header = try XCTUnwrap(review.putaway?.header)
        do {
            _ = try await SavedCouponReceipt.load(header: header, from: model, authorize: { true })
            XCTFail("A draft receipt must never supply evidence")
        } catch PantryReceiptError.stale { }
        try await model.saveReceipt(review)
        let saved = try await SavedCouponReceipt.load(header: header, from: model, authorize: { true })
        XCTAssertEqual(saved.products.map(\.original), ["Beans USD 2.00"])
        XCTAssertEqual(saved.discounts.map(\.original), ["Coupon -1.00"])
        let item = try XCTUnwrap(saved.products.first)
        let print = try XCTUnwrap(saved.discounts.first)
        let day = try MealDay(date: header.date, timeZoneIdentifier: "UTC")
        let check = CouponPackCheck(packCount: 2, size: .matches)
        let proof = try XCTUnwrap(saved.evidence(itemID: item.id, day: day, check: check,
            discount: .printed(lineID: print.id, wording: print.original, amount: Money(minorUnits: 100))))
        XCTAssertEqual(proof.receiptID, header.id)
        XCTAssertEqual(proof.itemLineID, item.id)
        XCTAssertEqual(proof.savings, Money(minorUnits: 100))
        XCTAssertNil(saved.evidence(itemID: item.id, day: day, check: check,
            discount: .printed(lineID: item.id, wording: print.original, amount: Money(minorUnits: 100))))
        let other = PantryRepository(store: store, aliasPersonaID: UUID(), authorize: { true })
        cleanup.track(other)
        let outsider = PantryModel(repository: other, clock: { self.now })
        await outsider.load()
        do {
            _ = try await SavedCouponReceipt.load(header: header, from: outsider, authorize: { true })
            XCTFail("Another receipt owner must not supply coupon evidence")
        } catch ComparisonStoreError.operationConflict { }
    }

    func testTypedReceiptKeepsCorrectedFieldsSeparateFromConfirmedStockAndPayment() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token), at: now)
        let repo = PantryRepository(store: store, authorize: { true })
        cleanup.track(repo)
        let text = "2x Canned lentils 3.20\nPlain yogurt 2.40\nHot lunch 5.00\nService fee 0.45"
        let scan = ScanModel(text: text, capturedAt: now)
        var rows = try ScanLimits.receiptLines(scan.text)
        let original = rows[0].originalText
        rows[0].quantityNote = "2 units"
        rows[0].priceNote = "USD 3.20"
        let target = CaptureTarget(workspaceID: store.workspaceID, containerID: UUID(), objectID: UUID(),
                                   revision: 1, kind: .receiptEvidence)
        XCTAssertThrowsError(try scan.reviewed(target: target, label: "Market", barcode: nil, receiptLines: rows))
        scan.confirmed = true
        let source = try scan.reviewed(target: target, label: "Market", barcode: nil, receiptLines: rows)
        XCTAssertEqual(source.originalText, text)
        var draft = try ReceiptImportDraft(source: source, now: now)
        draft.purchaseDate = now
        draft.tracksPutaway = true
        draft.dateConfirmed = true
        XCTAssertTrue(draft.selectedLines.isEmpty)
        XCTAssertTrue(draft.lines[0].received.isEmpty)
        XCTAssertTrue(draft.lines[0].usable.isEmpty)
        XCTAssertTrue(draft.lines[0].paid.isEmpty)
        XCTAssertEqual(draft.lines[0].printed?.quantity, "2")
        XCTAssertEqual(draft.lines[0].printed?.priceWording, "USD 3.20")
        draft.lines[0].treatment = .add
        draft.lines[0].usePrintedQuantity()
        XCTAssertTrue(draft.lines[0].usable.isEmpty)
        draft.lines[0].usable = draft.lines[0].received
        let before = try await store.inventoryState()
        let unpaid = try await repo.reviewReceipt(draft, expected: before, at: now)
        XCTAssertNil(unpaid.facts.first?.paidLineTotal)
        draft.lines[0].paid = try XCTUnwrap(draft.lines[0].printed?.amount)
        let preview = try await repo.reviewReceipt(draft, expected: before, at: now)
        XCTAssertEqual(preview.putaway?.decisions.map(\.original), [original])
        XCTAssertEqual(preview.facts.first?.paidLineTotal?.minorUnits, 320)
        XCTAssertNil(preview.putaway?.header.totalMinor)
        try await repo.applyReceipt(preview, at: now)
        let after = try await repo.load(at: now)
        XCTAssertEqual(after.lots.map(\.name), ["Canned lentils"])
        XCTAssertEqual(after.lots.first?.count.quantity?.amount, try Rational(2))
        let saved = try await repo.putawayDecisions(receiptID: draft.receiptID, after: nil)
        XCTAssertEqual(saved.map(\.original), [original])
        XCTAssertEqual(saved.first?.paidMinor, 320)
    }

    func testNoStockReceiptKeepsUnknownTotalAndPackRequiresIndividualReview() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
            request: Data([1]), mode: .activate, sourceToken: token), at: now)
        let repo = PantryRepository(store: store, authorize: { true })
        cleanup.track(repo)
        var draft = try receipt(store: store, lines: ["Lunch USD 8.00", "Juice 2 x 6-pack USD 12.00"])
        draft.lines[0].treatment = .eaten
        draft.lines[0].paid = "8.00"
        draft.lines[1].selectIntact(deliveries: [])
        XCTAssertEqual(draft.lines[1].treatment, .skip)
        let state = try await store.inventoryState()
        let noStock = try await repo.reviewReceipt(draft, expected: state, at: now)
        XCTAssertNil(noStock.putaway?.header.totalMinor)
        XCTAssertTrue(noStock.facts.isEmpty)
        try await repo.applyReceipt(noStock, at: now)
        let after = try await repo.load(at: now)
        XCTAssertTrue(after.lots.isEmpty)
        draft.lines[1].treatment = .add
        draft.lines[1].received = "2"; draft.lines[1].usable = "2"
        do { _ = try await repo.reviewReceipt(draft, expected: after.state, at: now); XCTFail("Confirm package unit first") }
        catch PantryReceiptError.invalid {}
        draft.lines[1].checkedPack = true
        let packs = try await repo.reviewReceipt(draft, expected: after.state, at: now)
        XCTAssertEqual(packs.facts.first?.usable.amount, try Rational(2))
    }
}
