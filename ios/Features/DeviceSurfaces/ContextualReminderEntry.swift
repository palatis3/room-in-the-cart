import SwiftUI
import DeviceSurfaces

/// A contextual entry stays attached to the exact saved workspace, pickup and
/// offer/deferral revision displayed by its originating review screen.
struct ContextualReminderRequest: Equatable {
    let target: SurfacePrivateTarget
    let sourceRevision: Int64
    let sourceSavedAt: Date

    func resolve(in targets: [SurfaceReminderTarget], at now: Date) -> SurfaceReminderTarget? {
        let matches = targets.filter { $0.target == target && $0.revision == sourceRevision }
        guard matches.count == 1, let selected = matches.first,
              selected.cutoff.map({ now < $0 }) ?? true else { return nil }
        return selected
    }
}

struct ContextualReminderLink: View {
    @EnvironmentObject private var composition: DeviceSurfacesComposition
    let request: ContextualReminderRequest

    var body: some View {
        TimelineView(.periodic(from: .now, by: 30)) { time in
            if let target = request.resolve(in: composition.reminderTargets, at: time.date) {
                NavigationLink(SurfaceCopy.text(target.cutoff == nil ? "Request a reminder for this deferral" : "Request an offer deadline reminder")) {
                    SurfaceReminderSetup(composition: composition, target: target, sourceSavedAt: request.sourceSavedAt)
                }
                .frame(minHeight: 44)
                .accessibilityIdentifier("reminder.request.\(target.id.uuidString)")
            }
        }
    }
}

/// Opening and reviewing this form never requests notification permission or
/// registers a notice. Only the shared editor's explicit Schedule action can.
struct SurfaceReminderSetup: View {
    @ObservedObject var composition: DeviceSurfacesComposition
    let target: SurfaceReminderTarget
    let sourceSavedAt: Date?
    @State private var expiry = Date().addingTimeInterval(86_400)
    @State private var reviewedExpiry = false
    @State private var context: ReminderEditorContext?
    @State private var failure = false

    init(composition: DeviceSurfacesComposition, target: SurfaceReminderTarget, sourceSavedAt: Date? = nil) {
        self.composition = composition; self.target = target; self.sourceSavedAt = sourceSavedAt
    }

    var body: some View {
        Group {
            if composition.reminderAuthorization(target) == nil { SurfaceUnavailableView() }
            else if let context, let coordinator = composition.reminders {
                ReminderEditorView(context: context, coordinator: coordinator,
                    sourceTitle: target.title, sourceSavedAt: sourceSavedAt,
                    currentAuthorization: { composition.reminderAuthorization(target) },
                    authorizeSave: { composition.authorizeReminderSave(target, reviewedGeneration: $0) })
            } else {
                Form {
                    Text(target.title).font(.headline).accessibilityIdentifier("reminder.subject")
                    if let sourceSavedAt {
                        LabeledContent(SurfaceCopy.text("Pickup last saved"), value: sourceSavedAt.formatted(date: .complete, time: .shortened))
                    }
                    Text(SurfaceCopy.text("Opening or reviewing this reminder does not schedule a notification. Your shop and retailer decision stay unchanged."))
                    if let cutoff = target.cutoff { LabeledContent(SurfaceCopy.text("Offer cutoff"), value: cutoff.formatted(date: .complete, time: .shortened)) }
                    else {
                        DatePicker(SurfaceCopy.text("Reminder expiry"), selection: $expiry)
                            .accessibilityIdentifier("reminder.expiry")
                        Toggle(SurfaceCopy.text("Use this expiry for this reminder"), isOn: $reviewedExpiry)
                            .accessibilityIdentifier("reminder.expiry.confirm")
                        Text(SurfaceCopy.text("This sets a reminder expiry. It does not date a meal or change the shopping list."))
                    }
                    Button(SurfaceCopy.text("Review reminder")) {
                        Task { do { context = try await composition.reminderContext(target, expiresAt: expiry); failure = false } catch { failure = true } }
                    }.disabled(target.cutoff == nil && !reviewedExpiry)
                        .accessibilityIdentifier("reminder.openEditor")
                    if failure { Text(SurfaceCopy.text("This reminder needs a fresh review.")) }
                }.onChange(of: expiry) { _, _ in reviewedExpiry = false }
            }
        }.navigationTitle(SurfaceCopy.text("Reminder"))
    }
}
