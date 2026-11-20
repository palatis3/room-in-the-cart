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
                    let byID = Dictionary(uniqueKeysWithValues: snapshot.lots.map { ($0.id, $0) })
                    let shelf = session.batches.compactMap { byID[$0.id] }.filter { $0.location == session.location }
                    let remaining = shelf.filter { session.answer(for: $0) == nil }
                    let answered = shelf.filter { session.answer(for: $0) != nil }
                    Section {
                        if let lot = remaining.first {
                            shelfLot(lot, session: session, snapshot: snapshot, access: access)
                        }
                        if remaining.count > 1 {
                            DisclosureGroup(pantryText("Other batches to check")) {
                                ForEach(remaining.dropFirst()) { lot in
                                    shelfLot(lot, session: session, snapshot: snapshot, access: access)
                                }
                            }
                        }
                        if !answered.isEmpty {
                            DisclosureGroup(pantryText("Reviewed batches")) {
                                ForEach(answered) { lot in
                                    shelfLot(lot, session: session, snapshot: snapshot, access: access)
                                }
                            }
                        }
                        Button(pantryText("Add a found item")) { editingSession = session; adding = true; editingLot = nil; sheet = .found(session.location) }
                    } header: {
                        Text(session.name.isEmpty ? pantryLocationName(session.location) : session.name)
                    } footer: {
                        Text(pantryText("Leave this screen to resume your count later."))
                    }
                    Button(pantryText("Finish shelf count")) {
                        do { try store.updateShelf(session, next: nil, access: access) } catch { self.error = true }
                    }
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
                    }.buttonStyle(PrimaryAction()).disabled(name.utf8.count > 128 || selected.count > 128)
                }
                if error { Text(pantryText("Food or reservations changed. Refresh and review again before saving.")) }
            } else { Text(pantryText("Unlock the authorized private workspace to view pantry food.")) }
        }
        .workingSurface()
        .navigationTitle(pantryText("Count one shelf"))
        .privacySensitive()
        .onChange(of: location) { _, _ in selected.removeAll() }
        .modifier(PantryEntryPresentation(model: model, accessAllowed: currentAccess?.scope == scope, sheet: $sheet, handlesReview: sheet != nil, didSave: {
            defer { editingSession = nil; editingLot = nil; adding = false }
            guard let access, let original = editingSession, let saved = model.savedLotID,
                  let doc = try? store.document(scope), var session = doc.shelf,
                  let lot = model.snapshot?.lots.first(where: { $0.id == saved }), adding || editingLot == saved,
                  session.markSaved(lot, from: original, adding: adding) else { return }
            do { try store.updateShelf(doc.shelf, next: session, access: access) } catch { self.error = true }
        }))
    }

    private func shelfLot(_ lot: InventoryLot, session: PantryShelfCount, snapshot: PantryRepository.Snapshot, access: PantryDigestAccess) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(lot.name).font(.title3.weight(.semibold))
            Text(pantryCount(lot.count)).monospacedDigit()
            LabeledContent(pantryText("Reserved"), value: pantryQuantity(snapshot.availability.lots.first { $0.id == lot.id }?.held))
            Text(pantryFormat("Batch %@", String(lot.id.uuidString.suffix(8)))).font(.footnote).foregroundStyle(Theme.secondary)
            if let answer = session.answer(for: lot) {
                Label(pantryText(answer == .skipped ? "Skipped" : answer == .present ? "Still here" : "Recounted"),
                      systemImage: answer == .skipped ? "forward" : "checkmark.circle")
                    .foregroundStyle(Theme.ink)
            } else {
                if session.batches.first(where: { $0.id == lot.id })?.revision != lot.revision {
                    Text(pantryText("This batch changed. Check it again.")).foregroundStyle(Theme.warning)
                }
                Button(pantryText("Still here")) { record(.present, lot, session, access) }
                    .buttonStyle(PrimaryAction())
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 16) { shelfActions(lot, session: session, access: access) }
                        .fixedSize(horizontal: true, vertical: false)
                    VStack(alignment: .leading, spacing: 2) { shelfActions(lot, session: session, access: access) }
                }
            }
        }.buttonStyle(.borderless).padding(.vertical, 4)
    }

    @ViewBuilder private func shelfActions(_ lot: InventoryLot, session: PantryShelfCount, access: PantryDigestAccess) -> some View {
        Button(pantryText("Recount food")) {
            editingSession = session; editingLot = lot.id; adding = false; sheet = .recount(lot.id)
        }.frame(minHeight: 44)
        Button(pantryText("Some left")) {
            editingSession = session; editingLot = lot.id; adding = false; sheet = .review
            Task { await model.prepare(lotID: lot.id, action: .someLeft) }
        }.frame(minHeight: 44)
        Button(pantryText("Skip")) { record(.skipped, lot, session, access) }.frame(minHeight: 44)
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
