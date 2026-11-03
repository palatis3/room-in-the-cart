import SwiftUI

private struct DinnerAccessShield: ViewModifier {
    @ObservedObject var model: DinnerFeatureModel
    var budget: Bool
    func body(content: Content) -> some View {
        TimelineView(.periodic(from: .now, by: 15)) { _ in
            if model.accessAvailable && (!budget || model.budgetVisible) { content }
            else { Text(dinnerText("Planning access changed or expired. Reconnect and review again.")).padding().accessibilityIdentifier("dinnerAccessEnded") }
        }
    }
}
extension View {
    func dinnerAccess(_ model: DinnerFeatureModel, budget: Bool = false) -> some View { modifier(DinnerAccessShield(model: model, budget: budget)) }
}
