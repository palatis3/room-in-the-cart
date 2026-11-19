import CoreDomain
import LocalStore
import SwiftUI

struct QuickGroceryAtHome: View {
    let name: String
    let branch: String
    let ledgerWorkspaceID: UUID
    let authorize: @MainActor () -> Bool
    let addingDisabled: Bool
    let keepOnList: () -> Void
    @EnvironmentObject private var pickup: PickupModel
    @Environment(\.locale) private var locale
    @State private var evidence: Evidence?
    @State private var choice: Choice?
    @State private var expanded = false
    @State private var allBatches = false
    @State private var batch: Batch?

    private struct Basis: Equatable {
        let generation: UUID
        let origin: UUID
        let revision: Int64
        let heads: [PantryLiveStockProjection.HeadRevision]
        let branch: String
        let language: String
    }

    private struct Evidence {
        let basis: Basis
        let projection: PantryLiveStockProjection
        let aliases: [InventoryReceiptAlias]
        let holds: [UUID: [InventoryReservation]]
    }

    private struct Choice { let wording: String; let foodID: UUID }
    private struct Batch: Identifiable {
        let id: UUID
        let generation: UUID
        let model: PantryModel
        let needsReview: Bool
    }

    private var context: PantryPackStockReview.Context? {
        guard authorize() else { return nil }
        return try? pickup.quickGroceryPantryContext(ledgerWorkspaceID: ledgerWorkspaceID)
    }

    private func basis(_ context: PantryPackStockReview.Context) -> Basis {
        Basis(generation: pickup.privatePantryGeneration, origin: context.snapshot.state.workspaceID,
              revision: context.snapshot.state.revision,
              heads: context.mapping.sourceHeads.map { .init(journeyID: $0.id, storeRevision: $0.revision) },
              branch: branch, language: locale.language.languageCode?.identifier == "es" ? "es" : "en")
    }

    var body: some View {
        let context = context
        let current = context.map(basis)
        VStack(alignment: .leading, spacing: 0) {
            if let evidence, evidence.basis == current {
                matchView(evidence)
            }
        }
        .privacySensitive()
        .task(id: current) {
            evidence = nil
            guard let current, let context, let projection = try? PantryLiveStockProjection.buildGlobal(
                snapshot: context.snapshot, mapping: context.mapping, at: context.asOf) else { return }
            let aliases = (try? await pickup.quickGroceryAliases(merchant: branch, language: current.language, origin: current.origin)) ?? []
            guard !Task.isCancelled, authorize(), self.context.map(basis) == current else { return }
            let claims = Dictionary(uniqueKeysWithValues: context.snapshot.reservations.map { ($0.id, $0) })
            let edges = Dictionary(grouping: context.snapshot.availability.allocations, by: \.lotID)
            let holds = edges.mapValues { edges in edges.compactMap { claims[$0.needID] } }
            evidence = Evidence(basis: current, projection: projection, aliases: aliases, holds: holds)
        }
        .onChange(of: name) { _, _ in choice = nil; expanded = false; allBatches = false }
        .sheet(item: $batch) { opened in
            NavigationStack {
                if authorize(), pickup.privatePantryGeneration == opened.generation {
                    PantryLotEntryView(model: opened.model, lotID: opened.id, accessAllowed: true,
                                       availabilityNeedsReview: opened.needsReview)
                        .toolbar {
                            ToolbarItem(placement: .cancellationAction) {
                                Button(ledgerText("Done")) { batch = nil }.disabled(opened.model.busy || opened.model.pending != nil)
                            }
                        }
                }
            }
        }
    }

    @ViewBuilder private func matchView(_ evidence: Evidence) -> some View {
        let key = InventoryReceiptAlias.key(name)
        let aliases = Set(evidence.aliases.filter { InventoryReceiptAlias.key($0.wording) == key }.map(\.foodID))
        let lots = evidence.projection.lots
        let matches = GroceryPantryCandidates(name: key, products: lots.map { ($0.current.foodID, $0.current.name) },
                                             confirmedAliases: aliases)
        let possible = lots.filter { matches.possible.contains($0.current.foodID) }
        let candidates = Dictionary(grouping: possible, by: { $0.current.foodID })
        let chosen = choice.flatMap { $0.wording == key ? $0.foodID : nil } ?? matches.unambiguous
        if !possible.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let chosen, let matches = candidates[chosen] {
                    Text(quickGroceryText("Already at home?")).font(.subheadline.bold())
                    let ordered = matches.sorted { ($0.current.confirmedAt, $0.id.uuidString) > ($1.current.confirmedAt, $1.id.uuidString) }
                    ForEach(allBatches ? ordered : Array(ordered.prefix(1))) { lot in
                        let label = pantryLocationName(lot.current.location)
                        VStack(alignment: .leading, spacing: 3) {
                            Text(lot.current.name + " · " + label)
                            Text(pantryText("Last quantity confirmation") + " · " + lot.current.confirmedAt.formatted(date: .abbreviated, time: .shortened))
                            Text(pantryText("Available for other meals") + " · " + pantryQuantity(lot.free))
                            Text(pantryText("Reserved") + " · " + pantryQuantity(lot.availability.held))
                            if lot.current.count.quantity == nil { Text(pantryCount(lot.current.count)) }
                            if lot.issues.isEmpty {
                                ForEach((evidence.holds[lot.id] ?? []).prefix(2)) { claim in
                                    Text([claim.name, claim.personal?.day?.iso8601].compactMap { $0 }.joined(separator: " · "))
                                }
                            }
                            if !lot.issues.isEmpty || lot.free == nil {
                                Text(pantryText("Availability needs review. Unknown food is not counted as free."))
                            }
                        }.font(.footnote).accessibilityElement(children: .combine)
                        Button(quickGroceryText("View batch or check amount")) {
                            guard authorize(), self.context.map(basis) == evidence.basis, let model = pickup.makePantryModel() else { return }
                            batch = Batch(id: lot.id, generation: pickup.privatePantryGeneration, model: model, needsReview: !lot.issues.isEmpty)
                        }.buttonStyle(.borderless).frame(minHeight: 44)
                    }
                    if matches.count > 1 {
                        Button(quickGroceryText(allBatches ? "Show one batch" : "Show all matching batches")) {
                            allBatches.toggle()
                        }.buttonStyle(.borderless).frame(minHeight: 44)
                    }
                }
                if chosen != nil {
                    Button(quickGroceryText("Keep on list"), action: keepOnList)
                        .buttonStyle(.borderless).frame(minHeight: 44).disabled(addingDisabled)
                }
                if chosen == nil || candidates.count > 1 {
                    DisclosureGroup(quickGroceryText("Choose a pantry product"), isExpanded: $expanded) {
                        ForEach(candidates.keys.sorted { $0.uuidString < $1.uuidString }, id: \.self) { id in
                            if let lot = candidates[id]?.first {
                                Button(lot.current.name + " · " + pantryLocationName(lot.current.location) + " · " + String(id.uuidString.suffix(6))) {
                                    choice = Choice(wording: key, foodID: id); expanded = false; allBatches = false
                                }.buttonStyle(.borderless).frame(minHeight: 44)
                            }
                        }
                    }
                }
            }.accessibilityIdentifier("quickGrocery.atHome")
        }
    }
}
