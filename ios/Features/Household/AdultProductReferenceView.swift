import HouseholdClient
import ImageIO
import PhotosUI
import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct AdultProductReferenceLink: View {
    @ObservedObject var household: HouseholdModel
    let request: OwnRequest
    var body: some View {
        if ["pending", "clarified", "added"].contains(request.status), request.carriedForward != true, request.fromPreviousShop != true,
           let shopID = UUID(uuidString: request.shopId), let requestID = UUID(uuidString: request.id),
           household.adultRequestScope(shop: shopID, capability: "adult_product_reference") != nil {
            NavigationLink {
                PrivateAdultRequestSurface(household: household, shopID: shopID, capability: "adult_product_reference") { scope in
                    ProductReferenceDetail(household: household, scope: scope, requestID: requestID,
                                           selectedRevision: request.revision, itemName: request.originalItem)
                }.navigationTitle(ht("Exact product"))
            } label: {
                Label(ht("Exact product"), systemImage: "barcode.viewfinder")
            }.accessibilityIdentifier("household.productReference." + request.id)
        }
    }
}

private struct ProductReferenceDetail: View {
    @ObservedObject var household: HouseholdModel
    let scope: AdultRequestViewScope
    let requestID: UUID
    let selectedRevision: Int
    let itemName: String
    @State private var page: AdultProductReferencePage?
    @State private var editing = false
    @State private var reviewed: AdultProductReference?
    @State private var brand = ""
    @State private var size = ""
    @State private var barcode = ""
    @State private var wording = ""
    @State private var crop: ProductReferenceCrop?
    @State private var selection: PhotosPickerItem?
    @State private var cropSource: UIImage?
    @State private var readingPhoto = false
    @State private var photoGeneration = UUID()
    @State private var confirming: Confirmation?
    @State private var reason: ProductReferenceReportReason = .unsafe
    @State private var busy = false
    @State private var notice: String?
    @State private var life = UUID()
    private enum Confirmation: String, Identifiable { case remove, block, report; var id: Self { self } }

