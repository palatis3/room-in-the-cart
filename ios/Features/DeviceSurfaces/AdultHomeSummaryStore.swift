import Foundation
import SwiftUI
import WidgetKit
import DeviceSurfaces
import CoreDomain

/// Only this app-private receipt associates a widget opt-in and its current route with a person.
@MainActor final class AdultHomeSummaryStore: ObservableObject {
    struct Consent: Codable {
        let origin: UUID
        let owner: String
        let token: UUID
        var projection: AdultFoodSummaryProjection?
        var tonightBasis: TonightHomeBasis?
        var reviewedLedger: UUID?
        var includesPlannedDinners: Bool?
        func belongs(to scope: PantryDigestScope) -> Bool { origin == scope.origin && owner == scope.owner }
    }

    static let shared: AdultHomeSummaryStore = {
        #if DEBUG
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil {
            let testRoot = FileManager.default.temporaryDirectory.appendingPathComponent("AdultHomeTests-" + UUID().uuidString)
            return AdultHomeSummaryStore(directory: testRoot.appendingPathComponent("private"),
                widgetDirectory: { testRoot.appendingPathComponent("widget") }, reload: { _ in })
        }
        #endif
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let runtime = SurfaceRuntimeIsolation(directory: nil, launchArguments: ProcessInfo.processInfo.arguments, applicationSupport: support)
        return AdultHomeSummaryStore(directory: runtime.directory.appendingPathComponent("AdultHome"),
            widgetDirectory: {
                if runtime.isUITesting { return runtime.directory.appendingPathComponent("TestWidget") }
                return try IOSSurfaceContainers.directory(groupKey: SurfaceInfo.widgetGroupKey)
            }, reload: { kind in runtime.performSystemEffect { WidgetCenter.shared.reloadTimelines(ofKind: kind.widgetKind) } })
    }()

