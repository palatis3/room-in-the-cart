import SwiftUI
import Vision
import VisionKit

struct LivePackageButton: View {
    let authorized: () -> Bool
    let receive: (CapturedBarcode) -> Void
    @Environment(\.scenePhase) private var scene
    @State private var scanning = false
    @State private var status: String?

    var body: some View {
        Button {
            Task {
                guard authorized(), DataScannerViewController.isSupported else { unavailable(); return }
                do {
                    try await CameraCapturePermission.request()
                    guard authorized(), DataScannerViewController.isAvailable else { unavailable(); return }
                    status = nil; scanning = true
                } catch { unavailable() }
            }
        } label: { Label(pantryText("Scan a live barcode"), systemImage: "barcode.viewfinder").frame(minHeight: 44) }
        .accessibilityIdentifier("productBatch.live")
        .fullScreenCover(isPresented: $scanning) {
            NavigationStack {
                if authorized(), scene == .active {
                    PackageCamera { code in
                        guard scanning, authorized() else { return }
                        scanning = false
                        if let code { receive(code) } else { unavailable() }
                    }
                    .navigationTitle(pantryText("Scan a live barcode"))
                    .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { scanning = false } } }
                }
            }
        }
        .onChange(of: scene) { _, phase in if phase == .background { scanning = false } }
        .onChange(of: authorized()) { _, allowed in if !allowed { scanning = false } }
        if let status { Text(status).foregroundStyle(Theme.secondary) }
    }
    private func unavailable() {
        scanning = false
        status = pantryText("Live scanning is unavailable. Choose a photo or type the code.")
    }
}

private struct PackageCamera: UIViewControllerRepresentable {
    let finished: (CapturedBarcode?) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(finished) }
    func makeUIViewController(context: Context) -> DataScannerViewController {
        let types: [VNBarcodeSymbology] = [.ean8, .ean13, .upce, .code128, .qr, .dataMatrix, .gs1DataBarExpanded]
        let controller = DataScannerViewController(recognizedDataTypes: [.barcode(symbologies: types)], qualityLevel: .balanced,
            recognizesMultipleItems: false, isHighFrameRateTrackingEnabled: false, isHighlightingEnabled: true)
        controller.delegate = context.coordinator
        return controller
    }
    func updateUIViewController(_ controller: DataScannerViewController, context: Context) {
        guard !controller.isScanning, !context.coordinator.resolved else { return }
        do { try controller.startScanning() } catch { Task { @MainActor in context.coordinator.finish(nil) } }
    }
    static func dismantleUIViewController(_ controller: DataScannerViewController, coordinator: Coordinator) {
        controller.stopScanning()
        controller.delegate = nil
    }
    @MainActor final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let finished: (CapturedBarcode?) -> Void
        private(set) var resolved = false
        init(_ finished: @escaping (CapturedBarcode?) -> Void) { self.finished = finished }
        func finish(_ code: CapturedBarcode?) {
            guard !resolved else { return }
            resolved = true
            finished(code)
        }
        func dataScanner(_ dataScanner: DataScannerViewController, didAdd addedItems: [RecognizedItem], allItems: [RecognizedItem]) {
            for item in addedItems {
                guard case .barcode(let barcode) = item, let raw = barcode.payloadStringValue else { continue }
                let code = CapturedBarcode(symbology: barcode.observation.symbology.rawValue, value: raw,
                                           isGS1: barcode.observation.isGS1DataCarrier ? true : nil)
                if (try? code.validate()) != nil { dataScanner.stopScanning(); finish(code); return }
            }
        }
        func dataScanner(_ dataScanner: DataScannerViewController, becameUnavailableWithError error: DataScannerViewController.ScanningUnavailable) {
            finish(nil)
        }
    }
}
