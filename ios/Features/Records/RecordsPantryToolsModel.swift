import Combine
import Foundation
import RecordArchive

/// Private pantry Records actions. Files callbacks retain the original operation,
/// key and authorization; none of these ephemeral admissions is restored from disk.
@MainActor final class RecordsPantryToolsModel: ObservableObject {
    typealias Authorization = RecordsToolsModel.Authorization
    typealias CaptureLive = (@escaping Authorization) async throws -> PantryArchiveHandle
    typealias Validate = (PantryArchiveHandle, @escaping Authorization) async throws -> Void
    typealias Open = (RecoveredPantryCopy, @escaping Authorization) async throws -> Void
    typealias CaptureIndependent = (RecoveredPantryCopy, @escaping Authorization) async throws -> PantryArchiveHandle

    struct PickerPresentation: Identifiable {
        let id: UUID
        let mode: RecordsPantryFilePicker.Mode
    }
    struct ImportReview {
        let handle: PantryArchiveHandle
        let registry: PantryRecoveryReview
    }
    enum Status { case imported, opened, exported, deleted, cancelled }
    enum Failure: Error { case unavailable, invalidKey, failed, stale }
    @Published private(set) var copies: [RecoveredPantryCopy] = []
    @Published private(set) var importReview: ImportReview?
    @Published private(set) var deletionReview: PantryDeletionReview?
    @Published private(set) var picker: PickerPresentation?
    @Published private(set) var busy = false
    @Published private(set) var cleaning = false
    @Published private(set) var status: Status?
    @Published private(set) var error: Failure?
    @Published var recoveryKey = "" {
        didSet { if recoveryKey != oldValue && !redacting {
            if picker != nil || importReview != nil || deletionReview != nil || workCount > 0 { cancelAction() }
            else { error = nil; status = nil }
        } }
    }

    private struct Admission {
        let id: UUID
        let authorize: Authorization
    }
    private struct Export {
        let package: PantryEncryptedPackage
        let intent: PantryBackupIntent
    }
    private let worker: PantryArchiveWorker
    private let registry: RecoveryRegistry
    private let captureLive: CaptureLive
    private let validateLocalDependencies: Validate
    private let openRecovered: Open
    private let captureIndependent: CaptureIndependent
    private let beginAuthorization: () -> Authorization?
    private let willRemove: (Set<UUID>) async throws -> Void
    private let discardCapture: (PantryArchiveHandle) async throws -> Void
    private let cleanup: () async throws -> Void
    private let clock: () -> Date
    private var admission: Admission?
    private var exports: [UUID: Export] = [:]
    private var captures: [UUID: PantryArchiveHandle] = [:]
    private var stagedImport: PantryPreparedImport?
    private var exportIDs: Set<UUID> { Set(exports.keys).union(captures.keys) }
    private var presentedPickers: Set<UUID> = []
    private var acceptedPickers: Set<UUID> = []
    @Published private var workCount = 0
    private var cleanupTask: Task<Void, Never>?
    private var cleanupNeeded = false
    private var redacting = false

    init(worker: PantryArchiveWorker, registry: RecoveryRegistry,
         captureLive: @escaping CaptureLive, validateLocalDependencies: @escaping Validate,
         openRecovered: @escaping Open, captureIndependent: @escaping CaptureIndependent,
         beginAuthorization: @escaping () -> Authorization?,
         willRemove: @escaping (Set<UUID>) async throws -> Void,
         discardCapture: @escaping (PantryArchiveHandle) async throws -> Void = { _ in },
         cleanup: @escaping () async throws -> Void, clock: @escaping () -> Date = Date.init) {
        self.worker = worker; self.registry = registry; self.captureLive = captureLive
        self.validateLocalDependencies = validateLocalDependencies; self.openRecovered = openRecovered
        self.captureIndependent = captureIndependent; self.beginAuthorization = beginAuthorization
        self.willRemove = willRemove; self.discardCapture = discardCapture; self.cleanup = cleanup; self.clock = clock
    }

    var canRefresh: Bool {
        !busy && picker == nil && importReview == nil && deletionReview == nil
            && presentedPickers.isEmpty && !cleaning && workCount == 0
    }
    var canStart: Bool { canRefresh && exportIDs.isEmpty && stagedImport == nil }
    var hasValidKey: Bool {
        Data(base64Encoded: recoveryKey.trimmingCharacters(in: .whitespacesAndNewlines))?.count == 32
    }
    func generateKey() { recoveryKey = EncryptedArchive.generateKey() }

    /// Synchronous privacy redaction. Files may still be copying its source, so
    /// encrypted staging is retired only after its original picker terminates.
    func invalidate() {
        cancelAction()
        redacting = true; recoveryKey = ""; redacting = false
        copies = []; error = nil; status = nil
    }
    func cancelAction() {
        admission = nil; picker = nil; importReview = nil; deletionReview = nil
        busy = false; error = nil; status = nil
        cleanupNeeded = true; scheduleCleanup()
    }

