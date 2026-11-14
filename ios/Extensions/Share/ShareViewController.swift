import UIKit
import SwiftUI
import DeviceSurfaces
import CoreDomain

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
        let expected = generation
        SelectedTextInbox.loadSelectedText(from: items[0]) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                switch result {
                case .success(let text): self.model.accept(text)
                case .failure(.capacity): self.model.rejectSize()
                case .failure: self.model.reject()
                }
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
    @Published var saveError: String?
    var onCancel: (() -> Void)?
    var onSaved: (() -> Void)?
    private let session = SelectedTextSession()
    func accept(_ text: String) {
        original = text; edited = text; loading = false
    }
    private var sizeMessage: String {
        SurfaceCopy.text("Share up to 500 lines and 64 KiB of plain text, including edits. Choose a smaller selection or shorten the edit.")
    }
    func rejectSize() {
        loading = false
        error = sizeMessage
    }
    func reject() { loading = false; error = SurfaceCopy.text("Select a shorter plain-text list and try again.") }
    func cancel() {
        guard !saving else { return }
        saving = true
        Task { try? await session.cancel(); onCancel?() }
    }
    func save() {
        guard !saving, !loading, !original.isEmpty else { return }
        // Canonically equivalent spellings can fall on opposite sides of the UTF-8 limit.
        let reviewEdit = edited.utf8.elementsEqual(original.utf8) ? nil : edited
        guard SelectedTextInbox.fitsEnvelope(original: original, edited: reviewEdit) else { saveError = sizeMessage; return }
        do {
            try StagedListImport.validateSourceText(reviewEdit ?? original, maximumLines: SelectedTextInbox.maximumLines)
        } catch ImportTextLimit.originalLineBytes(let item) {
            let format = SurfaceCopy.text("Shorten item %lld to %lld UTF-8 bytes or less.")
            saveError = String(format: format, locale: Locale.current, Int64(item), Int64(StagedListImport.maximumOriginalLineBytes))
            return
        } catch {
            saveError = sizeMessage
            return
        }
        saving = true; error = nil
        Task {
            defer { saving = false }
            do {
                let inbox = try IOSSurfaceContainers.inbox()
                let result = try await session.save(original: original, edited: reviewEdit, now: Date(), inbox: inbox)
                guard result.disposition == .pending else { throw SurfaceError.stale }
                onSaved?()
            } catch SelectedTextInbox.ReviewLimit.tooManyItems {
                self.saveError = sizeMessage
            } catch SelectedTextInbox.ReviewLimit.receiptLimitReached {
                self.saveError = SurfaceCopy.text("This device has reached its limit for shared lists. Open your shopping list in Room in the Cart and paste the text there.")
            } catch SurfaceError.capacity {
                self.saveError = SurfaceCopy.text("The share inbox is full. In Room in the Cart, open Shop, then Device shortcuts. Review or discard saved text to make room.")
            } catch { self.saveError = SurfaceCopy.text("Could not save for review. Try again or cancel; your shopping list is unchanged.") }
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
                    Button(SurfaceCopy.text("Save for review")) { model.save() }
                        .frame(minHeight: 44)
                        .disabled(model.saving || !model.edited.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) })
                }
                if let error = model.error { Text(error).accessibilityAddTraits(.updatesFrequently) }
            }.disabled(model.saving)
                .alert(SurfaceCopy.text("Could not save selected text"), isPresented: Binding(
                    get: { model.saveError != nil },
                    set: { if !$0 { model.saveError = nil } }
                ), presenting: model.saveError) { _ in
                    Button(SurfaceCopy.text("OK")) { model.saveError = nil }
                } message: { Text($0) }
                .navigationTitle(SurfaceCopy.text("Selected text"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(SurfaceCopy.text("Cancel")) { model.cancel() }.disabled(model.saving) } }
                .interactiveDismissDisabled(model.saving)
        }
    }
}
