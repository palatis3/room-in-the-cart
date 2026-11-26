import CoreDomain
import LocalStore
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
                    CookingNoteEditor(model: model, previous: editor.previous, index: editor.step, instruction: editor.instruction,
                        focus: noteFocus, finish: { self.editor = nil })
                        .id(editor.id)
                } else if let instruction {
                    ForEach(attached.filter { !$0.hidden || showHidden }) { note in
                        Text(verbatim: note.text).textSelection(.enabled)
                        Button(cookCompletionText("Edit note")) { editor = .init(previous: note, step: index, instruction: instruction) }
                        Button(cookCompletionText(note.hidden ? "Show note on this step" : "Hide note on this step")) {
                            model.setStepNote(note, with: CookingStepNote(id: note.id, revision: note.revision, step: note.step,
                                instruction: note.instruction, text: note.text, hidden: !note.hidden))
                        }
                        exportButton(note)
                    }
                    if attached.contains(where: \.hidden) {
                        Toggle(cookCompletionText("View hidden notes"), isOn: $showHidden)
                    }
                    if attached.isEmpty {
                        Button(cookCompletionText("Add a private note")) { editor = .init(previous: nil, step: index, instruction: instruction) }
                            .accessibilityIdentifier("cooking.stepNote.add")
                    }
                }
                if editor == nil && !unresolved.isEmpty {
                    DisclosureGroup(cookCompletionText("Notes from earlier instructions")) {
                        ForEach(unresolved) { note in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(verbatim: note.instruction).font(.caption)
                                Text(verbatim: note.text)
                                exportButton(note)
                                if let instruction, attached.isEmpty {
                                    Button(cookCompletionText("Review moving to this step")) {
                                        editor = .init(previous: note, step: index, instruction: instruction)
                                    }
                                }
                                Button(cookCompletionText("Delete note"), role: .destructive) {
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
            document = RecordsFileDocument(data: Data(current.text.utf8), kind: .text)
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
                    instruction: instruction, text: text, hidden: false)
                if model.setStepNote(previous, with: next) { focus.wrappedValue = false; finish() }
            }.disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || text.utf8.count > 2048)
            .accessibilityIdentifier("cooking.stepNote.save")
            Button(recordsText("Cancel")) { focus.wrappedValue = false; finish() }
            if let previous {
                Button(cookCompletionText("Delete note"), role: .destructive) {
                    if model.setStepNote(previous, with: nil) { focus.wrappedValue = false; finish() }
                }
            }
            if let message = model.message { Text(message) }
        }
    }
}