    func reload() async {
        guard canRefresh else { return }
        var started: Admission?
        do {
            let ticket = try start(); started = ticket; workCount += 1
            defer { finishWork(ticket.id) }
            for id in exportIDs { await retireExport(id); try require(ticket) }
            try await discardStagedImport(); try require(ticket)
            try await worker.reconcilePreparedImports(registry: registry); try require(ticket)
            guard exportIDs.isEmpty else { throw Failure.failed }
            try await cleanup(); try require(ticket)
            let values = try await registry.listPantry(); try require(ticket)
            copies = values
        } catch { if started == nil || admission?.id == started?.id { report(error) } }
    }

    func prepareExport(copy: RecoveredPantryCopy? = nil) async {
        guard canStart else { return }
        var ticket: Admission?
        do {
            guard hasValidKey else { throw Failure.invalidKey }
            let current = try start(); ticket = current; workCount += 1
            defer { finishWork(current.id) }
            let key = recoveryKey
            let handle: PantryArchiveHandle
            if let copy {
                let exact = try await registry.currentPantryCopy(copy); try require(current)
                handle = try await captureIndependent(exact, current.authorize)
            } else {
                handle = try await captureLive(current.authorize)
            }
            captures[current.id] = handle
            try require(current)
            try await validateLocalDependencies(handle, current.authorize); try require(current)
            let intent = try await registry.preparePantryBackup(Self.reference(handle), recoveredCopy: copy); try require(current)
            let package = try await worker.encryptedExport(handle, key: key)
            exports[current.id] = Export(package: package, intent: intent)
            try require(current)
            picker = .init(id: current.id, mode: .exportPackage(package.url))
        } catch {
            if ticket == nil || admission?.id == ticket?.id { report(error) }
            cleanupNeeded = true; scheduleCleanup()
        }
    }

    func beginImport() {
        guard canStart else { return }
        do {
            guard hasValidKey else { throw Failure.invalidKey }
            let current = try start()
            busy = false
            picker = .init(id: current.id, mode: .importPackage)
        } catch { report(error) }
    }

    /// Only a mounted native picker can still be reading encrypted staging.
    func pickerDidPresent(operationID: UUID) {
        if picker?.id == operationID { presentedPickers.insert(operationID) }
    }

    /// Synchronous once-only delegate acceptance closes the onDismiss race.
    func pickerWillComplete(operationID: UUID) {
        if presentedPickers.contains(operationID) { acceptedPickers.insert(operationID) }
    }

    /// Called by the native bridge while its selected URL security scope is alive.
    func completePicker(operationID: UUID, outcome: RecordsPantryFilePicker.Outcome) async {
        guard acceptedPickers.remove(operationID) != nil,
              presentedPickers.remove(operationID) != nil else { return }
        workCount += 1
        defer { finishWork(operationID) }
        if picker?.id == operationID { picker = nil }
        guard let current = admission, current.id == operationID, current.authorize() else {
            if admission?.id == operationID { invalidate() }
            await retireExport(operationID); cleanupNeeded = true; scheduleCleanup(); return
        }
        switch outcome {
        case .exported:
            guard let export = exports[operationID], let handle = captures[operationID] else { return }
            busy = true
            do {
                try require(current)
                try await validateLocalDependencies(handle, current.authorize); try require(current)
                try await registry.recordSuccessfulPantryBackup(export.intent, savedAtMilliseconds: ArchiveCodec.milliseconds(clock()))
                try require(current)
                status = .exported
            } catch { if admission?.id == current.id { report(error) } }
            await retireExport(operationID)
            cleanupNeeded = true
        case .selectedForImport(let url):
            guard exports[operationID] == nil else { await retireExport(operationID); return }
            busy = true
            do {
                let key = recoveryKey
                let prepared = try await worker.prepareImport(url: url, key: key)
                stagedImport = prepared
                try require(current)
                let handle = prepared.handle
                try await validateLocalDependencies(handle, current.authorize); try require(current)
                let review = try await registry.reviewPantry(Self.reference(handle)); try require(current)
                if !review.canApply { try await discardStagedImport(); try require(current) }
                importReview = .init(handle: handle, registry: review)
            } catch {
                if admission?.id == current.id { report(error) }
                cleanupNeeded = true
            }
        case .cancelled:
            status = .cancelled
            await retireExport(operationID)
            cleanupNeeded = true; scheduleCleanup()
        case .failed:
            error = .failed
            await retireExport(operationID)
            cleanupNeeded = true; scheduleCleanup()
        }
    }

    /// SwiftUI dismissal may precede or follow the accepted native callback.
    /// It cannot cancel that callback's in-progress import or record a backup.
    func pickerDidDismiss(operationID: UUID) async {
        guard !acceptedPickers.contains(operationID), presentedPickers.remove(operationID) != nil else { return }
        workCount += 1
        defer { finishWork(operationID) }
        if picker?.id == operationID { picker = nil }
        if admission?.id == operationID { admission = nil; busy = false; status = .cancelled }
        await retireExport(operationID)
        cleanupNeeded = true; scheduleCleanup()
    }

