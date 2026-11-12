import XCTest
import CoreDomain
@testable import RoomInTheCart

final class StructuredCaptureTests: XCTestCase {
    private let destination = "Saturday pickup"
    func testRangeConnectorsRemainAmountsAndKeepTheRealDestination() throws {
        let simple = try row("2 to 3 apples")
        XCTAssertEqual(simple.amount, "")
        XCTAssertEqual(simple.name, "apples")
        XCTAssertEqual(simple.destination, destination)
        let source = "two packs of six to eight wraps for lunch to Saturday pickup without sesame"
        var draft = try row(source)
        XCTAssertEqual(draft.amount, ""); XCTAssertEqual(draft.packCount, "2")
        XCTAssertEqual(draft.amountPerPack, ""); XCTAssertEqual(draft.name, "wraps")
        XCTAssertEqual(draft.destination, destination); XCTAssertEqual(draft.purpose, "lunch")
        XCTAssertEqual(draft.exclusions, "sesame")
        let trailing = try row("2 cans of beans, 6 to 8 oz each to 3 Oaks")
        XCTAssertEqual(trailing.name, "beans"); XCTAssertEqual(trailing.destination, "3 Oaks")
        XCTAssertEqual(trailing.packCount, "2"); XCTAssertEqual(trailing.amountPerPack, "")
        let chained = try row("two to three packs of six to eight wraps to Saturday pickup without sesame")
        XCTAssertEqual(chained.name, "wraps"); XCTAssertEqual(chained.packCount, "")
        XCTAssertEqual(chained.amountPerPack, ""); XCTAssertEqual(chained.destination, destination)
        XCTAssertEqual(chained.exclusions, "sesame")
        let lunches = try row("2 apples for two to three lunches to 3 Oaks without sesame")
        XCTAssertEqual(lunches.name, "apples"); XCTAssertEqual(lunches.amount, "2")
        XCTAssertEqual(lunches.purpose, "two to three lunches"); XCTAssertEqual(lunches.destination, "3 Oaks")
        XCTAssertEqual(lunches.exclusions, "sesame")
        let named = try row("2 apples to 3 Oaks")
        XCTAssertEqual(named.amount, "2"); XCTAssertEqual(named.destination, "3 Oaks")
        let spanish = try row("entre dos y tres tazas de arroz para cena destino esta compra sin nueces")
        XCTAssertEqual(spanish.amount, ""); XCTAssertEqual(spanish.name, "arroz")
        XCTAssertEqual(spanish.destination, destination); XCTAssertEqual(spanish.purpose, "cena")
        XCTAssertEqual(spanish.exclusions, "nueces")
        let branded = try row("2 Formula 1 to 3 Oaks")
        XCTAssertEqual(branded.name, "Formula 1"); XCTAssertEqual(branded.destination, "3 Oaks")
        draft.amountPerPack = "7"; draft.confirmed = true
        let reviewed = try XCTUnwrap(draft.reviewed(expectedDestination: destination))
        var shop = ShoppingLedger()
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: source, source: .voice, lines: [reviewed])
        try shop.commitImport(preview)
        let saved = try JSONDecoder().decode(ShoppingLedger.self, from: JSONEncoder().encode(shop))
        XCTAssertEqual(try saved.quantity(forLineID: draft.proposedLineID)?.amount, try Rational(14))
        XCTAssertEqual(saved.contributions.first?.originalText, source)
        XCTAssertEqual(saved.contributions.first?.exclusions, ["sesame"])
    }
    func testEnglishAndSpanishQuantitiesRemainExact() throws {
        let english = try row("half kg rice for dinner to this pickup")
        let spanish = try row("medio kg arroz para la cena destino esta compra")
        XCTAssertEqual(english.amount, "1/2"); XCTAssertEqual(spanish.amount, "1/2")
        XCTAssertEqual(english.unit, .kilogram); XCTAssertEqual(spanish.unit, .kilogram)
        XCTAssertEqual(english.name, "rice"); XCTAssertEqual(spanish.name, "arroz")
        XCTAssertEqual(spanish.purpose, "la cena"); XCTAssertEqual(spanish.destination, destination)
    }
    func testSpokenHalfMeasuresAndCompoundCountsReachTheReviewedGroceryList() throws {
        let examples: [(String, String, Rational?, UnitOfMeasure?)] = [
            ("one and a half cups of rice", "rice", try Rational(3, 2), .cup),
            ("dos y media tazas de arroz", "arroz", try Rational(5, 2), .cup),
            ("una taza y media de arroz", "arroz", try Rational(3, 2), .cup),
            ("a cup and a half of milk", "milk", try Rational(3, 2), .cup),
            ("veintidós tortillas", "tortillas", try Rational(22), .count),
            ("half a cup of milk", "milk", try Rational(1, 2), .cup),
            ("twenty Dos Equis", "Dos Equis", try Rational(20), .count),
            ("thirty thousand grains", "thirty thousand grains", nil, nil),
            ("a half cup of milk", "milk", try Rational(1, 2), .cup),
            ("twenty one tortillas", "tortillas", try Rational(21), .count),
            ("twenty-one tortillas", "tortillas", try Rational(21), .count),
            ("treinta y dos tortillas", "tortillas", try Rational(32), .count),
            ("half and half", "half and half", nil, nil),
            ("2 cups of Half and Half", "Half and Half", try Rational(2), .cup),
            ("two packs of one and a half cups of rice", "rice", try Rational(3), .cup),
            ("between one and a half and two cups of rice", "rice", nil, nil),
            ("entre una y media taza de arroz", "arroz", nil, nil),
            ("between one cup and half a cup of rice", "rice", nil, nil)
        ]
        for (text, name, amount, unit) in examples {
            var draft = try row(text)
            XCTAssertThrowsError(try draft.reviewed(expectedDestination: destination), text)
            draft.confirmed = true
            let line = try XCTUnwrap(draft.reviewed(expectedDestination: destination), text)
            var shop = ShoppingLedger()
            let preview = try shop.stageCaptureImport(id: UUID(), originalText: text, source: .voice, lines: [line])
            try shop.commitImport(preview)
            let saved = try XCTUnwrap(shop.contributions.first)
            XCTAssertEqual(preview.lines.first?.name, name, text)
            XCTAssertEqual(saved.quantity?.amount, amount, text)
            XCTAssertEqual(saved.quantity?.unit, unit, text)
            XCTAssertEqual(saved.originalText, text)
        }
        let purchased = try ShoppingLedger().stageImport(text: "2 Hundred Grand bars\n2 and a half cups of Half and Half", source: .paste)
        XCTAssertEqual(purchased.lines.map(\.name), ["Hundred Grand bars", "Half and Half"])
        XCTAssertEqual(purchased.lines.map { $0.quantity?.amount }, [try Rational(2), try Rational(5, 2)])
        XCTAssertEqual(purchased.lines.map { $0.quantity?.unit }, [.count, .cup])
        for name in ["Half and Half", "One Degree oats", "Seven Seas dressing"] {
            let pasted = try XCTUnwrap(ShoppingLedger().stageImport(text: name).lines.first)
            XCTAssertEqual(pasted.name, name)
            XCTAssertNil(pasted.quantity)
        }
    }
    func testMixedMeasuresAndSpanishPackEvidenceReachTheSameReviewedList() throws {
        for label in ["2 × 12 fl. oz. seltzer", "dos latas de 12 oz. líq. seltzer"] {
            var draft = try row(label)
            XCTAssertEqual(draft.name, "seltzer")
            XCTAssertEqual(draft.packUnit, .fluidOunce)
            draft.confirmed = true
            let captured = try XCTUnwrap(draft.reviewed(expectedDestination: destination))
            let preview = try ShoppingLedger().stageCaptureImport(id: UUID(), originalText: label, source: .voice, lines: [captured])
            XCTAssertEqual(preview.lines.first?.quantity?.unit, .fluidOunce)
            XCTAssertEqual(preview.lines.first?.quantity?.amount, try Rational(24))
        }
        for text in ["1 1/2 cups of arroz", "1½ tazas de arroz"] {
            let draft = try row(text)
            XCTAssertEqual(draft.amount, "3/2")
            XCTAssertEqual(draft.unit, .cup)
            XCTAssertEqual(draft.name, "arroz")
            XCTAssertEqual(draft.originalText, text)
        }
        var packs = try row("dos paquetes de 1 1/2 onzas líquidas de caldo sin sal")
        XCTAssertEqual(packs.packCount, "2")
        XCTAssertEqual(packs.amountPerPack, "3/2")
        XCTAssertEqual(packs.packUnit, .fluidOunce)
        XCTAssertEqual(packs.name, "caldo")
        XCTAssertEqual(packs.exclusions, "sal")
        packs.confirmed = true
        let captured = try XCTUnwrap(packs.reviewed(expectedDestination: destination))
        let shop = ShoppingLedger()
        let staged = try shop.stageCaptureImport(id: UUID(), originalText: packs.originalText, source: .voice, lines: [captured])
        XCTAssertEqual(staged.lines[0].quantity?.amount, try Rational(3))
        XCTAssertEqual(staged.lines[0].quantity?.unit, .fluidOunce)
        XCTAssertEqual(staged.lines[0].originalText, packs.originalText)
        let unknown = try row("dos paquetes de 2 cucharaditas de sal")
        XCTAssertTrue(unknown.amountPerPack.isEmpty)
        XCTAssertTrue(unknown.warnings.contains(.packUnknown))
        XCTAssertTrue(try row("1 1/0 cups rice").amount.isEmpty)
    }

    func testMultipliedAndNestedPackLabelsKeepExactPackEvidenceWithoutInventingMissingContents() throws {
        let label = "2 × 15 oz pinto beans"
        var draft = try row(label)
        XCTAssertEqual(draft.name, "pinto beans")
        XCTAssertEqual(draft.packCount, "2")
        XCTAssertEqual(draft.amountPerPack, "15")
        XCTAssertEqual(draft.packUnit, .ounce)
        draft.confirmed = true
        let capture = try XCTUnwrap(draft.reviewed(expectedDestination: destination))
        var shop = ShoppingLedger()
        let preview = try shop.stageCaptureImport(id: UUID(), originalText: label, source: .paste, lines: [capture])
        try shop.commitImport(preview)
        XCTAssertEqual(shop.contributions.first?.quantity?.amount, try Rational(30))
        XCTAssertEqual(shop.contributions.first?.quantity?.unit, .ounce)
        XCTAssertEqual(shop.contributions.first?.capture?.packCount, 2)
        XCTAssertEqual(shop.contributions.first?.originalText, label)
        let nested = try row("dos cajas de 6 paquetes de 8 tortillas")
        XCTAssertEqual(nested.name, "tortillas")
        XCTAssertEqual(nested.packCount, "2")
        XCTAssertEqual(nested.amountPerPack, "48")
        var missing = try row("2 packs of 6 packs of wraps")
        XCTAssertTrue(missing.amountPerPack.isEmpty)
        XCTAssertTrue(missing.warnings.contains(.packUnknown))
        missing.confirmed = true
        let unknown = try XCTUnwrap(missing.reviewed(expectedDestination: destination))
        let unknownPreview = try shop.stageCaptureImport(id: UUID(), originalText: missing.originalText, source: .paste, lines: [unknown])
        XCTAssertNil(unknownPreview.lines.first?.quantity)
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
        XCTAssertTrue(try row("2 tsp. sugar").amount.isEmpty)
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
        try await store.forget(id, scope: english)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
        XCTAssertTrue(files.isEmpty, "A stale forget must not recreate the deleted spelling file")
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
    func testConnectedSpellingFilesIsolateMembersAndAccountErasure() async throws {
        let directory = location(); defer { try? FileManager.default.removeItem(at: directory) }
        let household = UUID().uuidString, member = UUID().uuidString, otherMember = UUID().uuidString
        let subject = "verified-account", otherSubject = "other-account"
        func scope(_ subject: String, memberID: String? = nil, locale: String = "en-US") throws -> CaptureCorrectionScope {
            try XCTUnwrap(.connected(subject: subject, householdID: household, memberID: memberID ?? member, localeIdentifier: locale))
        }
        let connected = try scope(subject), spanish = try scope(subject, locale: "es-US")
        let sibling = try scope(subject, memberID: otherMember), otherAccount = try scope(otherSubject)
        let store = CaptureCorrectionStore(directory: directory)
        for saved in [connected, english, otherAccount] {
            try await store.setEnabled(true, scope: saved)
            try await store.remember(original: "tortiyas", replacement: "tortillas", scope: saved)
        }
        for separate in [spanish, sibling] {
            let initial = try await store.load(separate)
            XCTAssertFalse(initial.enabled); XCTAssertTrue(initial.entries.isEmpty)
            try await store.setEnabled(true, scope: separate)
        }
        try await store.eraseProfile(connected)
        let retired = try await store.load(spanish)
        let survivingMember = try await store.load(sibling)
        XCTAssertFalse(retired.enabled); XCTAssertTrue(survivingMember.enabled)
        try await store.eraseConnectedAccount(subject)

        let reopened = CaptureCorrectionStore(directory: directory)
        for erased in [connected, spanish, sibling] {
            let snapshot = try await reopened.load(erased)
            XCTAssertFalse(snapshot.enabled); XCTAssertTrue(snapshot.entries.isEmpty)
            do {
                try await reopened.setEnabled(true, scope: erased)
                XCTFail("A deleted account must reject late writes")
            } catch CaptureCorrectionFailure.invalidScope {}
        }
        for preserved in [english, otherAccount] {
            let snapshot = try await reopened.load(preserved)
            XCTAssertEqual(snapshot.entries.first?.replacement, "tortillas")
        }
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
