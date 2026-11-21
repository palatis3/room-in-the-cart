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
        let saved = access.authorized() ? (try? store.load(access.scope, lot: lot.id)) : nil
        Section(pantryText("Package label")) {
            if let current = saved {
                if let original = current.originalPrintedWording {
                    LabeledContent(pantryText("Original printed wording"), value: original)
                }
                LabeledContent(current.meaningLabel, value: current.meaning.label)
                if let lot = current.encodedSource?.gs1?.lot { LabeledContent(pantryText("Package lot number"), value: lot) }
                if let day = current.verifiedDay { LabeledContent(current.sourceLabel, value: dinnerDay(day)) }
                if current.yearNeedsReview { Text(pantryText("Confirm the year from the package before saving.")) }
            }
            NavigationLink(pantryText(saved == nil ? "Add the package date" : "Edit the package date")) {
                PantryPackageDateEditor(model: model, lot: lot, access: access, store: store)
            }.accessibilityIdentifier("pantry.packageDate")
        }
    }
}

@MainActor struct PantryPackageDateEditor: View {
    @ObservedObject var model: PantryModel
    let lot: InventoryLot
    let access: PantryDigestAccess
    let store: PantryPackageDateStore
    var scannedCode: CapturedBarcode? = nil
    var reviewedDateWording: String? = nil
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scene
    @Environment(\.pantryDigestPermissionPrompt) private var permissionPrompt
    private enum Field: Hashable { case wording, year }
    @FocusState private var editing: Field?
    @State private var visible = false
    @State private var reviewedLot: InventoryLot?
    @State private var reviewedScope: PantryDigestScope?
    @State private var previous: PrintedPackageDate?
    @State private var loaded = false
    @State private var wording = ""
    @State private var meaning = PrintedDateMeaning.other
    @Environment(\.locale) private var locale
    @State private var pendingMonthDay: PrintedPackageDate.MonthDay?
    @State private var printedYear = ""
    @State private var confirmingCalendar = false
    @State private var hasDay = false
    @State private var date = Date()
    @State private var selectedAI: String?
    @State private var photographedCode: CapturedBarcode?
    @State private var rejectedPhoto = false
    private var physicalSources: [CapturedBarcode] {
        let links = (try? PantryDigestStore.shared.packMemory.receiptLinks(lotID: lot.id, scope: access.scope)) ?? []
        return [lot.packageCode, scannedCode, previous?.encodedSource].compactMap { $0 } + links.map(\.code)
    }
    private var encodedCode: CapturedBarcode? {
        guard !rejectedPhoto else { return nil }
        return ([photographedCode] + physicalSources.map(Optional.some)).compactMap { $0 }
            .first { $0.gs1 != nil && PackageDateBinding.accepts($0, for: physicalSources) }
    }

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
    @State private var photoStatus: String?
    @State private var requestingCamera = false

