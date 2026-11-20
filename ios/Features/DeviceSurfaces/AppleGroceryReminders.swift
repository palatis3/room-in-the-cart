import SwiftUI
import EventKit
import CoreDomain

func applePlanningText(_ key: String) -> String {
    String(localized: String.LocalizationValue(key), table: "ApplePlanning")
}

@MainActor final class GroceryReminderReader: ObservableObject {
    struct Source: Identifiable { let id: String; let title: String }
    let store: EKEventStore
    private let requestAccess: (EKEventStore) async throws -> Bool

    init(store: EKEventStore = EKEventStore(),
         requestAccess: @escaping (EKEventStore) async throws -> Bool = { try await $0.requestFullAccessToReminders() }) {
        self.store = store
        self.requestAccess = requestAccess
    }
    @Published private(set) var sources: [Source] = []
    @Published private(set) var rows: [ReminderCopyRow] = []
    @Published private(set) var status = ""
    @Published private(set) var loading = false
    private var generation = UUID()
    private var fetchToken: Any?

    func clear() {
        generation = UUID()
        if let fetchToken { store.cancelFetchRequest(fetchToken) }
        fetchToken = nil; rows = []; sources = []; loading = false; status = ""
    }

    func loadSources() async {
        clear()
        let start = generation
        loading = true
        do {
            let granted = try await requestAccess(store)
            guard generation == start else { return }
            loading = false
            guard granted else { status = "Reminders access is unavailable. You can paste selected titles below."; return }
            sources = store.calendars(for: .reminder).map { Source(id: $0.calendarIdentifier, title: $0.title) }
            if sources.isEmpty { status = "No reminder lists are available. You can paste selected titles below." }
        } catch {
            guard generation == start else { return }
            loading = false; status = "Reminders access is unavailable. You can paste selected titles below."
        }
    }

    func loadRows(from id: String) {
        generation = UUID()
        let start = generation
        if let fetchToken { store.cancelFetchRequest(fetchToken) }
        fetchToken = nil; rows = []; loading = false; status = ""
        guard !id.isEmpty else { return }
        guard EKEventStore.authorizationStatus(for: .reminder) == .fullAccess,
              let calendar = store.calendar(withIdentifier: id), sources.contains(where: { $0.id == id }) else {
            clear(); status = "Reminders access is unavailable. You can paste selected titles below."; return
        }
        let predicate = store.predicateForIncompleteReminders(withDueDateStarting: nil, ending: nil, calendars: [calendar])
        loading = true
        fetchToken = store.fetchReminders(matching: predicate) { [weak self] reminders in
            let rows = reminders?.compactMap { item -> ReminderCopyRow? in
                guard item.calendar.calendarIdentifier == id else { return nil }
                return ReminderCopyRow(id: item.calendarItemIdentifier, title: item.title, completed: item.isCompleted)
            }
            Task { @MainActor in
                guard let self, self.generation == start else { return }
                self.fetchToken = nil; self.loading = false
                guard let rows, EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                    self.clear(); self.status = "Reminders access is unavailable. You can paste selected titles below."; return
                }
                self.rows = rows
                if rows.isEmpty { self.status = "There are no incomplete reminders in this list." }
            }
        }
    }
}

struct AppleGroceryReminders: View {
    let original: String
    let destinations: [CapturePickup]
    let authorize: () -> Bool
    let review: (String, CapturePickup) -> Bool
    @Environment(\.dismiss) private var dismiss
    @StateObject private var reader = GroceryReminderReader()
    @State private var source = ""
    @State private var selected: Set<String> = []
    @State private var pasted: [ReminderCopyRow]?
    @State private var copyMessage = ""
    @State private var destination: UUID

    init(original: String, destinations: [CapturePickup], destination: UUID, authorize: @escaping () -> Bool,
         review: @escaping (String, CapturePickup) -> Bool) {
        self.original = original; self.destinations = destinations
        self.authorize = authorize; self.review = review
        _destination = State(initialValue: destination)
    }

