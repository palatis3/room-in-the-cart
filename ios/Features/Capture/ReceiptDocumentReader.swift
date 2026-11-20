import CoreDomain
import CoreTransferable
import CryptoKit
import DeviceSurfaces
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ReceiptDocumentKind: String, Codable, Sendable { case pdf, image, text }
enum ReceiptDocumentFailure: Error, Equatable, Sendable { case size, pages, pixels, characters, lineLimit, selection, locked, unsupported, unavailable, timeout, duplicateSection }

enum ReceiptPhotoSelection: Sendable, Transferable {
    case selected(ReceiptDocumentBytes)
    case rejected(ReceiptDocumentFailure)

    static var transferRepresentation: some TransferRepresentation {
        FileRepresentation(importedContentType: .image) { received in
            do { return Self.selected(try ReceiptDocumentBytes.read(received.file, kind: .image)) }
            catch let failure as ReceiptDocumentFailure { return Self.rejected(failure) }
        }
    }

    var bytes: ReceiptDocumentBytes {
        get throws {
            switch self { case .selected(let input): return input; case .rejected(let failure): throw failure }
        }
    }
}

struct ReceiptDocumentBytes: Sendable {
    static let maximumBytes = 10_000_000
    let data: Data
    let kind: ReceiptDocumentKind
    var unmarkedUTF16: UnmarkedUTF16?

    static func read(_ url: URL, kind: ReceiptDocumentKind, type: UTType? = nil) throws -> Self {
        do {
            let bytes = try readRegularFile(at: url, maximumBytes: maximumBytes)
            return Self(data: bytes, kind: kind, unmarkedUTF16: kind == .text ? UnmarkedUTF16(data: bytes, type: type) : nil)
        }
        catch SurfaceError.capacity { throw ReceiptDocumentFailure.size }
        catch { throw ReceiptDocumentFailure.unavailable }
    }

    static func shared(_ data: Data, descriptor: SharedReceiptDescriptor) -> Self {
        let kind: ReceiptDocumentKind
        switch descriptor.kind { case .pdf: kind = .pdf; case .image: kind = .image; case .text: kind = .text }
        return Self(data: data, kind: kind, unmarkedUTF16: descriptor.unmarkedUTF16)
    }

    static func picked(_ url: URL) async throws -> Self {
        guard url.isFileURL else { throw ReceiptDocumentFailure.unavailable }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let intent = NSFileAccessIntent.readingIntent(with: url, options: .withoutChanges)
        let queue = OperationQueue()
        queue.qualityOfService = .userInitiated
        return try await withCheckedThrowingContinuation { continuation in
            NSFileCoordinator().coordinate(with: [intent], queue: queue) { error in
                guard error == nil else { continuation.resume(throwing: ReceiptDocumentFailure.unavailable); return }
                continuation.resume(with: Result {
                    let type = (try? intent.url.resourceValues(forKeys: [.contentTypeKey]))?.contentType ?? UTType(filenameExtension: url.pathExtension)
                    let kind: ReceiptDocumentKind
                    if type?.conforms(to: .pdf) == true { kind = .pdf }
                    else if type?.conforms(to: .image) == true { kind = .image }
                    else if type?.conforms(to: .plainText) == true { kind = .text }
                    else { throw ReceiptDocumentFailure.unsupported }
                    return try read(intent.url, kind: kind, type: type)
                })
            }
        }
    }
}

struct ReceiptDocumentPage: Identifiable, Sendable {
    let id: Int
    let method: ReceiptAcquisition.DocumentLine.Method
    struct Line: Identifiable, Sendable {
        let id: Int
        let text: String
        var uncertain = false
    }
    let lines: [Line]
    var skipped: ReceiptDocumentFailure? = nil
}

struct ExtractedReceiptDocument: Sendable {
    let digest: Data
    let pages: [ReceiptDocumentPage]
    var firstSectionDigest: Data? = nil