    private var currentAccess: Bool {
        visible && scene == .active && access.authorized() && model.phase == .ready &&
            model.snapshot?.state.workspaceID == access.scope.origin &&
            model.snapshot?.lots.first(where: { $0.id == lot.id }) == lot
    }
    private var authorized: Bool { currentAccess && reviewedLot == lot && reviewedScope == access.scope }
    private var proposal: PrintedPackageDate? {
        let day = hasDay ? try? MealDay(date: date, timeZoneIdentifier: zone) : nil
        guard !hasDay || day != nil else { return nil }
        let encoded = selectedAI.flatMap { ai in encodedCode?.gs1?.dates.first { $0.ai == ai } }
        let useEncoded = encoded != nil && day != nil && encoded?.day(zone: zone) == day && meaning == (encoded?.ai == "15" ? .bestBefore : .expires)
        let text = wording.isEmpty && useEncoded ? "GS1 (" + (encoded?.ai ?? "") + ") " + (encoded?.literal ?? "") : wording
        let value = PrintedPackageDate(wording: text, meaning: meaning, day: day, selectedPhotoText: photoText, photoDigest: photoDigest,
                                       encodedSource: encodedCode ?? previous?.encodedSource, selectedAI: useEncoded ? selectedAI : nil,
                                       wordingIsPrinted: useEncoded ? !wording.isEmpty : nil,
                                       confirmedPrintedYear: !useEncoded && !PrintedPackageDate.monthDayChoices(in: wording).isEmpty ? day?.year : nil)
        do { try value.validate(); return value } catch { return nil }
    }
    var body: some View {
        WorkingForm {
            if authorized && loaded {
                let gs1 = encodedCode?.gs1
                let reviewingSource = gs1 != nil || preview != nil || busy
                Section {
                    PantryBatchHeading(lot: lot)
                    Text(pantryText("Copy the date as printed, even if it only gives a month and year. You can choose a check day separately."))
                }
                Section(pantryText("Review the label")) {
                    WorkingField(pantryText("Original printed wording")) {
                        workingTextField(pantryText("Printed wording"), text: Binding(get: { wording }, set: { text in
                            wording = text; pendingMonthDay = nil; printedYear = ""
                            if selectedAI == nil { hasDay = false; confirmingCalendar = false }
                        }), axis: .vertical)
                        .focused($editing, equals: .wording)
                        .frame(minHeight: 44)
                        .accessibilityLabel(pantryText("Original printed wording"))
                        .accessibilityIdentifier("packageDate.wording")
                    }
                    .contentShape(Rectangle())
                    .simultaneousGesture(TapGesture().onEnded { editing = .wording })
                    if let value = proposal, value.selectedAI != nil, let day = value.day {
                        LabeledContent(value.meaningLabel, value: value.meaning.label)
                        LabeledContent(value.sourceLabel, value: dinnerDay(day))
                        Button(pantryText("Review a printed date instead")) { choosePrinted() }
                    } else {
                        printedControls
                    }
                    LabeledContent(pantryText("Label source"), value: proposal?.selectedAI != nil ? pantryText("Encoded package date") : (photoText == nil ? pantryText("Entered by hand") : pantryText("Selected label photo")))
                    if let photoText {
                        LabeledContent(pantryText("Selected text from your photo"), value: photoText)
                    }
                }
                if !reviewingSource {
                    Section { saveButton }
                }
                source
                if let gs1 {
                    Section(pantryText("Compare package dates")) {
                        if let lot = gs1.lot { LabeledContent(pantryText("Package lot number"), value: lot) }
                        if !wording.isEmpty {
                            LabeledContent(pantryText("Printed wording"), value: wording)
                            if let printedDay = PrintedPackageDate.proposedDay(in: wording, zone: zone) {
                                Button(pantryText("Choose printed date") + " · " + dinnerDay(printedDay)) {
                                    if let printed = printedDay.date {
                                        choosePrinted()
                                        date = printed; hasDay = true
                                    }
                                }
                            }
                        }
                        ForEach(gs1.dates, id: \.ai) { field in
                            if let day = field.day(zone: zone), let calendarDate = day.date {
                                let title = (field.ai == "15" ? PrintedDateMeaning.bestBefore : .expires).label
                                LabeledContent("GS1 (" + field.ai + ") · " + title, value: dinnerDay(day))
                                Button(pantryText("Choose encoded date") + " · " + title) {
                                    date = calendarDate; meaning = field.ai == "15" ? .bestBefore : .expires
                                    hasDay = true; selectedAI = field.ai
                                    pendingMonthDay = nil; printedYear = ""; confirmingCalendar = false
                                }
                            }
                        }
                    }
                }
                Section {
                    if reviewingSource { saveButton }
                    if previous != nil {
                        Button(pantryText("Remove saved label"), role: .destructive) { Task { await save(nil) } }
                            .disabled(saving || busy).accessibilityIdentifier("packageDate.remove")
                    }
                    Button(pantryText("Cancel")) { dismiss() }.disabled(saving)
                }
            } else {
                Text(pantryText("Reopen this pantry batch to review its current package label."))
            }
            if currentAccess, let status { Text(status).accessibilityIdentifier("packageDate.status") }
        }
        .privacySensitive()
        .navigationTitle(pantryText(proposal?.selectedAI == nil ? "Package date" : "Encoded package date"))
        .navigationBarTitleDisplayMode(.inline)
        .scrollDismissesKeyboard(.interactively)
        .keyboardDoneAction(visible: editing != nil, title: ledgerText("Done"), identifier: "packageDate.done") { editing = nil }
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
                case .failure: reportPhotoError(pantryText("Could not read this photo. Type the wording or choose another photo."))
                case nil: break
                }
            }.ignoresSafeArea()
        }
    }
    private func choosePrinted() {
        selectedAI = nil; pendingMonthDay = nil; printedYear = ""; confirmingCalendar = false
        meaning = .suggested(for: wording)
        let printed = PrintedPackageDate.proposedDay(in: wording, zone: zone)?.date
        hasDay = printed != nil
        if let printed { date = printed }
    }

    @ViewBuilder private var printedControls: some View {
        ForEach(PrintedPackageDate.monthDayChoices(in: wording), id: \.self) { choice in
            Button(choice.label(locale: locale)) {
                hasDay = false; selectedAI = nil; pendingMonthDay = choice; printedYear = ""; confirmingCalendar = false
            }
        }
        Picker(pantryText("Meaning printed on the package"), selection: $meaning) {
            ForEach(PrintedDateMeaning.allCases, id: \.self) { Text($0.label).tag($0) }
        }
        if let choice = pendingMonthDay {
            WorkingField(pantryText("Year printed on the package")) {
                TextField(pantryText("Four-digit year"), text: $printedYear)
                    .keyboardType(.numberPad)
                    .focused($editing, equals: .year)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("packageDate.year")
            }
            .contentShape(Rectangle())
            .simultaneousGesture(TapGesture().onEnded { editing = .year })
            if let full = choice.confirmed(year: printedYear, zone: zone), let chosen = full.date {
                Button(pantryText("Confirm printed date") + " · " + dinnerDay(full)) {
                    date = chosen; hasDay = true; pendingMonthDay = nil; printedYear = ""; editing = nil
                }.accessibilityIdentifier("packageDate.confirmYear")
            }
        } else {
            Toggle(pantryText("The full calendar date is clear"), isOn: Binding(
                get: { hasDay || confirmingCalendar },
                set: { enabled in hasDay = false; confirmingCalendar = enabled }
            )).accessibilityIdentifier("packageDate.hasDay")
            if hasDay || confirmingCalendar {
                DatePicker(pantryText("Printed calendar date"), selection: Binding(get: { date }, set: { chosen in
                    date = chosen; hasDay = false; confirmingCalendar = true
                }), displayedComponents: .date)
                    .environment(\.timeZone, TimeZone(identifier: zone) ?? .current)
                if confirmingCalendar, let full = try? MealDay(date: date, timeZoneIdentifier: zone) {
                    Button(pantryText("Confirm printed date") + " · " + dinnerDay(full)) {
                        hasDay = true; confirmingCalendar = false
                    }.accessibilityIdentifier("packageDate.confirmCalendar")
                }
            }
        }
    }

    private var saveButton: some View {
        Button(pantryText(proposal?.selectedAI != nil ? "Save encoded package date" : (pendingMonthDay != nil || confirmingCalendar ? "Save wording only" : "Save printed label"))) {
            Task { await save(proposal) }
        }
        .buttonStyle(PrimaryAction())
        .disabled(proposal == nil || saving || busy)
        .accessibilityIdentifier("packageDate.save")
    }

    private var source: some View {
        Section(pantryText("Label photo")) {
            if let photoStatus {
                Label(photoStatus, systemImage: "exclamationmark.circle")
                    .foregroundStyle(Theme.warning)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("packageDate.photoStatus")
            } else {
                Text(pantryText("Text recognition runs on this iPhone. Only the wording you select is saved."))
            }
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
                guard authorized, !requestingCamera else { return }
                requestingCamera = true
                Task {
                    defer { requestingCamera = false }
                    do {
                        try await CameraCapturePermission.request(presenting: permissionPrompt?.presenter(for: access.scope.origin))
                        if authorized { camera = true }
                    } catch { reportPhotoError(pantryText("Camera unavailable. Choose a photo or type the printed wording.")) }
                }
            }.disabled(requestingCamera)
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
                        reportPhotoError(pantryText("Choose fewer lines or type the printed wording.")); return
                    }
                    selectedAI = nil; pendingMonthDay = nil; printedYear = ""; confirmingCalendar = false
                    wording = draft.wording
                    photoText = draft.selectedPhotoText
                    photoDigest = draft.photoDigest
                    meaning = draft.meaning
                    hasDay = draft.day != nil
                    if let value = draft.day?.date { date = value }
                    clearPhoto(); status = nil; photoStatus = nil
                }.disabled(selected.isEmpty)
            }
        }
    }
    private func load() {
        guard currentAccess else { return }
        reviewedLot = lot; reviewedScope = access.scope
        do {
            let value = try store.load(access.scope, lot: lot.id)
            previous = value; selectedAI = value?.selectedAI
            if let value {
                wording = value.originalPrintedWording ?? ""; meaning = value.meaning
            } else {
                wording = reviewedDateWording ?? ""
                meaning = PrintedDateMeaning.suggested(for: wording)
            }
            hasDay = value?.verifiedDay != nil
            confirmingCalendar = value?.yearNeedsReview == true
            date = value?.day?.date ?? Date()
            zone = value?.day?.timeZoneIdentifier ?? TimeZone.current.identifier
            photoText = value?.selectedPhotoText; photoDigest = value?.photoDigest; loaded = true
        } catch { status = pantryText("The saved label could not be opened.") }
    }
    private func clearPhoto() { rows = []; uncertain = []; selected = []; preview = nil; readingDigest = nil }
    private func reportPhotoError(_ message: String) {
        guard authorized else { return }
        status = nil
        photoStatus = message
        UIAccessibility.post(notification: .announcement, argument: message)
    }
    private func cancelRead() { operation = UUID(); work?.cancel(); work = nil; busy = false }
    private func read(_ bytes: @escaping () async throws -> Data) {
        cancelRead()
        guard authorized else { return }
        let token = operation
        busy = true; clearPhoto(); status = nil; photoStatus = nil
        work = Task {
            defer { if operation == token { busy = false } }
            do {
                let data = try await bytes()
                guard !Task.isCancelled, operation == token, authorized else { return }
                let recognized = try await OnDeviceScanService().scan(data)
                guard !Task.isCancelled, operation == token, authorized else { return }
                let observed = recognized.barcodes.filter { $0.canonicalGTIN != nil }
                if !observed.isEmpty {
                    let physical = physicalSources
                    let foreign = observed.contains { code in
                        physical.contains { source in
                            source.canonicalGTIN != code.canonicalGTIN ||
                                (source.gs1?.lot != nil && code.gs1?.lot != nil && source.gs1?.lot != code.gs1?.lot)
                        }
                    }
                    let encoded = observed.filter { $0.gs1 != nil }
                    if foreign || encoded.count > 1 || encoded.first.map({ !PackageDateBinding.accepts($0, for: physical) }) == true {
                        photographedCode = nil; rejectedPhoto = true
                        if selectedAI != nil { choosePrinted() }
                        reportPhotoError(pantryText("The barcode belongs to a different pack. Check this batch."))
                        return
                    } else if let code = encoded.first {
                        if selectedAI != nil { choosePrinted() }
                        rejectedPhoto = false; photographedCode = code
                    }
                }
                rows = recognized.originalText.components(separatedBy: .newlines).filter { !$0.isEmpty }
                uncertain = Set(recognized.uncertainLines)
                preview = UIImage(data: recognized.referenceJPEG)
                readingDigest = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            } catch {
                if !Task.isCancelled && operation == token && authorized {
                    reportPhotoError(pantryText("Could not read this photo. Type the wording or choose another photo."))
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
