import SwiftUI
import UniformTypeIdentifiers
import RecordArchive

struct RecordsToolsView: View {
    @ObservedObject var model: RecordsToolsModel
    var recipeLibraryOnly = false
    @State private var exporting = false
    @State private var presentedSaveID: UUID?
    @State private var acknowledgedPrivate = false
    @State private var savedKey = false
    @State private var acknowledgedMedia = false
    @State private var deletion: Deletion?
    @AccessibilityFocusState private var actionResultFocused: Bool
    @AccessibilityFocusState private var importReviewFocused: Bool
    @State private var recoveryExpanded = false
    @State private var recoveredExpandedIDs: Set<String> = []
    #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
    @Environment(\.recordsMediaUITestFiles) private var uiTestFiles
    #endif
    private struct Deletion: Identifiable {
        let id = UUID()
        let title: String
        let source: ArchiveRecord?
        let recovered: RecoveryDeleteScope?
    }
    var body: some View {
        ScrollViewReader { proxy in
        Form {
            if !recipeLibraryOnly {
                Section {
                    Text(recordsText("Keep your records"))
                        .font(.title2.bold())
                    Text(recordsText("Export, recover and delete your own data. These tools stay free, including after membership ends."))
                    Text(recordsText("Recovery saves a separate copy. A file never restores membership, consent, permissions or a retailer order."))
                        .font(.footnote).foregroundStyle(.secondary)
                }
            }
            if model.busy { ProgressView(recordsText("Working on this iPhone…")) }
            if !recipeLibraryOnly && !model.unavailableRecords.isEmpty {
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
            if model.error != nil || model.status != nil {
                Section {
                    Group {
                        if let error = model.error {
                            let message = errorMessage(error)
                            Label(message, systemImage: "exclamationmark.triangle")
                                .foregroundStyle(.red)
                                .accessibilityElement(children: .ignore)
                                .accessibilityLabel(Text(verbatim: message))
                                .accessibilityIdentifier("records.error")
                        } else if let status = model.status {
                            Text(status).accessibilityIdentifier("records.status")
                        }
                    }
                    .accessibilityAddTraits(.updatesFrequently)
                    .accessibilityFocused($actionResultFocused)
                    .id("records.actionResult")
                    ForEach(model.recoveredRecords.filter { !recipeLibraryOnly && model.reopenedCopyIDs.contains($0.id) }) { saved in
                        recoveredCopy(saved)
                    }
                }
            }
            if recipeLibraryOnly {
                Section {
                    manualRecipeButton
                    recipeFileButton
                }
            } else {
                currentSources
                exportSection
                importSection
            }
            if let review = model.review { reviewSection(review) }
            if !model.lastImportIDs.isEmpty {
                Section { Button(recordsText("Undo imported batch")) { Task { await model.undoImport() } } }
            }
            if recipeLibraryOnly {
                Section(recordsText("Saved recipes")) {
                    let recipes = model.recoveredRecords.filter { $0.record.kind == .recipe && $0.record.nativePayload != nil }
                    if recipes.isEmpty { Text(recordsText("No saved recipes yet.")) }
                    ForEach(recipes) { saved in
                        Button(recordsTitle(saved.record)) { Task { await model.openRecovered(saved) } }
                            .accessibilityIdentifier("dinner.savedRecipe." + saved.id)
                    }
                }
            } else {
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
        }
        // Reopening moves the saved rows from the bottom of the form to the result.
        // A fresh list prevents iOS 17 from restoring the old offset after that move.
        .id(model.reopenedCopyIDs)
        .task(id: model.review != nil) {
            guard model.review != nil else { return }
            importReviewFocused = false
            await Task.yield()
            guard !Task.isCancelled, model.review != nil else { return }
            proxy.scrollTo("records.importReview", anchor: .top)
            await Task.yield()
            guard !Task.isCancelled, model.review != nil else { return }
            importReviewFocused = true
        }
        .task(id: model.actionOutcomeID) {
            guard let outcomeID = model.actionOutcomeID else { return }
            recoveredExpandedIDs.formUnion(model.reopenedCopyIDs)
            actionResultFocused = false
            await Task.yield()
            guard !Task.isCancelled, model.actionOutcomeID == outcomeID else { return }
            proxy.scrollTo("records.actionResult", anchor: .top)
            await Task.yield()
            guard !Task.isCancelled, model.actionOutcomeID == outcomeID else { return }
            actionResultFocused = true
        }
        }
        .navigationTitle(recordsText(recipeLibraryOnly ? "Import and use recipes" : "Data and recovery"))
        .accessibilityIdentifier("records.tools")
        .task { await model.refresh() }
        .disabled(model.busy)
        .onChange(of: model.selectedIDs) { _, _ in acknowledgedPrivate = false; acknowledgedMedia = false; savedKey = false; model.dismissPreparedFile() }
        .onChange(of: model.selectedMediaIDs) { _, _ in acknowledgedMedia = false; model.dismissPreparedFile() }
        .onChange(of: model.recoveryKey) { _, _ in savedKey = false }
        .background {
            if let presentation = model.importPresentation, presentation.entry != .manualRecipe {
                RecordsImportFilePicker(presentation: presentation) { result in
                    Task { await model.finishFileImport(result, from: presentation) }
                }
                .id(presentation.id)
            }
        }
        .fileExporter(isPresented: $exporting, document: model.preparedDocument,
                      contentTypes: [model.preparedDocument?.contentType ?? .json], defaultFilename: model.preparedName,
                      onCompletion: { [presentedSaveID] result in
                          finishFileSave(presentedSaveID, result.map { _ in () })
                      }, onCancellation: { [presentedSaveID] in
                          finishFileSave(presentedSaveID, .failure(CancellationError()))
                      })
        .sheet(item: manualRecipePresentation) { presentation in
            ManualRecipeEntryView { recipe in
                let staged = await model.stageManualRecipe(recipe, from: presentation)
                if staged { return nil }
                if model.error == .invalidRecipe {
                    return recordsText("Check the recipe text. The optional source must be an http or https web address without a username or password.")
                }
                return errorMessage(model.error ?? .unavailable)
            }
        }
        .alert(deletion?.title ?? "", isPresented: Binding(get: { deletion != nil }, set: { if !$0 { deletion = nil } }), presenting: deletion) { deletion in
            Button(recordsText("Cancel"), role: .cancel) { self.deletion = nil }
            Button(recordsText("Delete from this iPhone"), role: .destructive) {
                Task {
                    if let record = deletion.source { await model.deleteCurrentRecord(record) }
                    if let scope = deletion.recovered { await model.deleteRecovered(scope) }
                }
                self.deletion = nil
            }
        } message: { _ in
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
                        })) { Text(recordsTitle(record)) }
                            .accessibilityIdentifier("records.source." + record.id)
                        Text(recordKindLabel(record.kind)).font(.caption).foregroundStyle(.secondary)
                        if record.kind == .sharedHistory {
                            ForEach(SharedHistoryArchiveAdapter.coverageKeys(record), id: \.self) { key in
                                Text(recordsText(key)).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                        recordDates(record)
                        if model.canDeleteSource(record) {
                            Button(recordsText("Delete this source"), role: .destructive) {
                                deletion = Deletion(title: recordsTitle(record), source: record, recovered: nil)
                            }.font(.footnote)
                        }
                    }
                }
            }
            if model.canUndoSourceDeletion { Button(recordsText("Undo source deletion")) { Task { await model.undoCurrentDeletion() } } }
        }
    }
    @ViewBuilder private func recordDates(_ record: ArchiveRecord) -> some View {
        let id = RecordsToolsModel.selectionID(record)
        let hasSourceDate = record.kind == .sharedShop || record.kind == .sharedHistory || record.nativePayload == nil
            || model.sourceListing.recoveredCopyIDsByRecord[id] != nil
        Text(hasSourceDate
             ? RecordsDatePresentation.sourceSavedAt(record.savedAtMilliseconds, locale: recordsInterfaceLocale)
             : RecordsDatePresentation.localSavedAt(record.savedAtMilliseconds))
            .font(.caption).accessibilityIdentifier("records.sourceDate." + record.id)
        if let fetched = model.sourceListing.householdFetchedAtMilliseconds[id] {
            Text(RecordsDatePresentation.householdFetchedAt(fetched))
                .font(.caption).accessibilityIdentifier("records.householdFetchDate." + record.id)
        }
        if let backup = model.backupDateText(for: record) {
            Text(backup).font(.caption).accessibilityIdentifier("records.backupDate." + record.id)
        }
    }

    private var exportSection: some View {
        Section(recordsText("Export selected records")) {
            Text(recordsText("Cook and helper copies include selected food labels, amounts, purposes and actions. They leave out native financial and private record data."))
                .font(.footnote)
            Button(recordsText("Prepare readable cook copy")) { Task { await model.prepareExport(.helperText) } }.disabled(model.selectedCount != 1).accessibilityIdentifier("records.prepareHelperText")
            Button(recordsText("Prepare structured helper copy")) { Task { await model.prepareExport(.helperJSON) } }.disabled(model.selectedCount != 1).accessibilityIdentifier("records.prepareHelperJSON")
            Text(recordsText("Choose one source for each cook or helper copy.")).font(.footnote)
            Text(recordsText("A shop backup includes its linked dinner evidence and quote history. Reusable dinners, rotations and saved ideas are a separate library selection. Imported planning never restores paid access or permissions.")).font(.footnote)
            Toggle(recordsText("I understand a readable owner export includes private record data."), isOn: $acknowledgedPrivate).accessibilityIdentifier("records.ownerDisclosure")
            Button(recordsText("Prepare readable owner export")) { Task { await model.prepareExport(.ownerText) } }.disabled(model.selectedCount == 0 || !acknowledgedPrivate).accessibilityIdentifier("records.prepareOwnerText")
            DisclosureGroup(recordsText("Encrypted personal recovery"), isExpanded: $recoveryExpanded) {
                Text(recordsText("A recovery file restores selected private records, saved history and the source references you choose below as separate copies. It excludes raw voice, credentials, membership, consent and live permissions."))
                selectedMedia
                Button(recordsText("Generate recovery key")) { model.generateRecoveryKey(); savedKey = false }.accessibilityIdentifier("records.generateKey")
                TextField(recordsText("Recovery key"), text: $model.recoveryKey, axis: .vertical)
                    .font(.caption.monospaced()).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .accessibilityIdentifier("records.recoveryKey")
                Text(recordsText("Save this key somewhere safe, separately from the file. If the key is lost, this app cannot recover the encrypted file."))
                    .font(.footnote)
                Toggle(recordsText("I have saved my recovery key separately."), isOn: $savedKey).accessibilityIdentifier("records.savedKey")
                Button(recordsText("Prepare encrypted recovery file")) { Task { await model.prepareExport(.encryptedRecovery) } }
                    .disabled(!savedKey || model.recoveryKey.isEmpty || model.selectedCount == 0 || (model.selectedMediaCount > 0 && !acknowledgedMedia))
                    .accessibilityIdentifier("records.prepareRecovery")
            }
            .disclosureGroupStyle(LabeledFormDisclosureStyle(label: recordsText("Encrypted personal recovery"), identifier: "records.encryptedRecovery"))
            if let document = model.preparedDocument {
                Label(model.preparedIsPrivate ? recordsText("Private owner file ready") : recordsText("Redacted copy ready"), systemImage: model.preparedIsPrivate ? "lock.doc" : "doc.text")
                Text(ByteCountFormatter.string(fromByteCount: Int64(document.data.count), countStyle: .file)).font(.caption)
                Button(recordsText("Save file…")) { savePreparedFile() }.accessibilityIdentifier("records.saveFile")
                if document.kind != .text {
                    ShareLink(item: RecordsShareFile(data: document.data, kind: document.kind), preview: SharePreview(model.preparedName)) { Label(recordsText("Share prepared file…"), systemImage: "square.and.arrow.up") }
                } else if let text = String(data: document.data, encoding: .utf8) {
                    ShareLink(item: text) { Label(recordsText("Share prepared text…"), systemImage: "square.and.arrow.up") }
                    DisclosureGroup(recordsText("Preview readable copy")) { Text(text).textSelection(.enabled).accessibilityIdentifier("records.readableText") }
                        .disclosureGroupStyle(LabeledFormDisclosureStyle(label: recordsText("Preview readable copy"), identifier: "records.readablePreview"))
                }
                Button(recordsText("Discard prepared file")) { model.dismissPreparedFile() }.accessibilityIdentifier("records.discardFile")
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
                    Text(recordsTitle(record)).font(.subheadline.bold())
                    ForEach(media) { attachment in
                        Group {
                            Toggle(isOn: Binding(get: { model.selectedMediaIDs.contains(RecordsToolsModel.mediaSelectionID(attachment, record: record)) }, set: { selected in
                                let key = RecordsToolsModel.mediaSelectionID(attachment, record: record)
                                if selected { model.selectedMediaIDs.insert(key) } else { model.selectedMediaIDs.remove(key) }
                            })) { Text((try? RecordsMediaCodec.decode(attachment).reviewedLabel) ?? recordsText("Source reference")) }
                                .accessibilityIdentifier("records.mediaSelection." + attachment.id)
                            RecordsMediaPreview(attachment: attachment)
                        }
                    }
                }
            }
            Text(String(format: recordsText("Selected references: %lld · %@"), Int64(model.selectedMediaCount), ByteCountFormatter.string(fromByteCount: Int64(model.selectedMediaBytes), countStyle: .file)))
                .font(.footnote)
                .accessibilityIdentifier("records.mediaSummary")
            Text(recordsText("Up to twelve references and 4.2 MB of source evidence per recovery file; the encrypted file must be under 8 MB. Choose fewer references if the file is too large.")).font(.footnote)
            if model.selectedMediaCount > 0 {
                Toggle(recordsText("I reviewed the selected references and understand they include private source details."), isOn: $acknowledgedMedia)
                    .accessibilityIdentifier("records.mediaDisclosure")
            }
        }
    }
    private var manualRecipePresentation: Binding<RecordsToolsModel.ImportPresentation?> {
        let presentation = model.importPresentation.flatMap { $0.entry == .manualRecipe ? $0 : nil }
        return Binding(get: {
            model.importPresentation?.entry == .manualRecipe ? model.importPresentation : nil
        }, set: { value in
            if value == nil, let presentation { model.dismissImport(presentation) }
        })
    }
    private var manualRecipeButton: some View {
        Button(recordsText("Add recipe and source manually")) { model.beginImport(.manualRecipe) }
            .accessibilityIdentifier("records.addManualRecipe")
    }
    private var recipeFileButton: some View {
        Button(recordsText("Choose Recipe JSON-LD file…")) { chooseImportFile(recipes: true) }
            .accessibilityIdentifier("records.chooseRecipeFile")
    }
    private var importSection: some View {
        Section(recordsText("Bring records or recipes")) {
            TextField(recordsText("Key for an encrypted recovery file"), text: $model.recoveryKey)
                .textInputAutocapitalization(.never).autocorrectionDisabled()
            Button(recordsText("Choose recovery or helper file…")) { chooseImportFile(recipes: false) }.accessibilityIdentifier("records.chooseFile")
            recipeFileButton
            manualRecipeButton
            Text(recordsText("Recipe files may contain a Recipe, an array, or a graph. Original ingredient and yield text are preserved. Source links are attribution only; this app does not fetch the website."))
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
    private func reviewSection(_ review: RecoveryReview) -> some View {
        let currentVersions = model.currentImportVersions
        return Section {
            if !recipeLibraryOnly {
                importDetail(recordsText("File source"), value: review.envelope.originNamespace)
                Text(RecordsDatePresentation.exportedAt(review.envelope.exportedAtMilliseconds)).accessibilityIdentifier("records.importExportDate")
            }
            if let report = model.recipeReport {
                Text(report.localizedSummary)
                if let fields = report.localizedUnsupportedFields { Text(fields).font(.caption) }
            }
            ForEach(review.rows) { row in
                Group {
                    Text(recordsTitle(row.record)).font(.headline)
                    if !recipeLibraryOnly {
                        Text(RecordsDatePresentation.sourceSavedAt(row.record.savedAtMilliseconds)).font(.caption).accessibilityIdentifier("records.importSourceDate." + row.record.id)
                    }
                    Text(dispositionLabel(row.disposition)).accessibilityIdentifier("records.importDisposition." + row.record.id)
                    if recipeLibraryOnly, let recipe = recipe(row.record) {
                        if let source = recipe.sourceURL { Text(verbatim: source).textSelection(.enabled) }
                        if !recipe.yieldText.isEmpty { Text(verbatim: recipe.yieldText) }
                        ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, line in Text(verbatim: line) }
                        if !recipe.notes.isEmpty { Text(verbatim: recipe.notes) }
                        ForEach(Array(recipe.steps.enumerated()), id: \.offset) { _, step in Text(verbatim: step) }
                    } else {
                        Text(recordsText("Revision: ") + row.record.revision).font(.caption).textSelection(.enabled)
                        if let parent = row.record.parentRevision { Text(recordsText("Parent: ") + parent).font(.caption).textSelection(.enabled) }
                        importVersions(row, fileKind: review.envelope.documentKind, current: currentVersions[row.id] ?? [])
                        ForEach(row.record.media ?? []) { RecordsMediaPreview(attachment: $0) }
                    }
                }
            }
            if let media = review.envelope.mediaManifest {
                Text(String(format: recordsText("Selected references: %lld · %@"), Int64(media.entries.count), ByteCountFormatter.string(fromByteCount: Int64(media.totalBytes), countStyle: .file)))
                Text(recordsText("Selected references recover with these separate copies. They do not reopen the original photo store or restore access to another workspace.")).font(.footnote)
            }
            Text(recipeLibraryOnly
                 ? recordsText("Save these recipes to your library. Open a saved recipe to review its ingredients for a pickup.")
                 : recordsText("Current and newer work stays in place. Different revisions become separate copies; identical imports reopen the saved copy. A conflicting digest or erased identity blocks this batch."))
                .font(.footnote)
            Button(recipeLibraryOnly ? recordsText("Save reviewed recipes") : recordsText("Import reviewed copies")) {
                Task { await model.applyReviewedImport() }
            }.disabled(!review.canApply).accessibilityIdentifier("records.applyImport")
            Button(recordsText("Cancel import"), role: .cancel) { model.cancelReview() }.accessibilityIdentifier("records.cancelImport")
        } header: {
            Text(recordsText("Review before importing"))
                .id("records.importReview")
                .accessibilityFocused($importReviewFocused)
        }
    }
    private func importVersions(_ row: RecoveryReviewRow, fileKind: ArchiveKind,
                                current: [RecordsImportSourceVersion]) -> some View {
        let hasMatches = !current.isEmpty || !row.priorCopies.isEmpty
        let label = hasMatches ? recordsText("Compare versions") : recordsText("Record details")
        let key = importIdentityKey(row.id)
        return DisclosureGroup(label) {
            importDetail(recordsText("Record source"), value: row.id.origin)
                .accessibilityIdentifier("records.importOrigin." + key)
            importDetail(recordsText("Record ID"), value: row.id.recordID)
                .accessibilityIdentifier("records.importRecordID." + key)
            importVersion(heading: recordsText("In this file"), revision: row.id.revision,
                          date: row.record.savedAtMilliseconds, kind: fileKind,
                          referenceCount: row.record.media?.count ?? 0, projection: row.id.projection)
                .accessibilityIdentifier("records.importFileVersion." + key)
            ForEach(current) { version in
                importVersion(heading: recordsText("Current work"), revision: version.revision,
                              date: version.savedAtMilliseconds)
                    .accessibilityIdentifier("records.importCurrentVersion." + key + "." + version.revision)
            }
            ForEach(row.priorCopies) { copy in
                importVersion(heading: recordsText("Previously recovered on this iPhone"), revision: copy.id.revision,
                              date: copy.savedAtMilliseconds, kind: copy.documentKind,
                              referenceCount: copy.selectedReferenceCount, projection: copy.id.projection)
                    .accessibilityIdentifier("records.importPriorVersion." + importIdentityKey(copy.id))
            }
        }
        .disclosureGroupStyle(LabeledFormDisclosureStyle(
            label: label + ", " + recordsTitle(row.record), identifier: "records.importVersions." + key))
    }

    private func importIdentityKey(_ identity: ArchiveIdentity) -> String {
        [identity.origin, identity.recordID, identity.revision, identity.projection]
            .map { $0.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? $0 }
            .joined(separator: "/")
    }

    private func importDetail(_ label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label).font(.caption).foregroundStyle(.secondary)
            Text(verbatim: value).textSelection(.enabled)
        }.accessibilityElement(children: .combine)
    }

    private func importVersion(heading: String, revision: String, date: Int64,
                               kind: ArchiveKind? = nil, referenceCount: Int = 0, projection: String? = nil) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(heading).font(.subheadline.bold())
            Text(recordsText("Revision: ") + revision)
            Text(RecordsDatePresentation.sourceSavedAt(date))
            if let kind {
                Text(kind == .personalRecovery ? recordsText("Personal recovery copy") : recordsText("Helper copy"))
            }
            if referenceCount > 0, let projection {
                Text(String(format: recordsText("Selected references · %lld"), Int64(referenceCount)))
                Text(String(format: recordsText("Selection ID · %@"), projection)).foregroundStyle(.secondary)
            }
        }.font(.caption).textSelection(.enabled).accessibilityElement(children: .combine)
    }
    @ViewBuilder private var recoveredSection: some View {
        let remaining = model.recoveredRecords.filter { !model.reopenedCopyIDs.contains($0.id) }
        if model.recoveredRecords.isEmpty || !remaining.isEmpty || model.deleteUndo != nil {
            Section(recordsText("Recovered copies and saved recipes")) {
                if model.recoveredRecords.isEmpty { Text(recordsText("No recovered copies yet.")) }
                ForEach(remaining) { saved in recoveredCopy(saved) }
                if model.deleteUndo != nil { Button(recordsText("Undo recovered-copy deletion")) { Task { await model.undoRecoveredDeletion() } } }
            }
        }
    }
    private func recoveredCopy(_ saved: RecoveredRecord) -> some View {
        DisclosureGroup(recordsTitle(saved.record),
            isExpanded: Binding(get: { recoveredExpandedIDs.contains(saved.id) }, set: { expanded in
                if expanded { recoveredExpandedIDs.insert(saved.id) } else { recoveredExpandedIDs.remove(saved.id) }
            })) {
            Text(saved.record.origin).font(.caption).textSelection(.enabled)
            if saved.record.kind == .sharedShop || saved.record.kind == .sharedHistory {
                Text(RecordsDatePresentation.sourceSavedAt(saved.record.savedAtMilliseconds)).font(.caption).accessibilityIdentifier("records.recoveredSourceDate." + saved.record.id)
                Text(RecordsDatePresentation.recoveredAt(saved.recoveredAtMilliseconds)).font(.caption).accessibilityIdentifier("records.recoveryDate." + saved.record.id)
            }
            Text(recordsText("Revision: ") + saved.record.revision).font(.caption).textSelection(.enabled)
            if let recipe = recipe(saved.record) {
                Text(recipe.yieldText)
                ForEach(Array(recipe.ingredients.enumerated()), id: \.offset) { _, text in Text(text) }
                ForEach(Array(recipe.steps.enumerated()), id: \.offset) { _, text in Text(text) }
                if !recipe.notes.isEmpty { Text(recipe.notes) }
                if let source = recipe.sourceURL { Text(source).textSelection(.enabled).font(.caption) }
                Button(recordsText("Open saved recipe")) { Task { await model.openRecovered(saved) } }
            } else if saved.record.nativePayload != nil {
                Button(recordsText("Open separate recovered copy")) { Task { await model.openRecovered(saved) } }.accessibilityIdentifier("records.openRecovered." + saved.record.id)
            } else {
                Text(recordsReadableText(saved.record, owner: false)).textSelection(.enabled)
                Text(recordsText("This helper projection has no private payload and cannot replace an owner record.")).font(.footnote)
            }
            ForEach(saved.record.media ?? []) { RecordsMediaPreview(attachment: $0) }
            Button(recordsText("Delete this recovered copy"), role: .destructive) { deletion = Deletion(title: recordsTitle(saved.record), source: nil, recovered: .copy(saved.id)) }
            Button(recordsText("Delete recovered copies from this source"), role: .destructive) { deletion = Deletion(title: saved.record.origin, source: nil, recovered: .origin(saved.record.origin)) }
        }
        .disclosureGroupStyle(LabeledFormDisclosureStyle(
            label: recordsText("Recovered copy") + ": " + (recordsTitle(saved.record)),
            identifier: "records.recovered." + saved.record.title))
    }
    private func savePreparedFile() {
        guard let id = model.beginFileSave() else { return }
        #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
        if let uiTestFiles, let document = model.preparedDocument {
            let result = Result { try uiTestFiles.save(document) }
            finishFileSave(id, result)
            return
        }
        #endif
        presentedSaveID = id
        exporting = true
    }
    private func finishFileSave(_ id: UUID?, _ result: Result<Void, Error>) {
        guard let id else { return }
        let date = Date.now
        Task { await model.finishFileSave(id, result: result, at: date) }
    }
    private func chooseImportFile(recipes: Bool) {
        model.beginImport(recipes ? .recipeFile : .recordsFile)
    }
    private func recordKindLabel(_ kind: ArchiveRecordKind) -> String {
        switch kind {
        case .comparison: return recordsText("Pack comparison")
        case .ledger: return recordsText("Shopping list and dinners")
        case .pickup: return recordsText("Pickup history")
        case .recipe: return recordsText("Recipe")
        case .sharedShop: return recordsText("Shared pickup record")
        case .sharedHistory: return recordsText("Shared pickup history")
        }
    }
    private func recipe(_ record: ArchiveRecord) -> ImportedRecipe? {
        guard record.kind == .recipe, let data = record.nativePayload else { return nil }
        return try? JSONDecoder().decode(ImportedRecipe.self, from: data)
    }
    private func dispositionLabel(_ value: RecoveryDisposition) -> String {
        switch value {
        case .absent: return recordsText("Ready to recover a separate copy")
        case .identical: return recordsText("Identical — reopen existing copy")
        case .sibling: return recordsText("Related revision — keep both copies")
        case .quarantined: return recordsText("Same identity, different content — blocked")
        case .erased: return recordsText("Previously deleted here — blocked")
        }
    }
    private func unavailableMessage(_ reason: RecordsUnavailableRecord.Reason) -> String {
        switch reason {
        case .retiredHistory: return recordsText("This pickup’s history has been retired.")
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
        case .exportSelectionChanged: return recordsText("Your selection changed. Review the selected records and source references, then prepare the file again.")
        case .invalidRecipe: return recordsText("Check the recipe title, source URL and text. Use a supported Recipe JSON-LD file or enter it manually.")
        case .unavailable: return recordsText("The local operation could not finish. Your current records are still available. Try again.")
        }
    }
}

