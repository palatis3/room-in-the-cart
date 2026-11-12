import SwiftUI
import HouseholdClient

// A menu date is a civil day. Never store it as an instant relative to the device's zone.
private func mealCalendar() -> Calendar {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(secondsFromGMT: 0)!
    return calendar
}

func sharedMealDay(_ date: Date) -> String {
    let fields = mealCalendar().dateComponents([.year, .month, .day], from: date)
    return String(format: "%04d-%02d-%02d", fields.year!, fields.month!, fields.day!)
}

/// The picker represents civil days in UTC. Start on the user's local calendar date.
func sharedMealPickerToday(now: Date = Date(), timeZone: TimeZone = .current) -> Date {
    let offset = TimeInterval(timeZone.secondsFromGMT(for: now))
    return mealCalendar().startOfDay(for: now.addingTimeInterval(offset))
}

func sharedMealDate(_ day: String?) -> Date? {
    guard let day else { return nil }
    let parts = day.split(separator: "-").compactMap { Int($0) }
    guard parts.count == 3,
          let date = mealCalendar().date(from: DateComponents(year: parts[0], month: parts[1], day: parts[2])),
          sharedMealDay(date) == day else { return nil }
    return date
}

func sharedMealDayText(_ day: String?, locale: Locale) -> String? {
    guard let date = sharedMealDate(day) else { return nil }
    return date.formatted(Date.FormatStyle(date: .long, time: .omitted, locale: locale,
        calendar: mealCalendar(), timeZone: mealCalendar().timeZone))
}

// Render unknown scheduling explicitly, including recipient-selected cook-copy language.
func sharedMealScheduleText(_ day: String?, locale: Locale = .current) -> String {
    guard let day else {
        let language = locale.language.languageCode?.identifier ?? "en"
        let bundle = Bundle.main.path(forResource: language, ofType: "lproj").flatMap(Bundle.init(path:)) ?? .main
        return bundle.localizedString(forKey: "Unscheduled", value: "Unscheduled", table: "Household")
    }
    return sharedMealDayText(day, locale: locale) ?? day
}

private func mealKind(_ kind: String) -> String {
    switch kind { case "lunch": return ht("Lunch"); case "side": return ht("Side"); default: return ht("Dinner") }
}

struct SharedMealFacts: View {
    let meal: SharedMeal
    var deadlineIdentifier = "sharedMeal.deadlineFact"
    @Environment(\.locale) private var locale
    var body: some View {
        VStack(alignment: .leading) {
            Text(meal.title).font(.headline)
            Text(mealKind(meal.kind))
            Text(verbatim: sharedMealScheduleText(meal.day, locale: locale))
                .accessibilityIdentifier("shared-meal-civil-date")
            LabeledContent(sharedRecoveryText("Meal deadline"), value: meal.planning?.deadline?.display(locale: locale) ?? ht("Unknown"))
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier(deadlineIdentifier)
            LabeledContent(ht("Portions"), value: meal.portions.formatted())
            if meal.protected { Label(ht("Protected portions"), systemImage: "lock") }
            if let planning = meal.planning { SharedMealPlanningFacts(planning: planning) }
        }
    }
}

struct SharedMealEditor: View {
    @ObservedObject var model: HouseholdShopModel
    let meals: [SharedMealOccurrence]
    let presentDay: (SharedMealDaySelection) -> Void

    private func start(_ id: UUID, _ meal: SharedMeal?) {
        model.draft.mealEdit = .init(occurrenceID: id, meal: meal)
    }

    var body: some View {
        Section(ht("Shared meal plan")) {
            if let edit = model.draft.mealEdit, let meal = edit.meal {
                if edit.proposalID != nil || edit.changeProposalID != nil { SharedMealFacts(meal: meal) }
                else { fields(for: edit.occurrenceID, meal: meal) }
            } else if model.draft.mealEdit == nil {
                ForEach(meals) { occurrence in
                    VStack(alignment: .leading) {
                        SharedMealFacts(meal: occurrence.meal)
                        Button(ht("Edit this meal")) { start(occurrence.id, occurrence.meal) }
                        Button(ht("Review removing this meal"), role: .destructive) { start(occurrence.id, nil) }
                    }.buttonStyle(.borderless)
                }
                Button(ht("Add a meal")) {
                    start(UUID(), SharedMeal(title: "", day: nil, kind: "dinner", portions: 1, protected: false))
                }.disabled(meals.count >= 100)
                    .accessibilityIdentifier("sharedMeal.add")
            } else {
                Text(ht("Review meal removal alongside the packs below."))
            }
            if model.draft.mealEdit != nil {
                Text(ht("Check the shared packs and quote below. Changing a meal does not calculate or remove packs automatically."))
                Button(ht("Discard meal edit")) { model.draft.mealEdit = nil }
            }
        }
    }

