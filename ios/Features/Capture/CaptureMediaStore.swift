import Foundation
import CryptoKit
import Darwin

struct CaptureMediaArchiveListing: Sendable {
    var records: [SourceMediaRecord] = []
    var unavailableCount = 0
}

/// Sidecar evidence only. Saved bytes are never recovered as access, payment, food receipt or meal approval.
actor CaptureMediaStore {
    static let shared = CaptureMediaStore()
    private let directory: URL?
    init(directory: URL? = nil) { self.directory = directory }

    func save(_ record: SourceMediaRecord, authorize: @MainActor @Sendable () -> Bool) async throws -> SourceMediaReference {
        guard await authorize() else { throw ScanFailure.stale }
        try record.validate()
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys]
        let bytes = try encoder.encode(record)
        guard bytes.count <= ScanLimits.maximumRecordBytes else { throw ScanFailure.tooLarge }
        let inserted = try withLock {
            let workspace = try workspaceDirectory(record.target.workspaceID)
            guard try !retired(record.target, mediaID: record.id) else { throw ScanFailure.retired }
            try ensureDirectory(workspace)
            let url = workspace.appendingPathComponent(record.id.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                guard try readUnlocked(url) == record else { throw ScanFailure.replay }; return false
            }
            guard try recordFiles(workspace).count < ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.tooLarge }
            try write(bytes, to: url)
            return true
        }
        guard await authorize() else {
            // Remove only this newly created sidecar; an existing accepted receipt is not undone.
            if inserted { try removeExact(record) }
            throw ScanFailure.stale
        }
        return record.reference
    }
    func read(_ reference: SourceMediaReference, target: CaptureTarget,
              authorize: @MainActor @Sendable () -> Bool) async throws -> SourceMediaRecord {
        guard reference.workspaceID == target.workspaceID, await authorize() else { throw ScanFailure.stale }
        let result = try withLock {
            guard try !retired(target, mediaID: reference.mediaID) else { throw ScanFailure.retired }
            let directory = try workspaceDirectory(target.workspaceID)
            let value = try readUnlocked(directory.appendingPathComponent(reference.mediaID.uuidString.lowercased() + ".json"))
            guard value.id == reference.mediaID, value.target.sameObject(as: target) else { throw ScanFailure.stale }
            return value
        }
        guard await authorize() else { throw ScanFailure.stale }
        return result
    }
    func list(target: CaptureTarget, authorize: @MainActor @Sendable () -> Bool) async throws -> [SourceMediaRecord] {
        guard await authorize() else { throw ScanFailure.stale }
        let result = try withLock {
            guard try !retired(target) else { throw ScanFailure.retired }
            let directory = try workspaceDirectory(target.workspaceID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return [SourceMediaRecord]() }
            return try recordFiles(directory).map(readUnlocked).filter { record in
                guard record.target.sameObject(as: target) else { return false }
                return try !retired(record.target, mediaID: record.id)
            }.sorted { $0.capturedAt < $1.capturedAt }
        }
        guard await authorize() else { throw ScanFailure.stale }
        return result
    }
    /// One bounded file per workspace. Never enumerate or decode full source images while scrolling.
    func packagePhotos(target: CaptureTarget, owner: PackageRowPhoto.Owner,
                       authorize: @MainActor @Sendable () -> Bool) async throws -> [PackageRowPhoto] {
        guard target.kind == .packageReference, await authorize() else { throw ScanFailure.stale }
        let rows = try withLock {
            try livePackagePhotos(in: target.workspaceID, owner: owner).flatMap { row -> [PackageRowPhoto] in
                if row.target.containerID == target.containerID { return [row] }
                return (row.destinations ?? []).filter { $0.target.containerID == target.containerID }.map { row.projected(to: $0) }
            }
        }
        guard await authorize() else { throw ScanFailure.stale }
        return rows
    }

    private func livePackagePhotos(in workspace: UUID, owner: PackageRowPhoto.Owner) throws -> [PackageRowPhoto] {
        try loadPackagePhotos(workspace).filter { row in
            guard row.owner == owner, try !retired(row.target, mediaID: row.source.mediaID) else { return false }
            let source = try workspaceDirectory(workspace).appendingPathComponent(row.source.mediaID.uuidString.lowercased() + ".json")
            return FileManager.default.fileExists(atPath: source.path)
        }
    }

    /// Only source photos explicitly shown by this adult are offered for reuse.
    func earlierPackagePhotos(for target: CaptureTarget, owner: PackageRowPhoto.Owner,
                              authorize: @MainActor @Sendable () -> Bool) async throws -> [PackageRowPhoto] {
        guard target.kind == .packageReference, await authorize() else { throw ScanFailure.stale }
        let rows = try withLock { try livePackagePhotos(in: target.workspaceID, owner: owner).filter { $0.target.containerID != target.containerID } }
        guard await authorize() else { throw ScanFailure.stale }
        return rows
    }

    func reusePackagePhoto(_ original: PackageRowPhoto, destination: PackageRowPhoto.Destination, owner: PackageRowPhoto.Owner,
                           authorize: @MainActor @Sendable () -> Bool) async throws {
        let target = destination.target
        guard original.owner == owner, original.target.workspaceID == target.workspaceID, target.kind == .packageReference,
              target.containerID != original.target.containerID, original.association == nil,
              destination.originalProduct.utf8.count == 64, destination.destinationProduct.utf8.count == 64,
              await authorize() else { throw ScanFailure.stale }
        try withLock {
            var rows = try loadPackagePhotos(target.workspaceID)
            let sourceFile = try workspaceDirectory(target.workspaceID)
                .appendingPathComponent(original.source.mediaID.uuidString.lowercased() + ".json")
            guard FileManager.default.fileExists(atPath: sourceFile.path), try !retired(original.target, mediaID: original.source.mediaID),
                  let i = rows.firstIndex(where: { $0.revision == original.revision && $0.source == original.source &&
                      $0.owner == owner && $0.target.sameObject(as: original.target) }),
                  !rows.contains(where: { row in row.owner == owner && (row.target.sameObject(as: target) ||
                      row.destinations?.contains(where: { $0.target.sameObject(as: target) }) == true) }) else { throw ScanFailure.stale }
            var links = rows[i].destinations ?? []
            guard links.count < 100 else { throw ScanFailure.tooLarge }
            links.append(destination)
            rows[i].destinations = links
            try savePackagePhotos(rows, in: target.workspaceID)
        }
        guard await authorize() else {
            try unlinkPackageDestination(destination, from: original.source, owner: owner)
            await notifyPackagePhotosChanged()
            throw ScanFailure.stale
        }
        await notifyPackagePhotosChanged()
    }

    private func unlinkPackageDestination(_ link: PackageRowPhoto.Destination, from source: SourceMediaReference,
                                          owner: PackageRowPhoto.Owner) throws {
        try withLock {
            var rows = try loadPackagePhotos(source.workspaceID)
            guard let i = rows.firstIndex(where: { $0.source == source && $0.owner == owner }),
                  rows[i].destinations?.contains(link) == true else { return }
            rows[i].destinations?.removeAll { $0 == link }
            try savePackagePhotos(rows, in: source.workspaceID)
        }
    }

    func removeReusedPackagePhoto(_ photo: PackageRowPhoto, target: CaptureTarget, owner: PackageRowPhoto.Owner,
                                  authorize: @MainActor @Sendable () -> Bool) async throws {
        guard let link = photo.association, link.target.sameObject(as: target), target.workspaceID == photo.source.workspaceID,
              owner == photo.owner, await authorize() else { throw ScanFailure.stale }
        try unlinkPackageDestination(link, from: photo.source, owner: owner)
        await notifyPackagePhotosChanged()
    }

    func setPackagePhoto(_ reference: SourceMediaReference, target: CaptureTarget, owner: PackageRowPhoto.Owner,
                         cue: String?, authorize: @MainActor @Sendable () -> Bool) async throws {
        guard target.kind == .packageReference, reference.workspaceID == target.workspaceID,
              await authorize() else { throw ScanFailure.stale }
        var replacement: PackageRowPhoto?
        if let cue {
            let cue = try PackageRowPhoto.normalizedCue(cue)
            let record = try await read(reference, target: target, authorize: authorize)
            guard let jpeg = record.imageJPEG else { throw ScanFailure.invalidImage }
            replacement = try PackageRowPhoto(owner: owner, target: target, source: reference, cue: cue,
                                              thumbnail: PackageRowPhoto.makeThumbnail(jpeg))
        }
        guard await authorize() else { throw ScanFailure.stale }
        let previous: (direct: PackageRowPhoto?, reused: PackageRowPhoto?) = try withLock {
            guard try !retired(target, mediaID: reference.mediaID) else { throw ScanFailure.retired }
            var rows = try loadPackagePhotos(target.workspaceID)
            var oldReuse: PackageRowPhoto?
            if replacement != nil, let i = rows.firstIndex(where: { $0.owner == owner &&
                $0.destinations?.contains(where: { $0.target.sameObject(as: target) }) == true }),
               let linked = rows[i].destinations?.first(where: { $0.target.sameObject(as: target) }) {
                oldReuse = rows[i].projected(to: linked)
                rows[i].destinations?.removeAll { $0.id == linked.id }
            }
            let previous = rows.first { $0.owner == owner && $0.target.sameObject(as: target) }
            rows.removeAll { row in
                row.owner == owner && row.target.sameObject(as: target) && (replacement != nil || row.source == reference)
            }
            if let replacement { rows.append(replacement) }
            guard rows.count <= ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.tooLarge }
            try savePackagePhotos(rows, in: target.workspaceID)
            return (previous, oldReuse)
        }
        if let replacement, !(await authorize()) {
            // An interrupted opt-in cannot expose a new picture. Preserve a concurrent choice or removal.
            try withLock {
                var rows = try loadPackagePhotos(target.workspaceID)
                guard rows.contains(where: { $0.revision == replacement.revision }) else { return }
                rows.removeAll { $0.revision == replacement.revision }
                if let prior = previous.direct, try !retired(prior.target, mediaID: prior.source.mediaID) { rows.append(prior) }
                if let prior = previous.reused, let link = prior.association,
                   let i = rows.firstIndex(where: { $0.owner == owner && $0.revision == prior.revision && $0.source == prior.source }) {
                    rows[i].destinations = (rows[i].destinations ?? []) + [link]
                }
                try savePackagePhotos(rows, in: target.workspaceID)
            }
            await notifyPackagePhotosChanged()
            throw ScanFailure.stale
        }
        await notifyPackagePhotosChanged()
    }

    private func packagePhotoFile(_ workspace: UUID) throws -> URL {
        try root().appendingPathComponent("row-photos-" + hash(workspace.uuidString) + ".json")
    }

    private func loadPackagePhotos(_ workspace: UUID) throws -> [PackageRowPhoto] {
        let url = try packagePhotoFile(workspace)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try ensureNotLink(url)
        let limit = 600_000
        let attributes = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
        guard attributes.isRegularFile == true, (attributes.fileSize ?? Int.max) <= limit else { throw ScanFailure.storage }
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        let data = try handle.read(upToCount: limit + 1) ?? Data()
        guard data.count <= limit else { throw ScanFailure.tooLarge }
        let rows = try JSONDecoder().decode([PackageRowPhoto].self, from: data)
        guard rows.count <= ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.invalidImage }
        for row in rows {
            guard row.target.kind == .packageReference, row.target.workspaceID == workspace,
                  row.source.workspaceID == workspace, row.association == nil, row.originalTarget == nil,
                  (row.destinations?.count ?? 0) <= 100,
                  (row.destinations ?? []).allSatisfy({ $0.target.workspaceID == workspace && $0.target.kind == .packageReference &&
                      $0.target.containerID != row.target.containerID && $0.originalProduct.utf8.count == 64 && $0.destinationProduct.utf8.count == 64 }),
                  row.thumbnail.count <= PackageRowPhoto.maximumBytes,
                  try PackageRowPhoto.normalizedCue(row.cue) == row.cue,
                  PackageRowPhoto.validThumbnail(row.thumbnail) else { throw ScanFailure.invalidImage }
        }
        return rows
    }

    private func savePackagePhotos(_ rows: [PackageRowPhoto], in workspace: UUID) throws {
        let url = try packagePhotoFile(workspace)
        if rows.isEmpty {
            if FileManager.default.fileExists(atPath: url.path) { try FileManager.default.removeItem(at: url) }
        } else {
            let data = try JSONEncoder().encode(rows)
            guard data.count <= 600_000 else { throw ScanFailure.tooLarge }
            try write(data, to: url)
        }
    }

    @MainActor private func notifyPackagePhotosChanged() {
        NotificationCenter.default.post(name: PackageRowPhoto.changed, object: nil)
    }

    /// Records supplies a domain-owned namespace and filters targets against its
    /// scoped typed snapshot. This does not accept a decoded document as authority.
    func archiveListing(workspaceID: UUID, authorize: @MainActor @Sendable () -> Bool) async throws -> CaptureMediaArchiveListing {
        guard await authorize() else { throw ScanFailure.stale }
        let result = try withLock {
            let directory = try workspaceDirectory(workspaceID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return CaptureMediaArchiveListing() }
            try ensureNotLink(directory)
            let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            guard files.count <= ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.tooLarge }
            var listing = CaptureMediaArchiveListing()
            for file in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
                do {
                    guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                          file.lastPathComponent == id.uuidString.lowercased() + ".json" else { throw ScanFailure.storage }
                    // Retired IDs remain excluded even if corrupted bytes survive cleanup.
                    guard !FileManager.default.fileExists(atPath: try mediaMarker(workspaceID, id).path),
                          !FileManager.default.fileExists(atPath: try workspaceMarker(workspaceID).path) else { continue }
                    let record = try readUnlocked(file)
                    guard record.id == id, record.target.workspaceID == workspaceID else { throw ScanFailure.storage }
                    if try !retired(record.target, mediaID: record.id) { listing.records.append(record) }
                } catch { listing.unavailableCount += 1 }
            }
            return listing
        }
        guard await authorize() else { throw ScanFailure.stale }
        return result
    }
    /// Known removal markers also apply to a backup brought back to this device.
    /// This reads tombstones only and never opens an old source namespace.
    func isRetired(_ record: SourceMediaRecord) throws -> Bool {
        try withLock { try retired(record.target, mediaID: record.id) }
    }
    func eraseWorkspace(_ workspaceID: UUID) async throws {
        try withLock {
            try write(Data(), to: workspaceMarker(workspaceID))
            try savePackagePhotos([], in: workspaceID)
            let places = try savedPlacesURL(workspaceID)
            if FileManager.default.fileExists(atPath: places.path) { try FileManager.default.removeItem(at: places) }
            let directory = try workspaceDirectory(workspaceID)
            if FileManager.default.fileExists(atPath: directory.path) { try ensureNotLink(directory); try FileManager.default.removeItem(at: directory) }
        }
        await notifyPackagePhotosChanged()
    }
    func erasePickupRecord(workspaceID: UUID, recordID: UUID) async throws {
        try withLock {
            try write(Data(), to: recordMarker(workspaceID, recordID))
            let directory = try workspaceDirectory(workspaceID)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            for url in try recordFiles(directory) {
                let value = try readUnlocked(url)
                if value.target.kind == .receiptEvidence && value.target.containerID == recordID { try FileManager.default.removeItem(at: url) }
            }
        }
    }
    func remove(_ reference: SourceMediaReference, target: CaptureTarget,
                authorize: @MainActor @Sendable () -> Bool) async throws {
        guard reference.workspaceID == target.workspaceID, await authorize() else { throw ScanFailure.stale }
        try withLock {
            let directory = try workspaceDirectory(target.workspaceID)
            let url = directory.appendingPathComponent(reference.mediaID.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: url.path) {
                let record = try readUnlocked(url)
                guard record.target.sameObject(as: target) else { throw ScanFailure.stale }
                try write(Data(), to: mediaMarker(target.workspaceID, reference.mediaID))
                try FileManager.default.removeItem(at: url)
            } else {
                try write(Data(), to: mediaMarker(target.workspaceID, reference.mediaID))
            }
            if target.kind == .packageReference {
                // A damaged preference index can be discarded without restoring a deleted source.
                let rows = (try? loadPackagePhotos(target.workspaceID)) ?? []
                try savePackagePhotos(rows.filter { $0.source != reference }, in: target.workspaceID)
            }
        }
        await notifyPackagePhotosChanged()
    }
    nonisolated static func defaultDirectory(applicationSupport: URL, arguments: [String]) -> URL {
        #if DEBUG
        if arguments.contains("--ui-testing") { return applicationSupport.appendingPathComponent("UITestWorkspace/CaptureMedia", isDirectory: true) }
        #endif
        return applicationSupport.appendingPathComponent("RoomInTheCart/CaptureMedia", isDirectory: true)
    }
    private func root() throws -> URL {
        if let directory { return directory }
        let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        return Self.defaultDirectory(applicationSupport: base, arguments: ProcessInfo.processInfo.arguments)
    }
    private func workspaceDirectory(_ id: UUID) throws -> URL { try root().appendingPathComponent(hash(id.uuidString), isDirectory: true) }
    private func workspaceMarker(_ id: UUID) throws -> URL { try root().appendingPathComponent("workspace-" + hash(id.uuidString) + ".retired") }
    private func recordMarker(_ workspace: UUID, _ id: UUID) throws -> URL { try root().appendingPathComponent("record-" + hash(workspace.uuidString + ":" + id.uuidString) + ".retired") }
    private func mediaMarker(_ workspace: UUID, _ id: UUID) throws -> URL { try root().appendingPathComponent("media-" + hash(workspace.uuidString + ":" + id.uuidString) + ".retired") }
    private func retired(_ target: CaptureTarget, mediaID: UUID? = nil) throws -> Bool {
        if FileManager.default.fileExists(atPath: try workspaceMarker(target.workspaceID).path) { return true }
        if target.kind == .receiptEvidence, FileManager.default.fileExists(atPath: try recordMarker(target.workspaceID, target.containerID).path) { return true }
        if let mediaID, FileManager.default.fileExists(atPath: try mediaMarker(target.workspaceID, mediaID).path) { return true }
        return false
    }
    private func hash(_ value: String) -> String { SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined() }
    private func readUnlocked(_ url: URL) throws -> SourceMediaRecord {
        try ensureNotLink(url); try ensureNotLink(url.deletingLastPathComponent())
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard values.isRegularFile == true, (values.fileSize ?? Int.max) <= ScanLimits.maximumRecordBytes else { throw ScanFailure.storage }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let bytes = try handle.read(upToCount: ScanLimits.maximumRecordBytes + 1) ?? Data()
        guard bytes.count <= ScanLimits.maximumRecordBytes else { throw ScanFailure.tooLarge }
        let result = try JSONDecoder().decode(SourceMediaRecord.self, from: bytes)
        try result.validate(); return result
    }
    private func recordFiles(_ directory: URL) throws -> [URL] {
        try ensureNotLink(directory)
        let files = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.isSymbolicLinkKey])
        guard files.count <= ScanLimits.maximumWorkspaceRecords else { throw ScanFailure.tooLarge }
        for file in files {
            guard file.pathExtension == "json", let id = UUID(uuidString: file.deletingPathExtension().lastPathComponent),
                  file.lastPathComponent == id.uuidString.lowercased() + ".json" else { throw ScanFailure.storage }
            try ensureNotLink(file)
        }
        return files
    }
    private func removeExact(_ record: SourceMediaRecord) throws {
        try withLock {
            let url = try workspaceDirectory(record.target.workspaceID).appendingPathComponent(record.id.uuidString.lowercased() + ".json")
            if FileManager.default.fileExists(atPath: url.path), try readUnlocked(url) == record { try FileManager.default.removeItem(at: url) }
        }
    }
    private func withLock<T>(_ operation: () throws -> T) throws -> T {
        let directory = try root(); try ensureDirectory(directory)
        let lock = directory.appendingPathComponent("store.lock")
        if FileManager.default.fileExists(atPath: lock.path) { try ensureNotLink(lock) }
        let fd = Darwin.open(lock.path, O_CREAT | O_RDWR | O_NOFOLLOW, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw ScanFailure.storage }
        defer { Darwin.close(fd) }
        guard flock(fd, LOCK_EX) == 0 else { throw ScanFailure.storage }
        defer { flock(fd, LOCK_UN) }
        return try operation()
    }
    private func ensureNotLink(_ url: URL) throws {
        guard try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ScanFailure.storage }
    }
    private func ensureDirectory(_ url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) {
            try ensureNotLink(url)
            guard try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true else { throw ScanFailure.storage }
        } else { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
        var value = url; var resource = URLResourceValues(); resource.isExcludedFromBackup = true; try value.setResourceValues(resource)
        #if os(iOS)
        try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: url.path)
        #endif
    }
    private func write(_ data: Data, to url: URL) throws {
        if FileManager.default.fileExists(atPath: url.path) { try ensureNotLink(url) }
        #if os(iOS)
        try data.write(to: url, options: [.atomic, .completeFileProtection])
        #else
        try data.write(to: url, options: .atomic)
        #endif
    }
}

