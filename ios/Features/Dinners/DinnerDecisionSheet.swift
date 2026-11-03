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
