import SwiftUI
import CoreDomain

struct DinnerRotationsView: View {
    @ObservedObject var model: DinnerFeatureModel
    let weekStart: Date
    var body: some View {
        List {
            Section {
                Text(dinnerText("A rotation stores accepted dinner versions and relative nights. Select the nights to preview before adding any groceries."))
                if model.paid {
                    NavigationLink(dinnerText("Create rotation")) { DinnerRotationEditor(model: model, existing: nil) }
                } else {
                    Text(dinnerText("Rotations require paid access. You can still choose and date dinners individually."))
                    NavigationLink(dinnerText("Add a manual dinner")) { DinnerTemplateEditor(model: model, purpose: .manual) }
                }
            }
            ForEach(model.state.rotations) { rotation in
                Section(rotation.title) {
                    NavigationLink(dinnerText("Choose rotation nights")) { DinnerRotationReview(model: model, rotation: rotation, initialStart: weekStart) }
                        .disabled(!model.paid)
                    NavigationLink(dinnerText("Edit rotation")) { DinnerRotationEditor(model: model, existing: rotation) }.disabled(!model.paid)
                }
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Rotations")).dinnerAccess(model)
    }
}
private struct DinnerRotationRow: Identifiable {
    var id = UUID(); var acceptedDinnerID: UUID?; var offset = -1; var pinned = false
}
struct DinnerRotationEditor: View {
    @ObservedObject var model: DinnerFeatureModel
    let existing: DinnerRotation?
    @State private var id: UUID
    @State private var title: String
    @State private var entries: [DinnerRotationRow]
    @Environment(\.dismiss) private var dismiss
    init(model: DinnerFeatureModel, existing: DinnerRotation?) {
        self.model = model; self.existing = existing
        _id = State(initialValue: existing?.id ?? UUID()); _title = State(initialValue: existing?.title ?? "")
        _entries = State(initialValue: existing?.entries.map { DinnerRotationRow(id: $0.id, acceptedDinnerID: $0.acceptedDinnerID, offset: $0.dayOffset ?? -1, pinned: $0.pinned) } ?? [DinnerRotationRow()])
    }
    var body: some View {
        Form {
            Section {
                TextField(dinnerText("Rotation name"), text: $title)
                ForEach($entries) { $entry in
                    VStack(alignment: .leading, spacing: 8) {
                        Picker(dinnerText("Accepted dinner"), selection: $entry.acceptedDinnerID) {
                            Text(dinnerText("Select dinner")).tag(UUID?.none)
                            ForEach(model.state.acceptedDinners) { Text($0.template.title).tag(Optional($0.id)) }
                        }
                        Picker(dinnerText("Night relative to week start"), selection: $entry.offset) {
                            Text(dinnerText("Unscheduled")).tag(-1)
                            ForEach(0..<7) { Text(dinnerFormat("Day %d", $0 + 1)).tag($0) }
                        }
                        Toggle(dinnerText("Pin this dinner"), isOn: $entry.pinned)
                        Button(dinnerText("Remove rotation entry"), role: .destructive) { entries.removeAll { $0.id == entry.id } }
                    }.padding(.vertical, 6)
                }
                Button(dinnerText("Add rotation entry")) { entries.append(DinnerRotationRow()) }.disabled(entries.count >= 100)
                Button(dinnerText("Save rotation")) {
                    Task {
                        do {
                            let converted = try entries.map { row -> DinnerRotationEntry in
                                guard let id = row.acceptedDinnerID else { throw DinnerPlanningError.reviewRequired("acceptedDinner") }
                                return DinnerRotationEntry(id: row.id, acceptedDinnerID: id, dayOffset: row.offset < 0 ? nil : row.offset, pinned: row.pinned)
                            }
                            let revision: Int
                            if let existing {
                                let (next, overflow) = existing.revision.addingReportingOverflow(1)
                                guard !overflow else { throw DomainError.overflow }; revision = next
                            } else { revision = 0 }
                            if await model.saveRotation(DinnerRotation(id: id, revision: revision, title: title, entries: converted)) { dismiss() }
                        } catch { model.report(error) }
                    }
                }.disabled(!model.paid || !model.editable)
            }
            DinnerFeedback(model: model)
        }.navigationTitle(dinnerText("Edit rotation")).dinnerAccess(model)
    }
}
struct DinnerRotationReview: View {
    @ObservedObject var model: DinnerFeatureModel
    let rotation: DinnerRotation
    @State private var start: Date
    @State private var selected = Set<UUID>()
    @State private var showPreview = false
    init(model: DinnerFeatureModel, rotation: DinnerRotation, initialStart: Date) {
        self.model = model; self.rotation = rotation; _start = State(initialValue: initialStart)
    }
    var body: some View {
        Form {
            Section {
                DatePicker(dinnerText("Week starting"), selection: $start, displayedComponents: .date)
                Text(model.shop?.basis.timeZoneIdentifier ?? "")
                Text(dinnerText("Select only the entries you want to add. Existing chosen dinners remain unchanged."))
                ForEach(rotation.entries) { entry in
                    Toggle(isOn: Binding(get: { selected.contains(entry.id) }, set: { if $0 { selected.insert(entry.id) } else { selected.remove(entry.id) } })) {
                        VStack(alignment: .leading) {
                            Text(model.state.acceptedDinners.first { $0.id == entry.acceptedDinnerID }?.template.title ?? dinnerText("Unavailable dinner"))
                            Text(entry.dayOffset.map { dinnerFormat("Day %d", $0 + 1) } ?? dinnerText("Unscheduled"))
                            if entry.pinned { Text(dinnerText("Pinned")) }
                        }
                    }
                }
                Button(dinnerText("Preview selected nights")) {
                    do {
                        guard let shop = model.shop else { return }
                        showPreview = model.previewRotation(rotation, selected: rotation.entries.filter { selected.contains($0.id) }.map(\.id),
                            start: try MealDay(date: start, timeZoneIdentifier: shop.basis.timeZoneIdentifier))
                    } catch { model.report(error) }
                }.disabled(selected.isEmpty || !model.paid || !model.editable)
            }
            DinnerFeedback(model: model)
        }.navigationTitle(rotation.title).dinnerAccess(model)
            .dinnerApplyPresentation(model, presented: $showPreview)
    }
}
