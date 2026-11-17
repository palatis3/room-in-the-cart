import CSQLite
import Foundation

extension ComparisonDatabase {
  func migrateInventoryErasure() throws {
    try transaction {
      let version = try integer("PRAGMA user_version")
      if (4...7).contains(version) {
        try validateInventoryErasure()
        return
      }
      guard version == 3 else { throw ComparisonStoreError.unsupportedSchema(version) }
      try validateInventory()
      try execute(Self.inventoryErasureSchema)
      try validateInventoryErasure()
    }
  }

  private static let inventoryErasureSchema = """
    CREATE TABLE inventory_erasures (
        id TEXT PRIMARY KEY NOT NULL CHECK(length(id)=36),
        manifest BLOB NOT NULL CHECK(typeof(manifest)='blob' AND length(manifest) BETWEEN 1 AND 4096),
        digest BLOB NOT NULL CHECK(typeof(digest)='blob' AND length(digest)=32),
        status TEXT NOT NULL CHECK(status IN ('staging','completed','cancelled')),
        next_chunk INTEGER NOT NULL CHECK(typeof(next_chunk)='integer' AND next_chunk>=0),
        entry_count INTEGER NOT NULL CHECK(typeof(entry_count)='integer' AND entry_count>=0),
        chain_digest BLOB NOT NULL CHECK(typeof(chain_digest)='blob' AND length(chain_digest)=32),
        receipt BLOB CHECK(receipt IS NULL OR (typeof(receipt)='blob' AND length(receipt) BETWEEN 1 AND 4096)),
        CHECK((status='completed')=(receipt IS NOT NULL))
    );
    CREATE TABLE inventory_erasure_chunks (
        operation_id TEXT NOT NULL REFERENCES inventory_erasures(id),
        chunk_index INTEGER NOT NULL CHECK(typeof(chunk_index)='integer' AND chunk_index>=0),
        digest BLOB NOT NULL CHECK(typeof(digest)='blob' AND length(digest)=32),
        PRIMARY KEY(operation_id,chunk_index)
    );
    CREATE TABLE inventory_erasure_entries (
        operation_id TEXT NOT NULL REFERENCES inventory_erasures(id),
        kind TEXT NOT NULL CHECK(kind IN ('lot','observation','event','reservation','sourceLink','intent','comparison')),
        id TEXT NOT NULL CHECK(length(id)=36),
        chunk_index INTEGER NOT NULL CHECK(typeof(chunk_index)='integer' AND chunk_index>=0),
        ordinal INTEGER NOT NULL CHECK(typeof(ordinal)='integer' AND ordinal BETWEEN 0 AND 255),
        expected_revision INTEGER NOT NULL CHECK(typeof(expected_revision)='integer' AND expected_revision>0),
        replacement BLOB CHECK(replacement IS NULL OR (kind='reservation' AND typeof(replacement)='blob' AND length(replacement) BETWEEN 1 AND 131072)),
        PRIMARY KEY(operation_id,kind,id),
        UNIQUE(operation_id,chunk_index,ordinal),
        FOREIGN KEY(operation_id,chunk_index) REFERENCES inventory_erasure_chunks(operation_id,chunk_index) DEFERRABLE INITIALLY DEFERRED
    );
    CREATE TABLE inventory_reservation_redactions (
        id TEXT NOT NULL CHECK(length(id)=36),
        through_revision INTEGER NOT NULL CHECK(typeof(through_revision)='integer' AND through_revision>0),
        operation_id TEXT NOT NULL REFERENCES inventory_erasures(id),
        previous_lot_id TEXT CHECK(previous_lot_id IS NULL OR length(previous_lot_id)=36),
        PRIMARY KEY(id,through_revision)
    );
    CREATE TABLE inventory_origin_retirement (
        singleton INTEGER PRIMARY KEY CHECK(singleton=1),
        operation_id TEXT NOT NULL UNIQUE REFERENCES inventory_erasures(id)
    );
    CREATE TRIGGER inventory_erasure_identity BEFORE UPDATE ON inventory_erasures
    WHEN NEW.id!=OLD.id OR NEW.manifest!=OLD.manifest OR NEW.digest!=OLD.digest OR OLD.status!='staging'
      OR NEW.next_chunk<OLD.next_chunk OR NEW.entry_count<OLD.entry_count
    BEGIN SELECT RAISE(ABORT,'immutable erasure identity'); END;
    CREATE TRIGGER inventory_erasure_delete BEFORE DELETE ON inventory_erasures
    BEGIN SELECT RAISE(ABORT,'immutable erasure identity'); END;
    CREATE TRIGGER inventory_erasure_chunk_update BEFORE UPDATE ON inventory_erasure_chunks
    BEGIN SELECT RAISE(ABORT,'immutable erasure chunk'); END;
    CREATE TRIGGER inventory_erasure_chunk_delete BEFORE DELETE ON inventory_erasure_chunks
    BEGIN SELECT RAISE(ABORT,'immutable erasure chunk'); END;
    CREATE TRIGGER inventory_erasure_entry_insert BEFORE INSERT ON inventory_erasure_entries
    WHEN NOT EXISTS(SELECT 1 FROM inventory_erasures WHERE id=NEW.operation_id AND status='staging')
    BEGIN SELECT RAISE(ABORT,'retired erasure'); END;
    CREATE TRIGGER inventory_erasure_entry_update BEFORE UPDATE ON inventory_erasure_entries
    BEGIN SELECT RAISE(ABORT,'immutable erasure entry'); END;
    CREATE TRIGGER inventory_erasure_entry_delete BEFORE DELETE ON inventory_erasure_entries
    WHEN EXISTS(SELECT 1 FROM inventory_erasures WHERE id=OLD.operation_id AND status='staging')
    BEGIN SELECT RAISE(ABORT,'erasure staging active'); END;
    CREATE TRIGGER inventory_redaction_current BEFORE INSERT ON inventory_reservation_redactions
    WHEN NOT EXISTS(SELECT 1 FROM inventory_heads WHERE kind='reservation' AND id=NEW.id AND revision=NEW.through_revision AND lot_id IS NEW.previous_lot_id)
    BEGIN SELECT RAISE(ABORT,'stale reservation redaction'); END;
    CREATE TRIGGER inventory_redaction_update BEFORE UPDATE ON inventory_reservation_redactions
    BEGIN SELECT RAISE(ABORT,'immutable reservation redaction'); END;
    CREATE TRIGGER inventory_redaction_delete BEFORE DELETE ON inventory_reservation_redactions
    BEGIN SELECT RAISE(ABORT,'immutable reservation redaction'); END;
    DROP TRIGGER inventory_revision_delete;
    CREATE TRIGGER inventory_revision_delete BEFORE DELETE ON inventory_revisions
    WHEN NOT EXISTS(SELECT 1 FROM inventory_tombstones WHERE kind=OLD.kind AND id=OLD.id AND revision>=OLD.revision)
     AND NOT (OLD.kind='reservation' AND EXISTS(SELECT 1 FROM inventory_reservation_redactions WHERE id=OLD.id AND through_revision>=OLD.revision))
    BEGIN SELECT RAISE(ABORT,'inventory erasure required'); END;
    CREATE TRIGGER inventory_redacted_revision_insert BEFORE INSERT ON inventory_revisions
    WHEN NEW.kind='reservation' AND EXISTS(SELECT 1 FROM inventory_reservation_redactions WHERE id=NEW.id AND through_revision>=NEW.revision)
    BEGIN SELECT RAISE(ABORT,'redacted reservation revision'); END;
    CREATE TRIGGER inventory_origin_retirement_insert BEFORE INSERT ON inventory_origin_retirement
    WHEN EXISTS(SELECT 1 FROM inventory_heads) OR EXISTS(SELECT 1 FROM inventory_revisions)
      OR EXISTS(SELECT 1 FROM comparisons) OR EXISTS(SELECT 1 FROM comparison_revisions)
      OR EXISTS(SELECT 1 FROM inventory_staged_records) OR EXISTS(SELECT 1 FROM inventory_migrations WHERE plan IS NOT NULL)
      OR EXISTS(SELECT 1 FROM inventory_erasure_entries)
      OR NOT EXISTS(SELECT 1 FROM inventory_erasures WHERE id=NEW.operation_id AND status='completed')
    BEGIN SELECT RAISE(ABORT,'origin still has payloads'); END;
    CREATE TRIGGER inventory_origin_retirement_update BEFORE UPDATE ON inventory_origin_retirement
    BEGIN SELECT RAISE(ABORT,'immutable inventory retirement'); END;
    CREATE TRIGGER inventory_origin_retirement_delete BEFORE DELETE ON inventory_origin_retirement
    BEGIN SELECT RAISE(ABORT,'immutable inventory retirement'); END;
    CREATE TRIGGER inventory_retired_origin_head BEFORE INSERT ON inventory_heads
    WHEN EXISTS(SELECT 1 FROM inventory_origin_retirement)
    BEGIN SELECT RAISE(ABORT,'retired inventory origin'); END;
    CREATE TRIGGER inventory_retired_origin_revision BEFORE INSERT ON inventory_revisions
    WHEN EXISTS(SELECT 1 FROM inventory_origin_retirement)
    BEGIN SELECT RAISE(ABORT,'retired inventory origin'); END;
    CREATE TRIGGER inventory_retired_origin_comparison BEFORE INSERT ON comparisons
    WHEN EXISTS(SELECT 1 FROM inventory_origin_retirement)
    BEGIN SELECT RAISE(ABORT,'retired inventory origin'); END;
    CREATE TRIGGER inventory_retired_origin_comparison_revision BEFORE INSERT ON comparison_revisions
    WHEN EXISTS(SELECT 1 FROM inventory_origin_retirement)
    BEGIN SELECT RAISE(ABORT,'retired inventory origin'); END;
    CREATE TRIGGER inventory_retired_origin_migration BEFORE INSERT ON inventory_migrations
    WHEN EXISTS(SELECT 1 FROM inventory_origin_retirement)
    BEGIN SELECT RAISE(ABORT,'retired inventory origin'); END;
    CREATE TRIGGER inventory_operation_erasure_id BEFORE INSERT ON inventory_operations
    WHEN EXISTS(SELECT 1 FROM inventory_erasures WHERE id=NEW.id)
    BEGIN SELECT RAISE(ABORT,'erasure operation identity'); END;
    PRAGMA user_version=4;
    """