    @ViewBuilder private func fields(for id: UUID, meal: SharedMeal) -> some View {
        TextField(ht("Meal name"), text: field(id, meal, \.title))
        Picker(ht("Meal type"), selection: field(id, meal, \.kind)) {
            ForEach(["dinner","lunch","side"], id: \.self) { Text(mealKind($0)).tag($0) }
        }
        Toggle(ht("Assign a night"), isOn: Binding(get: { meal.day != nil }, set: { assigned in
            guard let edit = model.draft.mealEdit, edit.occurrenceID == id, var current = edit.meal else { return }
            current.move(to: assigned ? sharedMealDay(sharedMealPickerToday()) : nil)
            start(id, current)
        })).accessibilityIdentifier("sharedMeal.assignNight")
        if let day = meal.day {
            SharedMealDayEditor(day: day) {
                if let selection = SharedMealDaySelection(occurrenceID: id, day: day) { presentDay(selection) }
            }
        } else {
            Text(ht("Unscheduled")).accessibilityIdentifier("sharedMeal.unscheduled")
        }
        if let original = meals.first(where: { $0.id == id })?.meal, original.day != meal.day,
           original.planning?.deadline != nil && meal.planning?.deadline == nil {
            Text(sharedRecoveryText("The new day has no deadline until you set one."))
        }
        SharedMealDeadlineEditor(meal: meal) { deadline in
            guard let edit = model.draft.mealEdit, edit.occurrenceID == id, var current = edit.meal, current.day == meal.day,
                  (try? current.setDeadline(deadline)) != nil else { return }
            start(id, current)
        }.id(id)
        Stepper(value: field(id, meal, \.portions), in: 1...1000) { LabeledContent(ht("Portions"), value: meal.portions.formatted()) }
        Toggle(ht("Protect these portions"), isOn: field(id, meal, \.protected))
    }

    private func field<T>(_ id: UUID, _ meal: SharedMeal, _ key: WritableKeyPath<SharedMeal,T>) -> Binding<T> {
        Binding(get: { meal[keyPath: key] }, set: { newValue in
            guard let edit = model.draft.mealEdit, edit.occurrenceID == id, var current = edit.meal else { return }
            current[keyPath: key] = newValue
            start(id, current)
        })
    }
}

/// Presentation belongs to the outer form, so recycling a meal row cannot dismiss it.
struct SharedMealDaySelection: Identifiable {
    let id = UUID()
    let occurrenceID: UUID
    let originalDay: String
    let date: Date

    init?(occurrenceID: UUID, day: String) {
        guard let date = sharedMealDate(day) else { return nil }
        self.occurrenceID = occurrenceID; originalDay = day; self.date = date
    }
}

struct SharedMealDaySheet: View {
    @ObservedObject var model: HouseholdShopModel
    let selection: SharedMealDaySelection
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            SharedMealDayPicker(date: selection.date) { selectedDay in
                defer { dismiss() }
                guard let edit = model.draft.mealEdit, edit.occurrenceID == selection.occurrenceID,
                      var current = edit.meal, current.day == selection.originalDay else { return }
                current.move(to: selectedDay)
                model.draft.mealEdit = .init(occurrenceID: selection.occurrenceID, meal: current)
            }
        }
    }
}

/// The selected civil day is rendered by our locale-aware formatter. Calendar edits
/// remain local to the sheet until confirmed, before the separate shared-shop review.
private struct SharedMealDayEditor: View {
    let day: String
    let present: () -> Void
    @Environment(\.locale) private var locale

    var body: some View {
        Button(action: present) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ht("Meal day")).foregroundStyle(.primary)
                Text(verbatim: sharedMealScheduleText(day, locale: locale))
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(ht("Meal day"))
        .accessibilityValue(sharedMealScheduleText(day, locale: locale))
        .accessibilityIdentifier("sharedMeal.day")
        .disabled(sharedMealDate(day) == nil)
    }
}

