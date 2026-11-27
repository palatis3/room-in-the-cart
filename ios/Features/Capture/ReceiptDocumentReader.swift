import CoreDomain
import CoreTransferable
import CryptoKit
import DeviceSurfaces
import Foundation
import ImageIO
import PDFKit
import UniformTypeIdentifiers

enum ReceiptDocumentKind: String, Codable, Sendable { case pdf, image, text }
enum ReceiptDocumentFailure: String, Error, Codable, Sendable { case size, pages, pixels, characters, lineLimit, selection, locked, unsupported, unavailable, timeout, duplicateSection }

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

struct ReceiptDocumentPage: Identifiable, Equatable, Codable, Sendable {
    let id: Int
    let method: ReceiptAcquisition.DocumentLine.Method
    struct Line: Identifiable, Equatable, Codable, Sendable {
        let id: Int
        let text: String
        var uncertain = false
        var bounds: CGRect?
        var wordReadings: [ReceiptWordReading] = []
        var printedItemColumn: String?
    }
    let lines: [Line]
    var skipped: ReceiptDocumentFailure? = nil
}

struct ExtractedReceiptDocument: Equatable, Codable, Sendable {
    let digest: Data
    let pages: [ReceiptDocumentPage]
    var firstSectionDigest: Data? = nil

    struct Selection: Hashable, Identifiable, Codable, Sendable {
        let page: Int
        let line: Int
        var id: Self { self }
    }

    struct PurchaseDateEvidence: Equatable {
        let wording: String
        let position: Selection?
    }

    /// Keep ambiguous wording available for inspection. Only one clear source
    /// position can be offered for inclusion with the shopper's food selection.
    func purchaseDateEvidence(at now: Date, calendar: Calendar = .current) -> PurchaseDateEvidence? {
        let dates = pages.flatMap { page in
            page.lines.filter { ReceiptPrintedDate.looksLikeDate($0.text) }.map {
                (position: Selection(page: page.id, line: $0.id), line: $0)
            }
        }
        let readable = dates.filter { !$0.line.uncertain }
        guard let first = readable.first, readable.allSatisfy({ $0.line.text == first.line.text }) else { return nil }
        let offersDate = dates.count == 1 && pages.allSatisfy { $0.skipped == nil }
            && ReceiptPrintedDate.unique(in: [.init(originalText: first.line.text)], now: now, calendar: calendar) != nil
        return .init(wording: first.line.text, position: offersDate ? first.position : nil)
    }

    struct PrintedPaidTotal: Equatable, Codable, Sendable {
        let wording: String
        let amount: String
    }

    private static let paidTotalLabels = ["TOTAL PAID", "PAID TOTAL", "TOTAL PAGADO", "IMPORTE TOTAL PAGADO"]

    /// Require readable source pages and one explicit paid-total row.
    /// Selection preserves evidence, with payment confirmed later.
    func printedPaidTotal(selected: Set<Selection>, revised: Set<Selection> = []) -> PrintedPaidTotal? {
        guard !pages.isEmpty, pages.allSatisfy({
            $0.skipped == nil && !$0.lines.isEmpty && ($0.method == .imageOCR || $0.method == .pdfOCR)
        }) else { return nil }
        var source: (page: ReceiptDocumentPage, label: ReceiptDocumentPage.Line)?
        for page in pages {
            for line in page.lines {
                let text = line.text.split(whereSeparator: \.isWhitespace).joined(separator: " ").uppercased()
                let label = text.trimmingCharacters(in: .whitespaces.union(CharacterSet(charactersIn: ":")))
                let exact = Self.paidTotalLabels.contains(label)
                guard exact || Self.paidTotalLabels.contains(where: {
                    text.hasPrefix($0 + " ") || text.hasPrefix($0 + ":")
                }) else { continue }
                // Suppress proposals if a second paid total is present, or if a
                // total was merged with ambiguous wording in an OCR observation.
                guard source == nil, exact else { return nil }
                source = (page, line)
            }
        }
        guard let (page, label) = source, !label.uncertain, let labelBox = label.bounds,
              !revised.contains(.init(page: page.id, line: label.id)),
              selected.contains(.init(page: page.id, line: label.id)) else { return nil }
        let neighbors = page.lines.filter { line in
            guard line.id != label.id, let box = line.bounds else { return false }
            return Self.samePrintedRow(labelBox, box)
        }
        guard neighbors.count == 1, let amount = neighbors.first,
              abs(amount.id - label.id) == 1, !amount.uncertain,
              let box = amount.bounds, labelBox.maxX <= box.minX,
              !revised.contains(.init(page: page.id, line: amount.id)),
              selected.contains(.init(page: page.id, line: amount.id)),
              let value = ReceiptPrintedEvidence.standaloneAmount(amount.text) else { return nil }
        return PrintedPaidTotal(wording: amount.text, amount: value)
    }