  func validateInventoryErasure() throws {
    let tables = [
      "inventory_erasures", "inventory_erasure_chunks", "inventory_erasure_entries",
      "inventory_reservation_redactions", "inventory_origin_retirement",
    ]
    let triggers = [
      "inventory_erasure_identity", "inventory_erasure_delete", "inventory_erasure_chunk_update",
      "inventory_erasure_chunk_delete",
      "inventory_erasure_entry_insert", "inventory_erasure_entry_update",
      "inventory_erasure_entry_delete", "inventory_redaction_current",
      "inventory_redaction_update", "inventory_redaction_delete",
      "inventory_redacted_revision_insert", "inventory_origin_retirement_insert",
      "inventory_origin_retirement_update", "inventory_origin_retirement_delete",
      "inventory_retired_origin_head", "inventory_retired_origin_revision",
      "inventory_retired_origin_comparison", "inventory_retired_origin_comparison_revision",
      "inventory_retired_origin_migration", "inventory_operation_erasure_id",
    ]
    for (type, names) in [("table", tables), ("trigger", triggers)] {
      for name in names {
        guard
          try integer("SELECT count(*) FROM sqlite_master WHERE type='\(type)' AND name='\(name)'")
            == 1
        else { throw ComparisonStoreError.corruptRecord }
      }
    }
    guard
      try integer(
        "SELECT count(*) FROM inventory_reservation_redactions d JOIN inventory_revisions r ON r.kind='reservation' AND r.id=d.id AND r.revision<=d.through_revision"
      ) == 0,
      try integer(
        "SELECT count(*) FROM inventory_erasure_entries e JOIN inventory_erasures h ON h.id=e.operation_id WHERE h.status!='staging'"
      ) == 0,
      try integer(
        "SELECT count(*) FROM inventory_reservation_redactions d JOIN inventory_erasures e ON e.id=d.operation_id WHERE e.status!='completed'"
      ) == 0
    else {
      throw ComparisonStoreError.corruptRecord
    }
    if try originRetirement() != nil {
      for table in [
        "inventory_heads", "inventory_revisions", "comparisons", "comparison_revisions",
        "inventory_staged_records", "inventory_erasure_entries",
      ] {
        guard try integer("SELECT count(*) FROM \(table)") == 0 else {
          throw ComparisonStoreError.corruptRecord
        }
      }
      guard try integer("SELECT count(*) FROM inventory_migrations WHERE plan IS NOT NULL") == 0
      else { throw ComparisonStoreError.corruptRecord }
    }
    let rows = try statement("SELECT id FROM inventory_erasures")
    defer { sqlite3_finalize(rows) }
    while sqlite3_step(rows) == SQLITE_ROW {
      guard let id = UUID(uuidString: try text(rows, column: 0)), try erasureProgress(id) != nil
      else { throw ComparisonStoreError.corruptRecord }
    }
  }

