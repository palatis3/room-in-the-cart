import CoreDomain
import CryptoKit
import ImageIO
import SwiftUI
import UniformTypeIdentifiers

func packagePhotoText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "PackageRowPhoto")
}

/// Kept in CaptureMedia's private, protected directory, outside the shopping ledger and recovery archive.
struct PackageRowPhoto: Codable, Equatable, Sendable {
    struct Owner: Codable, Equatable, Sendable {
        let actor: UUID
        let subject: String?
        let household: String?
        let member: String?

        init(_ identity: CapturePrivateIdentity) {
            actor = identity.actorID
            subject = identity.subject
            household = identity.householdID
            member = identity.memberID
        }
    }

    static let changed = Notification.Name("RoomInTheCart.privatePackageRowPhotoChanged")
    static let maximumBytes = 32_768
    static let maximumDimension = 144
    var revision = UUID()
    let owner: Owner
    let target: CaptureTarget
    let source: SourceMediaReference
    let cue: String
    let thumbnail: Data

    struct Destination: Codable, Equatable, Sendable {
        let id: UUID
        let target: CaptureTarget
        let originalProduct: String
        let destinationProduct: String
    }
    /// Persist only reviewed destinations beside the original thumbnail. The two
    /// projection fields are populated only when resolving a later trip for display.
    var destinations: [Destination]? = nil
    var originalTarget: CaptureTarget? = nil
    var association: Destination? = nil

    func projected(to destination: Destination) -> Self {
        Self(revision: revision, owner: owner, target: destination.target, source: source, cue: cue,
             thumbnail: thumbnail, originalTarget: target, association: destination)
    }

    func matchesCurrentGroceries(in workspace: LedgerWorkspace) -> Bool {
        guard let originalTarget, let association else { return true }
        return Self.productSignature(originalTarget, in: workspace) == association.originalProduct &&
            Self.productSignature(target, in: workspace) == association.destinationProduct
    }

    static func productSignature(_ target: CaptureTarget, in workspace: LedgerWorkspace) -> String? {
        guard let shop = workspace.shops.first(where: { $0.id == target.containerID }),
              let line = shop.lines.first(where: { $0.id == target.objectID && !$0.isTrashed }) else { return nil }
        // Picking the item or pricing it leaves this identity intact. Changes to the
        // request, package or its exclusions require the shopper to confirm it again.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        guard let wording = try? encoder.encode([line.name, line.notes]),
              let ingredients = try? encoder.encode(shop.contributions(forLineID: line.id)) else { return nil }
        return SHA256.hash(data: wording + ingredients).map { String(format: "%02x", $0) }.joined()
    }

    static func normalizedCue(_ text: String) throws -> String {
        let cue = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cue.isEmpty, cue.count <= 100, !cue.unicodeScalars.contains(where: CharacterSet.controlCharacters.contains)
        else { throw ScanFailure.invalidText }
        return cue
    }

    static func validThumbnail(_ data: Data) -> Bool {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int else { return false }
        return (1...maximumDimension).contains(width) && (1...maximumDimension).contains(height)
    }

    static func makeThumbnail(_ data: Data, dimension: Int = maximumDimension, byteLimit: Int = maximumBytes) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: dimension
              ] as CFDictionary) else { throw ScanFailure.invalidImage }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ScanFailure.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.70] as CFDictionary)
        guard CGImageDestinationFinalize(destination), bytes.length <= byteLimit else { throw ScanFailure.invalidImage }
        return bytes as Data
    }
}

struct PackagePhotoRowLabel: View {
    let photo: PackageRowPhoto
    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            if let image = UIImage(data: photo.thumbnail) {
                Image(uiImage: image).resizable().scaledToFit().frame(width: 52, height: 52)
                    .accessibilityHidden(true)
            }
            Text(verbatim: photo.cue).font(.subheadline).fixedSize(horizontal: false, vertical: true)
        }.accessibilityElement(children: .ignore)
         .accessibilityLabel(packagePhotoText("Package cue") + ", " + photo.cue)
         .accessibilityIdentifier("privatePackagePhoto.row")
    }
}

struct PrivatePackagePhotoLink: View {
    @ObservedObject var model: LedgerModel
    let shop: ShoppingLedger
    let line: ShoppingLine