private struct SharedMealDayPicker: View {
    let save: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @Environment(\.locale) private var locale
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selected: Date

    init(date: Date, save: @escaping (String) -> Void) {
        self.save = save
        _selected = State(initialValue: date)
    }

    private var calendar: Calendar {
        var calendar = mealCalendar()
        calendar.locale = locale
        return calendar
    }

    @ViewBuilder private var dateControl: some View {
        let picker = DatePicker(ht("Meal day"), selection: $selected, displayedComponents: .date)
            .environment(\.calendar, calendar)
            .environment(\.timeZone, calendar.timeZone)
            .accessibilityIdentifier("sharedMeal.dayCalendar")
        if dynamicTypeSize.isAccessibilitySize {
            // Native adjustable wheels avoid overlapping month-navigation controls
            // while retaining the user's text size and the same staged civil day.
            picker.datePickerStyle(.wheel)
                .labelsHidden()
        } else {
            picker.datePickerStyle(.graphical)
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                Text(verbatim: sharedMealScheduleText(sharedMealDay(selected), locale: locale))
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("sharedMeal.dayPreview")
                dateControl
                Button(ht("Use this day")) { save(sharedMealDay(selected)) }
                    .buttonStyle(.borderedProminent)
                    .frame(minHeight: 44)
                    .accessibilityIdentifier("sharedMeal.useDay")
            }.padding()
        }
        .navigationTitle(ht("Meal day"))
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .cancellationAction) {
                Button(ht("Cancel")) { dismiss() }
                    .accessibilityIdentifier("sharedMeal.cancelDay")
            }
        }
    }
}

struct SharedMealMovesView: View {
    @ObservedObject var household: HouseholdModel
    var onReviewOpened: () -> Void = {}
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var plan: SharedMealPlan?
    @State private var selectedAdult: UUID?
    @State private var occurrenceID: UUID?
    @State private var day = sharedMealPickerToday()
    @State private var proposalID = UUID()
    @State private var busy = false
    @State private var notice: String?
    @State private var showingChanges = false
    @State private var confirmingAccess = false
    @State private var dismissingMove: SharedMealPlan.Move?

