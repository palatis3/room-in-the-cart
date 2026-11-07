import SwiftUI

// Standalone diagnostic: no application model, production endpoints or data.
@main
struct FormToggleDiagnostic: App {
    var body: some Scene { WindowGroup { ToggleControl() } }
}

private struct ToggleControl: View {
    private enum Field: Hashable { case store, branch, slot, source, cap }
    @FocusState private var field: Field?
    @State private var store = ""
    @State private var branch = ""
    @State private var slot = ""
    @State private var source = ""
    @State private var cap = ""
    @State private var inclusive = false
    @State private var total = ""
    @State private var complete = true
    @State private var sample = ""
    @State private var extras = ""
    @State private var observed = Date()
    @State private var mode = "Pickup"
    @State private var scope = "Whole checkout"

    var body: some View {
        TabView {
            NavigationStack {
                Form {
                    Section("Retailer preview · source and time") {
                        TextField("Store", text: $store).focused($field, equals: .store)
                        TextField("Branch", text: $branch).focused($field, equals: .branch)
                        TextField("Pickup or delivery slot", text: $slot).focused($field, equals: .slot)
                        TextField("Source of these prices", text: $source).focused($field, equals: .source)
                        DatePicker("Observed", selection: $observed)
                        Picker("Shopping mode", selection: $mode) {
                            ForEach(["Pickup", "Delivery", "In store"], id: \.self) { Text($0) }
                        }
                        Picker("Scope", selection: $scope) {
                            ForEach(["Whole checkout", "Dinners only", "Selected items only"], id: \.self) { Text($0) }
                        }
                        TextField("Spending cap", text: $cap).keyboardType(.decimalPad).focused($field, equals: .cap)
                    }
                    Section("Expected charges · USD") {
                        Toggle("Retailer total already includes all charges", isOn: $inclusive)
                        Text("Blank means unknown. Enter 0 only for a confirmed zero charge.")
                        if inclusive {
                            TextField("Inclusive total", text: $total).keyboardType(.decimalPad)
                        } else {
                            TextField("Wraps", text: $sample).keyboardType(.decimalPad)
                            Toggle("All original items are represented", isOn: $complete)
                            ForEach(["Fee below threshold or fixed fee", "Fee waived at subtotal (optional)", "Eligible discount", "Tax", "Deposits and other charges"], id: \.self) { label in
                                TextField(label, text: $extras).keyboardType(.decimalPad)
                            }
                        }
                        Button("Save and evaluate checkout") { }
                    }
                    Section("Payment hold · separate from spending") { Text("Compare an authorization hold") }
                }
                .navigationTitle("Whole checkout")
                .scrollDismissesKeyboard(.interactively)
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    if field != nil {
                        HStack { Spacer(); Button("Done") { field = nil }.font(.body.weight(.semibold)).frame(minHeight: 44) }
                            .padding(.horizontal).background(.bar)
                    }
                }
            }.tabItem { Label("Shop", systemImage: "cart") }
            Text("Dinners").tabItem { Label("Dinners", systemImage: "fork.knife") }
            Text("Records").tabItem { Label("Records", systemImage: "clock") }
        }
    }
}
