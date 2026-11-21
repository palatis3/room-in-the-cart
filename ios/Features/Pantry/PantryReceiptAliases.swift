import CoreDomain
import LocalStore
import SwiftUI

struct ReceiptLanguagePicker: View {
    @Binding var language: String
    var body: some View {
        Picker(pantryText("Printed receipt language"), selection: $language) {
            Text(pantryText("English")).tag("en")
            Text(pantryText("Spanish")).tag("es")
        }
    }
}

struct PantryReceiptAliasEntry: View {
    @ObservedObject var model: PantryModel
    let source: ReceiptAcquisition
    @FocusState private var editingWording: Bool
    @State private var wording = ""
    @State private var language = Bundle.main.preferredLocalizations.first?.hasPrefix("es") == true ? "es" : "en"
    @State private var basis: InventoryState?
    @State private var message: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WorkingForm {
            if let message { Text(message) }
            Section(pantryText("Confirmed receipt line")) {
                ReceiptPaperLine(wording: source.originalLine, provenance: source.documentLine.map(receiptProvenance))
                LabeledContent(pantryText("Store or branch"), value: source.merchant)
                LabeledContent(pantryText("Food name"), value: source.name)
            }
            Section {
                ReceiptLanguagePicker(language: $language)
                let title = pantryText("Product wording from the printed line")
                WorkingField(title) {
                    TextField(title, text: $wording, prompt: Text(""))
                        .receiptInputChrome()
                        .autocorrectionDisabled().textInputAutocapitalization(.never).focused($editingWording)
                }
                Text(pantryText("Future receipts can suggest this food for the same store and language. You choose whether to use it each time."))
                Text(pantryText("Saved spellings are private to your profile on this device and are excluded from pantry recovery copies."))
                Button(pantryText("Save receipt spelling")) {
                    guard let basis else { return }
                    saving = true
                    Task {
                        defer { saving = false }
                        do {
                            try await model.rememberReceiptAlias(source, wording: wording, language: language, state: basis)
                            dismiss()
                        } catch {
                            await model.load()
                            self.basis = model.snapshot?.state
                            message = pantryText("Check the printed wording and your saved spellings before trying again.")
                        }
                    }
                }.disabled(saving || !model.canEdit || basis == nil ||
                    !wording.unicodeScalars.contains(where: CharacterSet.letters.contains) ||
                    !ReceiptImportDraft.containsWording(wording, in: source.originalLine))
            }
        }
        .navigationTitle(pantryText("Remember this product spelling"))
        .privacySensitive()
        .keyboardDoneAction(visible: editingWording, title: pantryText("Done"), identifier: "receipt.alias.keyboardDone") { editingWording = false }
        .onAppear { basis = model.snapshot?.state }
        .onChange(of: model.snapshot?.state.workspaceID) { _, origin in if origin == nil { dismiss() } }
        .interactiveDismissDisabled(saving)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Close")) { dismiss() }.disabled(saving) } }
    }
}

struct PantryReceiptAliasList: View {
    @ObservedObject var model: PantryModel
    private struct Removal: Identifiable {
        let id = UUID()
        let aliases: [InventoryReceiptAlias]
        let basis: InventoryState
    }
    @State private var aliases: [InventoryReceiptAlias] = []
    @State private var basis: InventoryState?
    @State private var proposed: Removal?
    @State private var message: String?
    @State private var saving = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        List {
            Section {
                Text(pantryText("Saved spellings are private to your profile on this device and are excluded from pantry recovery copies."))
                    .font(.subheadline).foregroundStyle(Theme.secondary)
                if let message { Text(message) }
                if basis != nil && aliases.isEmpty { Text(pantryText("No saved receipt spellings.")) }
            }.listRowBackground(Theme.surface)
            ForEach(aliases) { alias in
                Section {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(verbatim: alias.product).font(.headline)
                        Text(alias.merchant + " · " + pantryText(alias.language == "es" ? "Spanish" : "English"))
                            .font(.subheadline).foregroundStyle(Theme.secondary)
                        ReceiptPaperLine(wording: alias.wording, title: pantryText("Product wording from the printed line"))
                    }
                    Button(pantryText("Forget this spelling"), role: .destructive) {
                        if let basis { proposed = Removal(aliases: [alias], basis: basis) }
                    }.disabled(saving || !model.canEdit)
                }.listRowBackground(Theme.surface)
            }
            if !aliases.isEmpty {
                Section {
                    Button(pantryText("Reset all my receipt spellings"), role: .destructive) {
                        if let basis { proposed = Removal(aliases: aliases, basis: basis) }
                    }.disabled(saving || !model.canEdit)
                }.listRowBackground(Theme.surface)
            }
        }
        .workingSurface()
        .privacySensitive()
        .navigationTitle(pantryText("Saved receipt spellings"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Done")) { dismiss() }.disabled(saving) } }
        .task { await reload() }
        .onChange(of: model.snapshot?.state.workspaceID) { _, origin in
            if origin == nil { proposed = nil; aliases = []; basis = nil; dismiss() }
        }
        .alert(item: $proposed) { change in
            Alert(title: Text(pantryFormat("Forget %@ saved receipt spellings?", change.aliases.count.formatted())),
                  message: Text(pantryText("Previous receipts and pantry food keep their confirmed details.")),
                  primaryButton: .destructive(Text(pantryText("Forget"))) {
                    saving = true
                    Task {
                        defer { saving = false }
                        do { try await model.forgetReceiptAliases(change.aliases, state: change.basis) }
                        catch { await model.load(); message = pantryText("The pantry changed. Check the current spellings and confirm again.") }
                        await reload()
                    }
                  }, secondaryButton: .cancel(Text(pantryText("Cancel"))))
        }
    }

    private func reload() async {
        let current = model.snapshot?.state
        do {
            let rows = try await model.receiptAliases()
            guard current == model.snapshot?.state else { throw PantryReceiptError.stale }
            aliases = rows
            basis = current
        } catch {
            aliases = []; basis = nil
            message = pantryText("Reopen the private pantry to review saved receipt spellings.")
        }
    }
}
