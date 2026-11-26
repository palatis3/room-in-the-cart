import CoreDomain
import LocalStore
import PhotosUI
import SwiftUI
import UniformTypeIdentifiers

/// A note is written against the source revision on screen. Moving an older note
/// always requires choosing and reviewing the destination instruction.
struct CookingStepNoteView: View {
    @ObservedObject var model: CookingSessionModel
    let steps: [RecipeStep]
    let index: Int
    let noteFocus: FocusState<Bool>.Binding
    @State private var editor: Editor?
    @State private var showHidden = false
    @State private var exporting = false
    @State private var document: RecordsFileDocument?
    @Environment(\.scenePhase) private var phase

    private struct Editor: Identifiable {
        let id = UUID()
        let previous: CookingStepNote?
        let step: Int
        let instruction: String
        var editingPhoto = false
    }
    private var instruction: String? {
        steps.indices.contains(index) && !steps[index].instruction.isEmpty ? steps[index].instruction : nil
    }
    private var attached: [CookingStepNote] {
        guard let instruction else { return [] }
        return model.stepNotes.filter { $0.belongs(to: model.context.noteKey, step: index, instruction: instruction) }
    }
    private var unresolved: [CookingStepNote] {
        model.stepNotes.filter { note in
            !steps.indices.contains(note.step) || !note.belongs(to: model.context.noteKey, step: note.step, instruction: steps[note.step].instruction)
        }
    }

    var body: some View {
        if model.permitsStepNotes, instruction != nil || !unresolved.isEmpty {
            Section(cookCompletionText("My note for this step")) {
                if let editor {
                    if editor.editingPhoto {
                        CookingStepPhotoEditor(model: model, previous: editor.previous, index: editor.step, instruction: editor.instruction,
                            focus: noteFocus, finish: { self.editor = nil })
                            .id(editor.id)
                    } else {
                        CookingNoteEditor(model: model, previous: editor.previous, index: editor.step, instruction: editor.instruction,
                            focus: noteFocus, finish: { self.editor = nil })
                            .id(editor.id)
                    }
                } else if let instruction {
                    ForEach(attached.filter { !$0.hidden || showHidden }) { note in
                        if !note.text.isEmpty { Text(verbatim: note.text).textSelection(.enabled) }
                        if let photo = note.photo {
                            cookingStepPhotoPreview(photo.jpeg, description: photo.description)
                        }
                        Button(cookCompletionText(note.photo == nil ? "Add a private step photo" : "Edit step photo")) {
                            editor = .init(previous: note, step: index, instruction: instruction, editingPhoto: true)
                        }
                        Button(cookCompletionText(note.text.isEmpty ? "Add a private note" : "Edit note")) { editor = .init(previous: note, step: index, instruction: instruction) }
                        Button(cookCompletionText(note.hidden ? "Show note on this step" : "Hide note on this step")) {
                            model.setStepNote(note, with: CookingStepNote(id: note.id, revision: note.revision, step: note.step,
                                instruction: note.instruction, text: note.text, hidden: !note.hidden, photo: note.photo))
                        }
                        exportButton(note)
                    }
                    if attached.contains(where: \.hidden) {
                        Toggle(cookCompletionText("View hidden notes"), isOn: $showHidden)
                    }
                    if attached.isEmpty {
                        Button(cookCompletionText("Add a private note")) { editor = .init(previous: nil, step: index, instruction: instruction) }
                            .accessibilityIdentifier("cooking.stepNote.add")
                        Button(cookCompletionText("Add a private step photo")) {
                            editor = .init(previous: nil, step: index, instruction: instruction, editingPhoto: true)
                        }.accessibilityIdentifier("cooking.stepPhoto.add")
                    }
                }
                if editor == nil && !unresolved.isEmpty {
                    DisclosureGroup(cookCompletionText("Notes from earlier instructions")) {
                        ForEach(unresolved) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: note.instruction).font(.caption)
                                if !note.text.isEmpty { Text(verbatim: note.text) }
                                if let photo = note.photo { cookingStepPhotoPreview(photo.jpeg, description: photo.description) }
                                exportButton(note)
                                if let instruction, attached.isEmpty {
                                    Button(cookCompletionText("Review moving to this step")) {
                                        editor = .init(previous: note, step: index, instruction: instruction)
                                    }
                                }
                                Button(cookCompletionText(note.photo == nil ? "Delete note" : "Delete note and photo"), role: .destructive) {
                                    model.setStepNote(note, with: nil)
                                }
                            }.buttonStyle(.borderless)
                        }
                    }
                }
            }
            .fileExporter(isPresented: $exporting, document: document, contentType: .plainText,
                          defaultFilename: cookCompletionText("My cooking note")) { _ in document = nil }
            .onChange(of: phase) { _, phase in if phase == .background { exporting = false; document = nil; editor = nil } }
            .onDisappear { exporting = false; document = nil }
        }
    }

    private func exportButton(_ note: CookingStepNote) -> some View {
        Button(cookCompletionText("Export this note as text")) {
            guard let current = model.currentStepNote(note) else { return }
            let text = [current.text, current.photo?.description].compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
            document = RecordsFileDocument(data: Data(text.utf8), kind: .text)
            exporting = true
        }
    }

}

