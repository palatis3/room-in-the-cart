#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import CoreDomain
import LocalStore
import SQLite3
import CryptoKit

private enum ImportRecoveryFixtureError: Error { case invalid(String) }

/// Only a synthetic fixture connection owns this lease. It never writes payloads.
private final class ImportRecoveryWriterLease {
    private var handle: OpaquePointer?

    init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ImportRecoveryFixtureError.invalid("Missing fixture database")
        }
        var opened: OpaquePointer?
        let result = sqlite3_open_v2(url.path, &opened, SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX, nil)
        guard result == SQLITE_OK, let opened else {
            sqlite3_close_v2(opened)
            throw ImportRecoveryFixtureError.invalid("Cannot open fixture writer")
        }
        handle = opened
        sqlite3_busy_timeout(opened, 1_000)
        guard sqlite3_exec(opened, "BEGIN IMMEDIATE", nil, nil, nil) == SQLITE_OK,
              sqlite3_get_autocommit(opened) == 0 else {
            try? release()
            throw ImportRecoveryFixtureError.invalid("Cannot acquire fixture writer")
        }
    }

    func release() throws {
        guard let opened = handle else { return }
        handle = nil
        defer { sqlite3_close_v2(opened) }
        let changes = sqlite3_total_changes(opened)
        let rollback = sqlite3_exec(opened, "ROLLBACK", nil, nil, nil)
        guard changes == 0, rollback == SQLITE_OK, sqlite3_get_autocommit(opened) != 0 else {
            throw ImportRecoveryFixtureError.invalid("Fixture writer cleanup failed")
        }
    }

    deinit { try? release() }
}

private struct ImportRecoveryAudit: Encodable {
    let sequence: Int
    let revision: Int64
    let payloadSHA256: String
    let matchesBaseline: Bool
    let pending: Bool
    let saving: Bool
    let batchCount: Int
    let lineIDs: [String]
    let contributionIDs: [String]
    let names: [String]
    let quantities: [String]
    let batchIDs: [String]
    let previewIDs: [String]
    let batchContributionIDs: [String]
    let proposedLineIDs: [String]
    let stagedContributionIDs: [String]
    let originalTexts: [String]
}

@MainActor private final class ImportRecoveryUIFixtureState: ObservableObject {
    let ledger: LedgerModel
    let access: WorkspaceAccess
    let household: HouseholdModel
    private let databaseURL: URL
    private var auditor: LedgerStore?
    private var baseline: LedgerRecord?
    private var lease: ImportRecoveryWriterLease?
    private var deadline: Task<Void, Never>?
    private var auditing = false
    @Published private(set) var phase = "opening"
    @Published private(set) var failure = "none"
    @Published private(set) var auditJSON = "{}"
    @Published private(set) var dismissals = 0
    @Published var presenting = false

    init() {
        let raw = ProcessInfo.processInfo.environment["RITC_IMPORT_RECOVERY_FIXTURE_ID"]
        let suppliedID = raw.flatMap(UUID.init(uuidString:))
        let id = (suppliedID ?? UUID()).uuidString
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("UITestWorkspace", isDirectory: true)
            .appendingPathComponent("ImportRecovery-" + id, isDirectory: true)
        databaseURL = directory.appendingPathComponent("ledger.sqlite")
        ledger = LedgerModel(databaseURL: databaseURL)
        access = WorkspaceAccess(defaults: UserDefaults(suiteName: "dev.roominthecart.fixture.import-recovery." + id)!)
        household = HouseholdModel(outboxURL: directory.appendingPathComponent("unused-household.json"))
        do {
            guard suppliedID != nil, ProcessInfo.processInfo.arguments.contains("--ui-testing"),
                  ProcessInfo.processInfo.arguments.contains("--import-recovery-fixture") else {
                throw ImportRecoveryFixtureError.invalid("Missing explicit fixture scope")
            }
            guard !FileManager.default.fileExists(atPath: directory.path) else {
                throw ImportRecoveryFixtureError.invalid("Fixture UUID was reused")
            }
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        } catch { fail(error) }
    }

