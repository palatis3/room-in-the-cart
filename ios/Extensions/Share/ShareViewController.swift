import UIKit
import UniformTypeIdentifiers
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
        loadSelection()
    }
    private func loadSelection() {
        guard let items = extensionContext?.inputItems as? [NSExtensionItem], items.count == 1 else { model.reject(); return }
        let expected = generation
        let item = items[0]
        let providers = item.attachments ?? []
        if providers.count == 1, let provider = providers.first {
            let type: UTType?
            if provider.hasItemConformingToTypeIdentifier(UTType.pdf.identifier) { type = .pdf }
            else if provider.hasItemConformingToTypeIdentifier(UTType.image.identifier) { type = .image }
            else if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier),
                    provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                type = .plainText
            } else { type = nil }
            if let type {
                loadReceipt(provider, type: type, generation: expected)
                return
            }
        }
        let urls = providers.filter { $0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
        if !urls.isEmpty {
            let companions = providers.filter { !$0.hasItemConformingToTypeIdentifier(UTType.url.identifier) }
            guard urls.count == 1, let provider = urls.first, companions.count <= 1,
                  companions.allSatisfy({ $0.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) })
            else { model.rejectLink(); return }
            if let text = item.attributedContentText?.string,
               SelectedTextInbox.fitsEnvelope(original: text), !text.contains("\0"),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                model.alternativeText = text
            } else if let textProvider = companions.first {
                SelectedTextInbox.loadPlainText(from: textProvider) { [weak self] result in
                    Task { @MainActor [weak self] in
                        guard let self, self.generation == expected, case .success(let text) = result else { return }
                        self.model.alternativeText = text
                    }
                }
            }
            SharedCaptureEnvelope.loadRecipeURL(from: provider) { [weak self] result in
                Task { @MainActor [weak self] in
                    guard let self, self.generation == expected else { return }
                    switch result {
                    case .success(let link): self.model.accept(link)
                    case .failure: self.model.rejectLink()
                    }
                }
            }
            return
        }
        SelectedTextInbox.loadSelectedText(from: item) { [weak self] result in
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                switch result {
                case .success(let text): self.model.accept(text)
                case .failure(.capacity):
                    if let text = item.attributedContentText?.string, text.utf8.count <= SharedReceiptDescriptor.maximumBytes {
                        self.model.acceptReceipt(.success(Data(text.utf8)), kind: .text)
                    } else if providers.count == 1, let provider = providers.first,
                              provider.hasItemConformingToTypeIdentifier(UTType.plainText.identifier) {
                        self.loadReceipt(provider, type: .plainText, generation: expected)
                    } else { self.model.rejectSize() }
                case .failure: self.model.reject()
                }
            }
        }
    }
    private func loadReceipt(_ provider: NSItemProvider, type requested: UTType, generation expected: UUID) {
        let type = requested == .plainText ? provider.registeredTypeIdentifiers.compactMap { UTType($0) }
            .first { $0.conforms(to: .plainText) } ?? .plainText : requested
        let kind: SharedReceiptDescriptor.Kind = type == .pdf ? .pdf : type.conforms(to: .plainText) ? .text : .image
        provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { [weak self] url, _ in
            let result = Result { () throws -> Data in
                guard let url else { throw SurfaceError.unavailable }
                return try readRegularFile(at: url, maximumBytes: SharedReceiptDescriptor.maximumBytes)
            }
            Task { @MainActor [weak self] in
                guard let self, self.generation == expected else { return }
                self.model.acceptReceipt(result, kind: kind, type: type)
            }
        }
    }

}

@MainActor private final class ShareComposerModel: ObservableObject {
    @Published var receiptData: Data?
    private var receiptType: UTType?
    var receiptKind: SharedReceiptDescriptor.Kind = .text
    var fileForReceiptReview: Data? { original.isEmpty ? receiptData : nil }
    @Published var link: SharedCaptureEnvelope?
    @Published var alternativeText: String?
    private let operationID = UUID()
    @Published var original = ""
    @Published var edited = ""
    @Published var loading = true
    @Published var saving = false
    @Published var error: String?
    @Published var saveError: String?
    var onCancel: (() -> Void)?
    var onSaved: (() -> Void)?
    private let session = SelectedTextSession()
    func accept(_ link: SharedCaptureEnvelope) {
        self.link = link
        loading = false
    }
    func rejectLink() {
        loading = false
        error = SurfaceCopy.text("Choose one HTTPS recipe page, or share a plain-text shopping list.")
    }
    func chooseAlternativeText() {
        guard let alternativeText else { return }
        link = nil
        error = nil
        self.alternativeText = nil
        accept(alternativeText)
    }
    func acceptReceipt(_ result: Result<Data, Error>, kind: SharedReceiptDescriptor.Kind, type: UTType? = nil) {
        loading = false
        do {
            let bytes = try result.get()
            receiptData = bytes
            receiptKind = kind
            receiptType = type
            if let type, type.conforms(to: .plainText),
               let text = try? SelectedTextInbox.decodePlainText(bytes, type: type),
               (try? StagedListImport.validateSourceText(text, maximumLines: SelectedTextInbox.maximumLines)) != nil {
                alternativeText = text
            }
        } catch { self.error = SurfaceCopy.text("Choose one readable receipt file up to 10 MB.") }
    }