    var body: some View {
        Form {
            if let page {
                Section {
                    Text(verbatim: itemName).font(.headline)
                    LabeledContent(ht("Authorized shopper"), value: page.recipientLabel)
                    if let expiry = page.expiresAt.flatMap(referenceDate) {
                        LabeledContent(ht("Reference expires"), value: expiry.formatted(date: .abbreviated, time: .shortened))
                    }
                }
                if let reviewed {
                    Section(ht("Review what you will share")) {
                        productFacts(reviewed)
                        LabeledContent(ht("Shopper who will receive it"), value: page.recipientLabel)
                        if reviewed.crop != nil {
                            Text(ht("The household service receives this crop without location metadata. An authorized moderator reviews it before the shopper can see it."))
                        }
                        Text(ht("You can remove this reference. It expires within seven days."))
                        Button(ht("Share this reference")) {
                            let key = UUID()
                            Task { await write(publishing: true) { service, session in
                                try await service.saveProductReference(reviewed, request: requestID, in: session, reviewed: page, clientKey: key)
                            } }
                        }
                        Button(ht("Back to editing")) { self.reviewed = nil }
                    }
                } else if editing {
                    Section(ht("Identify the exact product")) {
                        TextField(ht("Brand (optional)"), text: $brand)
                        TextField(ht("Package size (optional)"), text: $size)
                        TextField(ht("Barcode (optional)"), text: $barcode).keyboardType(.numberPad)
                        TextField(ht("Description the shopper can use"), text: $wording, axis: .vertical)
                        Text(ht("Describe the label or package that distinguishes this item."))
                    }
                    if scope.media {
                        Section(ht("Optional reference photo")) {
                            if let crop { referenceImage(crop, label: wording) }
                            PhotosPicker(selection: $selection, matching: .images) {
                                Label(ht("Choose a photo to crop"), systemImage: "photo")
                            }.disabled(readingPhoto)
                            if readingPhoto { ProgressView() }
                            if crop != nil { Button(ht("Remove the crop")) { crop = nil } }
                        }
                    }
                    Section {
                        Button(ht("Review recipient and reference")) {
                            do {
                                reviewed = try AdultProductReference(brand: brand, size: size, barcode: barcode, description: wording, crop: crop)
                                notice = nil
                            } catch { notice = ht("Enter a description up to 240 characters, brand and size up to 80 each, and an optional barcode of 8 to 14 digits.") }
                        }.disabled(readingPhoto)
                        Button(ht("Cancel")) { clearDraft() }
                    }
                } else {
                    Section(ht("Product reference")) {
                        if let reference = page.reference {
                            productFacts(reference)
                            if page.own, let status = reference.mediaStatus {
                                switch status {
                                case "pending": Text(ht("Crop awaiting moderation"))
                                case "approved": Text(ht("Crop approved for the shopper"))
                                case "rejected": Text(ht("Crop declined. The shopper cannot see it."))
                                default: EmptyView()
                                }
                            }
                        } else { Text(ht("No product reference is shared.")) }
                        if page.own {
                            Button(page.reference == nil ? ht("Add exact product") : ht("Edit exact product")) {
                                brand = page.reference?.brand ?? ""; size = page.reference?.size ?? ""
                                barcode = page.reference?.barcode ?? ""; wording = page.reference?.description ?? ""
                                crop = page.reference?.crop; editing = true
                            }
                            if page.reference != nil { Button(ht("Remove shared reference"), role: .destructive) { confirming = .remove } }
                        } else if page.reference != nil {
                            Picker(ht("Report reason"), selection: $reason) {
                                Text(ht("Unsafe content")).tag(ProductReferenceReportReason.unsafe)
                                Text(ht("Harassment")).tag(ProductReferenceReportReason.harassment)
                                Text(ht("Other")).tag(ProductReferenceReportReason.other)
                            }
                            Button(ht("Report this reference")) { confirming = .report }
                            Button(ht("Block this sender"), role: .destructive) { confirming = .block }
                        }
                    }
                }
            }
            if let notice { Text(notice).accessibilityAddTraits(.updatesFrequently) }
            if !editing && reviewed == nil { Button(ht("Refresh product reference")) { Task { await load() } } }
            if busy { ProgressView() }
        }
        .disabled(busy)
        .task {
            await load()
            while !Task.isCancelled {
                do { try await Task.sleep(for: .seconds(30)) } catch { return }
                await load(revalidate: true)
            }
        }
        .task(id: page?.expiresAt) {
            guard let expiry = page?.expiresAt.flatMap(referenceDate) else { return }
            do { try await Task.sleep(for: .seconds(max(0, expiry.timeIntervalSinceNow))) } catch { return }
            guard page?.expiresAt.flatMap(referenceDate) == expiry else { return }
            clearDraft(); page = nil; notice = ht("This reference expired. Refresh to check the current request.")
        }
        .onChange(of: selection) { _, value in
            guard let value, scope.media else { return }
            let token = UUID(); photoGeneration = token; readingPhoto = true
            Task {
                do {
                    guard let photo = try await value.loadTransferable(type: ReceiptPhotoSelection.self) else { throw ClientError.configuration }
                    let image = try ProductReferenceRaster.thumbnail(try photo.bytes.data)
                    guard photoGeneration == token, isCurrent, editing else { return }
                    cropSource = image
                } catch {
                    if photoGeneration == token, isCurrent { notice = ht("Choose a readable photo up to 10 MB.") }
                }
                if photoGeneration == token { readingPhoto = false; selection = nil }
            }
        }
        .sheet(isPresented: Binding(get: { cropSource != nil }, set: { if !$0 { cropSource = nil } })) {
            if let source = cropSource {
                ProductReferenceCropEditor(image: source) { result in
                    if isCurrent, editing { crop = result }
                    cropSource = nil
                } cancel: { cropSource = nil }
            }
        }
        .alert(item: $confirming) { action in
            let title: String, detail: String
            switch action {
            case .remove:
                title = ht("Remove shared reference"); detail = ht("The shopper will lose access to this product reference.")
            case .report:
                title = ht("Report this reference"); detail = ht("The reported reference will be hidden for you and sent for review.")
            case .block:
                title = ht("Block this sender"); detail = ht("Their shared content will be hidden from your view.")
            }
            return Alert(title: Text(title), message: Text(detail), primaryButton: .destructive(Text(title)) {
                guard let page else { return }; let key = UUID()
                Task {
                    if action == .remove {
                        await write { try await $0.removeProductReference(requestID, in: $1, reviewed: page, clientKey: key) }
                    } else {
                        await moderate(page, block: action == .block, key: key)
                    }
                }
            }, secondaryButton: .cancel(Text(ht("Cancel"))))
        }
        .onDisappear { life = UUID(); clearDraft(); page = nil; notice = nil; busy = false }
    }

