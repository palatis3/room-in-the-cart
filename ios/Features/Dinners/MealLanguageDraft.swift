import CoreDomain
import Foundation
import HouseholdClient
import UIKit

enum MealLanguageChoice: String, Decodable {
    case dislike, preferredBrand, makeAgain, tooMuchEffort, childrenLikedIt, tooManyLeftovers
}

enum MealLanguageDraft: Equatable {
    case preferences(MealPreferenceSettings)
    case feedback(Set<MealReaction>)

    var purpose: String {
        switch self {
        case .preferences: "meal-preference"
        case .feedback: "meal-feedback"
        }
    }

    func adding(_ choice: MealLanguageChoice, quote: String) throws -> Self {
        switch self {
        case .preferences(var settings):
            // A soft suggestion must never enter a category whose saved strength is required.
            switch choice {
            case .dislike where !settings.strictDislikes && !settings.dislikes.contains(quote):
                settings.dislikes.append(quote)
            case .preferredBrand where !settings.strictBrands && !settings.preferredBrands.contains(quote):
                settings.preferredBrands.append(quote)
            default: throw ClientError.invalidResponse
            }
            try settings.validate()
            return .preferences(settings)
        case .feedback(var reactions):
            guard let reaction = MealReaction(rawValue: choice.rawValue), reactions.insert(reaction).inserted else {
                throw ClientError.invalidResponse
            }
            return .feedback(reactions)
        }
    }
}

/// These identities stay on the device. The provider receives one user-selected line.
struct MealLanguageBasis: Equatable {
    enum Destination: Equatable {
        case personal(CapturePrivateIdentity, workspace: UUID, shop: UUID?, shopRevision: UUID?, source: MealFeedbackSource?)
        case householdPreferences(HouseholdPreferenceScope, device: HouseholdDeviceSession, grantEpoch: Int)
    }

    let account: ReceiptAssistanceScope
    let destination: Destination
    let revision: UUID?

    static func householdPreferences(scope: HouseholdPreferenceScope, session: HouseholdDeviceSession,
                                     page: HouseholdPreferencePage<MealPreferenceSettings>, revision: UUID?,
                                     selectedShop: String?) -> Self? {
        guard scope.administer, page.canWrite, page.revision == revision,
              page.householdId == session.householdID,
              session.householdID == UUID(uuidString: scope.householdID),
              session.memberID == UUID(uuidString: scope.memberID) else { return nil }
        return .init(account: .init(subject: scope.subject, householdID: scope.householdID,
                                    memberID: scope.memberID, shopID: selectedShop),
                     destination: .householdPreferences(scope, device: session, grantEpoch: page.grantEpoch), revision: revision)
    }

    @MainActor static func current(ledger: LedgerModel, access: WorkspaceAccess, household: HouseholdModel,
                                   childPresented: Bool, source: MealFeedbackSource?, revision: UUID?, duringSave: Bool = false) -> Self? {
        guard UIApplication.shared.applicationState == .active, UIApplication.shared.isProtectedDataAvailable,
              ledger.ready, duringSave || (!ledger.saving && !ledger.hasPendingSave), !ledger.hasPendingLedgerDeletion,
              !household.guardianChildOnly, household.projection?.grantId == nil, !childPresented,
              let identity = CapturePrivateIdentity.current(access: access, household: household),
              let subject = identity.subject, let householdID = identity.householdID, let memberID = identity.memberID,
              let workspaceID = ledger.sourceWorkspaceID else { return nil }
        if let source {
            guard ledger.workspace.feedbackSourceExists(source),
                  ledger.workspace.feedback(for: source, owner: identity.mealFeedbackOwner)?.revision == revision else { return nil }
            if case let .occurrence(shopID, _) = source, ledger.workspace.selectedShopID != shopID { return nil }
        } else if ledger.workspace.dinnerPlanning.privateMealPreferences?.revision != revision { return nil }
        return .init(account: .init(subject: subject, householdID: householdID, memberID: memberID, shopID: household.projection?.shopId),
                     destination: .personal(identity, workspace: workspaceID, shop: ledger.workspace.selectedShopID,
                                            shopRevision: ledger.shop?.revisionID, source: source), revision: revision)
    }
}

struct MealLanguageReply: Decodable, Sendable {
    struct Suggestion: Decodable, Sendable {
        let sourceLineID: UUID
        let kind: MealLanguageChoice
        let quote: String
    }
    let version: Int
    let requestID: UUID
    let suggestions: [Suggestion]

    func review(for request: LanguageAssistanceRequest, basis: MealLanguageBasis, draft: MealLanguageDraft) throws -> MealLanguageReview? {
        guard version == 1, requestID == request.requestID, request.sourceLines.count == 1,
              let line = request.sourceLines.first, suggestions.count <= 1 else { throw ClientError.invalidResponse }
        guard let suggestion = suggestions.first else { return nil }
        guard suggestion.sourceLineID == line.id, ReceiptLineAssistanceRequest.accepts(suggestion.quote),
              suggestion.quote.count <= 128, suggestion.quote == suggestion.quote.trimmingCharacters(in: .whitespacesAndNewlines),
              line.text.range(of: suggestion.quote, options: .literal) != nil else { throw ClientError.invalidResponse }
        return try .init(basis: basis, original: draft, result: draft.adding(suggestion.kind, quote: suggestion.quote),
            quote: suggestion.quote, choice: suggestion.kind, sourceText: line.text)
    }
}

struct MealLanguageReview {
    let basis: MealLanguageBasis
    let original: MealLanguageDraft
    let result: MealLanguageDraft
    let quote: String
    let choice: MealLanguageChoice
    let sourceText: String

    func applying(current: MealLanguageBasis?, draft: MealLanguageDraft, text: String) throws -> MealLanguageDraft {
        guard current == basis, draft == original, text == sourceText else { throw ClientError.invalidResponse }
        return result
    }
}
