import HouseholdClient
import SwiftUI

struct HouseholdStaplesView: View {
    @ObservedObject var model: HouseholdPantryModel
    @Environment(\.dismiss) private var dismiss
    @State private var forget: HouseholdStaplePage.Group?
    @State private var recallName = ""
    @State private var disabling = false
    @State private var removing: (group: UUID, lot: UUID)?

    var body: some View {
        List {
            if let state = model.staples {
                if state.enabled {
                    ForEach(state.groups) { group in groupSection(group, state) }
                    Section(pantryText("Manual recall")) {
                        TextField(pantryText("Staple name"), text: $recallName)
                        Button(pantryText("Remember a staple")) {
                            let name = recallName.trimmingCharacters(in: .whitespacesAndNewlines)
                            Task {
                                await model.changeStaples(.remember(name), reviewed: state)
                                if model.staples?.groups.contains(where: { $0.name == name }) == true { recallName = "" }
                            }
                        }.disabled(recallName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || recallName.count > 120)
                    }
                    Section {
                        NavigationLink(pantryText("Review a purchase")) { HouseholdStaplePurchaseView(model: model, state: state) }
                            .accessibilityIdentifier("householdStaple.purchase")
                        Button(pantryText("Turn off my reminders"), role: .destructive) { disabling = true }
                    } footer: {
                        Text(pantryText("Choose the stored deliveries you bought. A reminder needs three comparable purchase days."))
                    }
                } else {
                    Section {
                        Button(pantryText("Turn on my reminders")) { Task { await model.changeStaples(.enable(true), reviewed: state) } }
                    } footer: {
                        Text(pantryText("Only you can see and answer your reminders on your enrolled devices."))
                    }
                }
            }
            if model.busy { ProgressView() }
        }.disabled(model.busy)
            .navigationTitle(pantryText("Staple reminders"))
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button(tr("Done")) { dismiss() } } }
            .task { await model.loadStaples() }
            .confirmationDialog(pantryText("Forget this staple and its reviewed purchases?"),
                                isPresented: Binding(get: { forget != nil }, set: { if !$0 { forget = nil } }), presenting: forget) { group in
                Button(pantryText("Forget this staple"), role: .destructive) {
                    if let state = model.staples { Task { await model.changeStaples(.forget(group.id), reviewed: state) } }
                }
            }
            .confirmationDialog(pantryText("Remove this purchase from the reminder?"),
                                isPresented: Binding(get: { removing != nil }, set: { if !$0 { removing = nil } }), presenting: removing) { source in
                Button(pantryText("Remove from this staple"), role: .destructive) {
                    if let state = model.staples {
                        Task { await model.changeStaples(.removePurchase(group: source.group, lot: source.lot), reviewed: state) }
                    }
                }
            }
            .confirmationDialog(pantryText("Turn off reminders and forget your reviewed purchases?"), isPresented: $disabling) {
                Button(pantryText("Turn off my reminders"), role: .destructive) {
                    if let state = model.staples { Task { await model.changeStaples(.enable(false), reviewed: state) } }
                }
            }
    }

    @ViewBuilder private func groupSection(_ group: HouseholdStaplePage.Group, _ state: HouseholdStaplePage) -> some View {
        Section(group.name) {
            if let prompt = group.prompt {
                Text(String(format: pantryText("Need %@ this week?"), group.name)).font(.headline)
                Text(String(format: pantryText("%lld purchase days, usually %lld days apart."),
                            prompt.purchaseDays, prompt.intervalDays))
                Button(pantryText("Still have it")) { answer(.stillHave, group, prompt, state) }
                    .accessibilityIdentifier("householdStaple.stillHave")
                Button(pantryText("Snooze for one week")) { answer(.snooze, group, prompt, state) }
                Button(pantryText("Dismiss this reminder")) { answer(.dismiss, group, prompt, state) }
            } else {
                Text(group.purchases.count == 1 ? pantryText("1 reviewed purchase") : String(format: pantryText("%lld reviewed purchases"), group.purchases.count))
            }
            DisclosureGroup(pantryText("Reviewed purchases")) {
                ForEach(group.purchases, id: \.lotId) { purchase in
                    VStack(alignment: .leading) {
                        Text(verbatim: purchase.foodName ?? group.name)
                        Text(verbatim: purchase.day).foregroundStyle(.secondary)
                        Button(pantryText("Remove from this staple"), role: .destructive) {
                            removing = (group.id, purchase.lotId)
                        }
                    }
                }
            }
            Button(pantryText("Forget this staple"), role: .destructive) { forget = group }
        }
    }

    private func answer(_ choice: HouseholdStapleAction.Answer, _ group: HouseholdStaplePage.Group,
                        _ prompt: HouseholdStaplePage.Group.Prompt, _ state: HouseholdStaplePage) {
        Task { await model.changeStaples(.answer(group: group.id, basis: prompt.basis, choice: choice), reviewed: state) }
    }
}

