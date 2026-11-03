import XCTest
import CoreDomain
@testable import RoomInTheCart

final class StructuredCaptureTests: XCTestCase {
    private let destination = "Saturday pickup"
    func testEnglishAndSpanishQuantitiesRemainExact() throws {
        let english = try row("half kg rice for dinner to this pickup")
        let spanish = try row("medio kg arroz para la cena destino esta compra")
        XCTAssertEqual(english.amount, "1/2"); XCTAssertEqual(spanish.amount, "1/2")
        XCTAssertEqual(english.unit, .kilogram); XCTAssertEqual(spanish.unit, .kilogram)
        XCTAssertEqual(english.name, "rice"); XCTAssertEqual(spanish.name, "arroz")
        XCTAssertEqual(spanish.purpose, "la cena"); XCTAssertEqual(spanish.destination, destination)
    }
    func testPackEvidenceCommitsTogetherWithExclusionsAndOriginal() throws {
        let original = "two packs of six wraps for tacos without peanuts to this pickup"
        var draft = try row(original); draft.confirmed = true
        XCTAssertEqual(draft.packCount, "2"); XCTAssertEqual(draft.amountPerPack, "6")
        XCTAssertEqual(draft.exclusions, "peanuts"); XCTAssertEqual(draft.destination, destination)
        let value = try XCTUnwrap(draft.reviewed(expectedDestination: destination))
        var shop = ShoppingLedger()
        let operationID = UUID()
        let preview = try shop.stageCaptureImport(id: operationID, originalText: original, source: .voice, lines: [value])
        XCTAssertEqual(preview.lines.first?.quantity?.amount, try Rational(12))
        let receipt = try shop.commitImport(preview)
        XCTAssertEqual(try shop.commitImport(preview), receipt)
        XCTAssertEqual(shop.importBatches.count, 1)
        XCTAssertEqual(shop.contributions.first?.exclusions, ["peanuts"])
        XCTAssertEqual(shop.contributions.first?.capture?.purpose, "tacos")
        XCTAssertEqual(shop.importBatches.first?.originalText, original)
    }
    func testSpanishPackParsingAndSuffixOrder() throws {
        let draft = try row("dos paquetes de seis tortillas destino esta compra para tacos sin maní")
        XCTAssertEqual(draft.name, "tortillas"); XCTAssertEqual(draft.packCount, "2")
        XCTAssertEqual(draft.amountPerPack, "6"); XCTAssertEqual(draft.purpose, "tacos")
        XCTAssertEqual(draft.exclusions, "maní"); XCTAssertTrue(draft.warnings.contains(.negation))
    }
    func testUnknownMeasureAndAmbiguousCommaNeverBecomeKnownCount() throws {
        let unknown = try row("2 handfuls almonds")
        XCTAssertEqual(unknown.amount, ""); XCTAssertTrue(unknown.warnings.contains(.ambiguous))
        let comma = try row("1,000 tortillas")
        XCTAssertEqual(comma.amount, ""); XCTAssertEqual(comma.name, "1,000 tortillas")
        XCTAssertThrowsError(try CaptureNumber.parse("1,000"))
    }
    func testPackWithoutUsableAmountStaysUnknown() throws {
        var draft = try row("2 packs milk"); draft.confirmed = true
        let value = try XCTUnwrap(draft.reviewed(expectedDestination: destination))
        let preview = try ShoppingLedger().stageCaptureImport(id: UUID(), originalText: draft.originalText, source: .voice, lines: [value])
        XCTAssertNil(preview.lines.first?.quantity)
        XCTAssertTrue(value.unresolvedFields.contains(.amountPerPack))
    }
    func testMassAndFluidOuncesAreNotInterchanged() throws {
        XCTAssertEqual(try row("2 oz almonds").unit, .ounce)
        XCTAssertEqual(try row("2 fl oz milk").unit, .fluidOunce)
        XCTAssertEqual(try row("2 onzas líquidas leche").unit, .fluidOunce)
    }
    func testMaterialEditInvalidatesConfirmationAndPreservesIdentity() throws {
        var draft = try row("3 apples")
        let originalID = draft.id, lineID = draft.proposedLineID
        draft.confirmed = true; draft.name = "green apples"
        XCTAssertFalse(draft.confirmed)
        XCTAssertThrowsError(try draft.reviewed(expectedDestination: destination))
        XCTAssertEqual(draft.id, originalID); XCTAssertEqual(draft.proposedLineID, lineID)
        XCTAssertEqual(draft.originalText, "3 apples")
    }
    func testDestinationMustBeExplicitlyTheHostDestination() throws {
        var draft = try row("2 apples to next shop"); draft.confirmed = true
        XCTAssertThrowsError(try draft.reviewed(expectedDestination: destination))
        draft.destination = destination; draft.confirmed = true
        XCTAssertEqual(try draft.reviewed(expectedDestination: destination)?.destination, destination)
    }
    func testNegationIsVisibleAndNeverDeletesOrSilentlyBecomesQuantity() throws {
        let draft = try row("no milk")
        XCTAssertEqual(draft.name, "no milk"); XCTAssertEqual(draft.amount, "")
        XCTAssertTrue(draft.warnings.contains(.negation)); XCTAssertFalse(draft.confirmed)
        XCTAssertThrowsError(try draft.reviewed(expectedDestination: destination))
    }
    func testGuestWordingCannotImplicitlyBecomeAList() throws {
        XCTAssertThrowsError(try StructuredCaptureParser.lines("one more guest", destination: destination))
        XCTAssertEqual(try StructuredCaptureParser.lines("2 kg rice for guests", destination: destination, explicitlyTreatAsItems: true).first?.name, "rice")
        XCTAssertEqual(try CaptureGuestParser.proposal("one more guest")?.proposedTotal(current: Rational(4)), try Rational(5))
        XCTAssertEqual(CaptureGuestParser.proposal("dos invitados más")?.amount, try Rational(2))
        XCTAssertNil(CaptureGuestParser.proposal("no more guests"))
        XCTAssertNil(CaptureGuestParser.proposal("two guests and three lunches"))
    }
    func testConflictingTotalAndPackEvidenceFailsAtomically() throws {
        var draft = try row("2 packs of 6 wraps")
        draft.amount = "10"; draft.confirmed = true
        XCTAssertThrowsError(try draft.reviewed(expectedDestination: destination))
        XCTAssertEqual(draft.originalText, "2 packs of 6 wraps")
    }
    func testRepeatedCaptureCallbackKeepsOneReceiptAndChangedBodyFails() throws {
        var draft = try row("2 apples"); draft.confirmed = true
        let line = try XCTUnwrap(draft.reviewed(expectedDestination: destination))
        var capture = ReviewedCapture(id: UUID(), text: "2 apples", originalText: "2 apples", source: .speech,
            localeIdentifier: "en-US", sourceImageData: nil, lines: [line])
        var shop = ShoppingLedger()
        let first = try CaptureLedgerImport.stage(capture, in: shop)
        XCTAssertFalse(first.alreadyApplied)
        try shop.commitImport(first.preview)
        let replay = try CaptureLedgerImport.stage(capture, in: shop)
        XCTAssertTrue(replay.alreadyApplied); XCTAssertEqual(replay.preview, first.preview)
        XCTAssertEqual(shop.importBatches.count, 1)
        capture.lines?[0].name = "pears"
        XCTAssertThrowsError(try CaptureLedgerImport.stage(capture, in: shop))
    }
    func testUndoneCaptureCannotBeResubmittedByOldCallback() throws {
        var draft = try row("2 apples"); draft.confirmed = true
        let line = try XCTUnwrap(draft.reviewed(expectedDestination: destination))
        let capture = ReviewedCapture(id: UUID(), text: "2 apples", originalText: "2 apples", source: .typed,
            localeIdentifier: "en-US", sourceImageData: nil, lines: [line])
        var shop = ShoppingLedger()
        let preview = try CaptureLedgerImport.stage(capture, in: shop).preview
        let batch = try shop.commitImport(preview)
        try shop.undoImport(batchID: batch)
        XCTAssertThrowsError(try CaptureLedgerImport.stage(capture, in: shop))
    }
    func testCaptureBoundsRejectOversizedInput() {
        XCTAssertThrowsError(try StructuredCaptureParser.lines(String(repeating:"rice\n",count:201),destination:destination))
    }
    private func row(_ text:String) throws -> CaptureLineDraft { try XCTUnwrap(StructuredCaptureParser.lines(text,destination:destination).first) }
}