    @Published private(set) var generation = UUID()
    private let directory: URL
    private let widgetDirectory: () throws -> URL
    private let reload: (AdultFoodSummaryKind) -> Void
    init(directory: URL, widgetDirectory: @escaping () throws -> URL, reload: @escaping (AdultFoodSummaryKind) -> Void) {
        self.directory = directory; self.widgetDirectory = widgetDirectory; self.reload = reload
    }
    private func url(_ kind: AdultFoodSummaryKind) -> URL { directory.appendingPathComponent(kind.rawValue + ".json") }
    private func file(_ kind: AdultFoodSummaryKind) throws -> AdultFoodSummaryFile {
        try AdultFoodSummaryFile(directory: widgetDirectory(), kind: kind)
    }
    private func consent(_ kind: AdultFoodSummaryKind) throws -> Consent? {
        guard FileManager.default.fileExists(atPath: url(kind).path) else { return nil }
        return try JSONDecoder().decode(Consent.self, from: readRegularFile(at: url(kind), maximumBytes: 4096))
    }
    private func persist(_ receipt: Consent, _ kind: AdultFoodSummaryKind) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        try JSONEncoder().encode(receipt).write(to: url(kind), options: [.atomic, .completeFileProtection])
    }
    func enabled(_ kind: AdultFoodSummaryKind, scope: PantryDigestScope) -> Bool {
        (try? consent(kind)?.belongs(to: scope)) == true
    }
    func setEnabled(_ enabled: Bool, kind: AdultFoodSummaryKind, access: PantryDigestAccess, ledgerID: UUID? = nil) throws {
        guard access.authorized(), UIApplication.shared.isProtectedDataAvailable else { throw SurfaceError.unavailable }
        if !enabled { try revoke(kind); return }
        _ = try file(kind)
        guard kind != .tonight || ledgerID != nil else { throw SurfaceError.unavailable }
        if let existing = try consent(kind), existing.belongs(to: access.scope),
           kind != .tonight || (existing.reviewedLedger == ledgerID && existing.includesPlannedDinners == true) { return }
        try revoke(kind)
        try persist(Consent(origin: access.scope.origin, owner: access.scope.owner, token: UUID(), reviewedLedger: ledgerID, includesPlannedDinners: kind == .tonight ? true : nil), kind)
        generation = UUID()
    }
    func update(_ kind: AdultFoodSummaryKind, access: PantryDigestAccess, count: Int,
                reviewedTitle: String? = nil, plannedDinner: Bool = false, tonightBasis: TonightHomeBasis? = nil, now: Date = Date(), zone: TimeZone = .current) throws {
        guard access.authorized(), UIApplication.shared.isProtectedDataAvailable,
              var receipt = try consent(kind) else { return }
        guard receipt.belongs(to: access.scope) else { try revoke(kind); return }
        guard (kind == .tonight) == (tonightBasis != nil) else { throw SurfaceError.invalid }
        if kind == .tonight, receipt.reviewedLedger != tonightBasis?.ledger { try revoke(kind); return }
        guard !plannedDinner || receipt.includesPlannedDinners == true else { throw SurfaceError.unavailable }
        let projected = try file(kind)
        if let old = receipt.projection, old.count == count, old.reviewedTitle == reviewedTitle, (old.plannedDinner == true) == plannedDinner, receipt.tonightBasis == tonightBasis,
           old.isFresh(at: now, zone: zone),
           (try? projected.read()) == old { return }
        let fresh = try AdultFoodSummaryProjection(kind: kind, scope: receipt.token, now: now, zone: zone,
            count: count, reviewedTitle: reviewedTitle, plannedDinner: plannedDinner)
        receipt.tonightBasis = tonightBasis
        receipt.reviewedLedger = tonightBasis?.ledger
        receipt.projection = fresh
        try persist(receipt, kind)
        do { try projected.publish(fresh) }
        catch { try projected.clear(); reload(kind); throw error }
        reload(kind)
    }
    func publishedKind(for handle: RouteHandle, now: Date, zone: TimeZone = .current) -> AdultFoodSummaryKind? {
        guard UIApplication.shared.isProtectedDataAvailable else { return nil }
        return AdultFoodSummaryKind.allCases.first { kind in
            guard let receipt = try? consent(kind), let value = receipt.projection else { return false }
            return value.route == handle && value.scope == receipt.token && value.isFresh(at: now, zone: zone)
        }
    }
    func permits(_ handle: RouteHandle, kind: AdultFoodSummaryKind, access: PantryDigestAccess, now: Date = Date()) -> Bool {
        access.authorized() && enabled(kind, scope: access.scope) && publishedKind(for: handle, now: now) == kind
    }
    func permitsTonight(_ handle: RouteHandle, access: PantryDigestAccess, basis: TonightHomeBasis?) -> Bool {
        guard let basis, permits(handle, kind: .tonight, access: access),
              let receipt = try? consent(.tonight) else { return false }
        return receipt.tonightBasis == basis
    }
    func includesPlannedDinners(scope: PantryDigestScope, ledgerID: UUID) -> Bool {
        guard let receipt = try? consent(.tonight), receipt.belongs(to: scope),
              receipt.reviewedLedger == ledgerID else { return false }
        return receipt.includesPlannedDinners == true
    }
    func tonightConsentToken(scope: PantryDigestScope, ledger: UUID) -> UUID? {
        guard let receipt = try? consent(.tonight), receipt.belongs(to: scope),
              receipt.reviewedLedger == ledger else { return nil }
        return receipt.token
    }
    func reconcileOwner(_ access: PantryDigestAccess) throws {
        guard access.authorized() else { return }
        for kind in AdultFoodSummaryKind.allCases {
            if let receipt = try consent(kind), !receipt.belongs(to: access.scope) { try revoke(kind) }
        }
    }
    /// A planned title is a different disclosure from the older option-only widget.
    /// Opening Tonight is unnecessary after the adult opts into this summary.
    @discardableResult
    func refreshPlannedTonight(access: PantryDigestAccess, ledger: LedgerModel, pickup: PickupModel,
                               now: Date = Date(), zone: TimeZone = .current) throws -> Bool {
        guard access.authorized(), let origin = ledger.sourceWorkspaceID,
              includesPlannedDinners(scope: access.scope, ledgerID: origin) else { return false }
        do {
            guard ledger.ready, !ledger.saving, !ledger.hasPendingSave, !ledger.hasPendingLedgerDeletion,
                  pickup.ready, !pickup.saving, !pickup.hasPendingSave, pickup.pantryReadIsCurrent,
                  pickup.sourceWorkspaceID == access.scope.origin else {
                throw SurfaceError.unavailable
            }
            let plan = try TonightPlannedDinners.current(workspace: ledger.workspace, ledgerID: origin,
                journeys: pickup.journeys, now: now, zone: zone)
            guard plan.count > 0 else {
                if try consent(.tonight)?.projection?.plannedDinner == true {
                    try invalidate(.tonight, origin: access.scope.origin, forget: false)
                }
                return false
            }
            let basis = try TonightHomeBasis.current(ledger: ledger, pickup: pickup)
            try update(.tonight, access: access, count: plan.count, reviewedTitle: plan.title, plannedDinner: true,
                       tonightBasis: basis, now: now, zone: zone)
            return true
        } catch {
            try invalidate(.tonight, origin: access.scope.origin, forget: false)
            throw error
        }
    }
    func checkTonightSource(ledger: LedgerModel, pickup: PickupModel) throws {
        guard let receipt = try consent(.tonight), ledger.ready else { return }
        if let reviewedLedger = receipt.reviewedLedger, ledger.sourceWorkspaceID != reviewedLedger {
            try revoke(.tonight); return
        }
        guard let expected = receipt.tonightBasis else { return }
        // Startup publishes ledger readiness before opening the protected inventory.
        // A cold tap must wait for that read before comparing the pantry basis.
        if ledger.sourceWorkspaceID != expected.ledger || ledger.revision != expected.ledgerRevision ||
            ledger.hasPendingLedgerDeletion || receipt.projection?.isFresh(at: Date(), zone: .current) != true {
            try invalidate(.tonight, origin: receipt.origin, forget: false); return
        }
        guard pickup.ready, pickup.pantryReadIsCurrent else { return }
        if (try? TonightHomeBasis.current(ledger: ledger, pickup: pickup)) != expected {
            try invalidate(.tonight, origin: receipt.origin, forget: false)
        }
    }
    func invalidateLedger(_ ledgerID: UUID, forget: Bool) throws {
        guard let receipt = try consent(.tonight), (receipt.reviewedLedger ?? receipt.tonightBasis?.ledger) == ledgerID else { return }
        try invalidate(.tonight, origin: receipt.origin, forget: forget)
    }
    func permitsUseSoon(_ handle: RouteHandle, access: PantryDigestAccess, lots: [InventoryLot],
                        digest: PantryDigestStore, now: Date = Date()) -> Bool {
        guard permits(handle, kind: .useSoon, access: access, now: now),
              let shown = try? consent(.useSoon)?.projection,
              let document = try? digest.document(access.scope),
              let count = try? document.homeSummaryCount(lots: lots, now: now, zone: .current) else { return false }
        return shown.count == count
    }
    func invalidate(_ kind: AdultFoodSummaryKind, origin: UUID, forget: Bool) throws {
        guard var receipt = try consent(kind), receipt.origin == origin else { return }
        if forget { try revoke(kind); return }
        guard receipt.projection != nil else { return }
        try file(kind).clear()
        receipt.tonightBasis = nil
        receipt.projection = nil
        try persist(receipt, kind)
        reload(kind)
    }
    func revoke(_ kind: AdultFoodSummaryKind) throws {
        if let group = try? file(kind) { try group.clear() }
        else if try consent(kind) != nil { throw SurfaceError.unconfigured }
        do { try FileManager.default.removeItem(at: url(kind)) }
        catch let error as CocoaError where error.code == .fileNoSuchFile { }
        reload(kind); generation = UUID()
    }
    func revokeAll() { for kind in AdultFoodSummaryKind.allCases { try? revoke(kind) } }
}

