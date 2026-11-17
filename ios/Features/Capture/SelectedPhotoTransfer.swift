import Foundation
import CoreTransferable
import DeviceSurfaces
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
        do {
            return try readRegularFile(at: url, maximumBytes: CaptureLimits.imageBytes)
        } catch SurfaceError.capacity {
            throw ScanFailure.tooLarge
        } catch {
            throw ScanFailure.invalidImage
        }
    }
}
