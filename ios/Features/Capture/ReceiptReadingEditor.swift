import SwiftUI

/// The edits stay in the inspector until the shopper explicitly applies the wording.
struct ReceiptReadingEditor: View {
    let line: ReceiptDocumentPage.Line
    let image: CGImage
    let pageImage: CGImage
    let reviewed: String
    let apply: (String) -> Void
    @State private var draft: String
    @State private var strongerContrast = false

    init(line: ReceiptDocumentPage.Line, image: CGImage, pageImage: CGImage, reviewed: String, apply: @escaping (String) -> Void) {
        self.line = line
        self.image = image
        self.pageImage = pageImage
        self.reviewed = reviewed
        self.apply = apply
        _draft = State(initialValue: reviewed)
    }

    var body: some View {
        Section(captureText("Check the print")) {
            Image(decorative: image, scale: 1)
                .resizable().scaledToFit()
                .contrast(strongerContrast ? 1.8 : 1)
                .accessibilityLabel(captureText("Original printed line"))
            Toggle(captureText("Increase print contrast"), isOn: $strongerContrast)
            if draft == line.text {
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
            }
            WorkingField(captureText("Reviewed line wording")) {
                TextField(captureText("Reviewed line wording"), text: $draft, axis: .vertical)
                    .textFieldStyle(WorkingInputStyle())
                    .accessibilityIdentifier("receipt.reading.edit")
            }
            if draft != line.text {
                Button(captureText("Restore original wording")) { draft = line.text }
            }
            Button(captureText("Use reviewed wording")) { apply(draft) }
                .disabled(draft == reviewed || draft.trimmingCharacters(in: .whitespaces).isEmpty
                    || draft.contains(where: \.isNewline) || draft.utf8.count > 2048)
                .accessibilityIdentifier("receipt.reading.apply")
        }
    }
}
