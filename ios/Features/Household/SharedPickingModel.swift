import Foundation
import HouseholdClient
import SwiftUI

func householdTripText(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "TripCoordination") }

struct ScopedSharedPick: PendingShopWrite {
    let subject: String
    let intent: SharedPickIntent

    func validate() throws {
        let op = intent.operation
        guard !subject.isEmpty, op.expectedRevision >= 0, intent.expiresAt.timeIntervalSince1970.isFinite else { throw ClientError.configuration }
        switch op.action {
        case .claim: guard op.packs == nil, op.undoOperationId == nil else { throw ClientError.configuration }
        case .pick: guard let packs = op.packs, (1...10_000).contains(packs), op.undoOperationId == nil else { throw ClientError.configuration }
        case .undo: guard op.packs == nil, op.undoOperationId != nil else { throw ClientError.configuration }
        }
    }

    func sharesScope(with other: Self) -> Bool {
        subject == other.subject && intent.householdID == other.intent.householdID && intent.shopID == other.intent.shopID &&
        intent.operation.actorId == other.intent.operation.actorId && intent.operation.deviceId == other.intent.operation.deviceId &&
        intent.operation.permissionId == other.intent.operation.permissionId && intent.operation.rowId == other.intent.operation.rowId
    }

    func belongs(to householdID: String, subject: String) -> Bool {
        intent.householdID == UUID(uuidString: householdID) && self.subject == subject
    }
}

@MainActor final class SharedPickingModel: ObservableObject {
    @Published private(set) var page: SharedPickingPage?
    @Published private(set) var pending = [ScopedSharedPick]()
    @Published private(set) var busy = false
    @Published private(set) var notice: String?
    private weak var household: HouseholdModel?
    private let scope: AdultRequestViewScope
    private var life = UUID()
    private var session: AdultShopRequestSession?
    private var readFailed = false
    init(household: HouseholdModel, scope: AdultRequestViewScope) {
        self.household = household
        self.scope = scope
    }
    var member: UUID? { UUID(uuidString: scope.member) }
    private func current(_ token: UUID) -> Bool {
        life == token && household?.adultRequestScope(shop: scope.shop, capability: "shared_picking") == scope
    }

    func close() {
        life = UUID()
        page = nil
        pending = []
        session = nil
        readFailed = false
        notice = nil
        busy = false
    }
    func expire() async {
        guard let expiry = page?.expiry, expiry <= Date() else { return }
        close()
        notice = householdTripText("Picking permission has expired.")
        try? await household?.pickingPendingStore.retain { $0.intent.expiresAt > Date() }
    }
    private func accept(_ next: SharedPickingPage, session: AdultShopRequestSession, token: UUID) async throws {
        guard let store = household?.pickingPendingStore, current(token) else { throw ClientError.cancelled }
        let subject = scope.subject
        let rows = Set(next.rows.map(\.id))
        let writes = try await store.read()
        guard current(token) else { throw ClientError.cancelled }
        let lostRow = writes.contains {
            $0.subject == subject && $0.intent.matches(session) &&
            ($0.intent.operation.permissionId != next.permissionId || !rows.contains($0.intent.operation.rowId))
        }
        try await store.retain { write in
            guard write.subject == subject, write.intent.householdID == session.device.householdID,
                  write.intent.operation.actorId == session.device.memberID, write.intent.operation.deviceId == session.device.deviceID,
                  write.intent.expiresAt > Date() else { return false }
            return write.intent.shopID != session.shopID ||
                (write.intent.operation.permissionId == next.permissionId && rows.contains(write.intent.operation.rowId))
        }
        let restored = try await store.read()
        guard current(token), next.expiry.map({ $0 > Date() }) ?? true else { throw ClientError.cancelled }
        pending = restored.filter { $0.subject == subject && $0.intent.matches(session) && $0.intent.operation.permissionId == next.permissionId }
        self.session = session
        page = next
        if lostRow {
            notice = householdTripText("Sharing changed. Your earlier pending change was retired.")
        } else if readFailed { notice = nil }
        readFailed = false
    }

    func refresh() async {
        guard !busy, let household, let service = household.service, let projection = household.projection else { return }
        let token = life
        guard current(token) else { return }
        busy = true
        defer { if current(token) { busy = false } }
        do {
            try await household.pickingPendingStore.retain { $0.intent.expiresAt > Date() }
            guard current(token) else { return }
            let session = try await service.adultShopRequestSession(projection, shopID: scope.shop)
            let next = try await service.sharedPicking(in: session)
            guard current(token) else { return }
            try await accept(next, session: session, token: token)
            // After a dropped response the revision can already have advanced. Only the exact original operation resolves it.
            for write in pending {
                guard current(token), write.intent.matches(session) else { return }
                try await submit(write, service: service, session: session, token: token)
            }
        } catch { await failed(error, token: token) }
    }

