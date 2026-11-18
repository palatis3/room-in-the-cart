import CoreDomain
import CryptoKit
import PhotosUI
import SwiftUI

struct PriceImageReview: View {
    enum Purpose { case shelf, checkout }
    let purpose: Purpose
    var acceptShelf: (PriceImageLine) -> Void = { _ in }
    var acceptCheckout: (ReviewedCheckoutImage) -> Void = { _ in }
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @State private var photo: PhotosPickerItem?
    @State private var lines: [PriceImageLine] = []
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
            if !lines.isEmpty {
                if purpose == .shelf {
                    Section(pantryText("Choose the printed price line")) {
                        ForEach(lines, id: \.ordinal) { line in
                            Button { acceptShelf(line); dismiss() } label: {
                                VStack(alignment: .leading) {
                                    Text(verbatim: line.wording)
                                    if line.uncertain { Text(pantryText("Uncertain image wording")).font(.caption) }
                                }
                            }
                        }
                    }
                } else {
                    ForEach(ReviewedCheckoutImage.Field.allCases, id: \.self) { field in
                        Section(priceImageField(field)) {
                            Picker(pantryText("Printed wording"), selection: Binding(
                                get: { selections[field] ?? -1 }, set: { selections[field] = $0; amounts[field] = "" }
                            )) {
                                Text(pantryText("Not shown")).tag(-1)
                                ForEach(lines, id: \.ordinal) { line in Text(verbatim: line.wording).tag(line.ordinal) }
                            }
                            if let index = selections[field], lines.indices.contains(index) {
                                if lines[index].uncertain { Text(pantryText("Uncertain image wording")).font(.caption) }
                                TextField(pantryText("Shown USD amount, blank if unknown"), text: Binding(
                                    get: { amounts[field] ?? "" }, set: { amounts[field] = $0 })).keyboardType(.decimalPad)
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
                        do {
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
        .privacySensitive()
        .task(id: photo) {
            lines = []; selections = [:]; amounts = [:]; inclusions = [:]; notice = nil
            guard let photo else { return }
            loading = true
            defer { if !Task.isCancelled { loading = false } }
            do {
                guard let selected = try await photo.loadTransferable(type: SelectedPhotoTransfer.self) else { throw ScanFailure.invalidImage }
                let data = try selected.data
                let evidence = try await OnDeviceTextCapture().recognize(data)
                let digest = Data(SHA256.hash(data: data))
                let uncertain = Set(evidence.uncertainLines)
                let recognized = try evidence.text.split(separator: "\n").enumerated().map { ordinal, value in
                    try PriceImageLine(digest: digest, ordinal: ordinal, wording: String(value), uncertain: uncertain.contains(String(value)))
                }
                guard !Task.isCancelled else { return }
                lines = recognized
            } catch {
                guard !Task.isCancelled else { return }
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