extension PantryDigestDocument {
    func homeSummaryCount(lots: [InventoryLot], now: Date, zone: TimeZone) throws -> Int {
        var current = self
        current.reconcile(lots)
        let today = try MealDay(date: now, timeZoneIdentifier: zone.identifier)
        return current.rules.filter { $0.day.iso8601 <= today.iso8601 }.count
    }
}

struct AdultHomeSummaryPreference: View {
    let kind: AdultFoodSummaryKind
    let access: PantryDigestAccess
    var ledgerID: UUID? = nil
    @ObservedObject private var home = AdultHomeSummaryStore.shared
    @State private var error = false
    private var enabled: Binding<Bool> {
        Binding(get: { access.authorized() && home.enabled(kind, scope: access.scope) }, set: { value in
            do { try home.setEnabled(value, kind: kind, access: access, ledgerID: ledgerID); error = false }
            catch { self.error = true }
        })
    }
    var body: some View {
        Section {
            Toggle(SurfaceCopy.text("Show on my Home Screen"), isOn: enabled)
                .accessibilityIdentifier("adultHomeSummary." + kind.rawValue)
            if kind == .tonight, enabled.wrappedValue, let ledgerID,
               !home.includesPlannedDinners(scope: access.scope, ledgerID: ledgerID) {
                Button(SurfaceCopy.text("Include my planned dinners")) { enabled.wrappedValue = true }
            }
            if error { Text(SurfaceCopy.text("Could not update the Home Screen setting. Try again.")) }
        } footer: {
            if kind == .tonight {
                Text(SurfaceCopy.text("Shows today’s planned dinner title, or a count if several are planned. With no planned dinner, shows reviewed options."))
            }
            Text(SurfaceCopy.text("Anyone who can see your unlocked Home Screen may see this summary. iOS may briefly keep a previous widget image after you turn it off or change accounts."))
        }
    }
}