private struct CookingNoteEditor: View {
    @ObservedObject var model: CookingSessionModel
    let previous: CookingStepNote?
    let index: Int
    let instruction: String
    let finish: () -> Void
    @State private var text: String
    let focus: FocusState<Bool>.Binding

    init(model: CookingSessionModel, previous: CookingStepNote?, index: Int, instruction: String, focus: FocusState<Bool>.Binding,
         finish: @escaping () -> Void) {
        self.focus = focus
        self.model = model; self.previous = previous; self.index = index; self.instruction = instruction; self.finish = finish
        _text = State(initialValue: previous?.text ?? "")
    }

    var body: some View {
        if model.permitsStepNotes {
            if let previous, !previous.belongs(to: model.context.noteKey, step: index, instruction: instruction) {
                Text(String(format: recordsText("Step %lld"), Int64(index + 1)) + " · " + instruction)
                if let photo = previous.photo { cookingStepPhotoPreview(photo.jpeg, description: photo.description) }
            }
            VStack(alignment: .leading, spacing: 6) {
                let prompt = cookCompletionText("What would you change next time?")
                Text(prompt).font(.subheadline).accessibilityHidden(true)
                TextEditor(text: $text)
                    .focused(focus)
                    .accessibilityLabel(prompt)
                    .accessibilityIdentifier("cooking.stepNote.text")
                    .font(.body).frame(minHeight: 76)
                    .overlay {
                        RoundedRectangle(cornerRadius: 5)
                            .strokeBorder(Theme.controlEdge, lineWidth: 1)
                            .allowsHitTesting(false).accessibilityHidden(true)
                    }
            }
            Button(cookCompletionText("Save note")) {
                let next = CookingStepNote(id: previous?.id ?? UUID(), revision: model.context.noteKey.revision, step: index,
                    instruction: instruction, text: text, hidden: false, photo: previous?.photo)
                if model.setStepNote(previous, with: next) { focus.wrappedValue = false; finish() }
            }.disabled((text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && previous?.photo == nil) || text.utf8.count > 2048)
            .accessibilityIdentifier("cooking.stepNote.save")
            Button(recordsText("Cancel")) { focus.wrappedValue = false; finish() }
            if let previous {
                Button(cookCompletionText(previous.photo == nil ? "Delete note" : "Delete note and photo"), role: .destructive) {
                    if model.setStepNote(previous, with: nil) { focus.wrappedValue = false; finish() }
                }
            }
            if let message = model.message { Text(message) }
        }
    }
}

@ViewBuilder private func cookingStepPhotoPreview(_ data: Data, description: String) -> some View {
    if let image = UIImage(data: data) {
        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 220)
            .accessibilityHidden(true)
    }
    if !description.isEmpty {
        Text(verbatim: description).font(.subheadline)
            .accessibilityLabel(cookCompletionText("Step photo") + ", " + description)
    }
}

