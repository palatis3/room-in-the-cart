import XCTest
import HouseholdClient
import RecordArchive
@testable import RoomInTheCart

final class SharedRecordArchiveTests: XCTestCase {
    private func record() throws -> ArchiveRecord {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let bytes = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/shared-records/partial-v2.json"))
        return try SharedRecordArchiveAdapter.make(SharedRecordWire.snapshot(from: bytes))
    }
    @MainActor func testImportRechecksHouseholdListingOnceAndWithdrawsComparisonOnAccessLoss() async throws {
        let live = try record(), shopID = try XCTUnwrap(UUID(uuidString: live.id))
        let source = RecordsToolsModel.selectionID(live)
        var reads = 0, unreadable = false, authorized = true
        let model = RecordsToolsModel(registry: try registry(), snapshot: {
            reads += 1
            if unreadable { throw ArchiveError.unavailable }
            return try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shopID,
                authorized: { authorized }, current: { live }, history: { throw ClientError.transport })
        }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in },
           beginAuthorization: { { authorized } })
        let archive = try ArchiveCodec.make(records: [live], kind: .personalRecovery, origin: "file", revision: "export")
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".json")
        defer { try? FileManager.default.removeItem(at: url) }
        try ArchiveCodec.encode(archive).write(to: url)
        await model.refresh()
        unreadable = true
        await model.importFile(url, recipes: false)
        let rowID = try XCTUnwrap(model.review?.rows.first).id
        XCTAssertEqual(reads, 2)
        XCTAssertTrue(model.currentImportVersions.isEmpty)
        unreadable = false
        await model.refresh()
        XCTAssertEqual(model.currentImportVersions[rowID], [.init(revision: source.revision, savedAtMilliseconds: live.savedAtMilliseconds)])
        XCTAssertEqual(reads, 3)
        authorized = false
        XCTAssertTrue(model.currentImportVersions.isEmpty)
        authorized = true
        model.liveSharedAccessEnded()
        XCTAssertTrue(model.currentImportVersions.isEmpty)
        XCTAssertEqual(reads, 3)
    }

    @MainActor func testLiveRecordReadsDiscardEarlierShopDataWhenShopperAccessEnds() async throws {
        let live = try record()
        let shopID = try XCTUnwrap(UUID(uuidString: live.id))
        for denial: ClientError in [.accessEnded, .sessionNeeded,
                                     .service(status: 404, code: "unavailable", correlationID: nil, retryAfter: nil)] {
            let revoked = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shopID,
                authorized: { true }, current: { live }, history: { throw denial })
            XCTAssertTrue(revoked.records.isEmpty)
            XCTAssertEqual(revoked.unavailable.count, 2)
        }
        let denied = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shopID,
            authorized: { true }, current: { throw ClientError.accessEnded }, history: {
                XCTFail("A denied shopper should make no further live Records reads")
                return live
            })
        XCTAssertTrue(denied.records.isEmpty)

        let interrupted = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shopID,
            authorized: { true }, current: { live }, history: { throw ClientError.transport })
        XCTAssertEqual(interrupted.records, [live])
        XCTAssertEqual(interrupted.unavailable.map(\.recordID), [live.id + "/history"])
    }

    @MainActor func testLiveDenialClearsPreparedFileAndLeavesIndependentRecoveredExportUsable() async throws {
        let live = try record(), shop = try XCTUnwrap(UUID(uuidString: live.id)), registry = try registry()
        let archive = try ArchiveCodec.make(records: [live], kind: .personalRecovery, origin: "backup", revision: live.revision)
        _ = try await registry.apply(registry.review(archive))
        var denied = false
        weak var activeModel: RecordsToolsModel?
        let model = RecordsToolsModel(registry: registry, snapshot: {
            var batch = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shop,
                authorized: { true }, accessDenied: { activeModel?.liveSharedAccessEnded() }, current: { live }, history: {
                    if denied { throw ClientError.accessEnded }
                    throw ClientError.transport
                })
            let recovered = try await registry.refreshList().map(\.record)
            batch.records = try RecordsSnapshotProjection.mergeForExport(batch.records + recovered)
            return batch
        }, validateNativePayload: { try RecordsNativeCodec.validate($0) }, openRecovered: { _ in })
        activeModel = model
        await model.refresh()
        model.selectAll()
        await model.prepareExport(.ownerText)
        XCTAssertNotNil(model.preparedDocument)

        denied = true
        await model.refresh()
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(model.currentRecords, [live], "The independent recovered copy remains available")
        XCTAssertTrue(model.sourceListing.liveSharedRecordIDs.isEmpty)
        model.selectAll()
        await model.prepareExport(.ownerText)
        let localFile = try XCTUnwrap(model.preparedDocument)
        await model.refresh()
        XCTAssertEqual(model.preparedDocument?.data, localFile.data)
    }

    @MainActor func testConcurrentLiveDenialRejectsEarlierSharedReadAndOwnerExport() async throws {
        let live = try record(), shop = try XCTUnwrap(UUID(uuidString: live.id))
        for holdSnapshot in [true, false] {
            var denied = false, hold = false
            let suspended = expectation(description: holdSnapshot ? "Holding completed live read" : "Holding export validation")
            var resume: CheckedContinuation<Void, Never>?
            let pause: @MainActor () async -> Void = {
                guard hold else { return }
                hold = false
                await withCheckedContinuation { continuation in resume = continuation; suspended.fulfill() }
            }
            weak var activeModel: RecordsToolsModel?
            let model = RecordsToolsModel(registry: try registry(), snapshot: {
                let batch = try await RecordsSnapshotProjection.liveSharedRecords(householdID: "family", shopID: shop,
                    authorized: { true }, accessDenied: { activeModel?.liveSharedAccessEnded() }, current: { live }, history: {
                        if denied { throw ClientError.accessEnded }
                        throw ClientError.transport
                    })
                if holdSnapshot { await pause() }
                return batch
            }, validateNativePayload: {
                try RecordsNativeCodec.validate($0)
                if !holdSnapshot { await pause() }
            }, openRecovered: { _ in })
            activeModel = model
            await model.refresh()
            model.selectAll()
            hold = true
            let export = Task { await model.prepareExport(.ownerText) }
            await fulfillment(of: [suspended], timeout: 2)
            denied = true
            await model.refresh()
            XCTAssertTrue(model.currentRecords.isEmpty)
            XCTAssertTrue(model.selectedIDs.isEmpty)
            resume?.resume()
            await export.value
            XCTAssertTrue(model.currentRecords.isEmpty)
            XCTAssertNil(model.preparedDocument)
            XCTAssertEqual(model.error, .staleReview)
        }
    }

    @MainActor func testHistoricalArchiveIsEncryptedIndependentDeduplicatedAndNeverHelperData() async throws {
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let legacyBytes = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/shared-records/history-v1.json"))
        let legacy = try SharedHistoryArchiveAdapter.make(SharedRecordHistoryWire.snapshot(from: legacyBytes))
        XCTAssertTrue(SharedHistoryArchiveAdapter.coverageKeys(legacy).contains("Stock-lot history was not captured in this copy."))
        XCTAssertTrue(SharedHistoryArchiveAdapter.coverageKeys(legacy).contains("Food allocation history was not captured in this copy."))
        let earlierStockBytes = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/shared-records/history-food-v1.json"))
        let earlierStock = try SharedHistoryArchiveAdapter.make(SharedRecordHistoryWire.snapshot(from: earlierStockBytes))
        XCTAssertTrue(try SharedHistoryArchiveAdapter.readable(earlierStock, locale: Locale(identifier: "en_US")).contains("Delivery history from earlier pickups was not captured in this copy."))
        let bytes = try Data(contentsOf: root.appendingPathComponent("shared/fixtures/shared-records/history-carried-v1.json"))
        let source = try SharedRecordHistoryWire.snapshot(from: bytes)
        let record = try SharedHistoryArchiveAdapter.make(source)
        try RecordsNativeCodec.validate(record)
        XCTAssertTrue(record.id.hasSuffix("/history"))
        XCTAssertTrue(SharedHistoryArchiveAdapter.coverageKeys(record).contains("Stock-lot history is included."))
        XCTAssertTrue(SharedHistoryArchiveAdapter.coverageKeys(record).contains("Food allocation history is included."))
        let stock = try XCTUnwrap(source.record.stockHistory), food = try XCTUnwrap(source.record.foodHistory)
        XCTAssertFalse(stock.events.isEmpty); XCTAssertFalse(food.demandRevisions.isEmpty)
        XCTAssertEqual(record.revision, ArchiveCodec.digest(try source.record.independentData()))
        XCTAssertThrowsError(try ArchiveCodec.make(records: [record], kind: .helperShop, origin: "history", revision: "1"))
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "history", revision: record.revision)
        let key = EncryptedArchive.generateKey()
        let encrypted = try EncryptedArchive.seal(envelope, key: key)
        let reopened = try EncryptedArchive.open(encrypted, key: key)
        let registry = try registry()
        let firstReview = try await registry.review(reopened)
        let first = try await registry.apply(firstReview)
        let repeated = try await registry.review(reopened)
        let second = try await registry.apply(repeated)
        XCTAssertEqual(first.insertedCount, 1); XCTAssertEqual(second.insertedCount, 0)
        XCTAssertEqual(first.records.first?.id, second.records.first?.id)
        XCTAssertEqual(try SharedHistoryArchiveAdapter.validate(record), source.record)
        let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        XCTAssertEqual(try SharedHistoryArchiveAdapter.readable(record), try SharedHistoryArchiveAdapter.readable(record, locale: appLocale))
        for locale in ["en_US", "es_US"] {
            let text = try SharedHistoryArchiveAdapter.readable(record, locale: Locale(identifier: locale))
            let spanish = locale == "es_US"
            XCTAssertTrue(text.contains(spanish ? "Borrador · Cesta creada" : "Draft · Basket created"))
            XCTAssertTrue(text.contains(spanish ? "Fijada · Cesta fijada" : "Frozen · Basket frozen"))
            XCTAssertTrue(text.contains(spanish ? "Realizada · Pedido realizado" : "Placed · Order placed"))
            XCTAssertTrue(text.contains(spanish ? "Alcance / límite: compra completa / USD 38.00 · compra completa" : "Scope / cap: whole checkout / USD 38.00 · whole checkout"))
            XCTAssertTrue(text.contains(spanish ? "Fictional market · Main · Estante de la tienda · Recogida" : "Fictional market · Main · Store shelf · Pickup"))
            XCTAssertTrue(text.contains(spanish ? "8 wraps · 8/1 unidades" : "8 wraps · 8/1 units"))
            XCTAssertTrue(text.contains(spanish ? "10 earlier-pickup wraps (10/1 unidades)" : "10 earlier-pickup wraps (10/1 units)"))
            XCTAssertEqual(record.nativePayload, try source.record.independentData())
            XCTAssertTrue(text.contains(source.record.cookCopies[0].text))
            XCTAssertTrue(text.contains(source.record.decisions[0].decision))
            for lot in stock.lots { XCTAssertTrue(text.contains(lot.foodName)) }
            let carried = try XCTUnwrap(stock.carriedDeliveries)
            XCTAssertFalse(carried.isEmpty)
            for delivery in carried {
                XCTAssertTrue(text.contains(delivery.originShopId.uuidString.lowercased()))
                XCTAssertTrue(text.contains(delivery.source.foodName))
                for observation in delivery.observations { XCTAssertTrue(text.contains(observation.recordedAt)) }
            }
            for revision in food.demandRevisions {
                for contribution in revision.graph.contributions { XCTAssertTrue(text.contains(contribution.originalText)) }
                for edge in revision.graph.edges { XCTAssertTrue(text.contains(edge.confirmation.evidence)) }
            }
            for event in stock.events { XCTAssertTrue(text.contains(event.recordedAt)) }
            XCTAssertTrue(text.contains(locale == "es_US" ? "Reserva liberada" : "Reservation released"))
            XCTAssertTrue(text.contains("confirmed no usable wraps"))
            XCTAssertFalse(text.contains("authorityEpoch")); XCTAssertFalse(text.contains("replayWindow"))
        }
        var forged = record; forged.revision = "different"
        XCTAssertThrowsError(try RecordsNativeCodec.validate(forged))
        try await registry.registerErasedSources([.init(origin: record.origin, recordID: record.id)])
        let erased = try await registry.review(reopened)
        XCTAssertFalse(erased.canApply)
        let remaining = try await registry.refreshList(); XCTAssertTrue(remaining.isEmpty)
    }
    private func registry() throws -> RecoveryRegistry {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return try RecoveryRegistry(url: directory.appendingPathComponent("records.json"))
    }
    @MainActor func testEncryptedIndependentRoundtripReimportsOnceAndPreservesPartialFacts() async throws {
        let record = try record(), registry = try registry()
        try RecordsNativeCodec.validate(record)
        let envelope = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: "selected-local-records", revision: "test")
        let key = EncryptedArchive.generateKey(), bytes = try EncryptedArchive.seal(envelope, key: key)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains("Unknown lunch wraps"))
        let reopened = try EncryptedArchive.open(bytes, key: key)
        let firstReview = try await registry.review(reopened)
        let first = try await registry.apply(firstReview)
        let secondReview = try await registry.review(reopened)
        let second = try await registry.apply(secondReview)
        XCTAssertEqual(first.insertedCount, 1); XCTAssertEqual(second.insertedCount, 0)
        XCTAssertEqual(first.records.map(\.id), second.records.map(\.id))
        let recovered = try SharedRecordArchiveAdapter.validate(XCTUnwrap(first.records.first).record)
        XCTAssertEqual(recovered.food.coverage?.status, .partial); XCTAssertNil(recovered.food.unbound.first?.transferred?.quantity)
        XCTAssertTrue(recovered.food.coverage?.allocatableUnboundFactIds.isEmpty == true)
    }
    @MainActor func testHelperProjectionCannotAccidentallySharePrivateSnapshot() throws {
        XCTAssertThrowsError(try ArchiveCodec.make(records: [record()], kind: .helperShop, origin: "helper", revision: "1"))
    }
    @MainActor func testRepeatedHelperExportFailuresRevealFreshOutcomesWithoutPublishingOrWritingPrivateData() async throws {
        let source = try record()
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let manifest = directory.appendingPathComponent("records.json")
        let registry = try RecoveryRegistry(url: manifest)
        let existing = try ArchiveCodec.make(records: [source], kind: .personalRecovery, origin: source.origin, revision: source.revision)
        let existingReview = try await registry.review(existing)
        let saved = try await registry.apply(existingReview)
        let originalBytes = try Data(contentsOf: manifest)
        var reads = 0, validations = 0
        var refreshFails = false
        let model = RecordsToolsModel(registry: registry, snapshot: {
            reads += 1
            if refreshFails { throw ArchiveError.unavailable }
            return .init(records: [source])
        }, validateNativePayload: {
            validations += 1
            try RecordsNativeCodec.validate($0)
        }, openRecovered: { _ in XCTFail("Export must not open recovered work") },
           deleteSource: { _ in XCTFail("Export must not delete or write the source") })
        await model.refresh(); model.selectAll()
        XCTAssertNil(model.actionOutcomeID)
        // A failed helper action must also clear a previously prepared private file.
        await model.prepareExport(.ownerText)
        XCTAssertNotNil(model.preparedDocument); XCTAssertTrue(model.preparedIsPrivate)
        var previousOutcome: UUID?
        for choice in [RecordsToolsModel.ExportChoice.helperText, .helperJSON] {
            await model.prepareExport(choice)
            XCTAssertEqual(model.error, .unsupportedProjection)
            let outcome = try XCTUnwrap(model.actionOutcomeID)
            XCTAssertNotEqual(outcome, previousOutcome, "Each repeated failure must reveal the result again")
            previousOutcome = outcome
            XCTAssertNil(model.preparedDocument, "No private document may remain available to save or share")
            XCTAssertNil(model.status); XCTAssertFalse(model.busy)
            XCTAssertEqual(model.currentRecords, [source])
            XCTAssertEqual(model.selectedIDs, [RecordsToolsModel.selectionID(source)])
            XCTAssertEqual(model.recoveredRecords, saved.records)
            let persisted = try await registry.refreshList()
            XCTAssertEqual(persisted, saved.records)
            XCTAssertEqual(try Data(contentsOf: manifest), originalBytes, "Failed export must not write the recovery registry")
        }
        XCTAssertEqual(reads, 4); XCTAssertEqual(validations, 3)
        // A background refresh failure still does not move the user's focus.
        refreshFails = true
        await model.refresh()
        XCTAssertEqual(model.error, .unavailable); XCTAssertNil(model.actionOutcomeID)
        XCTAssertNil(model.preparedDocument)
        XCTAssertEqual(try Data(contentsOf: manifest), originalBytes)
    }
    @MainActor func testUnknownAuthorityAndForgedArchiveIdentityRejectBeforeRecovery() throws {
        var record = try record(), object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(record.nativePayload)) as? [String: Any])
        object["authorityEpoch"] = 8; record.nativePayload = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .withoutEscapingSlashes])
        XCTAssertThrowsError(try RecordsNativeCodec.validate(record))
        record = try self.record(); record.origin = "shared-shop/forged"; XCTAssertThrowsError(try SharedRecordArchiveAdapter.validate(record))
    }
    @MainActor func testConflictingSameRevisionIsQuarantinedAndKnownErasureBlocksOldCopies() async throws {
        let record = try record(), registry = try registry()
        let original = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: record.origin, revision: record.revision)
        let originalReview = try await registry.review(original)
        _ = try await registry.apply(originalReview)
        var changed = record; changed.title += " changed"
        let conflict = try ArchiveCodec.make(records: [changed], kind: .personalRecovery, origin: record.origin, revision: record.revision)
        let review = try await registry.review(conflict)
        XCTAssertEqual(review.rows.first?.disposition, .quarantined); XCTAssertFalse(review.canApply)
        try await registry.registerErasedSources([.init(origin: record.origin, recordID: record.id)])
        let erased = try await registry.review(original)
        XCTAssertEqual(erased.rows.first?.disposition, .erased)
        let remaining = await registry.list()
        XCTAssertTrue(remaining.isEmpty)
    }
    @MainActor func testReadableOwnerCopyKeepsOriginalWordingAndUnknownsInBothLanguages() throws {
        let value = try record()
        let english = try SharedRecordArchiveAdapter.readable(value, locale: Locale(identifier: "en_US"))
        let spanish = try SharedRecordArchiveAdapter.readable(value, locale: Locale(identifier: "es_US"))
        let appLocale = Locale(identifier: Bundle.main.preferredLocalizations.first ?? "en")
        XCTAssertEqual(try SharedRecordArchiveAdapter.readable(value), try SharedRecordArchiveAdapter.readable(value, locale: appLocale))
        XCTAssertTrue(english.contains("Unknown lunch wraps")); XCTAssertTrue(english.contains("Unbound; not available as free supply"))
        XCTAssertTrue(spanish.contains("Unknown lunch wraps")); XCTAssertTrue(spanish.contains("Sin determinar"))
        XCTAssertTrue(spanish.contains("Exact family restriction"))
        XCTAssertFalse(english.contains("authorityEpoch")); XCTAssertFalse(spanish.contains("previewId"))
    }

    @MainActor func testReadableExportLocalizesRecordedConversionButPreservesSourceWords() throws {
        var archive = try record()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: XCTUnwrap(archive.nativePayload)) as? [String: Any])
        var food = try XCTUnwrap(object["food"] as? [String: Any])
        var review = try XCTUnwrap(food["packReview"] as? [String: Any])
        var packs = try XCTUnwrap(review["values"] as? [[String: Any]])
        var quantity = try XCTUnwrap(packs[0]["usablePerPack"] as? [String: Any])
        for (unit, literal, enUnits, esUnits, enUnit, esUnit) in [
            ("cup", "3 cups as entered", "cups", "tazas", "cup", "taza"),
            ("fluidOunce", "3 fl oz as entered", "fl oz", "onzas líquidas", "fl oz", "onza líquida")
        ] {
            quantity["unit"] = unit
            quantity["originalLiteral"] = literal
            quantity["confirmedConversion"] = [
                "sourceUnit": unit, "targetUnit": "gram",
                "targetAmountPerSourceUnit": ["numerator": "120", "denominator": "1"],
                "sourceNote": "weighed at home", "confirmedAt": "2026-11-10T12:00:00.000Z"
            ]
            packs[0]["usablePerPack"] = quantity
            review["values"] = packs
            food["packReview"] = review
            object["food"] = food
            let source = try SharedRecordWire.independentRecord(from: JSONSerialization.data(withJSONObject: object))
            archive.nativePayload = try source.independentData()
            let en = try SharedRecordArchiveAdapter.readable(archive, locale: Locale(identifier: "en_US"))
            let es = try SharedRecordArchiveAdapter.readable(archive, locale: Locale(identifier: "es_US"))
            XCTAssertTrue(en.contains("\(literal) (3/1 \(enUnits)) · weighed at home · 120/1 grams / 1 \(enUnit) · 2026-11-10T12:00:00.000Z"))
            XCTAssertTrue(es.contains("\(literal) (3/1 \(esUnits)) · weighed at home · 120/1 gramos / 1 \(esUnit) · 2026-11-10T12:00:00.000Z"))
            XCTAssertTrue(en.contains("Tracked subtotal: Apples · 3/1 units"))
            XCTAssertTrue(es.contains("Subtotal registrado: Apples · 3/1 unidades"))
            XCTAssertEqual(archive.nativePayload, try source.independentData())
        }
    }

}