  func requireInventoryOriginLive() throws {
    if try integer("PRAGMA user_version") >= 4,
      try integer("SELECT count(*) FROM inventory_origin_retirement") != 0
    {
      throw ComparisonStoreError.erased
    }
  }

  func originRetirement() throws -> InventoryErasureReceipt? {
    let row = try statement("SELECT operation_id FROM inventory_origin_retirement")
    defer { sqlite3_finalize(row) }
    let status = sqlite3_step(row)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW, let id = UUID(uuidString: try text(row, column: 0)),
      let value = try erasureProgress(id), value.status == .completed,
      value.manifest.scope == .origin,
      let receipt = value.receipt
    else { throw ComparisonStoreError.corruptRecord }
    return receipt
  }

  func erasureProgress(_ id: UUID) throws -> InventoryErasureProgress? {
    let row = try statement(
      "SELECT manifest,digest,status,next_chunk,entry_count,receipt FROM inventory_erasures WHERE id=?",
      values: [.text(id.uuidString)])
    defer { sqlite3_finalize(row) }
    let status = sqlite3_step(row)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
    let bytes = try inventoryBlob(row, column: 0, maximum: 4096)
    guard inventoryDigest(bytes) == (try inventoryBlob(row, column: 1, maximum: 32)),
      let state = InventoryErasureProgress.Status(rawValue: try text(row, column: 2)),
      sqlite3_column_type(row, 3) == SQLITE_INTEGER, sqlite3_column_type(row, 4) == SQLITE_INTEGER
    else { throw ComparisonStoreError.corruptRecord }
    let manifest: InventoryErasureManifest
    let receipt: InventoryErasureReceipt?
    do {
      manifest = try JSONDecoder().decode(InventoryErasureManifest.self, from: bytes)
      receipt =
        sqlite3_column_type(row, 5) == SQLITE_NULL
        ? nil
        : try JSONDecoder().decode(
          InventoryErasureReceipt.self, from: inventoryBlob(row, column: 5, maximum: 4096))
    } catch { throw ComparisonStoreError.corruptRecord }
    let next = sqlite3_column_int64(row, 3)
    let count = sqlite3_column_int64(row, 4)
    guard manifest.version == 1, manifest.operationID == id, manifest.expectedRevision >= 0,
      manifest.expectedRevision < Int64.max,
      manifest.chunkCount >= next, next >= 0, manifest.entryCount >= count, count >= 0,
      (state == .completed) == (receipt != nil)
    else { throw ComparisonStoreError.corruptRecord }
    if let receipt {
      guard receipt.operationID == id, receipt.workspaceID == manifest.workspaceID,
        receipt.scope == manifest.scope,
        receipt.erasedRevision == manifest.expectedRevision,
        receipt.revision == manifest.expectedRevision + 1,
        receipt.committedAt.timeIntervalSinceReferenceDate.isFinite,
        receipt.erasedRecordCount >= 0, receipt.erasedComparisonCount >= 0,
        receipt.redactedReservationCount >= 0
      else { throw ComparisonStoreError.corruptRecord }
    }
    return .init(
      manifest: manifest, status: state, nextChunk: next, stagedEntryCount: count, receipt: receipt)
  }

