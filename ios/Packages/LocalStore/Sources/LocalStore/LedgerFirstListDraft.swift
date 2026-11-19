import Foundation
import CSQLite

/// Mutable editing state excluded from ledger snapshots and Records exports.
public struct FirstListDraftVersion: Equatable, Sendable {
    public let workspaceID: UUID
    public let owner: Data
    public let token: UUID
    public let baseRevision: Int64
}

public struct StoredFirstListDraft: Equatable, Sendable {
    public let version: FirstListDraftVersion
    public let payload: Data
}

extension LedgerStore {
    public nonisolated static let maximumFirstListDraftBytes = 1_048_576
    public nonisolated static let firstListDraftLifetime: TimeInterval = 7 * 24 * 3600

    /// The review counts drafts from every owner affected by whole-workspace erasure.
    /// Read only opaque version tokens, never the private draft wording or owner identity.
    public func workspaceErasureBasis() throws -> (head: LedgerRecord?, draftTokens: [UUID]) {
        try database.transaction(immediate: false) {
            (try database.current(workspaceID: workspaceID), try liveFirstListDraftTokens())
        }
    }

    func liveFirstListDraftTokens() throws -> [UUID] {
        guard try database.integer("SELECT count(*) FROM sqlite_master WHERE type='table' AND name='first_list_draft'") == 1 else { return [] }
        let rows = try database.statement("SELECT token FROM first_list_draft WHERE workspace_id=? AND expires_at>? ORDER BY token",
                                          values: [.text(workspaceID.uuidString), .real(Date().timeIntervalSinceReferenceDate)])
        defer { sqlite3_finalize(rows) }
        var tokens: [UUID] = []
        while true {
            let status = sqlite3_step(rows)
            if status == SQLITE_DONE { return tokens }
            guard status == SQLITE_ROW else { throw LedgerStoreError.database(status) }
            guard tokens.count < 32, let token = UUID(uuidString: try database.text(rows, 0)) else { throw LedgerStoreError.corruptRecord }
            tokens.append(token)
        }
    }

    private func prepareFirstListDrafts(owner: Data, now: Date) throws {
        guard owner.count == 32, now.timeIntervalSinceReferenceDate.isFinite else { throw LedgerStoreError.invalidInput }
        guard try database.workspace().id == workspaceID else { throw LedgerStoreError.erased }
        // This table is independent of the v2/v3 snapshot format. Even an older
        // application retiring this workspace cascades the deletion to its drafts.
        try database.execute("""
            CREATE TABLE IF NOT EXISTS first_list_draft (
                workspace_id TEXT NOT NULL REFERENCES ledger_workspace(id) ON DELETE CASCADE,
                owner BLOB NOT NULL CHECK(length(owner)=32),
                token TEXT NOT NULL,
                base_revision INTEGER NOT NULL CHECK(base_revision >= 0),
                expires_at REAL NOT NULL,
                payload BLOB NOT NULL CHECK(length(payload) BETWEEN 1 AND 1048576),
                PRIMARY KEY(workspace_id,owner)
            )
            """)
        try database.run("DELETE FROM first_list_draft WHERE expires_at <= ?", [.real(now.timeIntervalSinceReferenceDate)])
    }

    public func firstListDraft(owner: Data, now: Date = Date()) throws -> StoredFirstListDraft? {
        try database.transaction {
            try prepareFirstListDrafts(owner: owner, now: now)
            let row = try database.statement("SELECT token,base_revision,payload FROM first_list_draft WHERE workspace_id=? AND owner=?",
                                             values: [.text(workspaceID.uuidString), .blob(owner)])
            defer { sqlite3_finalize(row) }
            let status = sqlite3_step(row)
            if status == SQLITE_DONE { return nil }
            guard status == SQLITE_ROW, let token = UUID(uuidString: try database.text(row, 0)) else { throw LedgerStoreError.corruptRecord }
            let version = FirstListDraftVersion(workspaceID: workspaceID, owner: owner, token: token, baseRevision: sqlite3_column_int64(row, 1))
            return StoredFirstListDraft(version: version, payload: try database.blob(row, 2, limit: Self.maximumFirstListDraftBytes))
        }
    }

    public func replaceFirstListDraft(owner: Data, expected: FirstListDraftVersion?, baseRevision: Int64,
                                      payload: Data, now: Date = Date()) throws -> FirstListDraftVersion {
        guard !payload.isEmpty, payload.count <= Self.maximumFirstListDraftBytes else { throw LedgerStoreError.payloadTooLarge }
        return try database.transaction {
            try prepareFirstListDrafts(owner: owner, now: now)
            let actual = try database.workspace().revision
            guard actual == baseRevision else { throw LedgerStoreError.staleRevision(expected: baseRevision, actual: actual) }
            if let expected {
                guard expected.owner == owner else { throw LedgerStoreError.operationConflict }
                try deleteFirstListDraft(expected)
            }
            guard try database.integer("SELECT count(*) FROM first_list_draft") < 32 else { throw LedgerStoreError.payloadTooLarge }
            let token = UUID()
            let count = try database.run("""
                INSERT OR IGNORE INTO first_list_draft(workspace_id,owner,token,base_revision,expires_at,payload)
                VALUES(?,?,?,?,?,?)
                """, [.text(workspaceID.uuidString), .blob(owner), .text(token.uuidString), .integer(baseRevision),
                      .real(now.addingTimeInterval(Self.firstListDraftLifetime).timeIntervalSinceReferenceDate), .blob(payload)])
            guard count == 1 else { throw LedgerStoreError.operationConflict }
            return .init(workspaceID: workspaceID, owner: owner, token: token, baseRevision: baseRevision)
        }
    }

    func deleteFirstListDraft(_ draft: FirstListDraftVersion) throws {
        guard workspaceID == draft.workspaceID else { throw LedgerStoreError.erased }
        let removed = try database.run("DELETE FROM first_list_draft WHERE workspace_id=? AND owner=? AND token=? AND base_revision=?",
            [.text(workspaceID.uuidString), .blob(draft.owner), .text(draft.token.uuidString), .integer(draft.baseRevision)])
        guard removed == 1 else { throw LedgerStoreError.operationConflict }
    }

    public func discardFirstListDraft(_ draft: FirstListDraftVersion) throws {
        try database.transaction { try deleteFirstListDraft(draft) }
    }

    func consumeFirstListDraft(_ draft: FirstListDraftVersion, base: Int64, now: Date) throws {
        guard draft.baseRevision == base else { throw LedgerStoreError.operationConflict }
        try prepareFirstListDrafts(owner: draft.owner, now: now)
        try deleteFirstListDraft(draft)
    }
}
