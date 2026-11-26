import CoreDomain
import LocalStore
import SwiftUI
import UniformTypeIdentifiers

func pantryPlacePath(_ location: InventoryLocation, _ place: InventoryNamedPlace?) -> String {
    ([pantryLocationName(location)] + [place?.storage, place?.drawer].compactMap { $0 }.filter { !$0.isEmpty })
        .joined(separator: " › ")
}

struct PantryNamedPlacesView: View {
    @ObservedObject var model: PantryModel
    let origin: UUID
    @State private var query = ""
    @State private var physical: InventoryLocation?
    @State private var selection = Set<UUID>()
    @State private var storage = ""
    @State private var drawer = ""
    @State private var review: PantryPutaway?
    @State private var undo: PantryPutaway?
    @State private var message: String?

    var body: some View {
        JournalList {
            if model.phase == .ready, let snapshot = model.snapshot, snapshot.state.workspaceID == origin {
                if let message { Text(message) }
                if let review {
                    Section(pantryText("Review named location")) {
                        Text(verbatim: pantryPlacePath(review.storage, review.destination))
                        ForEach(review.rows) { row in
                            LabeledContent(row.name, value: pantryPlacePath(review.storage, row.before))
                        }
                        Button(pantryText("Save location labels")) { Task { await save(review, undoing: false) } }
                            .disabled(!model.canEdit || snapshot.state != review.basis)
                        if snapshot.state != review.basis { Text(pantryText("Pantry changed. Review your selection again.")) }
                        Button(pantryText("Cancel")) { self.review = nil }
                    }
                } else {
                    if let undo {
                        let conflicts = undo.rows.filter { row in
                            snapshot.lots.first { $0.id == row.id }?.revision != row.revision + 1
                        }
                        Section(pantryText("Last location change")) {
                            if conflicts.isEmpty {
                                if snapshot.state.revision != undo.basis.revision + 1 {
                                    Text(pantryText("The pantry changed after put-away. These selected location labels can still be restored."))
                                }
                                Button(pantryText("Undo location labels")) { Task { await save(undo, undoing: true) } }
                                    .disabled(!model.canEdit)
                            } else {
                                Text(pantryText("These batches changed after put-away. Undo is unavailable."))
                                ForEach(conflicts) { Text(verbatim: $0.name) }
                            }
                        }
                    }
                    Section(pantryText("Find food")) {
                        TextField(pantryText("Search food, storage or drawer"), text: $query)
                        Picker(pantryText("Storage location"), selection: Binding(get: { physical }, set: {
                            physical = $0
                            selection.removeAll(); storage = ""; drawer = ""
                        })) {
                            Text(pantryText("All locations")).tag(nil as InventoryLocation?)
                            ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag(Optional($0)) }
                        }
                        ForEach(snapshot.lots.filter {
                            let path = pantryPlacePath($0.location, $0.namedPlace)
                            return (physical == nil || $0.location == physical) && (query.isEmpty ||
                                $0.name.localizedStandardContains(query) || path.localizedStandardContains(query))
                        }) { lot in
                            Button {
                                if selection.contains(lot.id) { selection.remove(lot.id) }
                                else if selection.count < 64 {
                                    selection.insert(lot.id)
                                    if physical == nil { physical = lot.location }
                                }
                            } label: {
                                HStack {
                                    Image(systemName: selection.contains(lot.id) ? "checkmark.circle.fill" : "circle")
                                    VStack(alignment: .leading) {
                                        Text(verbatim: lot.name)
                                        Text(verbatim: pantryPlacePath(lot.location, lot.namedPlace)).font(.caption)
                                    }
                                }
                            }.accessibilityAddTraits(selection.contains(lot.id) ? .isSelected : [])
                        }
                    }
                    if !selection.isEmpty, let physical {
                        Section(pantryText("Put away selected food")) {
                            Text(pantryFormat("%lld batches selected", Int64(selection.count)))
                            TextField(pantryText("Storage name"), text: $storage)
                            TextField(pantryText("Drawer or bin (optional)"), text: $drawer)
                            let existing = Set(snapshot.lots.filter { $0.location == physical }.compactMap(\.namedPlace))
                            if !existing.isEmpty {
                                Menu(pantryText("Use a saved place")) {
                                    ForEach(existing.sorted { ($0.storage, $0.drawer) < ($1.storage, $1.drawer) }, id: \.self) { place in
                                        Button(pantryPlacePath(physical, place)) { storage = place.storage; drawer = place.drawer }
                                    }
                                }
                            }
                            Button(pantryText("Review named location")) { stage(snapshot) }
                                .disabled(!model.canEdit || (storage.isEmpty && !drawer.isEmpty))
                            if selection.count == 1, let lotID = selection.first {
                                NavigationLink(pantryText("Move to another storage type")) {
                                    PantryLotEntryView(model: model, lotID: lotID, accessAllowed: true)
                                }
                            }
                        }
                    }
                }
            }
        }
        .navigationTitle(pantryText("Named pantry places")).privacySensitive()
        .onChange(of: model.generation) { _, _ in
            review = nil; undo = nil; selection.removeAll(); message = nil; query = ""; storage = ""; drawer = ""
        }
    }

    private func stage(_ snapshot: PantryRepository.Snapshot) {
        do {
            let place = storage.isEmpty && drawer.isEmpty ? nil : InventoryNamedPlace(storage: storage, drawer: drawer)
            guard let physical else { return }
            review = try PantryPutaway(storage: physical, destination: place, selection: selection,
                                       lots: snapshot.lots, basis: snapshot.state)
            message = nil
        } catch { message = pantryText("Choose a different place or check its name.") }
    }

    private func save(_ change: PantryPutaway, undoing: Bool) async {
        guard model.canEdit, let basis = model.snapshot?.state, basis.workspaceID == origin else { return }
        do {
            try await model.saveOrganization(change.edits(undo: undoing), basis: undoing ? basis : change.basis)
            undo = undoing ? nil : change
            review = nil; selection.removeAll(); message = pantryText("Saved")
        } catch {
            await model.load()
            message = pantryText("Pantry changed. Review your selection again.")
        }
    }
}

