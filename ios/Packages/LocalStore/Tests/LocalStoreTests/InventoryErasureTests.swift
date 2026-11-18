import CSQLite
import Foundation
import XCTest

@testable import LocalStore

final class InventoryErasureTests: XCTestCase {
  private var directory: URL!
  private var url: URL { directory.appendingPathComponent("pickup.sqlite") }
  private let now = Date(timeIntervalSince1970: 1_800_000_000)
  override func setUpWithError() throws {
    directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
  }
  override func tearDownWithError() throws { try FileManager.default.removeItem(at: directory) }
  private func record(
    _ kind: InventoryRecordKind, id: UUID = UUID(), revision: Int64 = 1, lot: UUID? = nil,
    source: InventorySourceIdentity? = nil, payload: String = "private"
  ) -> InventoryRecord {
    .init(
      key: .init(kind, id), revision: revision, payload: Data(payload.utf8), lotID: lot,
      source: source)
  }
  private func activate(_ store: ComparisonStore, _ records: [InventoryRecord] = []) async throws {
    let token = try await store.inventorySourceToken()
    _ = try await store.commitInventory(
      .init(
        workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
        request: Data([1]), mode: .activate, sourceToken: token,
        writes: records.map { .init(record: $0, expectedRevision: 0) }), at: now)
  }
  private func append(_ store: ComparisonStore, _ values: [InventoryRecord]) async throws {
    for offset in stride(from: 0, to: values.count, by: 256) {
      let state = try await store.inventoryState()
      _ = try await store.commitInventory(
        .init(
          workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: state.revision,
          request: Data([2]),
          writes: values[offset..<min(offset + 256, values.count)].map {
            .init(record: $0, expectedRevision: $0.revision - 1)
          }), at: now)
    }
  }
  private func scalar(_ query: String) throws -> Int64 {
    let db = try ComparisonDatabase(url: url)
    defer { try? db.close() }
    return try db.integer(query)
  }
  private func sql(_ query: String) throws {
    let db = try ComparisonDatabase(url: url)
    defer { try? db.close() }
    try db.execute(query)
  }

