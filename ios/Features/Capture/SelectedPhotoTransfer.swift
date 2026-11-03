import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// The picker grants this one temporary file. Bound reads before allocating the selected data.
struct SelectedPhotoTransfer: Transferable, Sendable {
    let data: Data
    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            SelectedPhotoTransfer(data: try boundedData(received.file))
        }
    }
    static func boundedData(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ScanFailure.invalidImage }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0, size <= CaptureLimits.imageBytes else { throw ScanFailure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: CaptureLimits.imageBytes + 1) ?? Data()
        guard data.count == size, data.count <= CaptureLimits.imageBytes else { throw ScanFailure.tooLarge }
        return data
    }
}
