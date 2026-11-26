import CoreDomain
import LocalStore
import RecordArchive
import SwiftUI

extension CookingSessionContext {
    // A chosen occurrence can reuse a template's note while its timers and quantities remain occurrence-specific.
    static func recipeNotesKey(workspace: UUID, actor: CapturePrivateIdentity, templateID: UUID, revision: Int,
                               steps: [RecipeStep]) throws -> CookingSessionKey {
        let instructions = try ArchiveCodec.canonical(steps)
        return try CookingSessionKey(workspace: workspace, actor: actor.actorID,
            audience: [actor.subject, actor.householdID, actor.memberID, actor.role],
            kind: .reusableDinner, source: templateID, revision: String(revision) + "-" + ArchiveCodec.digest(instructions))
    }
}

struct ReusableDinnerCookingEntry: View {
    @ObservedObject var ledger: LedgerModel
    let recipe: MealTemplate
    var acceptedID: UUID?
    let permitted: () -> Bool
    @EnvironmentObject private var access: WorkspaceAccess
    @EnvironmentObject private var household: HouseholdModel
    @Environment(\.guardianChildCoordinator) private var child
    @Environment(\.scenePhase) private var scene

    private var identity: CapturePrivateIdentity? {
        guard scene == .active, UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
              child?.presented != true, household.projection?.grantId == nil, ledger.ready, permitted() else { return nil }
        if let acceptedID {
            guard ledger.workspace.dinnerPlanning.acceptedDinners.contains(where: { $0.id == acceptedID && $0.template == recipe })
            else { return nil }
        } else if !ledger.workspace.mealTemplates.contains(recipe) { return nil }
        return CapturePrivateIdentity.current(access: access, household: household)
    }

    var body: some View {
        if let actor = identity, let workspace = ledger.sourceWorkspaceID,
           let bytes = try? ArchiveCodec.canonical(recipe),
           let key = try? CookingSessionKey(workspace: workspace, actor: actor.actorID,
                audience: [actor.subject, actor.householdID, actor.memberID, actor.role],
                kind: .reusableDinner, source: acceptedID ?? recipe.id, revision: ArchiveCodec.digest(bytes)),
           let noteKey = try? CookingSessionContext.recipeNotesKey(workspace: workspace, actor: actor, templateID: recipe.id,
                revision: recipe.revision, steps: recipe.recipeSteps ?? []) {
            CookingSessionView(title: recipe.title, steps: recipe.recipeSteps ?? [],
                ingredients: recipe.ingredients.map {
                    $0.originalWording ?? [$0.name, $0.quantity.map { dinnerQuantity($0) }].compactMap { $0 }.joined(separator: " · ")
                }, legacyNotes: recipe.notes, yieldText: dinnerFormat("Servings: %@", recipe.servings.description),
                context: .init(key: key, authorize: { identity == actor && ledger.sourceWorkspaceID == workspace }, sourceNoteKey: noteKey)) { EmptyView() }
                .id(key)
        } else {
            Text(recordsText("Open this recipe from your current private workspace."))
        }
    }
}
