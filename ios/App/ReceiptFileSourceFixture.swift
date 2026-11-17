#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UniformTypeIdentifiers

/// Sender for journeys through the system document exporter and Share sheet.
struct ReceiptFileSourceFixture: View {
    @State private var exporting = false
    @State private var saved = false
    @State private var pdfURL: URL?
    @State private var photo: UIImage?
    static let name = "Room Market Fixture Receipt"

    var body: some View {
        VStack {
            if let pdfURL {
                ShareLink(item: pdfURL) { Text(verbatim: "Share sample receipt PDF") }
                Button { exporting = true } label: { Text(verbatim: "Export sample receipt PDF") }
            }
            if let photo {
                let image = Image(uiImage: photo)
                ShareLink(item: image, preview: SharePreview("Sample receipt", image: image)) {
                    Text(verbatim: "Share sample receipt photo")
                }
            }
            if saved { Text(verbatim: "Sample receipt exported").accessibilityIdentifier("fixture.receipt.exported") }
        }
        .task {
            let root = FileManager.default.temporaryDirectory.appendingPathComponent("receipt-sender", isDirectory: true)
            try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            let bounds = CGRect(x: 0, y: 0, width: 400, height: 440)
            func draw() {
                UIColor.white.setFill(); UIRectFill(bounds)
                for (i, text) in ["OATS", "SERVICE FEE"].enumerated() {
                    (text as NSString).draw(at: .init(x: 40, y: 60 + 70 * i), withAttributes: [.font: UIFont.systemFont(ofSize: 30), .foregroundColor: UIColor.black])
                }
            }
            let pdf = root.appendingPathComponent(Self.name + ".pdf")
            let data = UIGraphicsPDFRenderer(bounds: bounds).pdfData { context in context.beginPage(); draw() }
            try? data.write(to: pdf, options: .atomic)
            let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in draw() }
            pdfURL = pdf; photo = image
        }
        .fileExporter(isPresented: $exporting, document: pdfURL.flatMap { try? Data(contentsOf: $0) }.map(SamplePDF.init),
                      contentType: .pdf, defaultFilename: Self.name) { result in
            if case .success = result { saved = true }
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
