import SwiftUI

/// Host supplies a live private target and authorization. Merely decoding a reference cannot open this shelf.
@MainActor struct CaptureReferenceShelf: View {
    let target: CaptureTarget
    let initialLabel: String
    let authorize: @MainActor @Sendable () -> Bool
    @State private var entries: [SourceMediaRecord] = []
    @State private var mode: Mode?
    @State private var pending: SourceMediaRecord?
    @State private var removing: SourceMediaRecord?
    @State private var saving = false
    @State private var failed = false
    @State private var generation = UUID()
    private struct Mode: Identifiable { let kind: ScanKind; var id: String { kind.rawValue } }

    var body: some View {
        Form {
            Section {
                Text(captureText("References are private source evidence. They do not change quantities, prices, payments or arrivals."))
                Text(captureText("Saved references stay on this device until removed or their saved pickup or grocery workspace is deleted. You can choose references separately for an encrypted recovery file in Records."))
                Button(captureText("Add a source photo or typed reference")) {
                    mode = Mode(kind: target.kind == .receiptEvidence ? .receipt : .packageReference)
                }.disabled(!authorize() || saving || pending != nil)
                if target.kind == .packageReference {
                    Button(captureText("Scan a code and match it manually")) { mode = Mode(kind: .barcode) }
                        .disabled(!authorize() || saving || pending != nil)
                }
            }
            if let pending {
                Section {
                    Text(captureText("This reference still needs a save check. Retry, or remove this draft and any saved copy."))
                    Button(captureText("Retry saving reference")) { save(pending) }.disabled(!authorize() || saving)
                    Button(captureText("Discard reference draft"), role: .destructive) {
                        Task { @MainActor in
                            do { try await CaptureMediaStore.shared.remove(pending.reference, target: target, authorize: authorize); self.pending = nil; failed = false; await reload() }
                            catch { failed = true }
                        }
                    }.disabled(saving || !authorize())
                }
            }
            ForEach(entries) { entry in
                Section {
                    Text(entry.reviewedLabel).font(.headline)
                    Text(entry.capturedAt, style: .date)
                    Text(captureText("Source revision") + ": " + String(entry.target.revision)).font(.footnote)
                    if let data = entry.imageJPEG, let image = UIImage(data: data) {
                        Image(uiImage: image).resizable().scaledToFit().frame(maxHeight: 260)
                            .accessibilityLabel(captureText("Saved reduced-size source reference"))
                    }
                    SourceReferenceWording(source: entry)
                    if let barcode = entry.barcode {
                        Text(captureText("Manually matched code") + ": " + barcode.value).textSelection(.enabled)
                    }
                    ForEach(entry.receiptLines) { row in
                        VStack(alignment: .leading) {
                            Text(row.originalText).font(.footnote)
                            Text(row.reviewedText)
                            if !row.quantityNote.isEmpty { Text(row.quantityNote) }
                            if !row.priceNote.isEmpty { Text(row.priceNote) }
                        }
                    }
                    Button(captureText("Remove this source reference"), role: .destructive) { removing = entry }
                        .disabled(!authorize() || saving)
                }
            }
            if failed { Section { Text(captureText("The reference could not be saved or opened. Typed planning still works. Remove an older reference if this workspace already has twelve.")) } }
        }
        .navigationTitle(captureText("Source references"))
        .sheet(item: $mode) { mode in
            NavigationStack {
                ScanReviewView(kind: mode.kind, target: target, initialLabel: initialLabel, authorize: authorize) { reviewed in
                    guard case .evidence(let record) = reviewed else { return }
                    save(record)
                }
            }
        }
        .confirmationDialog(captureText("Remove the saved image and source wording from this device?"), isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } })) {
            Button(captureText("Remove source reference"), role: .destructive) {
                guard let record = removing else { return }; removing = nil
                Task { @MainActor in
                    do { try await CaptureMediaStore.shared.remove(record.reference, target: target, authorize: authorize); await reload() }
                    catch { failed = true }
                }
            }
        }
        .task(id: target) { generation = UUID(); entries = []; pending = nil; await reload() }
        .task {
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                if !authorize() { generation = UUID(); mode = nil; entries = []; pending = nil; return }
            }
        }
        .onDisappear { generation = UUID(); entries = []; if !saving { pending = nil } }
    }
    private func save(_ record: SourceMediaRecord) {
        guard !saving, authorize(), record.target == target else { failed = true; return }
        pending = record; saving = true; let attempt = generation
        Task { @MainActor in
            defer { saving = false }
            do {
                _ = try await CaptureMediaStore.shared.save(record, authorize: authorize)
                guard attempt == generation, authorize() else { return }
                pending = nil; failed = false; await reload()
            } catch { if attempt == generation, authorize() { failed = true } }
        }
    }
    private func reload() async {
        let attempt = generation
        do {
            let values = try await CaptureMediaStore.shared.list(target: target, authorize: authorize)
            guard attempt == generation, authorize() else { return }; entries = values; failed = false
        } catch { if attempt == generation, authorize() { entries = []; failed = true } }
    }
}

struct SourceReferenceWording: View {
    let source: SourceMediaRecord
    var originalIdentifier: String? = nil

    var body: some View {
        if let reviewed = source.reviewedText {
            Text(captureText("Reviewed wording")).font(.headline)
            Text(reviewed.isEmpty ? recordsText("Not entered") : reviewed).textSelection(.enabled)
            Text(ledgerText("Original wording")).font(.headline)
        }
        let original = Text(source.originalText).textSelection(.enabled)
        if let originalIdentifier {
            original.accessibilityIdentifier(originalIdentifier)
        } else {
            original
        }
    }
}