/// The preview opens only bytes already validated and committed with this copy.
/// It never follows recovered namespace references into a live media store.
@MainActor private struct RecordsMediaPreview: View {
    let attachment: ArchiveMediaAttachment
    @State private var expanded = false
    var body: some View {
        if let source = try? RecordsMediaCodec.decode(attachment) {
            DisclosureGroup(recordsText("Preview source reference"), isExpanded: $expanded) {
                Text(source.reviewedLabel).font(.headline)
                Text(kindLabel).font(.caption)
                if attachment.captureNamespace != nil { Text(recordsText("Captured in a separate recovered workspace.")).font(.caption) }
                Text(ByteCountFormatter.string(fromByteCount: Int64(attachment.data.count), countStyle: .file)).font(.caption)
                Text(source.capturedAt, format: .dateTime.year().month().day().hour().minute()).font(.caption)
                if let data = source.imageJPEG, let image = UIImage(data: data) {
                    Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                        .accessibilityLabel(recordsText("Selected reduced source photo"))
                        .accessibilityIdentifier("records.mediaImage." + attachment.id)
                }
                Text(source.originalText).textSelection(.enabled).accessibilityIdentifier("records.mediaWording." + attachment.id)
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
            .disclosureGroupStyle(LabeledFormDisclosureStyle(label: recordsText("Preview source reference") + ": " + source.reviewedLabel,
                identifier: "records.mediaPreview." + attachment.id))
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
    var selfSelectionID: RecordsSelectionID { RecordsToolsModel.selectionID(self) }
}

private struct RecordsImportFilePicker: View {
    let presentation: RecordsToolsModel.ImportPresentation
    let completion: (Result<URL, Error>) -> Void
    @State private var presented = false
    #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
    @Environment(\.recordsMediaUITestFiles) private var uiTestFiles
    #endif

    var body: some View {
        Color.clear
            .fileImporter(isPresented: $presented, allowedContentTypes: presentation.entry == .recipeFile
                          ? [.json, .data] : [.json, .roomRecovery, .roomHelper, .data], allowsMultipleSelection: false,
                          onCompletion: { result in
                completion(result.flatMap { urls in
                    guard let url = urls.first else { return .failure(CancellationError()) }
                    return .success(url)
                })
            }, onCancellation: { completion(.failure(CancellationError())) })
            .onAppear {
                #if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
                if let uiTestFiles {
                    if let url = uiTestFiles.selectedURL() { completion(.success(url)) }
                    else { completion(.failure(CancellationError())) }
                    return
                }
                #endif
                presented = true
            }
    }
}

private struct ManualRecipeEntryView: View {
    @Environment(\.dismiss) private var dismiss
    let submit: (ImportedRecipe) async -> String?
    @State private var submitting = false
    @State private var submissionError: String?
    @AccessibilityFocusState private var errorFocused: Bool
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
                if let submissionError {
                    Text(submissionError)
                        .foregroundStyle(.red)
                        .accessibilityFocused($errorFocused)
                        .accessibilityIdentifier("records.manualRecipeError")
                }
                Button(recordsText("Review recipe")) {
                    guard !submitting else { return }
                    submitting = true
                    let recipe = ImportedRecipe(title: title, yieldText: servings,
                        ingredients: ingredients.components(separatedBy: .newlines).filter { !$0.isEmpty },
                        steps: steps.components(separatedBy: .newlines).filter { !$0.isEmpty },
                        sourceURL: source.isEmpty ? nil : source, notes: notes)
                    Task {
                        submissionError = await submit(recipe)
                        submitting = false
                        if submissionError == nil { dismiss() }
                        else { errorFocused = true }
                    }
                }.disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .navigationTitle(recordsText("Save a recipe"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(recordsText("Cancel")) { dismiss() }.disabled(submitting) } }
            .disabled(submitting)
        }
        .interactiveDismissDisabled(submitting)
    }
}