    struct Selection: Hashable, Identifiable {
        let page: Int
        let line: Int
        var id: Self { self }
    }
    func source(target: CaptureTarget, merchant: String, stage: ReceiptAcquisition.DocumentLine.Stage,
                selection: Set<Selection>, at date: Date) throws -> SourceMediaRecord {
        guard (1...200).contains(selection.count) else { throw ReceiptDocumentFailure.selection }
        let id = ReceiptAcquisition.identity(["document", digest.base64EncodedString()])
        var rows: [ScanReceiptLine] = []
        for page in pages {
            for line in page.lines where selection.contains(.init(page: page.id, line: line.id)) {
                let place = ReceiptAcquisition.DocumentLine(method: page.method, stage: stage, page: page.id, line: line.id)
                var row = ScanReceiptLine(id: ReceiptAcquisition.lineID(receiptID: id, ordinal: place.ordinal), originalText: line.text)
                if line.uncertain { row.uncertainOCR = true }
                row.documentLine = place
                rows.append(row)
            }
        }
        guard rows.count == selection.count else { throw ReceiptDocumentFailure.selection }
        var source = SourceMediaRecord(id: id, target: target, originalText: rows.map(\.originalText).joined(separator: "\n"),
            reviewedLabel: merchant, imageJPEG: nil, barcode: nil, receiptLines: rows, capturedAt: date)
        // Extraction can change row positions even when the file bytes are identical.
        // Hash the entire coordinate map locally so picking a different subset preserves its identity.
        var coordinates = ["receipt-file-layout-v1", target.workspaceID.uuidString]
        if firstSectionDigest != nil { coordinates += ["segmented-photos", digest.base64EncodedString()] }
        for page in pages {
            coordinates += [String(page.id), page.method.rawValue, String(page.lines.count)]
            for line in page.lines { coordinates += [String(line.id), line.text] }
        }
        source.documentLayoutID = ReceiptAcquisition.identity(coordinates)
        source.documentDigest = digest
        source.firstSectionDigest = firstSectionDigest
        do { try source.validate() } catch { throw ReceiptDocumentFailure.selection }
        return source
    }
}

struct ReceiptDocumentReader: Sendable {
    typealias Recognize = @Sendable (Data) async throws -> String
    private var recognize: @Sendable (Data) async throws -> (String, Set<String>) = { data in
        let reading = try await OnDeviceTextCapture().recognize(data)
        return (reading.text, Set(reading.uncertainLines))
    }
    init() {}
    init(recognize: @escaping Recognize) {
        self.recognize = { data in (try await recognize(data), []) }
    }

    func extract(_ input: ReceiptDocumentBytes) async throws -> ExtractedReceiptDocument {
        guard !input.data.isEmpty, input.data.count <= ReceiptDocumentBytes.maximumBytes else { throw ReceiptDocumentFailure.size }
        return try await withThrowingTaskGroup(of: ExtractedReceiptDocument.self) { group in
            group.addTask {
                let pages = try await readPages(input)
                try Task.checkCancellation()
                return ExtractedReceiptDocument(digest: Data(SHA256.hash(data: input.data)), pages: pages)
            }
            group.addTask {
                try await Task.sleep(for: .seconds(30))
                throw ReceiptDocumentFailure.timeout
            }
            defer { group.cancelAll() }
            guard let first = try await group.next() else { throw ReceiptDocumentFailure.unavailable }
            return first
        }
    }

    /// Only called for an already-reviewed file, while its source inspector is visible.
    static func originalPage(_ input: ReceiptDocumentBytes, pageNumber: Int) async -> Data? {
        guard !Task.isCancelled, (1...20).contains(pageNumber), input.data.count <= ReceiptDocumentBytes.maximumBytes else { return nil }
        switch input.kind {
        case .text: return nil
        case .image: return pageNumber == 1 ? ReceiptSectionDraft.preview(input.data) : nil
        case .pdf:
            guard let pdf = PDFDocument(data: input.data), !pdf.isLocked, (1...20).contains(pdf.pageCount),
                  pageNumber <= pdf.pageCount, let page = pdf.page(at: pageNumber - 1) else { return nil }
            return try? raster(page)
        }
    }

