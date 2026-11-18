import CoreDomain
import HouseholdClient
import SwiftUI

/// The parent retains its exact authorized image and original row ordering while this picker is open.
struct AssistedImageLines: View {
    let wording: [String]
    let image: Data
    let purpose: ImageAssistancePurpose
    let authorized: () -> Bool
    let apply: (Int, ReviewedImageWording) throws -> Void

    private struct Row: Identifiable { let id: Int }
    @State private var selected: Row?

    var body: some View {
        NavigationLink(pantryText("Read an unclear image line")) {
            List {
                if authorized() {
                    ForEach(wording.indices, id: \.self) { index in
                        Button { selected = Row(id: index) } label: {
                            Text(verbatim: wording[index].isEmpty ? pantryText("Choose a line from the source photo") : wording[index])
                        }
                    }
                } else { Text(pantryText("The source changed. Open the line again.")) }
            }.navigationTitle(pantryText("Choose the printed line"))
            .sheet(item: $selected) { row in
                if wording.indices.contains(row.id), authorized() {
                    AssistedCaptureLineReview(original: wording[row.id], lineNumber: row.id + 1,
                        sourceImage: image, purpose: purpose, authorized: authorized) { reading in
                            guard authorized() else { throw ScanFailure.stale }
                            try apply(row.id, reading)
                        }
                } else { Text(pantryText("The source changed. Open the line again.")) }
            }
        }.accessibilityIdentifier("capture.assistedImageLine")
    }
}

struct ReviewedImageWordingLabel: View {
    let reading: ReviewedImageWording
    var body: some View {
        LabeledContent(reading.method == .assistedImage ? pantryText("Reviewed online image reading") : pantryText("Reviewed on-device image reading"),
            value: reading.text)
    }
}
