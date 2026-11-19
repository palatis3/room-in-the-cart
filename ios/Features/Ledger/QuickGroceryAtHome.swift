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

    private typealias Lot = PantryLiveStockProjection.Lot

    private struct Matches {
        let wording: String
        let byProduct: [UUID: [Lot]]
        let selected: UUID?
    }

    private func matches(in evidence: Evidence) -> Matches {
        let key = InventoryReceiptAlias.key(name)
        let aliases = evidence.aliases.filter { InventoryReceiptAlias.key($0.wording) == key }
        let lots = evidence.projection.lots
        let products = lots.map { (id: $0.current.foodID, name: $0.current.name) }
        let matches = GroceryPantryCandidates(name: key, products: products, confirmedAliases: Set(aliases.map(\.foodID)))
        let possible = lots.filter { matches.possible.contains($0.current.foodID) }
        let chosen = choice.flatMap { $0.wording == key ? $0.foodID : nil } ?? matches.unambiguous
        return Matches(wording: key, byProduct: Dictionary(grouping: possible) { $0.current.foodID }, selected: chosen)
    }

    @ViewBuilder private func matchView(_ evidence: Evidence) -> some View {
        let matches = matches(in: evidence)
        if !matches.byProduct.isEmpty {
            VStack(alignment: .leading, spacing: 4) {
                if let id = matches.selected, let lots = matches.byProduct[id] {
                    batchRows(lots, evidence: evidence)
                }
                if matches.selected != nil {
                    Button(quickGroceryText("Keep on list"), action: keepOnList)
                        .buttonStyle(.borderless).frame(minHeight: 44).disabled(addingDisabled)
                }
                if matches.selected == nil || matches.byProduct.count > 1 {
                    productPicker(matches)
                }
            }.accessibilityIdentifier("quickGrocery.atHome")
        }
    }

    @ViewBuilder private func batchRows(_ lots: [Lot], evidence: Evidence) -> some View {
        let ordered = lots.sorted { lhs, rhs in
            if lhs.current.confirmedAt == rhs.current.confirmedAt { return lhs.id.uuidString > rhs.id.uuidString }
            return lhs.current.confirmedAt > rhs.current.confirmedAt
        }
        let visible = allBatches ? ordered : Array(ordered.prefix(1))
        Text(quickGroceryText("Already at home?")).font(.subheadline.bold())
        ForEach(visible) { lot in
            QuickGroceryBatchRow(lot: lot, holds: evidence.holds[lot.id] ?? [],
                                 open: { open(lot, reviewedBasis: evidence.basis) })
        }
        if lots.count > 1 {
            Button(quickGroceryText(allBatches ? "Show one batch" : "Show all matching batches")) {
                allBatches.toggle()
            }.buttonStyle(.borderless).frame(minHeight: 44)
        }
    }

    private func open(_ lot: Lot, reviewedBasis: Basis) {
        guard authorize(), context.map(basis) == reviewedBasis, let model = pickup.makePantryModel() else { return }
        batch = Batch(id: lot.id, generation: pickup.privatePantryGeneration, model: model, needsReview: !lot.issues.isEmpty)
    }

    private func productPicker(_ matches: Matches) -> some View {
        let productIDs = matches.byProduct.keys.sorted { $0.uuidString < $1.uuidString }
        return DisclosureGroup(quickGroceryText("Choose a pantry product"), isExpanded: $expanded) {
            ForEach(productIDs, id: \.self) { id in
                if let lot = matches.byProduct[id]?.first {
                    let title = [lot.current.name, pantryLocationName(lot.current.location), String(id.uuidString.suffix(6))]
                        .joined(separator: " · ")
                    Button(title) {
                        choice = Choice(wording: matches.wording, foodID: id)
                        expanded = false
                        allBatches = false
                    }.buttonStyle(.borderless).frame(minHeight: 44)
                }
            }
        }
    }
}

private struct QuickGroceryBatchRow: View {
    let lot: PantryLiveStockProjection.Lot
    let holds: [InventoryReservation]
    let open: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            VStack(alignment: .leading, spacing: 3) {
                Text(lot.current.name + " · " + pantryLocationName(lot.current.location))
                let confirmed = lot.current.confirmedAt.formatted(date: .abbreviated, time: .shortened)
                Text(pantryText("Last quantity confirmation") + " · " + confirmed)
                Text(pantryText("Available for other meals") + " · " + pantryQuantity(lot.free))
                Text(pantryText("Reserved") + " · " + pantryQuantity(lot.availability.held))
                if lot.current.count.quantity == nil { Text(pantryCount(lot.current.count)) }
                if lot.issues.isEmpty { holdRows }
                if !lot.issues.isEmpty || lot.free == nil {
                    Text(pantryText("Availability needs review. Unknown food is not counted as free."))
                }
            }.font(.footnote).accessibilityElement(children: .combine)
            Button(quickGroceryText("View batch or check amount"), action: open)
                .buttonStyle(.borderless).frame(minHeight: 44)
        }
    }

    private var holdRows: some View {
        ForEach(holds.prefix(2)) { claim in
            let label = [claim.name, claim.personal?.day?.iso8601].compactMap { $0 }.joined(separator: " · ")
            Text(label)
        }
    }
}