    func applyImport() async {
        guard !busy, let reviewed = importReview, reviewed.registry.canApply, let prepared = stagedImport,
              let current = admission else { return }
        error = nil; status = nil
        busy = true; workCount += 1
        defer { finishWork(current.id) }
        do {
            try require(current)
            let verified = try await worker.revalidateImport(prepared); try require(current)
            try await validateLocalDependencies(verified, current.authorize); try require(current)
            _ = try await worker.applyImport(prepared, review: reviewed.registry, registry: registry, now: clock()) { [weak self] in
                self?.admission?.id == current.id && current.authorize()
            }
            try require(current)
            importReview = nil; cleanupNeeded = true
            let values = try await registry.listPantry(); try require(current)
            copies = values; status = .imported
        } catch {
            if admission?.id == current.id { importReview = nil; report(error) }
            cleanupNeeded = true
        }
    }

    func open(_ copy: RecoveredPantryCopy) async {
        guard canStart else { return }
        var ticket: Admission?
        do {
            let current = try start(); ticket = current; workCount += 1
            defer { finishWork(current.id) }
            let exact = try await registry.currentPantryCopy(copy); try require(current)
            let handle = try await worker.open(reference: .init(bundleID: exact.reference.bundleID, manifestDigest: exact.reference.manifestDigest))
            try require(current)
            try await validateLocalDependencies(handle, current.authorize); try require(current)
            try await openRecovered(exact, current.authorize); try require(current)
            let values = try await registry.listPantry(); try require(current)
            copies = values; status = .opened
        } catch { if ticket == nil || admission?.id == ticket?.id { report(error) } }
    }

    func reviewDeletion(_ copy: RecoveredPantryCopy) async {
        guard canStart else { return }
        var ticket: Admission?
        do {
            let current = try start(); ticket = current; workCount += 1
            defer { finishWork(current.id) }
            let exact = try await registry.currentPantryCopy(copy); try require(current)
            let review = try await registry.reviewPantryDeletion(copyIDs: [exact.id]); try require(current)
            deletionReview = review
        } catch { if ticket == nil || admission?.id == ticket?.id { report(error) } }
    }
    func applyDeletion() async {
        guard !busy, let reviewed = deletionReview, let current = admission else { return }
        error = nil; status = nil
        busy = true; workCount += 1
        defer { finishWork(current.id) }
        do {
            try require(current)
            try await willRemove(Set(reviewed.copies.map(\.id))); try require(current)
            try await registry.deletePantry(reviewed); try require(current)
            deletionReview = nil
            try await cleanup(); try require(current)
            let values = try await registry.listPantry(); try require(current)
            copies = values; status = .deleted
        } catch { if admission?.id == current.id { report(error) } }
    }

    private func start() throws -> Admission {
        guard let authorize = beginAuthorization(), authorize() else { invalidate(); throw Failure.unavailable }
        let value = Admission(id: UUID(), authorize: authorize)
        admission = value; busy = true; error = nil; status = nil
        return value
    }
    private func require(_ ticket: Admission) throws {
        try Task.checkCancellation()
        guard admission?.id == ticket.id else { throw Failure.stale }
        guard ticket.authorize() else { invalidate(); throw Failure.unavailable }
    }
    private func finishWork(_ operationID: UUID) {
        workCount -= 1
        if admission?.id == operationID { busy = false }
        scheduleCleanup()
    }
    private func report(_ failure: Error) {
        error = failure as? Failure ?? .failed
    }
    private func retireExport(_ id: UUID) async {
        if let value = exports[id] {
            do { try await worker.discardExport(value.package); exports[id] = nil }
            catch { cleanupNeeded = true }
        }
        if let handle = captures[id] {
            do { try await discardCapture(handle); captures[id] = nil }
            catch { cleanupNeeded = true }
        }
    }
    private func discardStagedImport() async throws {
        guard let prepared = stagedImport else { return }
        try await worker.discardImport(prepared, registry: registry)
        stagedImport = nil
    }

    /// A cross-store erasure may only acknowledge cleanup after this model has
    /// released its captured files. A still-mounted Files picker must finish
    /// first; its normal dismissal drives cleanup and the receipt can be retried.
    func invalidateAndDrain() async throws {
        invalidate()
        if let cleanupTask { await cleanupTask.value }
        guard workCount == 0, presentedPickers.isEmpty, cleanupTask == nil,
              stagedImport == nil, exportIDs.isEmpty else { throw Failure.unavailable }
    }

    private func scheduleCleanup() {
        guard cleanupNeeded, cleanupTask == nil, workCount == 0, picker == nil, presentedPickers.isEmpty, importReview == nil else { return }
        cleanupNeeded = false; cleaning = true
        cleanupTask = Task { [self] in
            for id in exportIDs { await retireExport(id) }
            do {
                try await discardStagedImport()
                try await cleanup()
            } catch {
                cleanupNeeded = true
                if admission?.authorize() == true, status == nil, self.error == nil { self.error = .failed }
            }
            cleanupTask = nil; cleaning = false
        }
    }
    private static func reference(_ handle: PantryArchiveHandle) -> PantryRecoveryReference {
        .init(bundleID: handle.reference.bundleID, manifestDigest: handle.reference.manifestDigest,
              originID: handle.descriptor.originID, inventoryRevision: handle.descriptor.inventoryRevision)
    }
}
