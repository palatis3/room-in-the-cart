import Foundation
import HouseholdClient

enum SharedOperationUndoCopy {
    static func text(_ key: String) -> String { String(localized: String.LocalizationValue(key), table: "SharedOperationUndo") }
    static func unavailable(_ reason: SharedOperationUndoEligibility.Reason) -> String {
        switch reason {
        case .explicit_current_preview_required: text("Review this change against the current shop.")
        case .food_undo_request_acceptance_unsupported: text("Request decisions cannot be undone here. Review the request in the household inbox.")
        case .food_undo_first_adoption_unsupported: text("Starting shared food tracking cannot be undone here.")
        case .food_undo_meal_action_unsupported: text("Meal changes cannot be undone here. Review the current meal plan.")
        case .food_undo_store_action_unsupported: text("Store changes cannot be undone here. Review the current store and quote.")
        case .food_undo_already_reversed: text("This change was already undone.")
        case .food_undo_inverse_operation_unsupported: text("An undo cannot be undone here. Review a new change to the current shop.")
        case .food_undo_line_conflict, .food_undo_quote_conflict, .food_undo_graph_conflict:
            text("Later changes or food commitments prevent this undo. Review the current shop instead.")
        case .food_undo_expired_quote: text("The earlier prices have expired. Review a fresh quote instead.")
        case .food_undo_no_effect: text("There is no remaining change to undo.")
        case .food_undo_history_unavailable, .food_undo_missing_snapshot_unsupported, .food_undo_operation_unsupported:
            text("The information needed to undo this change is unavailable. Review the current shop instead.")
        }
    }
}
