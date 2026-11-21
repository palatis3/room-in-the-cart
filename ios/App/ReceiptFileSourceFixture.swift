#if DEBUG && targetEnvironment(simulator)
import DeviceSurfaces
import Photos
import SwiftUI
import UniformTypeIdentifiers

/// Sender for journeys through the system document exporter and Share sheet.
struct ReceiptFileSourceFixture: View {
    @State private var exporting = false
    @State private var saved = false
    @State private var pdfDocument: SamplePDF?
    @State private var shareToken: String?
    @State private var pdfURL: URL?
    @State private var groceryTextURL: URL?
    @State private var photo: UIImage?
    @State private var photoResult = ""
    static let name = "Room Market Fixture Receipt"

    private var exportName: String {
        guard let token = ProcessInfo.processInfo.environment["RITC_RECEIPT_EXPORT_ID"],
              let run = UUID(uuidString: token) else { return Self.name }
        return Self.name + " " + run.uuidString
    }

    var body: some View {
        VStack {
            if let groceryTextURL {
                ShareLink(item: groceryTextURL) { Text(verbatim: "Share sample grocery text file") }
            }
            if let pdfURL {
                ShareLink(item: pdfURL) { Text(verbatim: "Share sample receipt PDF") }
                Button {
                    saved = false
                    exporting = true
                } label: { Text(verbatim: "Export sample receipt PDF") }
            }
            if let photo {
                Button { Task { await saveFixturePhoto(photo) } } label: {
                    Text(verbatim: "Add sample receipt to simulator Photos")
                }
                if !photoResult.isEmpty {
                    Text(verbatim: photoResult).accessibilityIdentifier("fixture.receipt.photoResult")
                }
            }
            if let shareToken { Text(verbatim: shareToken).accessibilityIdentifier("fixture.receipt.shareToken") }
            if saved { Text(verbatim: "Sample receipt exported").accessibilityIdentifier("fixture.receipt.exported") }
        }
        .task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-sender", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            if ProcessInfo.processInfo.arguments.contains("--shopping-list-text-file") {
                let list = root.appendingPathComponent("Shopping list.txt")
                do {
                    try "2 cajas de arroz\nCafé".write(to: list, atomically: true, encoding: .utf8)
                    groceryTextURL = list
                } catch { groceryTextURL = nil }
            }
            let bounds = CGRect(x: 0, y: 0, width: 400, height: 440)
            func draw() {
                UIColor.white.setFill(); UIRectFill(bounds)
                if ProcessInfo.processInfo.arguments.contains("--checkout-crop-photo") {
                    ("Subtotal $12.50" as NSString).draw(at: .init(x: 40, y: 174), withAttributes: [
                        .font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black])
                    return
                }
                for (i, text) in ["OATS", "SERVICE FEE"].enumerated() {
                    (text as NSString).draw(at: .init(x: 40, y: 60 + 70 * i), withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black])
                }
            }
            let pdf = root.appendingPathComponent(Self.name + ".pdf")
            let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in context.beginPage(); draw() }
            if ProcessInfo.processInfo.arguments.contains("--receipt-share-test-sender") {
                shareToken = try? ReceiptShareSystemFixture.register(data, now: Date())
            }
            try? data.write(to: pdf, options: .atomic)
            let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in draw() }
            pdfDocument = SamplePDF(data)
            pdfURL = pdf; photo = image
        }
        .fileExporter(isPresented: $exporting, document: pdfDocument,
                      contentType: .pdf, defaultFilename: exportName) { result in
            guard case .success(let destination) = result, let pdfURL, let pdfDocument,
                  destination.standardizedFileURL != pdfURL.standardizedFileURL else { return }
            let scoped = destination.startAccessingSecurityScopedResource()
            defer { if scoped { destination.stopAccessingSecurityScopedResource() } }
            saved = (try? Data(contentsOf: pdfURL)) == pdfDocument.bytes &&
                (try? Data(contentsOf: destination)) == pdfDocument.bytes
        }
    }

    @MainActor private func saveFixturePhoto(_ photo: UIImage) async {
        guard await PHPhotoLibrary.requestAuthorization(for: .addOnly) == .authorized,
              let png = photo.pngData() else {
            photoResult = "Test photo unavailable"
            return
        }
        do {
            try await PHPhotoLibrary.shared().performChanges {
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = "Room Market Fixture Receipt.png"
                PHAssetCreationRequest.forAsset().addResource(with: .photo, data: png, options: options)
            }
            photoResult = "Test photo saved"
        } catch {
            photoResult = "Test photo unavailable"
        }
    }

    private struct SamplePDF: FileDocument {
        static let readableContentTypes: [UTType] = [.pdf]
        let bytes: Data
        init(_ bytes: Data) { self.bytes = bytes }
        init(configuration: ReadConfiguration) throws {
            guard let bytes = configuration.file.regularFileContents else { throw CocoaError(.fileReadCorruptFile) }
            self.bytes = bytes
        }
        func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: bytes) }
    }
}
#endif
