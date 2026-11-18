#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import CoreDomain
import LocalStore
import SwiftUI

/// Only this companion fixture supplies the private store and a fictional authenticated service response.
struct FoodKeeperMatchFixtureLot: View {
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @State private var model: PantryModel?
    @State private var lotID: UUID?
    @State private var failed = false

    private var digestAccess: PantryDigestAccess? {
        guard let origin = model?.snapshot?.state.workspaceID,
              let identity = CapturePrivateIdentity.current(access: access, household: household) else { return nil }
        return PantryDigestAccess(scope: .init(origin: origin, identity: identity)) {
            CapturePrivateIdentity.current(access: access, household: household) == identity
        }
    }

    var body: some View {
        NavigationStack {
            if let model, let lotID, digestAccess != nil {
                PantryLotEntryView(model: model, lotID: lotID, accessAllowed: true)
            } else if failed { Text("Fixture setup failed") }
            else { ProgressView() }
        }
        .environment(\.pantryDigestAccess, digestAccess)
        .task {
            guard model == nil, let identity = CapturePrivateIdentity.current(access: access, household: household) else { return }
            do {
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("FoodKeeperMatch-" + UUID().uuidString)
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let store = try ComparisonStore(url: dir.appendingPathComponent("pantry.sqlite"), inventoryEnabled: true)
                let token = try await store.inventorySourceToken()
                let state = try await store.inventoryState()
                _ = try await store.commitInventory(.init(workspaceID: store.workspaceID, operationID: UUID(),
                    expectedRevision: state.revision, request: Data("activate synthetic pantry".utf8), mode: .activate, sourceToken: token), at: Date())
                let pantry = PantryModel(repository: PantryRepository(store: store, authorize: {
                    CapturePrivateIdentity.current(access: access, household: household) == identity
                }))
                await pantry.load()
                await pantry.prepareNewFood(name: "Canned chicken", location: .fridge, amount: "2", unit: .count)
                await pantry.confirmReview(acknowledgingReservations: true)
                guard let id = pantry.savedLotID else { failed = true; return }
                self.lotID = id
                self.model = pantry
            } catch { failed = true }
        }
    }
}
#endif
