import SwiftUI

enum Theme {
    static let canvas = Color("canvas")
    static let surface = Color("surface")
    static let ink = Color("ink")
    static let secondary = Color("secondary")
    static let action = Color("accent")
    static let onAction = Color("on_accent")
    static let selection = Color("selection")
    static let onSelection = Color("on_selection")
    static let divider = Color("divider")
    static let focus = Color("focus")
    static let controlEdge = Color("control_edge")
    static let error = Color("error")
    static let errorSurface = Color("error_surface")
    static let warning = Color("warning")
    static let warningSurface = Color("warning_surface")
}

/// The mark is supplementary. The localized source text remains the only accessibility element.
enum JournalSourceKind {
    case shoppingList, pantryCount, receipt
}

struct JournalSourceLabel: View {
    let kind: JournalSourceKind?
    let title: String
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        if let kind {
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .firstTextBaseline, spacing: 7) {
                    JournalSourceMark(kind: kind)
                        .stroke(contrast == .increased ? Theme.ink : Theme.action, lineWidth: 2)
                        .frame(width: 18, height: 17)
                        .alignmentGuide(.firstTextBaseline) { $0.height - 3 }
                        .accessibilityHidden(true)
                        .allowsHitTesting(false)
                    Text(verbatim: title)
                }
                .fixedSize(horizontal: true, vertical: true)
                textOnly
            }
            .accessibilityRepresentation { Text(verbatim: title) }
        } else {
            textOnly
        }
    }

    private var textOnly: some View {
        Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
    }
}

private struct JournalSourceMark: Shape {
    let kind: JournalSourceKind

    func path(in rect: CGRect) -> Path {
        // Coordinates follow the same 18 × 17 grid as the printed source specimens.
        var mark = Path()
        func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
            CGPoint(x: rect.minX + x * rect.width / 18, y: rect.minY + y * rect.height / 17)
        }
        func rule(_ points: CGPoint...) {
            if let first = points.first {
                mark.move(to: first)
                for next in points.dropFirst() { mark.addLine(to: next) }
            }
        }
        switch kind {
        case .shoppingList:
            rule(point(3, 2), point(3, 15))
            rule(point(3, 4), point(15, 4))
            rule(point(3, 8), point(15, 8))
            rule(point(3, 12), point(10, 12))
        case .pantryCount:
            rule(point(3, 2), point(3, 14), point(15, 14), point(15, 2))
            rule(point(3, 5), point(9, 5))
            rule(point(3, 9), point(8, 9))
        case .receipt:
            rule(point(3, 2), point(15, 2), point(15, 14), point(12, 12),
                 point(9, 14), point(6, 12), point(3, 14))
            mark.closeSubpath()
            rule(point(6, 6), point(12, 6))
        }
        return mark
    }
}

/// A compact scope or selected-choice label. The supplied words carry the meaning in every appearance.
struct BrandScopeLabel: View {
    let title: String
    let systemImage: String
    let showsSelection: Bool
    @Environment(\.colorSchemeContrast) private var contrast

    init(_ title: String, systemImage: String, showsSelection: Bool = false) {
        self.title = title
        self.systemImage = systemImage
        self.showsSelection = showsSelection
    }

