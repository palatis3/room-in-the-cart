import SwiftUI
#if DEBUG
import UIKit
import OSLog
#endif

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
        configuration.label.font(.headline).fixedSize(horizontal: false, vertical: true).frame(maxWidth: .infinity, minHeight: 44)
            .padding(.horizontal, 12).padding(.vertical, 4)
            .foregroundStyle(Theme.onAction).background(Theme.action, in: RoundedRectangle(cornerRadius: 14))
            .opacity(configuration.isPressed ? 0.8 : 1)
    }
}

extension View {
    @MainActor
    func keyboardDoneAction(visible: Bool, title: String, identifier: String? = nil, diagnosticFile: StaticString = #fileID, diagnosticLine: UInt = #line, dismiss: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if visible {
                HStack {
                    Spacer()
                    Button(title) {
                        #if DEBUG
                        KeyboardDiagnostic.record(.doneEnter, file: diagnosticFile, line: diagnosticLine)
                        #endif
                        dismiss()
                        #if DEBUG
                        KeyboardDiagnostic.record(.doneExit, file: diagnosticFile, line: diagnosticLine)
                        #endif
                    }
                        .font(.body.weight(.semibold)).frame(minHeight: 44)
                        .accessibilityIdentifier(identifier ?? title)
                }
                .padding(.horizontal).background(.bar)
            }
        }
        #if DEBUG
        .onAppear { KeyboardDiagnostic.start() }
        .onChange(of: visible) { _, focused in
            KeyboardDiagnostic.record(focused ? .focusIndicatorOn : .focusIndicatorOff,
                                      file: diagnosticFile, line: diagnosticLine)
        }
        #endif
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

#if DEBUG
/// Opt-in event-only diagnostics. No field values, identifiers, or notification payloads.
@MainActor
enum KeyboardDiagnostic {
    enum Event: String, Sendable {
        case observerInstalled = "observer.installed"
        case doneEnter = "done.enter", doneExit = "done.exit"
        case focusIndicatorOn = "focusIndicator.on", focusIndicatorOff = "focusIndicator.off"
        case stockFocusOn = "stock.focus.on", stockFocusOff = "stock.focus.off"
        case stockToggleTrue = "stock.toggle.setter.true", stockToggleFalse = "stock.toggle.setter.false"
        case stockResetAmount = "stock.reset.amount", stockResetFood = "stock.reset.food"
        case stockResetObservedAt = "stock.reset.observedAt", stockResetUseFirst = "stock.reset.useFirst"
        case keyboardWillShow = "keyboard.willShow", keyboardDidShow = "keyboard.didShow"
        case keyboardWillHide = "keyboard.willHide", keyboardDidHide = "keyboard.didHide"
        case keyboardWillChangeFrame = "keyboard.willChangeFrame", keyboardDidChangeFrame = "keyboard.didChangeFrame"
        case textFieldBegin = "textField.beginEditing", textFieldEnd = "textField.endEditing"
        case textViewBegin = "textView.beginEditing", textViewEnd = "textView.endEditing"
    }

    static let enabled = ProcessInfo.processInfo.environment["RITC_KEYBOARD_DIAGNOSTIC"] == "1"
    private static let logger = Logger(subsystem: "dev.roominthecart.keyboarddiagnostic", category: "events")
    // Intentionally process-lifetime observers, installed once only in an opted-in Debug app.
    private static var observers: [NSObjectProtocol] = []
    private static var started = false

    static func start() {
        guard enabled, !started else { return }
        started = true
        let events: [(Notification.Name, Event)] = [
            (UIResponder.keyboardWillShowNotification, .keyboardWillShow),
            (UIResponder.keyboardDidShowNotification, .keyboardDidShow),
            (UIResponder.keyboardWillHideNotification, .keyboardWillHide),
            (UIResponder.keyboardDidHideNotification, .keyboardDidHide),
            (UIResponder.keyboardWillChangeFrameNotification, .keyboardWillChangeFrame),
            (UIResponder.keyboardDidChangeFrameNotification, .keyboardDidChangeFrame),
            (UITextField.textDidBeginEditingNotification, .textFieldBegin),
            (UITextField.textDidEndEditingNotification, .textFieldEnd),
            (UITextView.textDidBeginEditingNotification, .textViewBegin),
            (UITextView.textDidEndEditingNotification, .textViewEnd),
        ]
        observers = events.map { name, event in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                // NotificationCenter's explicit main queue guarantees this executor;
                // do not send a non-Sendable Notification through a Task.
                MainActor.assumeIsolated { record(event) }
            }
        }
        record(.observerInstalled)
    }

    static func record(_ event: Event, file: StaticString = #fileID, line: UInt = #line) {
        guard enabled else { return }
        let timestamp = ProcessInfo.processInfo.systemUptime
        let name = event.rawValue
        let context = "\(file):\(line)"
        logger.info("uptime=\(timestamp, privacy: .public) event=\(name, privacy: .public) site=\(context, privacy: .public)")
    }
}
#endif
