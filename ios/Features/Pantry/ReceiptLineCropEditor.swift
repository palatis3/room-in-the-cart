import CoreGraphics
import CryptoKit
import HouseholdClient
import SwiftUI

extension ReceiptLineCrop {
    /// Read visible pixels from a normalized source, discard all metadata and limit the outgoing rectangle.
    static func selected(from image: CGImage, rectangle: CGRect) throws -> Self {
        guard rectangle.minX >= 0, rectangle.minY >= 0, rectangle.maxX <= 1, rectangle.maxY <= 1,
              rectangle.width > 0, rectangle.height > 0, rectangle.width * rectangle.height < 1 else { throw ScanFailure.invalidImage }
        let region = CGRect(x: rectangle.minX * CGFloat(image.width), y: rectangle.minY * CGFloat(image.height),
            width: rectangle.width * CGFloat(image.width), height: rectangle.height * CGFloat(image.height)).integral
        guard let part = image.cropping(to: region) else { throw ScanFailure.invalidImage }
        let scale = min(1, 768 / CGFloat(part.width), 240 / CGFloat(part.height))
        let width = Int(CGFloat(part.width) * scale), height = Int(CGFloat(part.height) * scale)
        guard width >= 8, height >= 8 else { throw ScanFailure.invalidImage }
        var data = Data(count: width * height)
        try data.withUnsafeMutableBytes { storage in
            guard let context = CGContext(data: storage.baseAddress, width: width, height: height, bitsPerComponent: 8,
                bytesPerRow: width, space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else {
                throw ScanFailure.invalidImage
            }
            context.interpolationQuality = .high
            context.draw(part, in: CGRect(x: 0, y: 0, width: width, height: height))
        }
        return try Self(width: width, height: height, pixels: data)
    }

    func sourceDigest(in image: CGImage, rectangle: CGRect) -> Data {
        let region = CGRect(x: rectangle.minX * CGFloat(image.width), y: rectangle.minY * CGFloat(image.height),
            width: rectangle.width * CGFloat(image.width), height: rectangle.height * CGFloat(image.height)).integral
        let geometry = [image.width, image.height, Int(region.minX), Int(region.minY), Int(region.width), Int(region.height), width, height]
        var hash = SHA256()
        hash.update(data: Data(("gray8/" + geometry.map(String.init).joined(separator: "/") + "/").utf8))
        hash.update(data: pixels)
        return Data(hash.finalize())
    }

    var previewImage: CGImage? {
        guard let provider = CGDataProvider(data: pixels as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 8, bytesPerRow: width,
            space: CGColorSpaceCreateDeviceGray(), bitmapInfo: .init(rawValue: CGImageAlphaInfo.none.rawValue),
            provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
    }
}

struct ReceiptLineCropEditor: View {
    let image: CGImage
    let select: (ReceiptLineCrop, Data) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var top = 0.35
    @State private var bottom = 0.55
    @State private var left = 0.02
    @State private var right = 0.98
    @State private var failed = false

    private var area: CGRect { CGRect(x: left, y: top, width: right-left, height: bottom-top) }

    var body: some View {
        NavigationStack {
            WorkingForm {
                Section {
                    Image(decorative: image, scale: 1).resizable().scaledToFit().overlay {
                        GeometryReader { geometry in
                            Rectangle().strokeBorder(.orange, lineWidth: 3)
                                .frame(width: area.width * geometry.size.width, height: area.height * geometry.size.height)
                                .position(x: area.midX * geometry.size.width, y: area.midY * geometry.size.height)
                        }
                    }.accessibilityLabel(pantryText("Source image with selected rectangle"))
                    Text(pantryText("Frame only the printed line. Leave out personal details and nearby lines."))
                    edge("Top edge", $top, 0...max(0, bottom-0.04))
                    edge("Bottom edge", $bottom, min(1, top+0.04)...1)
                    edge("Left edge", $left, 0...max(0, right-0.04))
                    edge("Right edge", $right, min(1, left+0.04)...1)
                }
                Button(pantryText("Preview this crop")) {
                    do { let crop = try ReceiptLineCrop.selected(from: image, rectangle: area); select(crop, crop.sourceDigest(in: image, rectangle: area)); dismiss() }
                    catch { failed = true }
                }.accessibilityIdentifier("receipt.assistance.previewCrop")
                if failed { Text(pantryText("Choose a smaller box around a legible line.")) }
            }
            .navigationTitle(pantryText("Choose the printed line"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(pantryText("Cancel")) { dismiss() } } }
        }.privacySensitive()
    }
    private func edge(_ title: String, _ value: Binding<Double>, _ bounds: ClosedRange<Double>) -> some View {
        VStack(alignment: .leading) {
            LabeledContent(pantryText(title), value: value.wrappedValue.formatted(.percent.precision(.fractionLength(0))))
            Slider(value: Binding(get: { value.wrappedValue }, set: {
                value.wrappedValue = min(bounds.upperBound, max(bounds.lowerBound, $0))
            }), in: 0...1).accessibilityLabel(pantryText(title))
        }
    }
}
