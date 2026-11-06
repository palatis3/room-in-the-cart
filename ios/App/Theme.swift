import SwiftUI
#if DEBUG
import Darwin
import OSLog
import UIKit
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
    #if DEBUG
    @MainActor
    #endif
    func keyboardDoneAction(visible: Bool, title: String, identifier: String? = nil, diagnosticFile: StaticString = #fileID, dismiss: @escaping () -> Void) -> some View {
        safeAreaInset(edge: .bottom, spacing: 0) {
            if visible {
                HStack {
                    Spacer()
                    Button(action: {
                        #if DEBUG
                        SpanishDoneDiagnostic.record(.doneEnter, scope: SpanishDoneDiagnostic.scope(for: diagnosticFile))
                        #endif
                        dismiss()
                        #if DEBUG
                        SpanishDoneDiagnostic.record(.doneExit, scope: SpanishDoneDiagnostic.scope(for: diagnosticFile))
                        #endif
                    }) {
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
        #if DEBUG
        .onAppear { SpanishDoneDiagnostic.start() }
        .onChange(of: visible) { _, value in
            SpanishDoneDiagnostic.record(value ? .focusVisible : .focusHidden, scope: SpanishDoneDiagnostic.scope(for: diagnosticFile))
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
/// Diagnostic-only fixed-token events. Never logs field text, models or notification payloads.
@MainActor
enum SpanishDoneDiagnostic {
    enum Event: String, Sendable {
        case installed = "observer.installed"
        case doneEnter = "done.enter", doneExit = "done.exit"
        case focusVisible = "focus.visible", focusHidden = "focus.hidden"
        case itemName = "comparison.focus.itemName", needed = "comparison.focus.needed"
        case aQuantity = "comparison.focus.aQuantity", aPrice = "comparison.focus.aPrice"
        case bQuantity = "comparison.focus.bQuantity", bPrice = "comparison.focus.bPrice"
        case none = "comparison.focus.none", other = "comparison.focus.other"
        case willShow = "keyboard.willShow", didShow = "keyboard.didShow"
        case willHide = "keyboard.willHide", didHide = "keyboard.didHide"
        case willFrame = "keyboard.willChangeFrame", didFrame = "keyboard.didChangeFrame"
        case fieldBegin = "textField.beginEditing", fieldEnd = "textField.endEditing"
        case viewBegin = "textView.beginEditing", viewEnd = "textView.endEditing"
    }
    enum Scope: String { case process, comparison, other }

    static func scope(for file: StaticString) -> Scope {
        String(describing: file).hasSuffix("/ComparisonView.swift") ? .comparison : .other
    }

    static let enabled = ProcessInfo.processInfo.environment["RITC_SPANISH_DONE_DIAGNOSTIC"] == "1"
    private static let logger = Logger(subsystem: "dev.roominthecart.spanishdone", category: "events")
    private static var started = false
    private static var journal: FileHandle?
    private static var observers: [NSObjectProtocol] = []
    private static var sequence = 0
    private static var bytes = 0

    static func start() {
        guard enabled, !started else { return }
        started = true
        do {
            let directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("SpanishDoneDiagnostic", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            let path = directory.appendingPathComponent("process-\(getpid()).events").path
            let descriptor = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, S_IRUSR | S_IWUSR)
            guard descriptor >= 0 else { fail("open"); return }
            journal = FileHandle(fileDescriptor: descriptor, closeOnDealloc: true)
        } catch { fail("directory"); return }
        let notifications: [(Notification.Name, Event)] = [
            (UIResponder.keyboardWillShowNotification, .willShow),
            (UIResponder.keyboardDidShowNotification, .didShow),
            (UIResponder.keyboardWillHideNotification, .willHide),
            (UIResponder.keyboardDidHideNotification, .didHide),
            (UIResponder.keyboardWillChangeFrameNotification, .willFrame),
            (UIResponder.keyboardDidChangeFrameNotification, .didFrame),
            (UITextField.textDidBeginEditingNotification, .fieldBegin),
            (UITextField.textDidEndEditingNotification, .fieldEnd),
            (UITextView.textDidBeginEditingNotification, .viewBegin),
            (UITextView.textDidEndEditingNotification, .viewEnd),
        ]
        observers = notifications.map { name, event in
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { _ in
                MainActor.assumeIsolated { record(event) }
            }
        }
        record(.installed)
    }

    static func focus(_ value: String?) {
        let event: Event
        switch value {
        case nil: event = .none
        case "itemName": event = .itemName
        case "needed": event = .needed
        case "aQuantity": event = .aQuantity
        case "aPrice": event = .aPrice
        case "bQuantity": event = .bQuantity
        case "bPrice": event = .bPrice
        default: event = .other
        }
        record(event, scope: .comparison)
    }

    static func record(_ event: Event, scope: Scope = .process) {
        guard enabled else { return }
        start()
        guard let journal else { return }
        let line = "SDD1|\(getpid())|\(sequence + 1)|\(ProcessInfo.processInfo.systemUptime)|\(event.rawValue)|\(scope.rawValue)"
        let data = Data((line + "\n").utf8)
        guard sequence < 2048, bytes + data.count <= 262144 else { fail("limit"); return }
        do {
            // FileHandle writes immediately; no user-space log buffer or per-event fsync.
            try journal.write(contentsOf: data)
            sequence += 1
            bytes += data.count
            logger.notice("\(line, privacy: .public)")
        } catch { fail("write") }
    }

    private static func fail(_ reason: String) {
        journal = nil
        logger.error("SDD_ERROR|\(getpid(), privacy: .public)|\(reason, privacy: .public)")
    }
}
#endif