    private var isCurrent: Bool {
        household.adultRequestScope(shop: scope.shop, capability: "adult_product_reference") == scope &&
        UIApplication.shared.isProtectedDataAvailable && UIApplication.shared.applicationState == .active
    }

    @ViewBuilder private func productFacts(_ value: AdultProductReference) -> some View {
        if let brand = value.brand { LabeledContent(ht("Brand"), value: brand) }
        if let size = value.size { LabeledContent(ht("Package size"), value: size) }
        if let barcode = value.barcode { LabeledContent(ht("Barcode"), value: barcode) }
        Text(verbatim: value.description)
        if scope.media, let crop = value.crop { referenceImage(crop, label: value.description) }
    }

    private func clearDraft() {
        editing = false; reviewed = nil; confirming = nil; brand = ""; size = ""; barcode = ""; wording = ""
        crop = nil; cropSource = nil; selection = nil; readingPhoto = false; photoGeneration = UUID()
    }

    private func load(revalidate: Bool = false) async {
        await write(preserveDraft: revalidate) { try await $0.productReference(requestID, in: $1) }
    }

    private func write(preserveDraft: Bool = false, publishing: Bool = false, _ action: (HouseholdService, AdultShopRequestSession) async throws -> AdultProductReferencePage) async {
        guard isCurrent, !busy, let service = household.service, let projection = household.projection else { return }
        let started = life
        busy = true; defer { if started == life { busy = false } }
        do {
            let session = try await service.adultShopRequestSession(projection, shopID: scope.shop)
            guard started == life, isCurrent else { return }
            let result = try await action(service, session)
            guard started == life, isCurrent else { return }
            guard result.requestRevision == selectedRevision else { throw ClientError.accessEnded }
            if !preserveDraft || page != result { clearDraft() }
            page = result; notice = nil
        } catch {
            guard started == life, isCurrent else { return }
            if publishing, case ClientError.service(422, "content_review_required", _, _) = error {
                reviewed = nil
                notice = ht("This wording could not be shared. Edit it and review it again before sending.")
                return
            }
            if publishing, case ClientError.service(429, "media_limit", _, _) = error {
                reviewed = nil
                notice = ht("Remove the crop to share text alone, or remove a photo from an earlier reference.")
                return
            }
            clearDraft(); page = nil
            notice = ht("This reference could not be confirmed. Check the request and current shopper, then refresh.")
        }
    }

    private func moderate(_ reviewed: AdultProductReferencePage, block: Bool, key: UUID) async {
        guard isCurrent, !busy, let service = household.service, let projection = household.projection else { return }
        let started = life; busy = true; defer { if started == life { busy = false } }
        do {
            let session = try await service.adultShopRequestSession(projection, shopID: scope.shop)
            guard started == life, isCurrent else { return }
            try await service.moderateProductReference(requestID, in: session, reviewed: reviewed, block: block, reason: block ? nil : reason, clientKey: key)
            guard started == life, isCurrent else { return }
            clearDraft(); page = nil
            notice = block ? ht("Sender blocked.") : ht("Report received.")
        } catch {
            guard started == life else { return }
            clearDraft(); page = nil; notice = ht("Check your connection and refresh before trying again.")
        }
    }


}

