import CoreDomain
import Foundation
import LocalStore
import RecordArchive
import XCTest
@testable import RoomInTheCart

@MainActor final class PantryArchivePrivacyValidatorTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private struct Fixture {
        let root: URL
        let cleanup: SQLiteFixtureDirectory
        let inventory: ComparisonStore
        let ledger: LedgerStore
        let worker: PantryArchiveWorker
        let gate: PantryMutationGate
    }

    private func fixture() throws -> Fixture {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(root, test: self)
        let inventory = try ComparisonStore(url: root.appendingPathComponent("inventory.sqlite"), inventoryEnabled: true)
        let ledger = try LedgerStore(url: root.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        cleanup.track(inventory, ledger)
        return .init(root: root, cleanup: cleanup, inventory: inventory, ledger: ledger,
                     worker: try PantryArchiveWorker(root: root.appendingPathComponent("bundles")), gate: PantryMutationGate())
    }

    private func archive(_ f: Fixture, origin: UUID, items: [PantryArchiveCodec.Item],
                         evidence: [PantryArchiveWorker.Evidence] = [], ledgerID: UUID? = nil) async throws -> PantryArchiveHandle {
        let descriptor = PantryArchiveCodec.Descriptor(originID: origin, inventoryRevision: 2, capturedAt: now)
        let job = try await f.worker.begin(descriptor: descriptor)
        let scope = PantryArchiveCapture.Scope(version: 1, inventoryOriginID: origin, inventoryRevision: 2,
            sourceToken: .init(workspaceID: origin, generation: 0, digest: Data(repeating: 0, count: 32)),
            ledgerOriginID: ledgerID ?? f.ledger.workspaceID, ledgerRevision: 0, ledgerOperationID: nil, ledgerPayloadDigest: nil,
            pendingDigest: nil, foodPendingDigest: nil, packPendingDigest: nil, capturedAt: now)
        for item in items { try await f.worker.append(ArchiveCodec.canonical(item), to: job) }
        for value in evidence { try await f.worker.appendEvidence(value, to: job) }
        return try await f.worker.finish(job, scope: .paired(scope))
    }

    private func validate(_ handle: PantryArchiveHandle, _ f: Fixture, ledger: LedgerStore? = nil) async throws {
        try await PantryArchivePrivacyValidator.validate(handle, worker: f.worker, inventory: f.inventory,
            ledger: ledger ?? f.ledger, gate: f.gate, authorize: { true })
    }
    private func expectRetired(_ handle: PantryArchiveHandle, _ f: Fixture, ledger: LedgerStore? = nil,
                               file: StaticString = #filePath, line: UInt = #line) async throws {
        do { try await validate(handle, f, ledger: ledger); XCTFail("Archive contained retired data", file: file, line: line) }
        catch PantryArchivePrivacyValidator.Failure.retired { }
    }
    private func activate(_ f: Fixture, _ writes: [InventoryWrite]) async throws {
        let token = try await f.inventory.inventorySourceToken()
        _ = try await f.inventory.commitInventory(.init(workspaceID: f.inventory.workspaceID, operationID: UUID(),
            expectedRevision: 0, request: Data([1]), mode: .activate, sourceToken: token, writes: writes), at: now)
    }
    private func erase(_ f: Fixture, _ entries: [InventoryErasureEntry]) async throws {
        let token = try await f.inventory.inventorySourceToken()
        _ = try await f.inventory.eraseInventory(workspaceID: f.inventory.workspaceID, operationID: UUID(),
            expectedRevision: 1, sourceToken: token, entries: entries, at: now)
    }

    func testRedactedBodyInForeignHistoryRejectedUnderNewBundleIDAndLaterCleanBodyAdmitted() async throws {
        let f = try fixture(), ns = f.inventory.workspaceID
        let old = InventoryReservation(id: UUID(), originID: ns, revision: 1, foodID: UUID(), lotID: nil,
            name: "Private promise", amount: nil, state: .unresolved)
        let clean = InventoryReservation(id: old.id, originID: ns, revision: 2, foodID: old.foodID, lotID: nil,
            name: "Unresolved", amount: nil, state: .unresolved)
        let key = InventoryRecordKey(.reservation, old.id)
        try await activate(f, [.init(record: .init(key: key, revision: 1, payload: ArchiveCodec.canonical(old)), expectedRevision: 0)])
        let before = try await archive(f, origin: ns, items: [.reservation(old)])
        try await validate(before, f)
        try await erase(f, [.reservation(.init(record: .init(key: key, revision: 2, payload: ArchiveCodec.canonical(clean)), expectedRevision: 1))])
        try await expectRetired(before, f)
        let foreign = try await archive(f, origin: UUID(), items: [.historical(.originalReservation(old))])
        XCTAssertNotEqual(before.reference.bundleID, foreign.reference.bundleID)
        try await expectRetired(foreign, f)
        let later = try await archive(f, origin: ns, items: [.reservation(clean)], evidence: [
            .current(.inventoryRetired(key: key, originID: ns, revision: 1, operationID: UUID()))
        ])
        try await validate(later, f)
        let retained = try await f.inventory.inventoryRecord(key)
        XCTAssertEqual(retained?.revision, 2)
    }

    func testRetiredSourceWithNewLotIDAndNestedComparisonHistory() async throws {
        let f = try fixture(), ns = f.inventory.workspaceID
        let command = InventoryCommand(id: UUID(), originID: ns, lotID: UUID(), eventID: UUID(), expectedRevision: nil,
            occurredAt: now, change: .create(.init(foodID: UUID(), name: "Original", source: .manual(originID: ns, sourceID: UUID()),
                location: .fridge, unit: .count, count: .someLeft), observationID: UUID()))
        let prepared = try InventoryEngine.prepare(command, current: nil, at: now)
        let writes = try PantryPersistenceCodec.writes(prepared)
        var journey = PickupJourney(id: UUID(), savedAt: now)
        let legacyID = UUID()
        journey.stockLots = [.init(id: legacyID, foodID: legacyID, name: "Saved food",
            usable: .init(amount: try Rational(1), unit: .count, originalLiteral: "1"), confirmedAt: now, source: .pantry)]
        try PickupModel.validate(journey)
        let saved = try await f.inventory.save(id: journey.id, title: "Shop", payload: ArchiveCodec.canonical(journey), savedAt: now)
        try await activate(f, writes)
        try await erase(f, writes.map { .record(.init(key: $0.record.key, expectedRevision: 1)) } +
            [.comparison(id: journey.id, expectedRevision: saved.revision)])
        let alias = InventoryLot(id: UUID(), foodID: UUID(), name: "Copied elsewhere", source: prepared.lot.source, revision: 1,
            location: .fridge, unit: .count, count: .someLeft, observationID: UUID(), confirmedAt: now, updatedAt: now)
        let sourceCopy = try await archive(f, origin: UUID(), items: [.historical(.originalLot(alias))])
        try await expectRetired(sourceCopy, f)
        let oldHead = try await archive(f, origin: UUID(), items: [.historical(.sourceHead(originID: ns, .init(saved)))])
        try await expectRetired(oldHead, f)
        let unrelatedHead = try await archive(f, origin: UUID(), items: [.historical(.sourceHead(originID: UUID(), .init(saved)))])
        try await validate(unrelatedHead, f)
    }

    func testLaterCorruptionTakesPrecedenceOverTentativeRetirementMatch() async throws {
        let f = try fixture(), ns = f.inventory.workspaceID
        let claim = InventoryReservation(id: UUID(), originID: ns, revision: 1, foodID: UUID(), lotID: nil,
            name: "Promise", amount: nil, state: .unresolved)
        let operation = UUID()
        let handle = try await archive(f, origin: ns, items: [.reservation(claim)], evidence: [
            .current(.comparisonRetired(id: UUID(), originID: ns, revision: 1, operationID: operation, at: now))
        ])
        let scopeURL = handle.directory.appendingPathComponent("scope-0.json")
        let original = try String(contentsOf: scopeURL, encoding: .utf8)
        let altered = original.replacingOccurrences(of: operation.uuidString, with: UUID().uuidString)
        XCTAssertNotEqual(original, altered)
        try Data(altered.utf8).write(to: scopeURL)
        let rules = PantryArchivePrivacyValidator.LocalRules(origin: ns, retiredOrigin: false, keys: [.init(.reservation, claim.id)])
        do {
            try await rules.check(handle, worker: f.worker)
            XCTFail("Tampered tail accepted")
        } catch PantryArchiveWorker.Failure.invalid { }
    }

    func testLedgerRetirementInPreviousScopeComparedAgainstReopenedPhysicalLedger() async throws {
        let f = try fixture(), oldLedgerID = f.ledger.workspaceID
        _ = try await f.ledger.eraseWorkspace(workspaceID: oldLedgerID, expectedRevision: 0, operationID: UUID(), at: now)
        let reopened = try LedgerStore(url: f.root.appendingPathComponent("ledger.sqlite"), inventoryProjectionsEnabled: true)
        f.cleanup.track(reopened)
        let former = UUID()
        let foreignScope = PantryArchiveCapture.Scope(version: 1, inventoryOriginID: former, inventoryRevision: 1,
            sourceToken: .init(workspaceID: former, generation: 0, digest: Data(repeating: 0, count: 32)),
            ledgerOriginID: oldLedgerID, ledgerRevision: 0, ledgerOperationID: nil, ledgerPayloadDigest: nil,
            pendingDigest: nil, foodPendingDigest: nil, packPendingDigest: nil, capturedAt: now)
        let handle = try await archive(f, origin: UUID(), items: [.historical(.restoredFrom(.init(originID: former,
            inventoryRevision: 1, capturedAt: now)))], evidence: [.previousScope(.paired(foreignScope))], ledgerID: reopened.workspaceID)
        try await expectRetired(handle, f, ledger: reopened)
    }
}