  func erasureChunkDigest(_ id: UUID, index: Int64) throws -> Data? {
    let row = try statement(
      "SELECT digest FROM inventory_erasure_chunks WHERE operation_id=? AND chunk_index=?",
      values: [.text(id.uuidString), .integer(index)])
    defer { sqlite3_finalize(row) }
    let status = sqlite3_step(row)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW else { throw ComparisonStoreError.database(status) }
    return try inventoryBlob(row, column: 0, maximum: 32)
  }
  func erasureChain(_ id: UUID) throws -> Data {
    let row = try statement(
      "SELECT chain_digest FROM inventory_erasures WHERE id=?", values: [.text(id.uuidString)])
    defer { sqlite3_finalize(row) }
    guard sqlite3_step(row) == SQLITE_ROW else { throw ComparisonStoreError.corruptRecord }
    return try inventoryBlob(row, column: 0, maximum: 32)
  }
  func stageErasureEntry(
    _ entry: InventoryErasureEntry, operationID: UUID, chunkIndex: Int64, ordinal: Int
  ) throws {
    let kind: String
    let id: UUID
    let revision: Int64
    let replacement: Data?
    switch entry {
    case .record(let value):
      kind = value.key.kind.rawValue
      id = value.key.id
      revision = value.expectedRevision
      replacement = nil
    case .comparison(let value, let expected):
      kind = "comparison"
      id = value
      revision = expected
      replacement = nil
    case .reservation(let value):
      kind = "reservation"
      id = value.record.key.id
      revision = value.expectedRevision
      replacement = try inventoryCanonical(value.record)
    }
    try run(
      "INSERT INTO inventory_erasure_entries(operation_id,kind,id,expected_revision,replacement,chunk_index,ordinal) VALUES(?,?,?,?,?,?,?)",
      [
        .text(operationID.uuidString), .text(kind), .text(id.uuidString), .integer(revision),
        replacement.map(ComparisonSQLValue.blob) ?? .null, .integer(chunkIndex),
        .integer(Int64(ordinal)),
      ])
  }