    /// Keep OCR observations separate. Offer a price only when the image supports
    /// an isolated item/amount pair on one printed row in reading order.
    var amountAssociations: [Selection: Selection] {
        var result: [Selection: Selection] = [:]
        for page in pages where page.method == .imageOCR || page.method == .pdfOCR {
            for (first, second) in zip(page.lines, page.lines.dropFirst()) {
                guard second.id == first.id + 1, !first.uncertain, !second.uncertain,
                      let firstBox = first.bounds, let secondBox = second.bounds else { continue }
                let (item, amount, left, right) = firstBox.minX < secondBox.minX
                    ? (first, second, firstBox, secondBox) : (second, first, secondBox, firstBox)
                guard left.maxX <= right.minX,
                      Self.samePrintedRow(left, right),
                      ReceiptPrintedEvidence.isStandaloneAmount(amount.text),
                      ReceiptPrintedEvidence.canSuggestAmount(for: item.text),
                      !page.lines.contains(where: { other in
                          guard other.id != item.id, other.id != amount.id, let box = other.bounds else { return false }
                          return Self.samePrintedRow(left, box) || Self.samePrintedRow(right, box)
                      })
                else { continue }
                result[.init(page: page.id, line: item.id)] = .init(page: page.id, line: amount.id)
            }
        }
        return result
    }

    /// Expose a named choice for a price printed directly below an item.
    /// These pairs still require a shopper to attach the separate amount.
    func splitAmountAssociations(excluding suggested: [Selection: Selection]) -> [Selection: Selection] {
        let suggestedAmounts = Set(suggested.values)
        var result: [Selection: Selection] = [:]
        for page in pages where page.method == .imageOCR || page.method == .pdfOCR {
            for (item, amount) in zip(page.lines, page.lines.dropFirst()) {
                let itemPosition = Selection(page: page.id, line: item.id)
                let amountPosition = Selection(page: page.id, line: amount.id)
                guard amount.id == item.id + 1, !item.uncertain, !amount.uncertain,
                      suggested[itemPosition] == nil, !suggestedAmounts.contains(amountPosition),
                      let itemBox = item.bounds, let amountBox = amount.bounds,
                      itemBox.maxX <= amountBox.minX, itemBox.minY >= amountBox.maxY,
                      itemBox.midY - amountBox.midY <= max(itemBox.height, amountBox.height) * 2,
                      ReceiptPrintedEvidence.canSuggestAmount(for: item.text),
                      ReceiptPrintedEvidence.isStandaloneAmount(amount.text),
                      !page.lines.contains(where: { other in
                          guard other.id != item.id, other.id != amount.id, let box = other.bounds else { return false }
                          return Self.samePrintedRow(itemBox, box) || Self.samePrintedRow(amountBox, box)
                      })
                else { continue }
                result[itemPosition] = amountPosition
            }
        }
        return result
    }

    private static func samePrintedRow(_ first: CGRect, _ second: CGRect) -> Bool {
        let minHeight = min(first.height, second.height), maxHeight = max(first.height, second.height)
        let overlap = min(first.maxY, second.maxY) - max(first.minY, second.minY)
        return minHeight > 0 && maxHeight <= 2 * minHeight && overlap >= minHeight * 0.65
            && abs(first.midY - second.midY) <= minHeight * 0.35
    }

