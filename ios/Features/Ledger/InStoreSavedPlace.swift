import CoreDomain
import CryptoKit
import SwiftUI

struct InStorePlaceScope: Codable, Equatable, Sendable {
    let owner: String
    let workspace, shop, stop: UUID

    init(identity: CapturePrivateIdentity, workspace: UUID, shop: ShoppingLedger, enrollment: String? = nil) {
        // Encode boundaries (including nils) without putting account or household labels on disk.
        let components = [Optional(identity.actorID.uuidString), identity.subject, identity.householdID, identity.memberID, identity.role, enrollment]
        let encoded = (try? JSONEncoder().encode(components)) ?? Data()
        owner = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
        self.workspace = workspace
        self.shop = shop.id
        self.stop = shop.currentStop.id
    }
}

struct InStoreSavedPlace: Codable, Equatable, Sendable {
    static let lifetime: TimeInterval = 24 * 60 * 60
    let line: UUID
    let product: String
    let photo: UUID?
    let association: UUID?
    let saved: Date

    func isLive(at now: Date) -> Bool { saved <= now && now.timeIntervalSince(saved) < Self.lifetime }

    static func make(scope: InStorePlaceScope, lineID: UUID, workspace: LedgerWorkspace,
                     photo: PackageRowPhoto?, at now: Date = .now) -> Self? {
        guard workspace.selectedShopID == scope.shop,
              let shop = workspace.shops.first(where: { $0.id == scope.shop }), shop.currentStop.id == scope.stop,
              let line = shop.lines.first(where: { $0.id == lineID }), !line.isTrashed, !line.isHandled, !line.isChecked,
              line.eligibleForStop(named: shop.currentStop.name) else { return nil }
        let target = CaptureTarget(workspaceID: scope.workspace, containerID: scope.shop, objectID: lineID, revision: 0, kind: .packageReference)
        guard let product = PackageRowPhoto.productSignature(target, in: workspace) else { return nil }
        return Self(line: lineID, product: product, photo: photo?.revision, association: photo?.association?.id, saved: now)
    }

    func atSaveTime(_ date: Date = .now) -> Self {
        Self(line: line, product: product, photo: photo, association: association, saved: date)
    }

    func matches(_ live: Self?) -> Bool {
        guard let live, line == live.line, product == live.product else { return false }
        // A picture added after a text-only bookmark does not change its grocery.
        return photo == nil || (photo == live.photo && association == live.association)
    }
}

/// A cleared slot retains its revision until expiry so a stale window cannot recreate it.
struct InStorePlaceSlot: Codable, Equatable, Sendable {
    let scope: InStorePlaceScope
    var revision = UUID()
    let changed: Date
    let place: InStoreSavedPlace?
}

func savedPlaceText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "SavedPlace")
}

struct InStorePlaceActions: View {
    let marked: Bool
    let replacing: Bool
    let busy: Bool
    let failed: Bool
    let save: () -> Void
    let clear: () -> Void
    @State private var confirmingClear = false
    @State private var confirmingMove = false

    var body: some View {
        Section {
            if marked {
                Button { confirmingClear = true } label: {
                    Label(savedPlaceText("Clear saved place"), systemImage: "bookmark.slash")
                }
                .accessibilityIdentifier("inStorePlace.clear")
                .alert(savedPlaceText("Clear this saved place?"), isPresented: $confirmingClear) {
                    Button(savedPlaceText("Clear saved place"), role: .destructive, action: clear)
                    Button(ledgerText("Cancel"), role: .cancel) {}
                }
            } else {
                Button { if replacing { confirmingMove = true } else { save() } } label: {
                    Label(savedPlaceText(replacing ? "Move my saved place here" : "Keep my place here"), systemImage: "bookmark")
                }.accessibilityIdentifier("inStorePlace.save")
                 .alert(savedPlaceText("Replace the saved place at this stop?"), isPresented: $confirmingMove) {
                     Button(savedPlaceText("Move my saved place here"), action: save)
                     Button(ledgerText("Cancel"), role: .cancel) {}
                 }
            }
            if failed { Text(savedPlaceText("Your saved place could not be updated. Try again.")) }
        } footer: {
            Text(savedPlaceText("Saved for up to 24 hours on this device."))
        }.disabled(busy)
    }
}
