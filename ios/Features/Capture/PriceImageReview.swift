import CoreDomain
import CryptoKit
import PhotosUI
import SwiftUI

struct PriceImageReview: View {
    enum Purpose { case shelf, checkout }
    let purpose: Purpose
    let authorized: () -> Bool
    var acceptShelf: (PriceImageLine) -> Void = { _ in }
    var acceptCheckout: (ReviewedCheckoutImage) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var photo: PhotosPickerItem?
    @State private var lines: [PriceImageLine] = []
    @State private var sourcePreview: Data?
    @State private var sourceDigest: Data?
    @FocusState private var focusedAmount: ReviewedCheckoutImage.Field?
    @State private var loading = false
    @State private var notice: String?
    @State private var selections: [ReviewedCheckoutImage.Field: Int] = [:]
    @State private var amounts: [ReviewedCheckoutImage.Field: String] = [:]
    @State private var inclusions: [ReviewedCheckoutImage.Field: ReviewedCheckoutImage.Inclusion] = [:]

    var body: some View {
        Form {
            PhotosPicker(selection: $photo, matching: .images, preferredItemEncoding: .current) {
                Label(pantryText("Choose a price image"), systemImage: "photo")
            }.accessibilityIdentifier("priceImage.choose")
            if loading { ProgressView() }
            if let notice { Text(verbatim: notice) }
            if let image = sourcePreview, let digest = sourceDigest, authorized() {
                let reviewed = lines
                let originals = reviewed.map(\.wording) + (reviewed.count < 200 ? [""] : [])
                AssistedImageLines(wording: originals, image: image, purpose: purpose == .shelf ? .shelf : .checkout, authorized: {
                    authorized() && sourceDigest == digest && lines == reviewed
                }) { index, reading in
                    guard originals.indices.contains(index) else { throw ScanFailure.stale }
                    let item = try PriceImageLine(digest: digest, ordinal: index, wording: originals[index], uncertain: true, reviewedReading: reading)
                    guard !lines.contains(where: { $0.ordinal != index && $0.reviewedReading?.cropDigest == reading.cropDigest }) else { throw ScanFailure.stale }
                    if index == lines.count {
                        lines.append(item)
                    } else { lines[index] = item }
                    // A corrected crop may name a different charge. Ask the shopper to assign it again.
                    for field in ReviewedCheckoutImage.Field.allCases where selections[field] == index {
                        selections[field] = nil
                        amounts[field] = nil
                        inclusions[field] = nil
                    }
                }
            }
            if authorized(), !lines.isEmpty {
                if purpose == .shelf {
                    Section(pantryText("Choose the printed price line")) {
                        ForEach(lines, id: \.ordinal) { line in
                            Button { guard authorized() else { return }; acceptShelf(line); dismiss() } label: {
                                VStack(alignment: .leading) {
                                    if !line.wording.isEmpty { Text(verbatim: line.wording) }
                                    if let reading = line.reviewedReading { ReviewedImageWordingLabel(reading: reading) }
                                    if line.uncertain { Text(pantryText("Uncertain image wording")).font(.caption) }
                                }
                            }
                        }
                    }
                } else {
                    ForEach(ReviewedCheckoutImage.Field.allCases, id: \.self) { field in
                        Section(priceImageField(field)) {
                            Picker(pantryText("Printed wording"), selection: Binding(
                                get: { selections[field] ?? -1 }, set: { index in
                                    guard selections[field] != index else { return }
                                    selections[field] = index
                                    let suggested = lines.indices.contains(index) ? ReviewedCheckoutImage.proposedAmount(for: field, from: lines[index]) : nil
                                    amounts[field] = suggested.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue }
                                    inclusions[field] = nil
                                }
                            )) {
                                Text(pantryText("Not shown")).tag(-1)
                                ForEach(lines, id: \.ordinal) { line in Text(verbatim: line.effectiveWording).tag(line.ordinal) }
                            }
                            .accessibilityIdentifier("priceImage.line." + field.rawValue)
                            if let index = selections[field], lines.indices.contains(index) {
                                if let reading = lines[index].reviewedReading { ReviewedImageWordingLabel(reading: reading) }
                                if lines[index].uncertain { Text(pantryText("Uncertain image wording")).font(.caption) }
                                TextField(pantryText("Shown USD amount, blank if unknown"), text: Binding(
                                    get: { amounts[field] ?? "" }, set: { amounts[field] = $0 })).keyboardType(.decimalPad)
                                    .focused($focusedAmount, equals: field)
                                    .accessibilityIdentifier("priceImage.amount." + field.rawValue)
                                if field != .total {
                                    Picker(pantryText("Relation to displayed total"), selection: Binding(
                                        get: { inclusions[field] ?? .unknown }, set: { inclusions[field] = $0 }
                                    )) {
                                        ForEach(ReviewedCheckoutImage.Inclusion.allCases, id: \.self) { value in Text(priceImageInclusion(value)).tag(value) }
                                    }
                                }
                            }
                        }
                    }
                    Button(pantryText("Use reviewed screenshot")) {
                        guard authorized() else { return }
                        do {
                            guard authorized() else { return }
                            let charges = try ReviewedCheckoutImage.Field.allCases.compactMap { field -> ReviewedCheckoutImage.Charge? in
                                guard let i = selections[field], lines.indices.contains(i) else { return nil }
                                let raw = (amounts[field] ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
                                let amount = raw.isEmpty ? nil : try Money(decimal: raw.replacingOccurrences(of: locale.decimalSeparator ?? ".", with: "."))
                                return .init(field: field, amount: amount, inclusion: inclusions[field] ?? .unknown, line: lines[i])
                            }
                            acceptCheckout(try .init(charges: charges))
                            dismiss()
                        } catch { notice = pantryText("Review the selected lines and amounts.") }
                    }.accessibilityIdentifier("priceImage.reviewCheckout")
                }
            }
        }
        .navigationTitle(purpose == .shelf ? pantryText("Shelf label") : pantryText("Checkout screenshot"))
        .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() } } }
        .keyboardDoneAction(visible: focusedAmount != nil, title: pantryText("Done"), identifier: "priceImage.done") { focusedAmount = nil }
        .privacySensitive()
        .onChange(of: authorized()) { _, allowed in
            if !allowed {
                photo = nil; sourcePreview = nil; sourceDigest = nil; lines = []
                selections = [:]; amounts = [:]; inclusions = [:]; notice = nil
                dismiss()
            }
        }
        .task(id: photo) {
            sourcePreview = nil; sourceDigest = nil
            lines = []; selections = [:]; amounts = [:]; inclusions = [:]; notice = nil
            guard let photo, authorized() else { loading = false; return }
            loading = true
            defer { if !Task.isCancelled { loading = false } }
            do {
                guard let selected = try await photo.loadTransferable(type: SelectedPhotoTransfer.self) else { throw ScanFailure.invalidImage }
                let data = try selected.data
                let digest = Data(SHA256.hash(data: data))
                let evidence: CaptureEvidence
                do { evidence = try await OnDeviceTextCapture().recognize(data) }
                catch {
                    let preview = try await Task.detached(priority: .userInitiated) { try ScanImageNormalizer.normalize(data) }.value
                    guard !Task.isCancelled, authorized() else { return }
                    sourcePreview = preview; sourceDigest = digest
                    notice = pantryText("Choose a line from the source photo or enter the wording manually.")
                    return
                }
                let uncertain = Set(evidence.uncertainLines)
                let recognized = try evidence.text.split(separator: "\n").enumerated().map { ordinal, value in
                    try PriceImageLine(digest: digest, ordinal: ordinal, wording: String(value), uncertain: uncertain.contains(String(value)))
                }
                guard !Task.isCancelled, authorized() else { return }
                sourcePreview = evidence.previewImageData
                sourceDigest = digest
                lines = recognized
                if purpose == .checkout {
                    let proposals = ReviewedCheckoutImage.proposals(from: recognized)
                    selections = proposals.mapValues { $0.line.ordinal }
                    amounts = proposals.compactMapValues { charge in
                        charge.amount.map { NSDecimalNumber(decimal: Decimal($0.minorUnits) / 100).stringValue }
                    }
                }
            } catch {
                guard !Task.isCancelled, authorized() else { return }
                notice = pantryText("Couldn’t read this image. Choose another image or enter the evidence manually.")
            }
        }
    }
}

func priceImageField(_ field: ReviewedCheckoutImage.Field) -> String {
    switch field {
    case .subtotal: pantryText("Printed subtotal")
    case .discount: pantryText("Printed discount")
    case .tax: pantryText("Printed tax")
    case .tip: pantryText("Printed tip")
    case .fee: pantryText("Printed fee")
    case .total: pantryText("Printed total")
    }
}

func priceImageInclusion(_ value: ReviewedCheckoutImage.Inclusion) -> String {
    switch value {
    case .unknown: pantryText("Inclusion unknown")
    case .included: pantryText("Included in displayed total")
    case .additional: pantryText("Additional to displayed total")
    }
}