    func saveReceipt(_ data: Data, kind: SharedReceiptDescriptor.Kind) {
        guard !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let inbox: SharedCaptureInbox
                #if DEBUG && targetEnvironment(simulator)
                inbox = try ReceiptShareSystemFixture.registeredInbox(for: data, now: Date()) ?? IOSSurfaceContainers.sharedCaptures()
                #else
                inbox = try IOSSurfaceContainers.sharedCaptures()
                #endif
                let saved = try await inbox.stageReceipt(data, kind: kind, id: operationID, now: Date(), type: receiptType)
                guard saved.disposition == .pending else { throw SurfaceError.stale }
                onSaved?()
            } catch {
                saveError = SurfaceCopy.text("Could not stage this receipt. Open the private pantry to remove an older shared file, then try again.")
            }
        }
    }
    func saveLink() {
        guard let link, !saving else { return }
        saving = true
        Task {
            defer { saving = false }
            do {
                let inbox = try IOSSurfaceContainers.sharedCaptures()
                let receipt = try await inbox.stage(link, id: operationID, now: Date())
                guard receipt.disposition == .pending else { throw SurfaceError.stale }
                onSaved?()
            } catch {
                saveError = SurfaceCopy.text("Could not save this link. In Import a recipe link, paste the address or remove an older shared link and try again.")
            }
        }
    }
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
                Section {
                    introduction
                } header: {
                    HStack(spacing: 8) {
                        Image(decorative: "BrandCartRest").resizable().scaledToFit()
                            .frame(width: 32, height: 32)
                            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                        Text(verbatim: "Room in the Cart").font(.headline).foregroundStyle(Color("ink"))
                    }
                    .textCase(nil)
                    .padding(.bottom, 4)
                }
                .listRowBackground(Color("surface"))

                if !model.original.isEmpty {
                    Section(SurfaceCopy.text("Original text")) { Text(model.original).textSelection(.enabled) }
                        .listRowBackground(Color("surface"))
                    Section(SurfaceCopy.text("Review text")) {
                        TextEditor(text: $model.edited)
                            .scrollContentBackground(.hidden)
                            .frame(minHeight: 140)
                            .accessibilityLabel(SurfaceCopy.text("Review text"))
                    }.listRowBackground(Color("surface"))
                }
                Section {
                    if let bytes = model.fileForReceiptReview {
                        saveButton("Save receipt file for review") { model.saveReceipt(bytes, kind: model.receiptKind) }
                    } else if model.link != nil {
                        saveButton("Save recipe link for review") { model.saveLink() }
                    } else if !model.original.isEmpty {
                        saveButton("Save for review") { model.save() }
                            .disabled(!model.edited.unicodeScalars.contains { !CharacterSet.whitespacesAndNewlines.contains($0) })
                        Button(SurfaceCopy.text("Save original text as a receipt")) {
                            model.saveReceipt(model.receiptData ?? Data(model.original.utf8), kind: .text)
                        }
                    }
                    if !model.loading, model.alternativeText != nil {
                        Button(SurfaceCopy.text("Use the selected text as a shopping list")) { model.chooseAlternativeText() }
                    }
                }.listRowBackground(Color("surface"))
            }
            .disabled(model.saving)
            .scrollContentBackground(.hidden)
            .background(Color("canvas"))
            .alert(model.fileForReceiptReview != nil ? SurfaceCopy.text("Receipt file") : model.link == nil ? SurfaceCopy.text("Could not save selected text") : SurfaceCopy.text("Could not save recipe link"), isPresented: Binding(
                get: { model.saveError != nil },
                set: { if !$0 { model.saveError = nil } }
            ), presenting: model.saveError) { _ in
                Button(SurfaceCopy.text("OK")) { model.saveError = nil }
            } message: { Text($0) }
            .navigationTitle(model.fileForReceiptReview != nil ? SurfaceCopy.text("Receipt file") : model.link == nil ? SurfaceCopy.text("Selected text") : SurfaceCopy.text("Recipe link"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(SurfaceCopy.text("Cancel")) { model.cancel() }.disabled(model.saving) } }
            .interactiveDismissDisabled(model.saving)
        }.tint(Color("accent"))
    }

    @ViewBuilder private var introduction: some View {
        if model.loading {
            ProgressView()
        } else if let error = model.error {
            Label(error, systemImage: "exclamationmark.circle")
                .foregroundStyle(Color("error")).accessibilityAddTraits(.updatesFrequently)
        } else if model.fileForReceiptReview != nil {
            Text(SurfaceCopy.text("Open Read a receipt file in My Pantry to review within seven days. Sharing keeps the file on this device until review, discard or expiry."))
        } else if let link = model.link {
            Text(verbatim: link.value).textSelection(.enabled)
            Text(SurfaceCopy.text("Open Import a recipe link in Room in the Cart to review this link within seven days."))
        } else {
            Text(SurfaceCopy.text("Save selected text for review in Room in the Cart. Nothing is added to a shop yet."))
        }
    }

    private func saveButton(_ title: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(SurfaceCopy.text(title)).font(.headline)
                .foregroundStyle(Color("on_accent"))
                .frame(maxWidth: .infinity, minHeight: 44)
        }
        .buttonStyle(.borderedProminent)
        .listRowInsets(EdgeInsets(top: 6, leading: 12, bottom: 6, trailing: 12))
    }
}