  func firstComparisonErasureHead() throws -> (id: UUID, revision: Int64)? {
    let row = try statement("SELECT id,head_revision FROM comparisons ORDER BY id LIMIT 1")
    defer { sqlite3_finalize(row) }
    let status = sqlite3_step(row)
    if status == SQLITE_DONE { return nil }
    guard status == SQLITE_ROW, let id = UUID(uuidString: try text(row, column: 0)),
      sqlite3_column_type(row, 1) == SQLITE_INTEGER
    else { throw ComparisonStoreError.corruptRecord }
    return (id, sqlite3_column_int64(row, 1))
  }

  func validateErasureStaging(_ progress: InventoryErasureProgress) throws {
    var digest = InventoryErasureManifest.initialDigest
    var total: Int64 = 0
    for index in 0..<progress.nextChunk {
      let row = try statement(
        "SELECT kind,id,expected_revision,replacement,ordinal FROM inventory_erasure_entries WHERE operation_id=? AND chunk_index=? ORDER BY ordinal LIMIT 257",
        values: [.text(progress.manifest.operationID.uuidString), .integer(index)])
      var entries: [InventoryErasureEntry] = []
      do {
        while true {
          let status = sqlite3_step(row)
          if status == SQLITE_DONE { break }
          guard status == SQLITE_ROW, let id = UUID(uuidString: try text(row, column: 1)),
            sqlite3_column_int64(row, 4) == Int64(entries.count)
          else { throw ComparisonStoreError.corruptRecord }
          let kind = try text(row, column: 0)
          let revision = sqlite3_column_int64(row, 2)
          if sqlite3_column_type(row, 3) != SQLITE_NULL {
            let record = try JSONDecoder().decode(
              InventoryRecord.self, from: inventoryBlob(row, column: 3, maximum: 131072))
            guard kind == "reservation", record.key == .init(.reservation, id) else {
              throw ComparisonStoreError.corruptRecord
            }
            entries.append(.reservation(.init(record: record, expectedRevision: revision)))
          } else if kind == "comparison" {
            entries.append(.comparison(id: id, expectedRevision: revision))
          } else {
            guard let value = InventoryRecordKind(rawValue: kind) else {
              throw ComparisonStoreError.corruptRecord
            }
            entries.append(.record(.init(key: .init(value, id), expectedRevision: revision)))
          }
        }
        sqlite3_finalize(row)
      } catch {
        sqlite3_finalize(row)
        throw error
      }
      let chunk = InventoryErasureChunk(index: index, entries: entries)
      try validateErasureChunk(chunk)
      guard
        try erasureChunkDigest(progress.manifest.operationID, index: index)
          == inventoryDigest(inventoryCanonical(chunk))
      else { throw ComparisonStoreError.corruptRecord }
      digest = try InventoryErasureManifest.appending(chunk, to: digest)
      total += Int64(entries.count)
    }
    guard total == progress.stagedEntryCount,
      digest == (try erasureChain(progress.manifest.operationID))
    else { throw ComparisonStoreError.corruptRecord }
  }

