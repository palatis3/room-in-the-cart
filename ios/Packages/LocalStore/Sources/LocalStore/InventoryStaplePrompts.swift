import CSQLite
import Foundation

public enum StaplePromptAnswer: Equatable, Sendable {
    case stillHave, dismiss, snooze(until: Date)
}

public struct StaplePromptPreferences: Equatable, Sendable {
    public let revision: UUID?
    public let answers: [UUID: StaplePromptAnswer] // keyed by the confirmed acquisition that prompted the question
    public var enabled: Bool { revision != nil }
}

extension ComparisonDatabase {
    func createStaplePromptsSchema() throws {
        try execute("""
            CREATE TABLE inventory_staple_preferences (
                persona TEXT PRIMARY KEY NOT NULL CHECK(length(persona)=36),
                revision TEXT NOT NULL CHECK(length(revision)=36)
            );
            CREATE TABLE inventory_staple_answers (
                persona TEXT NOT NULL REFERENCES inventory_staple_preferences(persona) ON DELETE CASCADE,
                food_id TEXT NOT NULL CHECK(length(food_id)=36),
                source_id TEXT NOT NULL REFERENCES inventory_acquisitions(id) ON DELETE CASCADE,
                answer TEXT NOT NULL CHECK(answer IN ('stillHave','dismiss','snooze')),
                until_time REAL,
                PRIMARY KEY(persona,food_id),
                CHECK((answer='snooze')=(until_time IS NOT NULL))
            );
            CREATE INDEX inventory_staple_source ON inventory_staple_answers(source_id);
            """)
    }

    func hasStaplePromptsSchema() throws -> Bool {
        let count = try integer("""
            SELECT count(*) FROM sqlite_master WHERE
            (type='table' AND name IN ('inventory_staple_preferences','inventory_staple_answers')) OR
            (type='index' AND name='inventory_staple_source')
            """)
        guard count == 0 || count == 3 else { throw ComparisonStoreError.corruptRecord }
        return count == 3
    }
}

extension ComparisonStore {
    private func stapleRevision(persona: UUID) throws -> UUID? {
        let row = try database.statement("SELECT revision FROM inventory_staple_preferences WHERE persona=?", values: [.text(persona.uuidString)])
        defer { sqlite3_finalize(row) }
        let step = sqlite3_step(row)
        if step == SQLITE_DONE { return nil }
        guard step == SQLITE_ROW, let id = try UUID(uuidString: database.text(row, column: 0)) else { throw ComparisonStoreError.corruptRecord }
        return id
    }

    public func staplePreferences(persona: UUID) throws -> StaplePromptPreferences {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        return try database.transaction(immediate: false) {
            try database.requireInventoryOriginLive()
            let revision = try stapleRevision(persona: persona)
            var answers: [UUID: StaplePromptAnswer] = [:]
            let rows = try database.statement("SELECT source_id,answer,until_time FROM inventory_staple_answers WHERE persona=?", values: [.text(persona.uuidString)])
            defer { sqlite3_finalize(rows) }
            while true {
                let step = sqlite3_step(rows)
                if step == SQLITE_DONE { break }
                guard step == SQLITE_ROW, let source = try UUID(uuidString: database.text(rows, column: 0)) else { throw ComparisonStoreError.corruptRecord }
                switch try database.text(rows, column: 1) {
                case "stillHave": answers[source] = .stillHave
                case "dismiss": answers[source] = .dismiss
                case "snooze":
                    let until = sqlite3_column_double(rows, 2)
                    guard until.isFinite else { throw ComparisonStoreError.corruptRecord }
                    answers[source] = .snooze(until: Date(timeIntervalSinceReferenceDate: until))
                default: throw ComparisonStoreError.corruptRecord
                }
            }
            return StaplePromptPreferences(revision: revision, answers: answers)
        }
    }

    public func setStaplePrompts(_ enabled: Bool, persona: UUID, expectedRevision: UUID?) throws {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.transaction {
            try database.requireInventoryOriginLive()
            guard try stapleRevision(persona: persona) == expectedRevision else { throw ComparisonStoreError.staleInventory }
            if enabled && expectedRevision == nil {
                try database.run("INSERT INTO inventory_staple_preferences(persona,revision) VALUES(?,?)", [.text(persona.uuidString), .text(UUID().uuidString)])
            } else if !enabled {
                try database.run("DELETE FROM inventory_staple_preferences WHERE persona=?", [.text(persona.uuidString)])
            }
        }
    }

    public func answerStaplePrompt(_ answer: StaplePromptAnswer, foodID: UUID, sourceID: UUID, persona: UUID,
                                   expectedRevision: UUID, inventoryRevision: Int64) throws {
        guard inventoryEnabled else { throw ComparisonStoreError.inventoryDisabled }
        try database.transaction {
            try database.requireInventoryOriginLive()
            let inventory = try database.inventoryState(workspaceID: workspaceID)
            guard inventory.active, inventory.revision == inventoryRevision,
                  try stapleRevision(persona: persona) == expectedRevision else { throw ComparisonStoreError.staleInventory }
            let kind: String
            var until: ComparisonSQLValue = .null
            switch answer {
            case .stillHave: kind = "stillHave"
            case .dismiss: kind = "dismiss"
            case .snooze(let date):
                guard date.timeIntervalSinceReferenceDate.isFinite else { throw ComparisonStoreError.invalidInput }
                kind = "snooze"; until = .real(date.timeIntervalSinceReferenceDate)
            }
            let changed = try database.run("""
                INSERT INTO inventory_staple_answers(persona,food_id,source_id,answer,until_time)
                SELECT ?,?,id,?,? FROM inventory_acquisitions WHERE id=? AND revision=1
                ON CONFLICT(persona,food_id) DO UPDATE SET
                    source_id=excluded.source_id,answer=excluded.answer,until_time=excluded.until_time
                """, [.text(persona.uuidString), .text(foodID.uuidString), .text(kind), until, .text(sourceID.uuidString)])
            guard changed == 1 else { throw ComparisonStoreError.staleInventory }
            try database.run("UPDATE inventory_staple_preferences SET revision=? WHERE persona=?", [.text(UUID().uuidString), .text(persona.uuidString)])
        }
    }
}
