import Foundation
import CoreTransferable
import UniformTypeIdentifiers

/// The picker grants this one temporary file. Bound reads before allocating the selected data.
enum SelectedPhotoTransfer: Transferable, Sendable {
    case image(Data)
    case overSizeLimit

    var data: Data {
        get throws {
            switch self {
            case let .image(data): return data
            case .overSizeLimit: throw ScanFailure.tooLarge
            }
        }
    }

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            // PhotosPicker wraps importer errors. Carry the known size refusal back to the editor.
            do { return Self.image(try boundedData(received.file)) }
            catch ScanFailure.tooLarge { return Self.overSizeLimit }
        }
    }
    static func boundedData(_ url: URL) throws -> Data {
        guard url.isFileURL else { throw ScanFailure.invalidImage }
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true,
              let size = values.fileSize, size > 0 else { throw ScanFailure.invalidImage }
        guard size <= CaptureLimits.imageBytes else { throw ScanFailure.tooLarge }
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        let data = try handle.read(upToCount: CaptureLimits.imageBytes + 1) ?? Data()
        guard data.count <= CaptureLimits.imageBytes else { throw ScanFailure.tooLarge }
        guard data.count == size else { throw ScanFailure.invalidImage }
        return data
    }
}
