#if DEBUG && CONTRIBUTOR_CAPTURE_UI_FIXTURE
import SwiftUI
import UIKit
import CoreDomain
import RecordArchive

/// Replaces only the operating-system file destination/selection in this dedicated
/// test build. Preparation, encryption, scoped validation, review and apply remain
/// the production RecordsToolsView/Model/Composition path.
struct RecordsMediaUITestFileAdapter {
    let save: @MainActor (RecordsFileDocument) throws -> Void
    let selectedURL: @MainActor () -> URL?
}
private struct RecordsMediaUITestFilesKey: EnvironmentKey {
    static let defaultValue: RecordsMediaUITestFileAdapter? = nil
}
extension EnvironmentValues {
    var recordsMediaUITestFiles: RecordsMediaUITestFileAdapter? {
        get { self[RecordsMediaUITestFilesKey.self] }
        set { self[RecordsMediaUITestFilesKey.self] = newValue }
    }
}

@MainActor private final class RecordsMediaUIFixtureState: ObservableObject {
    static let photoID = UUID(uuidString: "77777777-7777-4777-8777-777777777777")!
    static let originalWording = "F07 package wording: 8 wraps per pack. Review only."
    let app: AppModel
    let ledger: LedgerModel
    let pickup: PickupModel
    let household: HouseholdModel
    let access: WorkspaceAccess
    @Published private(set) var ready = false
    @Published private(set) var failure = false
    @Published private(set) var recoveredCount = 0
    @Published private(set) var sourceUnchanged = false
    @Published private(set) var savedFiles = 0
    @Published private(set) var savedFileHidesSource = false
    private let recordsDirectory: URL
    private let savedFile: URL
    private var registry: RecoveryRegistry?
    private var originalPayload: Data?

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        let isolated = support.appendingPathComponent("UITestWorkspace", isDirectory: true)
        let directory = isolated.appendingPathComponent("RecordsMediaFixture", isDirectory: true)
        recordsDirectory = isolated.appendingPathComponent("Records", isDirectory: true)
        savedFile = directory.appendingPathComponent("selected-personal-recovery.roomrecovery")
        let arguments = ProcessInfo.processInfo.arguments
        let defaults = UserDefaults(suiteName: "dev.roominthecart.records-media-ui-fixture")!
        if arguments.contains("--ui-testing"), arguments.contains("--records-media-fixture"), arguments.contains("--reset-records-media-fixture") {
            try? FileManager.default.removeItem(at: directory)
            try? FileManager.default.removeItem(at: recordsDirectory)
            try? FileManager.default.removeItem(at: isolated.appendingPathComponent("CaptureMedia", isDirectory: true))
            defaults.removePersistentDomain(forName: "dev.roominthecart.records-media-ui-fixture")
        }
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
            attributes: [.protectionKey: FileProtectionType.complete])
        app = AppModel(databaseURL: directory.appendingPathComponent("comparisons.sqlite"))
        ledger = LedgerModel(databaseURL: directory.appendingPathComponent("ledger.sqlite"))
        pickup = PickupModel(databaseURL: directory.appendingPathComponent("pickup.sqlite"))
        household = HouseholdModel(outboxURL: directory.appendingPathComponent("unused-local-outbox.json"))
        access = WorkspaceAccess(defaults: defaults)
    }
    var fileAdapter: RecordsMediaUITestFileAdapter {
        RecordsMediaUITestFileAdapter(save: { [weak self] document in
            guard let self, document.kind == .recovery,
                  let container = try JSONSerialization.jsonObject(with: document.data) as? [String: Any],
                  container["algorithm"] as? String == "AES-256-GCM" else { throw ArchiveError.integrity }
            try document.data.write(to: self.savedFile, options: [.atomic, .completeFileProtection])
            self.savedFiles += 1
            self.savedFileHidesSource = !String(decoding: document.data, as: UTF8.self).contains(Self.originalWording)
        }, selectedURL: { [weak self] in
            guard let self, FileManager.default.fileExists(atPath: self.savedFile.path) else { return nil }
            return self.savedFile
        })
    }
    func start() async {
        guard !ready, !failure, ProcessInfo.processInfo.arguments.contains("--ui-testing"),
              ProcessInfo.processInfo.arguments.contains("--records-media-fixture") else { return }
        do {
            await app.open(); await ledger.open(); await pickup.load()
            guard app.ready, ledger.ready, pickup.ready, access.unlocked else { throw ArchiveError.unavailable }
            if ledger.workspace.shops.isEmpty {
                var shop = ShoppingLedger(title: "F07 source pickup")
                let lineID = try shop.addManualLine(name: "F07 wraps", quantity: Quantity(amount: Rational(2), unit: .count, originalLiteral: "2 packs"))
                guard await ledger.change(key: "records-media-ui-source", { $0 = LedgerWorkspace(shops: [shop], selectedShopID: shop.id) }),
                      let workspaceID = ledger.sourceWorkspaceID else { throw ArchiveError.unavailable }
                let source = SourceMediaRecord(id: Self.photoID,
                    target: CaptureTarget(workspaceID: workspaceID, containerID: shop.id, objectID: lineID, revision: Int64(shop.revision), kind: .packageReference),
                    originalText: Self.originalWording, reviewedLabel: "F07 wraps package photo", imageJPEG: try referenceJPEG(),
                    barcode: nil, receiptLines: [], capturedAt: Date())
                guard let identity = CapturePrivateIdentity.current(access: access, household: household) else { throw ArchiveError.unavailable }
                _ = try await CaptureMediaStore.shared.save(source, authorize: { [weak self] in
                    guard let self else { return false }
                    return identity == CapturePrivateIdentity.current(access: self.access, household: self.household) &&
                        self.ledger.sourceWorkspaceID == workspaceID && self.ledger.workspace.shops.contains { $0.id == source.target.containerID }
                })
                try FileManager.default.createDirectory(at: recordsDirectory, withIntermediateDirectories: true,
                    attributes: [.protectionKey: FileProtectionType.complete])
                let registry = try RecoveryRegistry(url: recordsDirectory.appendingPathComponent("recovery-v1.json"))
                let originalScope = try RecordsNativeCodec.ledgerScope(ledger.workspace, shop: shop)
                let oldBytes = try RecordsNativeCodec.canonical(FixtureLedgerDocument(workspace: originalScope))
                var newerShop = shop
                newerShop.title = "F07 newer recovered work"
                try newerShop.updateLine(lineID: lineID, name: "F07 wraps", notes: "Newer independent planning remains", aisle: "", at: Date())
                let newerScope = try RecordsNativeCodec.ledgerScope(LedgerWorkspace(shops: [newerShop], selectedShopID: newerShop.id), shop: newerShop)
                let bytes = try RecordsNativeCodec.canonical(FixtureLedgerDocument(workspace: newerScope))
                let record = ArchiveRecord(id: shop.id.uuidString, origin: "ledger/" + workspaceID.uuidString,
                    revision: ArchiveCodec.digest(bytes), parentRevision: ArchiveCodec.digest(oldBytes), kind: .ledger,
                    title: newerShop.title, savedAtMilliseconds: ArchiveCodec.milliseconds(Date()), nativePayload: bytes)
                try RecordsNativeCodec.validate(record)
                let initial = try ArchiveCodec.make(records: [record], kind: .personalRecovery, origin: record.origin, revision: record.revision)
                _ = try await registry.apply(registry.review(initial))
            }
            registry = try RecoveryRegistry(url: recordsDirectory.appendingPathComponent("recovery-v1.json"))
            originalPayload = try RecordsNativeCodec.canonical(RecordsNativeCodec.ledger(ledger.exportPayload()))
            try await refreshEvidence()
            ready = true
        } catch { failure = true }
    }
    func refreshEvidence() async throws {
        guard let registry else { throw ArchiveError.unavailable }
        let count = try await registry.refreshList().count
        let unchanged = try RecordsNativeCodec.canonical(RecordsNativeCodec.ledger(ledger.exportPayload())) == originalPayload
        if recoveredCount != count { recoveredCount = count }
        if sourceUnchanged != unchanged { sourceUnchanged = unchanged }
    }
    private struct FixtureLedgerDocument: Encodable { let formatVersion = 1; let workspace: LedgerWorkspace }
    private func referenceJPEG() throws -> Data {
        let image = UIGraphicsImageRenderer(size: CGSize(width: 420, height: 240)).image { context in
            UIColor(red: 0.97, green: 0.96, blue: 0.93, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 0, width: 420, height: 240))
            UIColor(red: 0.1, green: 0.35, blue: 0.28, alpha: 1).setFill()
            context.fill(CGRect(x: 24, y: 24, width: 372, height: 192))
            let words = "F07 WRAPS\n8 wraps per pack\nSource reference"
            (words as NSString).draw(in: CGRect(x: 44, y: 48, width: 336, height: 150), withAttributes: [
                .font: UIFont.systemFont(ofSize: 29, weight: .semibold), .foregroundColor: UIColor.white
            ])
        }
        guard let bytes = image.jpegData(compressionQuality: 0.85) else { throw ArchiveError.integrity }
        return try ScanImageNormalizer.normalize(bytes)
    }
}

