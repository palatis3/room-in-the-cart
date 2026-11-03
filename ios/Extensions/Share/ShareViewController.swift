import UIKit
import SwiftUI
import UniformTypeIdentifiers
import DeviceSurfaces

final class ShareViewController: UIViewController {
    private let model = ShareComposerModel()
    private var generation = UUID()
    override func viewDidLoad() {
        super.viewDidLoad()
        model.onCancel = { [weak self] in
            self?.generation = UUID()
            self?.extensionContext?.cancelRequest(withError: NSError(domain: NSCocoaErrorDomain, code: NSUserCancelledError))
        }
        model.onSaved = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let hosted = UIHostingController(rootView: ShareComposerView(model: model))
        addChild(hosted); hosted.view.translatesAutoresizingMaskIntoConstraints = false; view.addSubview(hosted.view)
        NSLayoutConstraint.activate([hosted.view.leadingAnchor.constraint(equalTo: view.leadingAnchor), hosted.view.trailingAnchor.constraint(equalTo: view.trailingAnchor), hosted.view.topAnchor.constraint(equalTo: view.topAnchor), hosted.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)])
        hosted.didMove(toParent: self)
        loadSelectedText()
    }
    private func loadSelectedText() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], items.count == 1 else { model.reject(); return }
        if let text = items[0].attributedContentText?.string, !text.isEmpty { model.accept(text); return }
        let providers = (items[0].attachments ?? []).filter { $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) }
        guard providers.count == 1 else { model.reject(); return }
        let expected = generation
        providers[0].loadItem(forTypeIdentifier: UTType.plainText.identifier, options: nil) { [weak self] item, error in
            let text: String?
            if let value = item as? String { text = value }
            else if let data = item as? Data, data.count <= SelectedTextInbox.maximumEntryBytes { text = String(data: data, encoding: .utf8) }
            else { text = nil }
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                guard error == nil, let text else { self.model.reject(); return }
                self.model.accept(text)
            }
        }
    }
}

@MainActor private final class ShareComposerModel: ObservableObject {
    @Published var original = ""
    @Published var edited = ""
    @Published var loading = true
    @Published var saving = false
    @Published var error: String?
    var onCancel: (() -> Void)?
    var onSaved: (() -> Void)?
    private let session = SelectedTextSession()
    func accept(_ text: String) {
        guard text.utf8.count <= SelectedTextInbox.maximumEntryBytes, !text.contains("\0"), text.split(separator: "\n", omittingEmptySubsequences: false).count <= SelectedTextInbox.maximumLines else { reject(); return }
        original = text; edited = text; loading = false
    }
    func reject() { loading = false; error = SurfaceCopy.text("Select a shorter plain-text list and try again.") }
    func cancel() {
        guard !saving else { return }
        saving = true
        Task { try? await session.cancel(); onCancel?() }
    }
    func save() {
        guard !saving, !loading, !original.isEmpty else { return }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let inbox = try IOSSurfaceContainers.inbox()
                let result = try await session.save(original: original, edited: edited == original ? nil : edited, now: Date(), inbox: inbox)
                guard result.disposition == .pending else { throw SurfaceError.stale }
                onSaved?()
            } catch { self.error = SurfaceCopy.text("Could not save for review. Try again or cancel; your shopping list is unchanged.") }
        }
    }
}
private struct ShareComposerView: View {
    @ObservedObject var model: ShareComposerModel
    var body: some View {
        NavigationStack {
            Form {
                Text(SurfaceCopy.text("Save selected text for review in Room in the Cart. Nothing is added to a shop yet."))
                if model.loading { ProgressView() }
                if !model.original.isEmpty {
                    Section(SurfaceCopy.text("Original text")) { Text(model.original).textSelection(.enabled) }
                    Section(SurfaceCopy.text("Review text")) { TextEditor(text: $model.edited).frame(minHeight: 140).accessibilityLabel(SurfaceCopy.text("Review text")) }
                    Button(SurfaceCopy.text("Save for review")) { model.save() }.frame(minHeight: 44).disabled(model.saving || model.edited.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
                if let error = model.error { Text(error).accessibilityAddTraits(.updatesFrequently) }
            }.disabled(model.saving).navigationTitle(SurfaceCopy.text("Selected text"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(SurfaceCopy.text("Cancel")) { model.cancel() }.disabled(model.saving) } }
                .interactiveDismissDisabled(model.saving)
        }
    }
}