    var body: some View {
        if let workspaceID = model.sourceWorkspaceID, !line.isTrashed {
            NavigationLink(packagePhotoText("Package photos and barcode references")) {
                PrivateSourceReferenceEntry(target: CaptureTarget(workspaceID: workspaceID, containerID: shop.id,
                    objectID: line.id, revision: Int64(shop.revision), kind: .packageReference), initialLabel: line.name,
                    sourceCurrent: {
                        model.ready && !model.saving && !model.hasPendingSave && !model.hasPendingLedgerDeletion &&
                        model.sourceWorkspaceID == workspaceID && model.workspace.selectedShopID == shop.id &&
                        model.shop?.revision == shop.revision &&
                        model.shop?.lines.contains(where: { $0.id == line.id && !$0.isTrashed }) == true
                    }, packageLedger: model)
            }.accessibilityIdentifier("ledger.scanReferences")
        }
    }
}

struct PackagePhotoChoice: View {
    let entry: SourceMediaRecord
    let owner: PackageRowPhoto.Owner
    let focus: FocusState<UUID?>.Binding
    let authorize: @MainActor @Sendable () -> Bool
    @State private var saved: PackageRowPhoto?
    @State private var wording = ""
    @State private var editor = false
    @State private var busy = false
    @State private var failed = false
    @State private var refresh = UUID()

    var body: some View {
        if authorize() {
            VStack(alignment: .leading, spacing: 8) {
                if let saved {
                    Label(packagePhotoText("Shown on my in-store list"), systemImage: "checkmark")
                    Text(verbatim: saved.cue)
                }
                if editor {
                    Text(packagePhotoText("Distinguishing detail")).font(.subheadline)
                    TextField(packagePhotoText("Distinguishing detail"), text: $wording)
                        .focused(focus, equals: entry.id).submitLabel(.done)
                        .onSubmit { focus.wrappedValue = nil }
                        .accessibilityIdentifier("privatePackagePhoto.cue")
                    Text(packagePhotoText("Use a short detail, such as blue cap or unsweetened.")).font(.footnote)
                    Button { update(show: true) } label: { actionLabel(packagePhotoText("Save photo and cue")) }
                        .accessibilityIdentifier("privatePackagePhoto.save")
                        .disabled((try? PackageRowPhoto.normalizedCue(wording)) == nil)
                    Button { focus.wrappedValue = nil; editor = false } label: { actionLabel(ledgerText("Cancel")) }
                } else {
                    Button {
                        wording = saved?.cue ?? ""; failed = false; editor = true
                    } label: { actionLabel(packagePhotoText(saved == nil ? "Show photo on my in-store list" : "Edit package cue")) }
                    .accessibilityIdentifier("privatePackagePhoto.edit")
                    if saved != nil {
                        Button { update(show: false) } label: { actionLabel(packagePhotoText("Hide photo from my in-store list")) }
                    }
                }
                if failed { Text(packagePhotoText("Could not update this photo. Reopen the reference and try again.")) }
            }.buttonStyle(.borderless).disabled(busy)
             .task(id: refresh) {
                 do {
                     let rows = try await CaptureMediaStore.shared.packagePhotos(target: entry.target, owner: owner, authorize: authorize)
                     guard !Task.isCancelled, authorize() else { return }
                     saved = rows.first { $0.source == entry.reference }
                 } catch { if !Task.isCancelled && authorize() { saved = nil; failed = true } }
             }.onReceive(NotificationCenter.default.publisher(for: PackageRowPhoto.changed)) { _ in refresh = UUID() }
        }
    }

    private func actionLabel(_ title: String) -> some View {
        Text(title).frame(maxWidth: .infinity, minHeight: 48, alignment: .leading).contentShape(Rectangle())
    }

    private func update(show: Bool) {
        guard authorize(), !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await CaptureMediaStore.shared.setPackagePhoto(entry.reference, target: entry.target, owner: owner,
                                                                  cue: show ? wording : nil, authorize: authorize)
                guard authorize() else { return }
                focus.wrappedValue = nil; editor = false; failed = false
            } catch { if authorize() { failed = true } }
        }
    }
}

