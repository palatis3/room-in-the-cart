import AVFoundation
import CoreDomain
import PhotosUI
import SwiftUI

struct PantryShelfPhotoEditor: View {
    let access: PantryDigestAccess
    let location: InventoryLocation
    let expected: UUID?
    let didSave: () -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ShelfPhotoAccessGate(opened: access) {
            ShelfPhotoReview(location: location, expected: expected, access: access, didSave: didSave)
        }
        .navigationTitle(pantryLocationName(location))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() } } }
    }
}

private struct ShelfPhotoReview: View {
    let location: InventoryLocation
    let expected: UUID?
    let access: PantryDigestAccess
    let didSave: () -> Void
    @Environment(\.pantryDigestPermissionPrompt) private var prompt
    @State private var item: PhotosPickerItem?
    @State private var camera = false
    @State private var image: PantryShelfImage?
    @State private var date: Date?
    @State private var status: String?
    @State private var busy = false
    @State private var attempt = UUID()

    var body: some View {
        WorkingForm {
            Section {
                PhotosPicker(selection: $item, matching: .images, preferredItemEncoding: .current) {
                    Label(shelfPhotoText("Choose a photo"), systemImage: "photo.on.rectangle").frame(minHeight: 44)
                }
                .accessibilityIdentifier("shelfPhotos.choose")
                .onChange(of: item) { _, selection in
                    guard let selection else { return }
                    item = nil
                    preparePhoto(capturedNow: nil) {
                        guard let file = try await selection.loadTransferable(type: SelectedPhotoTransfer.self) else {
                            throw ScanFailure.invalidImage
                        }
                        return try file.data
                    }
                }
                Button { requestCamera() } label: {
                    Label(shelfPhotoText("Take a photo"), systemImage: "camera").frame(minHeight: 44)
                }.accessibilityIdentifier("shelfPhotos.camera")
            } footer: {
                Text(shelfPhotoText("Only the display copy and the date you confirm are kept on this iPhone."))
            }
            .disabled(busy)
            if busy { ProgressView() }
            if let image, let preview = UIImage(data: image.jpeg) {
                Section {
                    Image(uiImage: preview).resizable().scaledToFit()
                        .accessibilityLabel(shelfPhotoText("Selected shelf photo"))
                    if let date {
                        DatePicker(shelfPhotoText("Date taken"), selection: Binding(
                            get: { date }, set: { self.date = $0 }), in: ...Date(), displayedComponents: .date)
                    } else {
                        Text(shelfPhotoText("This photo has no capture date. Choose the day it was taken."))
                        Button(shelfPhotoText("Set date taken")) { date = Date() }.frame(minHeight: 44)
                    }
                    Button(shelfPhotoText("Save shelf photo")) { save(image) }
                        .buttonStyle(PrimaryAction())
                        .disabled(date == nil || busy)
                        .accessibilityIdentifier("shelfPhotos.save")
                }
            }
            if let status { Text(status).foregroundStyle(Theme.warning) }
        }
        .fullScreenCover(isPresented: $camera) {
            CameraCaptureView(authorize: access.authorized) { result in
                camera = false
                guard let result, access.authorized() else { return }
                switch result {
                case .success(let data): preparePhoto(capturedNow: Date()) { data }
                case .failure: report("Couldn’t read this photo. Try another image.")
                }
            }.ignoresSafeArea()
        }
        .onDisappear { attempt = UUID() }
    }

    private func report(_ key: String) {
        status = shelfPhotoText(key)
        UIAccessibility.post(notification: .announcement, argument: status)
    }

    private func requestCamera() {
        let token = UUID()
        attempt = token
        busy = true
        Task { @MainActor in
            do {
                if AVCaptureDevice.authorizationStatus(for: .video) == .notDetermined, let prompt, prompt.scope == access.scope {
                    _ = try await prompt.present {
                        try await CameraCapturePermission.request()
                        return true
                    }
                } else {
                    try await CameraCapturePermission.request()
                }
                guard token == attempt, access.authorized() else { return }
                camera = true
            } catch {
                if token == attempt, access.authorized() { report("Camera unavailable. Choose a photo instead.") }
            }
            if token == attempt { busy = false }
        }
    }

    private func preparePhoto(capturedNow: Date?, load: @escaping @MainActor () async throws -> Data) {
        let token = UUID()
        attempt = token
        busy = true
        status = nil
        Task { @MainActor in
            defer { if token == attempt { busy = false } }
            do {
                let bytes = try await load()
                guard token == attempt, access.authorized() else { return }
                let prepared = try await Task.detached(priority: .userInitiated) {
                    try PantryShelfImage(original: bytes, capturedNow: capturedNow)
                }.value
                guard token == attempt, access.authorized() else { return }
                image = prepared
                if let suggested = prepared.suggestedDay?.date,
                   Calendar.current.compare(suggested, to: Date(), toGranularity: .day) != .orderedDescending {
                    date = min(suggested, Date())
                } else { date = nil }
            } catch {
                if token == attempt, access.authorized() { report("Couldn’t read this photo. Try another image.") }
            }
        }
    }

    private func save(_ image: PantryShelfImage) {
        guard let date, !busy else { return }
        do {
            let day = try MealDay(date: date, timeZoneIdentifier: TimeZone.current.identifier)
            try PantryDigestStore.shared.shelfPhotos.save(image, captureDay: day, at: location, replacing: expected, access: access)
            didSave()
        } catch { report("Couldn’t save this photo. Reopen this location and try again.") }
    }
}
