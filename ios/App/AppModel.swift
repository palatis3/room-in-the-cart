import Foundation
import LocalStore
import CoreDomain

@MainActor final class AppModel: ObservableObject {
    @Published var records: [SavedComparison] = []
    @Published var unavailableRecords: [UnavailableComparison] = []
    @Published var error: String?
    @Published var ready = false
    @Published private(set) var hasLoadedRecords = false
    private(set) var store: ComparisonStore?
    private let databaseURL: URL

    init(databaseURL: URL? = nil) {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        var folder = base.appendingPathComponent("RoomInTheCart", isDirectory: true)
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("--ui-testing") {
            folder = base.appendingPathComponent("UITestWorkspace", isDirectory: true)
        }
        #endif
        self.databaseURL = databaseURL ?? folder.appendingPathComponent("local.sqlite")
    }

    func open() async {
        guard !ready else { return }
        do {
            let directory = databaseURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                attributes: [.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication])
            #if DEBUG
            if ProcessInfo.processInfo.arguments.contains("--reset-test-workspace"), directory.lastPathComponent == "UITestWorkspace" {
                UserDefaults.standard.removeObject(forKey: PickupFeedbackSection.consentKey)
                LocalPickupFeedbackConsent.shared.resetForUITest()
                for suffix in ["", "-wal", "-shm"] {
                    let file = URL(fileURLWithPath: databaseURL.path + suffix)
                    if FileManager.default.fileExists(atPath: file.path) { try FileManager.default.removeItem(at: file) }
                }
            }
            #endif
            store = try ComparisonStore(url: databaseURL)
            ready = true
            await refresh()
        } catch { Diagnostics.record(.localStoreUnavailable); self.error = tr("Could not open saved comparisons. Your records have not been removed. Try again.") }
    }

    func refresh() async {
        guard let store else { return }
        do {
            let listing = try await store.listing()
            records = listing.records
            unavailableRecords = listing.unavailable
            error = nil
            hasLoadedRecords = true
        }
        catch { Diagnostics.record(.localReadFailed); self.error = tr("Could not open saved comparisons. Your records have not been removed. Try again.") }
    }

    func decode(_ record: SavedComparison) throws -> ComparisonDraft {
        let payload = try JSONDecoder().decode(SavedPayload.self, from: record.payload)
        guard payload.formatVersion == 1, payload.draft.id == record.id else { throw EntryError.unsupportedVersion }
        let request = try ComparisonModel(draft: payload.draft).request()
        let computed = try PackComparison.evaluate(request)
        if let version = payload.calculationVersion {
            guard version == SavedPayload.currentCalculationVersion,
                  payload.roundingPolicy == SavedPayload.currentRoundingPolicy,
                  payload.normalizedRequest == request, payload.answer == computed else {
                throw EntryError.unsupportedVersion
            }
        } else if payload.normalizedRequest != nil || payload.answer != nil || payload.roundingPolicy != nil {
            throw EntryError.unsupportedVersion
        }
        return payload.draft
    }
}
