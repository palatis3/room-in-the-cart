import Foundation
import Combine
import HouseholdClient

enum DeviceManagementCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "DeviceManagement") }
}
struct DeviceManagementScope: Equatable {
    let subject: String
    let householdID: String
    let memberID: String
    let generation: UUID
    func matches(_ intent: DeviceRevocationIntent) -> Bool {
        subject == intent.subject && householdID == intent.householdID && memberID == intent.memberID
    }
}
protocol HouseholdDeviceServing: Sendable {
    func managedDevices(cursor: String?) async throws -> HouseholdDevicePage
    func prepareDeviceRevocation(_ device: ManagedHouseholdDevice) async throws -> DeviceRevocationIntent
    func authorizeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws
    func executeDeviceRevocation(_ intent: DeviceRevocationIntent) async throws -> DeviceRevocationReceipt
}
extension HouseholdService: HouseholdDeviceServing {}

@MainActor final class HouseholdDevicesModel: ObservableObject {
    let scope: DeviceManagementScope
    private let service: any HouseholdDeviceServing
    private let store: DeviceRevocationStore
    private let runtime: () -> DeviceManagementScope?
    private let accessEnded: @MainActor () async -> Void
    private var generation = UUID()
    private var epoch: UUID?
    @Published private(set) var devices: [ManagedHouseholdDevice] = []
    @Published private(set) var inventoryScope: String?
    @Published private(set) var nextCursor: String?
    @Published private(set) var pending: DeviceRevocationIntent?
    @Published private(set) var busy = false
    @Published private(set) var message: String?
    @Published private(set) var confirmedDeviceID: String?
    @Published private(set) var blocked = false
    @Published private(set) var suspended = false
    init(scope: DeviceManagementScope, service: any HouseholdDeviceServing, store: DeviceRevocationStore,
         runtime: @escaping () -> DeviceManagementScope?, accessEnded: @escaping @MainActor () async -> Void) {
        self.scope = scope; self.service = service; self.store = store; self.runtime = runtime; self.accessEnded = accessEnded
    }
    var live: Bool { runtime() == scope }
    func invalidate() {
        generation = UUID(); epoch = nil; devices = []; inventoryScope = nil; nextCursor = nil
        pending = nil; message = nil; confirmedDeviceID = nil; busy = false; blocked = true
    }
    func suspend() {
        generation = UUID(); epoch = nil; devices = []; inventoryScope = nil; nextCursor = nil
        pending = nil; message = nil; confirmedDeviceID = nil; busy = false; suspended = true
    }
    func resume() async {
        guard live, !blocked else { return }
        suspended = false; await load()
    }
    private func current(_ start: UUID) -> Bool { live && generation == start }
    func load(more: Bool = false) async {
        guard live, !suspended, !busy, !blocked, !more || nextCursor != nil else { return }
        let start = generation, cursor = more ? nextCursor : nil
        busy = true; message = nil; if !more { devices = []; inventoryScope = nil; nextCursor = nil }
        defer { if current(start) { busy = false } }
        do {
            let page = try await service.managedDevices(cursor: cursor)
            guard current(start) else { return }; try page.validate(cursor: cursor)
            if more {
                guard page.scope == inventoryScope, Set(devices.map(\.id)).isDisjoint(with: page.devices.map(\.id)) else { throw ClientError.invalidResponse }
                devices += page.devices
            } else { devices = page.devices; inventoryScope = page.scope }
            nextCursor = page.nextCursor
            let epoch = await store.epoch(), saved = try await store.read()
            guard current(start) else { return }; self.epoch = epoch; pending = nil
            if let saved, scope.matches(saved) {
                try await service.authorizeDeviceRevocation(saved)
                guard current(start) else { return }; pending = saved
            } else if saved != nil {
                // A different account's pending target is never shown or rebound.
                blocked = true; devices = []; nextCursor = nil
                message = DeviceManagementCopy.text("A saved device action belongs to another account or household. Return to that account to reconcile it.")
            }
        } catch { if current(start) { await fail(error) } }
    }
    func revoke(_ device: ManagedHouseholdDevice) async {
        guard live, !suspended, !busy, !blocked, pending == nil, let epoch, !device.isCurrentDevice, device.revokedAt == nil,
              devices.contains(device) else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do {
            let intent = try await service.prepareDeviceRevocation(device)
            guard current(start), scope.matches(intent) else { return }
            try await store.save(intent, epoch: epoch)
            guard current(start) else { return }; pending = intent
            try await send(intent, epoch: epoch, start: start)
        } catch { if current(start) { await fail(error) } }
    }
    func retry() async {
        guard live, !suspended, !busy, !blocked, let pending, let epoch else { return }
        let start = generation; busy = true; message = nil
        defer { if current(start) { busy = false } }
        do { try await send(pending, epoch: epoch, start: start) }
        catch { if current(start) { await fail(error) } }
    }
    private func send(_ intent: DeviceRevocationIntent, epoch: UUID, start: UUID) async throws {
        guard await store.epoch() == epoch, current(start) else { throw ClientError.cancelled }
        let receipt = try await service.executeDeviceRevocation(intent)
        guard current(start) else { return }
        guard receipt.revoked, receipt.deviceId == intent.targetDeviceID, receipt.memberId == intent.targetMemberID else { throw ClientError.invalidResponse }
        try await store.remove(intent, epoch: epoch)
        guard current(start) else { return }
        pending = nil; confirmedDeviceID = receipt.deviceId
        devices = []; nextCursor = nil
        message = DeviceManagementCopy.text("Device access was revoked. Refresh devices to review current access.")
    }
    private func fail(_ error: Error) async {
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded:
            invalidate(); await accessEnded()
        case .cancelled: break
        case .service(let status, _, _, _) where status == 404:
            devices = []; nextCursor = nil
            message = DeviceManagementCopy.text("These devices are no longer available to this account. Refresh current access.")
        default:
            message = pending == nil ? DeviceManagementCopy.text("Devices could not be loaded or the action could not be saved. Try again.") :
                DeviceManagementCopy.text("The result is not confirmed. Retry the same device action to confirm whether access ended.")
        }
    }
}
