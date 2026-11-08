import SwiftUI

enum Theme {
    static let canvas = Color("canvas")
    static let surface = Color("surface")
    static let ink = Color("ink")
    static let secondary = Color("secondary")
    static let action = Color("accent")
    static let onAction = Color("on_accent")
    static let controlEdge = Color("control_edge")
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

/// Keep expanded controls as separate Form rows. The native Chevron-only action
/// lacked a useful label/hit area on iOS 17, so the disclosure header is one
/// explicit, full-row semantic button using the normal expansion binding.
@MainActor struct LabeledFormDisclosureStyle: DisclosureGroupStyle {
    let label: String
    let identifier: String
    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        Button { configuration.isExpanded.toggle() } label: {
            HStack {
                configuration.label
                Spacer(minLength: 12)
                Image(systemName: configuration.isExpanded ? "chevron.down" : "chevron.forward")
                    .font(.body.weight(.semibold)).foregroundStyle(.tint).accessibilityHidden(true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier(identifier)
        .accessibilityLabel(label)
        .accessibilityValue(configuration.isExpanded ? Text("Expanded") : Text("Collapsed"))
        if configuration.isExpanded { configuration.content }
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
            .foregroundStyle(isEnabled ? Theme.onAction : Theme.ink)
            // Normalize label rendering only; the enclosing control keeps its disabled state.
            .environment(\.isEnabled, true)
            .background(isEnabled ? Theme.action : Theme.surface, in: RoundedRectangle(cornerRadius: 14))
            .overlay {
                if !isEnabled {
                    RoundedRectangle(cornerRadius: 14)
                        .strokeBorder(Theme.controlEdge, lineWidth: 1)
                        .accessibilityHidden(true)
                }
            }
            .opacity(isEnabled && isPressed ? 0.8 : 1)
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