extension CaptureMediaStore {
    private func savedPlacesURL(_ workspace: UUID) throws -> URL {
        try root().appendingPathComponent("shopping-places-" + hash(workspace.uuidString))
    }

    private func placeSlots(_ workspace: UUID, at now: Date) throws -> [InStorePlaceSlot] {
        guard !FileManager.default.fileExists(atPath: try workspaceMarker(workspace).path) else { throw ScanFailure.retired }
        let url = try savedPlacesURL(workspace)
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        try ensureNotLink(url)
        let info = try url.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
        guard info.isRegularFile == true, (info.fileSize ?? .max) <= 256_000 else { throw ScanFailure.storage }
        let slots = try JSONDecoder().decode([InStorePlaceSlot].self, from: Data(contentsOf: url))
        guard slots.count <= 256, slots.allSatisfy({ $0.scope.workspace == workspace }) else { throw ScanFailure.storage }
        let live = slots.filter { $0.changed <= now && now.timeIntervalSince($0.changed) < InStoreSavedPlace.lifetime }
        if live.count != slots.count { try write(JSONEncoder().encode(live), to: url) }
        return live
    }

    func savedPlace(in scope: InStorePlaceScope, at now: Date = .now, photoOwner: PackageRowPhoto.Owner? = nil,
                    authorize: @MainActor @Sendable () -> Bool) async throws -> InStorePlaceSlot? {
        guard await authorize() else { throw ScanFailure.stale }
        let slot: InStorePlaceSlot? = try withLock {
            let slot = try placeSlots(scope.workspace, at: now).first { $0.scope == scope }
            if let place = slot?.place, let photo = place.photo, let photoOwner {
                // Resolve the live opt-in again at the tap; another window can withdraw its
                // source before SwiftUI receives the row-photo notification.
                let hasSource = try livePackagePhotos(in: scope.workspace, owner: photoOwner).contains { row in
                    guard row.revision == photo else { return false }
                    if let association = place.association {
                        return row.destinations?.contains { $0.id == association && $0.target.containerID == scope.shop &&
                            $0.target.objectID == place.line } == true
                    }
                    return row.target.containerID == scope.shop && row.target.objectID == place.line
                }
                guard hasSource else { return nil }
            }
            return slot
        }
        guard await authorize() else { throw ScanFailure.stale }
        return slot
    }

