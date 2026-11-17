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
    func setEnabled(_ enabled: Bool, kind: AdultFoodSummaryKind, access: PantryDigestAccess) throws {
        guard access.authorized(), UIApplication.shared.isProtectedDataAvailable else { throw SurfaceError.unavailable }
        if !enabled { try revoke(kind); return }
        _ = try file(kind)
        if self.enabled(kind, scope: access.scope) { return }
        try revoke(kind)
        try persist(Consent(origin: access.scope.origin, owner: access.scope.owner, token: UUID()), kind)
        generation = UUID()
    }
    func update(_ kind: AdultFoodSummaryKind, access: PantryDigestAccess, count: Int,
                reviewedTitle: String? = nil, tonightBasis: TonightHomeBasis? = nil, now: Date = Date(), zone: TimeZone = .current) throws {
        guard access.authorized(), UIApplication.shared.isProtectedDataAvailable,
              var receipt = try consent(kind) else { return }
        guard receipt.belongs(to: access.scope) else { try revoke(kind); return }
        guard (kind == .tonight) == (tonightBasis != nil) else { throw SurfaceError.invalid }
        let projected = try file(kind)
        if let old = receipt.projection, old.count == count, old.reviewedTitle == reviewedTitle, receipt.tonightBasis == tonightBasis,
           old.isFresh(at: now, zone: zone),
           (try? projected.read()) == old { return }
        let fresh = try AdultFoodSummaryProjection(kind: kind, scope: receipt.token, now: now, zone: zone,
            count: count, reviewedTitle: reviewedTitle)
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
    func reconcileOwner(_ access: PantryDigestAccess) throws {
        guard access.authorized() else { return }
        for kind in AdultFoodSummaryKind.allCases {
            if let receipt = try consent(kind), !receipt.belongs(to: access.scope) { try revoke(kind) }
        }
    }
    func checkTonightSource(ledger: LedgerModel, pickup: PickupModel) throws {
        guard let receipt = try consent(.tonight), let expected = receipt.tonightBasis else { return }
        // Startup publishes ledger readiness before opening the protected inventory.
        // A cold tap must wait for that read before comparing the pantry basis.
        guard ledger.ready else { return }
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
    @ObservedObject private var home = AdultHomeSummaryStore.shared
    @State private var error = false
    private var enabled: Binding<Bool> {
        Binding(get: { access.authorized() && home.enabled(kind, scope: access.scope) }, set: { value in
            do { try home.setEnabled(value, kind: kind, access: access); error = false }
            catch { self.error = true }
        })
    }
    var body: some View {
        Section {
            Toggle(SurfaceCopy.text("Show on my Home Screen"), isOn: enabled)
                .accessibilityIdentifier("adultHomeSummary." + kind.rawValue)
            if error { Text(SurfaceCopy.text("Could not update the Home Screen setting. Try again.")) }
        } footer: {
            if kind == .tonight {
                Text(SurfaceCopy.text("Shows the first reviewed meal title and the number of fully covered options."))
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
    @State private var openedTonight: PantryDigestScope?
    @ObservedObject private var digest = PantryDigestStore.shared
    var body: some View {
        Group {
            if let child, let current = PantryDigestAccess.current(pickup: pickup, access: access, household: household, child: child) {
                if kind == .tonight, openedTonight == current.scope, home.enabled(.tonight, scope: current.scope) {
                    TonightEntry()
                } else if kind == .tonight, home.permitsTonight(handle, access: current,
                            basis: try? TonightHomeBasis.current(ledger: ledger, pickup: pickup)) {
                    ProgressView().task { openedTonight = current.scope }
                } else if kind == .useSoon, let snapshot = pickup.pantrySnapshot,
                          home.permitsUseSoon(handle, access: current, lots: snapshot.lots, digest: digest) {
                    if let model { PantryDigestList(model: model, access: current) }
                    else { ProgressView().task { model = pickup.makePantryModel() } }
                } else { SurfaceUnavailableView() }
            } else { SurfaceUnavailableView() }
        }.privacySensitive()
    }
}