  func testLargeGraphRedactsHistoryPreservesOtherFoodAndReplaysAfterReopen() async throws {
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    let source = try await store.save(
      id: UUID(), title: "Private delivery", payload: Data("secret old arrival".utf8), savedAt: now)
    _ = try await store.save(
      id: source.id, title: "Changed", payload: Data("secret corrected arrival".utf8), savedAt: now)
    let lot = record(.lot)
    let other = record(.lot, payload: "unrelated food")
    let claim = record(.reservation, lot: nil, payload: "old private promise")
    let pin = record(.reservation, lot: lot.key.id, payload: "pinned private promise")
    let link = record(
      .sourceLink, lot: lot.key.id,
      source: .init(originID: store.workspaceID, sourceID: "physical-arrival"))
    try await activate(store, [lot, other, claim, pin, link])
    let history = (0..<520).map {
      record(.observation, lot: lot.key.id, payload: "old count \($0)")
    }
    try await append(store, history)
    let current = try await store.inventoryState()
    let token = try await store.inventorySourceToken()
    let op = UUID()
    let sanitized = record(
      .reservation, id: pin.key.id, revision: 2, payload: "unresolved retained promise")
    let entries =
      ([lot, link] + history).map {
        InventoryErasureEntry.record(.init(key: $0.key, expectedRevision: 1))
      }
      + [
        .comparison(id: source.id, expectedRevision: 2),
        .reservation(.init(record: sanitized, expectedRevision: 1)),
      ]
    let receipt = try await store.eraseInventory(
      workspaceID: store.workspaceID, operationID: op, expectedRevision: current.revision,
      sourceToken: token, entries: entries, at: now)
    XCTAssertEqual(receipt.erasedRecordCount, 522)
    XCTAssertEqual(receipt.redactedReservationCount, 1)
    XCTAssertEqual(receipt.erasedComparisonCount, 1)
    let retained = try await store.inventoryRecord(other.key)
    let retainedClaim = try await store.inventoryRecord(claim.key)
    let redacted = try await store.inventoryRecord(pin.key)
    XCTAssertEqual(retained, other)
    XCTAssertEqual(retainedClaim, claim)
    XCTAssertEqual(redacted, sanitized)
    XCTAssertEqual(try scalar("SELECT count(*) FROM comparison_revisions"), 0)
    XCTAssertEqual(
      try scalar(
        "SELECT count(*) FROM inventory_revisions WHERE kind='reservation' AND id='\(pin.key.id.uuidString)'"
      ), 1)
    let markers = try await store.inventoryReservationRedactions(
      expectedInventoryRevision: receipt.revision)
    XCTAssertEqual(
      markers,
      [
        .init(
          workspaceID: store.workspaceID, reservationID: pin.key.id, throughRevision: 1,
          operationID: op, previousLotID: lot.key.id)
      ])
    let changed = record(.lot, id: other.key.id, revision: 2, payload: "later independent recount")
    try await append(store, [changed])
    try await store.close()
    let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
    let retry = try await reopened.eraseInventory(
      workspaceID: reopened.workspaceID, operationID: op, expectedRevision: current.revision,
      sourceToken: token, entries: entries, at: now.addingTimeInterval(100))
    XCTAssertEqual(retry, receipt)
    let later = try await reopened.inventoryRecord(other.key)
    XCTAssertEqual(later, changed)
    do {
      _ = try await reopened.eraseInventory(
        workspaceID: reopened.workspaceID, operationID: op, expectedRevision: current.revision,
        sourceToken: token, entries: Array(entries.dropLast()), at: now)
      XCTFail("changed body")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
    do {
      try await append(reopened, [lot])
      XCTFail("old source identity")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    try await reopened.close()
  }

  func testStagedGraphRollbackHasNoPartialVisibilityAndExactRestartFinish() async throws {
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    let values = (0..<600).map { record(.intent, payload: "private pending \($0)") }
    try await activate(store)
    try await append(store, values)
    let state = try await store.inventoryState()
    let token = try await store.inventorySourceToken()
    let op = UUID()
    var chunks: [InventoryErasureChunk] = []
    var digest = InventoryErasureManifest.initialDigest
    for offset in stride(from: 0, to: values.count, by: 200) {
      let chunk = InventoryErasureChunk(
        index: Int64(chunks.count),
        entries: values[offset..<min(offset + 200, values.count)].map {
          .record(.init(key: $0.key, expectedRevision: 1))
        })
      digest = try InventoryErasureManifest.appending(chunk, to: digest)
      chunks.append(chunk)
    }
    let plan = InventoryErasureManifest(
      workspaceID: store.workspaceID, operationID: op, expectedRevision: state.revision,
      sourceToken: token, chunkCount: 3, entryCount: 600, manifestDigest: digest)
    _ = try await store.beginInventoryErasure(plan)
    _ = try await store.stageInventoryErasure(id: op, chunk: chunks[0])
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 600)
    try await store.close()
    let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
    _ = try await reopened.stageInventoryErasure(id: op, chunk: chunks[0])
    for chunk in chunks.dropFirst() {
      _ = try await reopened.stageInventoryErasure(id: op, chunk: chunk)
    }
    try sql(
      "CREATE TRIGGER force_erase_failure BEFORE DELETE ON inventory_heads WHEN OLD.id='\(values[300].key.id.uuidString)' BEGIN SELECT RAISE(ABORT,'injected'); END"
    )
    do {
      _ = try await reopened.finishInventoryErasure(id: op, at: now)
      XCTFail("injected failure")
    } catch ComparisonStoreError.database {}
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 600)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_tombstones"), 0)
    let unchanged = try await reopened.inventoryState()
    XCTAssertEqual(unchanged, state)
    try sql("DROP TRIGGER force_erase_failure")
    let receipt = try await reopened.finishInventoryErasure(id: op, at: now)
    XCTAssertEqual(receipt.erasedRecordCount, 600)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 0)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_erasure_entries"), 0)
    let retry = try await reopened.finishInventoryErasure(id: op, at: now.addingTimeInterval(1))
    XCTAssertEqual(retry, receipt)
    try await reopened.close()
  }

  func testOriginRetirementPurgesEveryHistoryAndFencesOldAndReopenedActors() async throws {
    let old = try ComparisonStore(url: url)
    let saved = try await old.save(id: UUID(), title: "private", payload: Data([9]), savedAt: now)
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    try await activate(store)
    let price = InventoryPriceRow(id: UUID(), revision: 1, lotID: nil, payload: Data([7]))
    _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(),
      expectedRevision: 1, request: price.payload, price: price))
    try await store.setStaplePrompts(true, persona: UUID(), expectedRevision: nil)
    let values = (0..<700).map { record(.intent, payload: "pending \($0)") }
    try await append(store, values)
    let state = try await store.inventoryState()
    let token = try await store.inventorySourceToken()
    let op = UUID()
    let receipt = try await store.eraseInventoryOrigin(
      expectedRevision: state.revision, sourceToken: token, operationID: op, at: now)
    XCTAssertEqual(receipt.erasedRecordCount, 700)
    XCTAssertEqual(receipt.erasedComparisonCount, 1)
    for table in [
      "inventory_heads", "inventory_revisions", "comparison_revisions", "comparisons",
      "inventory_staged_records", "inventory_erasure_entries", "inventory_prices",
      "inventory_staple_preferences", "inventory_staple_answers",
    ] { XCTAssertEqual(try scalar("SELECT count(*) FROM \(table)"), 0) }
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_retired_prices"), 1)
    do {
      _ = try await old.save(id: UUID(), title: "resurrect", payload: Data([1]), savedAt: now)
      XCTFail("old generic writer")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    do {
      _ = try await old.load(id: saved.id)
      XCTFail("old generic reader")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    try await old.close()
    try await store.close()
    XCTAssertThrowsError(try ComparisonStore(url: url)) {
      XCTAssertEqual($0 as? ComparisonStoreError, .unsupportedSchema(8))
    }
    let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
    let proof = try await reopened.inventoryOriginRetirement()
    XCTAssertEqual(proof, receipt)
    let retry = try await reopened.eraseInventoryOrigin(
      expectedRevision: state.revision, sourceToken: token, operationID: op,
      at: now.addingTimeInterval(3))
    XCTAssertEqual(retry, receipt)
    do {
      _ = try await reopened.inventoryRecord(values[0].key)
      XCTFail("retired reader")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    do {
      _ = try await reopened.eraseInventoryOrigin(
        expectedRevision: state.revision + 1, sourceToken: token, operationID: op, at: now)
      XCTFail("changed scope")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
    try await reopened.close()
  }

  func testOriginErasureCancelsPrivateStagedMigrationAndErasurePayloads() async throws {
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    let token = try await store.inventorySourceToken()
    let source = try await store.save(
      id: UUID(), title: "original", payload: Data([3]), savedAt: now)
    let currentToken = try await store.inventorySourceToken()
    let chunk = InventoryMigrationChunk(
      index: 0, records: [record(.lot, payload: "secret staged count")])
    let migration = InventoryMigrationPlan(
      migrationID: UUID(), workspaceID: store.workspaceID, expectedRevision: 0,
      sourceToken: currentToken, reviewContext: Data("protected review context".utf8),
      expectedChunkCount: 1, expectedRecordCount: 1,
      manifestDigest: try InventoryMigrationManifest.appending(
        chunk, to: InventoryMigrationManifest.initialDigest))
    _ = try await store.beginInventoryMigration(migration)
    _ = try await store.stageInventoryMigration(id: migration.migrationID, chunk: chunk)
    let eraseChunk = InventoryErasureChunk(
      index: 0, entries: [.comparison(id: source.id, expectedRevision: 1)])
    let pending = InventoryErasureManifest(
      workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 0,
      sourceToken: currentToken, chunkCount: 1, entryCount: 1,
      manifestDigest: try InventoryErasureManifest.appending(
        eraseChunk, to: InventoryErasureManifest.initialDigest))
    _ = try await store.beginInventoryErasure(pending)
    _ = try await store.stageInventoryErasure(id: pending.operationID, chunk: eraseChunk)
    _ = try await store.eraseInventoryOrigin(
      expectedRevision: 0, sourceToken: currentToken, operationID: UUID(), at: now)
    XCTAssertEqual(
      try scalar("SELECT count(*) FROM inventory_migrations WHERE plan IS NOT NULL"), 0)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_staged_records"), 0)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_erasure_entries"), 0)
    let cancelled = try await store.inventoryErasureProgress(id: pending.operationID)
    XCTAssertEqual(cancelled?.status, .cancelled)
    do {
      _ = try await store.finishInventoryMigration(id: migration.migrationID, at: now)
      XCTFail("stale import")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    XCTAssertNotEqual(token, currentToken)
    try await store.close()
  }

  func testMissingDependentPinRollsBackAndHistoricalPagesBindFullBasis() async throws {
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    let source = try await store.save(id: UUID(), title: "old", payload: Data([1]), savedAt: now)
    _ = try await store.save(id: source.id, title: "new", payload: Data([2]), savedAt: now)
    let lot = record(.lot)
    let pin = record(.reservation, lot: nil)
    try await activate(store, [lot, pin])
    let pinned = record(
      .reservation, id: pin.key.id, revision: 2, lot: lot.key.id, payload: "exact pin")
    try await append(store, [pinned])
    let state = try await store.inventoryState()
    let token = try await store.inventorySourceToken()
    let comparisons = try await store.inventoryComparisonRevisionPage(
      expectedRevision: state.revision, sourceToken: token)
    XCTAssertEqual(comparisons.map(\.revision), [1, 2])
    XCTAssertEqual(comparisons.first?.payload, Data([1]))
    let histories = try await store.inventoryRevisionPage(
      expectedRevision: state.revision, sourceToken: token)
    XCTAssertEqual(histories.filter { $0.key == pin.key }.count, 2)
    do {
      _ = try await store.eraseInventory(
        workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: state.revision,
        sourceToken: token, entries: [.record(.init(key: lot.key, expectedRevision: 1))], at: now)
      XCTFail("dependent pin omitted")
    } catch ComparisonStoreError.database {}
    let retained = try await store.inventoryRecord(lot.key)
    XCTAssertEqual(retained, lot)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_tombstones"), 0)
    try await append(store, [record(.lot, id: lot.key.id, revision: 2)])
    do {
      _ = try await store.inventoryRevisionPage(
        expectedRevision: state.revision, sourceToken: token)
      XCTFail("stale history")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
    try await store.close()
  }

  func testSchemaThreeUpgradesAndRedactedReceiptsCannotReplay() async throws {
    let raw = try ComparisonDatabase(url: url)
    try raw.migrate()
    try raw.migrateInventory()
    XCTAssertEqual(try raw.integer("PRAGMA user_version"), 3)
    try raw.close()
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    XCTAssertEqual(try scalar("PRAGMA user_version"), 8)
    let claim = record(.reservation, payload: "private old history")
    try await activate(store)
    let batch = InventoryBatch(
      workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, request: Data([8]),
      writes: [.init(record: claim, expectedRevision: 0)])
    _ = try await store.commitInventory(batch, at: now)
    let token = try await store.inventorySourceToken()
    let clean = record(.reservation, id: claim.key.id, revision: 2, payload: "unknown hold")
    let receipt = try await store.eraseInventory(
      workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 2, sourceToken: token,
      entries: [.reservation(.init(record: clean, expectedRevision: 1))], at: now)
    do {
      _ = try await store.inventoryCommittedOperation(id: batch.operationID, request: batch.request)
      XCTFail("redacted receipt")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    do {
      _ = try await store.commitInventory(batch, at: now)
      XCTFail("old body replay")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    let history = try await store.inventoryRevisionPage(
      expectedRevision: receipt.revision, sourceToken: token)
    XCTAssertEqual(history, [clean])
    try await store.close()
    let reopened = try ComparisonStore(url: url, inventoryEnabled: true)
    let retained = try await reopened.inventoryRecord(claim.key)
    XCTAssertEqual(retained, clean)
    try await reopened.close()
  }
  func testPagedComparisonRetirementsDetectConcurrentSourceChange() async throws {
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    var ids: [UUID] = []
    for _ in 0..<5 {
      let source = try await store.save(
        id: UUID(), title: "Private", payload: Data([1]), savedAt: now)
      _ = try await store.erase(id: source.id, expectedRevision: 1, operationID: UUID(), at: now)
      ids.append(source.id)
    }
    let token = try await store.inventorySourceToken()
    var gathered: [UUID] = []
    var cursor: UUID?
    while true {
      let page = try await store.inventoryComparisonTombstones(
        token: token, after: cursor, limit: 2)
      if page.isEmpty { break }
      XCTAssertLessThanOrEqual(page.count, 2)
      gathered += page.map(\.id)
      cursor = page.last?.id
    }
    XCTAssertEqual(gathered, ids.sorted { $0.uuidString < $1.uuidString })
    _ = try await store.save(id: UUID(), title: "Concurrent", payload: Data([2]), savedAt: now)
    do {
      _ = try await store.inventoryComparisonTombstones(
        token: token, after: gathered.first, limit: 2)
      XCTFail("stale source token")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .staleInventory) }
    try await store.close()
  }

  func testPagedLedgerRetirementsDetectIndependentHeadAndOriginChanges() async throws {
    let ledgerURL = directory.appendingPathComponent("ledger.sqlite")
    var ledger = try LedgerStore(url: ledgerURL)
    var retired: [UUID] = []
    for _ in 0..<5 {
      retired.append(ledger.workspaceID)
      _ = try await ledger.eraseWorkspace(
        workspaceID: ledger.workspaceID, expectedRevision: 0, operationID: UUID(), at: now)
      try await ledger.close()
      ledger = try LedgerStore(url: ledgerURL)
    }
    var gathered: [UUID] = []
    var cursor: UUID?
    while true {
      let page = try await ledger.tombstonePage(
        expectedWorkspaceID: ledger.workspaceID, expectedRevision: 0, after: cursor, limit: 2)
      if page.isEmpty { break }
      gathered += page.map(\.workspaceID)
      cursor = page.last?.workspaceID
    }
    XCTAssertEqual(gathered, retired.sorted { $0.uuidString < $1.uuidString })
    let other = try LedgerStore(url: ledgerURL)
    _ = try await other.save(
      payload: Data([2]), expectedRevision: 0, operationID: UUID(), savedAt: now)
    do {
      _ = try await ledger.tombstonePage(
        expectedWorkspaceID: ledger.workspaceID, expectedRevision: 0, limit: 2)
      XCTFail("stale head")
    } catch { XCTAssertEqual(error as? LedgerStoreError, .staleRevision(expected: 0, actual: 1)) }
    _ = try await other.eraseWorkspace(
      workspaceID: other.workspaceID, expectedRevision: 1, operationID: UUID(), at: now)
    do {
      _ = try await ledger.tombstonePage(
        expectedWorkspaceID: ledger.workspaceID, expectedRevision: 1, limit: 2)
      XCTFail("retired physical origin")
    } catch { XCTAssertEqual(error as? LedgerStoreError, .erased) }
    try await other.close()
    try await ledger.close()
  }

  func testCancelledManifestCannotBeReusedAndBoundsFailWithoutWrites() async throws {
    let store = try ComparisonStore(url: url, inventoryEnabled: true)
    let claim = record(.reservation)
    try await activate(store, [claim])
    let token = try await store.inventorySourceToken()
    let clean = record(.reservation, id: claim.key.id, revision: 2, payload: "unknown")
    let chunk = InventoryErasureChunk(
      index: 0, entries: [.reservation(.init(record: clean, expectedRevision: 1))])
    let plan = InventoryErasureManifest(
      workspaceID: store.workspaceID, operationID: UUID(), expectedRevision: 1, sourceToken: token,
      chunkCount: 1, entryCount: 1,
      manifestDigest: try InventoryErasureManifest.appending(
        chunk, to: InventoryErasureManifest.initialDigest))
    _ = try await store.beginInventoryErasure(plan)
    _ = try await store.stageInventoryErasure(id: plan.operationID, chunk: chunk)
    let changed = InventoryErasureChunk(
      index: 0, entries: [.record(.init(key: claim.key, expectedRevision: 1))])
    do {
      _ = try await store.stageInventoryErasure(id: plan.operationID, chunk: changed)
      XCTFail("changed chunk")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
    _ = try await store.cancelInventoryErasure(id: plan.operationID)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_erasure_entries"), 0)
    do {
      _ = try await store.beginInventoryErasure(plan)
      XCTFail("cancelled operation")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .erased) }
    do {
      _ = try await store.inventoryCommittedOperation(id: plan.operationID, request: Data([1]))
      XCTFail("erasure cannot look like absent ordinary work")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
    let unrelated = record(.intent)
    do {
      _ = try await store.commitInventory(
        .init(
          workspaceID: store.workspaceID, operationID: plan.operationID, expectedRevision: 1,
          request: Data([1]), writes: [.init(record: unrelated, expectedRevision: 0)]))
      XCTFail("retired operation namespace")
    } catch { XCTAssertEqual(error as? ComparisonStoreError, .operationConflict) }
    let huge = InventoryErasureChunk(
      index: 0, entries: Array(repeating: chunk.entries[0], count: 257))
    XCTAssertThrowsError(
      try InventoryErasureManifest.appending(huge, to: InventoryErasureManifest.initialDigest))
    let retained = try await store.inventoryRecord(claim.key)
    XCTAssertEqual(retained, claim)
    XCTAssertEqual(try scalar("SELECT count(*) FROM inventory_heads"), 1)
    try await store.close()
  }

}
