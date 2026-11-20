import CoreDomain
import LocalStore
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
        XCTAssertNil(repeatReview.batch)
        let outsider = PantryRepository(store: reopenedStore, aliasPersonaID: UUID(), authorize: { true })
        let hidden = try await outsider.putawayHeaders(after: nil)
        XCTAssertTrue(hidden.isEmpty)
        draft.lines[3].treatment = .add
        draft.lines[3].received = "1"; draft.lines[3].usable = "1"
        do { _ = try await reopened.reviewReceipt(draft, expected: after.state, at: now); XCTFail("A consumed line must not add stock on replay") }
        catch PantryReceiptError.changedEvidence {}
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
