import XCTest
import CryptoKit
import UniformTypeIdentifiers
@testable import DeviceSurfaces

final class DeviceSurfacesTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    func file(_ name: String = "data.sqlite") throws -> URL {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("DeviceSurfaces-\(UUID())")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: directory) }
        return directory.appendingPathComponent(name)
    }
    func intent(id: UUID = UUID(), handle: RouteHandle = .random(), day: Int = 20, subject: ReminderSubject = .offer) throws -> ReminderIntent {
        try ReminderIntent(id: id, personaID: UUID(), targetID: UUID(), subject: subject, sourceRevision: 4, routeHandle: handle,
            localTime: CivilReminderTime(year: 2027, month: 1, day: day, hour: 13, minute: 0, timeZoneID: "America/New_York"),
            expiresAt: Date(timeIntervalSince1970: 1_810_000_000), cutoff: Date(timeIntervalSince1970: 1_810_000_000), language: .english, now: now)
    }
    private func loadTextFile(_ bytes: Data, type: UTType = .utf8PlainText) async throws -> Result<String, SurfaceError> {
        let source = try file("shopping.txt")
        try bytes.write(to: source)
        let provider = NSItemProvider()
        provider.registerFileRepresentation(forTypeIdentifier: type.identifier, fileOptions: [], visibility: .all) { receive in
            receive(source, false, nil)
            return nil
        }
        return await withCheckedContinuation { result in
            SelectedTextInbox.loadPlainText(from: provider) { result.resume(returning: $0) }
        }
    }
    func testSharedPlainTextFilesPreserveOriginalWordingAndLineBreaks() async throws {
        let text = "2 tortillas\r\nFrijoles negros 🍚"
        let utf8 = Data(text.utf8)
        let samples: [(UTType, Data)] = [
            (.utf8PlainText, utf8),
            (.plainText, Data([0xEF, 0xBB, 0xBF]) + utf8),
            (.utf16ExternalPlainText, try XCTUnwrap(text.data(using: .utf16))),
            (.utf16PlainText, try XCTUnwrap(text.data(using: .utf16LittleEndian)))
        ]
        for (type, data) in samples {
            let result = try await loadTextFile(data, type: type)
            XCTAssertEqual(try result.get(), text, type.identifier)
        }
        let stringResult: Result<String, SurfaceError> = await withCheckedContinuation { result in
            SelectedTextInbox.loadPlainText(from: NSItemProvider(object: text as NSString)) { result.resume(returning: $0) }
        }
        XCTAssertEqual(try stringResult.get(), text)
    }
    func testSharedPlainTextFilesRejectOversizedInvalidAndUnrelatedRepresentations() async throws {
        let exact = Data(repeating: 65, count: SelectedTextInbox.maximumEntryBytes)
        let valid = try await loadTextFile(exact)
        XCTAssertEqual(try valid.get().utf8.count, exact.count)
        let oversized = try await loadTextFile(exact + Data([65]))
        XCTAssertEqual(oversized, .failure(.capacity))
        for bytes in [Data([0xFF]), Data([0x61, 0x00, 0x62]), Data([0xFF, 0xFE, 65, 0, 65]), Data()] {
            let invalid = try await loadTextFile(bytes)
            XCTAssertEqual(invalid, .failure(.invalid))
        }
        let unrelated = try await loadTextFile(Data("beans".utf8), type: .pdf)
        XCTAssertEqual(unrelated, .failure(.unsupported))
    }
    func testSelectedTextExactReplayAfterReopenAndChangedReplayFails() async throws {
        let url = try file(), id = UUID(), inbox = try SelectedTextInbox(url: url)
        let first = try await inbox.stage(operationID: id, originalText: "12 tortillas — sin sal 🍚", now: now)
        let reopened = try SelectedTextInbox(url: url)
        let retry = try await reopened.stage(operationID: id, originalText: "12 tortillas — sin sal 🍚", now: now.addingTimeInterval(12))
        XCTAssertEqual(first, retry)
        do { _ = try await reopened.stage(operationID: id, originalText: "24 tortillas", now: now); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .changedReplay) }
        let entries = try await reopened.pending(now: now); XCTAssertEqual(entries.count, 1); XCTAssertEqual(entries[0].originalText, "12 tortillas — sin sal 🍚")
    }
    func testIndependentIntentionalSharesStaySeparateAndOriginalSurvivesEditing() async throws {
        let inbox = try SelectedTextInbox(url: file())
        for _ in 0..<2 { _ = try await inbox.stage(operationID: UUID(), originalText: "12 wraps", editedText: "6 wraps", now: now) }
        let rows = try await inbox.pending(now: now)
        XCTAssertEqual(rows.count, 2); XCTAssertEqual(rows[0].originalText, "12 wraps"); XCTAssertEqual(rows[0].textForReview, "6 wraps")
    }
    func testCancelSessionNeverWritesAndCannotLaterSave() async throws {
        let inbox = try SelectedTextInbox(url: file()), session = SelectedTextSession()
        try await session.cancel()
        do { _ = try await session.save(original: "coffee", edited: nil, now: now, inbox: inbox); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .cancelled) }
        let rows = try await inbox.pending(now: now); XCTAssertTrue(rows.isEmpty)
    }
    func testConsumedAndDiscardedReceiptsCannotResurrectPrivateText() async throws {
        let url = try file(), inbox = try SelectedTextInbox(url: url), id = UUID()
        let receipt = try await inbox.stage(operationID: id, originalText: "private selected phrase", now: now)
        let consumed = try await inbox.acknowledgeCommitted(operationID: id, digest: receipt.digest, now: now)
        XCTAssertEqual(consumed.disposition, .consumed)
        let repeated = try await inbox.stage(operationID: id, originalText: "private selected phrase", now: now)
        XCTAssertEqual(repeated.disposition, .consumed)
        let rows = try await inbox.pending(now: now); XCTAssertTrue(rows.isEmpty)
        XCTAssertNil(try Data(contentsOf: url).range(of: Data("private selected phrase".utf8)))
        let second = try await inbox.stage(operationID: UUID(), originalText: "discard this", now: now)
        _ = try await inbox.discard(operationID: second.operationID, digest: second.digest, now: now)
        let discarded = try await inbox.stage(operationID: second.operationID, originalText: "discard this", now: now)
        XCTAssertEqual(discarded.disposition, .discarded)
    }
    func testExpiryRetainsDeduplicationReceiptAndDropsBody() async throws {
        let inbox = try SelectedTextInbox(url: file()), id = UUID()
        _ = try await inbox.stage(operationID: id, originalText: "12 wraps", now: now)
        let later = now.addingTimeInterval(SelectedTextInbox.lifetime)
        let rows = try await inbox.pending(now: later); XCTAssertTrue(rows.isEmpty)
        let retry = try await inbox.stage(operationID: id, originalText: "12 wraps", now: later)
        XCTAssertEqual(retry.disposition, .expired)
    }
    func testBoundedBytesLinesAndPendingCapacityPreserveExistingRows() async throws {
        let inbox = try SelectedTextInbox(url: file())
        for bad in [String(repeating: "x", count: SelectedTextInbox.maximumEntryBytes + 1), String(repeating: "x\n", count: 501), "a\0b", "  "] {
            do { _ = try await inbox.stage(operationID: UUID(), originalText: bad, now: now); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .invalid) }
        }
        for _ in 0..<20 { _ = try await inbox.stage(operationID: UUID(), originalText: "item", now: now) }
        do { _ = try await inbox.stage(operationID: UUID(), originalText: "extra", now: now); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .capacity) }
        let rows = try await inbox.pending(now: now); XCTAssertEqual(rows.count, 20)
    }
    func testSelectedTextRejectsNewOversizedReviewButResolvesAnExactLegacyReceipt() async throws {
        let url = try file()
        let inbox = try SelectedTextInbox(url: url)
        let source = Array(repeating: "beans", count: 500).joined(separator: "\r\n") + "\u{2028}  \u{85}rice"
        let id = UUID()
        do {
            _ = try await inbox.stage(operationID: id, originalText: source, now: now)
            XCTFail("The ledger would receive 501 nonblank rows")
        } catch SelectedTextInbox.ReviewLimit.tooManyItems {}
        let absent = try await inbox.receipt(id)
        XCTAssertNil(absent)
        let corrected = Array(repeating: "rice", count: 500).joined(separator: "\r")
        _ = try await inbox.stage(operationID: id, originalText: source, editedText: corrected, now: now)
        let pending = try await inbox.pending(now: now)
        XCTAssertEqual(pending.first?.originalText, source)
        XCTAssertEqual(pending.first?.textForReview, corrected)

        // Schema-v1 receipts used this canonical payload and accepted 501 CRLF-separated items.
        struct LegacyBody: Encodable { let original: String }
        let digest = SHA256.hash(data: try canonical(LegacyBody(original: source))).map { String(format: "%02x", $0) }.joined()
        let legacy = UUID()
        let database = try SurfaceDatabase(url: url, kind: "selected-text-inbox", schema: "")
        try database.execute("INSERT INTO inbox (id,digest,created,expires,disposition,original,edited,bytes) VALUES(?,?,?,?,?,?,?,?)", [.text(legacy.uuidString), .text(digest),
            .double(now.timeIntervalSince1970), .double(now.addingTimeInterval(SelectedTextInbox.lifetime).timeIntervalSince1970),
            .text("pending"), .text(source), .null, .integer(Int64(source.utf8.count))])
        let retry = try await inbox.stage(operationID: legacy, originalText: source, now: now)
        XCTAssertEqual(retry.disposition, .pending)
        let older = try await inbox.pending(now: now)
        XCTAssertEqual(older.first { $0.id == legacy }?.textForReview, source)
        do {
            _ = try await inbox.stage(operationID: legacy, originalText: "changed", now: now)
            XCTFail("Changed text cannot reuse the legacy receipt")
        } catch SurfaceError.changedReplay {}
        _ = try await inbox.discard(operationID: legacy, digest: retry.digest, now: now)
        let terminal = try await inbox.stage(operationID: legacy, originalText: source, now: now)
        XCTAssertEqual(terminal.disposition, .discarded)
    }

    func testConcurrentConnectionsReturnOneDurableReceipt() async throws {
        let url = try file(), a = try SelectedTextInbox(url: url), b = try SelectedTextInbox(url: url), id = UUID(), date = now
        async let first = a.stage(operationID: id, originalText: "12 wraps", now: date)
        async let second = b.stage(operationID: id, originalText: "12 wraps", now: date)
        let values = try await [first, second]; XCTAssertEqual(values[0], values[1])
        let rows = try await a.pending(now: now); XCTAssertEqual(rows.count, 1)
    }
    func testMalformedDatabaseIsNotRecreated() throws {
        let url = try file(), bytes = Data("damaged file".utf8); try bytes.write(to: url)
        XCTAssertThrowsError(try SelectedTextInbox(url: url)); XCTAssertEqual(try Data(contentsOf: url), bytes)
    }
    func testRouteCodecRejectsCredentialsExtraKeysAndNoncanonicalHandles() throws {
        let codec = try SurfaceURLCodec(scheme: "test-surface"), handle = RouteHandle.random()
        XCTAssertEqual(try codec.parse(codec.url(handle: handle)), handle)
        XCTAssertNil(try codec.parse(codec.url(handle: nil)))
        for text in ["https://surface/open?handle=\(handle.rawValue)", "test-surface://x:password@surface/open?handle=\(handle.rawValue)", "test-surface://surface/open?handle=\(handle.rawValue)&budget=3", "test-surface://surface/open?handle=\(handle.rawValue)#secret", "test-surface://surface/open?handle=\(handle.rawValue.uppercased())"] {
            XCTAssertThrowsError(try codec.parse(URL(string: text)!))
        }
    }
    func testHandleNeverGrantsCrossPersonaOrLockedAdultAccess() throws {
        let person = UUID(), target = UUID(), generation = UUID(), handle = RouteHandle.random()
        let route = try PrivateRoute(handle: handle, personaID: person, targetID: target, generation: generation, destination: .shoppingList, expiresAt: now.addingTimeInterval(10))
        func context(_ role: SurfacePersona, unlocked: Bool = true, persona: UUID? = nil, permitted: Bool = true) -> RouteAuthorization {
            RouteAuthorization(personaID: persona ?? person, role: role, generation: generation, unlocked: unlocked, permittedTargetIDs: permitted ? [target] : [])
        }
        XCTAssertEqual(SurfaceRouter.resolve(route, handle: handle, authorization: context(.adult), now: now), .shoppingList)
        for auth in [context(.adult, unlocked: false), context(.contributor), context(.helper), context(.adult, persona: UUID()), context(.adult, permitted: false)] {
            XCTAssertNil(SurfaceRouter.resolve(route, handle: handle, authorization: auth, now: now))
        }
        XCTAssertNil(SurfaceRouter.resolve(route, handle: handle, authorization: context(.adult), now: route.expiresAt))
    }
    func testWidgetProjectionAllowsNoPrivateFieldAndConfigFailsClosed() throws {
        let projection = try WidgetProjection(writtenAt: now, routeHandle: .random(), destination: .shoppingList)
        let data = try canonical(projection); XCTAssertEqual(try WidgetProjection.decode(data), projection)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any]); object["budget"] = 38
        XCTAssertThrowsError(try WidgetProjection.decode(JSONSerialization.data(withJSONObject: object)))
        XCTAssertThrowsError(try SurfaceConfiguration(inboxGroup: nil, widgetGroup: nil, urlScheme: nil))
        XCTAssertThrowsError(try SurfaceConfiguration(inboxGroup: "group.test", widgetGroup: "group.test", urlScheme: "test-surface"))
    }
    func testDSTGapAndInvalidDateRejectWhileFoldNeedsExplicitOffset() throws {
        XCTAssertThrowsError(try ReminderPlanner.resolve(CivilReminderTime(year: 2027, month: 3, day: 14, hour: 2, minute: 30, timeZoneID: "America/New_York")))
        XCTAssertThrowsError(try ReminderPlanner.resolve(CivilReminderTime(year: 2027, month: 2, day: 30, hour: 12, minute: 0, timeZoneID: "UTC")))
        XCTAssertThrowsError(try ReminderPlanner.resolve(CivilReminderTime(year: 2027, month: 11, day: 7, hour: 1, minute: 30, timeZoneID: "America/New_York"))) { XCTAssertEqual($0 as? SurfaceError, .ambiguousCivilTime) }
        let a = try ReminderPlanner.resolve(CivilReminderTime(year: 2027, month: 11, day: 7, hour: 1, minute: 30, timeZoneID: "America/New_York", confirmedGMTOffset: -14400))
        let b = try ReminderPlanner.resolve(CivilReminderTime(year: 2027, month: 11, day: 7, hour: 1, minute: 30, timeZoneID: "America/New_York", confirmedGMTOffset: -18000))
        XCTAssertEqual(b.timeIntervalSince(a), 3600)
    }
    func testQuietHoursAndPastOrCutoffTimesNeverShiftSilently() throws {
        let quiet = try QuietHours(startMinute: 22*60, endMinute: 7*60)
        XCTAssertTrue(quiet.contains(hour: 23, minute: 0)); XCTAssertTrue(quiet.contains(hour: 6, minute: 59)); XCTAssertFalse(quiet.contains(hour: 7, minute: 0))
        let ordinary = try intent()
        XCTAssertThrowsError(try ReminderIntent(personaID: UUID(), targetID: UUID(), subject: .offer, sourceRevision: 1, routeHandle: .random(), localTime: ordinary.localTime, expiresAt: ordinary.fireAt, cutoff: ordinary.fireAt, language: .english, now: now))
        XCTAssertThrowsError(try ReminderIntent(personaID: UUID(), targetID: UUID(), subject: .deferral, sourceRevision: 1, routeHandle: .random(), localTime: ordinary.localTime, expiresAt: ordinary.expiresAt, quietHours: QuietHours(startMinute: 12*60, endMinute: 14*60), language: .english, now: now)) { XCTAssertEqual($0 as? SurfaceError, .quietHours) }
        XCTAssertThrowsError(try ordinary.validate(now: ordinary.fireAt))
    }
    func testLateOfferAlwaysOpensCurrentAwaitPickupWithoutFillClaim() throws {
        let value = try intent(), cutoff = now.addingTimeInterval(20)
        XCTAssertEqual(ReminderOpening.evaluate(intent: value, authorized: true, currentTargetID: value.targetID, currentCutoff: cutoff, now: cutoff), .awaitPickup(cutoff: cutoff))
        XCTAssertEqual(ReminderOpening.evaluate(intent: value, authorized: false, currentTargetID: value.targetID, currentCutoff: cutoff, now: cutoff), .unavailable)
        XCTAssertEqual(ReminderOpening.evaluate(intent: value, authorized: true, currentTargetID: nil, currentCutoff: cutoff, now: cutoff), .unavailable)
    }
    func testReminderSaveReplayAndStaleEditCannotResurrectCancellation() async throws {
        let store = try ReminderStore(url: file()), value = try intent()
        let a = try await store.put(value, expectedVersion: nil, now: now)
        let b = try await store.put(value, expectedVersion: nil, now: now); XCTAssertEqual(a, b)
        _ = try await store.cancel(value.id)
        do { _ = try await store.put(value, expectedVersion: nil, now: now); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .stale) }
        let stale = try await store.mark(value.id, version: a.version, status: .scheduled); XCTAssertFalse(stale)
    }
    func testPermissionDenialAndRetryAreTruthfulAndDoNotDuplicateID() async throws {
        let store = try ReminderStore(url: file()), fake = FakeScheduler(), value = try intent(), date = now
        let coordinator = ReminderCoordinator(store: store, scheduler: fake, now: { date })
        let first = try await coordinator.save(value, expectedVersion: nil, requestPermission: false); XCTAssertEqual(first.status, .permissionRequired)
        let calls = await fake.requestCalls; XCTAssertEqual(calls, 0)
        await fake.setPermission(.denied)
        let denied = try await coordinator.save(value, expectedVersion: first.version, requestPermission: false); XCTAssertEqual(denied.status, .denied)
        await fake.setPermission(.authorized); await fake.setFailure(true)
        let failed = try await coordinator.save(value, expectedVersion: first.version, requestPermission: false); XCTAssertEqual(failed.status, .retryNeeded)
        await fake.setFailure(false); try await coordinator.reconcileAll()
        let saved = try await store.get(value.id); XCTAssertEqual(saved?.status, .scheduled)
        let pending = await fake.pending; XCTAssertEqual(pending.count, 1)
    }
    func testElapsedOfferNoticesSurviveReconciliationUntilTurnOffOrPermissionLoss() async throws {
        let store = try ReminderStore(url: file()), scheduler = FakeScheduler(), date = now
        let delivered = try intent(), delayed = try intent()
        let deliveredID = ReminderNotification.identifier(delivered.id), delayedID = ReminderNotification.identifier(delayed.id)
        await scheduler.setPermission(.authorized)
        let original = ReminderCoordinator(store: store, scheduler: scheduler, now: { date })
        _ = try await original.save(delivered, expectedVersion: nil, requestPermission: true)
        _ = try await original.save(delayed, expectedVersion: nil, requestPermission: true)
        await scheduler.deliver(deliveredID)

        let atFire = ReminderCoordinator(store: store, scheduler: scheduler, now: { delivered.fireAt })
        try await atFire.reconcileAll()
        let afterCutoff = ReminderCoordinator(store: store, scheduler: scheduler, now: { delivered.expiresAt.addingTimeInterval(1) })
        try await afterCutoff.reconcileAll()
        let saved = try await store.all()
        let pending = await scheduler.pending, visible = await scheduler.delivered
        XCTAssertEqual(saved.map(\.status), [.expired, .expired])
        XCTAssertEqual(pending, [delayedID: ReminderNotification(delayed)])
        XCTAssertEqual(visible, [deliveredID: ReminderNotification(delivered)])

        try await afterCutoff.cancel(delivered.id)
        await scheduler.setPermission(.denied)
        try await afterCutoff.reconcileAll()
        let revokedPending = await scheduler.pending, cancelledVisible = await scheduler.delivered
        XCTAssertTrue(revokedPending.isEmpty)
        XCTAssertTrue(cancelledVisible.isEmpty)
    }
    func testElapsedDeferralNoticeIsRemovedAtItsExplicitExpiry() async throws {
        let store = try ReminderStore(url: file()), scheduler = FakeScheduler(), date = now, value = try intent(subject: .deferral)
        let id = ReminderNotification.identifier(value.id)
        await scheduler.setPermission(.authorized)
        let original = ReminderCoordinator(store: store, scheduler: scheduler, now: { date })
        _ = try await original.save(value, expectedVersion: nil, requestPermission: true)
        await scheduler.deliver(id)

        let atFire = ReminderCoordinator(store: store, scheduler: scheduler, now: { value.fireAt })
        try await atFire.reconcileAll()
        let beforeExpiry = await scheduler.delivered
        XCTAssertEqual(beforeExpiry[id], ReminderNotification(value))

        let atExpiry = ReminderCoordinator(store: store, scheduler: scheduler, now: { value.expiresAt })
        try await atExpiry.reconcileAll()
        let afterExpiry = await scheduler.delivered
        XCTAssertTrue(afterExpiry.isEmpty)
    }
    func testCancellationWhileOSAddWaitsCannotPublishStaleScheduledResult() async throws {
        let store = try ReminderStore(url: file()), fake = FakeScheduler(), value = try intent(), date = now
        await fake.setPermission(.authorized); await fake.blockNextAdd()
        let coordinator = ReminderCoordinator(store: store, scheduler: fake, now: { date })
        let save = Task { try await coordinator.save(value, expectedVersion: nil, requestPermission: false) }
        await fake.waitUntilAddEntered()
        let cancellation = Task { try await coordinator.cancel(value.id) }
        while try await store.get(value.id)?.status != .cancelled { await Task.yield() }
        await fake.releaseAdd()
        try await cancellation.value
        let final = try await save.value; XCTAssertEqual(final.status, .cancelled)
        let pending = await fake.pending; XCTAssertTrue(pending.isEmpty)
    }
    func testInvalidatedConfirmationCannotCancelNewerReminderVersion() async throws {
        let store = try ReminderStore(url: file()), scheduler = FakeScheduler(), date = now
        let value = try intent(), replacement = try intent(id: value.id, handle: value.routeHandle, day: 21)
        let authority = ReminderTestAuthorization()
        let coordinator = ReminderCoordinator(store: store, scheduler: scheduler, now: { date })
        await scheduler.setPermission(.authorized); await scheduler.blockNextAdd()
        let save = Task {
            try await coordinator.save(value, expectedVersion: nil, requestPermission: true, authorized: { await authority.valid })
        }
        await scheduler.waitUntilAddEntered()
        let newer = try await store.put(replacement, expectedVersion: 1, now: now)
        await authority.invalidate()
        await scheduler.releaseAdd()
        do { _ = try await save.value; XCTFail("The original confirmation lost authority") }
        catch { XCTAssertEqual(error as? SurfaceError, .stale) }
        try await coordinator.reconcileAll()
        let final = try await store.get(value.id)
        XCTAssertEqual(final?.version, newer.version)
        XCTAssertEqual(final?.intent, replacement)
        XCTAssertEqual(final?.status, .scheduled)
        let pending = await scheduler.pending
        XCTAssertEqual(Array(pending.values), [ReminderNotification(replacement)])
    }
    func testAutomaticReconciliationLeavesInFlightConfirmationToItsOwnAuthorization() async throws {
        let store = try ReminderStore(url: file()), scheduler = FakeScheduler(), value = try intent(), date = now
        let coordinator = ReminderCoordinator(store: store, scheduler: scheduler, now: { date })
        await scheduler.setPermission(.authorized); await scheduler.blockNextAdd()
        let confirmation = Task {
            try await coordinator.save(value, expectedVersion: nil, requestPermission: true, authorized: { true })
        }
        await scheduler.waitUntilAddEntered()
        let reconciled = expectation(description: "Automatic work does not wait for an in-flight confirmation")
        let reconciliation = Task { try await coordinator.reconcileAll(); reconciled.fulfill() }
        await fulfillment(of: [reconciled], timeout: 2)
        do {
            _ = try await coordinator.save(value, expectedVersion: 1, requestPermission: true, authorized: { true })
            XCTFail("Two independent confirmations cannot own the same in-flight version")
        } catch { XCTAssertEqual(error as? SurfaceError, .busy) }
        await scheduler.releaseAdd()
        try await reconciliation.value
        let original = try await confirmation.value
        XCTAssertEqual(original.status, .scheduled)
        let next = try await coordinator.save(value, expectedVersion: original.version, requestPermission: true, authorized: { true })
        XCTAssertEqual(next.version, original.version + 1)
        XCTAssertEqual(next.status, .scheduled)
    }
    func testSessionChangedReplayCannotReuseSuccessfulSave() async throws {
        let inbox = try SelectedTextInbox(url: file()), session = SelectedTextSession()
        _ = try await session.save(original: "12 wraps", edited: nil, now: now, inbox: inbox)
        do { _ = try await session.save(original: "24 wraps", edited: nil, now: now, inbox: inbox); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .changedReplay) }
        let rows = try await inbox.pending(now: now); XCTAssertEqual(rows.map(\.originalText), ["12 wraps"])
    }
    func testInboxCannotOpenPrivateReminderDatabase() async throws {
        let url = try file(); let store = try ReminderStore(url: url)
        _ = try await store.put(intent(), expectedVersion: nil, now: now)
        let before = try Data(contentsOf: url)
        XCTAssertThrowsError(try SelectedTextInbox(url: url))
        XCTAssertEqual(try Data(contentsOf: url), before)
    }
    func testWidgetFileRejectsCorruptionAndClearContainsOnlyGenericRoute() throws {
        let projectionFile = try WidgetProjectionFile(directory: file().deletingLastPathComponent())
        try projectionFile.publishAfterCommit(WidgetProjection(writtenAt: now, routeHandle: .random(), destination: .shoppingList))
        XCTAssertNotNil(try projectionFile.read().routeHandle)
        try projectionFile.clear(now: now); XCTAssertNil(try projectionFile.read().routeHandle)
        try Data("{not json".utf8).write(to: projectionFile.url)
        XCTAssertThrowsError(try projectionFile.read())
    }
    func testReminderCapacityAndPersonaCancellationKeepUnrelatedWork() async throws {
        let store = try ReminderStore(url: file()), fake = FakeScheduler(), date = now
        let coordinator = ReminderCoordinator(store: store, scheduler: fake, now: { date })
        let first = try intent(); _ = try await store.put(first, expectedVersion: nil, now: now)
        for _ in 1..<ReminderStore.maximumActive { _ = try await store.put(intent(), expectedVersion: nil, now: now) }
        do { _ = try await store.put(intent(), expectedVersion: nil, now: now); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .capacity) }
        try await coordinator.cancelAll(personaID: first.personaID)
        let rows = try await store.all(); XCTAssertEqual(rows.filter { $0.status == .cancelled }.count, 1)
        _ = try await store.put(intent(), expectedVersion: nil, now: now)
    }
    func testErasureCancelsOSRegistrationAndRemovesPrivateMetadataIdempotently() async throws {
        let store = try ReminderStore(url: file()), scheduler = FakeScheduler(), date = now, value = try intent()
        await scheduler.setPermission(.authorized)
        let coordinator = ReminderCoordinator(store: store, scheduler: scheduler, now: { date })
        _ = try await coordinator.save(value, expectedVersion: nil, requestPermission: false)
        try await coordinator.erase(value.id); try await coordinator.erase(value.id)
        let row = try await store.get(value.id); XCTAssertNil(row)
        let pending = await scheduler.pending; XCTAssertTrue(pending.isEmpty)
    }
    func testErasureRejectsUncancelledOrStaleVersion() async throws {
        let store = try ReminderStore(url: file()), value = try intent()
        let saved = try await store.put(value, expectedVersion: nil, now: now)
        do { try await store.eraseCancelled(value.id, version: saved.version); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .stale) }
        let cancelled = try await store.cancel(value.id)
        do { try await store.eraseCancelled(value.id, version: saved.version); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .stale) }
        try await store.eraseCancelled(value.id, version: try XCTUnwrap(cancelled).version)
        let absent = try await store.get(value.id); XCTAssertNil(absent)
    }

    func testErasureReceiptRejectsLateInitialSaveAcrossRestartAndAbsentRow() async throws {
        let url = try file(), store = try ReminderStore(url: url), scheduler = FakeScheduler(), date = now, value = try intent()
        let coordinator = ReminderCoordinator(store: store, scheduler: scheduler, now: { date })
        try await coordinator.erase(value.id)
        let reopened = try ReminderStore(url: url)
        do { _ = try await reopened.put(value, expectedVersion: nil, now: now); XCTFail() } catch { XCTAssertEqual(error as? SurfaceError, .stale) }
        let rows = try await reopened.all(); XCTAssertTrue(rows.isEmpty)
        let connection = try SurfaceDatabase(url: url, kind: "private-reminders", schema: "")
        let retirement = try connection.rows("SELECT * FROM reminder_retirements")
        XCTAssertEqual(retirement, [[value.id.uuidString]])
    }
    func testRetirementMigrationProtectsLegacyWriterWithoutKeepingPrivateBody() async throws {
        let url = try file(), value = try intent()
        let legacy = try SurfaceDatabase(url: url, kind: "private-reminders", schema: "CREATE TABLE reminders(id TEXT PRIMARY KEY NOT NULL, version INTEGER NOT NULL, body TEXT NOT NULL, status TEXT NOT NULL);")
        let store = try ReminderStore(url: url)
        let row = try await store.put(value, expectedVersion: nil, now: now)
        let cancelled = try await store.cancel(value.id)
        try await store.eraseCancelled(value.id, version: try XCTUnwrap(cancelled).version)
        let body = String(data: try canonical(value), encoding: .utf8)!
        XCTAssertThrowsError(try legacy.execute("INSERT INTO reminders VALUES(?,?,?,?)", [.text(value.id.uuidString), .integer(row.version), .text(body), .text("desired")]))
        XCTAssertTrue(try legacy.rows("SELECT body FROM reminders").isEmpty)
    }

}

