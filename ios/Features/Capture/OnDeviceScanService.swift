import Foundation
import Vision
import ImageIO
import CoreML

struct OnDeviceScanService: LocalScanService {
    func scan(_ data: Data) async throws -> ScannedSource {
        let cancellation = ScanVisionCancellation()
        let task = Task.detached(priority: .userInitiated) {
            try Task.checkCancellation()
            let jpeg = try ScanImageNormalizer.normalize(data)
            // Some supported runtimes cannot create the newer detector's inference
            // context, or return no observations for readable codes. Try the current
            // detector first, then at most one supported revision-2 pass. Both paths
            // remain local identifier proposals requiring the same manual match.
            var revisions = [VNDetectBarcodesRequest.defaultRevision]
            if !revisions.contains(VNDetectBarcodesRequestRevision2),
               VNDetectBarcodesRequest.supportedRevisions.contains(VNDetectBarcodesRequestRevision2) {
                revisions.append(VNDetectBarcodesRequestRevision2)
            }
            var codes: [CapturedBarcode] = []
            for revision in revisions {
                try Task.checkCancellation()
                let request = VNDetectBarcodesRequest()
                request.revision = revision
                request.symbologies = [.ean8, .ean13, .upce, .code128, .qr, .dataMatrix]
                if revision == VNDetectBarcodesRequestRevision2 {
                    // Use a supported CPU device for the compatibility pass rather
                    // than retrying the same unavailable accelerated inference path.
                    if let stages = try? request.supportedComputeStageDevices {
                        for (stage, devices) in stages {
                            if let cpu = devices.first(where: { if case .cpu = $0 { return true }; return false }) {
                                request.setComputeDevice(cpu, for: stage)
                            }
                        }
                    }
                }
                cancellation.install(request)
                try Task.checkCancellation()
                do { try VNImageRequestHandler(data: jpeg, options: [:]).perform([request]) }
                catch { try Task.checkCancellation(); continue }
                try Task.checkCancellation()
                codes = (request.results ?? []).compactMap { value -> CapturedBarcode? in
                    guard let text = value.payloadStringValue else { return nil }
                    let code = CapturedBarcode(symbology: value.symbology.rawValue, value: text)
                    return (try? code.validate()) == nil ? nil : code
                }
                if !codes.isEmpty { break }
            }
            var seen = Set<String>()
            let unique = Array(codes.filter { seen.insert($0.id).inserted }.prefix(16))
            let evidence: CaptureEvidence?
            do { evidence = try await OnDeviceTextCapture().recognize(jpeg) }
            catch is CancellationError { throw CancellationError() }
            catch { evidence = nil } // The image/code remains reviewable, with typing always available.
            try Task.checkCancellation()
            let text = evidence?.text ?? ""
            try ScanLimits.text(text)
            return ScannedSource(originalText: text, uncertainLines: evidence?.uncertainLines ?? [], originalImageData: data,
                referenceJPEG: jpeg, barcodes: unique)
        }
        return try await withTaskCancellationHandler(operation: { try await task.value }, onCancel: { cancellation.cancel(); task.cancel() })
    }
}
private final class ScanVisionCancellation: @unchecked Sendable {
    private let lock = NSLock()
    private var request: VNRequest?
    private var cancelled = false
    func install(_ value: VNRequest) {
        lock.lock(); request = value; let stop = cancelled; lock.unlock()
        if stop { value.cancel() }
    }
    func cancel() {
        lock.lock(); cancelled = true; let value = request; lock.unlock(); value?.cancel()
    }
}
