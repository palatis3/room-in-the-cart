import CoreDomain
import CryptoKit
import PhotosUI
import SwiftUI

struct PantryPackageDateSection: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let access: PantryDigestAccess
    @ObservedObject var store: PantryPackageDateStore

    var body: some View {
        Section(pantryText("Printed package date")) {
            if let current = try? store.load(access.scope, lot: lot.id) {
                Text(verbatim: current.wording)
                Text(current.meaning.label)
                if let day = current.day { Text(dinnerDay(day)) }
            }
            NavigationLink(pantryText("Review the date on this package")) {
                PantryPackageDateEditor(model: model, lot: lot, access: access, store: store)
            }.accessibilityIdentifier("pantry.packageDate")
        }
    }
}

@MainActor private struct PantryPackageDateEditor: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let access: PantryDigestAccess
    let store: PantryPackageDateStore
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @FocusState private var editing: Bool
    @State private var visible = false
    @State private var reviewedLot: InventoryLot?
    @State private var reviewedScope: PantryDigestScope?
    @State private var previous: PrintedPackageDate?
    @State private var loaded = false
    @State private var wording = ""
    @State private var meaning = PrintedDateMeaning.other
    @State private var hasDay = false
    @State private var date = Date()
    @State private var zone = TimeZone.current.identifier
    @State private var photoText: String?
    @State private var photoDigest: String?
    @State private var readingDigest: String?
    @State private var preview: UIImage?
    @State private var photo: PhotosPickerItem?
    @State private var camera = false
    @State private var rows: [String] = []
    @State private var uncertain: Set<String> = []
    @State private var selected: Set<Int> = []
    @State private var work: Task<Void, Never>?
    @State private var operation = UUID()
    @State private var busy = false
    @State private var saving = false
    @State private var status: String?

    private var currentAccess: Bool {
        visible && scene == .active && access.authorized() && model.phase == .ready &&
            model.snapshot?.state.workspaceID == access.scope.origin &&
            model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot
    }
    private var authorized: Bool { currentAccess && reviewedLot == lot && reviewedScope == access.scope }
    private var proposal: PrintedPackageDate? {
        let day = hasDay ? try? MealDay(date: date, timeZoneIdentifier: zone) : nil
        guard !hasDay || day != nil else { return nil }
        let value = PrintedPackageDate(wording: wording, meaning: meaning, day: day, selectedPhotoText: photoText, photoDigest: photoDigest)
        do { try value.validate(); return value } catch { return nil }
    }
    var body: some View {
        Form {
            if authorized && loaded {
                Section {
                    Text(verbatim: lot.name).font(.headline)
                    Text(pantryText("Record what the package says. The storage estimate and reminder are separate."))
                }
                source
                Section(pantryText("Review the label")) {
                    TextField(pantryText("Printed wording"), text: $wording, axis: .vertical)
                        .focused($editing).accessibilityIdentifier("packageDate.wording")
                    Picker(pantryText("Meaning printed on the package"), selection: $meaning) {
                        ForEach(PrintedDateMeaning.allCases, id: \.self) { Text($0.label).tag($0) }
                    }
                    Toggle(pantryText("The full calendar date is clear"), isOn: $hasDay)
                        .accessibilityIdentifier("packageDate.hasDay")
                    if hasDay {
                        DatePicker(pantryText("Printed calendar date"), selection: $date, displayedComponents: .date)
                            .environment(\.timeZone, TimeZone(identifier: zone) ?? .current)
                    }
                    LabeledContent(pantryText("Label source"), value: photoText == nil ? pantryText("Entered by hand") : pantryText("Selected label photo"))
                    if let photoText {
                        LabeledContent(pantryText("Selected text from your photo"), value: photoText)
                    }
                }
                Section {
                    Button(pantryText("Save printed label")) { Task { await save(proposal) } }
                        .disabled(proposal == nil || saving || busy)
                        .accessibilityIdentifier("packageDate.save")
                    if previous != nil {
                        Button(pantryText("Remove saved label"), role: .destructive) { Task { await save(nil) } }
                            .disabled(saving || busy).accessibilityIdentifier("packageDate.remove")
                    }
                    Button(pantryText("Cancel")) { dismiss() }.disabled(saving)
                }
            } else {
                Text(pantryText("Reopen this pantry batch to review its current package label."))
            }
            if let status { Text(status).accessibilityIdentifier("packageDate.status") }
        }
        .privacySensitive()
        .navigationTitle(pantryText("Printed package date"))
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: editing, title: ledgerText("Done"), identifier: "packageDate.done") { editing = false }
        .onAppear { visible = true; if !loaded { load() } }
        .onChange(of: currentAccess) { _, allowed in if allowed && !loaded { load() } }
        .onDisappear { if !camera { visible = false; cancelRead() } }
        .onChange(of: scene) { _, phase in if phase == .background { cancelRead(); clearPhoto() } }
        .fullScreenCover(isPresented: $camera) {
            CameraCaptureView(authorize: { authorized }) { result in
                camera = false
                guard authorized else { return }
                switch result {
                case .success(let data): read { data }
                case .failure: status = pantryText("Could not read this photo. Type the wording or choose another photo.")
                case nil: break
                }
            }.ignoresSafeArea()
        }
    }
    private var source: some View {
        Section(pantryText("Label photo")) {
            Text(pantryText("Text recognition runs on this iPhone. Only the wording you select is saved."))
            PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                Label(pantryText("Choose a label photo"), systemImage: "photo")
            }.onChange(of: photo) { _, item in
                guard let item else { return }
                photo = nil
                read {
                    guard let input = try await item.loadTransferable(type: SelectedPhotoTransfer.self) else { throw ScanFailure.invalidImage }
                    return try input.data
                }
            }
            Button(pantryText("Photograph the printed date")) {
                Task {
                    do {
                        try await CameraCapturePermission.request()
                        if authorized { camera = true }
                    } catch { status = pantryText("Camera unavailable. Choose a photo or type the printed wording.") }
                }
            }
            if let preview {
                Image(uiImage: preview).resizable().scaledToFit()
                    .accessibilityLabel(pantryText("Selected package label photo"))
            }
            if busy { ProgressView(pantryText("Reading the package label…")) }
            if !rows.isEmpty {
                Text(pantryText("Select the lines that belong to this date. Review any unclear text.")).font(.footnote)
                ForEach(rows.indices, id: \.self) { index in
                    Button {
                        if selected.contains(index) { selected.remove(index) } else { selected.insert(index) }
                    } label: {
                        HStack {
                            Image(systemName: selected.contains(index) ? "checkmark.circle.fill" : "circle")
                            VStack(alignment: .leading) {
                                Text(verbatim: rows[index])
                                if uncertain.contains(rows[index]) { Text(pantryText("Unclear text")).font(.caption) }
                            }
                        }
                    }.accessibilityAddTraits(selected.contains(index) ? .isSelected : [])
                }
                Button(pantryText("Use selected wording")) {
                    let text = selected.sorted().map { rows[$0] }.joined(separator: "\n")
                    guard let digest = readingDigest, let draft = try? PrintedPackageDate.reviewingPhoto(text, digest: digest, zone: zone) else {
                        status = pantryText("Choose fewer lines or type the printed wording."); return
                    }
                    wording = draft.wording
                    photoText = draft.selectedPhotoText
                    photoDigest = draft.photoDigest
                    meaning = draft.meaning
                    hasDay = draft.day != nil
                    if let value = draft.day?.date { date = value }
                    clearPhoto(); status = nil
                }.disabled(selected.isEmpty)
            }
        }
    }
    private func load() {
        guard currentAccess else { return }
        reviewedLot = lot; reviewedScope = access.scope
        do {
            let value = try store.load(access.scope, lot: lot.id)
            previous = value; wording = value?.wording ?? ""; meaning = value?.meaning ?? .other
            hasDay = value?.day != nil; date = value?.day?.date ?? Date()
            zone = value?.day?.timeZoneIdentifier ?? TimeZone.current.identifier
            photoText = value?.selectedPhotoText; photoDigest = value?.photoDigest; loaded = true
        } catch { status = pantryText("The saved label could not be opened.") }
    }
    private func clearPhoto() { rows = []; uncertain = []; selected = []; preview = nil; readingDigest = nil }
    private func cancelRead() { operation = UUID(); work?.cancel(); work = nil; busy = false }
    private func read(_ bytes: @escaping () async throws -> Data) {
        cancelRead()
        guard authorized else { return }
        let token = operation
        busy = true; clearPhoto(); status = nil
        work = Task {
            defer { if operation == token { busy = false } }
            do {
                let data = try await bytes()
                guard !Task.isCancelled, operation == token, authorized else { return }
                let recognized = try await OnDeviceTextCapture().recognize(data)
                guard !Task.isCancelled, operation == token, authorized else { return }
                rows = recognized.text.components(separatedBy: .newlines).filter { !$0.isEmpty }
                uncertain = Set(recognized.uncertainLines)
                preview = recognized.previewImageData.flatMap { UIImage(data: $0) }
                readingDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } catch {
                if !Task.isCancelled && operation == token && authorized {
                    status = pantryText("Could not read this photo. Type the wording or choose another photo.")
                }
            }
        }
    }
    private func save(_ value: PrintedPackageDate?) async {
        guard authorized, loaded, !saving else { return }
        saving = true; defer { saving = false }
        do {
            try await model.verifyDigestLot(lot, origin: access.scope.origin)
            try store.replace(previous, with: value, scope: access.scope, lot: lot.id, authorized: { authorized })
            dismiss()
        } catch { status = pantryText("The batch or its saved label changed. Reopen it before saving.") }
    }
}
