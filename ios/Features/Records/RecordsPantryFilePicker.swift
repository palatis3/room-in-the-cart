import SwiftUI
import UIKit
import UniformTypeIdentifiers

extension UTType {
    static let pantryRecoveryPackage = UTType(exportedAs: "com.roominthecart.pantry-recovery", conformingTo: .package)
}

/// Presents the worker's encrypted directory directly; no FileWrapper or whole
/// archive Data is constructed here. The owner rechecks its operation and live
/// authorization before adopting a result. A selected import URL is only valid
/// for coordinated reading during the awaited completion, not for later storage.
struct RecordsPantryFilePicker: View {
    enum Mode: Equatable {
        case exportPackage(URL)
        case importPackage
    }
    enum Failure: Error { case invalidSelection }
    enum Outcome {
        /// Files confirmed a copy at this URL. Merely presenting or dismissing
        /// the picker never establishes that an export succeeded.
        case exported(URL)
        case selectedForImport(URL)
        case cancelled
        case failed(Failure)
    }

    let operationID: UUID
    let mode: Mode
    let didPresent: @MainActor (UUID) -> Void
    let didDismiss: @MainActor (UUID) async -> Void
    var willComplete: @MainActor (UUID) -> Void = { _ in }
    let completion: @MainActor (UUID, Outcome) async -> Void

    var body: some View {
        Picker(operationID: operationID, mode: mode, didPresent: didPresent, didDismiss: didDismiss, willComplete: willComplete, completion: completion)
            .id(operationID)
    }

    private struct Picker: UIViewControllerRepresentable {
        let operationID: UUID
        let mode: Mode
        let didPresent: @MainActor (UUID) -> Void
        let didDismiss: @MainActor (UUID) async -> Void
        let willComplete: @MainActor (UUID) -> Void
        let completion: @MainActor (UUID, Outcome) async -> Void

        func makeCoordinator() -> Coordinator {
            Coordinator(operationID: operationID, mode: mode, didDismiss: didDismiss, willComplete: willComplete, completion: completion)
        }
        func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
            let controller: UIDocumentPickerViewController
            switch mode {
            case .exportPackage(let url):
                // Keep the protected source until the owning worker explicitly
                // retires it. Files receives a copy, never ownership of staging.
                controller = UIDocumentPickerViewController(forExporting: [url], asCopy: true)
            case .importPackage:
                controller = UIDocumentPickerViewController(forOpeningContentTypes: [.pantryRecoveryPackage], asCopy: false)
            }
            controller.allowsMultipleSelection = false
            controller.shouldShowFileExtensions = true
            context.coordinator.attach(controller)
            didPresent(operationID)
            controller.delegate = context.coordinator
            controller.presentationController?.delegate = context.coordinator
            return controller
        }
        func updateUIViewController(_ controller: UIDocumentPickerViewController, context: Context) {
            guard context.coordinator.operationID == operationID, context.coordinator.mode == mode else {
                // A mode/source change must create a new operation, not rebind
                // an already-presented picker to a different encrypted export.
                context.coordinator.invalidate()
                controller.delegate = nil
                controller.dismiss(animated: false)
                return
            }
            controller.presentationController?.delegate = context.coordinator
        }
        static func dismantleUIViewController(_ controller: UIDocumentPickerViewController, coordinator: Coordinator) {
            coordinator.dismantle()
            controller.delegate = nil
            controller.presentationController?.delegate = nil
        }
    }

    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate, UIAdaptivePresentationControllerDelegate {
        let operationID: UUID
        let mode: Mode
        private let didDismiss: @MainActor (UUID) async -> Void
        private let willComplete: @MainActor (UUID) -> Void
        private let completion: @MainActor (UUID, Outcome) async -> Void
        private weak var controller: UIDocumentPickerViewController?
        private var finished = false
        private var invalidated = false

        init(operationID: UUID, mode: Mode, didDismiss: @escaping @MainActor (UUID) async -> Void = { _ in }, willComplete: @escaping @MainActor (UUID) -> Void = { _ in }, completion: @escaping @MainActor (UUID, Outcome) async -> Void) {
            self.operationID = operationID; self.mode = mode; self.didDismiss = didDismiss; self.willComplete = willComplete; self.completion = completion
        }
        func attach(_ controller: UIDocumentPickerViewController) { self.controller = controller }
        func invalidate() {
            invalidated = true; controller = nil
            // Do not cancel an accepted import. Its task owns the security scope
            // until the worker returns; the owner separately rejects stale results.
        }
        func dismantle() {
            invalidate()
            let callback = didDismiss, operation = operationID
            Task { @MainActor in await callback(operation) }
        }
        private func accept(_ candidate: UIDocumentPickerViewController) -> Bool {
            guard !invalidated, !finished, candidate === controller else { return false }
            finished = true
            willComplete(operationID)
            return true
        }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) {
            guard accept(controller) else { return }
            guard urls.count == 1, let url = urls.first, url.isFileURL else {
                deliver(.failed(.invalidSelection)); return
            }
            switch mode {
            case .exportPackage:
                deliver(.exported(url))
            case .importPackage:
                // Acquire before scheduling so a normal picker dismantle cannot
                // end access between delegate selection and the worker's read.
                // False can mean an app-owned URL; the bounded reader decides.
                let scoped = url.startAccessingSecurityScopedResource()
                let callback = completion, operation = operationID
                Task { @MainActor in
                    defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                    await callback(operation, .selectedForImport(url))
                }
            }
        }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) {
            guard accept(controller) else { return }
            deliver(.cancelled)
        }
        func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
            guard let controller = presentationController.presentedViewController as? UIDocumentPickerViewController,
                  accept(controller) else { return }
            deliver(.cancelled)
        }
        private func deliver(_ outcome: Outcome) {
            let callback = completion, operation = operationID
            Task { @MainActor in await callback(operation, outcome) }
        }
    }
}