private func referenceDate(_ value: String) -> Date? {
    let iso = ISO8601DateFormatter()
    iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return iso.date(from: value) ?? ISO8601DateFormatter().date(from: value)
}

@ViewBuilder private func referenceImage(_ value: ProductReferenceCrop, label: String) -> some View {
    if let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
       let provider = CGDataProvider(data: value.pixels as CFData),
       let image = CGImage(width: value.width, height: value.height, bitsPerComponent: 8, bitsPerPixel: 24,
        bytesPerRow: value.width * 3, space: colorSpace, bitmapInfo: [],
        provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent) {
        Image(decorative: image, scale: 1).resizable().scaledToFit().frame(maxHeight: 192)
            .accessibilityElement().accessibilityLabel(Text(verbatim: label))
    }
}

private struct ProductReferenceCropEditor: View {
    let image: UIImage
    let confirm: (ProductReferenceCrop) -> Void
    let cancel: () -> Void
    @State private var horizontal = 0.5
    @State private var vertical = 0.5
    @State private var fraction = 0.75
    private var cropped: CGImage? {
        guard let image = image.cgImage else { return nil }
        let edge = max(8, Int(Double(min(image.width, image.height)) * fraction))
        return image.cropping(to: .init(x: Int(Double(image.width - edge) * horizontal),
                                        y: Int(Double(image.height - edge) * vertical), width: edge, height: edge))
    }

    var body: some View {
        NavigationStack {
            Form {
                if let cropped {
                    Image(decorative: cropped, scale: 1).resizable().scaledToFit().frame(maxHeight: 270)
                        .accessibilityLabel(ht("Selected crop"))
                }
                adjustment(ht("Crop size"), value: $fraction, range: 0.15...1)
                adjustment(ht("Horizontal position"), value: $horizontal, range: 0...1)
                adjustment(ht("Vertical position"), value: $vertical, range: 0...1)
                Button(ht("Use this crop")) { if let cropped, let value = ProductReferenceRaster.rgb(cropped) { confirm(value) } }
                Button(ht("Cancel"), role: .cancel, action: cancel)
            }.navigationTitle(ht("Crop product photo"))
        }
    }

    private func adjustment(_ name: String, value: Binding<Double>, range: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            Text(name)
            Slider(value: value, in: range, step: 0.05).accessibilityLabel(name)
        }
    }

}

enum ProductReferenceRaster {
    static func thumbnail(_ data: Data) throws -> UIImage {
        guard data.count <= ReceiptDocumentBytes.maximumBytes,
              let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary),
              CGImageSourceGetCount(source) == 1, let type = CGImageSourceGetType(source) as String?,
              [UTType.jpeg.identifier, UTType.png.identifier, UTType.heic.identifier, UTType.heif.identifier].contains(type),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = props[kCGImagePropertyPixelWidth] as? Int, let height = props[kCGImagePropertyPixelHeight] as? Int,
              height >= 8, width >= 8, width <= 30_000_000 / height,
              let image = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceCreateThumbnailWithTransform: true,
                kCGImageSourceThumbnailMaxPixelSize: 768
              ] as CFDictionary), min(image.width, image.height) >= 8 else { throw ClientError.configuration }
        return UIImage(cgImage: image)
    }

    static func rgb(_ image: CGImage) -> ProductReferenceCrop? {
        let side = min(192, image.width)
        var rgba = [UInt8](repeating: 0, count: side * side * 4)
        let rendered = rgba.withUnsafeMutableBytes { buffer -> Bool in
            guard let color = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: side, height: side,
                                          bitsPerComponent: 8, bytesPerRow: side * 4, space: color,
                                          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue) else { return false }
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            context.setFillColor(UIColor.white.cgColor); context.fill(rect); context.draw(image, in: rect)
            return true
        }
        guard rendered else { return nil }
        var data = Data(capacity: side * side * 3)
        for i in stride(from: 0, to: rgba.count, by: 4) { data.append(contentsOf: rgba[i..<(i + 3)]) }
        return try? ProductReferenceCrop(width: side, height: side, pixels: data)
    }
}