    private var rows: [ReminderCopyRow] { pasted ?? reader.rows }

    var body: some View {
        NavigationStack {
            WorkingForm {
                Section {
                    Text(applePlanningText("Apple requires full Reminders access to read a list. Choose one list to view its incomplete titles."))
                    Button(applePlanningText("Choose a Reminders list")) {
                        guard authorize() else { dismiss(); return }
                        source = ""; pasted = nil; selected.removeAll(); copyMessage = ""
                        Task { await reader.loadSources() }
                    }.disabled(reader.loading)
                    if !reader.sources.isEmpty {
                        Picker(applePlanningText("Source list"), selection: $source) {
                            Text(applePlanningText("Choose a list")).tag("")
                            ForEach(reader.sources) { Text(verbatim: $0.title).tag($0.id) }
                        }.onChange(of: source) { _, id in
                            guard !id.isEmpty else { return }
                            selected.removeAll(); pasted = nil; copyMessage = ""
                            if authorize() { reader.loadRows(from: id) } else { dismiss() }
                        }
                    }
                    if reader.loading { ProgressView() }
                    if !reader.status.isEmpty { Text(applePlanningText(reader.status)) }
                }
                Section {
                    Text(applePlanningText("Or copy reminder titles and paste them here, one per line."))
                    PasteButton(payloadType: String.self) { values in
                        guard authorize() else { dismiss(); return }
                        do {
                            let copied = try ReminderCopyRow.pastedTitles(values)
                            reader.clear(); selected.removeAll(); copyMessage = ""; pasted = copied
                        } catch let limit as ImportTextLimit { copyMessage = ledgerImportLimitMessage(limit) }
                        catch { copyMessage = applePlanningText("Check the copied titles and try again.") }
                    }
                }
                if !rows.isEmpty {
                    Section(applePlanningText("Select titles to copy")) {
                        ForEach(rows) { row in
                            Toggle(isOn: Binding(get: { selected.contains(row.id) }, set: { enabled in
                                if enabled { selected.insert(row.id) } else { selected.remove(row.id) }
                            })) { Text(verbatim: row.title) }
                        }
                    }
                }
                Section {
                    Picker(applePlanningText("Destination pickup"), selection: $destination) {
                        ForEach(destinations) { Text(verbatim: $0.title).tag($0.id) }
                    }
                    Button(applePlanningText("Review selected titles")) {
                        guard authorize(), let target = destinations.first(where: { $0.id == destination }) else { dismiss(); return }
                        guard pasted != nil || EKEventStore.authorizationStatus(for: .reminder) == .fullAccess else {
                            reader.clear(); selected.removeAll()
                            copyMessage = applePlanningText("Reminders access is unavailable. You can paste selected titles below."); return
                        }
                        do {
                            let text = try ReminderCopyRow.selectedText(rows: rows, selected: selected, appendingTo: original)
                            if review(text, target) { dismiss() }
                            else { copyMessage = applePlanningText("The destination changed. Close and choose the pickup again.") }
                        } catch let limit as ImportTextLimit { copyMessage = ledgerImportLimitMessage(limit) }
                        catch { copyMessage = applePlanningText("Check the copied titles and try again.") }
                    }.disabled(selected.isEmpty)
                    Text(applePlanningText("Review duplicates before adding the copy. The original reminders and completion states stay in Reminders."))
                    if !copyMessage.isEmpty { Text(verbatim: copyMessage) }
                }
            }.navigationTitle(applePlanningText("Copy from Reminders"))
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button(applePlanningText("Cancel")) { dismiss() } } }
                .onDisappear { reader.clear() }
                .onReceive(NotificationCenter.default.publisher(for: .EKEventStoreChanged, object: reader.store)) { _ in
                    guard pasted == nil, !source.isEmpty else { return }
                    selected.removeAll()
                    if authorize() { reader.loadRows(from: source) } else { dismiss() }
                }
        }
    }
}