private actor ReminderTestAuthorization {
    private(set) var valid = true
    func invalidate() { valid = false }
}

actor FakeScheduler: NotificationScheduling {
    var authorization: NotificationPermission = .unknown
    var pending: [String: ReminderNotification] = [:]
    var delivered: [String: ReminderNotification] = [:]
    var requestCalls = 0
    var failure = false
    var shouldBlock = false
    var entered = false
    var waiter: CheckedContinuation<Void, Never>?
    func permission() -> NotificationPermission { authorization }
    func requestPermission() -> Bool { requestCalls += 1; return authorization == .authorized }
    func setPermission(_ value: NotificationPermission) { authorization = value }
    func setFailure(_ value: Bool) { failure = value }
    func blockNextAdd() { shouldBlock = true }
    func waitUntilAddEntered() async { while !entered { await Task.yield() } }
    func releaseAdd() { waiter?.resume(); waiter = nil }
    func add(_ notification: ReminderNotification) async throws {
        if shouldBlock { shouldBlock = false; entered = true; await withCheckedContinuation { waiter = $0 } }
        if failure { throw SurfaceError.unavailable }
        pending[notification.identifier] = notification
    }
    func deliver(_ id: String) { delivered[id] = pending.removeValue(forKey: id) }
    func remove(_ identifiers: [String]) {
        for id in identifiers { pending.removeValue(forKey: id); delivered.removeValue(forKey: id) }
    }
}