    private var context: HouseholdBootstrap? {
        guard !household.locked, let scope = household.projection, scope.grantId == nil,
              scope.role == "shopper" || scope.capabilities.contains("meal_proposals") else { return nil }
        return scope
    }
    private var bindingID: String {
        [context?.household.id,context?.memberId,context?.shopId,context?.role].compactMap { $0 }.joined(separator: "/")
    }
    var body: some View {
        Form {
            NavigationLink(ht("Household dinner ideas")) { SharedMealIdeasView(household: household) }
            Button(ht("Guest, ingredient, and serving-group proposals")) { showingChanges = true }
            if let plan, plan.shopId == context?.shopId.flatMap(UUID.init(uuidString:)), plan.shopper == (context?.role == "shopper") {
                if plan.shopper {
                    Section(ht("Meal planning access")) {
                        Text(ht("Choose an adult who can use a named planning seat to see these meals and suggest a different day. Only the shopper can apply changes."))
                        Picker(ht("Planning adult"), selection: $selectedAdult) {
                            Text(ht("No planning adult")).tag(nil as UUID?)
                            ForEach(plan.adults) { Text($0.label).tag(Optional($0.id)) }
                        }
                        Button(ht("Review planning access")) { confirmingAccess = true }
                            .disabled(selectedAdult == plan.plannerId)
                    }
                } else {
                    Section(ht("Propose a meal move")) {
                        Picker(ht("Meal to move"), selection: $occurrenceID) {
                            Text(ht("Choose a meal")).tag(nil as UUID?)
                            ForEach(plan.meals) { Text(verbatim: "\($0.meal.title) · \(sharedMealScheduleText($0.meal.day))").tag(Optional($0.id)) }
                        }
                        if let occurrence = plan.meals.first(where: { $0.id == occurrenceID }) {
                            SharedMealFacts(meal: occurrence.meal)
                            DatePicker(ht("Proposed day"), selection: $day, displayedComponents: .date)
                                .environment(\.timeZone, mealCalendar().timeZone)
                            Text(ht("The current meal and basket stay in place until the shopper reviews the move."))
                            Button(ht("Send this proposed day")) {
                                Task { await run { service in
                                    try await service.proposeMealMove(id: proposalID, occurrenceID: occurrence.id, day: sharedMealDay(day), plan: plan)
                                } }
                            }.disabled(occurrence.meal.day == sharedMealDay(day))
                        }
                    }
                }
                Section(ht("Meal move proposals")) {
                    if plan.proposals.isEmpty { Text(ht("No current meal moves to review.")) }
                    ForEach(plan.proposals) { move in
                        if let occurrence = plan.meals.first(where: { $0.id == move.occurrenceId }) {
                            SharedMealFacts(meal: occurrence.meal)
                            LabeledContent(ht("Proposed day"), value: sharedMealScheduleText(move.day, locale: locale))
                            if plan.shopper {
                                Button(ht("Review move with shared packs")) { review(move, occurrence, plan) }
                                Button(ht("Dismiss proposed move"), role: .destructive) { dismissingMove = move }
                            }
                        }
                    }
                }
            }
            if let notice { Text(notice) }
            if busy { ProgressView() }
            Button(ht("Refresh meal plan")) { Task { await run() } }
        }.disabled(busy || context == nil)
        .navigationTitle(ht("Shared meal plan"))
        .sheet(isPresented: $showingChanges) { NavigationStack { SharedMealChangesView(household: household, onReviewOpened: { showingChanges = false; dismiss(); onReviewOpened() })
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button(ht("Close")) { showingChanges = false } } } } }
        .task(id: bindingID) { plan = nil; notice = nil; await run() }
        .onChange(of: day) { _,_ in proposalID = UUID() }
        .onChange(of: occurrenceID) { _,id in
            proposalID = UUID()
            if let meal = plan?.meals.first(where: { $0.id == id }), let date = sharedMealDate(meal.meal.day) { day = date }
        }
        .confirmationDialog(ht("Dismiss proposed move"), isPresented: Binding(get: { dismissingMove != nil },
            set: { if !$0 { dismissingMove = nil } }), presenting: dismissingMove) { move in
            Button(ht("Dismiss proposed move"), role: .destructive) {
                if let plan { Task { await run { try await $0.dismissMealMove(move, plan: plan) } } }
            }
        } message: { move in Text(verbatim: sharedMealScheduleText(move.day, locale: locale)) }
        .confirmationDialog(ht("Change meal planning access?"), isPresented: $confirmingAccess, titleVisibility: .visible) {
            Button(ht("Save planning access")) {
                if let plan { Task { await run { try await $0.changeMealPlanner(selectedAdult, plan: plan) } } }
            }
        } message: {
            Text(selectedAdult.flatMap { id in plan?.adults.first(where: { $0.id == id })?.label } ?? ht("No planning adult"))
        }
    }
    @MainActor private func run(_ action: ((HouseholdService) async throws -> Void)? = nil) async {
        guard let scope = context, let id = scope.shopId.flatMap(UUID.init(uuidString:)), let service = household.service else { return }
        let binding = bindingID
        busy = true; defer { if binding == bindingID { busy = false } }
        do {
            try await action?(service)
            let fresh = try await service.mealPlan(shopID: id)
            guard !Task.isCancelled, binding == bindingID else { return }
            plan = fresh; selectedAdult = fresh.plannerId; notice = nil
        } catch {
            guard binding == bindingID else { return }
            plan = nil; notice = ht("Meal planning access or the plan changed. Refresh to check your current access and proposals.")
        }
    }
    private func review(_ move: SharedMealPlan.Move, _ occurrence: SharedMealOccurrence, _ plan: SharedMealPlan) {
        guard let model = household.sharedShop, model.canManage, model.pending == nil, !model.editing,
              let shop = model.shop, UUID(uuidString: shop.shopId) == plan.shopId, shop.shopRevision == plan.shopRevision,
              shop.authorityEpoch == plan.authorityEpoch else {
            notice = ht("Return to the shared shop and refresh or finish the current edit first."); return
        }
        model.beginEditing()
        guard model.editing else { return }
        var meal = occurrence.meal; meal.move(to: move.day)
        model.draft.mealEdit = .init(occurrenceID: occurrence.id, meal: meal, proposalID: move.id)
        dismiss(); onReviewOpened()
    }
}