    /// Reconstruct observed columns in physical order. A bare count needs a second
    /// merchandise row with matching count and currency columns to establish the layout.
    /// Keep the original item position so subsequent receipt lines retain their IDs.
    static func groupingQuantityPriceColumns(_ lines: [ReceiptDocumentPage.Line],
                                             photo: () -> CGImage? = { nil }) -> [ReceiptDocumentPage.Line] {
        lazy var normalizedPhoto = photo()
        guard lines.count >= 2, lines.allSatisfy({ $0.bounds?.isEmpty == false }) else { return lines }
        var rateRows: [[ReceiptDocumentPage.Line]] = []
        var countRows: [[ReceiptDocumentPage.Line]] = []
        for item in lines {
            guard let box = item.bounds, item.text.first?.isLetter == true else { continue }
            let neighbors = lines.filter { line in
                guard let other = line.bounds else { return false }
                // Also inspect partial overlaps: a second offset column or a row
                // between baselines makes reconstruction ambiguous.
                return min(box.maxY, other.maxY) - max(box.minY, other.minY) > min(box.height, other.height) * 0.20
            }.sorted { ($0.bounds?.minX ?? 0) < ($1.bounds?.minX ?? 0) }
            guard (2...4).contains(neighbors.count), neighbors.first?.id == item.id,
                  neighbors.allSatisfy({ $0.bounds.map { samePrintedRow(box, $0) } == true }),
                  zip(neighbors, neighbors.dropFirst()).allSatisfy({ left, right in
                      guard let lhs = left.bounds, let rhs = right.bounds else { return false }
                      return samePrintedRow(lhs, rhs)
                  }) else { continue }
            let separate = zip(neighbors, neighbors.dropFirst()).allSatisfy { left, right in
                guard let lhs = left.bounds, let rhs = right.bounds else { return false }
                return lhs.maxX <= rhs.minX
            }
            let wording = neighbors.map(\.text).joined(separator: " ")
            guard wording.utf8.count <= 2048 else { continue }
            // Vision sometimes includes the count and rate in the name observation.
            // In that layout the only other cell must be the complete printed total.
            if let fields = ReceiptPrintedEvidence.printedQuantityPriceColumns(wording),
               fields.item == item.text || (neighbors.count == 2 && fields.total == neighbors[1].text) {
                if !separate {
                    // OCR can pad the name and rate into the same blank gutter. Only
                    // the original photo can establish separation when boxes overlap.
                    guard neighbors.count == 3, fields.item == item.text, fields.total == neighbors[2].text,
                          !neighbors.contains(where: \.uncertain), let rate = neighbors[1].bounds,
                          let total = neighbors[2].bounds, rate.maxX <= total.minX,
                          let photo = normalizedPhoto, printedGutterSeparates(box, rate, in: photo) else { continue }
                }
                rateRows.append(neighbors)
            } else if separate, neighbors.count == 3, !neighbors.contains(where: \.uncertain),
                      ReceiptPrintedEvidence.isPlainColumnItem(item.text),
                      ReceiptPrintedEvidence.isBareCountColumn(neighbors[1].text),
                      let countBox = neighbors[1].bounds, let amountBox = neighbors[2].bounds,
                      countBox.minX - box.maxX >= box.height,
                      amountBox.minX - countBox.maxX >= box.height,
                      ReceiptPrintedEvidence.isStandaloneAmount(neighbors[2].text) {
                countRows.append(neighbors)
            }
        }
        let alignedCountRows = countRows.filter { row in
            guard let count = row[1].bounds, let amount = row[2].bounds else { return false }
            return countRows.contains { other in
                guard other[0].id != row[0].id, let otherCount = other[1].bounds,
                      let otherAmount = other[2].bounds else { return false }
                let tolerance = min(count.height, otherCount.height)
                return abs(count.maxX - otherCount.maxX) <= tolerance
                    && abs(amount.maxX - otherAmount.maxX) <= tolerance
            }
        }

        let countItemIDs = Set(alignedCountRows.map { $0[0].id })
        var replacements: [Int: ReceiptDocumentPage.Line] = [:]
        var absorbed = Set<Int>()
        for neighbors in rateRows + alignedCountRows {
            let item = neighbors[0]
            let parts = neighbors.map(\.text)
            let wording = parts.joined(separator: " ")
            let combinedBounds = neighbors.compactMap(\.bounds).reduce(CGRect.null) { $0.union($1) }
            var choices: [ReceiptWordReading] = []
            var wordOffset = 0
            for (index, column) in neighbors.enumerated() {
                for choice in column.wordReadings {
                    var corrected = parts
                    corrected[index] = choice.wording
                    choices.append(.init(word: choice.word, replacement: choice.replacement,
                                         wording: corrected.joined(separator: " "), wordIndex: wordOffset + choice.wordIndex,
                                         bounds: choice.bounds))
                }
                wordOffset += column.text.split(whereSeparator: \.isWhitespace).count
            }
            replacements[item.id] = .init(id: item.id, text: wording, uncertain: neighbors.contains(where: \.uncertain),
                                          bounds: combinedBounds, wordReadings: choices,
                                          printedItemColumn: countItemIDs.contains(item.id) ? item.text : nil)
            absorbed.formUnion(neighbors.dropFirst().map(\.id))
        }
        return lines.compactMap { absorbed.contains($0.id) ? nil : replacements[$0.id] ?? $0 }
    }