extension PantryCSVField {
    var title: String {
        switch self {
        case .item: pantryText("Food name")
        case .lot: pantryText("Lot identifier")
        case .quantity: pantryText("Quantity")
        case .unit: pantryText("Unit")
        case .date: pantryText("Date as written")
        case .location: pantryText("Storage location")
        case .barcode: pantryText("Barcode")
        case .category: pantryText("Category")
        case .note: pantryText("Note")
        }
    }
}

struct PantrySpreadsheetEvidenceView: View {
    let evidence: InventorySpreadsheetRow
    var body: some View {
        DisclosureGroup(pantryText("Original spreadsheet row")) {
            LabeledContent(pantryText("Source spreadsheet"), value: evidence.sourceName)
            Text(verbatim: evidence.label)
            if evidence.rowKey.hasPrefix("lot-") {
                LabeledContent(PantryCSVField.lot.title, value: String(evidence.rowKey.dropFirst(4)))
            }
            ForEach(Array([
                (PantryCSVField.quantity, evidence.quantity), (.unit, evidence.unit), (.date, evidence.date),
                (.location, evidence.location), (.barcode, evidence.barcode), (.category, evidence.category),
                (.note, evidence.note)
            ].enumerated()), id: \.offset) { _, field in
                if !field.1.isEmpty { LabeledContent(field.0.title, value: field.1) }
            }
        }
    }
}

struct PantryCSVImportView: View {
    @ObservedObject var model: PantryModel
    let origin: UUID
    @State private var choosingFile = false
    @State private var table: GroceryCSVTable?
    @State private var mapping: [PantryCSVField: Int] = [:]
    @State private var sourceName = ""
    @State private var fallback: InventoryLocation = .cupboard
    @State private var preview: PantryCSVPreview?
    @State private var showEveryRow = false
    @State private var message: String?
    @State private var saving = false
    @State private var saveTask: Task<Void, Never>?

    var body: some View {
        JournalList {
            if model.phase == .ready, let snapshot = model.snapshot, snapshot.state.workspaceID == origin {
                if let message { Text(message) }
                if let preview { reviewSection(preview) }
                else {
                    Section {
                        Button(pantryText("Choose a pantry CSV")) { choosingFile = true }
                        if let table {
                            TextField(pantryText("Source spreadsheet"), text: $sourceName)
                            Text(pantryText("Keep this source name when importing an updated file."))
                            ForEach(PantryCSVField.allCases) { field in
                                Picker(field.title, selection: Binding(get: { mapping[field] ?? -1 }, set: {
                                    mapping[field] = $0 == -1 ? nil : $0
                                })) {
                                    Text(pantryText("Skip column")).tag(-1)
                                    ForEach(table.headers.indices, id: \.self) { i in Text(verbatim: table.headers[i]).tag(i) }
                                }
                            }
                            Picker(pantryText("Storage for unrecognized or empty locations"), selection: $fallback) {
                                ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                            }
                            Text(pantryText("Use a unique lot column when updating or reordering rows. Without one, keep rows in their original order."))
                            Button(pantryText("Preview pantry import")) {
                                do {
                                    preview = try .init(table: table, mapping: mapping, sourceName: sourceName,
                                        defaultLocation: fallback, basis: snapshot.state, lots: snapshot.lots)
                                    showEveryRow = false
                                    message = nil
                                } catch { message = pantryText("Choose a food name column and map each column once.") }
                            }.disabled(!model.canEdit)
                        }
                    }
                }
            }
        }
        .navigationTitle(pantryText("Import pantry CSV")).privacySensitive()
        .fileImporter(isPresented: $choosingFile, allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
            guard model.canEdit, model.snapshot?.state.workspaceID == origin else { clear(); return }
            guard case .success(let url) = result else { return }
            do {
                let access = url.startAccessingSecurityScopedResource()
                defer { if access { url.stopAccessingSecurityScopedResource() } }
                let handle = try FileHandle(forReadingFrom: url)
                defer { try? handle.close() }
                let data = try handle.read(upToCount: GroceryCSVTable.maximumBytes + 1) ?? Data()
                let value = try GroceryCSVTable(data: data)
                table = value; mapping = PantryCSVField.suggest(value.headers)
                sourceName = url.deletingPathExtension().lastPathComponent; preview = nil; message = nil
            } catch {
                clear()
                message = pantryText("Could not read this spreadsheet. Use a UTF-8 CSV with a header row.")
            }
        }
        .onDisappear { saveTask?.cancel() }
        .onChange(of: model.generation) { _, _ in saveTask?.cancel(); clear() }
    }

