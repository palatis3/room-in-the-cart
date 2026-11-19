import CoreDomain
import SwiftUI

struct PantryShelfView: View {
    @ObservedObject var model: PantryModel
    let scope: PantryDigestScope
    @Environment(\.pantryDigestAccess) private var currentAccess
    @ObservedObject private var store = PantryDigestStore.shared
    @State private var location = InventoryLocation.cupboard
    @State private var name = ""
    @State private var sheet: PantrySheet?
    @State private var editingLot: UUID?
    @State private var adding = false
    @State private var editingSession: PantryShelfCount?
    @State private var error = false
    @State private var selected = Set<UUID>()

    private var access: PantryDigestAccess? {
        guard let currentAccess, currentAccess.scope == scope, currentAccess.authorized(),
              model.snapshot?.state.workspaceID == scope.origin else { return nil }
        return currentAccess
    }

    var body: some View {
        List {
            if let access, let doc = try? store.document(scope), let snapshot = model.snapshot {
                if let session = doc.shelf {
                    Section(session.name.isEmpty ? pantryLocationName(session.location) : session.name) {
                        ForEach(session.batches) { row in
                            if let lot = snapshot.lots.first(where: { $0.id == row.id }), lot.location == session.location {
                                VStack(alignment: .leading, spacing: 8) {
                                    Text(lot.name).font(.headline)
                                    Text(pantryFormat("Batch %@", String(lot.id.uuidString.suffix(8))))
                                    Text(pantryCount(lot.count))
                                    LabeledContent(pantryText("Reserved"), value: pantryQuantity(snapshot.availability.lots.first { $0.id == lot.id }?.held))
                                    if let answer = session.answer(for: lot) {
                                        Text(pantryText(answer == .skipped ? "Skipped" : answer == .present ? "Still here" : "Recounted"))
                                    } else {
                                        if row.revision != lot.revision { Text(pantryText("This batch changed. Check it again.")) }
                                        Button(pantryText("Still here")) { record(.present, lot, session, access) }
                                        Button(pantryText("Recount food")) { editingSession = session; editingLot = lot.id; adding = false; sheet = .recount(lot.id) }
                                        Button(pantryText("Some left")) {
                                            editingSession = session; editingLot = lot.id; adding = false; sheet = .review
                                            Task { await model.prepare(lotID: lot.id, action: .someLeft) }
                                        }
                                        Button(pantryText("Skip")) { record(.skipped, lot, session, access) }
                                    }
                                }.buttonStyle(.borderless)
                            }
                        }
                        Button(pantryText("Add a found item")) { editingSession = session; adding = true; editingLot = nil; sheet = .found(session.location) }
                    }
                    Button(pantryText("Finish shelf count")) {
                        do { try store.updateShelf(session, next: nil, access: access) } catch { self.error = true }
                    }
                    Text(pantryText("Leave this screen to resume your count later."))
                } else {
                    Picker(pantryText("Storage location"), selection: $location) {
                        ForEach(InventoryLocation.allCases, id: \.self) { Text(pantryLocationName($0)).tag($0) }
                    }
                    TextField(pantryText("Shelf name (optional)"), text: $name)
                    let candidates = snapshot.lots.filter { $0.location == location && $0.count.quantity?.amount != .zero }
                    Section(pantryText("Choose batches to check")) {
                        ForEach(candidates) { lot in
                            Toggle(isOn: Binding(get: { selected.contains(lot.id) }, set: { on in
                                if on { selected.insert(lot.id) } else { selected.remove(lot.id) }
                            })) {
                                Text(lot.name + " · " + String(lot.id.uuidString.suffix(8)))
                            }
                        }
                    }
                    Button(pantryText("Start shelf count")) {
                        let batches = candidates.filter { selected.contains($0.id) }.map { PantryShelfCount.Batch(id: $0.id, revision: $0.revision) }
                        do { try store.updateShelf(nil, next: .init(id: UUID(), name: name, location: location, batches: batches), access: access) }
                        catch { self.error = true }
                    }.disabled(name.utf8.count > 128 || selected.count > 128)
                }
                if error { Text(pantryText("Food or reservations changed. Refresh and review again before saving.")) }
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }
        .navigationTitle(pantryText("Count one shelf"))
        .privacySensitive()
        .onChange(of: location) { _, _ in selected.removeAll() }
        .modifier(PantryEntryPresentation(model: model, accessAllowed: currentAccess?.scope == scope, sheet: $sheet, handlesReview: sheet != nil) {
            defer { editingSession = nil; editingLot = nil; adding = false }
            guard let access, let original = editingSession, let saved = model.savedLotID,
                  let doc = try? store.document(scope), var session = doc.shelf,
                  let lot = model.snapshot?.lots.first(where: { $0.id == saved }), adding || editingLot == saved,
                  session.markSaved(lot, from: original, adding: adding) else { return }
            do { try store.updateShelf(doc.shelf, next: session, access: access) } catch { self.error = true }
        })
    }

    private func record(_ answer: PantryShelfCount.Answer, _ lot: InventoryLot, _ session: PantryShelfCount, _ access: PantryDigestAccess) {
        Task {
            do {
                try await model.verifyDigestLot(lot, origin: scope.origin)
                var next = session
                guard let index = next.batches.firstIndex(where: { $0.id == lot.id }) else { return }
                next.batches[index] = .init(id: lot.id, revision: lot.revision, answer: answer)
                try store.updateShelf(session, next: next, sighting: answer == .present ? lot.id : nil, access: access)
                error = false
            } catch { self.error = true; await model.load() }
        }
    }
}
