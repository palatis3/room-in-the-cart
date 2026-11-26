import CoreDomain
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

    static func makeThumbnail(_ data: Data) throws -> Data {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: maximumDimension
              ] as CFDictionary) else { throw ScanFailure.invalidImage }
        let bytes = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil)
        else { throw ScanFailure.invalidImage }
        CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.70] as CFDictionary)
        guard CGImageDestinationFinalize(destination), bytes.length <= maximumBytes else { throw ScanFailure.invalidImage }
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
                    })
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