  func reservationRedactionFloor(_ id: UUID) throws -> Int64 {
    let row = try statement(
      "SELECT COALESCE(max(through_revision),0) FROM inventory_reservation_redactions WHERE id=?",
      values: [.text(id.uuidString)])
    defer { sqlite3_finalize(row) }
    guard sqlite3_step(row) == SQLITE_ROW else { throw ComparisonStoreError.corruptRecord }
    return sqlite3_column_int64(row, 0)
  }
}

extension ComparisonStore {
  func performInventoryErasure(_ plan: InventoryErasureManifest, at date: Date) throws -> (
    records: Int64, comparisons: Int64, redactions: Int64
  ) {
    let op = plan.operationID.uuidString
    // Cancel all staged imports: their context and chunks can contain erased source
    // bytes. Identity-only manifests remain and can never activate after cancellation.
    try database.run(
      "UPDATE inventory_migrations SET status='cancelled',plan=NULL WHERE status='staging'", [])
    try database.run("DELETE FROM inventory_staged_acquisitions WHERE migration_id IN (SELECT id FROM inventory_migrations WHERE status='cancelled')", [])
    try database.run(
      "DELETE FROM inventory_staged_records WHERE migration_id IN (SELECT id FROM inventory_migrations WHERE status='cancelled')",
      [])
    try database.run(
      "DELETE FROM inventory_migration_sources WHERE migration_id IN (SELECT id FROM inventory_migrations WHERE status='cancelled')",
      [])
    // Other erasure journals may embed stale reservation bodies. Retire them,
    // including their staged payloads, rather than allowing later resurrection.
    try database.run(
      "UPDATE inventory_erasures SET status='cancelled' WHERE status='staging' AND id!=?",
      [.text(op)])
    try database.run(
      "DELETE FROM inventory_erasure_entries WHERE operation_id IN (SELECT id FROM inventory_erasures WHERE status='cancelled')",
      [])
    if plan.scope == .origin {
      try database.run("DELETE FROM inventory_staple_preferences", [])
      let records = try database.integer("SELECT count(*) FROM inventory_heads")
      let comparisons = try database.integer("SELECT count(*) FROM comparisons")
      try database.run(
        "INSERT INTO inventory_retired_sources(origin_id,source_id,operation_id) SELECT source_origin,source_id,? FROM inventory_heads WHERE kind='sourceLink'",
        [.text(op)])
      try database.run(
        "INSERT INTO inventory_tombstones(kind,id,revision,operation_id) SELECT kind,id,revision,? FROM inventory_heads",
        [.text(op)])
      try database.run("DELETE FROM inventory_revisions", [])
      try database.run("DELETE FROM inventory_heads", [])
      // Each comparison retains a distinct existing-format tombstone operation.
      while let source = try database.firstComparisonErasureHead() {
        _ = try eraseComparison(
          id: source.id, expectedRevision: source.revision,
          operationID: inventoryComparisonErasureID(operation: plan.operationID, source: source.id),
          at: date)
      }
      return (records, comparisons, 0)
    }
    // Validate every explicit head before any redaction. The global CAS binds
    // opaque history scans as well as the current SQL graph.
    let bad = try database.statement(
      """
      SELECT count(*) FROM inventory_erasure_entries e
      LEFT JOIN inventory_heads h ON e.kind=h.kind AND e.id=h.id
      LEFT JOIN comparisons c ON e.kind='comparison' AND e.id=c.id
      WHERE e.operation_id=? AND ((e.kind='comparison' AND (c.id IS NULL OR c.head_revision!=e.expected_revision))
        OR (e.kind!='comparison' AND (h.id IS NULL OR h.revision!=e.expected_revision)))
      """, values: [.text(op)])
    defer { sqlite3_finalize(bad) }
    guard sqlite3_step(bad) == SQLITE_ROW, sqlite3_column_int64(bad, 0) == 0 else {
      throw ComparisonStoreError.staleInventory
    }
    var redactions: Int64 = 0
    let replacements = try database.statement(
      "SELECT id,expected_revision,replacement FROM inventory_erasure_entries WHERE operation_id=? AND replacement IS NOT NULL ORDER BY id",
      values: [.text(op)])
    defer { sqlite3_finalize(replacements) }
    while true {
      let status = sqlite3_step(replacements)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW,
        let id = UUID(uuidString: try database.text(replacements, column: 0))
      else { throw ComparisonStoreError.corruptRecord }
      let expected = sqlite3_column_int64(replacements, 1)
      let record = try JSONDecoder().decode(
        InventoryRecord.self, from: database.inventoryBlob(replacements, column: 2, maximum: 131072)
      )
      guard record.key == .init(.reservation, id), record.revision == expected + 1 else {
        throw ComparisonStoreError.corruptRecord
      }
      let prior = try database.inventoryRecords(kind: .reservation, id: id).first!
      try database.run(
        "INSERT INTO inventory_reservation_redactions(id,through_revision,operation_id,previous_lot_id) VALUES(?,?,?,?)",
        [
          .text(id.uuidString), .integer(expected), .text(op),
          prior.lotID.map { .text($0.uuidString) } ?? .null,
        ])
      try database.writeInventory(.init(record: record, expectedRevision: expected))
      try database.run(
        "DELETE FROM inventory_revisions WHERE kind='reservation' AND id=? AND revision<=?",
        [.text(id.uuidString), .integer(expected)])
      redactions += 1
    }
    let records = try database.statement(
      "SELECT kind,id,expected_revision FROM inventory_erasure_entries WHERE operation_id=? AND kind!='comparison' AND replacement IS NULL ORDER BY kind,id",
      values: [.text(op)])
    defer { sqlite3_finalize(records) }
    var recordCount: Int64 = 0
    while true {
      let status = sqlite3_step(records)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW,
        let kind = InventoryRecordKind(rawValue: try database.text(records, column: 0)),
        let id = UUID(uuidString: try database.text(records, column: 1))
      else { throw ComparisonStoreError.corruptRecord }
      try database.eraseInventory(
        .init(key: .init(kind, id), expectedRevision: sqlite3_column_int64(records, 2)),
        operationID: plan.operationID)
      recordCount += 1
    }
    let comparisons = try database.statement(
      "SELECT id,expected_revision FROM inventory_erasure_entries WHERE operation_id=? AND kind='comparison' ORDER BY id",
      values: [.text(op)])
    defer { sqlite3_finalize(comparisons) }
    var comparisonCount: Int64 = 0
    while true {
      let status = sqlite3_step(comparisons)
      if status == SQLITE_DONE { break }
      guard status == SQLITE_ROW,
        let id = UUID(uuidString: try database.text(comparisons, column: 0))
      else { throw ComparisonStoreError.corruptRecord }
      _ = try eraseComparison(
        id: id, expectedRevision: sqlite3_column_int64(comparisons, 1),
        operationID: inventoryComparisonErasureID(operation: plan.operationID, source: id), at: date
      )
      comparisonCount += 1
    }
    return (recordCount, comparisonCount, redactions)
  }
}