    /// Check the full overlapping strip and both inked sides in the upright OCR input.
    private static func printedGutterSeparates(_ item: CGRect, _ rate: CGRect, in image: CGImage) -> Bool {
        guard item.minX < rate.minX, item.maxX < rate.maxX, item.maxX > rate.minX,
              let left = ReceiptWordReading.pixels(for: item, width: image.width, height: image.height),
              let right = ReceiptWordReading.pixels(for: rate, width: image.width, height: image.height) else { return false }
        let overlap = left.maxX - right.minX
        guard overlap > 0, overlap <= min(left.height, right.height) / 4 else { return false }
        let area = left.union(right)
        guard area.width * area.height <= 250_000, let strip = image.cropping(to: area),
              let context = CGContext(data: nil, width: strip.width, height: strip.height, bitsPerComponent: 8,
                                      bytesPerRow: strip.width, space: CGColorSpaceCreateDeviceGray(),
                                      bitmapInfo: CGImageAlphaInfo.none.rawValue),
              let data = context.data else { return false }
        context.draw(strip, in: CGRect(x: 0, y: 0, width: strip.width, height: strip.height))
        let pixels = data.assumingMemoryBound(to: UInt8.self)
        let first = Int(right.minX - area.minX) - 1
        let last = Int(left.maxX - area.minX)
        guard first > 0, last < strip.width - 1 else { return false }
        var leftInk = false, rightInk = false
        for y in 0..<strip.height {
            for x in 0..<strip.width {
                let gray = pixels[y * context.bytesPerRow + x]
                if x < first { leftInk = leftInk || gray < 128 }
                else if x > last { rightInk = rightInk || gray < 128 }
                else if gray < 248 { return false }
            }
        }
        return leftInk && rightInk
    }