@MainActor final class CaptureCorrectionTests: XCTestCase {
    private func location() -> URL { FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString) }
    private let english = CaptureCorrectionScope(profileID:"local:test-a",localeIdentifier:"en-US")
    func testNoOptInMeansNoCorrectionWrites() async throws {
        let directory=location(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=CaptureCorrectionStore(directory:directory)
        let initial=try await store.load(english)
        XCTAssertFalse(initial.enabled); XCTAssertTrue(initial.entries.isEmpty)
        do { try await store.remember(original:"tortiyas",replacement:"tortillas",scope:english); XCTFail("Opt-in required") } catch {}
        XCTAssertFalse(FileManager.default.fileExists(atPath:directory.path))
    }
    func testExplicitRememberPreviewForgetAndOptOut() async throws {
        let directory=location(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=CaptureCorrectionStore(directory:directory)
        let model=CaptureCorrectionsModel(store:store)
        await model.bind(english); await model.setEnabled(true)
        await model.remember(original:"tortiyas",replacement:"tortillas")
        XCTAssertEqual(model.suggestion(for:"TORTIYAS")?.replacement,"tortillas")
        XCTAssertNil(model.suggestion(for:"tortiya"))
        let id=try XCTUnwrap(model.snapshot.entries.first?.id)
        await model.forget(id); XCTAssertNil(model.suggestion(for:"tortiyas"))
        await model.remember(original:"tortiyas",replacement:"tortillas")
        await model.setEnabled(false)
        XCTAssertFalse(model.snapshot.enabled); XCTAssertTrue(model.snapshot.entries.isEmpty)
        let reloaded=try await store.load(english); XCTAssertTrue(reloaded.entries.isEmpty)
    }
    func testProfileAndLocaleIsolationAndInvalidation() async throws {
        let directory=location(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=CaptureCorrectionStore(directory:directory)
        try await store.setEnabled(true,scope:english)
        try await store.remember(original:"tortiyas",replacement:"tortillas",scope:english)
        let model=CaptureCorrectionsModel(store:store)
        await model.bind(english); XCTAssertNotNil(model.suggestion(for:"tortiyas"))
        await model.bind(.init(profileID:"local:test-a",localeIdentifier:"es-US")); XCTAssertNil(model.suggestion(for:"tortiyas"))
        await model.bind(.init(profileID:"local:test-b",localeIdentifier:"en-US")); XCTAssertNil(model.suggestion(for:"tortiyas"))
        await model.bind(english); model.invalidate(); XCTAssertNil(model.suggestion(for:"tortiyas")); XCTAssertNil(model.scope)
    }
    func testCorrectionsCannotRewriteNumbersOrNegation() async throws {
        let directory=location(); defer { try? FileManager.default.removeItem(at:directory) }
        let store=CaptureCorrectionStore(directory:directory); try await store.setEnabled(true,scope:english)
        for (original,replacement) in [("2 milk","3 milk"),("milk without nuts","milk"),("sin azúcar","azúcar"),("gluten free","gluten")] {
            do { try await store.remember(original:original,replacement:replacement,scope:english); XCTFail("Material interpretation cannot be remembered as spelling") } catch {}
        }
        let result=try await store.load(english); XCTAssertTrue(result.entries.isEmpty)
    }
    func testEraseProfileRejectsLateRecreationAcrossLocalesAndRestart() async throws {
        let directory=location(); defer { try? FileManager.default.removeItem(at:directory) }
        let spanish=CaptureCorrectionScope(profileID:english.profileID,localeIdentifier:"es-US")
        let store=CaptureCorrectionStore(directory:directory)
        for scope in [english,spanish] {
            try await store.setEnabled(true,scope:scope)
            try await store.remember(original:"tortiyas",replacement:"tortillas",scope:scope)
        }
        try await store.eraseProfile(english)
        let reopened=CaptureCorrectionStore(directory:directory)
        for scope in [english,spanish] {
            let result=try await reopened.load(scope); XCTAssertFalse(result.enabled); XCTAssertTrue(result.entries.isEmpty)
            do { try await reopened.setEnabled(true,scope:scope); XCTFail("Retired profile cannot be recreated") } catch {}
        }
        let files=try FileManager.default.contentsOfDirectory(atPath:directory.path)
        XCTAssertEqual(files.filter { $0.hasSuffix(".json") }.count,0)
        XCTAssertEqual(files.filter { $0.hasSuffix(".erased") }.count,1)
    }
    func testUITestCorrectionDirectoryNeverSelectsDevelopmentProfiles() throws {
        let base = location()
        let normal = CaptureCorrectionStore.defaultDirectory(applicationSupport: base, arguments: [])
        let resetOnly = CaptureCorrectionStore.defaultDirectory(applicationSupport: base, arguments: ["--reset-test-workspace"])
        let ui = CaptureCorrectionStore.defaultDirectory(applicationSupport: base, arguments: ["--ui-testing", "--reset-test-workspace"])
        XCTAssertEqual(normal, base.appendingPathComponent("RoomInTheCart/CaptureCorrections", isDirectory: true))
        XCTAssertEqual(normal, resetOnly)
        #if DEBUG
        XCTAssertEqual(ui, base.appendingPathComponent("UITestWorkspace/CaptureCorrections", isDirectory: true))
        XCTAssertNotEqual(normal, ui)
        #else
        XCTAssertEqual(normal, ui)
        #endif
        XCTAssertFalse(FileManager.default.fileExists(atPath: base.path))
    }
    func testRawEmailIsNotAValidProfileScope() async {
        let store=CaptureCorrectionStore(directory:location())
        do { _=try await store.load(.init(profileID:"parent@example.com",localeIdentifier:"en-US")); XCTFail("Use opaque runtime identity") } catch {}
    }
}