struct AdultHomeSummaryDestination: View {
    let kind: AdultFoodSummaryKind
    let handle: RouteHandle
    @ObservedObject var pickup: PickupModel
    @ObservedObject var household: HouseholdModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @Environment(\.guardianChildCoordinator) private var child
    @ObservedObject private var home = AdultHomeSummaryStore.shared
    @State private var model: PantryModel?
    @State private var openedTonight: TonightSession?
    @ObservedObject private var digest = PantryDigestStore.shared

    private struct TonightSession: Equatable {
        let scope: PantryDigestScope
        let ledger: UUID
        let generation: UUID
        let consent: UUID
    }
    private var tonightSession: TonightSession? {
        guard UIApplication.shared.isProtectedDataAvailable, let child, !child.presented,
              household.projection?.grantId == nil, pickup.pantryRouteAvailable, pickup.pantryIsActive,
              let identity = CapturePrivateIdentity.current(access: access, household: household),
              let origin = pickup.sourceWorkspaceID, ledger.ready, !ledger.hasPendingLedgerDeletion,
              let ledgerID = ledger.sourceWorkspaceID else { return nil }
        let scope = PantryDigestScope(origin: origin, identity: identity)
        guard let consent = home.tonightConsentToken(scope: scope, ledger: ledgerID) else { return nil }
        return TonightSession(scope: scope, ledger: ledgerID, generation: pickup.privatePantryGeneration, consent: consent)
    }
    var body: some View {
        Group {
            if let openedTonight, kind == .tonight {
                // Tonight refreshes stock on entry. Its own in-flight read must
                // retain the view and task under the originally admitted session.
                if openedTonight == tonightSession { TonightEntry() }
                else { SurfaceUnavailableView(showsClose: true) }
            } else if let child, let current = PantryDigestAccess.current(pickup: pickup, access: access, household: household, child: child) {
                if kind == .tonight, home.permitsTonight(handle, access: current,
                            basis: try? TonightHomeBasis.current(ledger: ledger, pickup: pickup)) {
                    ProgressView().task {
                        guard current.authorized(), let session = tonightSession, session.scope == current.scope,
                              home.permitsTonight(handle, access: current, basis: try? TonightHomeBasis.current(ledger: ledger, pickup: pickup))
                        else { return }
                        openedTonight = session
                    }
                } else if kind == .useSoon, let snapshot = pickup.pantrySnapshot,
                          home.permitsUseSoon(handle, access: current, lots: snapshot.lots, digest: digest) {
                    if let model { PantryDigestList(model: model, access: current) }
                    else { ProgressView().task { model = pickup.makePantryModel() } }
                } else { SurfaceUnavailableView(showsClose: true) }
            } else { SurfaceUnavailableView(showsClose: true) }
        }.privacySensitive()
    }
}
