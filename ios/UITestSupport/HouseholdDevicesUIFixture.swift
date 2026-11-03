#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import HouseholdClient

private enum DeviceUIFixture {
    static let household = "30000000-0000-4000-8000-000000000001"
    static let mia = "30000000-0000-4000-8000-000000000002"
    static let alex = "30000000-0000-4000-8000-000000000003"
    static let current = "30000000-0000-4000-8000-000000000004"
    static let target = "30000000-0000-4000-8000-000000000005"
    static let sibling = "30000000-0000-4000-8000-000000000006"
    static func decode<T: Decodable>(_ value: Any, as type: T.Type = T.self) throws -> T {
        try JSONDecoder().decode(type, from: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]))
    }
}
/// Fictional, device-only service. No provider or HTTP transport is created.
private actor DeviceUIFixtureService: HouseholdDeviceServing {
    private let scope: DeviceManagementScope
    private var writes = 0
    private var revoked = false
    private var changed: (@Sendable (String) async -> Void)?
    init(scope: DeviceManagementScope) { self.scope = scope }
    func onChange(_ action: @escaping @Sendable (String) async -> Void) { changed = action }
    func managedDevices(cursor: String?) async throws -> HouseholdDevicePage {
        let ids = cursor == nil ? [DeviceUIFixture.current, DeviceUIFixture.target] : [DeviceUIFixture.sibling]
        let rows: [[String: Any]] = ids.map { id in
            ["deviceId": id, "memberId": id == DeviceUIFixture.current ? DeviceUIFixture.mia : DeviceUIFixture.alex,
             "memberAlias": id == DeviceUIFixture.current ? "Mia" : "Alex", "memberKind": "adult",
             "createdAt": id == DeviceUIFixture.sibling ? "2026-11-02T12:00:00.000Z" : "2026-11-01T12:00:00.000Z",
             "revokedAt": revoked && id == DeviceUIFixture.target ? "2026-11-03T12:00:00.000Z" : NSNull(),
             "isCurrentDevice": id == DeviceUIFixture.current]
        }
        return try DeviceUIFixture.decode(["scope": "household", "devices": rows, "nextCursor": cursor == nil ? DeviceUIFixture.target as Any : NSNull()])
    }
    func prepareDeviceRevocation(_ device: ManagedHouseholdDevice) async throws -> DeviceRevocationIntent {
        guard device.deviceId == DeviceUIFixture.target || device.deviceId == DeviceUIFixture.sibling,
              !device.isCurrentDevice else { throw ClientError.configuration }
        let body = try JSONSerialization.data(withJSONObject: ["memberId": device.memberId], options: [.sortedKeys])
        let value: DeviceRevocationIntent = try DeviceUIFixture.decode([
            "subject": scope.subject, "householdID": scope.householdID, "memberID": scope.memberID, "deviceID": DeviceUIFixture.current,
            "targetDeviceID": device.deviceId, "targetMemberID": device.memberId, "bytes": body.base64EncodedString()])
        try value.validate(); return value
    }
    func authorizeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws {
        guard scope.matches(intent), intent.deviceID == DeviceUIFixture.current else { throw ClientError.accessEnded }
    }
    func executeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws -> DeviceRevocationReceipt {
        try await authorizeDeviceRevocation(intent)
        guard intent.targetDeviceID == DeviceUIFixture.target, intent.targetMemberID == DeviceUIFixture.alex else { throw ClientError.configuration }
        writes += 1; revoked = true
        await changed?("writes=\(writes);current=active;target=revoked;sibling=active;membership=active;shopper=Mia")
        return try DeviceUIFixture.decode(["deviceId": intent.targetDeviceID, "memberId": intent.targetMemberID,
                                          "revoked": true, "revokedAt": "2026-11-03T12:00:00.000Z"])
    }
}
@MainActor private final class DeviceUIFixtureHarness: ObservableObject {
    @Published var summary = "writes=0;current=active;target=active;sibling=active;membership=active;shopper=Mia"
    var model: HouseholdDevicesModel!
    let service: DeviceUIFixtureService
    private let scope: DeviceManagementScope
    init() {
        scope = .init(subject: "fictional-device-manager", householdID: DeviceUIFixture.household, memberID: DeviceUIFixture.mia, generation: UUID())
        service = .init(scope: scope)
        let store = DeviceRevocationStore(url: FileManager.default.temporaryDirectory.appendingPathComponent("device-ui-fixture-\(UUID().uuidString)/pending.json"))
        model = HouseholdDevicesModel(scope: scope, service: service, store: store, runtime: { [weak self] in self?.scope }, accessEnded: {})
    }
    func observe() async {
        await service.onChange { [weak self] value in await self?.setSummary(value) }
    }
    private func setSummary(_ value: String) { summary = value }
}
struct HouseholdDevicesFixtureRoot: View {
    @StateObject private var harness = DeviceUIFixtureHarness()
    var body: some View {
        NavigationStack {
            HouseholdDevicesView(model: harness.model)
                .safeAreaInset(edge: .bottom) {
                    Text(harness.summary).font(.caption2).dynamicTypeSize(.small).accessibilityIdentifier("household.devices.fixtureSummary")
                        .padding(4).frame(maxWidth: .infinity).background(.regularMaterial)
                }
        }
        .environment(\.dynamicTypeSize, ProcessInfo.processInfo.arguments.contains("--device-fixture-largest-text") ? .accessibility5 : .large)
        .task { await harness.observe() }
    }
}
#endif
