import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Decodes only bounded raster photos. The persisted reference has no copied EXIF/location metadata.
enum ScanImageNormalizer {
    static func normalize(_ data: Data) throws -> Data {
        guard !data.isEmpty, data.count <= CaptureLimits.imageBytes else { throw ScanFailure.tooLarge }
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source),
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type as String),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let dimensions = dimensions(properties), dimensions.0 > 0, dimensions.1 > 0,
              dimensions.0 <= 30_000_000 / dimensions.1 else { throw ScanFailure.invalidImage }
        for side in [2500, 1800, 1200] {
            guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: side, kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw ScanFailure.invalidImage }
            let data = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(data, UTType.jpeg.identifier as CFString, 1, nil) else { throw ScanFailure.invalidImage }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8, kCGImagePropertyOrientation: 1] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw ScanFailure.invalidImage }
            if data.length <= ScanLimits.maximumReferenceBytes { return data as Data }
        }
        throw ScanFailure.tooLarge
    }
    static func validateReference(_ data: Data) throws {
        // ImageIO can report a truncated JPEG as complete after reading its header.
        // Our encoder always terminates each standalone reference with the JPEG EOI marker.
        guard data.count <= ScanLimits.maximumReferenceBytes, data.suffix(2).elementsEqual([0xff, 0xd9]),
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, CGImageSourceGetType(source) as String? == UTType.jpeg.identifier,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              properties[kCGImagePropertyGPSDictionary] == nil,
              let size = dimensions(properties), size.0 > 0, size.1 > 0, size.0 <= 2500, size.1 <= 2500 else { throw ScanFailure.invalidImage }
    }
    private static func dimensions(_ values: [CFString: Any]) -> (Int, Int)? {
        guard let width = values[kCGImagePropertyPixelWidth] as? Int, let height = values[kCGImagePropertyPixelHeight] as? Int else { return nil }
        return (width, height)
    }
}
