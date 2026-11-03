import SwiftUI
import UIKit
import CoreDomain

private struct DinnerDecisionCloseKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
private struct DinnerDecisionApplyKey: EnvironmentKey {
    static let defaultValue: (() -> Void)? = nil
}
extension EnvironmentValues {
    var advanceToDinnerApply: (() -> Void)? {
        get { self[DinnerDecisionApplyKey.self] }
        set { self[DinnerDecisionApplyKey.self] = newValue }
    }
    var closeDinnerDecision: (() -> Void)? {
        get { self[DinnerDecisionCloseKey.self] }
        set { self[DinnerDecisionCloseKey.self] = newValue }
    }
}

private struct DinnerDecisionContent<Decision: View>: View {
    @ObservedObject var model: DinnerFeatureModel
    @State private var finalReview = false
    let close: () -> Void
    @ViewBuilder let decision: () -> Decision
    var body: some View {
        Group {
            if finalReview {
                NavigationStack { DinnerPreviewView(model: model).toolbar { cancelControl } }
            } else {
                NavigationStack { decision().toolbar { cancelControl } }
            }
        }
        .environment(\.advanceToDinnerApply, { finalReview = true })
        .environment(\.closeDinnerDecision, close)
        .presentationDetents([.large])
    }
    @ToolbarContentBuilder private var cancelControl: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button(dinnerText("Cancel"), action: close).accessibilityIdentifier("dinnerDecisionCancel")
        }
    }

}

/// Retain the initiating control as the accessibility destination for every exit,
/// including a swipe to dismiss. Nested review steps share this navigation stack.
struct DinnerDecisionButton<Decision: View>: View {
    @ObservedObject var model: DinnerFeatureModel
    let title: String
    let identifier: String
    var preservePending = true
    @ViewBuilder let decision: () -> Decision
    @State private var previous: DinnerPreview?
    @State private var presented = false
    @AccessibilityFocusState private var focused: Bool
    var body: some View {
        Button(title) { previous = preservePending ? model.preview : nil; presented = true }
            .accessibilityIdentifier(identifier)
            .accessibilityFocused($focused)
            .sheet(isPresented: $presented, onDismiss: {
                model.endDecision(restoring: previous)
                previous = nil
                focused = true
            }) {
                DinnerDecisionContent(model: model, close: { presented = false }, decision: decision)
            }
    }
}

private struct DinnerApplyPresentation: ViewModifier {
    @ObservedObject var model: DinnerFeatureModel
    @Binding var presented: Bool
    @Environment(\.advanceToDinnerApply) private var advance
    @State private var origin: AnyObject?
    func body(content: Content) -> some View {
        if let advance {
            content.onChange(of: presented) { _, open in if open { advance() } }
        } else {
            content
                .onChange(of: presented) { _, open in
                    if open { origin = UIAccessibility.focusedElement(using: .notificationVoiceOver) as AnyObject? }
                }
                .sheet(isPresented: $presented, onDismiss: {
                    model.cancelPreview()
                    if let origin { UIAccessibility.post(notification: .layoutChanged, argument: origin) }
                    origin = nil
                }) {
                    DinnerDecisionContent(model: model, close: { presented = false }) { DinnerPreviewView(model: model) }
                }
        }
    }
}
extension View {
    func dinnerApplyPresentation(_ model: DinnerFeatureModel, presented: Binding<Bool>) -> some View {
        modifier(DinnerApplyPresentation(model: model, presented: presented))
    }
}

extension PickupJourney {
    func reviewedGuestQuote(for shop: ShoppingLedger, selections: [LedgerPackSelection]) -> CheckoutQuote? {
        guard id == shop.id, ledgerSourceRevisionID == shop.revisionID, ledgerBasis == shop.basis,
              let basket, quotedRevisionID == basket.current.id, let quote, context == quote.context,
              quote.context.commitmentsID == shop.id, quote.context.branchID == shop.basis.branch,
              quote.context.mode.rawValue == shop.basis.mode.rawValue,
              Set(basket.current.lines.map(\.id)) == Set(shop.lines.filter { !$0.isHandled && !$0.isTrashed }.map(\.id)) else { return nil }
        if let slot = shop.basis.slot, quote.context.slot != "\(slot.ISO8601Format()) · \(shop.basis.timeZoneIdentifier)" { return nil }
        for selection in selections {
            guard ledgerPackSelections.contains(selection),
                  let row = basket.current.lines.first(where: { $0.id == selection.lineID }),
                  row.quantity == selection.purchasedQuantity else { return nil }
        }
        return quote
    }
}

struct DinnerGuestPurchaseReview: View {
    @ObservedObject var model: DinnerFeatureModel
    @EnvironmentObject private var pickup: PickupModel
    let preview: DinnerPreview

    private var impact: DinnerGuestImpact? {
        guard let shop = model.shop, let workspaceID = model.store.sourceWorkspaceID else { return nil }
        let current = model.workspace.packSelections.filter {
            $0.shopID == shop.id && $0.shopRevisionID == shop.revisionID && $0.sourceWorkspaceID == workspaceID
        }
        // Later reviews supersede earlier selections for the same line, just as at checkout.
        let active = Dictionary(current.map { ($0.lineID, $0) }, uniquingKeysWith: { _, newest in newest })
        let quote = model.budgetVisible && pickup.ready && !pickup.saving && !pickup.hasPendingSave
            ? pickup.journeys.first(where: { $0.id == shop.id })?.reviewedGuestQuote(for: shop, selections: Array(active.values)) : nil
        return try? preview.guestImpact(workspace: model.workspace, workspaceID: workspaceID, quote: quote)
    }

    var body: some View {
        Section(dinnerText("Package and checkout effects")) {
            if let impact {
                ForEach(impact.lines) { line in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(line.name).font(.headline)
                        if let label = line.packLabel, let before = line.before, let after = line.after {
                            Text(label)
                            Text(dinnerFormat("Whole packages: %@ → %@", String(before), String(after)))
                            if model.budgetVisible {
                                Text(dinnerFormat("Item cost: %@ → %@", dinnerMoney(line.beforeCost), dinnerMoney(line.afterCost)))
                            }
                        } else { Text(dinnerText("Review a package for this item to calculate the change.")) }
                    }.accessibilityElement(children: .combine).accessibilityIdentifier("guestPackImpact-\(line.id)")
                }
                if model.budgetVisible {
                    Text(dinnerFormat("Pickup fees: %@ → %@", dinnerMoney(impact.beforeFees?.exact), dinnerMoney(impact.afterFees?.exact)))
                        .accessibilityIdentifier("guestFeeImpact")
                    Text(dinnerFormat("Whole pickup: %@ → %@", dinnerMoney(impact.beforeCheckout?.total.exact), dinnerMoney(impact.afterCheckout?.total.exact)))
                        .accessibilityIdentifier("guestCheckoutImpact")
                    Text(dinnerText("Estimate uses the same entered checkout terms. Review current package prices and charges at checkout."))
                }
            } else { Text(dinnerText("Reopen the current dinner and review its package and checkout terms.")) }
        }
    }
}