    private func readPages(_ input: ReceiptDocumentBytes) async throws -> [ReceiptDocumentPage] {
        var characterCount = 0
        func page(_ number: Int, method: ReceiptAcquisition.DocumentLine.Method, text: String, uncertain: Set<String> = []) throws -> ReceiptDocumentPage {
            characterCount += text.count
            guard characterCount <= 100_000, !text.contains("\0") else { throw ReceiptDocumentFailure.characters }
            var lines: [ReceiptDocumentPage.Line] = []
            for (index, row) in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                guard !row.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                guard index < 200 else { throw ReceiptDocumentFailure.lineLimit }
                lines.append(.init(id: index + 1, text: String(row), uncertain: uncertain.contains(String(row))))
            }
            return .init(id: number, method: method, lines: lines)
        }
        switch input.kind {
        case .text:
            guard let text = decodePlainTextFile(input.data, unmarkedUTF16: input.unmarkedUTF16) else { throw ReceiptDocumentFailure.unsupported }
            return [try page(1, method: .textFile, text: text)]
        case .image:
            try Self.checkPixels(input.data)
            let jpeg = try ScanImageNormalizer.normalize(input.data)
            let (text, uncertain) = try await readImage(jpeg)
            return [try page(1, method: .imageOCR, text: text, uncertain: uncertain)]
        case .pdf:
            guard let pdf = PDFDocument(data: input.data) else { throw ReceiptDocumentFailure.unsupported }
            guard !pdf.isLocked else { throw ReceiptDocumentFailure.locked }
            guard (1...20).contains(pdf.pageCount) else { throw ReceiptDocumentFailure.pages }
            var result: [ReceiptDocumentPage] = []
            for index in 0..<pdf.pageCount {
                try Task.checkCancellation()
                guard let original = pdf.page(at: index) else { throw ReceiptDocumentFailure.unavailable }
                guard original.numberOfCharacters <= 100_000 - characterCount else { throw ReceiptDocumentFailure.characters }
                let text = original.string ?? ""
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(try page(index + 1, method: .pdfText, text: text))
                } else {
                    do {
                        let bytes = try autoreleasepool { try Self.raster(original) }
                        let (text, uncertain) = try await readImage(bytes)
                        result.append(try page(index + 1, method: .pdfOCR, text: text, uncertain: uncertain))
                    } catch is CancellationError { throw CancellationError() }
                    catch let failure as ReceiptDocumentFailure {
                        switch failure {
                        case .pixels, .unsupported, .unavailable, .lineLimit:
                            result.append(.init(id: index + 1, method: .pdfOCR, lines: [], skipped: failure))
                        default: throw failure
                        }
                    } catch {
                        try Task.checkCancellation()
                        result.append(.init(id: index + 1, method: .pdfOCR, lines: [], skipped: .unavailable))
                    }
                }
            }
            return result
        }
    }

    private func readImage(_ data: Data) async throws -> (String, Set<String>) {
        do { return try await recognize(data) }
        catch CaptureFailure.noText { return ("", []) }
        catch CaptureFailure.inputTooLarge { throw ReceiptDocumentFailure.lineLimit }
    }

    private static func checkPixels(_ data: Data) throws {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1,
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let w = properties[kCGImagePropertyPixelWidth] as? Int, let h = properties[kCGImagePropertyPixelHeight] as? Int,
              w > 0, h > 0 else { throw ReceiptDocumentFailure.unsupported }
        guard w <= 25_000_000 / h else { throw ReceiptDocumentFailure.pixels }
    }

    private static func raster(_ page: PDFPage) throws -> Data {
        let bounds = page.bounds(for: .cropBox)
        guard bounds.width.isFinite, bounds.height.isFinite, bounds.width > 0, bounds.height > 0 else { throw ReceiptDocumentFailure.unsupported }
        let scale = min(2, 2200 / max(bounds.width, bounds.height))
        let w = max(1, Int((bounds.width * scale).rounded(.up))), h = max(1, Int((bounds.height * scale).rounded(.up)))
        guard w <= 25_000_000 / h, let ref = page.pageRef,
              let context = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw ReceiptDocumentFailure.pixels }
        // Reject oversized embedded image resources before asking Quartz to rasterize
        // a scanned page. A small destination alone cannot bound image decoding.
        try checkRasterResources(ref)
        let destination = CGRect(x: 0, y: 0, width: w, height: h)
        context.setFillColor(gray: 1, alpha: 1)
        context.fill(destination)
        context.concatenate(ref.getDrawingTransform(.cropBox, rect: destination, rotate: 0, preserveAspectRatio: true))
        context.drawPDFPage(ref)
        guard let image = context.makeImage() else { throw ReceiptDocumentFailure.unavailable }
        let bytes = NSMutableData()
        guard let output = CGImageDestinationCreateWithData(bytes, UTType.jpeg.identifier as CFString, 1, nil) else { throw ReceiptDocumentFailure.unavailable }
        CGImageDestinationAddImage(output, image, [kCGImageDestinationLossyCompressionQuality: 0.85] as CFDictionary)
        guard CGImageDestinationFinalize(output) else { throw ReceiptDocumentFailure.unavailable }
        return bytes as Data
    }

    private static func checkRasterResources(_ page: CGPDFPage) throws {
        let content = CGPDFContentStreamCreateWithPage(page)
        defer { CGPDFContentStreamRelease(content) }
        guard let operators = CGPDFOperatorTableCreate() else { throw ReceiptDocumentFailure.unsupported }
        defer { CGPDFOperatorTableRelease(operators) }
        // Inline images lack an independent ImageIO metadata boundary. Ask the
        // person for an image export for these and other complex scanned pages.
        CGPDFOperatorTableSetCallback(operators, "EI") { _, info in
            info?.assumingMemoryBound(to: Bool.self).pointee = true
        }
        var inlineImage = false
        try withUnsafeMutablePointer(to: &inlineImage) { flag in
            let scanner = CGPDFScannerCreate(content, operators, flag)
            defer { CGPDFScannerRelease(scanner) }
            guard CGPDFScannerScan(scanner), !flag.pointee else {
                throw ReceiptDocumentFailure.unsupported
            }
        }
        var dictionary = page.dictionary, resources: CGPDFDictionaryRef?
        for _ in 0..<24 {
            guard let current = dictionary else { break }
            if CGPDFDictionaryGetDictionary(current, "Resources", &resources) { break }
            var parent: CGPDFDictionaryRef?
            guard CGPDFDictionaryGetDictionary(current, "Parent", &parent) else { break }
            dictionary = parent
        }
        guard let resources else { return }
        var unsupported: CGPDFDictionaryRef?
        if CGPDFDictionaryGetDictionary(resources, "Pattern", &unsupported) { throw ReceiptDocumentFailure.unsupported }
        var xobjects: CGPDFDictionaryRef?
        guard CGPDFDictionaryGetDictionary(resources, "XObject", &xobjects), let xobjects else { return }
        guard CGPDFDictionaryGetCount(xobjects) <= 100 else { throw ReceiptDocumentFailure.pixels }
        var remaining = 25_000_000
        var error: ReceiptDocumentFailure?
        CGPDFDictionaryApplyBlock(xobjects, { _, object, _ in
            var stream: CGPDFStreamRef?, type: UnsafePointer<CChar>?
            guard CGPDFObjectGetValue(object, .stream, &stream), let stream, let metadata = CGPDFStreamGetDictionary(stream),
                  CGPDFDictionaryGetName(metadata, "Subtype", &type), let type, String(cString: type) == "Image" else {
                error = .unsupported; return false
            }
            var width: CGPDFInteger = 0, height: CGPDFInteger = 0
            guard CGPDFDictionaryGetInteger(metadata, "Width", &width), CGPDFDictionaryGetInteger(metadata, "Height", &height),
                  height > 0, width > 0, width <= remaining / height else { error = .pixels; return false }
            remaining -= width * height
            for mask in ["Mask", "SMask"] {
                var maskStream: CGPDFStreamRef?
                if CGPDFDictionaryGetStream(metadata, mask, &maskStream), let maskStream {
                    guard let maskInfo = CGPDFStreamGetDictionary(maskStream),
                          CGPDFDictionaryGetInteger(maskInfo, "Width", &width), CGPDFDictionaryGetInteger(maskInfo, "Height", &height),
                          height > 0, width > 0, width <= remaining / height else { error = .pixels; return false }
                    remaining -= width * height
                }
            }
            return true
        }, nil)
        if let error { throw error }
    }
}

