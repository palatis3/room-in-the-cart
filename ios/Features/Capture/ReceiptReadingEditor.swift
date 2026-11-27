import SwiftUI

/// The edits stay in the inspector until the shopper explicitly applies the wording.
struct ReceiptReadingEditor: View {
    let line: ReceiptDocumentPage.Line
    let image: CGImage
    let pageImage: CGImage
    @Binding var draft: String
    @State private var strongerContrast = false

    var body: some View {
        Section(captureText("Check the print")) {
            Image(decorative: image, scale: 1)
                .resizable().scaledToFit()
                .contrast(strongerContrast ? 1.8 : 1)
                .accessibilityLabel(captureText("Original printed line"))
            Toggle(captureText("Increase print contrast"), isOn: $strongerContrast)
            // Keep the same Form rows mounted while the shopper types.
            ForEach(line.wordReadings, id: \.wording) { choice in
                if let bounds = choice.bounds,
                   let pixels = ReceiptWordReading.pixels(for: bounds, width: pageImage.width, height: pageImage.height),
                   let cell = pageImage.cropping(to: pixels) {
                    Image(decorative: cell, scale: 1).resizable().scaledToFit()
                        .frame(maxHeight: 52, alignment: .leading).contrast(strongerContrast ? 1.8 : 1)
                        .accessibilityHidden(true)
                }
                Button(String(format: captureText("Read “%@” as “%@”"), choice.word, choice.replacement)) {
                    draft = choice.wording
                }
            }
            .disabled(draft != line.text)
            WorkingField(captureText("Reviewed line wording")) {
                TextField(captureText("Reviewed line wording"), text: $draft)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.done)
                    .accessibilityIdentifier("receipt.reading.edit")
            }
            Button(captureText("Restore original wording")) { draft = line.text }
                .disabled(draft == line.text)
        }
    }
}
