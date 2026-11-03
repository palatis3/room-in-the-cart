import Foundation
import Vision
import ImageIO
import UniformTypeIdentifiers

/// Vision OCR is local. Images remain bounded in-memory review evidence; it never marks a receipt paid or food received.
struct OnDeviceTextCapture: CaptureOCRService {
    func recognize(_ data: Data) async throws -> CaptureEvidence {
        guard !data.isEmpty, data.count <= CaptureLimits.imageBytes else { throw CaptureFailure.inputTooLarge }
        let cancellation = OCRRequestCancellation()
        let work = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            guard let source = CGImageSourceCreateWithData(data as CFData, nil),
                  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
                  let width = properties[kCGImagePropertyPixelWidth] as? Int,
                  let height = properties[kCGImagePropertyPixelHeight] as? Int,
                  width > 0, height > 0, width <= 30_000_000 / height,
                  let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                    kCGImageSourceCreateThumbnailFromImageAlways: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                    kCGImageSourceThumbnailMaxPixelSize: 2500,
                    kCGImageSourceShouldCacheImmediately: true] as CFDictionary) else { throw CaptureFailure.imageUnavailable }
            let request = VNRecognizeTextRequest()
            cancellation.install(request)
            try Task.checkCancellation()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = false
            let supported = try request.supportedRecognitionLanguages()
            request.recognitionLanguages = supported.filter { $0.hasPrefix("en") || $0.hasPrefix("es") }
            guard !request.recognitionLanguages.isEmpty else { throw CaptureFailure.onDeviceUnavailable }
            request.automaticallyDetectsLanguage = true
            try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
            try Task.checkCancellation()
            let raw = request.results ?? []
            let positions = raw.map { CaptureTextPosition(midY: Double($0.boundingBox.midY), minX: Double($0.boundingBox.minX)) }
            let observations = CaptureReadingOrder.indices(positions).map { raw[$0] }
            guard observations.count <= CaptureLimits.lines else { throw CaptureFailure.inputTooLarge }
            let lines = observations.compactMap { $0.topCandidates(1).first }
            let text = lines.map(\.string).joined(separator: "\n")
            try CaptureLimits.validate(text)
            guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { throw CaptureFailure.noText }
            let preview = NSMutableData()
            guard let destination = CGImageDestinationCreateWithData(preview, UTType.jpeg.identifier as CFString, 1, nil) else { throw CaptureFailure.imageUnavailable }
            CGImageDestinationAddImage(destination, image, [kCGImageDestinationLossyCompressionQuality: 0.8] as CFDictionary)
            guard CGImageDestinationFinalize(destination) else { throw CaptureFailure.imageUnavailable }
            return CaptureEvidence(text: text, source: .photoOCR, uncertainLines: lines.filter { $0.confidence < 0.7 }.map(\.string),
                sourceImageData: data, previewImageData: preview as Data)
        }
        return try await withTaskCancellationHandler(operation: { try await work.value }, onCancel: {
            cancellation.cancel(); work.cancel()
        })
    }
}

/// Synchronizes cancellation with creation of the local Vision request.
private final class OCRRequestCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func install(_ request: VNRequest) {
        lock.lock(); self.request = request; let cancelled = self.cancelled; lock.unlock()
        if cancelled { request.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let request = self.request; lock.unlock()
        request?.cancel()
    }
}
