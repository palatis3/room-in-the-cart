import SwiftUI
import CoreDomain

/// Captured from live app state, never from a recipe, scan, or recovered document.
struct CapturePrivateIdentity: Equatable {
    let actorID: UUID
    let subject: String?
    let householdID: String?
    let memberID: String?
    let role: String?
    @MainActor static func current(access: WorkspaceAccess, household: HouseholdModel) -> Self? {
        guard access.unlocked, !household.locked else { return nil }
        if let projection = household.projection {
            guard household.identity != nil, projection.enrolled,
                  ["shopper", "organizer"].contains(projection.role) else { return nil }
        } else if household.identity != nil { return nil }
        return Self(actorID: access.localActorID, subject: household.identity?.subject,
            householdID: household.projection?.household.id, memberID: household.projection?.memberId,
            role: household.projection?.role)
    }
}

@MainActor struct PrivateSourceReferenceEntry: View {
    let target: CaptureTarget
    let initialLabel: String
    let sourceCurrent: @MainActor @Sendable () -> Bool
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var identity: CapturePrivateIdentity?
    var body: some View {
        Group {
            if identity != nil { CaptureReferenceShelf(target: target, initialLabel: initialLabel, authorize: { authorized() }) }
            else { Text(captureText("Unlock your private workspace to review this source.")) }
        }.task(id: target) { identity = CapturePrivateIdentity.current(access: access, household: household) }
    }
    private func authorized() -> Bool {
        scenePhase == .active && identity != nil &&
        identity == CapturePrivateIdentity.current(access: access, household: household) && sourceCurrent()
    }
}

@MainActor struct RecipeCaptureEntry: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var target: CaptureTarget?
    @State private var shopID: UUID?
    @State private var identity: CapturePrivateIdentity?
    @State private var showCapture = false
    @State private var reviewed: MealTemplate?
    @State private var source: SourceMediaRecord?
    @State private var saving = false
    @State private var saved = false
    @State private var failed = false

    var body: some View {
        Form {
            Section {
                Text(captureText("Review a recipe from text or photo"))
                Text(captureText("Accepting a recipe saves an editable candidate. Choose it separately in the dinner library to add grocery needs."))
                if saved {
                    Text(captureText("Recipe accepted. No dinner was chosen and no groceries were added."))
                    NavigationLink(dinnerText("Dinner library")) { DinnerLibraryView(model: model) }
                } else if let reviewed {
                    Text(reviewed.title).font(.headline)
                    Text(dinnerFormat("Servings: %@", reviewed.servings.description))
                    ForEach(reviewed.ingredients) { ingredient in
                        Text(ingredient.name + " · " + dinnerQuantity(ingredient.quantity))
                    }
                    if let evidence = reviewed.sourceEvidence { RecipeSourceDisclosure(evidence: evidence) }
                    Text(captureText("The original source stays with this recipe. Saved photos stay on this device unless you choose them for an encrypted recovery file in Records."))
                    Button(captureText("Accept reviewed recipe")) { Task { await accept() } }
                        .disabled(!authorized() || !model.editable || saving)
                        .accessibilityIdentifier("dinner.acceptScannedRecipe")
                } else {
                    Button(captureText("Start recipe review")) { begin() }
                        .disabled(!canBegin).accessibilityIdentifier("dinner.beginRecipeReview")
                }
                if failed {
                    Text(captureText("The recipe save did not finish. Resolve any pending grocery save, then retry this same reviewed recipe. Nothing is chosen automatically."))
                }
            }
            LedgerSaveStatus(model: ledger)
            DinnerFeedback(model: model)
        }
        .navigationTitle(captureText("Recipe source review"))
        .sheet(isPresented: $showCapture) {
            if let target {
                NavigationStack {
                    ScanReviewView(kind: .recipe, target: target,
                        correctionScope: CaptureCorrectionScope(profileID: "local:" + target.workspaceID.uuidString,
                            localeIdentifier: Locale.current.language.languageCode?.identifier == "es" ? "es-US" : "en-US"),
                        authorize: { authorized() }) { result in
                        guard authorized(), case .recipe(let template, let record) = result else { return }
                        reviewed = template; source = record; showCapture = false
                    }
                }
            }
        }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if target != nil && !authorized() {
                    showCapture = false; reviewed = nil; source = nil; target = nil; identity = nil; saved = false
                }
            }
        }
        .onChange(of: scenePhase) { _, phase in if phase == .background { showCapture = false } }
    }
    private var canBegin: Bool {
        model.store === ledger && model.editable && model.accessAvailable && ledger.ready &&
        !ledger.hasPendingLedgerDeletion && ledger.sourceWorkspaceID != nil && model.shop != nil &&
        CapturePrivateIdentity.current(access: access, household: household) != nil
    }
    private func begin() {
        guard canBegin, let workspaceID = ledger.sourceWorkspaceID, let shop = model.shop else { return }
        identity = CapturePrivateIdentity.current(access: access, household: household)
        shopID = shop.id
        target = CaptureTarget(workspaceID: workspaceID, containerID: workspaceID, objectID: UUID(),
            revision: Int64(shop.revision), kind: .recipeSource)
        showCapture = true; failed = false
    }
    private func authorized() -> Bool {
        guard scenePhase == .active, model.store === ledger, let target, identity != nil,
              identity == CapturePrivateIdentity.current(access: access, household: household),
              ledger.ready, !ledger.hasPendingLedgerDeletion, ledger.sourceWorkspaceID == target.workspaceID,
              model.shop?.id == shopID, model.shop?.revision == Int(target.revision),
              model.accessAvailable else { return false }
        return true
    }
    private func accept() async {
        guard !saving, authorized(), model.editable, let reviewed, let source else { return }
        saving = true; defer { saving = false }
        do {
            // Persist the reviewed source first. Exact retries are idempotent. A failed
            // ledger save keeps this evidence until the same operation is retried or
            // the workspace is erased; never delete evidence for an uncertain commit.
            if source.imageJPEG != nil {
                _ = try await CaptureMediaStore.shared.save(source, authorize: { authorized() })
            }
            guard authorized() else { throw ScanFailure.stale }
            saved = await model.accept(reviewed, id: source.id, fallback: false)
            failed = !saved
        } catch { failed = true }
    }
}