/// Page/line coordinates always refer to the complete OCR result. Choosing to omit
/// a repeated edge never renumbers a purchased line or changes the source identity.
struct ReceiptSectionDraft {
    static let maximumSections = 6
    static let maximumBytes = 30_000_000
    struct Section {
        let digest: Data
        let byteCount: Int
        let page: ReceiptDocumentPage
        let preview: Data?
    }
    private(set) var sections: [Section] = []
    private(set) var omittedPrefixes: [Int: Int] = [:]

    mutating func put(_ document: ExtractedReceiptDocument, bytes: Int, preview: Data?, at index: Int) throws {
        guard (0...sections.count).contains(index), index < Self.maximumSections,
              (1...ReceiptDocumentBytes.maximumBytes).contains(bytes),
              document.pages.count == 1, let page = document.pages.first, page.method == .imageOCR,
              !page.lines.isEmpty else { throw ReceiptDocumentFailure.selection }
        guard !sections.enumerated().contains(where: { $0.offset != index && $0.element.digest == document.digest }) else {
            throw ReceiptDocumentFailure.duplicateSection
        }
        var next = sections
        let part = Section(digest: document.digest, byteCount: bytes, page: page, preview: preview)
        if index == next.count { next.append(part) } else { next[index] = part }
        guard next.reduce(0, { $0 + $1.byteCount }) <= Self.maximumBytes,
              next.flatMap({ $0.page.lines }).reduce(0, { $0 + $1.text.utf8.count }) <= 100_000 else {
            throw ReceiptDocumentFailure.size
        }
        sections = next
        omittedPrefixes.removeValue(forKey: index)
        omittedPrefixes.removeValue(forKey: index + 1)
    }

