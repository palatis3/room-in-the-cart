import SwiftUI

enum Theme {
    static let canvas = Color("canvas")
    static let surface = Color("surface")
    static let ink = Color("ink")
    static let secondary = Color("secondary")
    static let action = Color("accent")
    static let onAction = Color("on_accent")
    static let warning = Color("warning")
    static let warningSurface = Color("warning_surface")
}

struct PrimaryAction: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.headline).frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(Theme.onAction).background(Theme.action, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension View {
    func workingSurface() -> some View {
        self.scrollContentBackground(.hidden).background(Theme.canvas).foregroundStyle(Theme.ink)
    }
}