struct RecordsMediaUIFixtureRoot: View {
    @StateObject private var fixture = RecordsMediaUIFixtureState()
    var body: some View {
        VStack(spacing: 2) {
            HStack {
                Text("F07 recovered copies: \(fixture.recoveredCount)").accessibilityIdentifier("fixture.records.recoveredCount")
                Text("F07 source unchanged: \(fixture.sourceUnchanged ? "yes" : "no")").accessibilityIdentifier("fixture.records.sourceUnchanged")
            }.font(.caption2)
            HStack {
                Text("F07 encrypted files: \(fixture.savedFiles)").accessibilityIdentifier("fixture.records.savedFiles")
                Text("F07 file hides source: \(fixture.savedFileHidesSource ? "yes" : "no")").accessibilityIdentifier("fixture.records.fileHidesSource")
            }.font(.caption2)
            if fixture.ready {
                NavigationStack {
                    RecordsToolsEntryView(app: fixture.app, ledger: fixture.ledger, pickup: fixture.pickup,
                        erasureCleanup: RecordsErasureCleanup(eraseLedgerWorkspace: { try await CaptureMediaStore.shared.eraseWorkspace($0) },
                            erasePickupRecord: { try await CaptureMediaStore.shared.erasePickupRecord(workspaceID: $0, recordID: $1) }))
                }
                .environmentObject(fixture.app).environmentObject(fixture.ledger).environmentObject(fixture.pickup)
                .environmentObject(fixture.household).environmentObject(fixture.access)
                .environment(\.recordsMediaUITestFiles, fixture.fileAdapter)
                .tint(Theme.action)
            } else if fixture.failure { Text("F07 fixture failed").accessibilityIdentifier("fixture.records.failure") }
            else { ProgressView("Opening isolated F07 fixture") }
        }
        .task {
            await fixture.start()
            while !Task.isCancelled, fixture.ready {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
                do { try await fixture.refreshEvidence() } catch { return }
            }
        }
    }
}
#endif