    @ViewBuilder private func reviewSection(_ value: PantryCSVPreview) -> some View {
        Section(pantryText("Review pantry import")) {
            Text(pantryText("New lots have an unknown count. Dates and amounts are kept as written until you check the food. Changed rows update source details only."))
            ForEach(Array((showEveryRow ? value.rows[...] : value.rows.prefix(5))), id: \.id) { row in
                VStack(alignment: .leading) {
                    Text(verbatim: pantryFormat("Row %lld", Int64(row.id)) + " · " + row.source.label)
                    Text(verbatim: status(row.status) + " · " + pantryLocationName(row.location)).font(.caption)
                    ForEach(row.issues, id: \.self) { issue in
                        Text(issueMessage(issue)).font(.caption)
                    }
                    PantrySpreadsheetEvidenceView(evidence: row.source)
                }
            }
            if value.rows.count > 5 {
                Button(pantryText(showEveryRow ? "Show first five rows" : "Show all rows")) { showEveryRow.toggle() }
            }
            Text(pantryFormat("%lld additions · %lld changed · %lld already imported · %lld skipped",
                              Int64(value.rows.filter { $0.status == .add }.count),
                              Int64(value.rows.filter { $0.status == .update }.count),
                              Int64(value.rows.filter { $0.status == .unchanged }.count),
                              Int64(value.rows.filter { $0.status == .invalid || $0.status == .conflicting }.count)))
            Button(pantryText("Save reviewed pantry rows")) {
                saveTask = Task { await save(value) }
            }.disabled(saving || !model.canEdit || value.changes.isEmpty || model.snapshot?.state != value.basis)
            Button(pantryText("Back to column mapping")) { preview = nil }.disabled(saving)
        }
    }

    private func issueMessage(_ issue: PantryCSVPreview.Issue) -> String {
        switch issue {
        case .columns: pantryText("The number of fields differs from the header.")
        case .label: pantryText("The food name is empty.")
        case .lotKey: pantryText("The lot identifier is empty or repeated.")
        case .bounds: pantryText("A mapped field is too long or contains invalid text.")
        case .unknownPlace: pantryText("The location wording is unrecognized. The selected storage type will be used.")
        case .ambiguousDate: pantryText("The day and month are ambiguous. The original date is kept as text.")
        }
    }

    private func status(_ value: PantryCSVPreview.Status) -> String {
        switch value {
        case .add: pantryText("New lot")
        case .update: pantryText("Update original wording")
        case .unchanged: pantryText("Already imported")
        case .invalid: pantryText("Skipped: missing, duplicate or invalid field")
        case .conflicting: pantryText("Skipped: this row previously identified another lot")
        }
    }

    private func save(_ value: PantryCSVPreview) async {
        guard !saving, let initial = model.snapshot?.state, initial == value.basis else { return }
        saving = true
        defer { saving = false; saveTask = nil }
        var basis = initial
        let changes = value.changes
        do {
            for first in stride(from: 0, to: changes.count, by: 32) {
                try Task.checkCancellation()
                let rows = changes[first..<min(first + 32, changes.count)]
                let edits = try rows.map { try PantryCSVPreview.edit($0, origin: origin) }
                try await model.saveOrganization(edits, basis: basis)
                guard let next = model.snapshot?.state, next.workspaceID == origin,
                      next.revision == basis.revision + 1 else { throw InventoryError.stale }
                basis = next
            }
            clear()
            message = pantryText("Pantry import saved.")
        } catch {
            await model.load()
            preview = nil
            message = pantryText("Review the file again. Rows already saved will be recognized.")
        }
    }

    private func clear() {
        table = nil; preview = nil; mapping = [:]; sourceName = ""; message = nil; showEveryRow = false
    }
}
