import CoreDomain
import LocalStore
import XCTest
@testable import RoomInTheCart

@MainActor
final class PantryOrganizationTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func database() async throws -> ComparisonStore {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let cleanup = SQLiteFixtureDirectory(directory, test: self)
        let store = try ComparisonStore(url: directory.appendingPathComponent("inventory.sqlite"), inventoryEnabled: true)
        cleanup.track(store)
        let token = try await store.inventorySourceToken()
        let state = try await store.inventoryState()
        _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(),
            expectedRevision: state.revision, request: Data("activate".utf8), mode: .activate, sourceToken: token), at: now)
        return store
    }

    private func preview(_ csv: String, _ snapshot: PantryRepository.Snapshot) throws -> PantryCSVPreview {
        let table = try GroceryCSVTable(data: Data(csv.utf8))
        return try .init(table: table, mapping: PantryCSVField.suggest(table.headers), sourceName: "Cocina",
                         defaultLocation: .cupboard, basis: snapshot.state, lots: snapshot.lots)
    }

    private func apply(_ rows: [PantryCSVPreview.Row], _ repo: PantryRepository, _ basis: InventoryState) async throws {
        try await repo.applyOrganization(rows.map { try PantryCSVPreview.edit($0, origin: repo.originID) },
                                         basis: basis, at: now)
    }

    func testCSVInterruptedReimportAndChangedSourceRemainSeparateFromStock() async throws {
        let store = try await database()
        var allowed = true
        let repo = PantryRepository(store: store, authorize: { allowed })
        let initial = try await repo.load(at: now)
        let header = "Lote;Nombre;Cantidad;Unidad;Fecha;Ubicación;Código de barras;Nota"
        let csv = ([header] + (1...35).map { "lote-\($0);Chícharos;1,25;kg;01/02/26;Congelador;0000315;\"tapa; azul\"" }).joined(separator: "\n")
        let first = try preview(csv, initial)
        XCTAssertEqual(first.changes.count, 35)
        try await apply(Array(first.changes.prefix(32)), repo, initial.state)
        let partial = try await repo.load(at: now)
        let reopened = try preview(csv, partial)
        XCTAssertEqual(reopened.changes.count, 3)
        try await apply(reopened.changes, repo, partial.state)
        let complete = try await repo.load(at: now)
        XCTAssertEqual(complete.lots.count, 35)
        XCTAssertEqual(Set(complete.lots.map(\.id)).count, 35)
        XCTAssertTrue(complete.lots.allSatisfy { $0.count == .unknown && $0.location == .freezer })
        XCTAssertTrue(try preview(csv, complete).changes.isEmpty)
        let changed = csv.replacingOccurrences(of: "lote-7;Chícharos;1,25", with: "lote-7;Chícharos;2,75")
        let update = try preview(changed, complete)
        XCTAssertEqual(update.changes.count, 1)
        XCTAssertEqual(update.changes[0].status, .update)
        let cancelled = try await repo.load(at: now)
        XCTAssertEqual(cancelled.state, complete.state)
        let target = try XCTUnwrap(complete.lots.first { $0.id == update.changes[0].lotID })
        XCTAssertEqual(target.spreadsheetRow?.barcode, "0000315")
        XCTAssertEqual(target.spreadsheetRow?.date, "01/02/26")
        XCTAssertEqual(target.spreadsheetRow?.note, "tapa; azul")
        XCTAssertEqual(target.spreadsheetRow?.quantity, "1,25")
        allowed = false
        do { try await apply(update.changes, repo, complete.state); XCTFail("Access was revoked") } catch {}
        allowed = true
        try await apply(update.changes, repo, complete.state)
        let saved = try await repo.load(at: now)
        let updated = try XCTUnwrap(saved.lots.first { $0.id == target.id })
        XCTAssertEqual(updated.observationID, target.observationID)
        XCTAssertEqual(updated.count, .unknown)
        XCTAssertEqual(updated.spreadsheetRow?.quantity, "2,75")
        XCTAssertTrue(try preview(changed, saved).changes.isEmpty)
        let restored = try PantryArchiveRestore.baselineLot(updated, newOriginID: UUID(), restorationID: UUID())
        XCTAssertEqual(restored.spreadsheetRow, updated.spreadsheetRow)
    }

    func testOrdinalOnlyReorderAndRepeatedLotKeysCannotIntroduceExtraStock() async throws {
        let store = try await database()
        let repo = PantryRepository(store: store, authorize: { true })
        let empty = try await repo.load(at: now)
        let original = "Nombre;Fecha;Ubicación\nChícharos;04/05/26;Canasta azul\nChícharos;18/05/26;Congelador"
        let first = try preview(original, empty)
        XCTAssertEqual(first.rows[0].issues, [.unknownPlace, .ambiguousDate])
        try await apply(first.changes, repo, empty.state)
        let current = try await repo.load(at: now)
        let shifted = "Nombre;Fecha;Ubicación\nMaíz;;Despensa\nChícharos;04/05/26;Canasta azul\nChícharos;18/05/26;Congelador"
        XCTAssertTrue(try preview(shifted, current).changes.isEmpty)
        let repeated = try preview("Lote;Nombre\n00;Maíz\n00;Queso\n ;Piña", current)
        XCTAssertTrue(repeated.rows.allSatisfy { $0.status == .invalid && $0.issues.contains(.lotKey) })
    }

    func testPutAwayTwelveLotsPreservesClaimsDatesAndDetectsInterveningUndoConflict() async throws {
        let store = try await database()
        let repo = PantryRepository(store: store, authorize: { true })
        let initial = try await repo.load(at: now)
        let csv = (["Lote;Nombre;Ubicación"] + (1...12).map { "\($0);Chícharos;Congelador" }).joined(separator: "\n")
        try await apply(try preview(csv, initial).changes, repo, initial.state)
        let imported = try await repo.load(at: now)
        let target = try XCTUnwrap(imported.lots.first)
        let observed = InventoryCommand(id: UUID(), originID: repo.originID, lotID: target.id, eventID: UUID(),
            expectedRevision: target.revision, occurredAt: now,
            change: .count(.exact(.init(amount: try Rational(3), unit: .count, originalLiteral: "3")), observationID: UUID()))
        let result = try await repo.apply(observed, reviewedInventoryRevision: imported.state.revision, at: now)
        let claim = InventoryReservation(id: UUID(), originID: repo.originID, revision: 1, foodID: target.foodID,
            lotID: target.id, name: "Dinner", amount: .init(amount: .one, unit: .count, originalLiteral: "1"))
        _ = try await store.commitInventory(.init(workspaceID: repo.originID, operationID: UUID(),
            expectedRevision: result.current.state.revision, request: Data("hold".utf8),
            writes: [try PantryPersistenceCodec.write(claim, expectedRevision: 0)]), at: now)
        let before = try await repo.load(at: now)
        let garage = InventoryNamedPlace(storage: "Garage", drawer: "Top drawer")
        let kitchen = InventoryNamedPlace(storage: "Kitchen", drawer: "Top drawer")
        let plan = try PantryPutaway(storage: .freezer, destination: garage, selection: Set(before.lots.map(\.id)),
                                    lots: before.lots, basis: before.state)
        try await repo.applyOrganization(plan.edits(undo: false), basis: before.state, at: now)
        let moved = try await repo.load(at: now)
        XCTAssertEqual(moved.reservations, before.reservations)
        for lot in moved.lots {
            let old = try XCTUnwrap(before.lots.first { $0.id == lot.id })
            XCTAssertEqual(lot.namedPlace, garage)
            XCTAssertEqual(lot.count, old.count)
            XCTAssertEqual(lot.confirmedAt, old.confirmedAt)
            XCTAssertEqual(lot.observationID, old.observationID)
            XCTAssertTrue(lot.retainsPhysicalState(at: old.revision))
        }
        try await repo.applyOrganization(plan.edits(undo: true), basis: moved.state, at: now)
        let reverted = try await repo.load(at: now)
        XCTAssertTrue(reverted.lots.allSatisfy { $0.namedPlace == nil })
        let again = try PantryPutaway(storage: .freezer, destination: garage, selection: Set(before.lots.map(\.id)),
                                     lots: reverted.lots, basis: reverted.state)
        try await repo.applyOrganization(again.edits(undo: false), basis: reverted.state, at: now)
        let saved = try await repo.load(at: now)
        let one = try PantryPutaway(storage: .freezer, destination: kitchen, selection: [target.id], lots: saved.lots, basis: saved.state)
        try await repo.applyOrganization(one.edits(undo: false), basis: saved.state, at: now)
        let newer = try await repo.load(at: now)
        let edited = try XCTUnwrap(newer.lots.first { $0.id == target.id })
        XCTAssertNotEqual(pantryPlacePath(.freezer, garage), pantryPlacePath(.freezer, kitchen))
        XCTAssertEqual(try PantryArchiveRestore.baselineLot(edited, newOriginID: UUID(), restorationID: UUID()).namedPlace, kitchen)
        do { try await repo.applyOrganization(again.edits(undo: true), basis: newer.state, at: now); XCTFail("Stale undo") } catch {}
        let intact = try await repo.load(at: now)
        XCTAssertEqual(intact.lots, newer.lots)
        XCTAssertEqual(intact.reservations, before.reservations)
    }
}