/// Evidence text is safe to display with its authorized recipe. A decoded media
/// reference alone never opens the local media store (including recovered copies).
struct RecipeSourceDisclosure: View {
    let evidence: RecipeSourceEvidence
    var body: some View {
        DisclosureGroup(captureText("Original recipe source")) {
            Text(evidence.originalText).textSelection(.enabled)
            if evidence.localMedia != nil {
                Text(captureText("The source photo is local evidence. Encrypted recovery includes it only when you select it in Records."))
                    .font(.footnote)
            }
        }
    }
}

@MainActor struct RecipeSourceReview: View {
    @ObservedObject var model: DinnerFeatureModel
    let templateID: UUID
    let evidence: RecipeSourceEvidence
    @EnvironmentObject private var ledger: LedgerModel
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var identity: CapturePrivateIdentity?
    @State private var record: SourceMediaRecord?
    @State private var unavailable = false
    @State private var confirmRemoval = false
    private var target: CaptureTarget? {
        guard model.store === ledger, let workspaceID = ledger.sourceWorkspaceID,
              evidence.localMediaID(in: .activeNativeWorkspace(workspaceID)) != nil else { return nil }
        return CaptureTarget(workspaceID: workspaceID, containerID: workspaceID,
            objectID: templateID, revision: 0, kind: .recipeSource)
    }
    private func authorized() -> Bool {
        guard scenePhase == .active, model.store === ledger, ledger.ready, !ledger.hasPendingLedgerDeletion,
              identity != nil, identity == CapturePrivateIdentity.current(access: access, household: household),
              model.accessAvailable else { return false }
        return model.state.acceptedDinners.contains { $0.template.id == templateID && $0.template.sourceEvidence == evidence } ||
            (model.shop?.mealOccurrences.contains { $0.templateID == templateID && $0.sourceEvidence == evidence && $0.removedAt == nil } == true)
    }
    var body: some View {
        Form {
            if authorized() {
                Section { RecipeSourceDisclosure(evidence: evidence) }
                if let data = record?.imageJPEG, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().accessibilityLabel(captureText("Saved reduced-size source reference"))
                    Button(captureText("Remove saved recipe photo"), role: .destructive) { confirmRemoval = true }
                }
                if unavailable { Text(captureText("The source photo is unavailable. The original wording and editable recipe remain usable.")) }
            }
        }
        .navigationTitle(captureText("Original recipe source"))
        .task {
            identity = CapturePrivateIdentity.current(access: access, household: household)
            if let target, let id = evidence.localMediaID(in: .activeNativeWorkspace(target.workspaceID)) {
                do {
                    let value = try await CaptureMediaStore.shared.read(.init(workspaceID: target.workspaceID, mediaID: id), target: target, authorize: { authorized() })
                    if authorized() { record = value }
                } catch { unavailable = true }
            } else { unavailable = evidence.localMedia != nil }
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                if !authorized() { record = nil; return }
            }
        }
        .confirmationDialog(captureText("Remove saved recipe photo? The recipe and original text will stay."), isPresented: $confirmRemoval) {
            Button(captureText("Remove saved recipe photo"), role: .destructive) {
                guard let target, let record else { return }
                Task {
                    do { try await CaptureMediaStore.shared.remove(record.reference, target: target, authorize: { authorized() }); self.record = nil; unavailable = true }
                    catch { unavailable = true }
                }
            }
        }
        .onDisappear { record = nil; identity = nil }
    }
}
