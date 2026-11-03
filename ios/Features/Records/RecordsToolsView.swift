import SwiftUI
import UniformTypeIdentifiers
import RecordArchive

struct RecordsToolsView: View {
    @ObservedObject var model: RecordsToolsModel
    @State private var importing = false
    @State private var importingRecipes = false
    @State private var exporting = false
    @State private var showManualRecipe = false
    @State private var acknowledgedPrivate = false
    @State private var savedKey = false
    @State private var acknowledgedMedia = false
    @State private var deletion: Deletion?
    private struct Deletion: Identifiable {
        let id = UUID()
        let title: String
        let source: ArchiveRecord?
        let recovered: RecoveryDeleteScope?
    }
    var body: some View {
        Form {
            Section {
                Text(recordsText("Keep your records"))
                    .font(.title2.bold())
                Text(recordsText("Export, recover and delete your own data. These tools stay free, including after membership ends."))
                Text(recordsText("Recovery saves a separate copy. A file never restores membership, consent, permissions or a retailer order."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if model.busy { ProgressView(recordsText("Working on this iPhone…")) }
            if !model.unavailableRecords.isEmpty {
                Section(recordsText("Unavailable records · excluded from export")) {
                    Text(recordsText("These records remain saved on this iPhone, but this app could not read them. Only readable selected records are included in an export."))
                    ForEach(model.unavailableRecords) { record in
                        VStack(alignment: .leading, spacing: 4) {
                            Text(record.title?.isEmpty == false ? record.title! : recordsText("Untitled record"))
                            if record.localCopyID != nil { Text(recordsText("Recovered copy")).font(.caption) }
                            Text(unavailableMessage(record.reason)).font(.caption)
                        }
                    }
                }
            }
            if let error = model.error { Section { Label(errorMessage(error), systemImage: "exclamationmark.triangle").foregroundStyle(.red) } }
            if let status = model.status { Section { Text(status).accessibilityAddTraits(.updatesFrequently) } }
            currentSources
            exportSection
            importSection
            if let review = model.review { reviewSection(review) }
            if !model.lastImportIDs.isEmpty {
                Section { Button(recordsText("Undo imported batch")) { Task { await model.undoImport() } } }
            }
            recoveredSection
            Section(recordsText("Privacy and support")) {
                if model.canReviewWholeLedgerDeletion {
                    Button(recordsText("Delete all shopping lists and saved dinners…"), role: .destructive) {
                        Task { await model.reviewWholeLedgerDeletion() }
                    }
                    Text(recordsText("This separate action reviews the entire local ledger and its history before deletion.")).font(.footnote)
                }
                Text(recordsText("Only explicitly selected source references are included in encrypted recovery. Readable and helper copies contain no attachment bytes. No file is uploaded automatically. Shared copies cannot be recalled."))
                    .font(.footnote)
                ShareLink(item: model.supportText) { Label(recordsText("Share redacted support details"), systemImage: "lifepreserver") }
                Text(recordsText("Support details include only format, record count and an error code. They omit food names, receipts, account details and file paths."))
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .navigationTitle(recordsText("Data and recovery"))
        .task { await model.refresh() }
        .disabled(model.busy)
        .onChange(of: model.selectedIDs) { _, _ in acknowledgedPrivate = false; acknowledgedMedia = false; savedKey = false; model.dismissPreparedFile() }
        .onChange(of: model.selectedMediaIDs) { _, _ in acknowledgedMedia = false; model.dismissPreparedFile() }
        .onChange(of: model.recoveryKey) { _, _ in savedKey = false }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.json, .roomRecovery, .roomHelper, .data], allowsMultipleSelection: false) { result in
            switch result {
            case let .success(urls): if let url = urls.first { Task { await model.importFile(url, recipes: importingRecipes) } }
            case let .failure(error): model.reportFileError(error)
            }
        }
        .fileExporter(isPresented: $exporting, document: model.preparedDocument, contentType: model.preparedDocument?.contentType ?? .json, defaultFilename: model.preparedName) { result in
            if case let .failure(error) = result { model.reportFileError(error) }
        }
        .sheet(isPresented: $showManualRecipe) { ManualRecipeEntryView { recipe in
            showManualRecipe = false
            Task { await model.stageManualRecipe(recipe) }
        } }
        .confirmationDialog(deletion?.title ?? "", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), titleVisibility: .visible) {
            if let deletion {
                Button(recordsText("Delete from this iPhone"), role: .destructive) {
                    Task {
                        if let record = deletion.source { await model.deleteCurrentRecord(record) }
                        if let scope = deletion.recovered { await model.deleteRecovered(scope) }
                    }
                    self.deletion = nil
                }
            }
            Button(recordsText("Cancel"), role: .cancel) { deletion = nil }
        } message: {
            Text(recordsText(model.recoveredDeletionAllowsUndo ? "Only the named local source or recovered copies are removed. Other records and copies already shared remain. Recovered-copy deletion can be undone during this app session." : "The named local source or recovered copies and their separate workspaces will be permanently deleted. This cannot be undone. Other records and files already shared remain."))
        }
    }
    private var currentSources: some View {
        Section(recordsText("Choose records to export")) {
            if model.currentRecords.isEmpty { Text(recordsText(model.unavailableRecords.isEmpty ? "No saved source records yet." : "No readable source records are available for export.")) }
            else {
                Button(recordsText("Select all readable records")) { model.selectAll() }
                ForEach(model.currentRecords, id: \.selfSelectionID) { record in
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle(isOn: Binding(get: { model.selectedIDs.contains(RecordsToolsModel.selectionID(record)) }, set: { selected in
                            let key = RecordsToolsModel.selectionID(record)
                            if selected { model.selectedIDs.insert(key) } else { model.selectedIDs.remove(key) }
                        })) { Text(record.title.isEmpty ? recordsText("Untitled record") : record.title) }
                        Text(recordKindLabel(record.kind)).font(.caption).foregroundStyle(.secondary)
                        if model.canDeleteSource(record) {
                            Button(recordsText("Delete this source"), role: .destructive) {
                                deletion = Deletion(title: record.title, source: record, recovered: nil)
                            }.font(.footnote)
                        }
                    }
                }
            }
            if model.canUndoSourceDeletion { Button(recordsText("Undo source deletion")) { Task { await model.undoCurrentDeletion() } } }
        }
    }
    private var exportSection: some View {
        Section(recordsText("Export selected records")) {
            Text(recordsText("Cook and helper copies include selected food labels, amounts, purposes and actions. They leave out native financial and private record data."))
                .font(.footnote)
            Button(recordsText("Prepare readable cook copy")) { Task { await model.prepareExport(.helperText) } }.disabled(model.selectedCount != 1)
            Button(recordsText("Prepare structured helper copy")) { Task { await model.prepareExport(.helperJSON) } }.disabled(model.selectedCount != 1)
            Text(recordsText("Choose one source for each cook or helper copy.")).font(.footnote)
            Text(recordsText("A shop backup includes its linked dinner evidence and quote history. Reusable dinners, rotations and saved ideas are a separate library selection. Imported planning never restores paid access or permissions.")).font(.footnote)
            Toggle(recordsText("I understand a readable owner export includes private record data."), isOn: $acknowledgedPrivate)
            Button(recordsText("Prepare readable owner export")) { Task { await model.prepareExport(.ownerText) } }.disabled(model.selectedCount == 0 || !acknowledgedPrivate)
            DisclosureGroup(recordsText("Encrypted personal recovery")) {
                Text(recordsText("A recovery file restores selected private records, saved history and the source references you choose below as separate copies. It excludes raw voice, credentials, membership, consent and live permissions."))
                selectedMedia
                Button(recordsText("Generate recovery key")) { model.generateRecoveryKey(); savedKey = false }
                TextField(recordsText("Recovery key"), text: $model.recoveryKey, axis: .vertical)
                    .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                Text(recordsText("Save this key somewhere safe, separately from the file. If the key is lost, this app cannot recover the encrypted file."))
                    .font(.footnote)
                Toggle(recordsText("I have saved my recovery key separately."), isOn: $savedKey)
                Button(recordsText("Prepare encrypted recovery file")) { Task { await model.prepareExport(.encryptedRecovery) } }
                    .disabled(!savedKey || model.recoveryKey.isEmpty || model.selectedCount == 0 || (model.selectedMediaCount > 0 && !acknowledgedMedia))
            }
            if let document = model.preparedDocument {
                Label(model.preparedIsPrivate ? recordsText("Private owner file ready") : recordsText("Redacted copy ready"), systemImage: model.preparedIsPrivate ? "lock.doc" : "doc.text")
                Text(ByteCountFormatter.string(fromByteCount: Int64(document.data.count), countStyle: .file)).font(.caption)
                Button(recordsText("Save file…")) { exporting = true }
                if document.kind != .text {
                    ShareLink(item: RecordsShareFile(data: document.data, kind: document.kind), preview: SharePreview(model.preparedName)) { Label(recordsText("Share prepared file…"), systemImage: "square.and.arrow.up") }
                } else if let text = String(data: document.data, encoding: .utf8) {
                    ShareLink(item: text) { Label(recordsText("Share prepared text…"), systemImage: "square.and.arrow.up") }
                    DisclosureGroup(recordsText("Preview readable copy")) { Text(text).textSelection(.enabled) }
                }
                Button(recordsText("Discard prepared file")) { model.dismissPreparedFile() }
            }
        }
    }
    private var selectedMedia: some View {
        Group {
            Text(recordsText("Choose source references · optional")).font(.headline)
            Text(recordsText("References are off by default. Selected reduced photos, original wording, manually matched codes and receipt notes may contain private details. They remain evidence and do not change payments, food received or meal decisions.")).font(.footnote)
            Text(recordsText("Only saved reduced references are available. Full-size originals and missing photos cannot be recovered.")).font(.footnote)
            ForEach(model.currentRecords.filter { model.selectedIDs.contains(RecordsToolsModel.selectionID($0)) }, id: \.selfSelectionID) { record in
                if let media = record.media, !media.isEmpty {
                    Text(record.title).font(.subheadline.bold())
                    ForEach(media) { attachment in
                        VStack(alignment: .leading, spacing: 6) {
                            Toggle(isOn: Binding(get: { model.selectedMediaIDs.contains(RecordsToolsModel.mediaSelectionID(attachment, record: record)) }, set: { selected in
                                let key = RecordsToolsModel.mediaSelectionID(attachment, record: record)
                                if selected { model.selectedMediaIDs.insert(key) } else { model.selectedMediaIDs.remove(key) }
                            })) { Text((try? RecordsMediaCodec.decode(attachment).reviewedLabel) ?? recordsText("Source reference")) }
                            RecordsMediaPreview(attachment: attachment)
                        }
                    }
                }
            }
            Text(String(format: recordsText("%lld selected references · %@"), Int64(model.selectedMediaCount), ByteCountFormatter.string(fromByteCount: Int64(model.selectedMediaBytes), countStyle: .file)))
                .font(.footnote)
            Text(recordsText("Up to twelve references and 4.2 MB of source evidence per recovery file; the encrypted file must be under 8 MB. Choose fewer references if the file is too large.")).font(.footnote)
            if model.selectedMediaCount > 0 {
                Toggle(recordsText("I reviewed the selected references and understand they include private source details."), isOn: $acknowledgedMedia)
            }
        }
    }
    private var importSection: some View {
        Section(recordsText("Bring records or recipes")) {
            TextField(recordsText("Key for an encrypted recovery file"), text: $model.recoveryKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(recordsText("Choose recovery or helper file…")) { importingRecipes = false; importing = true }
            Button(recordsText("Choose Recipe JSON-LD file…")) { importingRecipes = true; importing = true }
            Button(recordsText("Add recipe and source manually")) { showManualRecipe = true }
            Text(recordsText("Recipe files may contain a Recipe, an array, or a graph. Original ingredient and yield text are preserved. Source links are attribution only; this app does not fetch the website."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func reviewSection(_ review: RecoveryReview) -> some View {
        Section(recordsText("Review before importing")) {
            Text(review.envelope.originNamespace).font(.caption).textSelection(.enabled)
            if review.envelope.lastSavedAtMilliseconds == 0 {
                Text(recordsText("The recipe file does not supply a saved date."))
            } else {
                Text(recordsText("Saved at") + " " + Date(timeIntervalSince1970: Double(review.envelope.lastSavedAtMilliseconds) / 1000).formatted(date: .abbreviated, time: .shortened))
            }
            if let report = model.recipeReport {
                Text("\(report.recipes.count) " + recordsText("recipes ready") + " · \(report.duplicateCount) " + recordsText("duplicates") + " · \(report.skippedRows) " + recordsText("rows skipped"))
                if !report.unsupportedFields.isEmpty { Text(recordsText("Unsupported fields: ") + report.unsupportedFields.joined(separator: ", ")).font(.caption) }
            }
            ForEach(review.rows) { row in
                VStack(alignment: .leading, spacing: 6) {
                    Text(row.record.title).font(.headline)
                    Text(dispositionLabel(row.disposition))
                    Text(recordsText("Revision: ") + row.record.revision).font(.caption).textSelection(.enabled)
                    if let parent = row.record.parentRevision { Text(recordsText("Parent: ") + parent).font(.caption).textSelection(.enabled) }
                    ForEach(row.record.media ?? []) { RecordsMediaPreview(attachment: $0) }
                }
            }
            if let media = review.envelope.mediaManifest {
                Text(String(format: recordsText("%lld selected references · %@"), Int64(media.entries.count), ByteCountFormatter.string(fromByteCount: Int64(media.totalBytes), countStyle: .file)))
                Text(recordsText("Selected references recover with these separate copies. They do not reopen the original photo store or restore access to another workspace.")).font(.footnote)
            }
            Text(recordsText("Current and newer work stays in place. Different revisions become separate copies; identical imports reopen the saved copy. A conflicting digest or erased identity blocks this batch."))
                .font(.footnote)
            Button(recordsText("Import reviewed copies")) { Task { await model.applyReviewedImport() } }.disabled(!review.canApply)
            Button(recordsText("Cancel import"), role: .cancel) { model.cancelReview() }
        }
    }
    private var recoveredSection: some View {
        Section(recordsText("Recovered copies and saved recipes")) {
            if model.recoveredRecords.isEmpty { Text(recordsText("No recovered copies yet.")) }
            ForEach(model.recoveredRecords) { saved in
                DisclosureGroup(saved.record.title.isEmpty ? recordsText("Untitled record") : saved.record.title) {
                    Text(saved.record.origin).font(.caption).textSelection(.enabled)
                    Text(recordsText("Revision: ") + saved.record.revision).font(.caption).textSelection(.enabled)
                    if let recipe = recipe(saved.record) {
                        Text(recipe.yieldText)
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, text in Text(text) }
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { _, text in Text(text) }
                        if !recipe.notes.isEmpty { Text(recipe.notes) }
                        if let source = recipe.sourceURL { Text(source).textSelection(.enabled).font(.caption) }
                        Button(recordsText("Open saved recipe")) { Task { await model.openRecovered(saved) } }
                    } else if saved.record.nativePayload != nil {
                        Button(recordsText("Open separate recovered copy")) { Task { await model.openRecovered(saved) } }
                    } else {
                        Text(ReadableArchive.text([saved.record], owner: false)).textSelection(.enabled)
                        Text(recordsText("This helper projection has no private payload and cannot replace an owner record.")).font(.footnote)
                    }
                    ForEach(saved.record.media ?? []) { RecordsMediaPreview(attachment: $0) }
                    Button(recordsText("Delete this recovered copy"), role: .destructive) { deletion = Deletion(title: saved.record.title, source: nil, recovered: .copy(saved.id)) }
                    Button(recordsText("Delete recovered copies from this source"), role: .destructive) { deletion = Deletion(title: saved.record.origin, source: nil, recovered: .origin(saved.record.origin)) }
                }
            }
            if model.deleteUndo != nil { Button(recordsText("Undo recovered-copy deletion")) { Task { await model.undoRecoveredDeletion() } } }
        }
    }
    private func recordKindLabel(_ kind: ArchiveRecordKind) -> String {
        switch kind {
        case .comparison: return recordsText("Pack comparison")
        case .ledger: return recordsText("Shopping list and dinners")
        case .pickup: return recordsText("Pickup history")
        case .recipe: return recordsText("Recipe")
        }
    }
    private func recipe(_ record: ArchiveRecord) -> ImportedRecipe? {
        guard record.kind == .recipe, let data = record.nativePayload else { return nil }
        return try? JSONDecoder().decode(ImportedRecipe.self, from: data)
    }
    private func dispositionLabel(_ value: RecoveryDisposition) -> String {
        switch value {
        case .absent: return recordsText("Absent here — recover separately")
        case .identical: return recordsText("Identical — reopen existing copy")
        case .sibling: return recordsText("Related revision — keep both copies")
        case .quarantined: return recordsText("Same identity, different content — blocked")
        case .erased: return recordsText("Previously deleted here — blocked")
        }
    }
    private func unavailableMessage(_ reason: RecordsUnavailableRecord.Reason) -> String {
        switch reason {
        case .unreadableStorage: return recordsText("Saved record could not be read. Its bytes were not replaced.")
        case .unsupportedStorage: return recordsText("This saved format needs a compatible app version.")
        case .invalidNative: return recordsText("This record's content could not be validated. Other readable records are still available.")
        }
    }
    private func errorMessage(_ error: ArchiveError) -> String {
        switch error {
        case .tooLarge: return recordsText("This file exceeds the supported size or complexity. Your records are unchanged.")
        case .unsupportedVersion, .unsupportedProjection, .unsupportedRecord: return recordsText("This file uses an unsupported format or record type. Your records are unchanged.")
        case .integrity, .malformed, .invalidIdentity: return recordsText("This file is incomplete or damaged. Your records are unchanged.")
        case .locked, .invalidKey: return recordsText("The recovery key could not unlock this file. Check the key and try again.")
        case .conflict: return recordsText("This batch conflicts with an existing or deleted copy. Nothing was imported.")
        case .staleReview: return recordsText("Your local copies changed during review. Select the file again before importing.")
        case .invalidRecipe: return recordsText("Check the recipe title, source URL and text. Use a supported Recipe JSON-LD file or enter it manually.")
        case .unavailable: return recordsText("The local operation could not finish. Your current records are still available. Try again.")
        }
    }
}

/// The preview opens only bytes already validated and committed with this copy.
/// It never follows recovered namespace references into a live media store.
@MainActor private struct RecordsMediaPreview: View {
    let attachment: ArchiveMediaAttachment
    var body: some View {
        if let source = try? RecordsMediaCodec.decode(attachment) {
            DisclosureGroup(recordsText("Preview source reference")) {
                Text(source.reviewedLabel).font(.headline)
                Text(kindLabel).font(.caption)
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.caption)
                Text(source.capturedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption)
                if let data = source.imageJPEG, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                        .accessibilityLabel(recordsText("Selected reduced source photo"))
                }
                Text(source.originalText).textSelection(.enabled)
                if let barcode = source.barcode { Text(barcode.value).textSelection(.enabled) }
                ForEach(source.receiptLines) { row in
                    VStack(alignment: .leading) {
                        Text(row.originalText).font(.footnote)
                        Text(row.reviewedText)
                        if !row.quantityNote.isEmpty { Text(row.quantityNote) }
                        if !row.priceNote.isEmpty { Text(row.priceNote) }
                    }
                }
            }
        }
    }
    private var kindLabel: String {
        switch attachment.kind {
        case .packageReference: return recordsText("Package reference")
        case .recipeSource: return recordsText("Recipe source")
        case .receiptEvidence: return recordsText("Receipt evidence")
        }
    }
}

private extension ArchiveRecord {
    var selfSelectionID: String { origin + "/" + id + "/" + revision }
}

private struct ManualRecipeEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let submit: (ImportedRecipe) -> Void
    @State private var title = ""
    @State private var servings = ""
    @State private var ingredients = ""
    @State private var steps = ""
    @State private var source = ""
    @State private var notes = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField(recordsText("Meal title"), text: $title)
                TextField(recordsText("Servings or yield, in your words"), text: $servings)
                TextField(recordsText("Ingredients, one per line"), text: $ingredients, axis: .vertical).lineLimit(3...12)
                TextField(recordsText("Steps, one per line"), text: $steps, axis: .vertical).lineLimit(3...12)
                TextField(recordsText("Source URL (optional)"), text: $source).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField(recordsText("Your notes"), text: $notes, axis: .vertical).lineLimit(3...12)
                Text(recordsText("Your meal remains editable even if its source website disappears. The URL does not fetch or import a web page."))
                    .font(.footnote)
                Button(recordsText("Review recipe")) {
                    submit(ImportedRecipe(title: title, yieldText: servings, ingredients: ingredients.components(separatedBy: .newlines).filter { !$0.isEmpty }, steps: steps.components(separatedBy: .newlines).filter { !$0.isEmpty }, sourceURL: source.isEmpty ? nil : source, notes: notes))
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle(recordsText("Save a recipe"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(recordsText("Cancel")) { dismiss() } } }
        }
    }
}