    func updateSavedPlace(in scope: InStorePlaceScope, expected: UUID?, place: InStoreSavedPlace?, at now: Date = .now,
                          authorize: @MainActor @Sendable () -> Bool) async throws {
        guard await authorize(), place?.isLive(at: now) != false else { throw ScanFailure.stale }
        let change = InStorePlaceSlot(scope: scope, changed: now, place: place)
        let previous: InStorePlaceSlot? = try withLock {
            var slots = try placeSlots(scope.workspace, at: now)
            let prior = slots.first { $0.scope == scope }
            guard prior?.revision == expected else { throw ScanFailure.stale }
            slots.removeAll { $0.scope == scope }
            slots.append(change)
            guard slots.count <= 256 else { throw ScanFailure.tooLarge }
            try write(JSONEncoder().encode(slots), to: savedPlacesURL(scope.workspace))
            return prior
        }
        guard await authorize() else {
            // Restore only our write, preserving a newer choice or an erased workspace.
            try withLock {
                var slots = try placeSlots(scope.workspace, at: now)
                guard slots.contains(where: { $0.revision == change.revision }) else { return }
                slots.removeAll { $0.revision == change.revision }
                if let previous { slots.append(previous) }
                try write(JSONEncoder().encode(slots), to: savedPlacesURL(scope.workspace))
            }
            throw ScanFailure.stale
        }
        await MainActor.run { NotificationCenter.default.post(name: Self.savedPlaceChanged, object: scope.workspace) }
    }

    static let savedPlaceChanged = Notification.Name("RoomInTheCart.privateShoppingPlaceChanged")
}