    func pick(_ action: SharedPickAction, row: SharedPickingPage.Row, packs: Int? = nil) async {
        guard !busy, let session, let household, let service = household.service, let page,
              !pending.contains(where: { $0.intent.operation.rowId == row.id }) else { return }
        let token = life
        guard current(token) else { return }
        busy = true
        defer { if current(token) { busy = false } }
        do {
            let write = ScopedSharedPick(subject: scope.subject, intent: try SharedPickIntent(page: page, row: row, in: session, action: action, packs: packs))
            let store = household.pickingPendingStore
            let epoch = await store.epoch()
            guard current(token) else { return }
            try await store.save(write, expectedEpoch: epoch)
            guard current(token) else { return }
            pending.append(write)
            try await submit(write, service: service, session: session, token: token)
        } catch { await failed(error, token: token) }
    }

    private func submit(_ write: ScopedSharedPick, service: HouseholdService, session: AdultShopRequestSession, token: UUID) async throws {
        guard let store = household?.pickingPendingStore, current(token) else { throw ClientError.cancelled }
        let epoch = await store.epoch()
        guard current(token), write.intent.matches(session) else { throw ClientError.cancelled }
        do {
            _ = try await service.applySharedPick(write.intent, in: session)
            guard current(token) else { throw ClientError.cancelled }
            // Keep the row disabled until its current server projection is visible.
            let next = try await service.sharedPicking(in: session)
            guard current(token) else { throw ClientError.cancelled }
            try await store.complete(write, expectedEpoch: epoch)
            try await accept(next, session: session, token: token)
            notice = householdTripText("Confirmed by the household.")
        } catch ClientError.service(let status, _, _, _) where status == 409 {
            // Read current quantities and names before retiring a stale pick, including after an uncertain response.
            let next = try await service.sharedPicking(in: session)
            guard current(token) else { throw ClientError.cancelled }
            try await store.complete(write, expectedEpoch: epoch)
            try await accept(next, session: session, token: token)
            if let row = next.rows.first(where: { $0.id == write.intent.operation.rowId }), row.picked > 0 {
                notice = householdTripText("The row changed. The picked count already includes the other shopper’s work. Your pending change was not added.")
            } else { notice = householdTripText("The row changed. Review the current row before trying again.") }
        }
    }

    func setPermission(recipient: UUID?, rowIDs: Set<UUID>, until: Date?) async {
        guard !busy, let service = household?.service, let page, let session else { return }
        let token = life
        guard current(token) else { return }
        busy = true
        defer { if current(token) { busy = false } }
        do {
            let next = try await service.setSharedPicking(recipient: recipient, lineIDs: rowIDs, until: until, reviewed: page, in: session, key: UUID())
            guard current(token) else { return }
            try await accept(next, session: session, token: token)
            notice = recipient == nil ? householdTripText("Sharing ended.") : householdTripText("Selected rows shared.")
        } catch { await failed(error, token: token) }
    }

    private func failed(_ error: Error, token: UUID) async {
        guard current(token) else { return }
        if let message = sharedPublicationNotice(error) { notice = message; return }
        readFailed = true
        switch error as? ClientError {
        case .accessEnded, .sessionNeeded:
            close()
            await household?.endTripDeviceAccess(error as? ClientError ?? .accessEnded, reviewed: scope)
        case .invalidResponse:
            // A lost or malformed receipt can follow a committed operation. Keep its ID for the next authorized read.
            close()
            readFailed = true
            notice = householdTripText("Refresh to check the current shared rows.")
        case .service(403, _, _, _), .service(404, _, _, _), .service(410, _, _, _):
            close()
            readFailed = true
            notice = householdTripText("Shared rows are no longer available for this shop.")
            let subject = scope.subject, shop = scope.shop, member = UUID(uuidString: scope.member)
            try? await household?.pickingPendingStore.retain {
                !($0.subject == subject && $0.intent.shopID == shop && $0.intent.operation.actorId == member)
            }
        case .transport:
            if let expiry = page?.expiry, expiry <= Date() { await expire(); return }
            if pending.isEmpty { notice = page == nil ? householdTripText("Connect to check shared picking access.") : householdTripText("Offline. Showing the last shared rows.") }
            else { notice = householdTripText("Pending. Changes will retry when the shared rows reconnect.") }
        case .cancelled: break
        default:
            notice = householdTripText("Refresh to check the current shared rows.")
        }
    }
}
