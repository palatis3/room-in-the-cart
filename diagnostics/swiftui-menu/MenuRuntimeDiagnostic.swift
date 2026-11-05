import SwiftUI

@main
struct MenuRuntimeDiagnostic: App {
    @State private var selectedPickup = "Original pickup"
    @State private var menuActions = 0

    var body: some Scene {
        WindowGroup {
            if ProcessInfo.processInfo.arguments.contains("--fixture-menu-context") {
                fixtureContext
            } else {
                pickupContext
            }
        }
    }

    private var pickupContext: some View {
        NavigationStack {
            VStack(spacing: 0) {
                HStack {
                    Menu {
                        Button("Original pickup") { menuActions += 1 }
                        Button("Start another pickup") {
                            menuActions += 1
                            selectedPickup = "Another pickup"
                        }
                    } label: {
                        Label(selectedPickup, systemImage: "chevron.down")
                            .font(.headline)
                            .frame(minHeight: 44)
                    }
                    .accessibilityIdentifier("probe.pickupMenu")
                    Spacer()
                }
                .padding(.horizontal)
                statusList
            }
            .navigationTitle("Menu diagnostic")
        }
    }

    private var fixtureContext: some View {
        VStack(spacing: 2) {
            HStack {
                Button("Use alternate fixture view") { menuActions += 1 }
                Menu("Fixture controls") {
                    Button("Advance fixture revision") { menuActions += 1 }
                    Button("Reset fixture", role: .destructive) { menuActions += 1 }
                }
                .accessibilityIdentifier("probe.fixtureMenu")
            }
            .dynamicTypeSize(.large)
            NavigationStack {
                statusList.navigationTitle("Menu diagnostic")
            }
        }
    }

    private var statusList: some View {
        List {
            Section("Unchanged state") {
                Text("Selected pickup: \(selectedPickup)").accessibilityIdentifier("probe.pickup")
                Text("Menu actions: \(menuActions)").accessibilityIdentifier("probe.actions")
            }
        }
        .listStyle(.insetGrouped)
    }
}