    func open() async {
        guard phase == "opening", failure == "none" else { return }
        phase = "preparing"
        await ledger.open()
        guard ledger.ready, await ledger.startShop(title: "Recovery fixture") else {
            fail(ImportRecoveryFixtureError.invalid("Cannot prepare synthetic shop")); return
        }
        do {
            let store = try LedgerStore(url: databaseURL)
            auditor = store
            guard let record = try await store.load() else {
                throw ImportRecoveryFixtureError.invalid("Missing baseline")
            }
            baseline = record
            let workspace = try LedgerModel.validatePayload(record.payload)
            guard workspace.shops.count == 1, let shop = workspace.shops.first,
                  shop.lines.isEmpty, shop.contributions.isEmpty, shop.importBatches.isEmpty else {
                throw ImportRecoveryFixtureError.invalid("Baseline is not empty")
            }
            try publish(record, sequence: 0)
            phase = "ready"
        } catch { fail(error) }
    }

    func openImport() {
        guard phase == "ready", failure == "none", !presenting else { return }
        presenting = true
    }

    func armWriter() {
        guard phase == "ready", presenting, !ledger.saving, !ledger.hasPendingSave,
              failure == "none", lease == nil else { return }
        do {
            lease = try ImportRecoveryWriterLease(url: databaseURL)
            phase = "held"
            deadline = Task { [weak self] in
                do { try await Task.sleep(nanoseconds: 90_000_000_000) }
                catch { return }
                guard let self, self.lease != nil else { return }
                self.abortHeldWriter("Writer lease exceeded 90 seconds")
            }
        } catch { fail(error) }
    }

    var canRelease: Bool {
        phase == "held" && lease != nil && ledger.hasPendingSave && ledger.error != nil && !ledger.saving
    }

    func releaseWriter() async {
        guard canRelease, let auditor, let baseline else { return }
        do {
            let retained = try await auditor.load()
            guard canRelease, failure == "none", retained == baseline else {
                throw ImportRecoveryFixtureError.invalid("Failed save changed baseline or lease expired")
            }
            try lease?.release()
            lease = nil
            deadline?.cancel(); deadline = nil
            phase = "released"
        } catch { abortHeldWriter(String(describing: error)) }
    }

    /// Observe the real pending-state transition in the root, even if the sheet closes.
    func auditRecovery() async {
        guard phase == "released", !auditing, !ledger.hasPendingSave, let auditor else { return }
        auditing = true
        do {
            guard let record = try await auditor.load() else {
                throw ImportRecoveryFixtureError.invalid("Missing recovery readback")
            }
            try publish(record, sequence: 1)
            phase = "audited"
        } catch { fail(error) }
    }

    func sheetDismissed() { dismissals += 1 }

    func backgrounded() {
        if lease != nil { abortHeldWriter("Fixture backgrounded with a held writer") }
    }