    func likelyOverlaps(at index: Int) -> [Int] {
        guard index > 0, sections.indices.contains(index) else { return [] }
        func key(_ line: ReceiptDocumentPage.Line) -> String {
            line.text.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let previous = sections[index - 1].page.lines.map(key)
        let next = sections[index].page.lines.map(key)
        return (1...min(previous.count, next.count)).filter { previous.suffix($0).elementsEqual(next.prefix($0)) }
    }

    mutating func resolve(at index: Int, omitting count: Int) {
        guard index > 0, sections.indices.contains(index), count == 0 || likelyOverlaps(at: index).contains(count) else { return }
        omittedPrefixes[index] = count
    }

    var hasUnresolvedOverlap: Bool {
        sections.indices.contains { !likelyOverlaps(at: $0).isEmpty && omittedPrefixes[$0] == nil }
    }

    func review() throws -> (document: ExtractedReceiptDocument, omitted: Set<ExtractedReceiptDocument.Selection>) {
        guard let first = sections.first, !hasUnresolvedOverlap else { throw ReceiptDocumentFailure.selection }
        var bytes = Data("receipt-sections-v1".utf8)
        var omitted = Set<ExtractedReceiptDocument.Selection>()
        let pages = sections.enumerated().map { index, section in
            bytes.append(section.digest)
            for line in section.page.lines.prefix(omittedPrefixes[index] ?? 0) {
                omitted.insert(.init(page: index + 1, line: line.id))
            }
            return ReceiptDocumentPage(id: index + 1, method: .imageOCR, lines: section.page.lines)
        }
        let digest = sections.count == 1 ? first.digest : Data(SHA256.hash(data: bytes))
        return (.init(digest: digest, pages: pages, firstSectionDigest: sections.count > 1 ? first.digest : nil), omitted)
    }

    static func preview(_ data: Data) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 1100] as CFDictionary) else { return nil }
        let output = NSMutableData()
        guard let writer = CGImageDestinationCreateWithData(output, UTType.jpeg.identifier as CFString, 1, nil) else { return nil }
        CGImageDestinationAddImage(writer, image, [kCGImageDestinationLossyCompressionQuality: 0.6] as CFDictionary)
        guard CGImageDestinationFinalize(writer), output.length <= 550_000 else { return nil }
        return output as Data
    }
}