struct EarlierPackageCueView: View {
    @ObservedObject var ledger: LedgerModel
    let target: CaptureTarget
    let owner: PackageRowPhoto.Owner
    let authorize: @MainActor @Sendable () -> Bool
    @State private var earlier: [PackageRowPhoto] = []
    @State private var existing: PackageRowPhoto?
    @State private var selected: PackageRowPhoto?
    @State private var selectedMatch: PackageRowPhoto.Destination?
    @State private var refresh = UUID()
    @State private var loaded = false
    @State private var busy = false
    @State private var failed = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        WorkingForm {
            if authorize(), let destination = grocery(target) {
                Section(packagePhotoText("This grocery")) { Text(verbatim: destination.name) }
                if !loaded && !failed { ProgressView() }
                else if let existing {
                    if existing.association != nil {
                        if existing.matchesCurrentGroceries(in: ledger.workspace) { PackagePhotoRowLabel(photo: existing) }
                        else { Text(packagePhotoText("The grocery changed. Choose its package again.")) }
                        Button(packagePhotoText("Remove cue from this trip"), role: .destructive) { remove(existing) }
                    } else {
                        Text(packagePhotoText("This grocery already has its own photo. Hide it in source references to use another cue."))
                    }
                } else if let selected, let selectedMatch {
                    Section(packagePhotoText("Previous package")) {
                        sourceLabel(selected)
                        Button(packagePhotoText("Same product and pack · Use this cue")) { confirm(selected, match: selectedMatch) }
                            .accessibilityIdentifier("privatePackagePhoto.confirmReuse")
                        Button(ledgerText("Cancel")) { clearSelection() }
                    }
                } else if loaded {
                    let choices = earlier.filter { grocery($0.target) != nil }
                    if choices.isEmpty { Text(packagePhotoText("No earlier trips have a saved package cue.")) }
                    else {
                        Section(packagePhotoText("Choose the exact previous package")) {
                            ForEach(choices, id: \.revision) { photo in
                                Button {
                                    guard let original = PackageRowPhoto.productSignature(photo.target, in: ledger.workspace),
                                          let destination = PackageRowPhoto.productSignature(target, in: ledger.workspace) else { failed = true; return }
                                    selected = photo
                                    selectedMatch = .init(id: UUID(), target: target, originalProduct: original, destinationProduct: destination)
                                } label: { sourceLabel(photo) }
                            }
                        }
                    }
                }
                if failed {
                    Text(packagePhotoText("Could not update this photo. Reopen the reference and try again."))
                    Button(ledgerText("Retry")) { reload() }
                }
            } else { Text(captureText("Unlock your private workspace to review this source.")) }
        }
        .disabled(busy)
        .privacySensitive()
        .navigationTitle(packagePhotoText("Previous package cue"))
        .task(id: refresh) {
            guard authorize() else { return }
            do {
                let active = try await CaptureMediaStore.shared.packagePhotos(target: target, owner: owner, authorize: authorize)
                let choices = try await CaptureMediaStore.shared.earlierPackagePhotos(for: target, owner: owner, authorize: authorize)
                guard authorize(), !Task.isCancelled else { return }
                existing = active.first { $0.target.sameObject(as: target) }
                earlier = choices
                loaded = true
            } catch { if authorize(), !Task.isCancelled { failed = true } }
        }
        .onReceive(NotificationCenter.default.publisher(for: PackageRowPhoto.changed)) { _ in reload() }
    }

    private func grocery(_ address: CaptureTarget) -> ShoppingLine? {
        guard ledger.sourceWorkspaceID == address.workspaceID,
              let trip = ledger.workspace.shops.first(where: { $0.id == address.containerID }) else { return nil }
        return trip.lines.first { $0.id == address.objectID && !$0.isTrashed }
    }

    @ViewBuilder private func sourceLabel(_ photo: PackageRowPhoto) -> some View {
        if let line = grocery(photo.target), let trip = ledger.workspace.shops.first(where: { $0.id == photo.target.containerID }) {
            VStack(alignment: .leading, spacing: 5) {
                Text(verbatim: line.name).font(.headline)
                Text(verbatim: [trip.title, trip.basis.branch].filter { !$0.isEmpty }.joined(separator: " · ")).font(.footnote)
                if let date = trip.basis.slot ?? trip.revisions.last?.createdAt { Text(date, style: .date).font(.footnote) }
                PackagePhotoRowLabel(photo: photo)
            }.accessibilityElement(children: .combine)
        }
    }

    private func clearSelection() { selected = nil; selectedMatch = nil }
    private func reload() {
        earlier = []; existing = nil; loaded = false; failed = false
        clearSelection()
        refresh = UUID()
    }

    private func confirm(_ original: PackageRowPhoto, match: PackageRowPhoto.Destination) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await CaptureMediaStore.shared.reusePackagePhoto(original, destination: match, owner: owner, authorize: {
                    authorize() && ledger.sourceWorkspaceID == target.workspaceID && ledger.shop?.id == target.containerID &&
                        PackageRowPhoto.productSignature(original.target, in: ledger.workspace) == match.originalProduct &&
                        PackageRowPhoto.productSignature(target, in: ledger.workspace) == match.destinationProduct
                })
                if authorize() { dismiss() }
            } catch { if authorize() { failed = true } }
        }
    }

    private func remove(_ photo: PackageRowPhoto) {
        guard !busy else { return }
        busy = true
        Task {
            defer { busy = false }
            do { try await CaptureMediaStore.shared.removeReusedPackagePhoto(photo, target: target, owner: owner, authorize: authorize) }
            catch { if authorize() { failed = true } }
        }
    }
}
