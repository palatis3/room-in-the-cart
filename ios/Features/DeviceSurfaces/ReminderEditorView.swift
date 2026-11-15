import SwiftUI
import DeviceSurfaces

public struct ReminderEditorContext: Sendable {
    public let reminderID: UUID, personaID: UUID, targetID: UUID
    public let subject: ReminderSubject
    public let sourceRevision: Int64
    public let routeHandle: RouteHandle
    public let expiresAt: Date
    public let cutoff: Date?
    public let cutoffTimeZoneID: String
    public let initialFireAt: Date
    public let timeZoneID: String
    public let initialQuietHours: QuietHours?
    public let expectedVersion: Int64?
    public init(reminderID: UUID = UUID(), personaID: UUID, targetID: UUID, subject: ReminderSubject, sourceRevision: Int64, routeHandle: RouteHandle, expiresAt: Date, cutoff: Date?, initialFireAt: Date, timeZoneID: String, initialQuietHours: QuietHours?, expectedVersion: Int64?, cutoffTimeZoneID: String? = nil) {
        self.reminderID = reminderID; self.personaID = personaID; self.targetID = targetID; self.subject = subject; self.sourceRevision = sourceRevision
        self.routeHandle = routeHandle; self.expiresAt = expiresAt; self.cutoff = cutoff; self.initialFireAt = initialFireAt; self.timeZoneID = timeZoneID; self.expectedVersion = expectedVersion
        self.cutoffTimeZoneID = cutoffTimeZoneID ?? timeZoneID
        self.initialQuietHours = initialQuietHours
    }
}

/// Keep the retailer's deadline in its saved zone even when the reminder is set in another zone.
func reminderCutoffText(_ cutoff: Date, timeZoneID: String, locale: Locale) -> String {
    var style = Date.FormatStyle(date: .complete, time: .shortened, locale: locale)
    guard let zone = TimeZone(identifier: timeZoneID) else { return SurfaceCopy.text("Review the date, time and time zone before continuing.") }
    style.timeZone = zone
    return "\(cutoff.formatted(style)) · \(timeZoneID)"
}

/// DatePicker needs a date. These values represent recurring wall-clock times,
/// so the picker and the minute conversion share a fixed zone without DST.
struct ReminderQuietHoursDraft: Equatable {
    var start: Date
    var end: Date

    init(_ saved: QuietHours?) {
        start = Date(timeIntervalSinceReferenceDate: TimeInterval((saved?.startMinute ?? 22 * 60) * 60))
        end = Date(timeIntervalSinceReferenceDate: TimeInterval((saved?.endMinute ?? 7 * 60) * 60))
    }

    func interval() throws -> QuietHours {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = .gmt
        func minuteOfDay(_ date: Date) -> Int {
            calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)
        }
        return try QuietHours(startMinute: minuteOfDay(start), endMinute: minuteOfDay(end))
    }
}

