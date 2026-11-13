import SwiftUI
import UIKit

@main struct TypeControlApp: App {
  var body: some Scene {
    WindowGroup {
      if ProcessInfo.processInfo.arguments.contains("--sheet") {
        SheetEntry()
      } else {
        Form {
          Text("Body text")
          Text("Headline text").font(.headline)
          Label("Protected meal commitments", systemImage: "lock").font(.headline)
          LabeledContent("Protected portions", value: "1").font(.caption)
          VStack(alignment: .leading) {
            Text("Sam’s wrap lunch").font(.subheadline.weight(.semibold))
            Text("Lunch · Tuesday").font(.caption)
            LabeledContent("Combined portions", value: "1").font(.caption)
          }.accessibilityElement(children: .combine).accessibilityIdentifier("meal")
          Button("Apply reviewed decision") {}
          NativeLabel()
        }
      }
    }
  }
}
struct NativeLabel: UIViewRepresentable {
  func makeUIView(context: Context) -> UILabel {
    let v = UILabel()
    v.font = UIFont.preferredFont(forTextStyle: .body)
    v.adjustsFontForContentSizeCategory = true
    v.numberOfLines = 0
    v.text = "UIKit reference"
    return v
  }
  func updateUIView(_ view: UILabel, context: Context) {}
}

private struct SheetEntry: View {
  @State var showing = false
  var body: some View {
    Button("Open stock sheet") { showing = true }
      .sheet(isPresented: $showing) {
        NavigationStack {
          ScrollViewReader { proxy in
            Form {
              Section("Input") {
                ForEach(0..<12) { Text("Input row " + String($0)) }
                Button("Review") { proxy.scrollTo("summary", anchor: .top) }
              }
              Section("Review before applying") {
                Text("Add packs to this shop").font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                  Text("After this decision").font(.headline)
                  LabeledContent("Expected total", value: "$40.69")
                  LabeledContent("Over cap", value: "$2.69")
                  LabeledContent("Before this decision", value: "$37.20")
                  Label("Protected meal commitments", systemImage: "lock").font(.headline)
                  ForEach(["Sam’s wrap lunch", "Mia’s wrap lunch"], id: \.self) { title in
                    VStack(alignment: .leading, spacing: 2) {
                      Text(title).font(.subheadline.weight(.semibold))
                      Text("Lunch · November 4, 2026").font(.caption)
                      LabeledContent("Protected portions", value: "1").font(.caption)
                    }.accessibilityElement(children: .combine)
                  }
                  Text("Check usable food separately; this review does not confirm meal coverage.")
                    .font(.caption).foregroundStyle(.secondary)
                }.id("summary")
                DisclosureGroup("Checkout calculation details") { Text("Details") }
                Toggle("I accept the displayed overage", isOn: .constant(false))
                Button("Apply reviewed decision") {}.disabled(true)
                Button("Cancel preview") {}
              }
            }
          }.navigationTitle("Review request")
            .toolbar {
              ToolbarItem(placement: .cancellationAction) { Button("Cancel") { showing = false } }
            }
        }.presentationDetents([.large])
      }
  }
}
