import XCTest
import HouseholdClient
@testable import RoomInTheCart

private enum DeviceModelFixture {
    static let household = "20000000-0000-4000-8000-000000000001"
    static let member = "20000000-0000-4000-8000-000000000002"
    static let device = "20000000-0000-4000-8000-000000000003"
    static let target = "20000000-0000-4000-8000-000000000004"
    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
    static func row(current: Bool = false) throws -> ManagedHouseholdDevice {
        try decode(["deviceId": current ? device : target, "memberId": member, "memberAlias": "Mia", "memberKind": "adult",
                    "createdAt": "2026-11-03T12:00:00.000Z", "revokedAt": NSNull(), "isCurrentDevice": current])
    }
    static func page() throws -> HouseholdDevicePage {
        try decode(["scope": "household", "devices": [JSONSerialization.jsonObject(with: JSONEncoder().encode(row()))], "nextCursor": NSNull()])
    }
    static func intent(_ scope: DeviceManagementScope, targetID: String = target) throws -> DeviceRevocationIntent {
        let bytes = try JSONSerialization.data(withJSONObject: ["memberId": member], options: [.sortedKeys])
        let value: DeviceRevocationIntent = try decode(["subject": scope.subject, "householdID": scope.householdID, "memberID": scope.memberID, "deviceID": device,
            "targetDeviceID": targetID, "targetMemberID": member, "bytes": bytes.base64EncodedString()])
        try value.validate(); return value
    }
}
private actor DeviceModelService: HouseholdDeviceServing {
    let scope: DeviceManagementScope
    var loss = false
    var denied = false
    var sent: [DeviceRevocationIntent] = []
    var onRead: (@Sendable () async -> Void)?
    var onPrepare: (@Sendable () async -> Void)?
    var onSend: (@Sendable () async -> Void)?
    init(scope: DeviceManagementScope) { self.scope = scope }
    func setLoss(_ value: Bool) { loss = value }
    func setDenied() { denied = true }
    func setOnRead(_ action: @escaping @Sendable () async -> Void) { onRead = action }
    func setOnPrepare(_ action: @escaping @Sendable () async -> Void) { onPrepare = action }
    func setOnSend(_ action: @escaping @Sendable () async -> Void) { onSend = action }
    func managedDevices(cursor: String?) async throws -> HouseholdDevicePage {
        if let onRead { await onRead() }; if denied { throw ClientError.accessEnded }; return try DeviceModelFixture.page()
    }
    func prepareDeviceRevocation(_ device: ManagedHouseholdDevice) async throws -> DeviceRevocationIntent {
        if let onPrepare { await onPrepare() }; return try DeviceModelFixture.intent(scope)
    }
    func authorizeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws { if denied { throw ClientError.accessEnded } }
    func executeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws -> DeviceRevocationReceipt {
        if let onSend { await onSend() }; sent.append(intent)
        if denied { throw ClientError.accessEnded }; if loss { throw ClientError.transport }
        return try DeviceModelFixture.decode(["deviceId": intent.targetDeviceID, "memberId": intent.targetMemberID, "revoked": true, "revokedAt": "2026-11-03T12:01:00.000Z"])
    }
    func sentIntents() -> [DeviceRevocationIntent] { sent }
}
@MainActor private final class DeviceRuntime {
    var scope: DeviceManagementScope?
    var ended = 0
    init(_ scope: DeviceManagementScope) { self.scope = scope }
}