    func source(target: CaptureTarget, merchant: String, stage: ReceiptAcquisition.DocumentLine.Stage,
                selection: Set<Selection>, linkedAmountItems: Set<Selection> = [], reviewedWording: [Selection: String] = [:], at date: Date) throws -> SourceMediaRecord {
        var associations: [Selection: Selection] = [:]
        if !linkedAmountItems.isEmpty {
            let suggested = amountAssociations
            associations = suggested.merging(splitAmountAssociations(excluding: suggested)) { suggested, _ in suggested }
        }
        let amounts = linkedAmountItems.compactMap { associations[$0] }
        let included = selection.union(amounts)
        guard (1...200).contains(included.count), linkedAmountItems.isSubset(of: selection),
              Set(amounts).count == linkedAmountItems.count, linkedAmountItems.isEmpty || stage != .order
        else { throw ReceiptDocumentFailure.selection }
        let id = ReceiptAcquisition.identity(["document", digest.base64EncodedString()])
        var rows: [ScanReceiptLine] = []
        for page in pages {
            let pageLines = Dictionary(uniqueKeysWithValues: page.lines.map { ($0.id, $0) })
            for line in page.lines where included.contains(.init(page: page.id, line: line.id)) {
                let place = ReceiptAcquisition.DocumentLine(method: page.method, stage: stage, page: page.id, line: line.id)
                var row = ScanReceiptLine(id: ReceiptAcquisition.lineID(receiptID: id, ordinal: place.ordinal), originalText: line.text)
                if line.uncertain { row.uncertainOCR = true }
                row.printedItemColumn = line.printedItemColumn
                row.documentLine = place
                let position = Selection(page: page.id, line: line.id)
                if let correction = reviewedWording[position] {
                    guard !correction.trimmingCharacters(in: .whitespaces).isEmpty,
                          !correction.contains(where: \.isNewline), !linkedAmountItems.contains(position),
                          !amounts.contains(position) else { throw ReceiptDocumentFailure.selection }
                    row.reviewedText = correction
                }
                if linkedAmountItems.contains(position), let amount = associations[position], let printed = pageLines[amount.line] {
                    let amountPlace = ReceiptAcquisition.DocumentLine(method: page.method, stage: stage, page: page.id, line: amount.line)
                    row.linkedAmountLineID = ReceiptAcquisition.lineID(receiptID: id, ordinal: amountPlace.ordinal)
                    row.priceNote = printed.text
                }
                rows.append(row)
            }
        }
        guard rows.count == included.count else { throw ReceiptDocumentFailure.selection }
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
    private struct Reading: Sendable {
        let text: String
        var uncertain: Set<String> = []
        var bounds: [CGRect] = []
        var wordReadings: [[ReceiptWordReading]] = []
    }
    private var recognize: @Sendable (Data) async throws -> Reading = { data in
        let reading = try await OnDeviceTextCapture().recognizeWithLayout(data, receiptReadings: true)
        return Reading(text: reading.evidence.text, uncertain: Set(reading.evidence.uncertainLines), bounds: reading.lineBounds, wordReadings: reading.wordReadings)
    }
    init() {}
    init(recognize: @escaping Recognize) {
        self.recognize = { data in Reading(text: try await recognize(data)) }
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
        func page(_ number: Int, method: ReceiptAcquisition.DocumentLine.Method, reading: Reading, photo: Data? = nil) throws -> ReceiptDocumentPage {
            characterCount += reading.text.count
            guard characterCount <= 100_000, !reading.text.contains("\0") else { throw ReceiptDocumentFailure.characters }
            var lines: [ReceiptDocumentPage.Line] = []
            for (index, row) in reading.text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).enumerated() {
                guard !row.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
                guard index < 200 else { throw ReceiptDocumentFailure.lineLimit }
                let bounds = reading.bounds.indices.contains(index) ? reading.bounds[index] : nil
                lines.append(.init(id: index + 1, text: String(row), uncertain: reading.uncertain.contains(String(row)), bounds: bounds,
                                   wordReadings: reading.wordReadings.indices.contains(index) ? reading.wordReadings[index] : []))
            }
            if method == .imageOCR || method == .pdfOCR {
                lines = ExtractedReceiptDocument.groupingQuantityPriceColumns(lines) {
                    guard let photo, let source = CGImageSourceCreateWithData(photo as CFData, nil) else { return nil }
                    return CGImageSourceCreateImageAtIndex(source, 0, nil)
                }
            }
            return .init(id: number, method: method, lines: lines)
        }
        switch input.kind {
        case .text:
            guard let text = decodePlainTextFile(input.data, unmarkedUTF16: input.unmarkedUTF16) else { throw ReceiptDocumentFailure.unsupported }
            return [try page(1, method: .textFile, reading: Reading(text: text))]
        case .image:
            try Self.checkPixels(input.data)
            let jpeg = try ScanImageNormalizer.normalize(input.data)
            return [try page(1, method: .imageOCR, reading: try await readImage(jpeg), photo: jpeg)]
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
                    let wording = try Self.pdfPrintedWording(text, page: original)
                    result.append(try page(index + 1, method: .pdfText, reading: Reading(text: wording)))
                } else {
                    do {
                        let bytes = try autoreleasepool { try Self.raster(original) }
                        result.append(try page(index + 1, method: .pdfOCR, reading: try await readImage(bytes)))
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

    private func readImage(_ data: Data) async throws -> Reading {
        do { return try await recognize(data) }
        catch CaptureFailure.noText { return Reading(text: "") }
        catch CaptureFailure.inputTooLarge { throw ReceiptDocumentFailure.lineLimit }
    }

    /// Some PDFKit versions emit spaces between printed rows. Use PDFKit's
    /// line selections only if they account for all wording in the same order.
    /// Keep the source's other spaces and existing line breaks.
    static func pdfPrintedWording(_ text: String, page: PDFPage) throws -> String {
        guard let selection = page.selection(for: NSRange(location: 0, length: page.numberOfCharacters)) else { return text }
        let rows = selection.selectionsByLine().compactMap { row -> (words: [Substring], bounds: CGRect)? in
            let words = row.string?.split(whereSeparator: \.isWhitespace) ?? []
            guard !words.isEmpty else { return nil }
            return (words, row.bounds(for: page))
        }
        let original = text.split(whereSeparator: \.isWhitespace)
        guard rows.count > 1, rows.flatMap(\.words).elementsEqual(original) else { return text }
        var result = ""
        var copied = text.startIndex
        var index = 0
        for (row, following) in zip(rows, rows.dropFirst()) {
            index += row.words.count
            try Task.checkCancellation()
            let space = original[index - 1].endIndex..<original[index].startIndex
            guard row.bounds.isFiniteSelection, following.bounds.isFiniteSelection,
                  row.bounds.minY >= following.bounds.maxY,
                  !space.isEmpty, !text[space].contains(where: \.isNewline) else { continue }
            result += text[copied..<space.lowerBound]
            result.append("\n")
            copied = space.upperBound
        }
        guard copied != text.startIndex else { return text }
        result += text[copied...]
        return result
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

private extension CGRect {
    var isFiniteSelection: Bool {
        !isEmpty && !isNull && minX.isFinite && minY.isFinite && maxX.isFinite && maxY.isFinite
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