private struct HouseholdStaplePurchaseView: View {
    @ObservedObject var model: HouseholdPantryModel
    let state: HouseholdStaplePage
    @Environment(\.dismiss) private var dismiss
    @State private var lotID: UUID?
    @State private var groupID: UUID?
    @State private var name = ""
    @State private var day = Date()
    @State private var reviewing = false

    private var lots: [HouseholdPantryPage.Lot] {
        model.lots.filter { $0.origin == .delivery && ($0.observation?.quantity?.amount.numerator ?? 0) > 0 }
    }
    var body: some View {
        let lot = lots.first { $0.id == lotID }
        let group = state.groups.first { $0.id == groupID }
        let title = group?.name ?? name.trimmingCharacters(in: .whitespacesAndNewlines)
        Form {
            if reviewing, let lot, let count = lot.observation {
                LabeledContent(pantryText("Staple"), value: title)
                LabeledContent(ht("Food name"), value: lot.foodName)
                LabeledContent(ht("Confirmed usable quantity"), value: deliveryQuantityText(count.quantity))
                LabeledContent(pantryText("Purchase day"), value: day.formatted(date: .long, time: .omitted))
                Button(pantryText("Confirm this purchase")) {
                    let format = DateFormatter()
                    format.locale = Locale(identifier: "en_US_POSIX")
                    format.calendar = Calendar(identifier: .gregorian)
                    format.timeZone = TimeZone(identifier: state.zone)
                    format.dateFormat = "yyyy-MM-dd"
                    let action = HouseholdStapleAction.purchase(group: groupID, name: groupID == nil ? title : nil,
                            lot: lot.id, reviewed: count.observationId, day: format.string(from: day))
                    Task { await model.changeStaples(action, reviewed: state); if model.staples != state { dismiss() } }
                }.accessibilityIdentifier("householdStaple.confirmPurchase")
                Button(pantryText("Edit purchase")) { reviewing = false }
            } else {
                Section {
                    Picker(pantryText("Stored delivery"), selection: $lotID) {
                        Text(pantryText("Choose a delivery")).tag(Optional<UUID>.none)
                        ForEach(lots) { lot in
                            let date = lot.observation.flatMap { serviceDate($0.confirmedAt) }?.formatted(date: .abbreviated, time: .shortened) ?? ""
                            Text(verbatim: [lot.foodName, deliveryQuantityText(lot.observation?.quantity), date].joined(separator: " · ")).tag(Optional(lot.id))
                        }
                    }
                    .accessibilityIdentifier("householdStaple.delivery")
                    if lots.isEmpty { Text(pantryText("No loaded delivery has a confirmed usable quantity.")) }
                    if model.page?.nextCursor != nil { Button(pantryText("Load more food")) { Task { await model.loadMore() } } }
                } footer: { Text(pantryText("Use the receipt to check the purchase day and the amount of usable food.")) }
                if !lots.isEmpty {
                    Picker(pantryText("Staple"), selection: $groupID) {
                        Text(pantryText("New staple")).tag(Optional<UUID>.none)
                        ForEach(state.groups) { Text($0.name).tag(Optional($0.id)) }
                    }
                    .accessibilityIdentifier("householdStaple.group")
                    if groupID == nil { TextField(pantryText("Staple name"), text: $name).accessibilityIdentifier("householdStaple.name") }
                    DatePicker(pantryText("Purchase day"), selection: $day, in: ...Date.now, displayedComponents: .date)
                    Button(pantryText("Review purchase")) { reviewing = true }.accessibilityIdentifier("householdStaple.review").disabled(lot == nil || title.isEmpty || title.count > 120)
                }
            }
        }.navigationTitle(pantryText("Review a purchase")).disabled(model.busy)
            .onChange(of: lotID) { _, id in
                let group = state.groups.first { group in group.purchases.contains { $0.lotId == id } }
                groupID = group?.id
                if let value = group?.purchases.first(where: { $0.lotId == id })?.day {
                    let parser = DateFormatter()
                    parser.locale = Locale(identifier: "en_US_POSIX")
                    parser.timeZone = TimeZone(identifier: state.zone)
                    parser.dateFormat = "yyyy-MM-dd"
                    if let prior = parser.date(from: value) { day = prior }
                }
            }
    }
}