    private func publish(_ record: LedgerRecord, sequence: Int) throws {
        let workspace = try LedgerModel.validatePayload(record.payload)
        guard workspace.shops.count == 1, let shop = workspace.shops.first else {
            throw ImportRecoveryFixtureError.invalid("Unexpected audit workspace")
        }
        let names = Dictionary(uniqueKeysWithValues: shop.lines.map { ($0.id, $0.name) })
        let amounts = shop.contributions.map { contribution -> String in
            let name = names[contribution.lineID] ?? "missing line"
            guard let quantity = contribution.quantity else { return name + "=unknown" }
            return "\(name)=\(quantity.amount.numerator)/\(quantity.amount.denominator) \(quantity.unit.rawValue)"
        }
        let value = ImportRecoveryAudit(sequence: sequence, revision: record.revision,
            payloadSHA256: SHA256.hash(data: record.payload).map { String(format: "%02x", $0) }.joined(),
            matchesBaseline: record == baseline, pending: ledger.hasPendingSave, saving: ledger.saving,
            batchCount: shop.importBatches.count,
            lineIDs: shop.lines.map { $0.id.uuidString }.sorted(),
            contributionIDs: shop.contributions.map { $0.id.uuidString }.sorted(),
            names: shop.lines.map(\.name).sorted(), quantities: amounts.sorted(),
            batchIDs: shop.importBatches.map { $0.id.uuidString }.sorted(),
            previewIDs: shop.importBatches.map { $0.preview.id.uuidString }.sorted(),
            batchContributionIDs: shop.importBatches.flatMap { $0.contributionIDs.map(\.uuidString) }.sorted(),
            proposedLineIDs: shop.importBatches.flatMap { $0.preview.lines.map { $0.proposedLineID.uuidString } }.sorted(),
            stagedContributionIDs: shop.importBatches.flatMap { $0.preview.lines.map { $0.id.uuidString } }.sorted(),
            originalTexts: shop.importBatches.map(\.originalText).sorted())
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        auditJSON = String(decoding: try encoder.encode(value), as: UTF8.self)
    }

    private func abortHeldWriter(_ message: String) {
        deadline?.cancel(); deadline = nil
        do { try lease?.release() }
        catch { fail(error); lease = nil; return }
        lease = nil
        fail(ImportRecoveryFixtureError.invalid(message))
    }

    private func fail(_ error: Error) { failure = String(describing: error); phase = "failed" }
}

struct ImportRecoveryUIFixtureRoot: View {
    @StateObject private var state = ImportRecoveryUIFixtureState()
    @Environment(\.scenePhase) private var scenePhase
    var body: some View {
        ImportRecoveryUIFixtureContent(state: state, ledger: state.ledger)
            .task { await state.open() }
            .onChange(of: scenePhase) { _, phase in if phase == .background { state.backgrounded() } }
    }
}

private struct ImportRecoveryUIFixtureContent: View {
    @ObservedObject var state: ImportRecoveryUIFixtureState
    @ObservedObject var ledger: LedgerModel
    var body: some View {
        VStack {
            diagnostics("root")
            Button("Open import review") { state.openImport() }
                .accessibilityIdentifier("fixture.importRecovery.open")
                .disabled(state.phase != "ready")
        }
        .sheet(isPresented: $state.presenting, onDismiss: state.sheetDismissed) {
            VStack(spacing: 0) {
                diagnostics("sheet")
                NavigationStack {
                    if let shop = ledger.shop {
                        LedgerImportView(model: ledger, shopID: shop.id)
                            .toolbar {
                                ToolbarItem(placement: .topBarTrailing) {
                                    Button(state.phase == "ready" ? "Arm test writer" : "Release test writer") {
                                        if state.phase == "ready" { state.armWriter() }
                                        else { Task { await state.releaseWriter() } }
                                    }
                                    .accessibilityIdentifier("fixture.importRecovery.writer")
                                    .disabled(state.phase == "ready" ? ledger.saving || ledger.hasPendingSave : !state.canRelease)
                                }
                            }
                    }
                }
                .environmentObject(state.access).environmentObject(state.household)
                .tint(Theme.action)
            }
        }
        .onChange(of: ledger.hasPendingSave) { wasPending, pending in
            if wasPending && !pending { Task { await state.auditRecovery() } }
        }
        // Never set a container buttonStyle here: it would mask the production regression.
    }

    private func diagnostics(_ location: String) -> some View {
        VStack(spacing: 0) {
            Text(state.phase).accessibilityIdentifier("fixture.importRecovery.\(location).phase")
            Text(state.failure).accessibilityIdentifier("fixture.importRecovery.\(location).failure")
            Text(String(state.dismissals)).accessibilityIdentifier("fixture.importRecovery.\(location).dismissals")
            Text(state.auditJSON).accessibilityIdentifier("fixture.importRecovery.\(location).audit")
        }
        .font(.system(size: 10, design: .monospaced)).dynamicTypeSize(.medium).lineLimit(1)
    }
}
#endif
