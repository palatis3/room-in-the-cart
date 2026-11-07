import SwiftUI

enum Theme {
    static let canvas = Color("canvas")
    static let surface = Color("surface")
    static let ink = Color("ink")
    static let secondary = Color("secondary")
    static let action = Color("accent")
    static let onAction = Color("on_accent")
    static let error = Color("error")
    static let warning = Color("warning")
    static let warningSurface = Color("warning_surface")
}

/// Native form chrome uses the app's semantic colors in either appearance.
/// Keep row styling on the content, where Form consumes list-row preferences.
struct WorkingForm<Content: View>: View {
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            Group { content }
                .listRowBackground(Theme.surface)
        }.workingSurface()
    }
}

/// Explicit prompt color keeps native empty-field purposes readable. Return the
/// native TextField so callers retain their existing focus and input modifiers.
func workingTextField(_ title: String, text: Binding<String>) -> TextField<Text> {
    TextField(title, text: text, prompt: Text(title).foregroundStyle(Theme.secondary))
}

func workingTextField(_ title: String, text: Binding<String>, axis: Axis) -> TextField<Text> {
    TextField(title, text: text, prompt: Text(title).foregroundStyle(Theme.secondary), axis: axis)
}

struct PrimaryActionLabel<Label: View>: View {
    let label: Label
    var isPressed = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        label.font(.headline).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(Theme.onAction).background(Theme.action, in: RoundedRectangle(cornerRadius: 14))
            .opacity(isEnabled ? (isPressed ? 0.8 : 1) : 0.45)
    }
}

struct PrimaryAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionLabel(label: configuration.label, isPressed: configuration.isPressed)
    }
}

extension View {
    func keyboardDoneAction(visible: Bool, title: String, identifier: String? = nil, dismiss: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if visible {
                HStack {
                    Spacer()
                    Button(action: dismiss) {
                        Text(title)
                            .font(.body.weight(.semibold))
                            .frame(minWidth: 44, minHeight: 44)
                            .contentShape(Rectangle())
                    }
                    .accessibilityIdentifier(identifier ?? title)
                }
                .padding(.horizontal).background(.bar)
            }
        }
    }

    /// Navigation transitions can briefly propose an empty viewport.
    func fittingViewport(_ size: CGSize) -> some View {
        frame(width: size.width.isFinite ? max(0, size.width) : nil,
              height: size.height.isFinite ? max(0, size.height) : nil)
    }

    func workingSurface() -> some View {
        self.scrollContentBackground(.hidden).background(Theme.canvas).foregroundStyle(Theme.ink)
    }
}
