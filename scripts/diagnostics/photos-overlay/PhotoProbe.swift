import SwiftUI
import PhotosUI

@MainActor struct PhotoProbe: View {
    @State private var photo: PhotosPickerItem?
    var body: some View {
        PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
            Text("Select photo")
        }
    }
    func read(_ item: PhotosPickerItem) async throws -> Data? {
        try await item.loadTransferable(type: Data.self)
    }
}