@MainActor public struct ReminderEditorView: View {
    private let context: ReminderEditorContext
    private let coordinator: ReminderCoordinator
    private let sourceTitle: String?
    private let sourceSavedAt: Date?
    /// Root returns a generation only when both current persona AND current subject revision are permitted.
    private let currentAuthorization: () -> UUID?
    private let authorizeSave: (UUID) -> ReminderCoordinator.SaveAuthorization?
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var fireAt: Date
    @State private var timeZoneID: String
    @FocusState private var timeZoneFocused: Bool
    @State private var quiet: Bool
    @State private var quietTimes: ReminderQuietHoursDraft
    @State private var reviewed: ReminderIntent?
    @State private var reviewedGeneration: UUID?
    @State private var version: Int64?
    @State private var busy = false
    @State private var message: String?
    @State private var saved: SavedReminder?
    @State private var statusLoaded = false
    @State private var statusLoadFailed = false
    public init(context: ReminderEditorContext, coordinator: ReminderCoordinator, sourceTitle: String? = nil, sourceSavedAt: Date? = nil,
                currentAuthorization: @escaping () -> UUID?, authorizeSave: @escaping (UUID) -> ReminderCoordinator.SaveAuthorization?) {
        self.context = context; self.coordinator = coordinator; self.sourceTitle = sourceTitle; self.sourceSavedAt = sourceSavedAt; self.currentAuthorization = currentAuthorization
        self.authorizeSave = authorizeSave
        _fireAt = State(initialValue: context.initialFireAt); _timeZoneID = State(initialValue: context.timeZoneID); _version = State(initialValue: context.expectedVersion)
        _quiet = State(initialValue: context.initialQuietHours != nil)
        _quietTimes = State(initialValue: ReminderQuietHoursDraft(context.initialQuietHours))
    }
    public var body: some View {
        Form {
            if let sourceTitle {
                Section {
                    Text(sourceTitle).font(.headline).accessibilityIdentifier("reminder.subject")
                    if let sourceSavedAt { LabeledContent(SurfaceCopy.text("Pickup last saved"), value: display(sourceSavedAt)) }
                }
            }
            Section(SurfaceCopy.text("Current reminder")) {
                Text(statusText).accessibilityIdentifier("reminder.status").accessibilityAddTraits(.updatesFrequently)
                if let saved, saved.status == .scheduled {
                    Text(display(saved.intent.fireAt, timeZone: saved.intent.localTime.timeZoneID))
                    Text(saved.intent.localTime.timeZoneID)
                }
            }
            Section {
                Text(SurfaceCopy.text("Choose a reminder for this item. The notification contains no grocery or budget details."))
                DatePicker(SurfaceCopy.text("Reminder time"), selection: $fireAt).environment(\.timeZone, TimeZone(identifier: timeZoneID) ?? .gmt)
                    .accessibilityIdentifier("reminder.time")
                TextField(SurfaceCopy.text("Time zone"), text: $timeZoneID).textInputAutocapitalization(.never).autocorrectionDisabled()
                    .focused($timeZoneFocused).submitLabel(.done).onSubmit { timeZoneFocused = false }
                Toggle(SurfaceCopy.text("Quiet hours"), isOn: $quiet).accessibilityIdentifier("reminder.quietHours")
                if quiet {
                    DatePicker(SurfaceCopy.text("Quiet hours start"), selection: $quietTimes.start, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, .gmt)
                        .accessibilityIdentifier("reminder.quietStart")
                    DatePicker(SurfaceCopy.text("Quiet hours end"), selection: $quietTimes.end, displayedComponents: .hourAndMinute)
                        .environment(\.timeZone, .gmt)
                        .accessibilityIdentifier("reminder.quietEnd")
                }
                LabeledContent(SurfaceCopy.text("Expires"), value: display(context.expiresAt))
                if let cutoff = context.cutoff {
                    LabeledContent(SurfaceCopy.text("Offer cutoff"),
                                   value: reminderCutoffText(cutoff, timeZoneID: context.cutoffTimeZoneID, locale: locale))
                }
                Button(SurfaceCopy.text("Review reminder")) { prepare() }.frame(minHeight: 44).accessibilityIdentifier("reminder.review")
            }
            if let reviewed {
                Section(SurfaceCopy.text("Review reminder")) {
                    Text(display(reviewed.fireAt)); Text(reviewed.localTime.timeZoneID)
                    Text(SurfaceCopy.text("Nothing is scheduled until you confirm. Quiet hours never move the chosen time automatically."))
                    Button(SurfaceCopy.text("Schedule reminder")) { save(reviewed) }.frame(minHeight: 44).accessibilityIdentifier("reminder.schedule")
                }
            }
            if let message { Text(message).accessibilityAddTraits(.updatesFrequently) }
            Button(SurfaceCopy.text("Turn off this reminder"), role: .destructive) { turnOff() }.frame(minHeight: 44).accessibilityIdentifier("reminder.turnOff")
                .disabled(!statusLoaded || statusLoadFailed || saved == nil || saved?.status == .cancelled)
        }.disabled(busy).navigationTitle(SurfaceCopy.text("Reminder"))
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(SurfaceCopy.text(saved?.status == .scheduled ? "Done" : "Cancel")) { dismiss() }.disabled(busy).accessibilityIdentifier("reminder.close") } }
            .keyboardDoneAction(visible: timeZoneFocused, title: SurfaceCopy.text("Done"), identifier: "reminder.keyboardDone") { timeZoneFocused = false }
            .interactiveDismissDisabled(busy)
            .task(id: currentAuthorization()) {
                guard let generation = currentAuthorization() else { return }
                do {
                    let current = try await coordinator.current(context.reminderID)
                    guard currentAuthorization() == generation, !busy else { return }
                    saved = current; statusLoaded = true; statusLoadFailed = false
                } catch {
                    guard currentAuthorization() == generation else { return }
                    statusLoaded = true; statusLoadFailed = true
                }
            }
            .onChange(of: fireAt) { _, _ in clearReview() }.onChange(of: timeZoneID) { _, _ in clearReview() }
            .onChange(of: quiet) { _, _ in clearReview() }.onChange(of: quietTimes) { _, _ in clearReview() }
    }
    private var statusText: String {
        if busy { return SurfaceCopy.text("Reminder update pending. Wait for the saved result.") }
        if !statusLoaded { return SurfaceCopy.text("Checking the saved reminder…") }
        if statusLoadFailed { return SurfaceCopy.text("This reminder needs a fresh review.") }
        switch saved?.status {
        case .scheduled: return SurfaceCopy.text("Reminder scheduled.")
        case .desired: return SurfaceCopy.text("Reminder pending. Not yet scheduled.")
        case .denied, .permissionRequired: return SurfaceCopy.text("Reminder not scheduled. Notifications are off; your shop is still available.")
        case .expired: return SurfaceCopy.text("That reminder time has passed. Review the current item.")
        case .retryNeeded: return SurfaceCopy.text("Reminder not scheduled. Review and try again.")
        case .cancelled, nil: return SurfaceCopy.text("Reminder off. Nothing is scheduled.")
        }
    }
    private func clearReview() { reviewed = nil; reviewedGeneration = nil; message = nil }
    private func display(_ date: Date, timeZone: String? = nil) -> String {
        let formatter = DateFormatter(); formatter.locale = locale; formatter.timeZone = TimeZone(identifier: timeZone ?? timeZoneID) ?? .gmt
        formatter.dateStyle = .full; formatter.timeStyle = .long; return formatter.string(from: date)
    }
    private func prepare() {
        timeZoneFocused = false
        clearReview()
        guard let generation = currentAuthorization(), let zone = TimeZone(identifier: timeZoneID) else { message = SurfaceCopy.text("This reminder needs a fresh review."); return }
        var calendar = Calendar(identifier: .gregorian); calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: fireAt)
        do {
            guard let year = parts.year, let month = parts.month, let day = parts.day, let hour = parts.hour, let minute = parts.minute else { throw SurfaceError.invalidCivilTime }
            let local = CivilReminderTime(year: year, month: month, day: day, hour: hour, minute: minute, timeZoneID: zone.identifier, confirmedGMTOffset: zone.secondsFromGMT(for: fireAt))
            reviewed = try ReminderIntent(id: context.reminderID, personaID: context.personaID, targetID: context.targetID, subject: context.subject, sourceRevision: context.sourceRevision,
                routeHandle: context.routeHandle, localTime: local, expiresAt: context.expiresAt, cutoff: context.cutoff,
                quietHours: quiet ? quietTimes.interval() : nil,
                language: locale.language.languageCode?.identifier == "es" ? .spanish : .english, now: Date())
            reviewedGeneration = generation
        } catch { message = errorText(error) }
    }
    private func save(_ value: ReminderIntent) {
        guard let generation = reviewedGeneration, let authorized = authorizeSave(generation) else {
            clearReview(); message = SurfaceCopy.text("This reminder needs a fresh review."); return
        }
        let expectedVersion = version
        busy = true
        Task {
            defer { busy = false }
            do {
                let saved = try await coordinator.save(value, expectedVersion: expectedVersion, requestPermission: true, authorized: authorized)
                guard await authorized(), currentAuthorization() != nil else { clearReview(); return }
                version = saved.version; self.saved = saved; statusLoaded = true; statusLoadFailed = false; reviewed = nil; message = nil
            } catch {
                if currentAuthorization() == generation { message = errorText(error) }
                else { clearReview() }
            }
        }
    }
    private func turnOff() {
        guard let generation = currentAuthorization(), let expectedVersion = saved?.version else { clearReview(); return }
        busy = true
        Task {
            defer { busy = false }
            do {
                let cancelled = try await coordinator.cancel(context.reminderID, expectedVersion: expectedVersion)
                guard currentAuthorization() == generation else { clearReview(); return }
                saved = cancelled
                version = cancelled.version
                clearReview()
                message = SurfaceCopy.text("Reminder turned off.")
            } catch {
                guard currentAuthorization() == generation else { clearReview(); return }
                if error as? SurfaceError == .stale {
                    clearReview()
                    statusLoadFailed = true
                    message = errorText(error)
                } else {
                    message = SurfaceCopy.text("Could not turn off the reminder. Try again.")
                }
            }
        }
    }
    private func errorText(_ error: Error) -> String {
        switch error as? SurfaceError {
        case .quietHours: return SurfaceCopy.text("Choose a time outside quiet hours and before the deadline.")
        case .expired: return SurfaceCopy.text("Choose a future time before the expiry and offer cutoff.")
        case .invalidCivilTime, .ambiguousCivilTime: return SurfaceCopy.text("Review the date, time and time zone before continuing.")
        case .capacity: return SurfaceCopy.text("Turn off an unused reminder before adding another.")
        default: return SurfaceCopy.text("This reminder needs a fresh review.")
        }
    }
}