private struct CookingStepPhotoEditor: View {
    @ObservedObject var model: CookingSessionModel
    let previous: CookingStepNote?
    let index: Int
    let instruction: String
    let focus: FocusState<Bool>.Binding
    let finish: () -> Void
    @State private var jpeg: Data?
    @State private var cue: String
    @State private var selection: PhotosPickerItem?
    @State private var failure = false
    @State private var loadedSelection: PhotosPickerItem?

    init(model: CookingSessionModel, previous: CookingStepNote?, index: Int, instruction: String,
         focus: FocusState<Bool>.Binding, finish: @escaping () -> Void) {
        self.model = model
        self.previous = previous
        self.index = index
        self.instruction = instruction
        self.focus = focus
        self.finish = finish
        _jpeg = State(initialValue: previous?.photo?.jpeg)
        _cue = State(initialValue: previous?.photo?.description ?? "")
    }

    private var photo: CookingStepPhoto? {
        jpeg.map { CookingStepPhoto(jpeg: $0, description: cue) }
    }

    var body: some View {
        if model.permitsStepNotes {
            PhotosPicker(selection: $selection, matching: .images, preferredItemEncoding: .current) {
                Label(cookCompletionText(jpeg == nil ? "Choose a step photo" : "Choose a different step photo"), systemImage: "photo")
            }
            .accessibilityIdentifier("cooking.stepPhoto.pick")
            .task(id: selection) {
                guard let selection else { return }
                failure = false
                do {
                    guard let item = try await selection.loadTransferable(type: SelectedPhotoTransfer.self) else {
                        throw ScanFailure.invalidImage
                    }
                    let data = try item.data
                    let thumbnail = try await Task.detached(priority: .userInitiated) {
                        try PackageRowPhoto.makeThumbnail(data, dimension: CookingStepPhoto.maximumDimension, byteLimit: CookingStepPhoto.maximumBytes)
                    }.value
                    guard !Task.isCancelled, model.permitsStepNotes else { return }
                    jpeg = thumbnail
                    loadedSelection = selection
                } catch {
                    guard !Task.isCancelled, model.permitsStepNotes else { return }
                    failure = true
                }
            }
            if failure { Text(cookCompletionText("This photo could not be opened. Choose another photo.")) }
            else if selection != loadedSelection { ProgressView(cookCompletionText("Opening photo")) }
            if let jpeg {
                cookingStepPhotoPreview(jpeg, description: "")
                TextField(cookCompletionText("Describe what to look for"), text: $cue)
                    .focused(focus).submitLabel(.done).onSubmit { focus.wrappedValue = false }
                    .accessibilityIdentifier("cooking.stepPhoto.description")
                let description = cue.trimmingCharacters(in: .whitespacesAndNewlines)
                if !description.isEmpty && !CookingStepPhoto.validDescription(description) {
                    Text(cookCompletionText("Use one line of 160 characters or fewer.")).font(.footnote)
                }
            }
            Button(cookCompletionText("Save private step photo")) {
                guard let photo, photo.valid, !failure, selection == loadedSelection else { return }
                let note = CookingStepNote(id: previous?.id ?? UUID(), revision: model.context.noteKey.revision,
                    step: index, instruction: instruction, text: previous?.text ?? "", hidden: previous?.hidden ?? false, photo: photo)
                complete(with: note)
            }
            .disabled(photo?.valid != true || failure || selection != loadedSelection)
            .accessibilityIdentifier("cooking.stepPhoto.save")
            if let previous, previous.photo != nil {
                Button(cookCompletionText("Remove step photo"), role: .destructive) {
                    let retained = previous.text.isEmpty ? nil : CookingStepNote(id: previous.id, revision: previous.revision,
                        step: previous.step, instruction: previous.instruction, text: previous.text, hidden: previous.hidden)
                    complete(with: retained)
                }
            }
            Button(recordsText("Cancel")) { focus.wrappedValue = false; finish() }
            if let message = model.message { Text(message) }
        }
    }

    private func complete(with next: CookingStepNote?) {
        if model.setStepNote(previous, with: next) {
            focus.wrappedValue = false
            finish()
        }
    }
}