@MainActor final class HouseholdDevicesTests: XCTestCase {
    private var temporaryDirectories: [URL] = []
    override func tearDown() { temporaryDirectories.forEach { try? FileManager.default.removeItem(at: $0) }; temporaryDirectories = []; super.tearDown() }
    private func fixture() -> (HouseholdDevicesModel, DeviceModelService, DeviceRevocationStore, DeviceRuntime) {
        let scope = DeviceManagementScope(subject: "device-account", householdID: DeviceModelFixture.household, memberID: DeviceModelFixture.member, generation: UUID())
        let service = DeviceModelService(scope: scope), runtime = DeviceRuntime(scope)
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString); temporaryDirectories.append(dir)
        let store = DeviceRevocationStore(url: dir.appendingPathComponent("pending.json"))
        let model = HouseholdDevicesModel(scope: scope, service: service, store: store, runtime: { runtime.scope }, accessEnded: { runtime.ended += 1; runtime.scope = nil })
        return (model, service, store, runtime)
    }
    func testLostResponseRetainsExactIntentAndFreshModelReconcilesSameTarget() async throws {
        let (model, service, store, runtime) = fixture(); await service.setLoss(true)
        await model.load(); await model.revoke(try DeviceModelFixture.row())
        let intent = try XCTUnwrap(model.pending); XCTAssertEqual(intent.targetDeviceID, DeviceModelFixture.target)
        let saved = try await store.read(); XCTAssertEqual(saved, intent)
        let restored = HouseholdDevicesModel(scope: model.scope, service: service, store: store, runtime: { runtime.scope }, accessEnded: {})
        await restored.load(); XCTAssertEqual(restored.pending, intent)
        await service.setLoss(false); await restored.retry()
        XCTAssertNil(restored.pending); XCTAssertEqual(restored.confirmedDeviceID, DeviceModelFixture.target)
        let calls = await service.sentIntents(); XCTAssertEqual(calls, [intent, intent])
        let after = try await store.read(); XCTAssertNil(after)
    }
    func testScopeChangeDuringInventoryOrPreparationCannotExposeRowsOrSend() async throws {
        let (model, service, _, runtime) = fixture()
        await service.setOnRead { await MainActor.run { runtime.scope = nil } }
        await model.load(); XCTAssertTrue(model.devices.isEmpty)
        let (other, otherService, store, otherRuntime) = fixture(); await other.load()
        await otherService.setOnPrepare { await MainActor.run { otherRuntime.scope = nil } }
        await other.revoke(try DeviceModelFixture.row())
        let calls = await otherService.sentIntents(), saved = try await store.read(); XCTAssertTrue(calls.isEmpty); XCTAssertNil(saved)
    }
    func testBackgroundClearsProtectedRowsAndResumesWithSameAuthorizedRetry() async throws {
        let (model, service, _, _) = fixture(); await service.setLoss(true)
        await model.load(); await model.revoke(try DeviceModelFixture.row()); XCTAssertNotNil(model.pending)
        model.suspend(); XCTAssertTrue(model.devices.isEmpty); XCTAssertNil(model.pending); XCTAssertTrue(model.suspended)
        await model.retry(); let before = await service.sentIntents(); XCTAssertEqual(before.count, 1)
        await model.resume(); XCTAssertFalse(model.suspended); XCTAssertNotNil(model.pending)
        await service.setLoss(false); await model.retry(); XCTAssertNil(model.pending)
    }
    func testRevokedContextDropsInventoryAndPendingWithoutShowingPriorReceipt() async throws {
        let (model, service, _, runtime) = fixture(); await model.load(); XCTAssertEqual(model.devices.count, 1)
        await service.setDenied(); await model.load()
        XCTAssertEqual(runtime.ended, 1); XCTAssertTrue(model.devices.isEmpty); XCTAssertNil(model.pending); XCTAssertNil(model.confirmedDeviceID)
        await model.retry(); let calls = await service.sentIntents(); XCTAssertTrue(calls.isEmpty)
    }
    func testPurgeDuringSendCannotResurrectReceiptOrPendingAction() async throws {
        let (model, service, store, runtime) = fixture(); await model.load()
        await service.setOnSend {
            await MainActor.run { runtime.scope = nil; model.invalidate() }
            try? await store.purge(householdID: DeviceModelFixture.household, subject: "device-account")
        }
        await model.revoke(try DeviceModelFixture.row())
        XCTAssertNil(model.pending); XCTAssertNil(model.confirmedDeviceID)
        let after = try await store.read(); XCTAssertNil(after)
    }
    func testCurrentDeviceAndUnlistedTargetNeverSend() async throws {
        let (model, service, _, _) = fixture(); await model.load()
        await model.revoke(try DeviceModelFixture.row(current: true)); let calls = await service.sentIntents(); XCTAssertTrue(calls.isEmpty)
    }
    func testScopedPurgeInvalidatesAlreadyPreparedRetryBeforeTransmission() async throws {
        let (model, service, store, _) = fixture(); await service.setLoss(true)
        await model.load(); await model.revoke(try DeviceModelFixture.row()); XCTAssertNotNil(model.pending)
        try await store.purge(householdID: DeviceModelFixture.household, subject: "device-account")
        await model.retry(); let calls = await service.sentIntents(); XCTAssertEqual(calls.count, 1)
        await model.load(); XCTAssertNil(model.pending)
    }
}