    var body: some View {
        Label {
            Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .font(.subheadline.weight(.semibold))
        .foregroundStyle(showsSelection ? Theme.onSelection : Theme.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(showsSelection ? Theme.selection : Theme.surface, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            if contrast == .increased {
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(Theme.controlEdge, lineWidth: 1)
                    .accessibilityHidden(true)
            }
        }
    }
}

/// The cart is decorative beside a named result or About caption. Offset is in display points.
/// Only the pear moves. Its pivot is registered to the lower body, just behind the cart rim.
struct BrandCartMark: View {
    var pearOffset: CGSize = .zero
    var pearAngle: Double = 0

    var body: some View {
        GeometryReader { geometry in
            let side = min(geometry.size.width, geometry.size.height)
            ZStack {
                Image(decorative: "BrandCartField").resizable()
                Image(decorative: "BrandCartPear").resizable()
                    .rotationEffect(.degrees(pearAngle), anchor: UnitPoint(x: 0.68, y: 0.47))
                    .offset(pearOffset)
                Image(decorative: "BrandCartFront").resizable()
            }
            .frame(width: side, height: side)
            .clipShape(RoundedRectangle(cornerRadius: side * 0.23, style: .continuous))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .aspectRatio(1, contentMode: .fit)
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}

/// Native form chrome uses the app's semantic colors in either appearance.
/// Keep row styling on the content, where Form consumes list-row preferences.
struct WorkingForm<Content: View>: View {
    private let content: Content
    @Environment(\.colorSchemeContrast) private var contrast
    @ScaledMetric(relativeTo: .body) private var sectionSpacing: CGFloat = 18

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        Form {
            Group { content }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(contrast == .increased ? Theme.controlEdge : Theme.divider)
        }
        .listSectionSpacing(sectionSpacing)
        .workingSurface()
    }
}

/// Native list content keeps its own sections, row identities and editing actions.
struct JournalList<Content: View>: View {
    @Environment(\.colorSchemeContrast) private var contrast
    private let content: Content

    init(@ViewBuilder content: () -> Content) {
        self.content = content()
    }

    var body: some View {
        List {
            Group { content }
                .listRowBackground(Theme.surface)
                .listRowSeparatorTint(contrast == .increased ? Theme.controlEdge : Theme.divider)
        }
        .workingSurface()
    }
}

/// A secondary action within a journal list. Its enclosing button owns the operation.
struct JournalActionLabel: View {
    let title: String
    let systemImage: String

    init(_ title: String, systemImage: String) {
        self.title = title
        self.systemImage = systemImage
    }

    var body: some View {
        Label {
            Text(verbatim: title).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: systemImage).accessibilityHidden(true)
        }
        .font(.body.weight(.medium))
        .foregroundStyle(Theme.action)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
        .accessibilityLabel(title)
    }
}

/// Give a menu label and its selected value separate lines at accessibility text sizes.
func journalStackedMenu<Content: View>(_ title: String, value: String, id: String,
                                        @ViewBuilder content: () -> Content) -> some View {
    Menu(content: content) {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.subheadline).foregroundStyle(Theme.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(value).foregroundStyle(Theme.action)
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").imageScale(.small)
                    .foregroundStyle(Theme.action).accessibilityHidden(true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
        .contentShape(Rectangle())
    }
    .accessibilityLabel(title).accessibilityValue(value).accessibilityIdentifier(id)
}

/// One input with a name that remains visible after a value has been entered.
struct WorkingField<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.subheadline.weight(.medium)).foregroundStyle(Theme.secondary)
                .lineLimit(nil).fixedSize(horizontal: false, vertical: true)
                .accessibilityHidden(true)
            content.accessibilityLabel(title)
        }
        .padding(.vertical, 3)
    }
}

/// The item stays prominent while the detail identifies its location, source or count.
struct WorkingRecordHeading: View {
    let title: String
    let detail: String
    let systemImage: String
    @Environment(\.dynamicTypeSize) private var typeSize

    init(_ title: String, detail: String, systemImage: String) {
        self.title = title
        self.detail = detail
        self.systemImage = systemImage
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if !typeSize.isAccessibilitySize {
                Image(systemName: systemImage)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(Theme.onSelection)
                    .frame(width: 40, height: 40)
                    .background(Theme.selection, in: RoundedRectangle(cornerRadius: 12))
                    .accessibilityHidden(true)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.title2.weight(.semibold)).foregroundStyle(Theme.ink)
                Text(detail).font(.subheadline).foregroundStyle(Theme.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 4)
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
                // Reserve both symbol widths so expansion cannot rewrap the label.
                ZStack {
                    Image(systemName: "chevron.down").opacity(configuration.isExpanded ? 1 : 0)
                    Image(systemName: "chevron.forward").opacity(configuration.isExpanded ? 0 : 1)
                }
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
struct WorkingInputStyle: TextFieldStyle {
    func _body(configuration: TextField<Self._Label>) -> some View {
        configuration
            .textFieldStyle(.roundedBorder)
            .overlay {
                RoundedRectangle(cornerRadius: 5)
                    .strokeBorder(Theme.controlEdge, lineWidth: 1)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
    }
}

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
    @Environment(\.isFocused) private var isFocused

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
                } else if isPressed {
                    RoundedRectangle(cornerRadius: 14)
                        .inset(by: 3)
                        .strokeBorder(Theme.onAction, lineWidth: 1)
                        .accessibilityHidden(true)
                }
                if isFocused {
                    RoundedRectangle(cornerRadius: 14)
                        .inset(by: -3)
                        .strokeBorder(Theme.surface, lineWidth: 3)
                    RoundedRectangle(cornerRadius: 14)
                        .inset(by: -6)
                        .strokeBorder(Theme.focus, lineWidth: 3)
                }
            }
    }
}

struct PrimaryAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        PrimaryActionLabel(label: configuration.label, isPressed: configuration.isPressed)
    }
}

extension View {
    /// Use on editorial headings. Food quantities, prices and form controls use native body styles.
    func marketJournalTitle(_ style: Font.TextStyle = .title) -> some View {
        font(.system(style, design: .serif, weight: .semibold))
            .foregroundStyle(Theme.ink)
            .accessibilityAddTraits(.isHeader)
    }

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
