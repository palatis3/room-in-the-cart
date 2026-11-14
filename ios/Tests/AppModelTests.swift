import XCTest
import CoreDomain
import LocalStore
import RecordArchive
import SQLite3
@testable import RoomInTheCart

final class AppModelTests: XCTestCase {
    @MainActor
    func testDamagedComparisonDoesNotHideHealthyRecordAfterRelaunch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.sqlite")
        let store = try ComparisonStore(url: url)
        let draft = makeDraft(unknownSecondYield: false)
        let healthy = try await store.save(id: draft.id, title: draft.item,
            payload: JSONEncoder().encode(SavedPayload(draft: draft)), savedAt: Date())
        let damagedID = UUID()
        try await store.save(id: damagedID, title: "Damaged", payload: Data([1]), savedAt: Date())
        try await store.close()
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &db), SQLITE_OK)
        let query = "DROP TRIGGER immutable_revision_update; UPDATE comparison_revisions SET envelope = x'7B' WHERE comparison_id = '\(damagedID.uuidString)'"
        let status = sqlite3_exec(db, query, nil, nil, nil)
        sqlite3_close(db)
        XCTAssertEqual(status, SQLITE_OK)
        let before = try Data(contentsOf: url)
        let app = AppModel(databaseURL: url)
        await app.open()
        XCTAssertTrue(app.ready)
        XCTAssertNil(app.error)
        XCTAssertEqual(app.records, [healthy])
        XCTAssertEqual(app.unavailableRecords.map(\.id), [damagedID])
        XCTAssertEqual(try app.decode(try XCTUnwrap(app.records.first)), draft)
        await app.refresh()
        XCTAssertEqual(app.unavailableRecords.count, 1)
        try await app.store?.close()
        XCTAssertEqual(try Data(contentsOf: url), before)
    }

    @MainActor
    func testDecimalQuantityParsingIsExactAndRetainsSourceLiteral() throws {
        let cases: [(String, Int64, Int64)] = [
            ("0", 0, 1), ("0.1", 1, 10), ("12.5000", 25, 2),
            ("0.000001", 1, 1_000_000), (" 001.2500 \n", 5, 4)
        ]
        for (literal, numerator, denominator) in cases {
            let quantity = try XCTUnwrap(ComparisonModel.quantity(literal, .kilogram))
            XCTAssertEqual(quantity.amount, try Rational(numerator, denominator), literal)
            XCTAssertEqual(quantity.originalLiteral, literal)
            XCTAssertEqual(quantity.unit, .kilogram)
        }
        XCTAssertNil(try ComparisonModel.rational(" \n\t"))
        XCTAssertNil(try ComparisonModel.quantity("", .count))
    }

    @MainActor
    func testParserRejectsSignsGroupingExponentsAndMalformedNumbers() {
        let invalid = ["-1", "+1", "−1", "1,000", "1,25", "1 000", "1e3", "1E-3",
                       ".5", "1.", "1.2.3", "NaN", "Infinity", "$2.00", "1/2", "2 cups",
                       "0.0000001", "１２", "١٢", "1\0", "1234567890123456789012345"]
        for literal in invalid {
            XCTAssertThrowsError(try ComparisonModel.rational(literal), literal)
            XCTAssertThrowsError(try ComparisonModel.money(literal), literal)
        }
    }

    func testFractionalFoodAmountsRetainOriginalInputAndDoNotBecomePrices() throws {
        let cases: [(String, Rational)] = [("1/3", try Rational(1, 3)),
            ("1 1/2", try Rational(3, 2)), ("2⅔", try Rational(8, 3)), (" ½ ", try Rational(1, 2))]
        for (literal, expected) in cases {
            let quantity = try XCTUnwrap(ComparisonModel.quantity(literal, .cup))
            XCTAssertEqual(quantity.amount, expected)
            XCTAssertEqual(quantity.originalLiteral, literal)
            XCTAssertThrowsError(try ComparisonModel.money(literal))
        }
        for invalid in ["1/0", "1/2-3/4", "1/2 cup", "+1/2", "1 2", "1.0000001", "1 1/2 1/2"] {
            XCTAssertThrowsError(try ComparisonModel.quantity(invalid, .cup), invalid)
        }
    }

    @MainActor
    func testUSDParserUsesExactCentsAndRejectsMoreThanTwoDecimalPlaces() throws {
        let cases: [(String, Int64)] = [("0", 0), ("0.01", 1), ("0.10", 10), ("3.49", 349), (" 003.40 ", 340)]
        for (literal, cents) in cases {
            XCTAssertEqual(try ComparisonModel.money(literal), Money(minorUnits: cents), literal)
        }
        for literal in ["0.001", "3.499", "1.000", "1.230", "0.000000"] {
            XCTAssertThrowsError(try ComparisonModel.money(literal), literal)
        }
        XCTAssertNil(try ComparisonModel.money("  "))
    }

    func testIngredientConversionKeepsReviewedLiteralsAndUsesAnExactPositiveRatio() throws {
        for (source, target, expected) in [
            (" 1/3 ", "20.00", try Rational(60)),
            ("1 1/2", "0.1250", try Rational(1, 12)),
            ("½", "0.000001", try Rational(1, 500_000))
        ] {
            let conversion = ComparisonConversion(sourceLiteral: source, targetLiteral: target,
                sourceUnit: .cup, targetUnit: .gram, sourceNote: "Measured this flour")
            let basis = try conversion.unitBasis()
            XCTAssertEqual(basis.sourceUnit, .cup)
            XCTAssertEqual(basis.targetUnit, .gram)
            XCTAssertEqual(basis.targetAmountPerSourceUnit, expected)
            XCTAssertEqual(basis.sourceLiteral, source)
            XCTAssertEqual(basis.targetLiteral, target)
            XCTAssertEqual(basis.sourceNote, "Measured this flour")
            XCTAssertEqual(try JSONDecoder().decode(ComparisonConversion.self, from: JSONEncoder().encode(conversion)), conversion)
        }
        let oversized = "1" + String(repeating: " ", count: StagedListImport.maximumOriginalLineBytes)
        for invalid in ["", "0", "0/1", "-1", "1/0", "1,25", "1 cup", "1e3", "0.0000001", oversized] {
            for (source, target) in [(invalid, "1"), ("1", invalid)] {
                let conversion = ComparisonConversion(sourceLiteral: source, targetLiteral: target,
                    sourceUnit: .cup, targetUnit: .gram)
                XCTAssertThrowsError(try conversion.unitBasis(), invalid)
            }
        }
        XCTAssertThrowsError(try ComparisonConversion(sourceLiteral: "1", targetLiteral: "1000",
            sourceUnit: .kilogram, targetUnit: .gram).unitBasis(), "Defined same-dimension conversions do not need an ingredient basis")
        XCTAssertThrowsError(try ComparisonConversion(sourceLiteral: "1", targetLiteral: "120",
            sourceUnit: .cup, targetUnit: .gram, sourceNote: String(repeating: "a", count: 2_049)).unitBasis())
    }

    @MainActor
    func testConfirmedConversionResolvesOnlyItsOwnOfferAndKeepsUnknownsVisible() throws {
        let draft = makeConversionDraft()
        var withoutSecondBasis = draft
        withoutSecondBasis.bConversion = nil
        let one = ComparisonModel(draft: withoutSecondBasis)
        let oneRequest = try one.request()
        XCTAssertEqual(oneRequest.offerA.confirmedConversion, try draft.aConversion?.unitBasis())
        XCTAssertNil(oneRequest.offerB.confirmedConversion)
        one.compare()
        let partial = try XCTUnwrap(one.result)
        XCTAssertEqual(partial.offerA.packsToBuy, 2)
        XCTAssertEqual(partial.offerA.totalCost, Money(minorUnits: 698))
        XCTAssertTrue(partial.offerB.issues.contains(.usableConversionUnknown))
        XCTAssertNil(partial.offerB.totalCost)
        XCTAssertNil(partial.preferredOfferID)

        let both = ComparisonModel(draft: draft)
        both.compare()
        let resolved = try XCTUnwrap(both.result)
        XCTAssertTrue(resolved.offerA.isResolved)
        XCTAssertTrue(resolved.offerB.isResolved)
        XCTAssertEqual(resolved.offerB.packsToBuy, 2)
        XCTAssertEqual(resolved.offerB.totalCost, Money(minorUnits: 600))
        XCTAssertEqual(resolved.preferredOfferID, "b")
        XCTAssertEqual(try both.request().offerB.confirmedConversion?.targetAmountPerSourceUnit, try Rational(80))
    }

    @MainActor
    func testConversionScopeEditsInvalidatePermanentlyAndOtherOfferEditsDoNot() throws {
        let original = makeConversionDraft()
        let changes: [(String, (inout ComparisonDraft) -> Void, (inout ComparisonDraft) -> Void, Bool, Bool)] = [
            ("item", { $0.item = "Another ingredient" }, { $0.item = original.item }, true, true),
            ("needed unit", { $0.unit = .kilogram }, { $0.unit = original.unit }, true, true),
            ("A label", { $0.aLabel = "Another pack" }, { $0.aLabel = original.aLabel }, true, false),
            ("A unit", { $0.aUnit = .milliliter }, { $0.aUnit = original.aUnit }, true, false),
            ("B label", { $0.bLabel = "Another pack" }, { $0.bLabel = original.bLabel }, false, true),
            ("B unit", { $0.bUnit = .milliliter }, { $0.bUnit = original.bUnit }, false, true)
        ]
        for (label, change, restore, clearsA, clearsB) in changes {
            var draft = original
            change(&draft)
            XCTAssertEqual(draft.aConversion == nil, clearsA, label)
            XCTAssertEqual(draft.bConversion == nil, clearsB, label)
            restore(&draft)
            XCTAssertEqual(draft.aConversion == nil, clearsA, label + " after switching back")
            XCTAssertEqual(draft.bConversion == nil, clearsB, label + " after switching back")

            let model = ComparisonModel(draft: original)
            model.compare()
            model.savedAt = Date()
            change(&model.draft)
            XCTAssertEqual(model.draft.aConversion == nil, clearsA, label + " model edit")
            XCTAssertEqual(model.draft.bConversion == nil, clearsB, label + " model edit")
            XCTAssertNil(model.result)
            XCTAssertNil(model.savedAt)
            restore(&model.draft)
            XCTAssertEqual(model.draft.aConversion == nil, clearsA, label + " model edit after switching back")
            XCTAssertEqual(model.draft.bConversion == nil, clearsB, label + " model edit after switching back")
        }
        var unchangedScope = original
        unchangedScope.item = original.item; unchangedScope.unit = original.unit
        unchangedScope.aLabel = original.aLabel; unchangedScope.aUnit = original.aUnit
        unchangedScope.bLabel = original.bLabel; unchangedScope.bUnit = original.bUnit
        unchangedScope.needed = "240"; unchangedScope.stock = "10"; unchangedScope.protected = "5"
        unchangedScope.aQuantity = "2"; unchangedScope.aPrice = "4.00"
        unchangedScope.bQuantity = "3"; unchangedScope.bPrice = "5.00"; unchangedScope.cap = "12.00"
        XCTAssertEqual(unchangedScope.aConversion, original.aConversion)
        XCTAssertEqual(unchangedScope.bConversion, original.bConversion)
        XCTAssertNoThrow(try ComparisonModel(draft: unchangedScope).request())
        let model = ComparisonModel(draft: original)
        model.compare()
        model.savedAt = Date()
        var otherRecord = makeConversionDraft()
        otherRecord.item = "Another flour"
        otherRecord.aConversion = original.aConversion
        otherRecord.bConversion = original.bConversion
        model.draft = otherRecord
        XCTAssertEqual(model.draft, otherRecord, "Opening an independently confirmed saved draft retains its own basis")
        XCTAssertNil(model.result)
        XCTAssertNil(model.savedAt)
    }

    @MainActor
    func testEditingWhileComparisonSaveIsPendingKeepsNewInputAndFeedback() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.sqlite")
        let store = try ComparisonStore(url: url)
        var writer: OpaquePointer?
        XCTAssertEqual(sqlite3_open(url.path, &writer), SQLITE_OK)
        defer { sqlite3_close(writer) }
        XCTAssertEqual(sqlite3_exec(writer, "BEGIN IMMEDIATE", nil, nil, nil), SQLITE_OK)

        let original = makeDraft(unknownSecondYield: false)
        let started = expectation(description: "Captured the reviewed draft for persistence")
        var firstSave = true
        let model = ComparisonModel(draft: original, clock: {
            if firstSave { firstSave = false; started.fulfill() }
            return Date()
        })
        let save = Task { await model.save(in: store) }
        await fulfillment(of: [started], timeout: 3)
        XCTAssertTrue(model.saving)
        model.draft.aPrice = "4."
        model.compare()
        let feedback = try XCTUnwrap(model.error)
        XCTAssertEqual(sqlite3_exec(writer, "COMMIT", nil, nil, nil), SQLITE_OK)
        await save.value

        XCTAssertEqual(model.draft.aPrice, "4.")
        XCTAssertEqual(model.error, feedback)
        XCTAssertNil(model.savedAt)
        let firstRecord = try await store.load(id: original.id)
        let saved = try XCTUnwrap(firstRecord)
        XCTAssertEqual(try JSONDecoder().decode(SavedPayload.self, from: saved.payload).draft, original)

        model.draft.aPrice = "4.95"
        model.compare()
        await model.save(in: store)
        XCTAssertNil(model.error)
        XCTAssertNotNil(model.savedAt)
        let secondRecord = try await store.load(id: original.id)
        let updated = try XCTUnwrap(secondRecord)
        XCTAssertEqual(updated.revision, saved.revision + 1)
        XCTAssertEqual(try JSONDecoder().decode(SavedPayload.self, from: updated.payload).draft, model.draft)
    }

    @MainActor
    func testEditingTwoCopiesOfAComparisonPreservesTheNewerSavedPrice() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComparisonStore(url: directory.appendingPathComponent("local.sqlite"))
        let draft = makeDraft(unknownSecondYield: false)
        let first = ComparisonModel(draft: draft)
        let other = ComparisonModel(draft: draft)
        await first.save(in: store)
        await other.save(in: store)
        XCTAssertNil(other.error)

        first.draft.aPrice = "5.25"
        await first.save(in: store)
        XCTAssertNil(first.error)
        other.draft.bPrice = "6.75"
        await other.save(in: store)
        XCTAssertEqual(other.error, tr("This saved comparison changed. Reopen it to review the latest prices before saving your edits."))
        XCTAssertNil(other.savedAt)
        XCTAssertEqual(other.draft.bPrice, "6.75")
        let loaded = try await store.load(id: draft.id)
        let saved = try XCTUnwrap(loaded)
        XCTAssertEqual(saved.revision, 2)
        let latestDraft = try JSONDecoder().decode(SavedPayload.self, from: saved.payload).draft
        XCTAssertEqual(latestDraft, first.draft)
        let reopened = ComparisonModel(draft: latestDraft, savedRevision: saved.revision)
        reopened.draft.bPrice = other.draft.bPrice
        await reopened.save(in: store)
        XCTAssertNil(reopened.error)
        let updated = try await store.load(id: draft.id)
        XCTAssertEqual(updated?.revision, 3)
        let newRecord = try XCTUnwrap(updated)
        XCTAssertEqual(try JSONDecoder().decode(SavedPayload.self, from: newRecord.payload).draft, reopened.draft)
        try await store.close()
    }

    @MainActor
    func testConfirmedConversionSaveReopenKeepsOriginalBasisAndAnUnchangedRetry() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("local.sqlite")
        let store = try ComparisonStore(url: url)
        let original = makeConversionDraft()
        let model = ComparisonModel(draft: original, clock: { Date(timeIntervalSince1970: 1_700_000_000) })
        model.compare()
        let result = try XCTUnwrap(model.result)
        await model.save(in: store)
        XCTAssertNil(model.error)
        let loaded = try await store.load(id: original.id)
        let saved = try XCTUnwrap(loaded)
        let payload = try JSONDecoder().decode(SavedPayload.self, from: saved.payload)
        XCTAssertEqual(payload.draft, original)
        XCTAssertEqual(payload.normalizedRequest?.offerA.confirmedConversion, try original.aConversion?.unitBasis())
        XCTAssertEqual(payload.normalizedRequest?.offerB.confirmedConversion, try original.bConversion?.unitBasis())
        XCTAssertEqual(payload.answer, result)
        try await store.close()

        let app = AppModel(databaseURL: url)
        await app.open()
        let reopened = try XCTUnwrap(app.records.first)
        let restored = ComparisonModel(draft: try app.decode(reopened), savedRevision: reopened.revision, clock: { Date(timeIntervalSince1970: 1_800_000_000) })
        XCTAssertEqual(restored.draft, original)
        restored.compare()
        XCTAssertEqual(restored.result, result)
        await restored.save(in: app.store)
        await app.refresh()
        XCTAssertEqual(app.records, [saved])
        try await app.store?.close()
    }

    @MainActor
    func testMalformedSavedConversionRejectsWithoutDeletingItsOriginalBytes() async throws {
        let original = makeConversionDraft()
        var wrongSource = original; wrongSource.aConversion?.sourceUnit = .count
        var wrongTarget = original; wrongTarget.aConversion?.targetUnit = .kilogram
        var zero = original; zero.bConversion?.targetLiteral = "0"
        var invalid = original; invalid.aConversion?.sourceLiteral = "NaN"
        var oversized = original; oversized.bConversion?.sourceNote = String(repeating: "x", count: 2_049)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(databaseURL: directory.appendingPathComponent("local.sqlite"))
        await app.open()
        let store = try XCTUnwrap(app.store)
        for var draft in [wrongSource, wrongTarget, zero, invalid, oversized] {
            draft.id = UUID()
            // Legacy draft-only payloads have no normalized snapshot to catch a
            // malformed conversion: the draft itself must validate its basis.
            let bytes = try JSONEncoder().encode(SavedPayload(draft: draft))
            let saved = try await store.save(id: draft.id, title: draft.item, payload: bytes, savedAt: Date())
            XCTAssertThrowsError(try app.decode(saved))
            XCTAssertThrowsError(try RecordsNativeCodec.comparison(bytes))
            let retained = try await store.load(id: draft.id)
            XCTAssertEqual(retained, saved)
        }
        try await store.close()
    }

    @MainActor
    func testOwnerConversionTextKeepsReviewedEqualityAndHelperProjectionOmitsIt() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let draft = makeConversionDraft()
        let request = try ComparisonModel(draft: draft).request()
        let payload = SavedPayload(draft: draft, calculationVersion: SavedPayload.currentCalculationVersion,
            normalizedRequest: request, answer: try PackComparison.evaluate(request), roundingPolicy: SavedPayload.currentRoundingPolicy)
        let bytes = try RecordsNativeCodec.canonical(payload)
        let record = ArchiveRecord(id: draft.id.uuidString, origin: "comparisons/" + UUID().uuidString,
            revision: ArchiveCodec.digest(bytes), kind: .comparison, title: draft.item, savedAtMilliseconds: 1_700_000_000_000,
            helperLines: [HelperLine(label: draft.item, originalAmount: draft.needed, originalUnit: draft.unit.rawValue)], nativePayload: bytes)
        let registry = try RecoveryRegistry(url: directory.appendingPathComponent("registry.json"))
        let model = RecordsToolsModel(registry: registry, snapshot: { .init(records: [record]) },
            validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        await model.refresh()
        model.selectAll()
        await model.prepareExport(.ownerText)
        let owner = String(decoding: try XCTUnwrap(model.preparedDocument).data, as: UTF8.self)
        for conversion in [try XCTUnwrap(draft.aConversion), try XCTUnwrap(draft.bConversion)] {
            XCTAssertTrue(owner.contains(conversion.readableText()))
            XCTAssertEqual(ComparisonConversion.readableText(for: try conversion.unitBasis()), conversion.readableText())
        }
        let oldBasis = UnitBasis(sourceUnit: .cup, targetUnit: .gram,
            targetAmountPerSourceUnit: try Rational(60), sourceNote: "Old measured basis")
        XCTAssertEqual(ComparisonConversion.readableText(for: oldBasis), ComparisonConversion(sourceLiteral: "1", targetLiteral: "60",
            sourceUnit: .cup, targetUnit: .gram, sourceNote: "Old measured basis").readableText())
        await model.prepareExport(.helperText)
        let helper = String(decoding: try XCTUnwrap(model.preparedDocument).data, as: UTF8.self)
        XCTAssertTrue(helper.contains(draft.item))
        for privateValue in ["1/3", "20.00", "0.5000", "40.000", "Measured flour A", "Package B equality", "confirmedConversion", "sourceLiteral"] {
            XCTAssertFalse(helper.contains(privateValue), privateValue)
        }
    }

    @MainActor
    func testComparisonAmountLabelsKeepSingularUnitsAndDistinguishWeightFromVolume() throws {
        let cases: [(UnitOfMeasure, String)] = [
            (.count, tr("item")), (.ounce, tr("ounce (weight)")),
            (.cup, tr("US cup")), (.fluidOunce, tr("US fluid ounce")),
            (.gram, pTr("gram")), (.kilogram, pTr("kilogram")), (.pound, pTr("pound")),
            (.milliliter, pTr("milliliter")), (.liter, pTr("liter"))
        ]
        for (unit, singular) in cases {
            XCTAssertEqual(unit.comparisonLabel(for: try Rational(decimal: "1.00")), singular)
            XCTAssertEqual(unit.comparisonLabel(for: .zero), unit.displayName)
            XCTAssertEqual(unit.comparisonLabel(for: try Rational(2)), unit.displayName)
        }
    }

    @MainActor
    func testKnownComparisonSaveCloseReopenRecomputesIdenticalAnswer() async throws {
        try await assertSaveReopen(unknownSecondYield: false)
    }

    @MainActor
    func testUnknownComparisonSaveCloseReopenStaysUnresolved() async throws {
        try await assertSaveReopen(unknownSecondYield: true)
    }

    @MainActor
    func testInvalidEditClearsPreviousAnswer() {
        let model = ComparisonModel(draft: makeDraft(unknownSecondYield: false))
        model.compare()
        XCTAssertNotNil(model.result)
        model.draft.needed = "twelve"
        model.compare()
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.result, "A prior answer cannot describe a draft whose current quantity is invalid")
    }

    @MainActor
    func testFailedSaveRetainsDraftAndComputedResult() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = try ComparisonStore(url: directory.appendingPathComponent("local.sqlite"))
        try await store.close()
        let original = makeDraft(unknownSecondYield: true)
        let model = ComparisonModel(draft: original)
        model.compare()
        let result = model.result

        await model.save(in: store)

        XCTAssertEqual(model.draft, original)
        XCTAssertEqual(model.result, result)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.savedAt)
        XCTAssertFalse(model.saving)
    }

    @MainActor
    func testUnavailableStoreLeavesEditableDraftIntact() async {
        let original = makeDraft(unknownSecondYield: false)
        let model = ComparisonModel(draft: original)
        await model.save(in: nil)
        XCTAssertEqual(model.draft, original)
        XCTAssertNotNil(model.error)
        XCTAssertNil(model.savedAt)
        XCTAssertFalse(model.saving)
    }

    @MainActor
    func testSavedPayloadRejectsFutureFormatAndDifferentRecordIdentity() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(databaseURL: directory.appendingPathComponent("local.sqlite"))
        await app.open()
        let store = try XCTUnwrap(app.store)
        let draft = makeDraft(unknownSecondYield: false)
        let future = SavedPayload(formatVersion: 2, draft: draft)
        let futureRecord = try await store.save(id: draft.id, title: draft.item,
                                               payload: JSONEncoder().encode(future), savedAt: Date())
        XCTAssertThrowsError(try app.decode(futureRecord))
        let mismatch = try await store.save(id: UUID(), title: draft.item,
                                           payload: JSONEncoder().encode(SavedPayload(draft: draft)), savedAt: Date())
        XCTAssertThrowsError(try app.decode(mismatch))
        try await store.close()
    }

    @MainActor
    func testLegacyDraftOnlyV1RemainsReadableWithoutRewritingRecord() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("local.sqlite")
        let store = try ComparisonStore(url: databaseURL)
        let draft = makeDraft(unknownSecondYield: true)
        // This fixture encodes only the two original v1 keys, rather than relying on
        // the current SavedPayload encoder to keep omitting new optional properties.
        struct LegacyPayload: Encodable {
            let formatVersion: Int
            let draft: ComparisonDraft
        }
        let bytes = try JSONEncoder().encode(LegacyPayload(formatVersion: 1, draft: draft))
        let legacyDraft = try XCTUnwrap((JSONSerialization.jsonObject(with: bytes) as? [String: Any])?["draft"] as? [String: Any])
        XCTAssertNil(legacyDraft["aConversion"])
        XCTAssertNil(legacyDraft["bConversion"])
        let saved = try await store.save(id: draft.id, title: draft.item, payload: bytes,
                                         savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        try await store.close()

        let app = AppModel(databaseURL: databaseURL)
        await app.open()
        XCTAssertTrue(app.ready)
        let record = try XCTUnwrap(app.records.first)
        XCTAssertEqual(try app.decode(record), draft)
        XCTAssertNil(try app.decode(record).aConversion)
        XCTAssertNil(try app.decode(record).bConversion)
        let readPayload = try JSONDecoder().decode(SavedPayload.self, from: record.payload)
        XCTAssertNil(readPayload.calculationVersion)
        XCTAssertNil(readPayload.normalizedRequest)
        XCTAssertNil(readPayload.answer)
        XCTAssertNil(readPayload.roundingPolicy)
        XCTAssertEqual(record, saved)
        let reopenedStore = try XCTUnwrap(app.store)
        let retained = try await reopenedStore.load(id: draft.id)
        XCTAssertEqual(retained, saved)
        try await reopenedStore.close()
    }

    @MainActor
    func testUnsupportedCalculationVersionIsRejectedWithoutMutation() async throws {
        try await assertRejectedSnapshotRetained { payload in
            payload.calculationVersion = "pack-future/unknown-unit-table"
        }
    }

    @MainActor
    func testAnswerFromDifferentPriceIsRejectedWithoutDeletion() async throws {
        try await assertRejectedSnapshotRetained { payload in
            var changed = payload.draft
            changed.aPrice = "9.99"
            payload.answer = try PackComparison.evaluate(ComparisonModel(draft: changed).request())
        }
    }

    @MainActor
    func testSnapshotDraftMismatchIsRejectedWithoutDeletion() async throws {
        try await assertRejectedSnapshotRetained { payload in
            payload.draft.needed = "24"
        }
    }

    @MainActor
    func testNormalizedRequestMismatchIsRejectedWithoutDeletion() async throws {
        try await assertRejectedSnapshotRetained { payload in
            var changed = payload.draft
            changed.aPrice = "9.99"
            payload.normalizedRequest = try ComparisonModel(draft: changed).request()
        }
    }

    @MainActor
    private func assertRejectedSnapshotRetained(_ change: (inout SavedPayload) throws -> Void) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let app = AppModel(databaseURL: directory.appendingPathComponent("local.sqlite"))
        await app.open()
        let store = try XCTUnwrap(app.store)
        let draft = makeDraft(unknownSecondYield: false)
        let request = try ComparisonModel(draft: draft).request()
        var payload = SavedPayload(draft: draft,
                                   calculationVersion: SavedPayload.currentCalculationVersion,
                                   normalizedRequest: request,
                                   answer: try PackComparison.evaluate(request),
                                   roundingPolicy: "whole-packs-ceiling; USD-cents-exact; per-pack-ceiling-floor")
        try change(&payload)
        let saved = try await store.save(id: draft.id, title: draft.item,
                                         payload: JSONEncoder().encode(payload),
                                         savedAt: Date(timeIntervalSince1970: 1_700_000_000))
        let before = try await store.list()
        XCTAssertThrowsError(try app.decode(saved))
        await app.refresh()
        XCTAssertEqual(app.records, before)
        let retained = try await store.load(id: draft.id)
        XCTAssertEqual(retained, saved)
        try await store.close()
    }

    @MainActor
    private func assertSaveReopen(unknownSecondYield: Bool) async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let databaseURL = directory.appendingPathComponent("local.sqlite")
        let app = AppModel(databaseURL: databaseURL)
        await app.open()
        XCTAssertTrue(app.ready)
        XCTAssertNil(app.error)
        let store = try XCTUnwrap(app.store)
        let workspace = store.workspaceID
        let draft = makeDraft(unknownSecondYield: unknownSecondYield)
        let fixedTime = Date(timeIntervalSince1970: 1_700_000_000)
        let model = ComparisonModel(draft: draft, clock: { fixedTime })
        model.compare()
        XCTAssertNil(model.error)
        let originalResult = try XCTUnwrap(model.result)
        XCTAssertEqual(originalResult.scope, .itemOnly)
        XCTAssertEqual(originalResult.offerA.packsToBuy, 2)
        XCTAssertEqual(originalResult.offerA.totalCost, Money(minorUnits: 698))
        if unknownSecondYield {
            XCTAssertTrue(originalResult.offerB.issues.contains(.usableQuantityUnknown))
            XCTAssertNil(originalResult.offerB.packsToBuy)
            XCTAssertNil(originalResult.offerB.totalCost)
            XCTAssertNil(originalResult.preferredOfferID)
        } else {
            XCTAssertTrue(originalResult.offerA.isResolved)
            XCTAssertTrue(originalResult.offerB.isResolved)
            XCTAssertEqual(originalResult.preferredOfferID, "b")
        }

        await model.save(in: store)
        XCTAssertNil(model.error)
        XCTAssertEqual(model.savedAt, fixedTime)
        XCTAssertFalse(model.saving)
        XCTAssertEqual(model.draft, draft)
        await app.refresh()
        XCTAssertEqual(app.records.count, 1)
        let record = try XCTUnwrap(app.records.first)
        XCTAssertEqual(record.id, draft.id)
        XCTAssertEqual(record.savedAt, fixedTime)
        XCTAssertEqual(record.revision, 1)
        let payload = try JSONDecoder().decode(SavedPayload.self, from: record.payload)
        XCTAssertEqual(payload.formatVersion, 1)
        XCTAssertEqual(payload.draft, draft)
        XCTAssertEqual(payload.calculationVersion, SavedPayload.currentCalculationVersion)
        XCTAssertEqual(payload.roundingPolicy, "whole-packs-ceiling; USD-cents-exact; per-pack-ceiling-floor")
        XCTAssertEqual(payload.answer, originalResult)
        let normalized = try XCTUnwrap(payload.normalizedRequest)
        XCTAssertEqual(normalized, try model.request())
        XCTAssertEqual(normalized.needed?.amount, try Rational(12))
        XCTAssertEqual(normalized.needed?.originalLiteral, " 12.000 ")
        XCTAssertEqual(normalized.confirmedAtHome?.amount, .zero)
        XCTAssertEqual(normalized.protectedAmount?.amount, try Rational(2))
        XCTAssertEqual(normalized.offerA.usableQuantity?.amount, try Rational(8))
        XCTAssertEqual(normalized.offerA.price?.minorUnits, 349)
        XCTAssertEqual(normalized.offerB.price?.minorUnits, 450)
        XCTAssertEqual(normalized.itemCap?.minorUnits, 3_000)
        if unknownSecondYield { XCTAssertNil(normalized.offerB.usableQuantity) }
        else { XCTAssertEqual(normalized.offerB.usableQuantity?.amount, try Rational(12)) }
        try await store.close()

        let reopened = AppModel(databaseURL: databaseURL)
        await reopened.open()
        XCTAssertTrue(reopened.ready)
        XCTAssertNil(reopened.error)
        XCTAssertEqual(reopened.store?.workspaceID, workspace)
        XCTAssertEqual(reopened.records, [record])
        let restoredDraft = try reopened.decode(XCTUnwrap(reopened.records.first))
        XCTAssertEqual(restoredDraft, draft)
        let restored = ComparisonModel(draft: restoredDraft, savedRevision: record.revision, clock: { fixedTime.addingTimeInterval(30) })
        restored.compare()
        XCTAssertNil(restored.error)
        XCTAssertEqual(restored.result, originalResult)
        await restored.save(in: reopened.store)
        await reopened.refresh()
        XCTAssertEqual(reopened.records, [record], "An unchanged retry must preserve its original evidence time and revision")
        let reopenedStore = try XCTUnwrap(reopened.store)
        try await reopenedStore.close()
    }

    private func makeDraft(unknownSecondYield: Bool) -> ComparisonDraft {
        var draft = ComparisonDraft()
        draft.item = "Tortillas — family wraps"
        draft.needed = " 12.000 "
        draft.stock = "00.00"
        draft.protected = "2.0"
        draft.cap = "30.00"
        draft.aLabel = "Eight usable wraps"
        draft.aQuantity = "08.000"
        draft.aPrice = "3.49"
        draft.bLabel = "Twelve-wrap option"
        draft.bQuantity = unknownSecondYield ? "" : "12.00"
        draft.bPrice = "04.50"
        return draft
    }

    private func makeConversionDraft() -> ComparisonDraft {
        var draft = ComparisonDraft()
        draft.item = "Flour"
        draft.needed = "120"
        draft.unit = .gram
        draft.aLabel = "Flour A"
        draft.aQuantity = "1"
        draft.aUnit = .cup
        draft.aPrice = "3.49"
        draft.bLabel = "Flour B"
        draft.bQuantity = "1"
        draft.bUnit = .cup
        draft.bPrice = "3.00"
        draft.aConversion = ComparisonConversion(sourceLiteral: "1/3", targetLiteral: "20.00",
            sourceUnit: .cup, targetUnit: .gram, sourceNote: "Measured flour A")
        draft.bConversion = ComparisonConversion(sourceLiteral: "0.5000", targetLiteral: "40.000",
            sourceUnit: .cup, targetUnit: .gram, sourceNote: "Package B equality")
        return draft
    }

    private func temporaryDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("AppModelTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }
}
