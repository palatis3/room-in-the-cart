import XCTest
import Darwin
@testable import RecordArchive

final class RecordArchiveTests: XCTestCase {
    private func record(id: String = "shop-1", revision: String = "revision-1", parent: String? = nil, saved: Int64 = 1000, title: String = "Dinner") -> ArchiveRecord {
        ArchiveRecord(id: id, origin: "local-origin", revision: revision, parentRevision: parent, kind: .comparison, title: title,
                      savedAtMilliseconds: saved, helperLines: [HelperLine(label: "Rice", originalAmount: "2", originalUnit: "packs")],
                      nativePayload: Data(#"{"privateCost":"12.50","privateNotes":"not for helper"}"#.utf8))
    }
    private func envelope(_ records: [ArchiveRecord], kind: ArchiveKind = .personalRecovery, date: Date = Date(timeIntervalSince1970: 100)) throws -> ArchiveEnvelope {
        try ArchiveCodec.make(records: records, kind: kind, origin: "local-origin", revision: "export-head", exportedAt: date)
    }
    private func temporaryURL() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent("recovery.json")
    }
    func testCanonicalRetryIgnoresEnvelopeExportTimeAndReopensAfterRestart() async throws {
        let url = try temporaryURL()
        let registry = try RecoveryRegistry(url: url)
        let firstEnvelope = try envelope([record()])
        let first = try await registry.apply(registry.review(firstEnvelope))
        let retryEnvelope = try envelope([record()], date: Date(timeIntervalSince1970: 9000))
        XCTAssertNotEqual(try ArchiveCodec.encode(firstEnvelope), try ArchiveCodec.encode(retryEnvelope))
        XCTAssertEqual(firstEnvelope.canonicalPayloadDigest, retryEnvelope.canonicalPayloadDigest)
        let reopened = try RecoveryRegistry(url: url)
        let review = try await reopened.review(retryEnvelope)
        XCTAssertEqual(review.rows.first?.disposition, .identical)
        let retry = try await reopened.apply(review)
        XCTAssertEqual(retry.insertedCount, 0)
        XCTAssertEqual(retry.records.first?.id, first.records.first?.id)
    }
    func testSiblingAndOlderImportNeverOverwriteNewerCopy() async throws {
        let registry = try RecoveryRegistry(url: temporaryURL())
        let newer = try envelope([record(revision: "newer", parent: "base", saved: 9000)])
        let newCopy = try await registry.apply(registry.review(newer))
        let older = try envelope([record(revision: "older", parent: "base", saved: 100)])
        let review = try await registry.review(older)
        XCTAssertEqual(review.rows.first?.disposition, .sibling)
        _ = try await registry.apply(review)
        let all = await registry.list()
        XCTAssertEqual(all.count, 2)
        let stillNew = await registry.load(id: newCopy.records[0].id)
        XCTAssertEqual(stillNew?.record.revision, "newer")
    }
    func testImportReviewListsOnlyMatchingSourceVersionsWithTheirOriginalDatesAndMediaSelection() async throws {
        let url = try temporaryURL(), registry = try RecoveryRegistry(url: url)
        let plain = record(revision: "b", saved: 600)
        var selected = plain
        selected.media = [.init(id: "pack", kind: .packageReference, data: Data("private label".utf8))]
        let unknown = record(revision: "unknown-date", saved: 0)
        var otherOrigin = record(revision: "other origin", saved: 900)
        otherOrigin.origin = "other"
        let ownerFile = try envelope([plain, selected, unknown, otherOrigin, record(id: "other-id")])
        let ownerCommit = try await registry.apply(registry.review(ownerFile))
        let helperFile = try envelope([record(revision: "a", saved: 600)], kind: .helperShop)
        let helperCommit = try await registry.apply(registry.review(helperFile))
        let reopened = try RecoveryRegistry(url: url)
        let incoming = try envelope([record(revision: "new"), plain, record(id: "unrelated")])
        let review = try await reopened.review(incoming)
        let plainCopy = try XCTUnwrap(ownerCommit.records.first { $0.record == plain })
        let selectedCopy = try XCTUnwrap(ownerCommit.records.first { $0.record == selected })
        let unknownCopy = try XCTUnwrap(ownerCommit.records.first { $0.record == unknown })
        let byRevision = [helperCommit.records[0], plainCopy, selectedCopy].sorted {
            ($0.receipt.identity.revision, $0.receipt.identity.projection) < ($1.receipt.identity.revision, $1.receipt.identity.projection)
        } + [unknownCopy]
        let expected = byRevision.map { saved in
            RecoveredCopySummary(id: saved.receipt.identity, documentKind: saved.documentKind,
                                 savedAtMilliseconds: saved.record.savedAtMilliseconds, selectedReferenceCount: saved.record.media?.count ?? 0)
        }
        let sibling = try XCTUnwrap(review.rows.first { $0.record.revision == "new" })
        let identical = try XCTUnwrap(review.rows.first { $0.record == plain })
        let absent = try XCTUnwrap(review.rows.first { $0.record.id == "unrelated" })
        XCTAssertEqual([sibling.disposition, identical.disposition, absent.disposition], [.sibling, .identical, .absent])
        XCTAssertEqual(sibling.priorCopies, expected)
        XCTAssertEqual(identical.priorCopies, expected)
        XCTAssertEqual(identical.existingCopyID, plainCopy.id)
        XCTAssertTrue(absent.priorCopies.isEmpty)
        XCTAssertEqual(sibling.priorCopies.last?.savedAtMilliseconds, 0)
        XCTAssertEqual(sibling.priorCopies.filter { $0.selectedReferenceCount == 1 }.map(\.id), [selectedCopy.receipt.identity])
    }

    func testHelperAndErasedReviewHideOwnerMetadataAndConflictingBatchLeavesBytesUntouched() async throws {
        let url = try temporaryURL(), registry = try RecoveryRegistry(url: url)
        let owner = record(revision: "private"), other = record(revision: "sibling")
        let commit = try await registry.apply(registry.review(envelope([owner, other])))
        let helperFile = try envelope([record(revision: "helper")], kind: .helperShop)
        let helperReview = try await registry.review(helperFile)
        XCTAssertEqual(helperReview.rows[0].disposition, .sibling)
        XCTAssertTrue(helperReview.rows[0].priorCopies.isEmpty)
        let savedHelper = try await registry.apply(helperReview)
        let helperVersions = try await registry.review(helperFile).rows[0].priorCopies
        XCTAssertEqual(helperVersions.map(\.id), [savedHelper.records[0].receipt.identity])
        XCTAssertEqual(helperVersions.map(\.selectedReferenceCount), [0])
        let rewrapped = try await registry.review(envelope(helperFile.payload.records))
        XCTAssertEqual(rewrapped.rows[0].priorCopies, helperVersions)
        _ = try await registry.delete(.copy(commit.records[0].id))
        var changed = other
        changed.title = "Conflict"
        let before = try Data(contentsOf: url)
        let blocked = try await registry.review(envelope([owner, changed, record(id: "new")]))
        let erased = try XCTUnwrap(blocked.rows.first { $0.record == owner })
        let quarantined = try XCTUnwrap(blocked.rows.first { $0.record == changed })
        let absent = try XCTUnwrap(blocked.rows.first { $0.record.id == "new" })
        XCTAssertEqual([erased.disposition, quarantined.disposition, absent.disposition], [.erased, .quarantined, .absent])
        XCTAssertTrue(erased.priorCopies.isEmpty)
        XCTAssertNil(erased.existingCopyID)
        XCTAssertEqual(Set(quarantined.priorCopies.map(\.id)), [savedHelper.records[0].receipt.identity, commit.records[1].receipt.identity])
        do { _ = try await registry.apply(blocked); XCTFail("The entire batch must be refused") }
        catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    func testSameRevisionDifferentDigestQuarantinesEntireBatch() async throws {
        let registry = try RecoveryRegistry(url: temporaryURL())
        _ = try await registry.apply(registry.review(envelope([record()])))
        let attempted = try envelope([record(title: "tampered"), record(id: "unrelated")])
        let review = try await registry.review(attempted)
        XCTAssertFalse(review.canApply)
        XCTAssertTrue(review.rows.contains { $0.disposition == .quarantined })
        do { _ = try await registry.apply(review); XCTFail("Conflict must not apply") } catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
        let remaining = await registry.list()
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(remaining[0].record.title, "Dinner")
    }
    func testCorruptTruncatedFutureAndOversizedInputsNeverMutateRegistry() async throws {
        let url = try temporaryURL(), registry: RecoveryRegistry
        registry = try RecoveryRegistry(url: url)
        _ = try await registry.apply(registry.review(envelope([record()])))
        let original = try Data(contentsOf: url)
        let data = try ArchiveCodec.encode(envelope([record()]))
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        json["canonicalPayloadDigest"] = String(repeating: "0", count: 64)
        XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: json))) { XCTAssertEqual($0 as? ArchiveError, .integrity) }
        XCTAssertThrowsError(try ArchiveCodec.decode(data.dropLast()))
        json["formatMajor"] = 99
        XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: json))) { XCTAssertEqual($0 as? ArchiveError, .unsupportedVersion) }
        XCTAssertThrowsError(try ArchiveCodec.decode(Data(repeating: 32, count: ArchiveCodec.maximumFileBytes + 1))) { XCTAssertEqual($0 as? ArchiveError, .tooLarge) }
        XCTAssertEqual(try Data(contentsOf: url), original)
    }
    func testProjectionRedactsPrivateNativePayloadInJSONAndReadableText() throws {
        let projected = try envelope([record()], kind: .helperShop)
        let data = try ArchiveCodec.encode(projected)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertFalse(text.contains("nativePayload"))
        XCTAssertFalse(text.contains("privateCost"))
        XCTAssertNil(projected.payload.records[0].nativePayload)
        XCTAssertNotEqual(projected.projectionID, ArchiveCodec.projection(for: .personalRecovery))
        let readable = ReadableArchive.text([record()], owner: false)
        XCTAssertTrue(readable.contains("Rice")); XCTAssertFalse(readable.contains("12.50"))
        XCTAssertTrue(ReadableArchive.text([record()], owner: true).contains("12.50"))
    }
    func testPersonalRecipeTextKeepsOriginalIngredientsAndOrderedInstructionsInBothLanguages() throws {
        let recipe = ImportedRecipe(title: "Sopa", yieldText: "2 platos", ingredients: ["½ taza de arroz", "salt to taste"],
                                    steps: ["Añadir arroz.", "Cover and simmer."], sourceURL: "https://example.test/sopa", notes: "La nota familiar")
        let record = try recipe.archiveRecord(origin: "recipes")
        let en = ReadableArchive.text([record], owner: true, locale: Locale(identifier: "en_US"))
        let es = ReadableArchive.text([record], owner: true, locale: Locale(identifier: "es_US"))
        XCTAssertTrue(en.contains("Yield: 2 platos\nIngredients\n½ taza de arroz\nsalt to taste\nInstructions"))
        XCTAssertTrue(es.contains("Rinde: 2 platos\nIngredientes\n½ taza de arroz\nsalt to taste\nPreparación"))
        for text in [en, es] {
            XCTAssertTrue(text.contains("1. Añadir arroz.\n2. Cover and simmer."))
            XCTAssertTrue(text.contains("La nota familiar"))
            XCTAssertTrue(text.contains("https://example.test/sopa"))
            XCTAssertFalse(text.contains("\"yieldText\":"))
        }
        let helper = ReadableArchive.text([record], owner: false, locale: Locale(identifier: "es_US"))
        XCTAssertTrue(helper.contains("½ taza de arroz"))
        XCTAssertFalse(helper.contains("La nota familiar"))
        XCTAssertFalse(helper.contains("https://example.test/sopa"))
    }

    func testHelperThenOwnerKeepsProjectionsIndependent() async throws {
        let registry = try RecoveryRegistry(url: temporaryURL())
        _ = try await registry.apply(registry.review(envelope([record()], kind: .helperShop)))
        let ownerReview = try await registry.review(envelope([record()]))
        XCTAssertEqual(ownerReview.rows.first?.disposition, .sibling)
        _ = try await registry.apply(ownerReview)
        let records = await registry.list()
        XCTAssertEqual(records.count, 2)
        XCTAssertEqual(records.filter { $0.record.nativePayload != nil }.count, 1)
    }
    func testAuthenticatedEncryptionRejectsWrongKeyAndTampering() throws {
        let expected = try envelope([record()]), key = EncryptedArchive.generateKey()
        let bytes = try EncryptedArchive.seal(expected, key: key)
        XCTAssertEqual(try EncryptedArchive.open(bytes, key: key), expected)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Dinner"))
        XCTAssertThrowsError(try EncryptedArchive.open(bytes, key: EncryptedArchive.generateKey())) { XCTAssertEqual($0 as? ArchiveError, .locked) }
        XCTAssertThrowsError(try EncryptedArchive.open(bytes, key: "password")) { XCTAssertEqual($0 as? ArchiveError, .invalidKey) }
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        var sealed = try XCTUnwrap(Data(base64Encoded: object["combined"] as! String)); sealed[sealed.count - 1] ^= 1
        object["combined"] = sealed.base64EncodedString()
        XCTAssertThrowsError(try EncryptedArchive.open(JSONSerialization.data(withJSONObject: object), key: key))
    }
    func testStaleReviewCannotCommit() async throws {
        let registry = try RecoveryRegistry(url: temporaryURL())
        let stale = try await registry.review(envelope([record()]))
        _ = try await registry.apply(registry.review(envelope([record(id: "different")])) )
        do { _ = try await registry.apply(stale); XCTFail("Requires another review") } catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let all = await registry.list(); XCTAssertEqual(all.count, 1)
    }
    func testScopedDeleteUndoAndErasureMarker() async throws {
        let registry = try RecoveryRegistry(url: temporaryURL())
        let archive = try envelope([record(), record(id: "other")])
        let commit = try await registry.apply(registry.review(archive))
        let token = try await registry.delete(.copy(commit.records[0].id))
        let afterDelete = await registry.list(); XCTAssertEqual(afterDelete.count, 1)
        let blocked = try await registry.review(archive); XCTAssertFalse(blocked.canApply)
        try await registry.undoDelete(token)
        let restored = await registry.list(); XCTAssertEqual(restored.count, 2)
        let reimport = try await registry.review(archive); XCTAssertTrue(reimport.canApply)
    }
    func testSupportReportNamesSupportedFormatsAndKeepsDiagnosticCodesInBothLanguages() {
        let spanish = ReadableArchive.supportReport(error: .invalidKey, recordCount: 2, locale: Locale(identifier: "es_US"))
        XCTAssertEqual(spanish, "Soporte de Room in the Cart\nFormatos compatibles: 1.0, 1.1, 1.2\nNúmero de registros: 2\nEstado: invalidKey")
        let english = ReadableArchive.supportReport(error: nil, recordCount: 0, locale: Locale(identifier: "en_US"))
        XCTAssertEqual(english, "Room in the Cart support\nSupported archive formats: 1.0, 1.1, 1.2\nRecord count: 0\nStatus: ok")
    }
    func testRecipeGraphPreservesOriginalTextAndReportsSkippedFieldsAndDuplicates() throws {
        let data = Data(#"{"@context":"https://unreachable.invalid/context","formatVersion":1,"@graph":[{"@type":"Recipe","name":"Arroz","recipeYield":"three plates + lunch","recipeIngredient":["2 cans (15 oz) tomatoes","salt to taste"],"recipeInstructions":[{"@type":"HowToStep","text":"Keep original words."}],"url":"https://example.invalid/recipe","notes":"Family note","nutrition":{"calories":"unknown"}},{"@type":"Person","name":"ignored"},{"@type":"Recipe","name":"Arroz","recipeYield":"three plates + lunch","recipeIngredient":["2 cans (15 oz) tomatoes","salt to taste"],"recipeInstructions":[{"@type":"HowToStep","text":"Keep original words."}],"url":"https://example.invalid/recipe","notes":"Family note"}]}"#.utf8)
        let report = try RecipeImporter.stage(data)
        XCTAssertEqual(report.recipes.count, 1); XCTAssertEqual(report.duplicateCount, 1); XCTAssertEqual(report.skippedRows, 1)
        XCTAssertEqual(report.unsupportedFields, ["nutrition"])
        XCTAssertEqual(report.recipes[0].ingredients[0], "2 cans (15 oz) tomatoes")
        XCTAssertEqual(report.recipes[0].yieldText, "three plates + lunch")
    }
    func testRecipeExceedingNativeRecordSizeDoesNotBlockAnotherRecipeInTheFile() throws {
        let step = String(repeating: "a", count: 32768)
        let file = try JSONSerialization.data(withJSONObject: [
            ["@type": "Recipe", "name": "Too large", "recipeInstructions": Array(repeating: step, count: 128)],
            ["@type": "Recipe", "name": "Dinner", "recipeInstructions": [step]]
        ])
        let staged = try RecipeImporter.stage(file)
        XCTAssertEqual(staged.skippedRows, 1)
        XCTAssertEqual(staged.recipes.map(\.title), ["Dinner"])
        XCTAssertEqual(staged.recipes.first?.steps, [step])
    }

    func testRecipePreviewSkipsUnrelatedNodesAndIdentifiesOmittedInstructionFields() throws {
        let data = Data(#"""
        {"formatVersion":1,"@graph":[
          {"@type":"Person","formatVersion":7,"name":"Author"},
          {"@type":"Recipe","name":"Bad notes","description":{"text":"Do not silently discard me"}},
          {"@type":"Recipe","name":"Rice","description":"Family recipe",
           "recipeInstructions":[{"@type":"HowToStep","text":"Simmer","image":"pot.jpg"}]},
          {"@type":"Recipe","name":"Soup","notes":"Original notes","description":{"text":"Other metadata"}}
        ]}
        """#.utf8)
        let report = try RecipeImporter.stage(data)
        XCTAssertEqual(report.skippedRows, 2)
        XCTAssertEqual(report.recipes.map(\.title), ["Rice", "Soup"])
        XCTAssertEqual(report.recipes.map(\.notes), ["Family recipe", "Original notes"])
        XCTAssertEqual(report.recipes.first?.steps, ["Simmer"])
        XCTAssertEqual(report.unsupportedFields, ["recipeInstructions.image"])
    }
    func testRecipeUnknownVersionUnsafeURLAndMalformedInputsFail() throws {
        XCTAssertThrowsError(try RecipeImporter.stage(Data(#"{"formatVersion":2,"@type":"Recipe","name":"Dinner"}"#.utf8))) { XCTAssertEqual($0 as? ArchiveError, .unsupportedVersion) }
        XCTAssertThrowsError(try RecipeImporter.stage(Data(#"[{"formatVersion":2,"@type":"Recipe","name":"Dinner"}]"#.utf8)))
        for json in [#"{"formatVersion":true,"@graph":[{"@type":"Recipe","name":"Dinner"}]}"#,
                     #"[{"@type":"Recipe","name":"Dinner","formatVersion":true}]"#] {
            XCTAssertThrowsError(try RecipeImporter.stage(Data(json.utf8))) {
                XCTAssertEqual($0 as? ArchiveError, .unsupportedVersion)
            }
        }
        let mixed = Data(#"[{"@type":"Recipe","name":"Bad source","url":"https:///recipe"},{"@type":"Recipe","name":"Dinner","url":"https://example.org/recipe"}]"#.utf8)
        let preview = try RecipeImporter.stage(mixed)
        XCTAssertEqual(preview.recipes.map(\.title), ["Dinner"])
        XCTAssertEqual(preview.skippedRows, 1)
        let recipeJSON = #"{"@type":"Recipe","name":"Dinner"}"#
        for encoding: String.Encoding in [.utf16LittleEndian, .utf16BigEndian, .utf32LittleEndian, .utf32BigEndian] {
            let bytes = try XCTUnwrap(recipeJSON.data(using: encoding))
            XCTAssertThrowsError(try RecipeImporter.stage(bytes)) { XCTAssertEqual($0 as? ArchiveError, .malformed) }
        }
        XCTAssertThrowsError(try ImportedRecipe(title: "Dinner", sourceURL: "javascript:alert(1)").validated())
        XCTAssertThrowsError(try RecipeImporter.stage(Data(#"{"@type":"Recipe""#.utf8)))
    }
    func testRecipeBatchUndoPreservesExistingCopyAndAllowsRetry() async throws {
        let registry = try RecoveryRegistry(url: temporaryURL())
        let first = try await registry.apply(registry.review(envelope([record()])))
        let added = try await registry.apply(registry.review(envelope([record(id: "new-recipe")])))
        try await registry.undoImport(insertedCopyIDs: added.records.map(\.id))
        let remaining = await registry.list(); XCTAssertEqual(remaining.map(\.id), first.records.map(\.id))
        let review = try await registry.review(envelope([record(id: "new-recipe")]))
        XCTAssertEqual(review.rows.first?.disposition, .absent)
    }
    func testVersionOneFixtureAndExplicitVersionZeroMigrationBoundary() throws {
        let directory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appendingPathComponent("Fixtures")
        let current = try ArchiveCodec.decode(Data(contentsOf: directory.appendingPathComponent("archive-v1.json")))
        XCTAssertEqual(current.formatMajor, 1)
        XCTAssertEqual(current.payload.records.first?.title, "Fixture dinner")
        XCTAssertThrowsError(try ArchiveCodec.decode(Data(contentsOf: directory.appendingPathComponent("archive-v0-unsupported.json")))) { XCTAssertEqual($0 as? ArchiveError, .unsupportedVersion) }
    }
    func testRecoveryReadOpensOnlyTheSelectedRegularFile() throws {
        let source = try temporaryURL()
        let contents = Data("private backup".utf8)
        try contents.write(to: source)
        XCTAssertEqual(try RecoveryRegistry.boundedRead(source, maximum: contents.count), contents)

        let link = source.appendingPathExtension("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: source)
        let pipe = source.appendingPathExtension("fifo")
        XCTAssertEqual(mkfifo(pipe.path, S_IRUSR | S_IWUSR), 0)
        // Keep the fixture open so a regression also terminates deterministically.
        let endpoint = Darwin.open(pipe.path, O_RDWR | O_NONBLOCK)
        guard endpoint >= 0 else { return XCTFail("Could not open the test pipe") }
        defer { Darwin.close(endpoint) }
        let sample: [UInt8] = [1, 2]
        XCTAssertEqual(Darwin.write(endpoint, sample, sample.count), sample.count)
        for url in [link, pipe, source.deletingLastPathComponent()] {
            XCTAssertThrowsError(try RecoveryRegistry.boundedRead(url, maximum: 1)) {
                XCTAssertEqual($0 as? ArchiveError, .unavailable)
            }
        }
    }

    func testDepthAndFileReadAreBounded() throws {
        let excessive = Data((String(repeating: "[", count: 49) + "0" + String(repeating: "]", count: 49)).utf8)
        XCTAssertThrowsError(try ArchiveCodec.preflight(excessive)) { XCTAssertEqual($0 as? ArchiveError, .tooLarge) }
        let url = try temporaryURL(); try Data(repeating: 1, count: 101).write(to: url)
        XCTAssertThrowsError(try RecoveryRegistry.boundedRead(url, maximum: 100)) { XCTAssertEqual($0 as? ArchiveError, .tooLarge) }
    }
    func testTwoFreshRegistriesConcurrentIdenticalApplyReturnsOneCopyAndExactInsertedIDs() async throws {
        let url = try temporaryURL()
        let first = try RecoveryRegistry(url: url), second = try RecoveryRegistry(url: url)
        let archive = try envelope([record()])
        let a = try await first.review(archive), b = try await second.review(archive)
        async let left = first.apply(a)
        async let right = second.apply(b)
        let commits = try await [left, right]
        XCTAssertEqual(commits.reduce(0) { $0 + $1.insertedCount }, 1)
        XCTAssertEqual(commits[0].records.first?.id, commits[1].records.first?.id)
        let all = try await first.refreshList()
        XCTAssertEqual(all.count, 1)
        let retry = try await second.apply(b)
        XCTAssertTrue(retry.insertedCopyIDs.isEmpty)
        try await second.undoImport(insertedCopyIDs: retry.insertedCopyIDs)
        let remaining = try await second.refreshList()
        XCTAssertEqual(remaining.count, 1)
    }
    func testConcurrentConflictingDigestIsQuarantinedAndCanReReviewUnrelatedChange() async throws {
        let url = try temporaryURL()
        let first = try RecoveryRegistry(url: url), second = try RecoveryRegistry(url: url)
        let conflict = try await second.review(envelope([record(title: "Changed")]))
        let unrelated = try await second.review(envelope([record(id: "another")]))
        _ = try await first.apply(first.review(envelope([record()])))
        do { _ = try await second.apply(conflict); XCTFail("Must quarantine") }
        catch { XCTAssertEqual(error as? ArchiveError, .conflict) }
        do { _ = try await second.apply(unrelated); XCTFail("Must re-review") }
        catch { XCTAssertEqual(error as? ArchiveError, .staleReview) }
        let fresh = try await second.review(unrelated.envelope)
        _ = try await second.apply(fresh)
        let all = try await first.refreshList()
        XCTAssertEqual(all.count, 2)
        XCTAssertEqual(all.first { $0.record.id == "shop-1" }?.record.title, "Dinner")
    }
    func testRepeatedImportUndoPreservesUnrelatedPendingReview() async throws {
        let url = try temporaryURL()
        let registry = try RecoveryRegistry(url: url)
        let imported = try await registry.apply(registry.review(envelope([record()])))
        try await registry.undoImport(insertedCopyIDs: imported.insertedCopyIDs)

        let other = try RecoveryRegistry(url: url)
        let pending = try await other.review(envelope([record(id: "another")]))
        let savedManifest = try Data(contentsOf: url)
        try await registry.undoImport(insertedCopyIDs: [])
        XCTAssertEqual(try Data(contentsOf: url), savedManifest)
        try await registry.undoImport(insertedCopyIDs: imported.insertedCopyIDs)
        XCTAssertEqual(try Data(contentsOf: url), savedManifest)
        let result = try await other.apply(pending)
        XCTAssertEqual(result.insertedCount, 1)
    }
    func testFailedAtomicWriteLeavesRegistryEmptyAndRetryPreservesReview() async throws {
        let url = try temporaryURL()
        let actual = try RecoveryRegistry(url: url)
        let reviewed = try await actual.review(envelope([record()]))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        do { _ = try await actual.apply(reviewed); XCTFail("Directory cannot hold manifest") } catch {}
        try FileManager.default.removeItem(at: url)
        let retry = try await actual.apply(reviewed)
        XCTAssertEqual(retry.insertedCount, 1)
    }
    func testExternalSourceErasurePurgesAllProjectionsAndBlocksOlderRevisionsAfterRestart() async throws {
        let url = try temporaryURL()
        let actual = try RecoveryRegistry(url: url)
        _ = try await actual.apply(actual.review(envelope([record()])))
        _ = try await actual.apply(actual.review(envelope([record()], kind: .helperShop)))
        try await actual.registerErasedSources([ArchiveSourceIdentity(origin: "local-origin", recordID: "shop-1")])
        let reopened = try RecoveryRegistry(url: url)
        let all = try await reopened.refreshList(); XCTAssertTrue(all.isEmpty)
        let old = try await reopened.review(envelope([record(revision: "earlier")]))
        XCTAssertEqual(old.rows.first?.disposition, .erased)
        XCTAssertFalse(old.canApply)
        let text = String(decoding: try Data(contentsOf: url), as: UTF8.self)
        XCTAssertFalse(text.contains("Dinner")); XCTAssertFalse(text.contains("privateCost"))
    }
    func testUnknownEnvelopeAndHelperFieldsAreRejected() throws {
        let bytes = try ArchiveCodec.encode(envelope([record()], kind: .helperShop))
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: bytes) as? [String: Any])
        object["credentials"] = "must not be ignored"
        XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: object))) { XCTAssertEqual($0 as? ArchiveError, .unsupportedRecord) }
        object.removeValue(forKey: "credentials")
        var payload = try XCTUnwrap(object["payload"] as? [String: Any])
        var records = try XCTUnwrap(payload["records"] as? [[String: Any]])
        records[0]["privateBudget"] = "34.50"
        payload["records"] = records; object["payload"] = payload
        XCTAssertThrowsError(try ArchiveCodec.decode(JSONSerialization.data(withJSONObject: object))) { XCTAssertEqual($0 as? ArchiveError, .unsupportedRecord) }
    }

    func testRetiredOriginBlocksUnseenOldShopAndCannotUndoDeletedPrivateText() async throws {
        let url = try temporaryURL(), registry = try RecoveryRegistry(url: url)
        let committed = try await registry.apply(registry.review(envelope([record()])))
        let undo = try await registry.delete(.copy(committed.records[0].id))
        try await registry.registerErasedOrigins(["local-origin"])
        do { try await registry.undoDelete(undo); XCTFail("Erasure overrides undo") } catch {}
        let restarted = try RecoveryRegistry(url: url)
        let old = try await restarted.review(envelope([record(id: "previously-unseen-shop", revision: "old")]))
        XCTAssertEqual(old.rows.first?.disposition, .erased)
        XCTAssertFalse(old.canApply)
        let all = try await restarted.refreshList(); XCTAssertTrue(all.isEmpty)
    }

    func testCombinedPayloadIsBoundedBeforeEncodingAndHelperIgnoresPrivateBytes() throws {
        var first = record(), second = record(id: "second")
        first.nativePayload = Data(repeating: 65, count: ArchiveCodec.maximumNativeBytes)
        second.nativePayload = first.nativePayload
        XCTAssertThrowsError(try envelope([first, second])) { XCTAssertEqual($0 as? ArchiveError, .tooLarge) }
        let helper = try envelope([first, second], kind: .helperShop)
        XCTAssertLessThan(try ArchiveCodec.encode(helper).count, 4096)
    }

}
