import SwiftUI
import HouseholdClient
import CoreDomain

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
                if edit.proposalID != nil || edit.changeProposalID != nil || edit.dinnerSwap == true || edit.repeatPlanID != nil { SharedMealFacts(meal: meal) }
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

func sharedWeekMeals(_ meals: [SharedMealOccurrence], starting date: Date) -> [SharedMealOccurrence] {
    let start = sharedMealDay(date)
    guard let endDate = mealCalendar().date(byAdding: .day, value: 7, to: date) else { return [] }
    let end = sharedMealDay(endDate)
    return meals.filter { row in
        guard let day = row.meal.day else { return false }
        return day >= start && day < end
    }.sorted { lhs, rhs in
        if lhs.meal.day != rhs.meal.day { return (lhs.meal.day ?? "") < (rhs.meal.day ?? "") }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

struct SharedMealMovesView: View {
    @ObservedObject var household: HouseholdModel
    var onReviewOpened: () -> Void = {}
    @Environment(\.locale) private var locale
    @Environment(\.dismiss) private var dismiss
    @State private var plan: SharedMealPlan?
    @State private var reviewedScope: SharedMealChangeScope?
    @State private var weekStart = sharedMealPickerToday()
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
    private var bindingID: SharedMealChangeScope? { household.sharedMealChangeScope }
    var body: some View {
        WorkingForm {
            NavigationLink(ht("Household dinner ideas")) { SharedMealIdeasView(household: household) }
            Button(ht("Guest, ingredient, and serving-group proposals")) { showingChanges = true }
            if let plan, let bindingID, reviewedScope == bindingID,
               plan.shopId == context?.shopId.flatMap(UUID.init(uuidString:)), plan.shopper == (context?.role == "shopper") {
                Section(dinnerText("This week")) {
                    DatePicker(dinnerText("Week starting"), selection: $weekStart, displayedComponents: .date)
                        .environment(\.timeZone, mealCalendar().timeZone)
                    HStack {
                        Button(dinnerText("Previous week")) { if let day = mealCalendar().date(byAdding: .day, value: -7, to: weekStart) { weekStart = day } }
                        Spacer()
                        Button(dinnerText("Next week")) { if let day = mealCalendar().date(byAdding: .day, value: 7, to: weekStart) { weekStart = day } }
                    }.buttonStyle(.borderless)
                    let meals = sharedWeekMeals(plan.meals, starting: weekStart)
                    if plan.phase == "placed" { Text(weekReviewText("Current menu after delivery")).font(.headline) }
                    if meals.isEmpty { Text(weekReviewText("No shared meals scheduled for these seven days.")) }
                    ForEach(meals) { row in
                        DisclosureGroup {
                            SharedMealFacts(meal: row.meal)
                        } label: {
                            VStack(alignment: .leading) {
                                Text(verbatim: row.meal.title).font(.headline)
                                Text(verbatim: sharedMealScheduleText(row.meal.day, locale: locale))
                            }
                        }
                    }
                }
                if plan.phase == "draft" {
                    SavedWeekEntry(household: household, scope: bindingID, start: weekStart)
                        .id(SharedWeekRepeatIdentity(scope: bindingID, week: sharedMealDay(weekStart),
                            shopRevision: plan.shopRevision, grantRevision: plan.grantRevision))
                }
                if plan.phase == "draft" || plan.phase == "placed" {
                    SharedWeekRepeatSection(household: household, plan: plan, scope: bindingID, start: weekStart) {
                        dismiss(); onReviewOpened()
                    }.id(SharedWeekRepeatIdentity(scope: bindingID, week: sharedMealDay(weekStart),
                        shopRevision: plan.shopRevision, grantRevision: plan.grantRevision))
                }
                if plan.shopper && plan.phase == "placed" && plan.plannerId != nil {
                    Button(weekReviewText("Remove planning access"), role: .destructive) {
                        selectedAdult = nil; confirmingAccess = true
                    }
                }
                if plan.phase == nil || plan.phase == "draft" {
                    if plan.shopper {
                        Section(ht("Meal planning access")) {
                            Text(ht("Choose an adult who can use a named planning seat to see these meals and suggest a different day. Only the shopper can apply changes."))
                            if let lifecycle = household.lifecycle, let scope = lifecycle.scope, scope == context,
                               lifecycle.canAdminister, !plan.meals.isEmpty {
                                DisclosureGroup(ht("Invite an adult to this dinner")) {
                                    ForEach(plan.meals) { row in
                                        NavigationLink {
                                            HouseholdDinnerInvitationView(model: lifecycle, scope: scope,
                                                target: .init(shopId: plan.shopId, occurrenceId: row.id), title: row.meal.title)
                                        } label: {
                                            Text(verbatim: "\(row.meal.title) · \(sharedMealScheduleText(row.meal.day))")
                                        }
                                    }
                                }
                            }
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
        guard let scope = context, let id = scope.shopId.flatMap(UUID.init(uuidString:)), let service = household.service,
              let binding = bindingID, action == nil || reviewedScope == binding else { return }
        busy = true; defer { if binding == bindingID { busy = false } }
        do {
            try await action?(service)
            let fresh = try await service.mealPlan(shopID: id, currentWeek: true)
            guard !Task.isCancelled, binding == bindingID else { return }
            reviewedScope = binding; plan = fresh; selectedAdult = fresh.plannerId; notice = nil
        } catch {
            guard binding == bindingID else { return }
            plan = nil; notice = ht("Meal planning access or the plan changed. Refresh to check your current access and proposals.")
        }
    }
    private func review(_ move: SharedMealPlan.Move, _ occurrence: SharedMealOccurrence, _ plan: SharedMealPlan) {
        guard let reviewedScope, reviewedScope == bindingID,
              let model = household.sharedShop, model.canManage, model.pending == nil, !model.editing,
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

private struct SharedWeekRepeatIdentity: Hashable {
    let scope: SharedMealChangeScope
    let week: String
    let shopRevision, grantRevision: Int
}

private struct SharedWeekRepeatSection: View {
    @ObservedObject var household: HouseholdModel
    let plan: SharedMealPlan
    let scope: SharedMealChangeScope
    let start: Date
    let openShop: () -> Void
    @State private var series: SharedRepeatSeries?
    @State private var receiptMenu: SharedMealPlan?
    @State private var selections: [UUID:Date] = [:]
    @State private var requestID = UUID()
    @State private var initialLoad = true
    @State private var loaded = false
    @State private var working = false
    @State private var failed = false
    @State private var confirmStop = false
    @State private var openReview = false

    private var current: Bool { household.sharedMealChangeScope == scope && !Task.isCancelled }
    private var week: String { sharedMealDay(start) }
    private var candidates: [SharedMealOccurrence] {
        guard let previous = mealCalendar().date(byAdding: .day, value: -7, to: start) else { return [] }
        return sharedWeekMeals(plan.meals, starting: previous).filter { $0.meal.kind == "dinner" }
    }
    private var bounds: ClosedRange<Date> {
        let day = mealCalendar().startOfDay(for: start)
        return day...(mealCalendar().date(byAdding: .day, value: 6, to: day) ?? day)
    }

    var body: some View {
        Group {
            if current, initialLoad {
                ProgressView().task {
                    await load()
                    if !Task.isCancelled { initialLoad = false }
                }
            }
            if current, loaded, let series {
                let currentPlan = receiptMenu ?? plan
                Section(weekReviewText("Shared repeat week")) {
                    Text(weekReviewText("Each dinner has its own grocery review. Both planners can return to this list to see what was saved."))
                    if household.storeQuoteScope != nil {
                        NavigationLink(ht("Shared week costs")) {
                            SharedWeekCostDetails(household: household, mealScope: scope, planID: series.planId)
                        }
                    }
                    ForEach(series.steps) { step in
                        let source = currentPlan.meals.first { $0.id == step.sourceId }
                        VStack(alignment: .leading) {
                            switch series.menuState(for: step, in: currentPlan.meals) {
                            case .present(let dinner):
                                Text(verbatim: dinner.meal.title).font(.headline)
                                Text(verbatim: sharedMealScheduleText(dinner.meal.day))
                                Label(weekReviewText("Saved to the shared shop"), systemImage: "checkmark.circle")
                                if currentPlan.phase == "draft", currentPlan.shopper, !dinner.meal.protected,
                                   dinner.meal.planning?.groups.contains(where: { $0.protected }) != true {
                                    Button(ht("Review removing this meal")) {
                                        Task { await reviewRemoval(of: dinner, in: currentPlan) }
                                    }
                                    .accessibilityIdentifier("week.series.remove." + step.id.uuidString)
                                }
                            case .removed:
                                Text(verbatim: source?.meal.title ?? weekReviewText("Dinner unavailable")).font(.headline)
                                Text(weekReviewText("Previously saved and now off the menu."))
                            case .pending:
                                Text(verbatim: source?.meal.title ?? weekReviewText("Dinner unavailable")).font(.headline)
                                Text(verbatim: sharedMealScheduleText(step.day))
                                if series.stopped || currentPlan.phase == "placed" { Text(weekReviewText("Stopped before saving")) }
                                else if source?.revision != step.sourceRevision { Text(weekReviewText("Source dinner changed. Start a fresh review.")) }
                                else if currentPlan.phase == "draft", currentPlan.shopper, let source {
                                    Button(weekReviewText("Review this dinner and its groceries")) { Task { await open(step, source: source, series: series, menu: currentPlan) } }
                                        .accessibilityIdentifier("week.series.review." + step.id.uuidString)
                                } else { Text(weekReviewText("Waiting for shopper review")) }
                            }
                        }
                    }
                    if currentPlan.phase == "draft", currentPlan.shopper, let shop = household.sharedShop, shop.canManage, !series.receipts.isEmpty {
                        NavigationLink(SharedOperationUndoCopy.text("Saved changes")) { SharedOperationUndoView(shopModel: shop) }
                    }
                    if currentPlan.phase == "draft" && !series.stopped && series.steps.contains(where: { !series.saved($0) }) {
                        Button(weekReviewText("Stop remaining dinners"), role: .destructive) { confirmStop = true }
                    }
                    if currentPlan.phase == "draft" && series.stopped && !candidates.isEmpty {
                        Button(weekReviewText("Start a fresh review")) { self.series = nil; selections = [:]; requestID = UUID() }
                    }
                    Button(ht("Refresh")) { Task { await load() } }
                }
            } else if current, plan.phase == "draft", loaded, !candidates.isEmpty {
                Section(weekReviewText("Shared repeat week")) {
                    DisclosureGroup(isExpanded: $openReview) {
                        ForEach(candidates) { meal in
                            Toggle(isOn: Binding(get: { selections[meal.id] != nil }, set: { selected in
                                if selected, let original = sharedMealDate(meal.meal.day) {
                                    selections[meal.id] = mealCalendar().date(byAdding: .day, value: 7, to: original)
                                } else { selections.removeValue(forKey: meal.id) }
                                requestID = UUID()
                            })) { Text(verbatim: meal.meal.title) }
                            if let chosen = selections[meal.id] {
                                DatePicker(dinnerText("Dinner date"), selection: Binding(get: { chosen }, set: {
                                    selections[meal.id] = $0; requestID = UUID()
                                }), in: bounds, displayedComponents: .date)
                                    .environment(\.timeZone, mealCalendar().timeZone)
                                SharedMealFacts(meal: meal.meal.repeated(on: sharedMealDay(chosen)))
                            }
                        }
                        Text(weekReviewText("Save the selected dinners for both planners to review. The shopper confirms grocery changes one dinner at a time."))
                        Button(weekReviewText("Save shared review")) { Task { await stage() } }
                            .disabled(selections.isEmpty).accessibilityIdentifier("week.series.stage")
                    } label: { Text(dinnerText("Repeat last week")) }
                }
            }
            if failed && current {
                Button(weekReviewText("Refresh shared repeat review")) { Task { await load() } }
            }
        }
        .disabled(working)
        .confirmationDialog(weekReviewText("Stop remaining dinners?"), isPresented: $confirmStop) {
            Button(weekReviewText("Stop remaining dinners"), role: .destructive) { Task { await stop() } }
        } message: { Text(weekReviewText("Saved dinners stay in the shop. Review Saved changes to undo an eligible dinner.")) }
    }

    @MainActor private func load() async {
        guard current, let service = household.service, !working else { return }
        working = true; defer { working = false }
        do {
            let fresh = try await service.sharedRepeatWeek(shopID: scope.shopID, week: week)
            try await display(fresh, using: service)
        } catch {
            guard current else { return }
            receiptMenu = nil; series = nil; loaded = false
            if case ClientError.service(let status, _, _, _) = error, [403,404].contains(status) { failed = false }
            else { failed = true }
        }
    }
    @MainActor private func stage() async {
        guard current, let service = household.service, !working, !selections.isEmpty else { return }
        let choices = candidates.compactMap { source in
            selections[source.id].map { SharedRepeatSelection(source: source, day: sharedMealDay($0)) }
        }
        working = true; defer { working = false }
        do {
            let fresh = try await service.stageRepeatWeek(id: requestID, week: week, plan: plan, selections: choices)
            try await display(fresh, using: service)
        } catch { if current { failed = true; loaded = false } }
    }
    @MainActor private func stop() async {
        guard current, !working, let series, let service = household.service else { return }
        working = true; defer { working = false }
        do {
            let stopped = try await service.stopRepeatWeek(series, plan: plan)
            try await display(stopped, using: service)
        } catch { if current { failed = true; loaded = false } }
    }
    @MainActor private func display(_ fresh: SharedRepeatSeries?, using service: HouseholdService) async throws {
        var menu: SharedMealPlan?
        if let fresh, !fresh.receipts.isEmpty {
            // Read the menu after the receipt so another adult's removal or later edit is visible.
            let latest = try await service.mealPlan(shopID: scope.shopID, currentWeek: true)
            guard latest.shopId == scope.shopID, latest.authorityEpoch == plan.authorityEpoch,
                  latest.grantRevision == plan.grantRevision, latest.shopper == plan.shopper else {
                throw ClientError.configuration
            }
            menu = latest
        }
        guard current else { return }
        receiptMenu = menu; series = fresh; failed = false; loaded = true
    }

    @MainActor private func open(_ step: SharedRepeatSeries.Step, source: SharedMealOccurrence,
                                 series: SharedRepeatSeries, menu: SharedMealPlan) async {
        guard !working, !series.stopped, !series.saved(step) else { return }
        working = true; defer { working = false }
        guard let model = await reviewableShop(matching: menu), let meals = model.shop?.meals,
              meals.contains(source), !meals.contains(where: { $0.id == step.id }),
              let edit = try? step.reviewedEdit(source: source, planID: series.planId) else { failed = true; return }
        show(edit, in: model)
    }

    @MainActor private func reviewRemoval(of dinner: SharedMealOccurrence, in menu: SharedMealPlan) async {
        guard !working else { return }
        working = true; defer { working = false }
        guard let model = await reviewableShop(matching: menu), model.shop?.meals?.contains(dinner) == true else {
            failed = true; return
        }
        // The shopper reviews the current packs, quote and any food commitments in the normal editor.
        show(SharedMealEdit(occurrenceID: dinner.id, meal: nil), in: model)
    }

    @MainActor private func reviewableShop(matching menu: SharedMealPlan) async -> HouseholdShopModel? {
        guard current, menu.shopper, let model = household.sharedShop, model.canManage,
              !model.editing, !model.busy, model.pending == nil else { return nil }
        if model.shop?.shopRevision != menu.shopRevision { await model.load() }
        guard current, household.sharedShop === model, model.canManage, !model.editing, !model.busy,
              model.pending == nil, let shop = model.shop, shop.phase == "draft",
              UUID(uuidString: shop.shopId) == scope.shopID, shop.shopRevision == menu.shopRevision,
              shop.authorityEpoch == menu.authorityEpoch else { return nil }
        return model
    }

    @MainActor private func show(_ edit: SharedMealEdit, in model: HouseholdShopModel) {
        model.beginEditing()
        guard model.editing else { failed = true; return }
        model.draft.mealEdit = edit
        openShop()
    }
}

private struct SharedWeekCostDetails: View {
    @ObservedObject var household: HouseholdModel
    let mealScope: SharedMealChangeScope
    let planID: UUID
    @Environment(\.scenePhase) private var scene
    @EnvironmentObject private var membership: MembershipCoordinator
    @State private var costs: SharedWeekCosts?
    @State private var loaded: StoreQuoteScope?
    @State private var failed = false
    @State private var request = UUID()

    private var scope: StoreQuoteScope? {
        guard scene == .active, household.sharedMealChangeScope == mealScope,
              membership.model(for: household.membershipSession)?.hasPaidAccess == true else { return nil }
        return household.storeQuoteScope
    }
    var body: some View {
        JournalList {
            if let scope, loaded == scope, let costs {
                Section(ht("Original weekly basket")) {
                    if let original = costs.original { version(original) }
                    else { Text(dinnerText("No saved estimate for this shop.")) }
                }
                ForEach(costs.revisions) { saved in
                    Section(ht("Accepted basket revision") + " " + String(saved.revision)) {
                        version(saved)
                        if let original = costs.original, let change = comparableChange(original, saved) {
                            LabeledContent(dinnerText("Change in comparable priced groceries"), value: dinnerMoney(change))
                            Text(dinnerText("Historical grocery estimate. Taxes, fees and posted charges are separate."))
                        }
                    }
                }
                LabeledContent(ht("Reported shop charges after posted credits"),
                               value: money(costs.reportedNetMinor, currency: costs.currency))
            } else if scope != nil && !failed { ProgressView() }
            else { Text(ht("Shared week costs are unavailable.")) }
        }
        .navigationTitle(ht("Shared week costs")).privacySensitive()
        .task(id: scope) { await load() }
        .refreshable { await load() }
    }
    @ViewBuilder private func version(_ value: SharedWeekCosts.Version) -> some View {
        if let date = serviceDate(value.capturedAt) { Text(date.formatted(date: .abbreviated, time: .shortened)) }
        LabeledContent(dinnerText("Priced items"), value: "\(value.pricedLines) / \(value.lines.count)")
        LabeledContent(dinnerText("Known estimated subtotal"), value: money(value.knownItemSubtotalMinor, currency: value.currency))
        if let quote = value.adoptedQuote {
            Text(verbatim: quote.store + " · " + quote.branch)
            if let observed = serviceDate(quote.observedAt) { Text(observed.formatted(date: .abbreviated, time: .shortened)) }
            LabeledContent(ht("Adopted quote item subtotal"), value: money(quote.itemsMinor, currency: value.currency))
            LabeledContent(ht("Adopted quote checkout"), value: money(quote.checkoutMinor, currency: value.currency))
        }
        ForEach(value.lines) { line in
            LabeledContent(line.name, value: String(line.packs) + " × " + money(line.unitPriceMinor, currency: value.currency))
        }
    }
    /// The service redacts line prices for a planner with only a shared adoption.
    /// An aggregate store quote alone supplies no per-line comparison.
    private func comparableChange(_ before: SharedWeekCosts.Version, _ after: SharedWeekCosts.Version) -> Money? {
        guard scope != nil, loaded == scope, let currency = Currency(rawValue: before.currency),
              after.currency == before.currency, before.pricedLines > 0, after.pricedLines > 0 else { return nil }
        func estimate(_ version: SharedWeekCosts.Version) throws -> GroceryCostReview {
            let rows = try version.lines.map { row in
                let amount = try row.unitPriceMinor.map {
                    try Money(minorUnits: $0, currency: currency).multiplied(by: Int64(row.packs))
                }
                return (row.id, amount)
            }
            return try GroceryCostReview(lines: rows, currency: currency, inventoryComplete: true)
        }
        return try? estimate(after).pricedChange(from: estimate(before))
    }
    private func money(_ minor: Int64?, currency: String) -> String {
        guard let minor else { return dinnerText("Unknown") }
        return (Decimal(minor) / 100).formatted(.currency(code: currency))
    }
    @MainActor private func load() async {
        let token = UUID()
        request = token
        costs = nil; loaded = nil; failed = false
        guard let expected = scope, let service = household.service else { return }
        do {
            let result = try await service.sharedWeekCosts(shopID: mealScope.shopID, planID: planID)
            guard !Task.isCancelled, token == request, expected == scope else { return }
            costs = result; loaded = expected
        } catch { if token == request, !Task.isCancelled { failed = true } }
    }
}
