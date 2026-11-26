import Foundation
import XCTest
@testable import RecordArchive

final class PaprikaCollectionTests: XCTestCase {
    private func collection() throws -> Data {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "fictional-paprika", withExtension: "paprikarecipes", subdirectory: "Fixtures"))
        return try Data(contentsOf: file)
    }

    func testCollectionPreservesSourceTextAndReportsDuplicatesAndSkippedRows() throws {
        let report = try PaprikaCollection.stage(collection())
        XCTAssertEqual(report.recipes.map(\.title), ["Sopa de calabaza", "Bread"])
        let soup = try XCTUnwrap(report.recipes.first)
        XCTAssertEqual(soup.yieldText, "4 platos")
        XCTAssertEqual(soup.ingredients, ["2 calabazas", "Agua"])
        XCTAssertEqual(soup.steps, ["Cortar.", "Cocer."])
        XCTAssertEqual(soup.sourceURL, "https://example.org/sopa")
        XCTAssertEqual(soup.notes, "Family cookbook\n\nAl gusto.")
        XCTAssertEqual(report.duplicateCount, 1)
        XCTAssertEqual(report.skippedRows, 1)
        XCTAssertTrue(report.unsupportedFields.isEmpty)
        XCTAssertEqual(soup.categories, ["Sopas"])
    }

    func testRepeatImportPreservesEditedSourceAndSkipsExistingLibrary() throws {
        let data = try collection()
        let recipes = try PaprikaCollection.stage(data).recipes
        let repeated = try PaprikaCollection.stage(data, existing: [recipes[1]], existingSourceIDs: [recipes[0].id])
        XCTAssertTrue(repeated.recipes.isEmpty)
        XCTAssertEqual(repeated.duplicateCount, 3)
    }

    private func identified() throws -> Data {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "fictional-paprika-identified", withExtension: "paprikarecipes", subdirectory: "Fixtures"))
        return try Data(contentsOf: file)
    }

    func testDistinctUIDsWithIdenticalTextAndSameUIDRevisionsRemainAddressable() throws {
        let stage = try PaprikaCollection.stageRecords(identified(), saved: [])
        XCTAssertEqual(stage.report.duplicateCount, 1)
        XCTAssertEqual(stage.records.count, 3)
        let first = stage.records[0], other = stage.records[1], changed = stage.records[2]
        XCTAssertTrue(stage.records.allSatisfy(PaprikaCollection.isTracked))
        XCTAssertNotEqual(first.id, other.id)
        XCTAssertEqual(first.revision, other.revision)
        XCTAssertEqual(first.id, changed.id)
        XCTAssertNotEqual(first.revision, changed.revision)
        let draft = try RecipeDraftFile.encode(stage.records)
        XCTAssertEqual(Set(try XCTUnwrap(RecipeDraftFile.readIfPresent(draft)).1.map { $0.id + $0.revision }),
                       Set(stage.records.map { $0.id + $0.revision }))
    }

    func testLocalCorrectionsRememberOriginalRevisionWithoutCollapsingAnotherUID() throws {
        let stage = try PaprikaCollection.stageRecords(identified(), saved: [])
        let original = stage.records[0], other = stage.records[1], upstream = stage.records[2]
        var changed = stage.report.recipes[0]
        changed.notes = "Local change"
        let once = try PaprikaCollection.correctedRecord(changed, previous: original)
        changed.notes = "Second local change"
        let twice = try PaprikaCollection.correctedRecord(changed, previous: once)
        XCTAssertEqual(twice.parentRevision, original.revision)
        let repeated = try PaprikaCollection.stageRecords(identified(), saved: [twice])
        XCTAssertEqual(repeated.records, [other, upstream])
        XCTAssertEqual(repeated.report.duplicateCount, 2)
    }

    func testLegacySourceKeepsItsBytesAndConflictingTrackedRowsCanBeReviewed() throws {
        let stage = try PaprikaCollection.stageRecords(identified(), saved: [])
        let legacy = try stage.report.recipes[0].archiveRecord(origin: "recipe-library-v1", savedAt: Date(timeIntervalSince1970: 0))
        let oldDraft = try RecipeDraftFile.encode([legacy])
        XCTAssertEqual(try XCTUnwrap(RecipeDraftFile.readIfPresent(oldDraft)).1, [legacy])
        var edited = stage.report.recipes[0]
        edited.title = "My corrected rice"
        let corrected = try PaprikaCollection.correctedRecord(edited, previous: legacy)
        let repeated = try PaprikaCollection.stageRecords(identified(), saved: [corrected])
        XCTAssertEqual(repeated.records.count, 3)
        XCTAssertEqual(PaprikaCollection.legacyMatches(repeated.records, saved: [corrected]),
                       Set([stage.records[0].id, stage.records[1].id]))
        XCTAssertTrue(PaprikaCollection.legacyMatches(repeated.records, saved: [stage.records[0]]).isEmpty)
    }

    func testRegistrySeparatesUpstreamRevisionAndHonorsAnEarlierContentErasure() async throws {
        let stage = try PaprikaCollection.stageRecords(identified(), saved: [])
        let original = stage.records[0], changed = stage.records[2]
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let registry = try RecoveryRegistry(url: dir.appendingPathComponent("recipes.json"))
        func envelope(_ records: [ArchiveRecord]) throws -> ArchiveEnvelope {
            try ArchiveCodec.make(records: records, kind: .personalRecovery, origin: "recipe-library-v1", revision: "review")
        }
        let before = try await registry.review(envelope([original]))
        let commit = try await registry.apply(before)
        let after = try await registry.review(envelope([changed]))
        XCTAssertEqual(after.rows.first?.disposition, .sibling)
        let saved = try await registry.refreshList()
        XCTAssertEqual(saved.map(\.record), [original])
        try await registry.undoImport(insertedCopyIDs: commit.insertedCopyIDs)
        try await registry.registerErasedSources([ArchiveSourceIdentity(origin: original.origin, recordID: original.revision)])
        let erased = try await registry.review(envelope([original]))
        XCTAssertEqual(erased.rows.first?.disposition, .erased)
    }

    func testHundredRecipeMappingSurvivesDraftReimportAndPrivateExport() async throws {
        let file = try XCTUnwrap(Bundle.module.url(forResource: "fictional-cookbook-categories", withExtension: "paprikarecipes", subdirectory: "Fixtures"))
        let data = try Data(contentsOf: file)
        let first = try PaprikaCollection.stageRecords(data, saved: [])
        XCTAssertEqual(first.records.count, 100)
        XCTAssertEqual(first.report.unsupportedFields, ["categories"]) // A malformed label kept its valid sibling.
        let mapped = try first.records.map { record in
            let changed = try PaprikaCollection.mapCategory("Weeknights", to: "Menú rápido", in: record)
            return try PaprikaCollection.mapCategory("Sin carne", to: "Menú rápido", in: changed)
        }
        XCTAssertEqual(mapped.map(\.id), first.records.map(\.id))
        let draft = try XCTUnwrap(RecipeDraftFile.readIfPresent(try RecipeDraftFile.encode(mapped)))
        XCTAssertEqual(Set(draft.1.map(\.id)), Set(mapped.map(\.id)))
        XCTAssertEqual(draft.0.recipes.filter { $0.categories == ["Menú rápido"] }.count, 51)
        let sample = try XCTUnwrap(draft.0.recipes.first { $0.title == "Fixture 0" })
        XCTAssertEqual(sample.sourceURL, "https://example.org/recipes/0")
        XCTAssertEqual(sample.filing?.map(\.source), ["Sin carne", "Weeknights"])
        let repeated = try PaprikaCollection.stageRecords(data, saved: draft.1)
        XCTAssertEqual(repeated.report.duplicateCount, 100)
        XCTAssertTrue(repeated.records.isEmpty)
        var edited = sample
        edited.filing = nil
        edited.notes = "Reviewed"
        let previous = try XCTUnwrap(mapped.first { $0.title == sample.title })
        let corrected = try PaprikaCollection.correctedRecord(edited, previous: previous)
        XCTAssertEqual(corrected.id, previous.id)
        XCTAssertEqual(corrected.parentRevision, previous.parentRevision)
        let restored = try JSONDecoder().decode(ImportedRecipe.self, from: XCTUnwrap(corrected.nativePayload))
        XCTAssertEqual(restored.categories, ["Menú rápido"])
        XCTAssertTrue(ReadableArchive.text([corrected], owner: true, locale: Locale(identifier: "es_MX")).contains("Categorías: Menú rápido"))
        XCTAssertFalse(ReadableArchive.text([corrected], owner: false).contains("Menú rápido"))
        XCTAssertThrowsError(try PaprikaCollection.mapCategory("Weeknights", to: "bad\nlabel", in: previous))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("cookbook.json"))
        let document = try ArchiveCodec.make(records: draft.1, kind: .personalRecovery, origin: "recipe-library-v1", revision: "fixture")
        let review = try await registry.review(document)
        let saved = try await registry.apply(review)
        let classified = try saved.records.filter { copy in
            let recipe = try JSONDecoder().decode(ImportedRecipe.self, from: XCTUnwrap(copy.record.nativePayload))
            return recipe.categories.contains("Menú rápido")
        }
        XCTAssertEqual(classified.count, 51)
        try await registry.renameCookbookCategory("Menú rápido", to: "Todavía más fácil", reviewed: classified, authorize: { true })
        let afterRename = try await registry.refreshList()
        XCTAssertEqual(Set(afterRename.map(\.id)), Set(saved.records.map(\.id)))
        XCTAssertEqual(Set(afterRename.map(\.record.id)), Set(saved.records.map(\.record.id)))
        XCTAssertEqual(try PaprikaCollection.stageRecords(data, saved: afterRename.map(\.record)).report.duplicateCount, 100)

    }

    func testOldContentIdentityAndErasureRemainEffectiveForCategorizedSource() async throws {
        let original = try PaprikaCollection.stageRecords(collection(), saved: []).records[0]
        var legacy = try JSONDecoder().decode(ImportedRecipe.self, from: XCTUnwrap(original.nativePayload))
        legacy.filing = nil
        legacy.paprikaLegacyRevision = nil
        XCTAssertEqual(original.id, legacy.id)
        XCTAssertNotEqual(original.revision, legacy.id)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("registry.json"))
        try await registry.registerErasedSources([.init(origin: original.origin, recordID: legacy.id)])
        var tracked = try PaprikaCollection.mapCategory("Sopas", to: nil, in: original)
        tracked.id = "paprika-v1/" + ArchiveCodec.digest(Data("upstream UID".utf8))
        var renamed = try JSONDecoder().decode(ImportedRecipe.self, from: XCTUnwrap(tracked.nativePayload))
        renamed.title = "Edited after filing"
        let corrected = try PaprikaCollection.correctedRecord(renamed, previous: tracked)
        let envelope = try ArchiveCodec.make(records: [corrected], kind: .personalRecovery, origin: original.origin, revision: "fixture")
        let review = try await registry.review(envelope)
        XCTAssertEqual(review.rows.first?.disposition, .erased)
    }

    func testRejectsIncompleteAndDamagedCollectionBeforeAnyRecipeIsSaved() throws {
        var data = try collection()
        XCTAssertThrowsError(try PaprikaCollection.stage(data.dropLast(1)))
        let header = try XCTUnwrap(data.range(of: Data([0x1f, 0x8b, 0x08])))
        data[header.lowerBound + 10] ^= 1
        XCTAssertThrowsError(try PaprikaCollection.stage(data))
    }
}
